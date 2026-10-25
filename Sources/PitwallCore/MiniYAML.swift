import Foundation

/// A parsed YAML value. Scalars stay strings; callers decide what they mean.
public indirect enum YAMLNode: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let key: String
        public let value: YAMLNode
    }

    case scalar(String)
    case list([YAMLNode])
    case map([Entry])

    public subscript(key: String) -> YAMLNode? {
        guard case .map(let entries) = self else { return nil }
        return entries.last { $0.key == key }?.value
    }

    public var string: String? {
        if case .scalar(let s) = self { return s }
        return nil
    }
}

public enum YAMLError: Error, Equatable {
    case tooLarge
    case tooDeep
    case malformed(line: Int, reason: String)
}

/// Just enough YAML for GitHub workflow files: block maps and lists, flow
/// lists and maps, quoted and plain scalars, `|` / `>` block scalars and
/// comments. No anchors, tags or multiple documents. Workflow files come
/// from the repository, so input size and nesting are capped.
public enum MiniYAML {
    public static let maxBytes = 512 * 1024
    public static let maxDepth = 64

    public static func parse(_ source: String) throws -> YAMLNode {
        guard source.utf8.count <= maxBytes else { throw YAMLError.tooLarge }
        var parser = Parser(lines: source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init))
        return try parser.parseDocument()
    }

    private struct Line {
        let number: Int
        let indent: Int
        let text: String
    }

    private struct Parser {
        var raw: [String]
        var index = 0
        var depth = 0

        init(lines: [String]) { raw = lines }

        mutating func parseDocument() throws -> YAMLNode {
            // Skip a leading document marker.
            if let line = try peek(), line.text == "---" { index += 1 }
            guard let first = try peek() else { return .map([]) }
            let node = try parseBlock(indent: first.indent)
            if let extra = try peek(), !isDocumentMarker(extra.text) {
                throw YAMLError.malformed(line: extra.number, reason: "unexpected indentation")
            }
            return node
        }

        /// Next line with content, comments stripped. Doesn't consume it.
        mutating func peek() throws -> Line? {
            while index < raw.count {
                let line = raw[index]
                let spaces = line.prefix { $0 == " " }.count
                let rest = line.dropFirst(spaces)
                if rest.first == "\t" { throw YAMLError.malformed(line: index + 1, reason: "tabs can't indent YAML") }
                let text = stripComment(String(rest)).trimmingCharacters(in: .whitespaces)
                if text.isEmpty { index += 1; continue }
                return Line(number: index + 1, indent: spaces, text: text)
            }
            return nil
        }

        mutating func parseBlock(indent: Int) throws -> YAMLNode {
            depth += 1
            defer { depth -= 1 }
            guard depth <= MiniYAML.maxDepth else { throw YAMLError.tooDeep }
            guard let line = try peek() else { return .scalar("") }
            return isListItem(line.text) ? try parseList(indent: indent) : try parseMap(indent: indent)
        }

        mutating func parseMap(indent: Int) throws -> YAMLNode {
            var entries: [YAMLNode.Entry] = []
            while let line = try peek(), line.indent == indent, !isListItem(line.text), !isDocumentMarker(line.text) {
                guard let (rawKey, rest) = splitKey(line.text) else {
                    throw YAMLError.malformed(line: line.number, reason: "expected `key: value`")
                }
                index += 1
                let value = try parseValue(rest, parentIndent: indent, line: line.number, allowSameIndentList: true)
                entries.append(.init(key: unquote(rawKey), value: value))
            }
            if let line = try peek(), line.indent > indent {
                throw YAMLError.malformed(line: line.number, reason: "unexpected indentation")
            }
            return .map(entries)
        }

        mutating func parseList(indent: Int) throws -> YAMLNode {
            var items: [YAMLNode] = []
            while let line = try peek(), line.indent == indent, isListItem(line.text) {
                let content = String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty, splitKey(content) != nil, !content.hasPrefix("[") , !content.hasPrefix("{") {
                    // `- key: value` starts a map whose keys line up with `key`.
                    let offset = line.text.count - content.count
                    raw[index] = String(repeating: " ", count: indent + offset) + content
                    items.append(try parseBlock(indent: indent + offset))
                } else {
                    index += 1
                    items.append(try parseValue(content, parentIndent: indent, line: line.number, allowSameIndentList: false))
                }
            }
            return .list(items)
        }

        /// The value after `key:` or `- `.
        mutating func parseValue(_ rest: String, parentIndent: Int, line: Int, allowSameIndentList: Bool) throws -> YAMLNode {
            if rest.isEmpty {
                guard let next = try peek() else { return .scalar("") }
                if next.indent > parentIndent { return try parseBlock(indent: next.indent) }
                if allowSameIndentList, next.indent == parentIndent, isListItem(next.text) {
                    return try parseList(indent: parentIndent)
                }
                return .scalar("")
            }
            if rest.hasPrefix("|") || rest.hasPrefix(">") {
                return .scalar(blockScalar(folded: rest.hasPrefix(">"), parentIndent: parentIndent))
            }
            if rest.hasPrefix("[") || rest.hasPrefix("{") {
                var text = rest
                // Flow collections may span lines; gather until brackets balance.
                while !isBalanced(text) {
                    guard let next = try peek() else { throw YAMLError.malformed(line: line, reason: "unclosed bracket") }
                    index += 1
                    text += " " + next.text
                }
                var flow = FlowParser(text: text, line: line)
                return try flow.parse()
            }
            return .scalar(unquote(rest))
        }

        /// Lines indented deeper than the key, taken verbatim (comments included).
        mutating func blockScalar(folded: Bool, parentIndent: Int) -> String {
            var lines: [String] = []
            var contentIndent: Int?
            while index < raw.count {
                let line = raw[index]
                let spaces = line.prefix { $0 == " " }.count
                let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
                if !isBlank && spaces <= parentIndent { break }
                if !isBlank && contentIndent == nil { contentIndent = spaces }
                lines.append(isBlank ? "" : String(line.dropFirst(min(spaces, contentIndent ?? spaces))))
                index += 1
            }
            while lines.last == "" { lines.removeLast() }
            return folded ? lines.joined(separator: " ") : lines.joined(separator: "\n")
        }

        func isListItem(_ text: String) -> Bool {
            text == "-" || text.hasPrefix("- ")
        }

        /// `---` or `...`: only the first document is read.
        func isDocumentMarker(_ text: String) -> Bool {
            text == "---" || text == "..."
        }
    }

    /// `[a, "b", [c]]` and `{a: 1, b: x}` on one (joined) line.
    private struct FlowParser {
        let chars: [Character]
        let line: Int
        var pos = 0
        var depth = 0

        init(text: String, line: Int) {
            chars = Array(text)
            self.line = line
        }

        mutating func parse() throws -> YAMLNode {
            let node = try value()
            skipSpaces()
            guard pos == chars.count else { throw YAMLError.malformed(line: line, reason: "text after flow collection") }
            return node
        }

        mutating func value() throws -> YAMLNode {
            skipSpaces()
            guard pos < chars.count else { return .scalar("") }
            switch chars[pos] {
            case "[": return try collection(close: "]", isMap: false)
            case "{": return try collection(close: "}", isMap: true)
            default: return .scalar(unquote(scalarText(stopAt: [",", "]", "}"])))
            }
        }

        mutating func collection(close: Character, isMap: Bool) throws -> YAMLNode {
            depth += 1
            defer { depth -= 1 }
            guard depth <= MiniYAML.maxDepth else { throw YAMLError.tooDeep }
            pos += 1
            var items: [YAMLNode] = []
            var entries: [YAMLNode.Entry] = []
            while true {
                skipSpaces()
                guard pos < chars.count else { throw YAMLError.malformed(line: line, reason: "unclosed bracket") }
                if chars[pos] == close { pos += 1; break }
                if isMap {
                    let key = unquote(scalarText(stopAt: [":", ",", "}"]))
                    var item = YAMLNode.scalar("")
                    if pos < chars.count, chars[pos] == ":" { pos += 1; item = try value() }
                    entries.append(.init(key: key, value: item))
                } else {
                    items.append(try value())
                }
                skipSpaces()
                if pos < chars.count, chars[pos] == "," { pos += 1 }
            }
            return isMap ? .map(entries) : .list(items)
        }

        mutating func scalarText(stopAt stops: Set<Character>) -> String {
            skipSpaces()
            var out = ""
            var quote: Character?
            while pos < chars.count {
                let c = chars[pos]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if stops.contains(c) {
                    break
                }
                out.append(c)
                pos += 1
            }
            return out.trimmingCharacters(in: .whitespaces)
        }

        mutating func skipSpaces() {
            while pos < chars.count, chars[pos] == " " { pos += 1 }
        }
    }

    /// Drops a `#` comment that isn't inside quotes.
    static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for (i, c) in zip(text.indices, text) {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", previous == " " {
                return String(text[..<i])
            }
            previous = c
        }
        return text
    }

    /// Splits `key: value` at the first unquoted `:` followed by a space or the end.
    static func splitKey(_ text: String) -> (String, String)? {
        var quote: Character?
        let chars = Array(text)
        for i in chars.indices {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
                continue
            }
            if (c == "\"" || c == "'") && i == 0 { quote = c; continue }
            if c == "[" || c == "{" { return nil }
            if c == ":", i + 1 == chars.count || chars[i + 1] == " " {
                let key = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (key, String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func unquote(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, let first = t.first, first == t.last, first == "\"" || first == "'" else { return t }
        let inner = String(t.dropFirst().dropLast())
        if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var out = ""
        var escaping = false
        for c in inner {
            if escaping {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    static func isBalanced(_ text: String) -> Bool {
        var level = 0
        var quote: Character?
        for c in text {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "[" || c == "{" {
                level += 1
            } else if c == "]" || c == "}" {
                level -= 1
            }
        }
        return level <= 0
    }
}

import Foundation

/// A validated `owner/name` pair. Construction is the only way in, so every
/// value that reaches a URL path has already passed the GitHub naming rules.
public struct RepoRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public var fullName: String { "\(owner)/\(name)" }
    public var description: String { fullName }

    public init?(owner: String, name: String) {
        guard Validation.isValidOwner(owner), Validation.isValidRepoName(name) else { return nil }
        self.owner = owner
        self.name = name
    }

    public init?(fullName: String) {
        let parts = fullName.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(owner: String(parts[0]), name: String(parts[1]))
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let ref = RepoRef(fullName: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid repo"))
        }
        self = ref
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fullName)
    }
}

public enum Validation {
    // GitHub logins: alphanumerics and single hyphens, max 39 chars. Underscores
    // appear in Enterprise Managed User logins (`jdoe_acme`).
    private static var ownerPattern: Regex<Substring> { /^[A-Za-z0-9](?:[A-Za-z0-9_]|-(?=[A-Za-z0-9])){0,38}$/ }
    // Repo names: letters, digits, '-', '_', '.', max 100 chars. "." and ".." are reserved.
    private static var repoPattern: Regex<Substring> { /^[A-Za-z0-9._-]{1,100}$/ }
    // Workflow input keys follow YAML identifier rules in practice.
    private static var inputKeyPattern: Regex<Substring> { /^[A-Za-z_][A-Za-z0-9_-]{0,99}$/ }
    // Classic (ghp_, gho_, ...) and fine-grained (github_pat_) tokens.
    private static var tokenPattern: Regex<Substring> { /^[A-Za-z0-9_]{20,255}$/ }

    public static let maxDispatchInputs = 25
    public static let maxInputValueLength = 65_535

    public static func isValidOwner(_ s: String) -> Bool {
        s.wholeMatch(of: ownerPattern) != nil
    }

    public static func isValidRepoName(_ s: String) -> Bool {
        s != "." && s != ".." && s.wholeMatch(of: repoPattern) != nil
    }

    public static func isValidToken(_ s: String) -> Bool {
        s.wholeMatch(of: tokenPattern) != nil
    }

    public static func isValidInputKey(_ s: String) -> Bool {
        s.wholeMatch(of: inputKeyPattern) != nil
    }

    /// Git ref rules (subset of `git check-ref-format`), enough to reject
    /// anything that could confuse a request body or path.
    public static func isValidRef(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 255 else { return false }
        if s.hasPrefix("/") || s.hasSuffix("/") || s.hasSuffix(".") || s.hasSuffix(".lock") { return false }
        if s.contains("..") || s.contains("//") || s.contains("@{") { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters)
        return s.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    /// Only ever hand the system browser github.com pages.
    public static func isSafeGitHubWebURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" && url.user == nil && url.password == nil && url.port == nil
    }
}

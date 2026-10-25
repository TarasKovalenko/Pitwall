import Foundation
import Security

/// Where the GitHub token lives. `TokenStore` is the Keychain adapter.
public protocol TokenStoring: AnyObject, Sendable {
    func token() -> String?
    func save(_ token: String) throws
    func delete()
}

/// Keeps the GitHub token in the login Keychain. The token never touches
/// UserDefaults, disk, or logs. Reads are cached in memory so the poller
/// doesn't hit Keychain on every request.
public final class TokenStore: TokenStoring, @unchecked Sendable {
    private let service: String
    private let account = "github-token"
    private let lock = NSLock()
    private var cached: String??

    public static let defaultService = "dev.pitwall.Pitwall"

    public init(service: String = TokenStore.defaultService) {
        self.service = service
    }

    public func token() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let value = read()
        cached = .some(value)
        return value
    }

    public func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Validation.isValidToken(trimmed) else {
            throw GitHubError.invalidInput("That doesn't look like a GitHub token.")
        }
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = Data(trimmed.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attrs[kSecAttrLabel as String] = "Pitwall GitHub token"
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GitHubError.invalidInput("Couldn't save to Keychain (\(status)).")
        }
        cached = .some(trimmed)
    }

    public func delete() {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery as CFDictionary)
        cached = .some(nil)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Borrows the token the GitHub CLI already has (`gh auth token`).
/// Runs a fixed binary with fixed arguments, no shell involved.
public enum GitHubCLITokenImporter {
    static let candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    public static var cliPath: String? { cliPath(in: candidatePaths) }

    static func cliPath(in candidates: [String]) -> String? {
        candidates.first { path in
            let fm = FileManager.default
            guard fm.isExecutableFile(atPath: path),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  let perms = attrs[.posixPermissions] as? NSNumber
            else { return false }
            // Skip binaries anyone can overwrite.
            return perms.intValue & 0o002 == 0
        }
    }

    public static func importToken(timeout: TimeInterval = 5) async throws -> String {
        try await importToken(timeout: timeout, candidates: candidatePaths)
    }

    static func importToken(timeout: TimeInterval, candidates: [String]) async throws -> String {
        guard let path = cliPath(in: candidates) else {
            throw GitHubError.invalidInput("GitHub CLI not found. Install it with `brew install gh`.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["auth", "token", "--hostname", "github.com"]
            // Minimal environment: nothing from our process leaks to the child,
            // and no GH_HOST/GH_TOKEN overrides sneak in.
            process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                process.terminate()
                throw GitHubError.invalidInput("`gh auth token` timed out.")
            }
            let data = out.fileHandleForReading.readDataToEndOfFile().prefix(512)
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, Validation.isValidToken(token) else {
                throw GitHubError.invalidInput("GitHub CLI isn't logged in. Run `gh auth login` first.")
            }
            return token
        }.value
    }
}

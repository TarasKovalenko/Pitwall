import Foundation
import Security

/// Where the GitHub token lives. `FileTokenStore` is the one the app uses;
/// `TokenStore` (Keychain) is only read once, to move an older install's token.
public protocol TokenStoring: AnyObject, Sendable {
    func token() -> String?
    func save(_ token: String) throws
    func delete()
}

/// Keeps the GitHub token in the login Keychain. Versions up to 0.2.1 used
/// this. The release builds are ad-hoc signed, and the Keychain only hands an
/// item back to the exact build that wrote it, so every update lost the token.
/// Reads are cached in memory so the poller doesn't hit Keychain on every request.
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

/// Keeps the GitHub token in a file only the user can read:
/// `~/Library/Application Support/Pitwall/token`, 0600 inside a 0700 folder.
/// Survives updates, unlike the Keychain for an ad-hoc signed app (see
/// `TokenStore`). Written atomically; a file that's a symlink, owned by
/// someone else, readable by others or oversized is ignored. Never logged.
public final class FileTokenStore: TokenStoring, @unchecked Sendable {
    public let url: URL
    private let legacy: (any TokenStoring)?
    private let lock = NSLock()
    private var cached: String??

    static let maxBytes = 1024

    /// The app's store, which moves a token left in the Keychain by an older version.
    public static func standard() -> FileTokenStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileTokenStore(url: support.appending(path: "Pitwall/token"), legacy: TokenStore())
    }

    /// `legacy` is read only while there's no token file yet.
    public init(url: URL, legacy: (any TokenStoring)? = nil) {
        self.url = url
        self.legacy = legacy
    }

    public func token() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var value = read()
        if value == nil, !fileExists, let old = legacy?.token(), Validation.isValidToken(old) {
            if (try? write(old)) != nil { legacy?.delete() }
            value = old
        }
        cached = .some(value)
        return value
    }

    public func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Validation.isValidToken(trimmed) else {
            throw GitHubError.invalidInput("That doesn't look like a GitHub token.")
        }
        lock.lock(); defer { lock.unlock() }
        try write(trimmed)
        cached = .some(trimmed)
    }

    public func delete() {
        lock.lock(); defer { lock.unlock() }
        unlink(url.path)
        legacy?.delete()
        cached = .some(nil)
    }

    private var fileExists: Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func read() -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0,
              info.st_size <= Self.maxBytes
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: Self.maxBytes + 1)
        let count = Foundation.read(fd, &buffer, buffer.count)
        guard count > 0, count <= Self.maxBytes else { return nil }
        let text = String(decoding: buffer[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Validation.isValidToken(text) ? text : nil
    }

    /// Temp file then rename, so a crash never leaves half a token and a
    /// symlink planted at `url` is replaced rather than followed.
    private func write(_ token: String) throws {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw GitHubError.invalidInput("Couldn't create \(dir.path).")
        }
        var info = stat()
        guard lstat(dir.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw GitHubError.invalidInput("\(dir.path) isn't a folder Pitwall owns.")
        }
        chmod(dir.path, 0o700)

        let temp = dir.appending(path: ".token-\(UUID().uuidString)").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GitHubError.invalidInput("Couldn't save the token (\(errnoText)).") }
        let bytes = Array(token.utf8)
        let ok = Foundation.write(fd, bytes, bytes.count) == bytes.count && fsync(fd) == 0
        close(fd)
        guard ok, rename(temp, url.path) == 0 else {
            let reason = errnoText
            unlink(temp)
            throw GitHubError.invalidInput("Couldn't save the token (\(reason)).")
        }
    }

    private var errnoText: String { String(cString: strerror(errno)) }
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

import Foundation

public enum GitHubError: Error, Equatable, LocalizedError {
    case missingToken
    case unauthorized
    case forbidden(String)
    case notFound
    case rateLimited(resetAt: Date)
    case validation(String)
    case http(Int)
    case invalidInput(String)
    case transport(String)
    case decoding

    public var errorDescription: String? {
        switch self {
        case .missingToken: "No GitHub token. Add one in Settings."
        case .unauthorized: "GitHub rejected the token. It may be expired or revoked."
        case .forbidden(let m): "Not allowed: \(m)"
        case .notFound: "Not found, or the token can't see it."
        case .rateLimited(let reset):
            "Rate limited until \(reset.formatted(date: .omitted, time: .shortened))."
        case .validation(let m): "GitHub refused the request: \(m)"
        case .http(let code): "GitHub returned HTTP \(code)."
        case .invalidInput(let m): m
        case .transport(let m): "Network error: \(m)"
        case .decoding: "Unexpected response from GitHub."
        }
    }
}

/// Everything RunStore needs from GitHub. `GitHubClient` is the real
/// adapter; tests use an in-memory one.
public protocol GitHubAPI: Sendable {
    func currentUser() async throws -> GitHubUser
    func repositories() async throws -> [Repository]
    func runs(for repo: RepoRef) async throws -> [WorkflowRun]
    func jobs(for repo: RepoRef, runID: Int) async throws -> [Job]
    func workflows(for repo: RepoRef) async throws -> [Workflow]
    func branches(for repo: RepoRef) async throws -> [Branch]
    func dispatch(repo: RepoRef, workflowID: Int, ref: String, inputs: [String: String]) async throws
    func rerun(repo: RepoRef, runID: Int, failedOnly: Bool) async throws
    func cancel(repo: RepoRef, runID: Int) async throws
    /// Forget cached responses, e.g. when the account changes.
    func clearCache() async
    /// Budget reported by the most recent response.
    var rateLimit: RateLimit? { get async }
}

/// Talks to the GitHub REST API. All requests go to `https://api.github.com`;
/// the host is fixed, so nothing user-controlled can redirect the token.
public actor GitHubClient: GitHubAPI {
    public static let apiHost = "api.github.com"

    private let transport: any HTTPTransport
    private let tokenProvider: @Sendable () -> String?
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // ETag cache. 304 responses don't count against the rate limit, which is
    // what lets us poll every few seconds while a run is active.
    private var etagCache: [String: (etag: String, body: Data)] = [:]
    private var etagOrder: [String] = []
    private let etagCapacity = 300
    /// Bumped by `clearCache`. A response that started before the bump
    /// belongs to the previous account and must not land in the cache.
    private var cacheGeneration = 0
    private let maxRepositoryPages = 5

    public private(set) var rateLimit: RateLimit?

    public init(tokenProvider: @escaping @Sendable () -> String?, transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
        self.tokenProvider = tokenProvider
    }

    // MARK: Endpoints

    public func currentUser() async throws -> GitHubUser {
        try await get(["user"])
    }

    /// Repositories the user can see, most recently pushed first. Capped at
    /// five pages so huge org memberships don't stall the settings screen.
    public func repositories() async throws -> [Repository] {
        var all: [Repository] = []
        for page in 1...maxRepositoryPages {
            let batch: [Repository] = try await get(["user", "repos"], query: [
                .init(name: "per_page", value: "100"),
                .init(name: "page", value: String(page)),
                .init(name: "sort", value: "pushed"),
                .init(name: "affiliation", value: "owner,collaborator,organization_member"),
            ])
            all += batch
            if batch.count < 100 { break }
        }
        return all
    }

    public func runs(for repo: RepoRef) async throws -> [WorkflowRun] {
        let list: WorkflowRunList = try await get(
            ["repos", repo.owner, repo.name, "actions", "runs"],
            query: [.init(name: "per_page", value: "10")]
        )
        return list.workflowRuns
    }

    public func workflows(for repo: RepoRef) async throws -> [Workflow] {
        let list: WorkflowList = try await get(
            ["repos", repo.owner, repo.name, "actions", "workflows"],
            query: [.init(name: "per_page", value: "100")]
        )
        return list.workflows
    }

    public func jobs(for repo: RepoRef, runID: Int) async throws -> [Job] {
        let list: JobList = try await get(
            ["repos", repo.owner, repo.name, "actions", "runs", String(runID), "jobs"],
            query: [.init(name: "per_page", value: "100")]
        )
        return list.jobs
    }

    public func branches(for repo: RepoRef) async throws -> [Branch] {
        try await get(["repos", repo.owner, repo.name, "branches"], query: [.init(name: "per_page", value: "100")])
    }

    public func dispatch(repo: RepoRef, workflowID: Int, ref: String, inputs: [String: String]) async throws {
        guard Validation.isValidRef(ref) else { throw GitHubError.invalidInput("Invalid branch or tag name.") }
        guard inputs.count <= Validation.maxDispatchInputs else {
            throw GitHubError.invalidInput("Too many inputs (max \(Validation.maxDispatchInputs)).")
        }
        for (key, value) in inputs {
            guard Validation.isValidInputKey(key) else { throw GitHubError.invalidInput("Invalid input name: \(key)") }
            guard value.utf8.count <= Validation.maxInputValueLength else {
                throw GitHubError.invalidInput("Input \(key) is too long.")
            }
        }
        struct Body: Encodable { let ref: String; let inputs: [String: String] }
        let body = try JSONEncoder().encode(Body(ref: ref, inputs: inputs))
        try await send("POST", ["repos", repo.owner, repo.name, "actions", "workflows", String(workflowID), "dispatches"], body: body)
    }

    public func rerun(repo: RepoRef, runID: Int, failedOnly: Bool) async throws {
        let action = failedOnly ? "rerun-failed-jobs" : "rerun"
        try await send("POST", ["repos", repo.owner, repo.name, "actions", "runs", String(runID), action])
    }

    public func cancel(repo: RepoRef, runID: Int) async throws {
        try await send("POST", ["repos", repo.owner, repo.name, "actions", "runs", String(runID), "cancel"])
    }

    public func clearCache() {
        etagCache.removeAll()
        etagOrder.removeAll()
        cacheGeneration += 1
        rateLimit = nil
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: [String], query: [URLQueryItem] = []) async throws -> T {
        let url = try Self.makeURL(path: path, query: query)
        let key = url.absoluteString
        let generation = cacheGeneration
        var request = try authorizedRequest(url: url, method: "GET")
        let cached = etagCache[key]
        if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }

        var (data, http) = try await perform(request)
        if http.statusCode == 304 {
            // Read the cache again: it may have been cleared while we waited.
            if let fresh = etagCache[key], fresh.etag == cached?.etag, generation == cacheGeneration {
                return try decode(fresh.body)
            }
            // Nothing to serve the 304 from. Ask once more for the full body,
            // with a fresh request so it carries the current token.
            request = try authorizedRequest(url: url, method: "GET")
            (data, http) = try await perform(request)
        }
        try check(http, data: data)
        if let etag = http.value(forHTTPHeaderField: "ETag"), generation == cacheGeneration {
            storeETag(etag, body: data, for: key)
        }
        return try decode(data)
    }

    private func decode<T: Decodable>(_ body: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: body)
        } catch {
            throw GitHubError.decoding
        }
    }

    private func send(_ method: String, _ path: [String], body: Data? = nil) async throws {
        let url = try Self.makeURL(path: path, query: [])
        var request = try authorizedRequest(url: url, method: method)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, http) = try await perform(request)
        try check(http, data: data)
    }

    private func authorizedRequest(url: URL, method: String) throws -> URLRequest {
        guard let token = tokenProvider(), !token.isEmpty else { throw GitHubError.missingToken }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Pitwall", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // The token only ever goes to the API host, whatever transport is plugged in.
        guard request.url?.scheme == "https", request.url?.host == Self.apiHost else {
            throw GitHubError.invalidInput("Refusing to send the token outside \(Self.apiHost)")
        }
        let (data, http) = try await transport.send(request)
        if let limit = Self.rateLimit(from: http) { rateLimit = limit }
        return (data, http)
    }

    private func check(_ http: HTTPURLResponse, data: Data) throws {
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            // Decide from this response's own headers, not whatever was stored last.
            let limit = Self.rateLimit(from: http)
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            if limit?.remaining == 0 || retryAfter != nil || http.statusCode == 429 {
                let resetAt = retryAfter.map { Date().addingTimeInterval($0) }
                    ?? limit?.resetAt ?? Date().addingTimeInterval(60)
                throw GitHubError.rateLimited(resetAt: resetAt)
            }
            throw GitHubError.forbidden(Self.apiMessage(data) ?? "missing permission")
        case 404:
            throw GitHubError.notFound
        case 409, 422:
            throw GitHubError.validation(Self.apiMessage(data) ?? "invalid request")
        default:
            throw GitHubError.http(http.statusCode)
        }
    }

    static func rateLimit(from http: HTTPURLResponse) -> RateLimit? {
        guard
            let limit = http.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init),
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        else { return nil }
        return RateLimit(limit: limit, remaining: remaining, resetAt: Date(timeIntervalSince1970: reset))
    }

    private func storeETag(_ etag: String, body: Data, for key: String) {
        if etagCache[key] == nil {
            etagOrder.append(key)
            if etagOrder.count > etagCapacity {
                etagCache.removeValue(forKey: etagOrder.removeFirst())
            }
        }
        etagCache[key] = (etag, body)
    }

    /// Builds the URL from path segments. Each segment is percent-encoded on
    /// its own, so a segment can never introduce `/`, `?` or `#`.
    static func makeURL(path: [String], query: [URLQueryItem]) throws -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        let encoded = try path.map { segment -> String in
            guard !segment.isEmpty, segment != ".", segment != "..",
                  let e = segment.addingPercentEncoding(withAllowedCharacters: allowed)
            else { throw GitHubError.invalidInput("Invalid path segment") }
            return e
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.percentEncodedPath = "/" + encoded.joined(separator: "/")
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GitHubError.invalidInput("Invalid URL") }
        return url
    }

    /// GitHub error bodies carry a `message`. Keep it short; it ends up in the UI.
    private static func apiMessage(_ data: Data) -> String? {
        struct APIError: Decodable { let message: String }
        guard let message = try? JSONDecoder().decode(APIError.self, from: data).message else { return nil }
        return String(message.prefix(200))
    }
}

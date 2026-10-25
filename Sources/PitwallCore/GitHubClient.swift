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

/// Talks to the GitHub REST API. All requests go to `https://api.github.com`;
/// the host is fixed, so nothing user-controlled can redirect the token.
public actor GitHubClient {
    public static let apiHost = "api.github.com"

    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?
    private let redirectGuard = SameHostRedirectGuard()
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

    public private(set) var rateLimit: RateLimit?

    public init(tokenProvider: @escaping @Sendable () -> String?) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.tokenProvider = tokenProvider
    }

    // MARK: Endpoints

    public func currentUser() async throws -> GitHubUser {
        try await get(["user"])
    }

    /// Repositories the user can see, most recently pushed first. Capped at
    /// `maxPages` so huge org memberships don't stall the settings screen.
    public func repositories(maxPages: Int = 5) async throws -> [Repository] {
        var all: [Repository] = []
        for page in 1...maxPages {
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

    public func runs(for repo: RepoRef, perPage: Int = 10) async throws -> [WorkflowRun] {
        let list: WorkflowRunList = try await get(
            ["repos", repo.owner, repo.name, "actions", "runs"],
            query: [.init(name: "per_page", value: String(min(max(perPage, 1), 100)))]
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
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: [String], query: [URLQueryItem] = []) async throws -> T {
        let url = try Self.makeURL(path: path, query: query)
        var request = try authorizedRequest(url: url, method: "GET")
        let key = url.absoluteString
        if let cached = etagCache[key] {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, http) = try await perform(request)
        let body: Data
        if http.statusCode == 304, let cached = etagCache[key] {
            body = cached.body
        } else {
            try check(http, data: data)
            body = data
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                storeETag(etag, body: data, for: key)
            }
        }
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
        do {
            let (data, response) = try await session.data(for: request, delegate: redirectGuard)
            guard let http = response as? HTTPURLResponse else { throw GitHubError.transport("No HTTP response") }
            updateRateLimit(from: http)
            return (data, http)
        } catch let error as GitHubError {
            throw error
        } catch {
            throw GitHubError.transport((error as? URLError)?.code.description ?? "request failed")
        }
    }

    private func check(_ http: HTTPURLResponse, data: Data) throws {
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            if rateLimit?.remaining == 0 || http.value(forHTTPHeaderField: "Retry-After") != nil {
                let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                throw GitHubError.rateLimited(resetAt: rateLimit?.resetAt ?? Date().addingTimeInterval(retry))
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

    private func updateRateLimit(from http: HTTPURLResponse) {
        guard
            let limit = http.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init),
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        else { return }
        rateLimit = RateLimit(limit: limit, remaining: remaining, resetAt: Date(timeIntervalSince1970: reset))
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

/// Refuses redirects that leave `api.github.com` over HTTPS, so the bearer
/// token is never replayed to another host.
final class SameHostRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard request.url?.scheme == "https", request.url?.host == GitHubClient.apiHost else { return nil }
        return request
    }
}

private extension URLError.Code {
    var description: String {
        switch self {
        case .notConnectedToInternet: "offline"
        case .timedOut: "timed out"
        case .cannotFindHost, .dnsLookupFailed: "can't reach GitHub"
        case .secureConnectionFailed, .serverCertificateUntrusted: "TLS failure"
        default: "error \(rawValue)"
        }
    }
}

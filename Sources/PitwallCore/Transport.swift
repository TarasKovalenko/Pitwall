import Foundation

/// Sends one HTTP request. `GitHubClient` does everything else (auth headers,
/// ETags, rate limits, status mapping) on top of this, so tests can swap the
/// network for a scripted adapter.
public protocol HTTPTransport: Sendable {
    /// Errors should be `GitHubError.transport` so callers see one error type.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real adapter: an ephemeral URLSession that refuses cross-host redirects.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let redirectGuard = SameHostRedirectGuard()

    public convenience init() {
        self.init(configuration: .ephemeral)
    }

    /// Tests pass a configuration with a stub `URLProtocol`.
    init(configuration config: URLSessionConfiguration) {
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request, delegate: redirectGuard)
            guard let http = response as? HTTPURLResponse else { throw GitHubError.transport("No HTTP response") }
            return (data, http)
        } catch let error as GitHubError {
            throw error
        } catch {
            throw GitHubError.transport((error as? URLError)?.code.shortDescription ?? "request failed")
        }
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

extension URLError.Code {
    var shortDescription: String {
        switch self {
        case .notConnectedToInternet: "offline"
        case .timedOut: "timed out"
        case .cannotFindHost, .dnsLookupFailed: "can't reach GitHub"
        case .secureConnectionFailed, .serverCertificateUntrusted: "TLS failure"
        default: "error \(rawValue)"
        }
    }
}

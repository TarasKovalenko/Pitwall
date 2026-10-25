import Foundation
import Testing
@testable import PitwallCore
import PitwallTestSupport

/// Stands in for the network inside a real URLSession.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (URLRequest) -> Result<(URLResponse, Data), URLError> = { _ in .failure(URLError(.unknown)) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        switch Self.reply(request) {
        case .success(let (response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite(.serialized) struct URLSessionTransportTests {
    let url = URL(string: "https://api.github.com/user")!

    func transport() -> URLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSessionTransport(configuration: config)
    }

    @Test func returnsBodyAndResponse() async throws {
        StubProtocol.reply = { request in
            .success((HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "x"])!, Data("hi".utf8)))
        }
        let (data, http) = try await transport().send(URLRequest(url: url))
        #expect(String(decoding: data, as: UTF8.self) == "hi")
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "ETag") == "x")
    }

    @Test func nonHTTPResponseIsATransportError() async {
        StubProtocol.reply = { request in
            .success((URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data()))
        }
        await #expect(throws: GitHubError.transport("No HTTP response")) { try await transport().send(URLRequest(url: url)) }
    }

    @Test func networkErrorsBecomeShortMessages() async {
        let cases: [(URLError.Code, String)] = [
            (.notConnectedToInternet, "offline"), (.timedOut, "timed out"), (.cannotFindHost, "can't reach GitHub"),
            (.dnsLookupFailed, "can't reach GitHub"), (.secureConnectionFailed, "TLS failure"),
            (.serverCertificateUntrusted, "TLS failure"), (.badURL, "error \(URLError.Code.badURL.rawValue)"),
        ]
        for (code, message) in cases {
            StubProtocol.reply = { _ in .failure(URLError(code)) }
            await #expect(throws: GitHubError.transport(message), "\(code)") { try await transport().send(URLRequest(url: url)) }
        }
    }

    @Test func redirectsOnlyStayOnTheAPIHost() async {
        let guardian = SameHostRedirectGuard()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        func follow(_ target: String) async -> URLRequest? {
            await guardian.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!))
        }
        #expect(await follow("https://api.github.com/repos/o/r") != nil)
        #expect(await follow("https://evil.example/steal") == nil)
        #expect(await follow("http://api.github.com/user") == nil)
        #expect(await follow("https://api.github.com.evil.example/") == nil)
    }
}

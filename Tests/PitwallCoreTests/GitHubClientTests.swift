import Foundation
import Testing
@testable import PitwallCore

private let userJSON = #"{"login":"me","avatar_url":null}"#
private let token = "ghp_" + String(repeating: "a", count: 36)

private final class ClientBox: @unchecked Sendable {
    var client: GitHubClient?
}

@Suite struct GitHubClientTests {
    func makeClient(_ transport: ScriptedTransport) -> GitHubClient {
        GitHubClient(tokenProvider: { token }, transport: transport)
    }

    @Test func notModifiedIsServedFromTheETagCache() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.respond(200, body: userJSON, headers: ["ETag": "\"a\""]),
            ScriptedTransport.respond(304),
        ])
        let client = makeClient(transport)
        _ = try await client.currentUser()
        let user = try await client.currentUser()
        #expect(user.login == "me")
        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"a\"")
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }

    @Test func notModifiedAfterTheCacheWasClearedFetchesAgain() async throws {
        let box = ClientBox()
        let transport = ScriptedTransport([
            ScriptedTransport.respond(200, body: userJSON, headers: ["ETag": "\"a\""]),
            { request in
                await box.client?.clearCache() // e.g. sign-out while this request was in flight
                return try await ScriptedTransport.respond(304)(request)
            },
            ScriptedTransport.respond(200, body: userJSON),
        ])
        let client = makeClient(transport)
        box.client = client
        _ = try await client.currentUser()
        let user = try await client.currentUser()
        #expect(user.login == "me")
        #expect(transport.requests.count == 3)
        #expect(transport.requests[2].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func responseFromBeforeACacheClearIsNotCached() async throws {
        let box = ClientBox()
        let transport = ScriptedTransport([
            { request in
                await box.client?.clearCache()
                return try await ScriptedTransport.respond(200, body: userJSON, headers: ["ETag": "\"old\""])(request)
            },
            ScriptedTransport.respond(200, body: userJSON),
        ])
        let client = makeClient(transport)
        box.client = client
        _ = try await client.currentUser()
        _ = try await client.currentUser()
        #expect(transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func forbiddenWithNoBudgetLeftIsARateLimit() async {
        let reset = Date().addingTimeInterval(600).timeIntervalSince1970.rounded()
        let transport = ScriptedTransport([
            ScriptedTransport.respond(403, body: #"{"message":"API rate limit exceeded"}"#, headers: [
                "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset)),
            ]),
        ])
        await #expect(throws: GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: reset))) {
            try await makeClient(transport).currentUser()
        }
    }

    @Test func forbiddenWithBudgetLeftIsAPermissionError() async {
        let transport = ScriptedTransport([
            ScriptedTransport.respond(403, body: #"{"message":"Resource not accessible"}"#, headers: [
                "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4000", "X-RateLimit-Reset": "2000000000",
            ]),
        ])
        await #expect(throws: GitHubError.forbidden("Resource not accessible")) {
            try await makeClient(transport).currentUser()
        }
    }

    @Test func tooManyRequestsIsARateLimit() async {
        let transport = ScriptedTransport([ScriptedTransport.respond(429, headers: ["Retry-After": "30"])])
        do {
            _ = try await makeClient(transport).currentUser()
            Issue.record("expected an error")
        } catch {
            guard case GitHubError.rateLimited = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test func unauthorizedMapsToUnauthorized() async {
        let transport = ScriptedTransport([ScriptedTransport.respond(401)])
        await #expect(throws: GitHubError.unauthorized) { try await makeClient(transport).currentUser() }
    }

    @Test func rateLimitIsReadFromEveryResponse() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.respond(200, body: userJSON, headers: [
                "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4321", "X-RateLimit-Reset": "2000000000",
            ]),
        ])
        let client = makeClient(transport)
        _ = try await client.currentUser()
        #expect(await client.rateLimit?.remaining == 4321)
        await client.clearCache()
        #expect(await client.rateLimit == nil)
    }

    @Test func transportErrorsPassThrough() async {
        let transport = ScriptedTransport([{ _ in throw GitHubError.transport("offline") }])
        await #expect(throws: GitHubError.transport("offline")) { try await makeClient(transport).currentUser() }
    }

    @Test func garbageBodyIsADecodingError() async {
        let transport = ScriptedTransport([ScriptedTransport.respond(200, body: "not json")])
        await #expect(throws: GitHubError.decoding) { try await makeClient(transport).currentUser() }
    }

    @Test func requestsOnlyEverGoToTheAPIHost() async throws {
        let transport = ScriptedTransport([ScriptedTransport.respond(200, body: userJSON)])
        _ = try await makeClient(transport).currentUser()
        #expect(transport.requests.allSatisfy { $0.url?.host == GitHubClient.apiHost && $0.url?.scheme == "https" })
    }
}

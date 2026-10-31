import Foundation
import Testing
@testable import KBMCPServer

@Suite struct HTTPRouteTests {
    let handler = makeHandler(nonce: UUID().uuidString)
    let goodHeaders = ["host": "127.0.0.1:47821", "authorization": "Bearer secret"]

    private func request(
        _ method: String = "POST",
        path: String = "/mcp",
        headers: [String: String],
        body: String = ""
    ) -> MCPHTTPServer.Request {
        MCPHTTPServer.Request(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    private func route(_ request: MCPHTTPServer.Request) async -> MCPHTTPServer.Response {
        await MCPHTTPServer.route(request, handler: handler, token: "secret")
    }

    private func merged(_ extra: [String: String]) -> [String: String] {
        goodHeaders.merging(extra) { $1 }
    }

    @Test func foreignHostIsRejectedEvenWithAGoodToken() async {
        let response = await route(request(headers: merged(["host": "evil.example"]), body: pingBody))
        #expect(response.status == 403)
        #expect(response.body == Data("Forbidden host".utf8))
    }

    @Test func foreignOriginIsRejectedAndALocalOneAccepted() async {
        let foreign = await route(request(headers: merged(["origin": "https://evil.example"]), body: pingBody))
        #expect(foreign.status == 403)
        #expect(foreign.body == Data("Forbidden origin".utf8))
        let local = await route(request(headers: merged(["origin": "http://localhost:3000"]), body: pingBody))
        #expect(local.status == 200)
    }

    @Test func bearerTokenIsRequired() async {
        let missing = await route(request(headers: ["host": "localhost"], body: pingBody))
        #expect(missing.status == 401)
        #expect(missing.headers["WWW-Authenticate"] == "Bearer")
        let wrong = await route(request(headers: merged(["authorization": "Bearer wrong"]), body: pingBody))
        #expect(wrong.status == 401)
        let otherScheme = await route(request(headers: merged(["authorization": "Basic secret"]), body: pingBody))
        #expect(otherScheme.status == 401)
        let lowercase = await route(request(headers: merged(["authorization": "bearer secret"]), body: pingBody))
        #expect(lowercase.status == 200)
    }

    @Test func onlyPostToMCPIsServed() async {
        #expect(await route(request(path: "/other", headers: goodHeaders, body: pingBody)).status == 404)
        let get = await route(request("GET", headers: goodHeaders))
        #expect(get.status == 405)
        #expect(get.headers["Allow"] == "POST")
        #expect(get.body == nil)
        let query = await route(request(path: "/mcp?x=1", headers: goodHeaders, body: pingBody))
        #expect(query.status == 200)
        #expect(query.contentType == "application/json")
    }

    @Test func notificationsAre202WithNoBody() async {
        let response = await route(request(headers: goodHeaders, body: notificationBody))
        #expect(response.status == 202)
        #expect(response.body == nil)
    }

    @Test func emptyBodyIsAParseError() async throws {
        let response = await route(request(headers: goodHeaders))
        #expect(response.status == 200)
        let reply = try JSONDecoder().decode(MCPValue.self, from: try #require(response.body))
        #expect(reply["error"]?["code"]?.intValue == -32700)
    }

    @Test func hostChecks() {
        #expect(MCPHTTPServer.isLocal(host: "[::1]:9"))
        #expect(MCPHTTPServer.isLocal(host: "LOCALHOST:1"))
        #expect(MCPHTTPServer.isLocal(host: "127.0.0.1"))
        #expect(MCPHTTPServer.isLocal(host: "[::1]"))
        #expect(!MCPHTTPServer.isLocal(host: "[::1].evil.com"))
        #expect(!MCPHTTPServer.isLocal(host: "[::1"))
        #expect(!MCPHTTPServer.isLocal(host: "localhost.evil.com:80"))
        #expect(!MCPHTTPServer.isLocal(host: "127.0.0.1.evil.com"))
        #expect(!MCPHTTPServer.isLocal(host: "evil.example"))
        #expect(!MCPHTTPServer.isLocal(host: nil))
        #expect(MCPHTTPServer.isLocalOrigin("http://127.0.0.1:8080"))
        #expect(!MCPHTTPServer.isLocalOrigin("http://localhost.evil.example"))
        #expect(!MCPHTTPServer.isLocalOrigin("null"))
    }

    @Test(arguments: [
        "::1", "[::1]", "[::1]:8080", "localhost", "LOCALHOST:1", "localhost:47821",
        "127.0.0.1", "127.0.0.1:47821"
    ])
    func localHostFormsAreAccepted(host: String) {
        #expect(MCPHTTPServer.isLocal(host: host))
    }

    @Test(arguments: [
        "::1:8080", "::2", "::", ":::1", "::1::", "[::1", "[::1]x", "[::1].evil.com", "[::2]",
        "evil.com", "evil.com:80", "127.0.0.2", "127.0.0.1.evil.com", "", ":", ":80"
    ])
    func foreignHostFormsAreRejected(host: String) {
        #expect(!MCPHTTPServer.isLocal(host: host))
    }

    @Test func bareIPv6LoopbackHostIsServed() async throws {
        let response = await route(request(headers: merged(["host": "::1"]), body: pingBody))
        #expect(response.status == 200)
        let reply = try JSONDecoder().decode(MCPValue.self, from: try #require(response.body))
        #expect(reply["result"] == .object([:]))
        let ambiguous = await route(request(headers: merged(["host": "::1:8080"]), body: pingBody))
        #expect(ambiguous.status == 403)
    }

    @Test func tokenCompare() {
        #expect(MCPHTTPServer.constantTimeEqual("abc", "abc"))
        #expect(!MCPHTTPServer.constantTimeEqual("abc", "abd"))
        #expect(!MCPHTTPServer.constantTimeEqual("abc", "abcd"))
        #expect(!MCPHTTPServer.constantTimeEqual("abcd", "abc"))
        #expect(!MCPHTTPServer.constantTimeEqual("a", ""))
        #expect(MCPHTTPServer.constantTimeEqual("", ""))
    }
}

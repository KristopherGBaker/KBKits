import Foundation
import Testing
@testable import KBMCPServer

@Suite struct LoopbackTests {
    let nonce = UUID().uuidString
    var token: String { "tok-\(nonce)" }

    /// Starts a server on an ephemeral port and returns it with the bound port.
    private func running(
        timeout: Duration = MCPHTTPServer.defaultConnectionTimeout
    ) async throws -> (MCPHTTPServer, UInt16) {
        let server = MCPHTTPServer(handler: makeHandler(nonce: nonce), token: token, connectionTimeout: timeout)
        let state = await server.start(port: 0)
        guard case .running(let port) = state else {
            server.stop()
            throw MCPToolError("server did not start: \(state)")
        }
        #expect(port != 0)
        return (server, port)
    }

    @Test func servesInitializeListAndCallOverRealHTTP() async throws {
        let (server, port) = try await running()
        defer { server.stop() }

        let initialize = try await post(port: port, token: token, body: try request("initialize"))
        #expect(initialize.status == 200)
        let initReply = try JSONDecoder().decode(MCPValue.self, from: initialize.data)
        #expect(initReply["result"]?["protocolVersion"]?.stringValue == "2025-06-18")

        let list = try await post(port: port, token: token, body: try request("tools/list", id: 2))
        #expect(list.status == 200)
        let tools = try JSONDecoder().decode(MCPValue.self, from: list.data)["result"]?["tools"]?.arrayValue
        #expect(tools?.compactMap { $0["name"]?.stringValue } == ["echo"])

        let msg = UUID().uuidString
        let call = try await post(
            port: port,
            token: token,
            body: try request("tools/call", ["name": "echo", "arguments": ["msg": .string(msg)]], id: 3)
        )
        #expect(call.status == 200)
        #expect(toolText(try JSONDecoder().decode(MCPValue.self, from: call.data)).text == "\(nonce):\(msg)")
    }

    @Test func rejectsBadTokensAndAnswersNotificationsAndGet() async throws {
        let (server, port) = try await running()
        defer { server.stop() }
        #expect(try await post(port: port, token: nil, body: pingBody).status == 401)
        #expect(try await post(port: port, token: "wrong", body: pingBody).status == 401)
        let note = try await post(port: port, token: token, body: notificationBody)
        #expect(note.status == 202 && note.data.isEmpty)
        let get = try await post(port: port, token: token, body: "", method: "GET")
        #expect(get.status == 405)
        #expect(get.response.value(forHTTPHeaderField: "Allow") == "POST")
    }

    @Test func oversizedBodyIsRefusedBeforeItIsSent() async throws {
        let (server, port) = try await running()
        defer { server.stop() }
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\n"
            + "Content-Length: 8388609\r\n\r\n"
        let reply = try await rawExchange(port: port, payload: Data(head.utf8))
        #expect(reply.text.hasPrefix("HTTP/1.1 413"))
    }

    @Test func responseIsOneExchangeWithExactHeadersThenEOF() async throws {
        let (server, port) = try await running()
        defer { server.stop() }
        let reply = try await rawExchange(port: port, payload: rawRequest(token: token, body: pingBody))
        #expect(reply.text.hasPrefix("HTTP/1.1 200"))
        let headers = reply.headers
        #expect(headers["content-length"] == String(reply.body.count))
        #expect(!reply.body.isEmpty)
        #expect(headers["content-type"] == "application/json")
        #expect(headers["cache-control"] == "no-store")
        #expect(headers["connection"] == "close")
        #expect(reply.sawEOF)
        #expect(reply.elapsed < .seconds(3))
    }

    @Test func stopRefusesNewConnections() async throws {
        let (server, port) = try await running()
        #expect(try await post(port: port, token: token, body: pingBody).status == 200)
        server.stop()
        #expect(await refusesConnections(port: port, within: .seconds(2)))
    }

    @Test func secondServerOnABoundPortFails() async throws {
        let (server, port) = try await running()
        defer { server.stop() }
        let rival = MCPHTTPServer(handler: makeHandler(nonce: nonce), token: token)
        let clash = await rival.start(port: port)
        defer { rival.stop() }
        guard case .failed(let text) = clash else {
            Issue.record("expected a port clash, got \(clash)")
            return
        }
        #expect(text.contains("Port \(port) is already in use."))
        #expect(try await post(port: port, token: token, body: pingBody).status == 200)
    }

    @Test func stalledConnectionsTimeOut() async throws {
        #expect(MCPHTTPServer.defaultConnectionTimeout == .seconds(30))
        let (server, port) = try await running(timeout: .milliseconds(300))
        defer { server.stop() }
        let stalled = try await rawExchange(port: port, payload: Data("POST /mcp HTTP/1.1\r\nHost: loc".utf8))
        #expect(stalled.closed)
        #expect(stalled.bytes.isEmpty)
        #expect(stalled.elapsed >= .milliseconds(200))
        #expect(stalled.elapsed < .seconds(3))
        let complete = try await rawExchange(port: port, payload: rawRequest(token: token, body: pingBody))
        #expect(complete.text.hasPrefix("HTTP/1.1 200"))
    }
}

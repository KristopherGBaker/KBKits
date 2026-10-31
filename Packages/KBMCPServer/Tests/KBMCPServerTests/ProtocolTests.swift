import Foundation
import Testing
@testable import KBMCPServer

@Suite struct ProtocolTests {
    let nonce = UUID().uuidString

    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    // MARK: - initialize, ping, tools/list

    @Test func supportedVersionsAreNewestFirst() {
        #expect(MCPRequestHandler.supportedProtocolVersions == ["2025-06-18", "2025-03-26", "2024-11-05"])
    }

    @Test func initializeEchoesASupportedVersionAndTheCallersIdentity() async throws {
        let handler = makeHandler(nonce: nonce)
        let known = try await rpc(handler, try request("initialize", ["protocolVersion": "2025-03-26"]))
        let result = try #require(known["result"])
        #expect(result["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(result["capabilities"]?["tools"]?["listChanged"] == .bool(false))
        #expect(result["serverInfo"]?["name"]?.stringValue == "srv-\(nonce)")
        #expect(result["serverInfo"]?["version"]?.stringValue == "v-\(nonce)")
        #expect(result["instructions"]?.stringValue == "ins-\(nonce)")
    }

    @Test func initializeFallsBackToTheNewestVersion() async throws {
        let handler = makeHandler(nonce: nonce)
        let unknown = try await rpc(handler, try request("initialize", ["protocolVersion": "1999-01-01"]))
        #expect(unknown["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        let missing = try await rpc(handler, try request("initialize"))
        #expect(missing["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
    }

    @Test func pingReturnsAnEmptyObject() async throws {
        let reply = try await rpc(makeHandler(nonce: nonce), pingBody)
        #expect(reply["result"] == .object([:]))
        #expect(reply["error"] == nil)
    }

    @Test func toolsListKeepsRegistrationOrderAndAnnotations() async throws {
        let handler = makeHandler(nonce: nonce, tools: [
            echoTool(nonce: nonce, name: "zeta_read", readOnly: true),
            echoTool(nonce: nonce, name: "alpha_delete", destructive: true)
        ])
        let tools = try #require(try await rpc(handler, try request("tools/list"))["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == ["zeta_read", "alpha_delete"])
        #expect(tools[0]["title"]?.stringValue == "Echo")
        #expect(tools[0]["inputSchema"]?["type"]?.stringValue == "object")
        #expect(tools[0]["annotations"] == [
            "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false
        ])
        #expect(tools[1]["annotations"] == [
            "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false
        ])
    }

    // MARK: - tools/call

    @Test func stringResultsComeBackVerbatim() async throws {
        let msg = UUID().uuidString
        let reply = try await rpc(
            makeHandler(nonce: nonce),
            try request("tools/call", ["name": "echo", "arguments": ["msg": .string(msg)]])
        )
        let (isError, text) = toolText(reply)
        #expect(isError == false)
        #expect(text == "\(nonce):\(msg)")
        #expect(reply["result"]?["content"]?.arrayValue?.first?["type"]?.stringValue == "text")
    }

    @Test func structuredResultsArePrettySortedJSONText() async throws {
        let tool = MCPTool(name: "obj", title: "O", description: "d", inputSchema: [:]) { _ in
            ["b": 1, "a": "x/y"]
        }
        let reply = try await rpc(makeHandler(nonce: nonce, tools: [tool]), try request("tools/call", ["name": "obj"]))
        let text = try #require(toolText(reply).text)
        #expect(try JSONDecoder().decode(MCPValue.self, from: Data(text.utf8)) == ["b": 1, "a": "x/y"])
        let aIndex = try #require(text.range(of: "\"a\""))
        let bIndex = try #require(text.range(of: "\"b\""))
        #expect(aIndex.lowerBound < bIndex.lowerBound)
        #expect(text.contains("\n"))
        #expect(text.contains("x/y"))
        #expect(text.contains("1") && !text.contains("1.0"))
    }

    @Test func duplicateNamesDispatchToTheFirstHandler() async throws {
        let second = MCPTool(name: "echo", title: "Second", description: "d", inputSchema: [:]) { _ in
            .string("second-\(UUID().uuidString)")
        }
        let handler = makeHandler(nonce: nonce, tools: [echoTool(nonce: nonce), second])
        let msg = UUID().uuidString
        let call = try request("tools/call", ["name": "echo", "arguments": ["msg": .string(msg)]])
        #expect(toolText(try await rpc(handler, call)).text == "\(nonce):\(msg)")
    }

    @Test func toolErrorsAreResultsNotProtocolErrors() async throws {
        let handler = makeHandler(nonce: nonce, tools: [
            MCPTool(name: "typed", title: "T", description: "d", inputSchema: [:]) { _ in
                throw MCPToolError("bad id")
            },
            MCPTool(name: "other", title: "O", description: "d", inputSchema: [:]) { _ in throw Boom() }
        ])
        let typed = try await rpc(handler, try request("tools/call", ["name": "typed"]))
        #expect(toolText(typed).isError == true && toolText(typed).text == "bad id")
        #expect(typed["error"] == nil)
        let other = try await rpc(handler, try request("tools/call", ["name": "other"]))
        #expect(toolText(other).isError == true && toolText(other).text == "Tool failed: boom")
        #expect(other["error"] == nil)
    }

    // MARK: - Protocol errors

    @Test func unparseableBodiesAndEmptyBatchesAreErrors() async throws {
        let handler = makeHandler(nonce: nonce)
        let parse = try await rpc(handler, "not json")
        #expect(parse["error"]?["code"]?.intValue == -32700)
        #expect(parse["error"]?["message"]?.stringValue == "Parse error")
        #expect(parse["id"] == .null)
        let empty = try await rpc(handler, "[]")
        #expect(empty["error"]?["code"]?.intValue == -32600)
        #expect(empty["error"]?["message"]?.stringValue == "Empty batch")
        let invalid = try #require(try await rpc(handler, "[5]").arrayValue)
        #expect(invalid.count == 1)
        #expect(invalid.first?["error"]?["code"]?.intValue == -32600)
        #expect(invalid.first?["error"]?["message"]?.stringValue == "Invalid Request")
    }

    @Test func unknownMethodsAndToolsAreNamed() async throws {
        let handler = makeHandler(nonce: nonce)
        let method = try await rpc(handler, try request("resources/list"))
        #expect(method["error"]?["code"]?.intValue == -32601)
        #expect(method["error"]?["message"]?.stringValue == "Method not found: resources/list")
        let nope = try await rpc(handler, try request("tools/call", ["name": "nope"]))
        #expect(nope["error"]?["code"]?.intValue == -32602)
        #expect(nope["error"]?["message"]?.stringValue == "Unknown tool: nope")
        let unnamed = try await rpc(handler, try request("tools/call", [:]))
        #expect(unnamed["error"]?["code"]?.intValue == -32602)
        #expect(unnamed["error"]?["message"]?.stringValue == "Unknown tool: (none)")
    }

    @Test func idsEchoExactly() async throws {
        let handler = makeHandler(nonce: nonce)
        let numeric = try #require(await handler.handle(body: Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8)))
        #expect(try utf8(numeric).contains(#""id":7"#))
        let string = try await rpc(handler, #"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)
        #expect(string["id"] == .string("a"))
    }

    // MARK: - Notifications and batches

    @Test func notificationsAndResponsesGetNoReply() async {
        let handler = makeHandler(nonce: nonce)
        #expect(await handler.handle(body: Data(notificationBody.utf8)) == nil)
        #expect(await handler.handle(body: Data(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#.utf8)) == nil)
        #expect(await handler.handle(body: Data(#"{"jsonrpc":"2.0","id":3,"result":{}}"#.utf8)) == nil)
    }

    @Test func batchesAnswerOnlyRequestsInOrder() async throws {
        let handler = makeHandler(nonce: nonce)
        let batch = #"[{"jsonrpc":"2.0","id":1,"method":"ping"},"#
            + #"{"jsonrpc":"2.0","method":"notifications/initialized"},"#
            + #"{"jsonrpc":"2.0","id":2,"method":"nope/nope"}]"#
        let replies = try #require(try await rpc(handler, batch).arrayValue)
        #expect(replies.count == 2)
        #expect(replies.map { $0["id"] } == [.number(1), .number(2)])
        #expect(replies[0]["result"] == .object([:]))
        #expect(replies[1]["error"]?["code"]?.intValue == -32601)
        let allNotes = "[\(notificationBody),\(notificationBody)]"
        #expect(await handler.handle(body: Data(allNotes.utf8)) == nil)
    }
}

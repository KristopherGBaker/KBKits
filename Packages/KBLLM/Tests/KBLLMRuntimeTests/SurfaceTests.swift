import Foundation
import KBLLM
import KBLLMRuntime
import Testing

@Suite struct SurfaceTests {
    // MARK: Assertion 1 - Message ordered parts, text init, Codable round-trip.

    @Test func messageCarriesOrderedContentPartsAndRoundTrips() throws {
        // The one-line text init is a single `.text` part.
        #expect(Message(role: .user, text: "hi") == Message(role: .user, content: [.text("hi")]))

        let call = ToolCallRecord(id: "tc", name: "search", arguments: Data(#"{"q":"x"}"#.utf8))
        let result = ToolResult.success(toolName: "search", content: Data(#"{"r":1}"#.utf8))
        let message = Message(
            role: .assistant,
            content: [.text("t"), .toolCall(call), .toolResult(callID: "c1", result)]
        )
        #expect(message.content.count == 3)
        guard
            case .text = message.content[0],
            case .toolCall = message.content[1],
            case .toolResult(let callID, _) = message.content[2]
        else {
            Issue.record("content order not preserved")
            return
        }
        #expect(callID == "c1")

        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: encoded)
        #expect(decoded == message)
    }

    // MARK: Assertion 14(b) - runtime async-boundary types are Sendable.

    @Test func runtimeSurfaceIsSendable() {
        func requireSendable<Value: Sendable>(_ type: Value.Type) {}
        requireSendable(RunEvent.self)
        requireSendable(RunResult.self)
        requireSendable(AgentSession.self)
        let boxed: any Sendable = RunEvent.finished(.stop)
        #expect(boxed is RunEvent)
    }
}

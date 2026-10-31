import Foundation
import KBLLM
import KBLLMApple
import Testing

// `AppleModel` refuses, before any backend run, a request that needs a capability the
// backend does not report: structured output without guidedGeneration, tools without
// toolCalling, an image without vision. Each refusal is paired with the same request on a
// backend that DOES report the capability, so a gate that refused everything fails too.
@Suite struct CapabilityGatingAppleTests {
    private let schema = JSONSchema.object(
        properties: ["word": .string(description: "the gated word")],
        required: ["word"],
        description: "a gated card"
    )

    private var structuredRequest: ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: "card please")], responseSchema: schema)
    }

    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x11, 0x22, 0x33])

    private var imageRequest: ModelRequest {
        ModelRequest(messages: [Message(role: .user, content: [
            .text("What colour is this?"),
            .image(data: pngBytes, mimeType: "image/png")
        ])])
    }

    @Test func structuredOutputRefusedWithoutGuidedGeneration() async {
        let fake = FakeFoundationModelBackend(capabilities: [.vision], script: .snapshots([#"{"word":"neko"}"#]))
        let result = await collect(AppleModel(backend: fake), structuredRequest)
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(field == "responseSchema")
        #expect(reason.contains("guidedGeneration"))
        #expect(fake.inferenceCount == 0)
        #expect(result.events.isEmpty)
    }

    @Test func structuredOutputDispatchesWithGuidedGeneration() async {
        let fake = FakeFoundationModelBackend(
            capabilities: [.guidedGeneration],
            script: .snapshots([#"{"word":"neko"}"#])
        )
        let result = await collect(AppleModel(backend: fake), structuredRequest)
        #expect(result.error == nil)
        #expect(fake.inferenceCount == 1)
        #expect(result.content == #"{"word":"neko"}"#)
    }

    @Test func toolsRefusedWithoutToolCalling() async {
        let tool = ToolDefinition(
            name: "lookup",
            description: "looks a gated word up",
            parameters: .object(properties: [:], required: [], description: nil)
        )
        let request = ModelRequest(messages: [Message(role: .user, text: "look it up")], tools: [tool])
        let fake = FakeFoundationModelBackend(capabilities: [.guidedGeneration], script: .snapshots(["done"]))
        let result = await collect(AppleModel(backend: fake), request)
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(field == "tools")
        #expect(reason.contains("toolCalling"))
        #expect(fake.inferenceCount == 0)

        // The contrast: the same request on a backend that reports toolCalling dispatches.
        let capable = FakeFoundationModelBackend(capabilities: [.toolCalling], script: .snapshots(["done"]))
        let dispatched = await collect(AppleModel(backend: capable), request)
        #expect(dispatched.error == nil)
        #expect(capable.inferenceCount == 1)
    }

    @Test func imageReachesBackendWhenVisionReported() async throws {
        let fake = FakeFoundationModelBackend(
            capabilities: [.vision, .guidedGeneration],
            script: .snapshots(["It is red."])
        )
        let result = await collect(AppleModel(backend: fake), imageRequest)
        #expect(result.error == nil)
        #expect(fake.inferenceCount == 1)
        let received = try #require(fake.receivedRequests.first)
        let parts = received.messages.flatMap(\.content)
        #expect(parts.contains(.image(data: pngBytes, mimeType: "image/png")))
    }

    @Test func imageRefusedNamingVisionWhenAbsent() async {
        let fake = FakeFoundationModelBackend(
            capabilities: [.guidedGeneration, .toolCalling, .reasoning],
            script: .snapshots(["It is red."])
        )
        let result = await collect(AppleModel(backend: fake), imageRequest)
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(field == "content.image")
        #expect(reason.contains("vision"))
        #expect(reason.contains("macOS 27"))
        #expect(!reason.lowercased().contains("toolchain"))
        #expect(fake.inferenceCount == 0)
        #expect(result.events.isEmpty)
    }
}

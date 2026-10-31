import Foundation
import KBLLM
import Testing

// Compile-time reference tests: they name every adapter-facing type and every
// host-consumed seam, so a rename or a deletion of any of them breaks the build here
// rather than silently dropping the seam.
@Suite struct CompileReferenceTests {
    @Test func adapterFacingSurfaceIsReferenceable() {
        let request: ModelRequest = ModelRequest(messages: [Message(role: .user, text: "hi")])
        let event: ModelEvent = .completed(.stop)
        let response: ModelResponse = ModelResponse(content: "")
        let model: (any LanguageModel)? = nil
        #expect(request.messages.count == 1)
        #expect(event == .completed(.stop))
        #expect(response.content.isEmpty)
        #expect(model == nil)
    }

    @Test func hostConsumedSeamsAreReferenceable() {
        let transport: (any HTTPTransport)? = nil
        let credentials: (any CredentialStore)? = nil
        let logger: (any LogSink)? = nil
        let clock: (any ClockSource)? = nil
        let random: (any RandomSource)? = nil
        #expect(transport == nil)
        #expect(credentials == nil)
        #expect(logger == nil)
        #expect(clock == nil)
        #expect(random == nil)
    }
}

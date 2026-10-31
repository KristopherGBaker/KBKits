import Foundation
import KBLLM
import Testing
@testable import KBLLMApple

// Unit 9 (Apple leaf): the neutral sampling controls must reach the on-device seam as a
// FoundationModels `GenerationOptions`, on BOTH the plain and the schema-constrained response
// paths, and an unset knob must fabricate nothing. These tests drive `LiveFoundationModelBackend`
// with the recording `FoundationModelResponder` (reused from the structured suite), so the real
// construction site is observed with no on-device inference. FM-gated: they name the framework
// type, so they only compile where `FoundationModels` is importable.

#if canImport(FoundationModels)
import FoundationModels

@Suite struct GenerationOptionsAppleTests {
    // MARK: Assertion 8 - temperature + max tokens reach the seam on both response paths.

    @Test func liveBackendSuppliesGenerationOptionsToResponseOperation() async throws {
        let options = GenerationOptions(temperature: 0.3, maxOutputTokens: 4000)

        // (a) plain path: no schema, options reach the seam.
        let plainResponder = RecordingResponder(snapshots: ["hi"])
        let plainBackend = LiveFoundationModelBackend(responder: plainResponder)
        let plainRequest = ModelRequest(
            messages: [Message(role: .user, text: "hi")],
            options: options
        )
        for try await _ in plainBackend.run(plainRequest) {}
        let plainRecorded = try #require(plainResponder.recordedOptions)
        #expect(plainRecorded.temperature == 0.3)
        #expect(plainRecorded.maximumResponseTokens == 4000)

        // (b) schema-constrained path: the SAME options AND a non-nil schema both reach the
        // seam in one call, so an implementation that forwards options only when no schema is
        // present fails here.
        let schemaResponder = RecordingResponder(snapshots: [appleConformingDocument])
        let schemaBackend = LiveFoundationModelBackend(responder: schemaResponder)
        let schemaRequest = ModelRequest(
            messages: [Message(role: .user, text: "card")],
            responseSchema: appleStructuredSchema,
            options: options
        )
        for try await _ in schemaBackend.run(schemaRequest) {}
        let schemaRecorded = try #require(schemaResponder.recordedOptions)
        #expect(schemaRecorded.temperature == 0.3)
        #expect(schemaRecorded.maximumResponseTokens == 4000)
        #expect(schemaResponder.recordedSchema != nil)

        // (c) default options: nothing is fabricated.
        let defaultResponder = RecordingResponder(snapshots: ["hi"])
        let defaultBackend = LiveFoundationModelBackend(responder: defaultResponder)
        for try await _ in defaultBackend.run(ModelRequest(messages: [Message(role: .user, text: "hi")])) {}
        let defaultRecorded = try #require(defaultResponder.recordedOptions)
        #expect(defaultRecorded.temperature == nil)
        #expect(defaultRecorded.maximumResponseTokens == nil)
    }

    // MARK: Assertion 9 - top-p becomes nucleus sampling at the exact threshold; nil fabricates none.

    @Test func liveBackendForwardsTopPAsNucleusSampling() async throws {
        // topP maps to nucleus sampling at exactly 0.9.
        let nucleusResponder = RecordingResponder(snapshots: ["hi"])
        let nucleusBackend = LiveFoundationModelBackend(responder: nucleusResponder)
        let nucleusRequest = ModelRequest(
            messages: [Message(role: .user, text: "hi")],
            options: GenerationOptions(topP: 0.9)
        )
        for try await _ in nucleusBackend.run(nucleusRequest) {}
        let nucleusRecorded = try #require(nucleusResponder.recordedOptions)
        #expect(nucleusRecorded.sampling == .random(probabilityThreshold: 0.9))

        // A nil topP fabricates NO sampling mode.
        let plainResponder = RecordingResponder(snapshots: ["hi"])
        let plainBackend = LiveFoundationModelBackend(responder: plainResponder)
        for try await _ in plainBackend.run(ModelRequest(messages: [Message(role: .user, text: "hi")])) {}
        let plainRecorded = try #require(plainResponder.recordedOptions)
        #expect(plainRecorded.sampling == nil)
    }
}
#endif

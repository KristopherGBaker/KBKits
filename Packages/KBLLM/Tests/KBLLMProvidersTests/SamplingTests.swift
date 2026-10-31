import Foundation
import KBLLM
import Testing
@testable import KBLLMAnthropic

// Sampling hints against the Anthropic model table, offline: which of `temperature` and `top_p`
// reach the wire for each model. A model that removed sampling answers any value with a 400, and
// the 4.x models newer than 4.1 reject the two together, so the adapter drops what the model
// would refuse instead of failing the request.
@Suite struct SamplingTests {
    static let noSampling = [
        "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5",
        "claude-fable-5", "claude-fable-5-1", "claude-sonnet-5", "claude-sonnet-5-5", "claude-haiku-5-5"
    ]

    static let oneOfSampling = [
        "claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-4-5", "claude-sonnet-4-5-20250929", "claude-haiku-4-5"
    ]

    static let anySampling = [
        "claude-opus-4-1", "claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022", "qwen2.5-7b-instruct"
    ]

    private func body(_ model: String, _ options: GenerationOptions) async throws -> [String: Any] {
        let (adapter, transport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage), model: model)
        let request = ModelRequest(messages: [Message(role: .user, text: "hi")], options: options)
        // Never refused: a dropped hint changes the sampling, not whether the call goes out.
        #expect(await collect(adapter, request).error == nil)
        return try #require(requestBodies(transport).first)
    }

    @Test(arguments: noSampling)
    func modelsWithoutSamplingAreSentNeither(model: String) async throws {
        #expect(AnthropicModelProfile(model).sampling == .none)
        for options in [
            GenerationOptions(temperature: 0.3, maxOutputTokens: 900, topP: 0.9),
            GenerationOptions(temperature: 0.3),
            GenerationOptions(topP: 0.9)
        ] {
            let sent = try await body(model, options)
            #expect(sent["temperature"] == nil)
            #expect(sent["top_p"] == nil)
            // Only the sampling hints go: the output limit still reaches the wire.
            #expect(sent["max_tokens"] as? Int == options.maxOutputTokens ?? AnthropicModel.maxOutputTokensFallback)
        }
    }

    @Test(arguments: oneOfSampling)
    func newerFourXModelsAreSentAtMostOneTemperatureFirst(model: String) async throws {
        #expect(AnthropicModelProfile(model).sampling == .oneOf)
        let both = try await body(model, GenerationOptions(temperature: 0.3, topP: 0.9))
        #expect(both["temperature"] as? Double == 0.3)
        #expect(both["top_p"] == nil)

        let topPOnly = try await body(model, GenerationOptions(topP: 0.9))
        #expect(topPOnly["top_p"] as? Double == 0.9)
        #expect(topPOnly["temperature"] == nil)

        let temperatureOnly = try await body(model, GenerationOptions(temperature: 0.3))
        #expect(temperatureOnly["temperature"] as? Double == 0.3)
        #expect(temperatureOnly["top_p"] == nil)
    }

    @Test(arguments: anySampling)
    func olderAndUnplacedModelsAreSentBoth(model: String) async throws {
        #expect(AnthropicModelProfile(model).sampling == .any)
        let both = try await body(model, GenerationOptions(temperature: 0.3, topP: 0.9))
        #expect(both["temperature"] as? Double == 0.3)
        #expect(both["top_p"] as? Double == 0.9)
    }

    @Test(arguments: noSampling + oneOfSampling + anySampling)
    func unsetHintsAreNeverInvented(model: String) async throws {
        let sent = try await body(model, GenerationOptions())
        #expect(sent["temperature"] == nil)
        #expect(sent["top_p"] == nil)
    }
}

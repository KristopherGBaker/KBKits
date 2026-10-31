import Foundation
import KBLLM
import KBLLMOpenAI
import Testing
@testable import KBLLMAnthropic

// Greedy sampling on the HTTP adapters, offline: which sampling keys reach the wire for each
// Anthropic model generation and for OpenAI, that greedy wins over a temperature or top-p also
// set, and that leaving it unset changes no request body.
@Suite struct GreedySamplingTests {
    private func anthropicBody(_ model: String, _ options: GenerationOptions) async throws -> [String: Any] {
        let (adapter, transport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage), model: model)
        let request = ModelRequest(messages: [Message(role: .user, text: "hi")], options: options)
        // Never refused: a dropped hint changes the sampling, not whether the call goes out.
        #expect(await collect(adapter, request).error == nil)
        return try #require(requestBodies(transport).first)
    }

    private func openAIBody(_ options: GenerationOptions) async throws -> [String: Any] {
        let (adapter, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        let request = ModelRequest(messages: [Message(role: .user, text: "hi")], options: options)
        _ = await collect(adapter, request)
        return try #require(requestBodies(transport).first)
    }

    private static let greedyVariants = [
        GenerationOptions(sampling: .greedy),
        GenerationOptions(temperature: 0.8, sampling: .greedy),
        GenerationOptions(topP: 0.9, sampling: .greedy),
        GenerationOptions(temperature: 0.8, maxOutputTokens: 700, topP: 0.9, sampling: .greedy)
    ]

    // MARK: Anthropic

    @Test(arguments: SamplingTests.oneOfSampling + SamplingTests.anySampling)
    func anthropicSendsTemperatureZeroAloneWhereSamplingIsAccepted(model: String) async throws {
        #expect(AnthropicModelProfile(model).sampling != .none)
        for options in Self.greedyVariants {
            let sent = try await anthropicBody(model, options)
            #expect(sent["temperature"] as? Double == 0)
            #expect(sent["top_p"] == nil)
            #expect(sent["max_tokens"] as? Int == options.maxOutputTokens ?? AnthropicModel.maxOutputTokensFallback)
        }
    }

    @Test(arguments: SamplingTests.noSampling)
    func anthropicDropsGreedyWhereSamplingWasRemoved(model: String) async throws {
        #expect(AnthropicModelProfile(model).sampling == .none)
        for options in Self.greedyVariants {
            let sent = try await anthropicBody(model, options)
            #expect(sent["temperature"] == nil)
            #expect(sent["top_p"] == nil)
            #expect(sent["max_tokens"] as? Int == options.maxOutputTokens ?? AnthropicModel.maxOutputTokensFallback)
        }
    }

    // MARK: OpenAI

    @Test func openAISendsTemperatureZeroAndNoTopP() async throws {
        for options in Self.greedyVariants {
            let sent = try await openAIBody(options)
            #expect(sent["temperature"] as? Double == 0)
            #expect(sent["top_p"] == nil)
            #expect(sent["max_tokens"] as? Int == options.maxOutputTokens)
        }
    }

    // MARK: Unset is inert

    @Test func theDefaultIsUnset() {
        #expect(GenerationOptions().sampling == nil)
        #expect(GenerationOptions(temperature: 0.3, maxOutputTokens: 10, topP: 0.5).sampling == nil)
    }

    /// The same request with `sampling` left unset and spelled out as nil writes the same body
    /// (canonically: key order is not stable between two serializations of equal dictionaries),
    /// and the non-greedy knobs still reach the wire exactly as before. The byte-level pin
    /// against the pre-greedy bodies is `UnsetOptionsWireTests`.
    @Test(arguments: SamplingTests.noSampling + SamplingTests.oneOfSampling + SamplingTests.anySampling)
    func anUnsetStrategyLeavesTheAnthropicBodyUnchanged(model: String) async throws {
        let implicit = try await anthropicBody(model, GenerationOptions(temperature: 0.5, topP: 0.25))
        let explicit = try await anthropicBody(model, GenerationOptions(temperature: 0.5, topP: 0.25, sampling: nil))
        #expect(canonicalJSON(implicit) == canonicalJSON(explicit))
        let expected: Double? = AnthropicModelProfile(model).sampling == .none ? nil : 0.5
        #expect(implicit["temperature"] as? Double == expected)
    }

    @Test func anUnsetStrategyLeavesTheOpenAIBodyUnchanged() async throws {
        let options = GenerationOptions(temperature: 0.3, maxOutputTokens: 50, topP: 0.9)
        let sent = try await openAIBody(options)
        #expect(sent["temperature"] as? Double == 0.3)
        #expect(sent["top_p"] as? Double == 0.9)
        let bare = try await openAIBody(GenerationOptions())
        #expect(bare["temperature"] == nil)
        #expect(bare["top_p"] == nil)
    }
}

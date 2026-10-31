#if canImport(FoundationModels)
import Foundation
import KBLLM
import Testing
@testable import KBLLMApple

// The opt-in live check for string choices plus greedy sampling: with `KBLLM_LIVE_APPLE=1` it
// runs ONE real on-device inference through `AppleModel` and checks the answer is one of the
// choices. Without the variable the suite is disabled, so the default run touches nothing live.
// When the on-device model is not available (Apple Intelligence off, an ineligible device, or the
// model still downloading) the test is skipped, and the reason the framework gave is printed as
// an `APPLE-LIVE-CHOICES` line so the skip says why.

private let liveChoicesEnabled = ProcessInfo.processInfo.environment["KBLLM_LIVE_APPLE"] == "1"

/// Whether the on-device model can run here, printing the reason when it cannot. Read only
/// when the suite is enabled, so a default run never asks the framework.
private func onDeviceModelIsAvailable() -> Bool {
    switch LiveFoundationModelBackend().availability {
    case .available:
        return true
    case .unavailable(let reason):
        let line = "APPLE-LIVE-CHOICES skipped: the on-device model is unavailable (\(reason))\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        return false
    }
}

@Suite(.enabled(if: liveChoicesEnabled, "set KBLLM_LIVE_APPLE=1 to run on-device inference"))
struct LiveAppleChoicesTests {
    static let labels = ["personalClaim", "general", "instruction"]

    @Test(.enabled("the on-device model is unavailable on this Mac; see the APPLE-LIVE-CHOICES line") {
        onDeviceModelIsAvailable()
    })
    func choicesAndGreedyReturnOneOfTheValues() async throws {
        var request = ModelRequest(
            messages: [
                Message(role: .system, text: "Classify the user's sentence. personalClaim: a fact about the "
                    + "speaker. general: a fact about the world. instruction: a request to do something."),
                Message(role: .user, text: "I was born in Osaka.")
            ],
            responseSchema: .object(
                properties: ["label": .string(description: "the kind of sentence", choices: Self.labels)],
                required: ["label"],
                description: "a classification"
            )
        )
        request.options.sampling = .greedy
        let model = AppleModel(backend: LiveFoundationModelBackend())
        let response = try await model.complete(request)
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(response.content.utf8))
        let label = try #require(decoded["label"])
        FileHandle.standardOutput.write(Data("APPLE-LIVE-CHOICES label=\(label)\n".utf8))
        #expect(Self.labels.contains(label))
    }
}
#endif

import Foundation
import KBLLM
import KBLLMApple
import Testing

// A backend whose model does not report the vision capability (every macOS 26 model, and any
// 27 model without it) cannot carry an image, so `AppleModel` must REJECT an image-bearing
// request before any backend run rather than silently dropping the picture and answering
// about nothing. These tests drive `AppleModel` over the scripted `FakeFoundationModelBackend`
// with its default capabilities (no vision), proving the typed rejection, that zero inference
// is attempted, that no events escape, and that the reason names the missing capability.
@Suite struct ImageRejectionAppleTests {
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00, 0x42, 0x7F])

    private func imageRequest() -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, content: [
            .text("What colour is this?"),
            .image(data: pngBytes, mimeType: "image/png")
        ])])
    }

    // MARK: Assertion 9 - the image is rejected pre-dispatch, typed, with no inference.

    @Test func imageIsRejectedPreDispatchWithNoInference() async {
        let fake = FakeFoundationModelBackend(script: .snapshots(["The image is red."]))
        let result = await collect(AppleModel(backend: fake), imageRequest())
        guard case .invalidRequest(let field, _) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(field == "content.image")
        // The image was not silently dropped and the text run in its place: no inference ran,
        // and no event escaped.
        #expect(fake.inferenceCount == 0)
        #expect(result.events.isEmpty)
    }

    // MARK: Assertion 10 - the rejection reason names the missing vision capability.

    @Test func rejectionReasonNamesTheVisionCapability() async {
        let fake = FakeFoundationModelBackend(script: .snapshots(["The image is red."]))
        let result = await collect(AppleModel(backend: fake), imageRequest())
        guard case .invalidRequest(_, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        // The reason explains what would let it through: a vision-capable model, which needs
        // macOS 27. It is about the model's capability, not about how this repo is built.
        #expect(reason.contains("vision"))
        #expect(reason.contains("macOS 27"))
        #expect(!reason.lowercased().contains("toolchain"))
    }
}

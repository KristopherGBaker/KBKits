#if canImport(FoundationModels)
import Foundation
import KBLLM
import Testing
@testable import KBLLMApple

// On macOS 27 a request's `.image` parts reach the live responder as decoded images, in
// message order, alongside the prompt text; the real responder wraps each as an `Attachment`.
// Every test runs against BOTH live backends (on-device and Private Cloud Compute), because
// they share one decode path, and reads the recorded images' real dimensions and pixels, so
// an implementation that dropped, reordered or substituted an image fails here. Every test is
// macOS 27 only (Swift Testing takes the availability per test, not on the suite type).
@Suite struct ImageAttachmentAppleTests {
    private func imageMessage(_ caption: String, _ image: SolidPNG) -> Message {
        Message(role: .user, content: [.text(caption), .image(data: image.data, mimeType: "image/png")])
    }

    /// The fixtures are what they claim: each decodes to its own size, and they differ.
    private func checkFixtures() throws {
        let decoded = try LiveImageDecoding.decodeImages(in: ModelRequest(messages: [
            imageMessage("red", .red), imageMessage("blue", .blue)
        ]))
        try #require(decoded.count == 2)
        try #require(decoded[0].width == 2 && decoded[0].height == 3)
        try #require(decoded[1].width == 5 && decoded[1].height == 4)
        try #require(SolidPNG.red.data != SolidPNG.blue.data)
    }

    private func expectImage(
        _ image: DecodedImage,
        matches fixture: SolidPNG,
        _ label: String
    ) {
        #expect(image.width == fixture.width, "\(label): width")
        #expect(image.height == fixture.height, "\(label): height")
        #expect(topLeftRGB(of: image.cgImage) == fixture.rgb, "\(label): pixel (0,0)")
    }

    @available(macOS 27, iOS 27, *)
    @Test func twoDistinctImagesReachResponderInOrderOnBothBackends() async throws {
        try checkFixtures()
        let request = ModelRequest(messages: [
            imageMessage("caption-alpha", .red),
            imageMessage("caption-beta", .blue)
        ])
        let responder = ImageRecordingResponder()
        for (label, backend) in bothLiveBackends(responder: responder) {
            let before = responder.recordedCalls.count
            #expect(await drainRun(backend, request) == nil, "\(label)")
            let call = try #require(responder.recordedCalls.last)
            #expect(responder.recordedCalls.count == before + 1, "\(label)")
            try #require(call.images.count == 2, "\(label)")
            expectImage(call.images[0], matches: .red, "\(label) [0]")
            expectImage(call.images[1], matches: .blue, "\(label) [1]")
            let alpha = try #require(call.prompt.range(of: "caption-alpha"), "\(label)")
            let beta = try #require(call.prompt.range(of: "caption-beta"), "\(label)")
            #expect(alpha.lowerBound < beta.lowerBound, "\(label)")
        }
    }

    @available(macOS 27, iOS 27, *)
    @Test func reversedImagesArriveReversedOnBothBackends() async throws {
        try checkFixtures()
        let request = ModelRequest(messages: [
            imageMessage("caption-beta", .blue),
            imageMessage("caption-alpha", .red)
        ])
        let responder = ImageRecordingResponder()
        for (label, backend) in bothLiveBackends(responder: responder) {
            #expect(await drainRun(backend, request) == nil, "\(label)")
            let call = try #require(responder.recordedCalls.last)
            try #require(call.images.count == 2, "\(label)")
            expectImage(call.images[0], matches: .blue, "\(label) [0]")
            expectImage(call.images[1], matches: .red, "\(label) [1]")
        }
    }

    @available(macOS 27, iOS 27, *)
    @Test func textOnlyRequestHasNoImagesOnBothBackends() async throws {
        let request = ModelRequest(messages: [Message(role: .user, text: "plain-question-gamma")])
        let responder = ImageRecordingResponder()
        for (label, backend) in bothLiveBackends(responder: responder) {
            #expect(await drainRun(backend, request) == nil, "\(label)")
            let call = try #require(responder.recordedCalls.last)
            #expect(call.images.isEmpty, "\(label)")
            #expect(call.prompt == "plain-question-gamma", "\(label)")
        }
    }

    @available(macOS 27, iOS 27, *)
    @Test func undecodableImageRefusedBeforeResponder() async throws {
        let request = ModelRequest(messages: [Message(role: .user, content: [
            .text("what is this?"),
            .image(data: undecodableImageBytes, mimeType: "image/png")
        ])])
        let responder = ImageRecordingResponder()
        for (label, backend) in bothLiveBackends(responder: responder) {
            let error = await drainRun(backend, request)
            guard case .invalidRequest(let field, let reason) = error else {
                Issue.record("\(label): expected .invalidRequest, got \(String(describing: error))")
                continue
            }
            #expect(field == "content.image", "\(label)")
            #expect(reason.contains("decode"), "\(label)")
        }
        // Neither backend ever called the responder: the refusal came before any session.
        #expect(responder.recordedCalls.isEmpty)
    }
}
#endif

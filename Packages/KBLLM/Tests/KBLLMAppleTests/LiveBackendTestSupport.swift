#if canImport(FoundationModels)
import Foundation
import FoundationModels
import KBLLM
@testable import KBLLMApple
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

// Offline scaffolding for the live-layer suites (image attachments, error mapping): a
// responder that records the decoded images and prompt it receives, a responder that throws
// a scripted framework error, scripted metadata so a live backend can be driven through
// `AppleModel` whatever this machine's models report, and generated PNG fixtures. NOTHING
// here runs inference.

/// One call the recording responder received: the prompt text and the decoded images.
struct RecordedImageCall: Sendable {
    let prompt: String
    let images: [DecodedImage]
}

/// Records every call's prompt and decoded images, then answers one fixed snapshot.
final class ImageRecordingResponder: FoundationModelResponder, @unchecked Sendable {
    private let calls = Box<[RecordedImageCall]>([])

    var recordedCalls: [RecordedImageCall] { calls.get() }

    func streamResponse(
        to prompt: ResponderPrompt,
        instructions: String?,
        tools: [any FoundationModels.Tool],
        schema: GenerationSchema?,
        options: FoundationModels.GenerationOptions
    ) -> AsyncThrowingStream<String, any Error> {
        calls.mutate { $0.append(RecordedImageCall(prompt: prompt.text, images: prompt.images)) }
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }
}

/// Throws one scripted error from the response op, as the real session would mid-run.
final class ThrowingResponder: FoundationModelResponder, @unchecked Sendable {
    private let error: any Error

    init(_ error: any Error) {
        self.error = error
    }

    func streamResponse(
        to prompt: ResponderPrompt,
        instructions: String?,
        tools: [any FoundationModels.Tool],
        schema: GenerationSchema?,
        options: FoundationModels.GenerationOptions
    ) -> AsyncThrowingStream<String, any Error> {
        let error = self.error
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

extension LiveModelMetadata {
    /// Available, every capability, unmetered, unknown context size: lets a live backend reach
    /// its run path through `AppleModel` on any machine.
    static let scriptedAvailable = LiveModelMetadata(
        availability: { .available },
        capabilities: { [.vision, .guidedGeneration, .reasoning, .toolCalling] },
        quotaUsage: { nil },
        contextSize: { nil }
    )
}

/// Both live backends over the same injected responder, labelled for failure messages, so a
/// live-layer test proves the on-device and Private Cloud Compute paths behave identically.
@available(macOS 27, iOS 27, *)
func bothLiveBackends(
    responder: any FoundationModelResponder
) -> [(label: String, backend: any FoundationModelBackend)] {
    [
        ("onDevice", LiveFoundationModelBackend(responder: responder, metadata: .scriptedAvailable)),
        ("pcc", LivePrivateCloudComputeBackend(responder: responder, metadata: .scriptedAvailable))
    ]
}

/// Drain a backend's run directly (the live layer, below `AppleModel`), returning the typed
/// error if it threw.
func drainRun(_ backend: any FoundationModelBackend, _ request: ModelRequest) async -> KBLLMError? {
    do {
        for try await _ in backend.run(request) {}
        return nil
    } catch {
        return KBLLMError.from(error)
    }
}

/// A solid-colour image fixture, generated rather than checked in, so its exact size and pixel
/// value are visible in the test that uses it.
struct SolidPNG {
    let width: Int
    let height: Int
    let rgb: [UInt8]
    let data: Data

    static let red = SolidPNG(width: 2, height: 3, rgb: [255, 0, 0])
    static let blue = SolidPNG(width: 5, height: 4, rgb: [0, 0, 255])

    private init(width: Int, height: Int, rgb: [UInt8]) {
        self.width = width
        self.height = height
        self.rgb = rgb
        self.data = Self.encode(width: width, height: height, rgb: rgb) ?? Data()
    }

    private static func encode(width: Int, height: Int, rgb: [UInt8]) -> Data? {
        var pixels: [UInt8] = []
        for _ in 0..<(width * height) { pixels += rgb + [255] }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// The RGB value of pixel (0,0), rendered into an sRGB buffer so the check reads real pixels.
func topLeftRGB(of image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { raw in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: raw.baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return Array(buffer[0..<3])
}

/// The same 12 bytes the rejection suite uses: a PNG signature followed by garbage, which no
/// decoder can turn into an image.
let undecodableImageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00, 0x42, 0x7F])
#endif

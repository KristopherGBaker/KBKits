#if canImport(FoundationModels)
import Foundation
import FoundationModels
import KBLLM
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

// What the two live backends (on-device and Private Cloud Compute) share beyond the run path:
// image decoding, the FoundationModels-to-`KBLLMError` mapping, the neutral capability mapping
// and the injectable metadata. Compiled in only where `canImport(FoundationModels)` holds; the
// image modules are guarded in-file too, so the portability tripwire sees every import gated.

/// One decoded `.image` part, CGImage-backed, so the real responder can wrap it as an
/// `Attachment` and a test recorder can read its dimensions and pixels. `@unchecked Sendable`
/// because a `CGImage` is immutable once created.
struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage

    var width: Int { cgImage.width }
    var height: Int { cgImage.height }
}

/// What the responder is asked to answer: the rendered prompt text and the request's decoded
/// images, in message order, which the real responder attaches after the text.
struct ResponderPrompt: Sendable {
    let text: String
    let images: [DecodedImage]
}

/// Decodes a request's image parts. Shared by both live backends so there is one decode path.
enum LiveImageDecoding {
    /// Every `.image` part across the messages, decoded, in message order. Throws
    /// `.invalidRequest(field: "content.image")` naming the decode failure for the first part
    /// that is not a readable image, so a broken picture is refused rather than dropped.
    static func decodeImages(in request: ModelRequest) throws -> [DecodedImage] {
        var images: [DecodedImage] = []
        for message in request.messages {
            for part in message.content {
                guard case .image(let data, let mimeType) = part else { continue }
                guard let image = decode(data) else {
                    throw KBLLMError.invalidRequest(
                        field: "content.image",
                        reason: "could not decode the \(data.count)-byte \(mimeType) image part"
                    )
                }
                images.append(image)
            }
        }
        return images
    }

    private static func decode(_ data: Data) -> DecodedImage? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return DecodedImage(cgImage: image)
        #else
        return nil
        #endif
    }
}

/// Maps the framework's errors onto the existing `KBLLMError` cases before they reach
/// `AppleModel`. No new case: an added case breaks every consumer's exhaustive switch, and each
/// error fits one already. A network failure is `.transport`; a used-up quota or a service
/// outage is "cannot run here now", `.unavailable`; an over-size context is a wrong request,
/// `.invalidRequest`. Anything else passes through, and `AppleModel` makes it `.upstream`.
enum LiveErrorMapping {
    /// The endpoint named in a `.transport` error. Private Cloud Compute has no URL the caller
    /// configures, so the service's name stands in for one.
    static let privateCloudComputeEndpoint = "Private Cloud Compute"

    static func map(_ error: any Error) -> any Error {
        if error is KBLLMError { return error }
        if #available(macOS 27, iOS 27, *) {
            if let pcc = error as? PrivateCloudComputeLanguageModel.Error {
                return map(pcc)
            }
            if let model = error as? LanguageModelError, case .contextSizeExceeded(let exceeded) = model {
                return KBLLMError.invalidRequest(
                    field: "messages",
                    reason: "the request is \(exceeded.tokenCount) tokens, over the model's contextSize of "
                        + "\(exceeded.contextSize) tokens (contextSizeExceeded); trim the history with "
                        + "trimmedToFit(maxTokens:) and resend"
                )
            }
        }
        return error
    }

    @available(macOS 27, iOS 27, *)
    private static func map(_ error: PrivateCloudComputeLanguageModel.Error) -> KBLLMError {
        switch error {
        case .networkFailure(let failure):
            return .transport(url: privateCloudComputeEndpoint, underlying: failure.debugDescription)
        case .quotaLimitReached(let reached):
            let reset = reached.resetDate.map { "; it resets at \($0.formatted(.iso8601))" } ?? ""
            return .unavailable(
                reason: "Private Cloud Compute usage quota reached (quotaLimitReached)\(reset): "
                    + reached.debugDescription
            )
        case .serviceUnavailable(let unavailable):
            return .unavailable(
                reason: "Private Cloud Compute service unavailable (serviceUnavailable): "
                    + unavailable.debugDescription
            )
        @unknown default:
            return .upstream(cause: String(describing: error))
        }
    }
}

/// A live backend's metadata, injectable so a test can drive a live backend (and its real run
/// path) through `AppleModel` whatever this machine's model reports. `nil` on a backend means
/// "ask the real model".
struct LiveModelMetadata: Sendable {
    var availability: @Sendable () -> FoundationModelAvailability
    var capabilities: @Sendable () -> Set<FoundationModelCapability>
    var quotaUsage: @Sendable () -> FoundationModelQuotaUsage?
    var contextSize: @Sendable () async throws -> Int?
}

@available(macOS 27, iOS 27, *)
extension FoundationModelCapability {
    /// The neutral set for a model's `LanguageModelCapabilities`. Internal so a test can check
    /// a live backend's report against the live model's own capabilities.
    static func set(from capabilities: LanguageModelCapabilities) -> Set<FoundationModelCapability> {
        let pairs: [(LanguageModelCapabilities.Capability, FoundationModelCapability)] = [
            (.vision, .vision),
            (.guidedGeneration, .guidedGeneration),
            (.reasoning, .reasoning),
            (.toolCalling, .toolCalling)
        ]
        return Set(pairs.filter { capabilities.contains($0.0) }.map(\.1))
    }
}
#endif

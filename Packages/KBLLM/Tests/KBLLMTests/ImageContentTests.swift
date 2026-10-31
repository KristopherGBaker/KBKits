import Foundation
import KBLLM
import Testing

// The core-surface tests for unit 8's multimodal input: the neutral `MessageContent.image`
// case carries inline bytes plus a MIME type, survives an ordered Codable round trip alongside
// text and a tool call, and its bytes and MIME participate in `Equatable`. Everything here is
// pure value work, so it needs no transport, no clock, and no backend.
@Suite struct ImageContentTests {
    /// A distinctive multi-byte `Data` opening with the PNG signature (89 50 4E 47). It is
    /// non-empty and deliberately NOT valid UTF-8 (the 0x89 and 0xFF bytes), so a translation
    /// that round-trips it as a string rather than base64 would corrupt it observably.
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00, 0x42, 0x7F])

    private var toolCallRecord: ToolCallRecord {
        ToolCallRecord(id: "call_1", name: "get_weather", arguments: Data(#"{"city":"Paris"}"#.utf8))
    }

    // MARK: Assertion 1 - the image case carries bytes and MIME and nothing gets lost.

    @Test func imageCaseCarriesBytesAndMIME() {
        let content = MessageContent.image(data: pngBytes, mimeType: "image/png")
        guard case .image(let data, let mimeType) = content else {
            Issue.record("expected .image, got \(content)")
            return
        }
        #expect(data == pngBytes)
        #expect(mimeType == "image/png")
    }

    // MARK: Assertion 3 - a mixed ordered-content turn survives a Codable round trip.

    @Test func mixedOrderedContentSurvivesCodableRoundTrip() throws {
        let original = Message(role: .user, content: [
            .text("q"),
            .image(data: pngBytes, mimeType: "image/png"),
            .toolCall(toolCallRecord)
        ])
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.self, from: encoded)
        // Whole-value equality proves the bytes, the MIME, and the element ORDER all survive.
        #expect(decoded == original)
        // And the image bytes specifically come back byte-identical, not mangled through coding.
        guard case .image(let data, let mimeType) = decoded.content[1] else {
            Issue.record("expected the image to stay the second part, got \(decoded.content)")
            return
        }
        #expect(data == pngBytes)
        #expect(mimeType == "image/png")
    }

    // MARK: Assertion 4 - Equatable discriminates the image payload and its MIME.

    @Test func equatableDiscriminatesImagePayloadAndMIME() {
        let base = Message(role: .user, content: [.image(data: pngBytes, mimeType: "image/png")])
        let identical = Message(role: .user, content: [.image(data: pngBytes, mimeType: "image/png")])
        let differentBytes = Message(
            role: .user,
            content: [.image(data: pngBytes + Data([0x01]), mimeType: "image/png")]
        )
        let differentMIME = Message(role: .user, content: [.image(data: pngBytes, mimeType: "image/jpeg")])
        #expect(base == identical)
        #expect(base != differentBytes)
        #expect(base != differentMIME)
    }
}

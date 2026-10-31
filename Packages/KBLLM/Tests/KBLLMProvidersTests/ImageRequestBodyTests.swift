import Foundation
import KBLLM
import Testing

// Wire-translation tests for unit 8's multimodal input. Each drives a real adapter over the
// offline `RecordingTransport`, then parses the RECORDED request body with `JSONSerialization`
// and navigates by index (order) and base64-decodes the payload back to the original `Data`
// (fidelity), so no assertion string-matches ordering. The replayed transcript only keeps the
// stream finite; every assertion is on the body the adapter built, never on the reply.
@Suite struct ImageRequestBodyTests {
    /// A distinctive multi-byte `Data` opening with the PNG signature (89 50 4E 47), non-empty
    /// and NOT valid UTF-8, so a base64 that silently became a UTF-8 string would corrupt it.
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00, 0x42, 0x7F])
    /// A second, structurally different image so a MIME hardcoded to one value is caught.
    private let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])

    private func bodyObject(_ transport: RecordingTransport) -> [String: Any] {
        let data = transport.requests.get().first?.body ?? Data()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// The `content` array of the LAST wire message, which is where a user turn lands for both
    /// adapters. Returning the raw array keeps the index navigation in the test, where order is
    /// the thing under assertion.
    private func lastMessageContent(_ transport: RecordingTransport) -> [[String: Any]] {
        let messages = (bodyObject(transport)["messages"] as? [[String: Any]]) ?? []
        return (messages.last?["content"] as? [[String: Any]]) ?? []
    }

    private func imageRequest(_ image: MessageContent, prompt: String = "What colour is this?") -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, content: [.text(prompt), image])])
    }

    // MARK: Assertion 5 - OpenAI renders an image as an ordered data-URI part.

    @Test func openAIRendersImageAsOrderedDataURIPart() async {
        let (oai, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(oai, imageRequest(.image(data: pngBytes, mimeType: "image/png")))
        let content = lastMessageContent(transport)
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "What colour is this?")
        #expect(content[1]["type"] as? String == "image_url")
        let url = ((content[1]["image_url"] as? [String: Any])?["url"] as? String) ?? ""
        #expect(url.hasPrefix("data:image/png;base64,"))
        #expect(decodedDataURI(url) == pngBytes)
    }

    // MARK: Assertion 6 - reversed neutral order yields reversed OpenAI wire order.

    @Test func openAIPreservesReversedNeutralOrder() async {
        let (oai, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        let request = ModelRequest(messages: [Message(role: .user, content: [
            .image(data: pngBytes, mimeType: "image/png"),
            .text("and this?")
        ])])
        _ = await collect(oai, request)
        let content = lastMessageContent(transport)
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "image_url")
        #expect(content[1]["type"] as? String == "text")
    }

    // MARK: Assertion 7 - Anthropic renders an image with a separate media_type block.

    @Test func anthropicRendersImageWithSeparateMediaType() async {
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anth, imageRequest(.image(data: pngBytes, mimeType: "image/png")))
        let content = lastMessageContent(transport)
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "What colour is this?")
        #expect(content[1]["type"] as? String == "image")
        let source = (content[1]["source"] as? [String: Any]) ?? [:]
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        let base64 = (source["data"] as? String) ?? ""
        #expect(Data(base64Encoded: base64) == pngBytes)
    }

    // MARK: Assertion 8 - the supplied MIME rides exactly, not a constant.

    @Test func exactSuppliedMIMENotAConstant() async {
        // The JPEG fixture yields image/jpeg on both wires.
        let (oaiJpeg, oaiJpegTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(oaiJpeg, imageRequest(.image(data: jpegBytes, mimeType: "image/jpeg")))
        let oaiURL = ((lastMessageContent(oaiJpegTransport)[1]["image_url"] as? [String: Any])?["url"] as? String) ?? ""
        #expect(oaiURL.hasPrefix("data:image/jpeg;base64,"))
        #expect(decodedDataURI(oaiURL) == jpegBytes)

        let (anthJpeg, anthJpegTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anthJpeg, imageRequest(.image(data: jpegBytes, mimeType: "image/jpeg")))
        let anthJpegSource = (lastMessageContent(anthJpegTransport)[1]["source"] as? [String: Any]) ?? [:]
        #expect(anthJpegSource["media_type"] as? String == "image/jpeg")

        // The PNG fixture yields image/png on both wires: proves the MIME follows the input.
        let (oaiPng, oaiPngTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(oaiPng, imageRequest(.image(data: pngBytes, mimeType: "image/png")))
        let oaiPngImage = lastMessageContent(oaiPngTransport)[1]["image_url"] as? [String: Any]
        let oaiPngURL = (oaiPngImage?["url"] as? String) ?? ""
        #expect(oaiPngURL.hasPrefix("data:image/png;base64,"))

        let (anthPng, anthPngTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anthPng, imageRequest(.image(data: pngBytes, mimeType: "image/png")))
        let anthPngSource = (lastMessageContent(anthPngTransport)[1]["source"] as? [String: Any]) ?? [:]
        #expect(anthPngSource["media_type"] as? String == "image/png")
    }

    /// Strip a `data:<mime>;base64,` prefix and decode the payload back to `Data`, so a body
    /// assertion compares BYTES rather than a string, catching a mangled base64.
    private func decodedDataURI(_ url: String) -> Data? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let payload = String(url[url.index(after: comma)...])
        return Data(base64Encoded: payload)
    }
}

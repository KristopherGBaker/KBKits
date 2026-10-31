import Foundation
import KBLLM

// Transcripts in the shape the CURRENT Messages API streams, field for field: `message_start`
// carrying the model, `service_tier` and the `cache_creation` breakdown, `ping` frames between
// blocks, `content_block_stop` after every block, and `message_delta` closing with a stop reason
// and output usage. Built from dictionaries through `JSONSerialization`, so a JSON answer or a
// URL inside a delta is escaped exactly as the wire escapes it.
extension Fixtures {
    // MARK: Frame builders

    /// One `event:`-tagged frame whose `data` is `object` serialized, the event name taken from
    /// the object's own `type`, the way the API pairs them.
    static func event(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return frame(event: object["type"] as? String, data: String(bytes: data, encoding: .utf8) ?? "")
    }

    static func currentMessageStart(model: String, inputTokens: Int, container: [String: Any]? = nil) -> String {
        var message: [String: Any] = [
            "id": "msg_01XcurrentShape", "type": "message", "role": "assistant", "model": model,
            "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(),
            "usage": [
                "input_tokens": inputTokens, "output_tokens": 3,
                "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
                "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0],
                "service_tier": "standard"
            ]
        ]
        if let container { message["container"] = container }
        return event(["type": "message_start", "message": message])
    }

    static let ping = frame(event: "ping", data: #"{"type": "ping"}"#)

    static func blockStart(_ index: Int, _ block: [String: Any]) -> String {
        event(["type": "content_block_start", "index": index, "content_block": block])
    }

    static func delta(_ index: Int, _ delta: [String: Any]) -> String {
        event(["type": "content_block_delta", "index": index, "delta": delta])
    }

    static func stop(_ index: Int) -> String {
        event(["type": "content_block_stop", "index": index])
    }

    /// A whole text block: its start, one `text_delta` per piece, then its stop.
    static func textBlock(_ index: Int, _ pieces: [String], citations: [[String: Any]] = []) -> String {
        blockStart(index, ["type": "text", "text": ""])
            + citations.map { delta(index, ["type": "citations_delta", "citation": $0]) }.joined()
            + pieces.map { delta(index, ["type": "text_delta", "text": $0]) }.joined()
            + stop(index)
    }

    static func messageEnd(
        _ stopReason: String,
        outputTokens: Int,
        searches: Int? = nil,
        container: [String: Any]? = nil
    ) -> String {
        var usage: [String: Any] = ["output_tokens": outputTokens]
        if let searches { usage["server_tool_use"] = ["web_search_requests": searches, "web_fetch_requests": 0] }
        var delta: [String: Any] = ["stop_reason": stopReason, "stop_sequence": NSNull()]
        if let container { delta["container"] = container }
        return event(["type": "message_delta", "delta": delta, "usage": usage])
            + event(["type": "message_stop"])
    }

    // MARK: Structured outputs

    /// A learning plan answer, with an escaped quote, Japanese and an emoji, so a split inside a
    /// multi-byte character or an escape is exercised when it is streamed in pieces.
    static let learnPlanDocument =
        #"{"topic":"Swift concurrency","steps":[{"title":"Read the guide","resources":["#
        + #""https://www.swift.org/documentation/concurrency/"]},{"title":"Port one module","#
        + #""resources":[]},{"title":"Review the 東京 notes 🎌","resources":["a \"quoted\" note"]}]}"#

    /// `learnPlanDocument` cut into uneven pieces, as a model streams it.
    static func pieces(of document: String, sizes: [Int] = [7, 30, 3, 51, 12]) -> [String] {
        var rest = Substring(document)
        var pieces: [String] = []
        for size in sizes where !rest.isEmpty {
            pieces.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }

    /// A structured-outputs answer: the JSON arrives as ordinary text, here split across two
    /// text blocks, which the parser must join in order.
    static func structuredOutputAnswer(model: String, document: String = learnPlanDocument) -> [UInt8] {
        let parts = pieces(of: document)
        let half = parts.count / 2
        return bytes(
            currentMessageStart(model: model, inputTokens: 812)
                + textBlock(0, Array(parts[..<half])) + ping
                + textBlock(1, Array(parts[half...]))
                + messageEnd("end_turn", outputTokens: 96)
        )
    }

    /// A structured-outputs answer the API cut off at `max_tokens`: the document never closes.
    static func structuredOutputTruncated(model: String) -> [UInt8] {
        bytes(
            currentMessageStart(model: model, inputTokens: 812)
                + textBlock(0, [String(learnPlanDocument.prefix(60))])
                + messageEnd("max_tokens", outputTokens: 4096)
        )
    }

    /// The API failing after the stream opened: part of the answer, then an in-band
    /// `overloaded_error` event, and the connection closes with no `message_stop`.
    static func structuredOutputOverloaded(model: String) -> [UInt8] {
        bytes(
            currentMessageStart(model: model, inputTokens: 812)
                + blockStart(0, ["type": "text", "text": ""])
                + delta(0, ["type": "text_delta", "text": String(learnPlanDocument.prefix(40))])
                + event(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]])
        )
    }

    /// The legacy route answered the way an unforced model does: a remark in text, THEN the
    /// structured tool call, then `tool_use`.
    static func legacyRemarkThenTool(toolName: String, document: String) -> [UInt8] {
        bytes(
            currentMessageStart(model: "claude-3-5-sonnet-20241022", inputTokens: 300)
                + textBlock(0, ["Here is the ", "structured answer."])
                + blockStart(1, ["type": "tool_use", "id": "toolu_01", "name": toolName, "input": [:]])
                + pieces(of: document).map { delta(1, ["type": "input_json_delta", "partial_json": $0]) }.joined()
                + stop(1)
                + messageEnd("tool_use", outputTokens: 80)
        )
    }
}

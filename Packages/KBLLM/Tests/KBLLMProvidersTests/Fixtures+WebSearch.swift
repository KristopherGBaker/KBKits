import Foundation

// The server-side web search transcripts, in Anthropic's documented streaming shape:
// `server_tool_use` blocks whose query streams as `input_json_delta`, `web_search_tool_result`
// blocks that carry their whole `content` in the start frame, text blocks whose citations
// arrive as `citations_delta`, and `usage.server_tool_use.web_search_requests` on the closing
// `message_delta`. The encrypted values are deliberately full of `/`, `+` and `=`, the
// characters a careless re-serialization escapes or mangles, so an echo test that passes on
// them has proved a verbatim round trip.
extension Fixtures {
    // MARK: Encrypted fields

    static let encryptedSwiftRelease = "EqgfCioIARgBKkCm/+Zs9Q==/abc+def/ghi="
    static let encryptedWhatsNew = "Ep0CCioIARgB/QW+9xYzAbc/=="
    static let encryptedConcurrency = "Enc3/x+y=/Zz+0=="
    static let encryptedSwiftIndex = "Eo8BCioIAhgB/+idx/QQ=="
    static let encryptedConcurrencyIndex = "Eo9CCioIAhgB/+cc/RR=="
    static let encryptedKyoto = "EkKy/oto+Weather/Forecast==/+/"
    static let encryptedKyotoIndex = "EiKy/idx+0/=="

    // MARK: Frame builders

    private static func searchStart(index: Int, id: String) -> String {
        frame(
            event: "content_block_start",
            data: #"{"type":"content_block_start","index":\#(index),"content_block":"#
                + #"{"type":"server_tool_use","id":"\#(id)","name":"web_search","input":{}}}"#
        )
    }

    private static func inputDelta(index: Int, _ partialJSON: String) -> String {
        frame(
            event: "content_block_delta",
            data: #"{"type":"content_block_delta","index":\#(index),"delta":"#
                + #"{"type":"input_json_delta","partial_json":"\#(partialJSON)"}}"#
        )
    }

    private static func resultStart(index: Int, searchID: String, content: String) -> String {
        frame(
            event: "content_block_start",
            data: #"{"type":"content_block_start","index":\#(index),"content_block":"#
                + #"{"type":"web_search_tool_result","tool_use_id":"\#(searchID)","content":\#(content)}}"#
        )
    }

    private static func textStart(index: Int) -> String {
        frame(
            event: "content_block_start",
            data: #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#
        )
    }

    private static func textDelta(index: Int, _ text: String) -> String {
        frame(
            event: "content_block_delta",
            data: #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(text)"}}"#
        )
    }

    private static func citationDelta(index: Int, _ citation: String) -> String {
        frame(
            event: "content_block_delta",
            data: #"{"type":"content_block_delta","index":\#(index),"delta":"#
                + #"{"type":"citations_delta","citation":\#(citation)}}"#
        )
    }

    private static func blockStop(index: Int) -> String {
        frame(event: "content_block_stop", data: #"{"type":"content_block_stop","index":\#(index)}"#)
    }

    private static func messageStart(inputTokens: Int) -> String {
        frame(
            event: "message_start",
            data: #"{"type":"message_start","message":{"id":"msg_ws","role":"assistant","content":[],"#
                + #""usage":{"input_tokens":\#(inputTokens),"output_tokens":1}}}"#
        )
    }

    private static func messageEnd(stopReason: String, outputTokens: Int, searches: Int?) -> String {
        let serverToolUse = searches.map { #","server_tool_use":{"web_search_requests":\#($0)}"# } ?? ""
        return frame(
            event: "message_delta",
            data: #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)","stop_sequence":null},"#
                + #""usage":{"output_tokens":\#(outputTokens)\#(serverToolUse)}}"#
        )
            + frame(event: "message_stop", data: #"{"type":"message_stop"}"#)
    }

    // MARK: Two searches, results, citations and usage

    static let swiftReleaseResults =
        #"[{"type":"web_search_result","title":"Swift 6.2 Released","#
        + #""url":"https://swift.org/blog/swift-6.2-released/","#
        + #""encrypted_content":"\#(encryptedSwiftRelease)","page_age":"2 days ago"},"#
        + #"{"type":"web_search_result","title":"What's new in Swift","#
        + #""url":"https://developer.apple.com/swift/whats-new/","#
        + #""encrypted_content":"\#(encryptedWhatsNew)","page_age":null}]"#

    static let concurrencyResults =
        #"[{"type":"web_search_result","title":"Concurrency Guide","#
        + #""url":"https://www.swift.org/documentation/concurrency/","#
        + #""encrypted_content":"\#(encryptedConcurrency)","page_age":"1 week ago"}]"#

    static let swiftReleaseCitation =
        #"{"type":"web_search_result_location","cited_text":"Swift 6.2 is now available.","#
        + #""url":"https://swift.org/blog/swift-6.2-released/","title":"Swift 6.2 Released","#
        + #""encrypted_index":"\#(encryptedSwiftIndex)"}"#

    static let concurrencyCitation =
        #"{"type":"web_search_result_location","cited_text":"Approachable concurrency is on by default.","#
        + #""url":"https://www.swift.org/documentation/concurrency/","title":"Concurrency Guide","#
        + #""encrypted_index":"\#(encryptedConcurrencyIndex)"}"#

    /// Text, two searches with their results, then two cited text blocks. The opening text
    /// starts with an emoji (two UTF-16 units, one `Character`), so a citation range counted
    /// in the wrong unit is off by one and caught.
    static let anthropicTwoSearches = bytes(
        messageStart(inputTokens: 2679)
        + textStart(index: 0) + textDelta(index: 0, "🔎 Searching. ") + blockStop(index: 0)
        + searchStart(index: 1, id: "srvtoolu_01")
        + inputDelta(index: 1, "")
        + inputDelta(index: 1, #"{\"query\": \"swift 6"#)
        + inputDelta(index: 1, #".2 release\"}"#)
        + blockStop(index: 1)
        + resultStart(index: 2, searchID: "srvtoolu_01", content: swiftReleaseResults) + blockStop(index: 2)
        + searchStart(index: 3, id: "srvtoolu_02")
        + inputDelta(index: 3, #"{\"query\": \"swift concurrency changes\"}"#)
        + blockStop(index: 3)
        + resultStart(index: 4, searchID: "srvtoolu_02", content: concurrencyResults) + blockStop(index: 4)
        + textStart(index: 5)
        + citationDelta(index: 5, swiftReleaseCitation)
        + textDelta(index: 5, "Swift 6.2 shipped") + textDelta(index: 5, " this week.")
        + blockStop(index: 5)
        + textStart(index: 6)
        + citationDelta(index: 6, concurrencyCitation)
        + textDelta(index: 6, " Concurrency got simpler.")
        + blockStop(index: 6)
        + messageEnd(stopReason: "end_turn", outputTokens: 510, searches: 2)
    )

    // MARK: Every search failed

    /// Two searches, both answered with an error object inside a 200, then the model's text.
    static let anthropicFailedSearches = bytes(
        messageStart(inputTokens: 900)
        + searchStart(index: 0, id: "srvtoolu_e1")
        + inputDelta(index: 0, #"{\"query\": \"swift news\"}"#)
        + blockStop(index: 0)
        + resultStart(
            index: 1,
            searchID: "srvtoolu_e1",
            content: #"{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}"#
        )
        + blockStop(index: 1)
        + searchStart(index: 2, id: "srvtoolu_e2")
        + inputDelta(index: 2, #"{\"query\": \"swift forums\"}"#)
        + blockStop(index: 2)
        + resultStart(
            index: 3,
            searchID: "srvtoolu_e2",
            content: #"{"type":"web_search_tool_result_error","error_code":"unavailable"}"#
        )
        + blockStop(index: 3)
        + textStart(index: 4) + textDelta(index: 4, "I could not search right now.") + blockStop(index: 4)
        + messageEnd(stopReason: "end_turn", outputTokens: 40, searches: 0)
    )

    // MARK: pause_turn

    static let kyotoResults =
        #"[{"type":"web_search_result","title":"Kyoto forecast","url":"https://weather.example/kyoto","#
        + #""encrypted_content":"\#(encryptedKyoto)","page_age":"1 hour ago"}]"#

    static let kyotoCitation =
        #"{"type":"web_search_result_location","cited_text":"Mild, 18C","#
        + #""url":"https://weather.example/kyoto","title":"Kyoto forecast","#
        + #""encrypted_index":"\#(encryptedKyotoIndex)"}"#

    /// A search turn the API paused part way: one search, its result, one cited text block, then
    /// `stop_reason: pause_turn`.
    static let anthropicPausedTurn = bytes(
        messageStart(inputTokens: 100)
        + searchStart(index: 0, id: "srvtoolu_p1")
        + inputDelta(index: 0, #"{\"query\": "#)
        + inputDelta(index: 0, #"\"kyoto weather\"}"#)
        + blockStop(index: 0)
        + resultStart(index: 1, searchID: "srvtoolu_p1", content: kyotoResults) + blockStop(index: 1)
        + textStart(index: 2)
        + citationDelta(index: 2, kyotoCitation)
        + textDelta(index: 2, "Kyoto is mild") + textDelta(index: 2, " today.")
        + blockStop(index: 2)
        + messageEnd(stopReason: "pause_turn", outputTokens: 50, searches: 1)
    )

    /// The continuation's answer: the rest of the turn.
    static let anthropicResumedTurn = bytes(
        messageStart(inputTokens: 300)
        + textStart(index: 0) + textDelta(index: 0, " Pack a light jacket.") + blockStop(index: 0)
        + messageEnd(stopReason: "end_turn", outputTokens: 20, searches: nil)
    )

    /// The paused turn's content blocks exactly as the non-streaming API would have delivered
    /// them, which is what a continuation must send back.
    static let expectedPausedTurnJSON =
        #"[{"type":"server_tool_use","id":"srvtoolu_p1","name":"web_search","input":{"query":"kyoto weather"}},"#
        + #"{"type":"web_search_tool_result","tool_use_id":"srvtoolu_p1","content":\#(kyotoResults)},"#
        + #"{"type":"text","text":"Kyoto is mild today.","citations":[\#(kyotoCitation)]}]"#
}

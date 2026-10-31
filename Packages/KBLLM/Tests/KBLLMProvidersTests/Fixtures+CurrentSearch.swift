import Foundation

// Web search transcripts in the shape a current model streams with the dynamic-filtering tool
// (`web_search_20260209`): direct searches, a server-side code execution step that filters
// results (its own `server_tool_use` and result blocks, which are not searches), a search that
// failed with an error OBJECT inside an HTTP 200, several text blocks of which some are cited,
// `ping` frames between blocks, and the code execution container named on `message_delta`.
extension Fixtures {
    static let currentModel = "claude-sonnet-5-5"

    private static func searchBlocks(_ index: Int, id: String, query: String) -> String {
        blockStart(index, ["type": "server_tool_use", "id": id, "name": "web_search", "input": [:]])
            + delta(index, ["type": "input_json_delta", "partial_json": ""])
            + delta(index, ["type": "input_json_delta", "partial_json": #"{"query": ""#])
            + delta(index, ["type": "input_json_delta", "partial_json": query + #""}"#])
            + stop(index)
    }

    private static func resultBlock(_ index: Int, searchID: String, content: Any) -> String {
        blockStart(index, ["type": "web_search_tool_result", "tool_use_id": searchID, "content": content])
            + stop(index)
    }

    // Computed rather than stored: a dictionary of `Any` is not `Sendable`, so it cannot be a
    // static constant under strict concurrency.
    static var swiftResultList: [[String: Any]] {
        [
            [
                "type": "web_search_result", "title": "Swift 6.2 Released",
                "url": "https://swift.org/blog/swift-6.2-released/",
                "encrypted_content": "Eq/+Zs9Q==/abc+def/", "page_age": "2 days ago"
            ],
            [
                "type": "web_search_result", "title": "Swift Forums",
                "url": "https://forums.swift.org/", "encrypted_content": "Ep0/QW+9x==", "page_age": NSNull()
            ]
        ]
    }

    static var swiftCitation: [String: Any] {
        [
            "type": "web_search_result_location", "cited_text": "Swift 6.2 is now available.",
            "url": "https://swift.org/blog/swift-6.2-released/", "title": "Swift 6.2 Released",
            "encrypted_index": "Eo8B/+idx/QQ=="
        ]
    }

    static var filterContainer: [String: Any] {
        ["id": "container_011CWfilter", "expires_at": "2026-10-14T12:30:00Z"]
    }

    /// The full mixed turn. The answer is the text blocks joined in order:
    /// `mixedSearchAnswer`.
    static let currentMixedSearch = bytes(
        currentMessageStart(model: currentModel, inputTokens: 2_210)
            + textBlock(0, ["I'll look ", "into that."]) + ping
            + searchBlocks(1, id: "srvtoolu_01A", query: "swift 6.2 release")
            + resultBlock(2, searchID: "srvtoolu_01A", content: swiftResultList)
            // Server-side code filtering the results: a tool use and result that are NOT searches.
            + blockStart(3, [
                "type": "server_tool_use", "id": "srvtoolu_01C", "name": "code_execution", "input": [:],
                "caller": ["type": "direct"]
            ])
            + delta(3, ["type": "input_json_delta", "partial_json": #"{"code": "print(len(results))"}"#])
            + stop(3)
            + blockStart(4, [
                "type": "code_execution_tool_result", "tool_use_id": "srvtoolu_01C",
                "content": [
                    "type": "code_execution_result", "stdout": "2", "stderr": "", "return_code": 0, "content": []
                ]
            ])
            + stop(4) + ping
            + searchBlocks(5, id: "srvtoolu_01B", query: "swift forums outage")
            + resultBlock(
                6,
                searchID: "srvtoolu_01B",
                content: ["type": "web_search_tool_result_error", "error_code": "too_many_requests"]
            )
            + textBlock(7, ["Swift 6.2 ", "shipped this week."], citations: [swiftCitation])
            + textBlock(8, [" One search was rate limited."])
            + messageEnd("end_turn", outputTokens: 388, searches: 2, container: filterContainer)
    )

    static let mixedSearchAnswer = "I'll look into that.Swift 6.2 shipped this week. One search was rate limited."

    // MARK: pause_turn with a container

    static var pauseContainer: [String: Any] {
        ["id": "container_011CWpause", "expires_at": "2026-10-14T12:30:00Z"]
    }

    /// A long search turn the API paused after one search, naming the container it ran in.
    static let currentPausedTurn = bytes(
        currentMessageStart(model: currentModel, inputTokens: 1_400)
            + textBlock(0, ["Checking the forecast."])
            + searchBlocks(1, id: "srvtoolu_01P", query: "kyoto weather")
            + resultBlock(2, searchID: "srvtoolu_01P", content: [[
                "type": "web_search_result", "title": "Kyoto forecast", "url": "https://weather.example/kyoto",
                "encrypted_content": "EkKy/oto+W==/+/", "page_age": "1 hour ago"
            ]])
            + messageEnd("pause_turn", outputTokens: 60, searches: 1, container: pauseContainer)
    )

    /// The continuation: the rest of the answer.
    static let currentResumedTurn = bytes(
        currentMessageStart(model: currentModel, inputTokens: 1_700)
            + textBlock(0, [" Mild, ", "pack a light jacket."])
            + messageEnd("end_turn", outputTokens: 20, searches: 0)
    )
}

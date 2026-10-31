import Foundation
import KBLLM

// The web search half of the response grammar: turning `server_tool_use` and
// `web_search_tool_result` blocks into neutral search events. Split from the parser's main
// file by subject, so that file stays within the house length limits.
extension AnthropicResponseParser {
    /// An open `server_tool_use` block. The query is usually streamed as `input_json_delta`
    /// fragments into `input`; `startQuery` covers a block that arrived with its input whole.
    struct SearchAccumulator {
        var id: String
        var startQuery: String?
        var input: String
    }

    /// A citation before its span is known: the text it cites streams after it, so the range is
    /// filled in when the text block stops.
    struct WebSearchCitationSeed {
        var url: String
        var title: String?
        var citedText: String
    }

    /// The query a finished search block asked for: the joined fragments when there were any,
    /// else the input the block opened with. An unreadable input is reported as an empty query
    /// rather than dropped, because the search still ran and still costs.
    static func query(of search: SearchAccumulator) -> String {
        struct Input: Decodable { let query: String? }
        let joined = search.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return search.startQuery ?? "" }
        let input = try? JSONDecoder().decode(Input.self, from: Data(joined.utf8))
        return input?.query ?? search.startQuery ?? ""
    }

    /// The neutral result for a `web_search_tool_result` block. An error result is DATA: it
    /// becomes `.failed(code)`, the model's text after it still streams, and nothing throws.
    func searchResultEvents(_ block: AnthropicFrame.ContentBlock) -> [ModelEvent] {
        guard let searchID = block.toolUseId, let content = block.content else { return [] }
        let outcome: WebSearchOutcome
        switch content {
        case .results(let results):
            outcome = .sources(results.compactMap { result in
                guard let url = result.url else { return nil }
                return WebSearchSource(url: url, title: result.title ?? "", pageAge: result.pageAge)
            })
        case .error(let code):
            outcome = .failed(Self.errorCode(code))
        case .unrecognized:
            // A result this version cannot read is still a result: say so with the closest
            // honest outcome rather than leave the search looking like it never answered.
            outcome = .failed(.other("unrecognized web_search_tool_result content"))
        }
        return [.webSearchResult(WebSearchResult(searchID: searchID, outcome: outcome))]
    }

    /// Anthropic's documented search error codes, mapped onto the neutral ones. An unknown code
    /// is carried verbatim in `.other`.
    static func errorCode(_ wire: String) -> WebSearchErrorCode {
        switch wire {
        case "too_many_requests": .tooManyRequests
        case "invalid_tool_input": .invalidToolInput
        case "max_uses_exceeded": .maxUsesExceeded
        case "query_too_long": .queryTooLong
        case "request_too_large": .requestTooLarge
        case "unavailable": .unavailable
        default: .other(wire)
        }
    }
}

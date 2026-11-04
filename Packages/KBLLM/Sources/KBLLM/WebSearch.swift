import Foundation

// The value types of SERVER-SIDE web search: what a caller asks for (`WebSearchOptions`, set on
// `ModelRequest.webSearch`) and what comes back (`WebSearchCall`, `WebSearchResult`,
// `WebSearchCitation` on the stream, `WebSearch` on the collected response). They live beside
// `LanguageModel.swift` rather than inside it only to keep that file within the house length
// limit; `ModelRequest`, `ModelEvent` and `ModelResponse`, which carry them, stay there.
//
// "Server-side" is the load-bearing word: the PROVIDER runs the searches inside the same call
// and hands back the queries, the sources and the citations as data. Nothing here fetches a
// page, and a model that cannot search refuses the request rather than answering without it.

/// The caller's opt-in to server-side web search for one request.
///
/// Setting `ModelRequest.webSearch` to a value of this type asks the model to search the web
/// when it judges current information would help. Only a model whose
/// ``LanguageModel/supportsWebSearch`` is `true` honours it (today, Anthropic); every other
/// adapter refuses the request as `.invalidRequest(field: "webSearch", ...)` before dispatch,
/// because answering without the search the caller asked for would be a silent downgrade.
///
/// Privacy and cost belong to the caller's decision to set this: the model's queries, and the
/// pages they return, pass through the provider, and each search is billed on top of tokens
/// (``TokenUsage/webSearchRequests`` counts them).
public struct WebSearchOptions: Sendable, Equatable {
    /// The most searches the model may run in this request, or nil for the provider's own
    /// limit. Must be positive when set.
    public var maxUses: Int?
    /// When non-empty, results come ONLY from these domains. Cannot be combined with
    /// `blockedDomains`.
    public var allowedDomains: [String]
    /// When non-empty, results never come from these domains. Cannot be combined with
    /// `allowedDomains`.
    public var blockedDomains: [String]

    public init(maxUses: Int? = nil, allowedDomains: [String] = [], blockedDomains: [String] = []) {
        self.maxUses = maxUses
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
    }

    /// Throw `.invalidRequest` for options no provider could be sent: both domain lists at once
    /// (an allow list and a block list contradict each other, and Anthropic answers the pair
    /// with a 400), or a `maxUses` below 1 (zero searches is "do not search", which is spelled
    /// by leaving `webSearch` nil). Adapters call this before opening a transport.
    public func validate() throws(KBLLMError) {
        if !allowedDomains.isEmpty, !blockedDomains.isEmpty {
            throw KBLLMError.invalidRequest(
                field: "webSearch.allowedDomains+blockedDomains",
                reason: "allowedDomains and blockedDomains cannot both be set; use one list"
            )
        }
        if let maxUses, maxUses < 1 {
            throw KBLLMError.invalidRequest(
                field: "webSearch.maxUses",
                reason: "maxUses must be a positive integer when set; got \(maxUses)"
            )
        }
    }
}

/// A search the model ran: the provider's id for it and the query it searched for. Streamed as
/// `ModelEvent.webSearchCall` once the query is complete, before its result arrives.
public struct WebSearchCall: Sendable, Equatable {
    public var id: String
    public var query: String

    public init(id: String, query: String) {
        self.id = id
        self.query = query
    }
}

/// One page a search returned.
public struct WebSearchSource: Sendable, Equatable {
    public var url: String
    public var title: String
    /// How old the page is, in the provider's own words (for example "2 days ago"), or nil when
    /// the provider did not say. Kept as text because providers do not give a date.
    public var pageAge: String?

    public init(url: String, title: String, pageAge: String? = nil) {
        self.url = url
        self.title = title
        self.pageAge = pageAge
    }
}

/// Why a search produced no sources. A failed search is DATA, not a thrown error: the provider
/// answers 200 and the model carries on (usually saying it could not search), so the caller
/// still gets the text alongside the reason.
public enum WebSearchErrorCode: Sendable, Equatable, Hashable {
    /// The provider rate-limited the search.
    case tooManyRequests
    /// The query the model produced was not a valid search.
    case invalidToolInput
    /// The request's `maxUses` was already spent.
    case maxUsesExceeded
    /// The query was longer than the provider accepts.
    case queryTooLong
    /// The request grew too large to continue searching.
    case requestTooLarge
    /// The search service was unavailable.
    case unavailable
    /// A code this version does not know, carried verbatim so it is never lost.
    case other(String)
}

/// What a search produced: the pages it found, or the reason it found none.
public enum WebSearchOutcome: Sendable, Equatable {
    case sources([WebSearchSource])
    case failed(WebSearchErrorCode)
}

/// The result of one search, keyed to its ``WebSearchCall`` by `searchID`. Streamed as
/// `ModelEvent.webSearchResult`.
public struct WebSearchResult: Sendable, Equatable {
    public var searchID: String
    public var outcome: WebSearchOutcome

    public init(searchID: String, outcome: WebSearchOutcome) {
        self.searchID = searchID
        self.outcome = outcome
    }
}

/// One search in a collected response: the query joined to its outcome. `outcome` is nil only
/// when the call ended before the provider returned the result.
public struct WebSearch: Sendable, Equatable {
    public var id: String
    public var query: String
    public var outcome: WebSearchOutcome?

    public init(id: String, query: String, outcome: WebSearchOutcome? = nil) {
        self.id = id
        self.query = query
        self.outcome = outcome
    }
}

/// A source the model cited for a span of its answer.
///
/// `utf16Range` locates the cited span in the COLLECTED content: the concatenation of every
/// `contentDelta` of the call, which is exactly `ModelResponse.content`. It is counted in UTF-16
/// code units because those concatenate exactly (a range computed while streaming stays valid
/// in the joined string, which `Character` offsets do not guarantee) and map directly onto
/// `NSRange`. ``range(in:)`` converts it to `String.Index` bounds.
///
/// On the stream a citation is emitted when the span it covers has finished, so the text it
/// points at has always already arrived.
public struct WebSearchCitation: Sendable, Equatable {
    public var url: String
    public var title: String?
    /// The passage of the source the model relied on.
    public var citedText: String
    /// The cited span of the collected content, in UTF-16 code units.
    public var utf16Range: Range<Int>

    public init(url: String, title: String?, citedText: String, utf16Range: Range<Int>) {
        self.url = url
        self.title = title
        self.citedText = citedText
        self.utf16Range = utf16Range
    }

    /// The cited span as indices into `content`, or nil when `content` is not the collected text
    /// this citation was reported against (the range falls outside it).
    public func range(in content: String) -> Range<String.Index>? {
        let utf16 = content.utf16
        guard utf16Range.lowerBound >= 0, utf16Range.upperBound <= utf16.count else { return nil }
        let lower = utf16.index(utf16.startIndex, offsetBy: utf16Range.lowerBound)
        let upper = utf16.index(utf16.startIndex, offsetBy: utf16Range.upperBound)
        return lower..<upper
    }
}

/// Folds the search events of one call into the collected `ModelResponse` fields for
/// `complete`: each result is joined to the call that asked for it, citations kept in order.
struct WebSearchCollector {
    private(set) var searches: [WebSearch] = []
    private(set) var citations: [WebSearchCitation] = []

    mutating func absorb(_ event: ModelEvent) {
        switch event {
        case .webSearchCall(let call):
            searches.append(WebSearch(id: call.id, query: call.query))
        case .webSearchResult(let result):
            if let index = searches.lastIndex(where: { $0.id == result.searchID }) {
                searches[index].outcome = result.outcome
            } else {
                // A result whose call was never reported is still a search that ran; keep it
                // with an empty query rather than lose its sources.
                searches.append(WebSearch(id: result.searchID, query: "", outcome: result.outcome))
            }
        case .citation(let citation):
            citations.append(citation)
        case .contentDelta, .reasoningDelta, .reasoningBlock, .toolCall, .usage, .completed:
            break
        }
    }
}

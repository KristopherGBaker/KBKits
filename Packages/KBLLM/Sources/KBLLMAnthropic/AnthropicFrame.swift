import Foundation

/// The one key `AnthropicFrame.SearchInput` reads. File scope rather than nested in it, to stay
/// within the house nesting limit.
private enum SearchInputKeys: String, CodingKey {
    case query
}

/// The one key `AnthropicFrame.Container` reads, at file scope for the same reason.
private enum ContainerKeys: String, CodingKey {
    case id
}

/// The subset of an Anthropic streaming frame the adapter reads. Snake-case wire keys
/// (`content_block`, `partial_json`, `stop_reason`) map to these camel-case fields.
///
/// Everything web search adds is optional and decoded leniently: a frame from a request without
/// search never carries those keys, and a search field this version does not understand must
/// not turn an otherwise good stream into a decoding failure.
struct AnthropicFrame: Decodable {
    let type: String
    let index: Int?
    let contentBlock: ContentBlock?
    let delta: Delta?
    /// `message_delta` reports output tokens here.
    let usage: Usage?
    /// `message_start` reports input and cache tokens on the message it opens.
    let message: MessageEnvelope?
    /// An `error` event's payload: the API failed after the stream had opened (an overload, say),
    /// so it reports the failure in-band instead of as an HTTP status.
    let error: APIError?

    struct MessageEnvelope: Decodable {
        let usage: Usage?
        /// The code execution container the turn runs in, when it runs code.
        let container: Container?
    }

    struct APIError: Decodable {
        let type: String?
        let message: String?
    }

    /// A code execution container, which the API reports as an object carrying its `id`. Read
    /// leniently (a bare id string is accepted too) because only the id is needed, and an
    /// unexpected shape must not fail an otherwise good stream.
    struct Container: Decodable {
        let id: String?

        init(from decoder: any Decoder) throws {
            if let id = try? decoder.singleValueContainer().decode(String.self) {
                self.id = id
                return
            }
            let object = try? decoder.container(keyedBy: ContainerKeys.self)
            id = (try? object?.decodeIfPresent(String.self, forKey: .id))
        }
    }

    /// Anthropic splits one call's usage across two frames, so every field is optional and
    /// the adapter merges what it is given.
    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        /// `cache_creation`: the write split by lifetime (5-minute and 1-hour).
        let cacheCreation: CacheCreation?
        /// `server_tool_use.web_search_requests`: the searches the call ran.
        let serverToolUse: ServerToolUsage?
    }

    /// `usage.cache_creation`: `ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`.
    /// `convertFromSnakeCase` capitalizes the component after each underscore, digits
    /// included, so `_1h_` arrives as `1H`: the names below are what the decoder looks up.
    struct CacheCreation: Decodable {
        let ephemeral5MInputTokens: Int?
        let ephemeral1HInputTokens: Int?
    }

    struct ServerToolUsage: Decodable {
        let webSearchRequests: Int?
    }

    struct ContentBlock: Decodable {
        let type: String
        let id: String?
        let name: String?
        /// A `server_tool_use` block's input. Streamed as `{}` here and filled by
        /// `input_json_delta`, but read in case a block arrives whole.
        let input: SearchInput?
        /// A `web_search_tool_result` block's id of the search it answers.
        let toolUseId: String?
        /// A `web_search_tool_result` block's whole result, which arrives in the start frame.
        let content: SearchResultContent?
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
        // The reasoning payload of a `thinking_delta`, the single reasoning wire form this
        // adapter promises, covered by the `anthropicReasoning` fixture.
        let thinking: String?
        let partialJson: String?
        let stopReason: String?
        /// A `citations_delta`'s citation for the text block it arrives in.
        let citation: Citation?
        /// `message_delta` may name the code execution container the turn ran in.
        let container: Container?
    }

    /// A web search query, from a `server_tool_use` input. Lenient because the same key holds a
    /// client `tool_use` block's input, whose shape is the caller's tool's, not this one.
    struct SearchInput: Decodable {
        let query: String?

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: SearchInputKeys.self)
            query = (try? container?.decodeIfPresent(String.self, forKey: .query))
        }
    }

    /// A `web_search_tool_result` block's `content`: a list of results on success, or one error
    /// object. Never throws, so an unrecognized shape is reported as such rather than failing
    /// the frame.
    enum SearchResultContent: Decodable {
        case results([SearchResult])
        case error(code: String)
        case unrecognized

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let results = try? container.decode([SearchResult].self) {
                self = .results(results)
            } else if let failure = try? container.decode(SearchError.self), let code = failure.errorCode {
                self = .error(code: code)
            } else {
                self = .unrecognized
            }
        }
    }

    struct SearchResult: Decodable {
        let url: String?
        let title: String?
        let pageAge: String?
    }

    struct SearchError: Decodable {
        let errorCode: String?
    }

    /// A `web_search_result_location` citation. Optional throughout so another citation type
    /// (a document location) decodes and is then ignored rather than failing the frame.
    struct Citation: Decodable {
        let type: String?
        let url: String?
        let title: String?
        let citedText: String?
    }
}

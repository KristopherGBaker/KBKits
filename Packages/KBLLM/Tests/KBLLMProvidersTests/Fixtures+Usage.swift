import Foundation

// The token-usage transcripts, in a separate file because `Fixtures` had reached the house
// type-body limit. Split by SUBJECT rather than arbitrarily: everything here exists to
// exercise what a provider says a call consumed.
extension Fixtures {
    /// A message_start that opens with the usage counts Anthropic reports up front: input
    /// tokens plus the prompt-cache read/write split.
    private static let anthMessageStartWithUsage =
        #"{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],"#
        + #""usage":{"input_tokens":11,"cache_read_input_tokens":300,"cache_creation_input_tokens":7}}}"#

    /// The closing frame, which is where Anthropic states output tokens.
    private static let anthEndTurnDeltaWithUsage =
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"#
        + #""usage":{"output_tokens":29}}"#

    /// A complete exchange that reports usage the way Anthropic actually does: split across
    /// the opening and closing frames, never in one place.
    static let anthropicWithUsage = bytes(
        frame(event: "message_start", data: anthMessageStartWithUsage)
        + frame(event: "content_block_start", data: anthTextBlockStart)
        + frame(event: "content_block_delta", data: anthTextDelta)
        + frame(event: "content_block_stop", data: anthTextBlockStop)
        + frame(event: "message_delta", data: anthEndTurnDeltaWithUsage)
        + frame(event: "message_stop", data: anthMessageStop)
    )

    /// The choice-less trailing frame OpenAI sends when `stream_options.include_usage` was
    /// requested. It arrives AFTER the frame carrying `finish_reason`, which is the ordering
    /// the adapter has to absorb.
    private static let openAIUsageFrame =
        #"{"choices":[],"usage":{"prompt_tokens":13,"completion_tokens":21,"#
        + #""prompt_tokens_details":{"cached_tokens":8}}}"#

    /// A plain text answer that ends with a usage frame after its finish reason.
    static let openAIWithUsage = bytes(
        frame(data: openAIContentDelta)
        + frame(data: openAIChoice("{}", finish: #""stop""#))
        + frame(data: openAIUsageFrame)
        + frame(data: "[DONE]")
    )

    /// A message_start whose cache write is split by lifetime, as Anthropic reports it under
    /// `usage.cache_creation`: 5 tokens written for five minutes and 40 for an hour.
    private static let anthMessageStartWithCacheLifetimes =
        #"{"type":"message_start","message":{"id":"msg_2","role":"assistant","content":[],"#
        + #""usage":{"input_tokens":11,"cache_read_input_tokens":0,"cache_creation_input_tokens":45,"#
        + #""cache_creation":{"ephemeral_5m_input_tokens":5,"ephemeral_1h_input_tokens":40}}}}"#

    static let anthropicWithCacheLifetimes = bytes(
        frame(event: "message_start", data: anthMessageStartWithCacheLifetimes)
        + frame(event: "content_block_start", data: anthTextBlockStart)
        + frame(event: "content_block_delta", data: anthTextDelta)
        + frame(event: "content_block_stop", data: anthTextBlockStop)
        + frame(event: "message_delta", data: anthEndTurnDeltaWithUsage)
        + frame(event: "message_stop", data: anthMessageStop)
    )

    /// An OpenAI-compatible provider (OpenRouter) that states the call's cost in `usage.cost`.
    private static let openAIUsageFrameWithCost =
        #"{"choices":[],"usage":{"prompt_tokens":13,"completion_tokens":21,"cost":0.00042}}"#

    static let openAIWithReportedCost = bytes(
        frame(data: openAIContentDelta)
        + frame(data: openAIChoice("{}", finish: #""stop""#))
        + frame(data: openAIUsageFrameWithCost)
        + frame(data: "[DONE]")
    )

    /// The same answer from a server that reports no usage at all, which is what a caller
    /// gets from an OpenAI-compatible endpoint that ignores `stream_options`.
    static let openAIWithoutUsage = bytes(
        frame(data: openAIContentDelta)
        + frame(data: openAIChoice("{}", finish: #""stop""#))
        + frame(data: "[DONE]")
    )

    /// The usage frame of a model that bills cache writes (GPT-5.6 and later), in the current
    /// Chat Completions shape: `usage.prompt_tokens_details.cache_write_tokens` beside
    /// `cached_tokens`, both parts of `prompt_tokens` (12,000 = 4,000 read + 7,000 written +
    /// 1,000 ordinary input, OpenAI's own worked example).
    private static let openAIUsageFrameWithCacheWrites =
        #"{"id":"chatcmpl-1","object":"chat.completion.chunk","model":"gpt-5.6-terra","choices":[],"#
        + #""usage":{"prompt_tokens":12000,"completion_tokens":250,"total_tokens":12250,"#
        + #""prompt_tokens_details":{"cached_tokens":4000,"cache_write_tokens":7000,"audio_tokens":0},"#
        + #""completion_tokens_details":{"reasoning_tokens":0}}}"#

    static let openAIWithCacheWrites = bytes(
        frame(data: openAIContentDelta)
        + frame(data: openAIChoice("{}", finish: #""stop""#))
        + frame(data: openAIUsageFrameWithCacheWrites)
        + frame(data: "[DONE]")
    )
}

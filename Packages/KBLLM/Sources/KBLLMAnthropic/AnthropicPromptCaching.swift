import Foundation

/// Where `AnthropicModel` places Anthropic prompt-cache breakpoints (`cache_control`), and how long an entry lives.
///
/// The cache is a prefix match over the rendered request (tools, then system, then messages): a breakpoint caches
/// everything before it, and a later request reads that entry only while those bytes are identical. So each breakpoint
/// is worth placing only where the caller knows the prefix will come back unchanged, which is why this is the caller's
/// choice and not the adapter's.
///
/// - `systemPrompt` marks the end of the system prompt (or, with none, the last tool), caching the tools and the
///   system prompt together. Right for a long, stable prompt sent with a different question each time.
/// - `conversation` also marks the last block of the last message, so the next request in the same conversation reads
///   the whole history so far and pays full price only for what it appends. Right for an agent loop or a chat, where
///   every request repeats the previous one and adds to it. Wrong for one-off requests that end in unique content:
///   each would pay the write premium on a tail that is never read back.
///
/// Whether it paid off is visible in `TokenUsage.cacheReadTokens` and `cacheWriteTokens`.
public struct AnthropicPromptCaching: Sendable, Equatable {
    /// How long an entry lives after the last request that wrote or read it. A read refreshes it at no extra cost.
    public enum Lifetime: Sendable, Equatable {
        /// The default. Writes cost 1.25 times base input; right when requests sharing the prefix start under five
        /// minutes apart, which keeps the entry alive indefinitely.
        case fiveMinutes
        /// Writes cost 2 times base input; pays off only when the gap between requests is between five minutes and
        /// an hour (a person who replies after a while).
        case oneHour
    }

    /// Whether the system prompt (with the tools before it) is marked.
    public var cachesSystemPrompt: Bool
    /// Whether the last block of the conversation is marked, so the next request reads the history.
    public var cachesConversation: Bool
    /// The lifetime of every entry this request writes. One value for every breakpoint, because the API requires an
    /// entry with a longer lifetime to come before any with a shorter one.
    public var lifetime: Lifetime

    public init(cachesSystemPrompt: Bool, cachesConversation: Bool, lifetime: Lifetime = .fiveMinutes) {
        self.cachesSystemPrompt = cachesSystemPrompt
        self.cachesConversation = cachesConversation
        self.lifetime = lifetime
    }

    /// No breakpoints: the request shape is exactly what it is without caching.
    public static let off = AnthropicPromptCaching(cachesSystemPrompt: false, cachesConversation: false)
    /// The tools and system prompt only.
    public static let systemPrompt = AnthropicPromptCaching(cachesSystemPrompt: true, cachesConversation: false)
    /// The tools and system prompt, and the conversation so far.
    public static let conversation = AnthropicPromptCaching(cachesSystemPrompt: true, cachesConversation: true)

    /// The `cache_control` object for this lifetime. The five-minute form leaves `ttl` out, so a caller that never
    /// asks for an hour sends the bytes it always did.
    var control: [String: Any] {
        switch lifetime {
        case .fiveMinutes: ["type": "ephemeral"]
        case .oneHour: ["type": "ephemeral", "ttl": "1h"]
        }
    }
}

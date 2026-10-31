import KBLLM

/// A run-level event, observed while an `AgentSession` drives a whole tool loop. It is a
/// type DISTINCT from `ModelEvent` on purpose: `ModelEvent` describes ONE model call,
/// whereas a run spans many calls plus the tool dispatch in between, so it needs cases a
/// single stream cannot express (a tool being invoked, a tool returning). Every payload
/// is a typed value, so a renderer reads a run by pattern-matching cases rather than by
/// scraping strings out of a formatted line.
public enum RunEvent: Sendable, Equatable {
    /// A slice of assistant text as it streams from the current model call.
    case contentDelta(String)

    /// A slice of the model's REASONING as it streams. Carried separately from
    /// `contentDelta` because reasoning is not the answer and must never be folded into
    /// the assistant text fed back into history. It is surfaced rather than dropped
    /// because a reasoning model can think for a long time before its first answer
    /// token, and a caller with nothing to render cannot tell thinking from a hang.
    case reasoningDelta(String)

    /// The model asked for a tool; carries the call so a renderer can show what ran.
    case toolInvoked(ToolCallRecord)

    /// A dispatched tool returned; carries the result (success or recoverable error).
    case toolReturned(ToolResult)

    /// What ONE model call in this run consumed, reported as that call ends.
    ///
    /// Per call, deliberately not summed over the run: a tool loop makes as many calls as it
    /// needs, and a single total would hide that a run cost six calls instead of one. A
    /// caller wanting the total adds them up, which it can only do if it was given the
    /// parts.
    case usage(TokenUsage)

    /// The run reached a terminal state; carries why it stopped.
    case finished(FinishReason)
}

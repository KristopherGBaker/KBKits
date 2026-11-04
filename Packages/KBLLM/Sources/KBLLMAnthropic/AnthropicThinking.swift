import Foundation

/// The `thinking` setting an `AnthropicModel` sends, when the caller sets one; nil sends no `thinking` field, so the
/// model's own default holds (adaptive thinking on every 5.x model). Which values a model accepts differs: `disabled`
/// is a 400 on Opus 5.5, Sonnet 5.5 and Fable 5.1 and is accepted by Haiku 5.5 only at `high` effort or below, and
/// `betweenTools` is Sonnet 5.5's lowest setting (no up-front thinking) at `high` effort or below. The adapter sends
/// what it is given; the caller knows the model.
public enum AnthropicThinking: Sendable, Hashable {
    /// `{type: "adaptive"}`: the model decides when and how much to think. `summarized` asks for a readable summary of
    /// each thinking block (`display: "summarized"`); otherwise the model's default display holds, which on the 5.x
    /// models is `omitted` (thinking blocks with empty text, billed the same).
    case adaptive(summarized: Bool)
    /// `{type: "between_tools"}`: no thinking before the first tool call, only between tool calls.
    case betweenTools
    /// `{type: "disabled"}`.
    case disabled

    var json: [String: Any] {
        switch self {
        case let .adaptive(summarized):
            summarized ? ["type": "adaptive", "display": "summarized"] : ["type": "adaptive"]
        case .betweenTools: ["type": "between_tools"]
        case .disabled: ["type": "disabled"]
        }
    }
}

/// `output_config.effort`: how much the model spends on a response, its thinking included. nil sends none, so the
/// model's default holds (`medium` on Opus 5.5 and Haiku 5.5, `high` elsewhere). Changing it mid-conversation
/// invalidates the prompt cache, so a caller keeps one per conversation.
public enum AnthropicEffort: String, Sendable, Hashable, CaseIterable {
    case low
    case medium
    case high
    case xhigh
    case max
}

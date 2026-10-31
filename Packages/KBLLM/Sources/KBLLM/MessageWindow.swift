import Foundation

/// Estimates how much of a model's context a message costs.
///
/// A seam because only the provider can count exactly, and asking it costs a round trip. Every
/// implementation here is an approximation, and the honest thing is to say so in the name
/// rather than to imply a precision the client does not have.
public protocol TokenEstimating: Sendable {
    func estimatedTokens(for message: Message) -> Int
}

/// Counts characters and divides.
///
/// Crude and deliberately so: it is deterministic, needs no model, and never differs between
/// two runs over the same input, which is what makes a trimming decision reproducible in a
/// test. It runs about 4 characters per token for English prose and less for CJK, so a caller
/// that must not overflow should leave headroom rather than trust the number.
public struct CharacterCountEstimator: TokenEstimating {
    public let charactersPerToken: Int
    /// What a non-text part costs. Images and tool calls carry no text to count but are not
    /// free, and pretending otherwise makes a history of images look empty.
    public let nonTextPartCost: Int

    public init(charactersPerToken: Int = 4, nonTextPartCost: Int = 1) {
        self.charactersPerToken = max(1, charactersPerToken)
        self.nonTextPartCost = max(0, nonTextPartCost)
    }

    public func estimatedTokens(for message: Message) -> Int {
        message.content.reduce(0) { total, part in
            switch part {
            case .text(let text):
                return total + (text.count + charactersPerToken - 1) / charactersPerToken
            case .toolResult(_, let result):
                let text = result.text ?? ""
                return total + (text.count + charactersPerToken - 1) / charactersPerToken
            case .image, .toolCall:
                return total + nonTextPartCost
            }
        }
    }
}

public extension Array where Element == Message {
    /// The newest messages that fit `maxTokens`, oldest dropped first.
    ///
    /// System messages are KEPT regardless of budget and stay at the front. They are the
    /// instructions that make every other message mean what it means, so dropping them to fit
    /// one more turn changes the model's behaviour rather than merely shortening its memory.
    ///
    /// Returns only the system messages when even one conversational message will not fit,
    /// rather than overflowing or returning nothing. A caller that must distinguish "trimmed
    /// hard" from "fitted comfortably" should compare counts; a caller that cannot proceed
    /// with a truncated history should check before sending.
    func trimmedToFit(
        maxTokens: Int,
        estimator: some TokenEstimating = CharacterCountEstimator()
    ) -> [Message] {
        guard maxTokens > 0 else { return filter { $0.role == .system } }

        let pinned = filter { $0.role == .system }
        let rest = filter { $0.role != .system }
        var budget = maxTokens - pinned.reduce(0) { $0 + estimator.estimatedTokens(for: $1) }
        guard budget > 0 else { return pinned }

        // Walked newest-first so the messages nearest the current turn are the ones kept.
        var kept: [Message] = []
        for message in rest.reversed() {
            let cost = estimator.estimatedTokens(for: message)
            if cost > budget { break }
            budget -= cost
            kept.append(message)
        }
        return pinned + kept.reversed()
    }
}

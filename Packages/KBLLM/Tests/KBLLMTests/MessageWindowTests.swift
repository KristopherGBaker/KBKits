import Foundation
import KBLLM
import Testing

private func user(_ text: String) -> Message { Message(role: .user, text: text) }
private func system(_ text: String) -> Message { Message(role: .system, text: text) }

@Suite("Message windowing")
struct MessageWindowTests {
    @Test("A history that already fits is returned unchanged")
    func fittingHistoryIsUntouched() {
        let messages = [system("be brief"), user("hello"), user("again")]
        #expect(messages.trimmedToFit(maxTokens: 1_000) == messages)
    }

    @Test("The oldest conversational messages are dropped first")
    func oldestGoFirst() {
        // 4 chars per token, so each of these costs 5 tokens.
        let messages = (1...4).map { user(String(repeating: "\($0)", count: 20)) }
        let kept = messages.trimmedToFit(maxTokens: 10)

        #expect(kept.count == 2)
        #expect(kept == Array(messages.suffix(2)))
    }

    /// Instructions are what make every other message mean what it means, so a budget squeeze
    /// must not quietly change the model's behaviour.
    @Test("System messages survive the budget and stay at the front")
    func systemMessagesArePinned() {
        let instructions = system("answer only in French")
        let messages = [instructions] + (1...6).map { user(String(repeating: "\($0)", count: 40)) }
        let kept = messages.trimmedToFit(maxTokens: 15)

        #expect(kept.first == instructions)
        #expect(kept.count < messages.count)
    }

    @Test("When nothing conversational fits, the instructions still come back")
    func instructionsSurviveAnImpossibleBudget() {
        let messages = [system("be brief"), user(String(repeating: "x", count: 400))]
        #expect(messages.trimmedToFit(maxTokens: 3) == [system("be brief")])
    }

    @Test("A zero or negative budget keeps only what must never be dropped")
    func nonPositiveBudgetKeepsOnlySystem() {
        let messages = [system("s"), user("u")]
        #expect(messages.trimmedToFit(maxTokens: 0) == [system("s")])
    }

    @Test("Order is preserved among the messages that survive")
    func orderIsPreserved() {
        let messages = (1...5).map { user("message \($0)") }
        let kept = messages.trimmedToFit(maxTokens: 8)
        #expect(kept == kept.sorted { lhs, rhs in
            messages.firstIndex(of: lhs) ?? 0 < messages.firstIndex(of: rhs) ?? 0
        })
    }

    @Test("Non-text parts cost something, so a history of images is not free")
    func imagesAreNotFree() {
        let estimator = CharacterCountEstimator()
        let imageMessage = Message(role: .user, content: [.image(data: Data([0x1]), mimeType: "image/png")])
        #expect(estimator.estimatedTokens(for: imageMessage) == 1)
    }

    @Test("The character estimator rounds up, so a short message never costs nothing")
    func shortMessagesStillCost() {
        #expect(CharacterCountEstimator().estimatedTokens(for: user("hi")) == 1)
        #expect(CharacterCountEstimator().estimatedTokens(for: user("")) == 0)
    }
}

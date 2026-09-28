import Testing
@testable import KBCore

@Suite("Spoken-text substitution")
struct SpokenTextSubstitutionTests {

    private func english(_ term: String, _ replacement: String, caseSensitive: Bool = false)
        -> SpokenTextSubstitution.Rule {
        .init(term: term, replacement: replacement, language: .english, caseSensitive: caseSensitive)
    }

    private func japanese(_ term: String, _ replacement: String)
        -> SpokenTextSubstitution.Rule {
        .init(term: term, replacement: replacement, language: .japanese)
    }

    @Test("empty rule list is a no-op")
    func emptyIsNoOp() {
        let out = SpokenTextSubstitution.apply("hello world", rules: [], language: .english)
        #expect(out == "hello world")
    }

    @Test("English replaces whole words, case-insensitive by default")
    func englishWholeWord() {
        let rules = [english("Pocket", "POCK-it")]
        #expect(SpokenTextSubstitution.apply("I love Pocket.", rules: rules, language: .english)
                == "I love POCK-it.")
        #expect(SpokenTextSubstitution.apply("the pocket app", rules: rules, language: .english)
                == "the POCK-it app")
    }

    @Test("English whole-word match does not touch substrings")
    func englishNoSubstring() {
        let rules = [english("cat", "feline")]
        let out = SpokenTextSubstitution.apply("the category caterpillar", rules: rules, language: .english)
        #expect(out == "the category caterpillar")
    }

    @Test("case-sensitive English rule only matches exact case")
    func englishCaseSensitive() {
        let rules = [english("SQL", "sequel", caseSensitive: true)]
        #expect(SpokenTextSubstitution.apply("learn SQL today", rules: rules, language: .english)
                == "learn sequel today")
        #expect(SpokenTextSubstitution.apply("a sql query", rules: rules, language: .english)
                == "a sql query")
    }

    @Test("longest term wins over a shorter one it contains")
    func longestFirst() {
        let rules = [english("Pocket", "wrong"), english("Pocket Reader", "the reader")]
        let out = SpokenTextSubstitution.apply("open Pocket Reader now", rules: rules, language: .english)
        #expect(out == "open the reader now")
    }

    @Test("symbol-only term falls back to a literal swap")
    func symbolTerm() {
        let rules = [english("&", "and")]
        let out = SpokenTextSubstitution.apply("rock & roll", rules: rules, language: .english)
        #expect(out == "rock and roll")
    }

    @Test("replacement with $ is taken literally, not as a capture reference")
    func dollarInReplacement() {
        let rules = [english("USD", "$5")]
        let out = SpokenTextSubstitution.apply("costs USD", rules: rules, language: .english)
        #expect(out == "costs $5")
    }

    @Test("Japanese replaces exact substrings (no word boundaries)")
    func japaneseSubstring() {
        let rules = [japanese("生憎", "あいにく")]
        let out = SpokenTextSubstitution.apply("生憎ですが", rules: rules, language: .japanese)
        #expect(out == "あいにくですが")
    }

    @Test("rules scoped to another language are ignored")
    func languageScoping() {
        let rules = [japanese("life", "ライフ"), english("life", "lyfe")]
        #expect(SpokenTextSubstitution.apply("a good life", rules: rules, language: .english)
                == "a good lyfe")
        #expect(SpokenTextSubstitution.apply("life is", rules: rules, language: .japanese)
                == "ライフ is")
    }

    @Test("empty-term rule is skipped")
    func emptyTermSkipped() {
        let rules = [english("", "x")]
        let out = SpokenTextSubstitution.apply("unchanged", rules: rules, language: .english)
        #expect(out == "unchanged")
    }
}

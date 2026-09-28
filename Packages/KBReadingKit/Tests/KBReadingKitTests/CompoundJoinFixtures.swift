import KBCore
import Foundation
@testable import KBReadingKit

// Shared by CompoundJoinTests and CompoundJoinTestsNearestArm, kept as separate
// files only to stay under the house file_length limit. Internal rather than private for
// that reason; FakeDict is a value type copied per test, and the helpers are pure, so the
// split introduces no shared mutable state.
// MARK: - Injected dictionary fixtures

/// A per-form table of (reading -> optional spans), standing in for JMdict's
/// `kanaReadings(forForm:)` and `furiganaSegments(form:reading:)`.
struct FakeDict {
    var byForm: [String: [(reading: String, spans: [ReadingSpan]?)]] = [:]

    var readings: (String) -> [String] {
        { form in (self.byForm[form] ?? []).map(\.reading) }
    }
    var spans: (String, String) -> [ReadingSpan]? {
        { form, reading in
            (self.byForm[form] ?? []).first { $0.reading == reading }.flatMap { $0.spans }
        }
    }
}

func token(_ text: String, _ lower: Int, _ upper: Int) -> WordTokenizer.Token {
    WordTokenizer.Token(offsets: WordOffsets(lower: lower, upper: upper), text: text,
                        latinTranscription: nil, tightLeading: false)
}

/// All ruby segments the join produced, in token order. A spanning run contributes its one
/// segment at the index its range starts, so a test can assert the rendered reading without
/// caring which mechanism produced it.
func flatSegments(_ result: KaraokeWord.JoinResult) -> [RubySegment] {
    var byIndex = result.overrides
    for run in result.spanning { byIndex[run.range.lowerBound, default: []].append(run.segment) }
    return byIndex.keys.sorted().flatMap { byIndex[$0]! }
}

extension KaraokeWord.JoinResult {
    /// Nothing was decided for this run: neither a per-token replacement nor a spanning one.
    var isEmpty: Bool { overrides.isEmpty && spanning.isEmpty }
}

// 運転手 as the tokenizer splits it: 運転|手. The decision is keyed by the reading each token
// ACTUALLY renders, so the fixtures inject that directly (運転 renders うんてん, 手 renders て,
// so the run renders the nonword うんてんて). Shared by both compound-join suites.
var untenshuTokens: [WordTokenizer.Token] { [token("運転", 0, 2), token("手", 2, 3)] }
var untenshuRendered: [String] { ["うんてん", "て"] }

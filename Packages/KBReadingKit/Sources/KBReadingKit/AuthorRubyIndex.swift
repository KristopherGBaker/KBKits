public import KBCore
import Foundation

/// What the author of THIS document told us their own kanji read, gathered across the whole
/// document so a reading given once reaches every later occurrence.
///
/// A publisher rubies a name on its first appearance and not again. Rendering the first
/// occurrence from the author's ruby and every later one from our own analysis makes the same
/// name change reading down the page - 沙名子 as さなこ and then すななご four lines later, both
/// on one screen. That is worse than a plain wrong reading: the page contradicts itself and the
/// reader has no way to tell which half is right.
///
/// PER DOCUMENT, always. A reading learned from one book must never leak into another, which is
/// why this is derived from a `Document` at build time and never cached or persisted - there is
/// no store to key on a text hash the way `RubyCorrection` has to be, because there is nothing
/// that outlives the build.
///
/// TWO GATES, and the index carries the first. The unfiltered class - every rendered token whose
/// surface the author rubied somewhere in the same book and that we read differently - is 41,823
/// positions over the 30-book corpus, and it is dominated by ordinary polysemous words whose ruby
/// is context-specific: 私 we render わたし where the author wrote わたくし (1,129 positions),
/// 来 as らい against きた/こ (539), 上 with six different author readings. Forcing one of those
/// everywhere would be a regression, not a fix.
///
/// So a surface enters the index only when the author gave it EXACTLY ONE reading in the whole
/// document. That is 30,220 positions. The second gate lives at the point of use (the reading
/// must be one the ordinary dictionary cannot account for), and together they isolate 3,354
/// positions that look like this:
///
///     茂作  しげさく -> もさく      小日向  おびなた -> こびなた
///     華山  げさん   -> かざん      通町    とおりまち -> とおりちょう
///
/// which is names and places - including the invented ones no dictionary will ever have (臨也,
/// 陀多, 芬子), which is exactly where a name dictionary runs out.
public struct AuthorRubyIndex: Sendable, Equatable {
    /// Surface -> the single reading the author gave it, hiragana-folded. A surface the author
    /// read two ways is ABSENT, not stored with one of them.
    private let readings: [String: String]
    /// The longest indexed surface, in Characters. The run scan needs a bound and there is no
    /// point offering it runs longer than anything it could match.
    let longestSurface: Int

    public static let empty = AuthorRubyIndex(rubied: [])

    /// Build from the author's `(base, reading)` pairs, however they were obtained.
    ///
    /// Rejected on the way in: an empty side; a base with no kanji (the author spelling out Ｂ
    /// as びい is not a reading we could ever have drawn); a reading that is not wholly kana
    /// (an authorial gloss in latin or an annotation is not a reading); and a reading equal to
    /// its own base.
    public init(rubied pairs: [(base: String, reading: String)]) {
        var seen: [String: String?] = [:]   // nil marks a surface read more than one way
        for pair in pairs {
            let base = pair.base
            let reading = KaraokeWord.normalizeKana(pair.reading)
            guard !base.isEmpty, !reading.isEmpty, base != reading,
                  FuriganaAnnotator.containsKanji(base),
                  FuriganaAnnotator.isKanaOnly(reading)
            else { continue }
            if let existing = seen[base] {
                if existing != reading { seen[base] = String?.none }
            } else {
                seen[base] = reading
            }
        }
        var settled: [String: String] = [:]
        var longest = 0
        for (base, reading) in seen {
            guard let reading else { continue }
            settled[base] = reading
            longest = max(longest, base.count)
        }
        self.readings = settled
        self.longestSurface = longest
    }

    /// Build from a document's own author ruby.
    ///
    /// GAPLESS ADJACENT RUNS MERGE, matching `Tools/FuriganaQA`'s gold grouping. Publishers set
    /// ruby per character as readily as per word - 沙《さ》名《な》子《こ》 is the same annotation
    /// as 沙名子《さなこ》 - and without the merge the first form would index three single kanji
    /// (each of which the polysemy gate then throws away) and never learn the name at all.
    public init(document: Document) {
        var pairs: [(base: String, reading: String)] = []
        for segment in document.segments {
            let text = segment.displayText
            guard !text.isEmpty, !segment.rubyRuns.isEmpty else { continue }
            let units = Array(text.utf16)
            for run in Self.merged(segment.rubyRuns) {
                guard run.lower >= 0, run.upper <= units.count, run.lower < run.upper else { continue }
                let base = String(utf16CodeUnits: Array(units[run.lower..<run.upper]),
                                  count: run.upper - run.lower)
                pairs.append((base: base, reading: run.reading))
            }
        }
        self.init(rubied: pairs)
    }

    /// Gapless adjacent runs concatenated into one, base and reading both. The same rule as
    /// `DocumentGold.merged` in the QA harness, so the reader learns the same units the
    /// instrument grades.
    private static func merged(_ runs: [RubyRun]) -> [RubyRun] {
        var out: [RubyRun] = []
        for run in runs.sorted(by: { $0.lower < $1.lower }) {
            guard let last = out.last, last.upper == run.lower else {
                out.append(run)
                continue
            }
            out[out.count - 1] = RubyRun(lower: last.lower, upper: run.upper,
                                         reading: last.reading + run.reading)
        }
        return out
    }

    public var isEmpty: Bool { readings.isEmpty }

    /// How many surfaces the author settled a single reading for. Diagnostic: a build that
    /// learned nothing and a build that was never given the index look identical otherwise.
    public var count: Int { readings.count }

    /// The author's reading for `surface`, or nil when they never rubied it or rubied it more
    /// than one way.
    public func reading(for surface: String) -> String? { readings[surface] }
}

public import Foundation

/// Which backend produced a timeline. Lives in `KBCore` because
/// `TimingProvenance` (a cache key) references it.
public enum ProviderID: String, Sendable, Hashable, Codable, CaseIterable {
    case apple
    case kokoro
    case elevenLabs
    case voicevox
}

/// How a timeline's word boundaries were derived. New timing methods add cases;
/// the value is part of the cache key so a quality upgrade invalidates stale
/// artifacts instead of serving worse data (§3.2, §M3).
public enum DerivationStrategy: String, Sendable, Hashable, Codable {
    case liveRange          // AVSpeech willSpeakRange callbacks (live)
    case proportional       // character/phoneme-weighted distribution (fallback)
    case durationPredictor  // Kokoro StyleTTS2 per-phoneme durations (M3)
    case forcedAlignment    // on-device ASR alignment
    case native             // provider-supplied timestamps (ElevenLabs)
}

/// How aggressively the UI should trust word-level highlighting.
public enum TimingConfidence: String, Sendable, Hashable, Codable {
    case exact      // native per-word boundaries (AVSpeech live, ElevenLabs)
    case aligned    // derived via on-device forced alignment
    case estimated  // proportional distribution — UI softens to sentence-band
                    // emphasis + word hinting, not a crisp cursor
}

/// Identifies *how* a timeline was produced, so cached audio/timing invalidates
/// when any input that affects it changes (§3.2, §M3 cache key).
public struct TimingProvenance: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let providerID: ProviderID
    public let providerVersion: String   // e.g. FluidAudio "0.15.1"
    public let strategy: DerivationStrategy
    public let textHash: String          // hash of the exact normalized segment text

    public init(
        schemaVersion: Int = KBCore.schemaVersion,
        providerID: ProviderID,
        providerVersion: String,
        strategy: DerivationStrategy,
        textHash: String
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.strategy = strategy
        self.textHash = textHash
    }
}

/// One word's timing within a segment. Persistable: holds UTF-16 `offsets`, not
/// a `String.Index` range (indices aren't stable across launches — §3.2). The
/// runtime `Range<String.Index>` is materialized on demand via
/// `range(in:)` against the live segment text.
public struct WordToken: Sendable, Hashable, Codable {
    public let offsets: WordOffsets
    public let start: TimeInterval      // seconds from segment audio start, at 1.0×
    public let duration: TimeInterval

    public init(offsets: WordOffsets, start: TimeInterval, duration: TimeInterval) {
        self.offsets = offsets
        self.start = start
        self.duration = duration
    }

    public var end: TimeInterval { start + duration }

    /// Materialize the runtime character range against the segment's text.
    public func range(in text: String) -> Range<String.Index>? {
        text.range(fromUTF16: offsets)
    }
}

/// Normalized, provider-independent timing for ONE segment. All times are
/// relative to the START of this segment's audio, at 1.0× rate (the "source
/// timeline" — §3.5 covers how playback rate is applied). Every backend's wildly
/// different native timing is normalized into this one shape so the playback
/// layer and UI never branch on provider (§3.1).
public struct HighlightTimeline: Sendable, Hashable, Codable {
    public let segmentID: SegmentID
    public let audioDuration: TimeInterval   // source duration at 1.0×
    public let words: [WordToken]            // ordered, non-overlapping
    public let confidence: TimingConfidence
    public let provenance: TimingProvenance

    public init(
        segmentID: SegmentID,
        audioDuration: TimeInterval,
        words: [WordToken],
        confidence: TimingConfidence,
        provenance: TimingProvenance
    ) {
        self.segmentID = segmentID
        self.audioDuration = audioDuration
        self.words = words
        self.confidence = confidence
        self.provenance = provenance
    }

    /// Index of the word active at `sourceTime` (seconds into the segment at
    /// 1.0×), or nil if before the first/after the last word. Binary search;
    /// no per-call allocation (§3.5, §M2 `HighlightDriver`).
    public func wordIndex(atSourceTime sourceTime: TimeInterval) -> Int? {
        guard let first = words.first, sourceTime >= first.start else { return nil }
        var low = 0
        var high = words.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let word = words[mid]
            if sourceTime < word.start {
                high = mid - 1
            } else if sourceTime >= word.end {
                low = mid + 1
            } else {
                return mid
            }
        }
        // In a gap between words (or past the last word's end): hold the most
        // recent word that has started — that's `high` after the search.
        return high >= 0 ? high : nil
    }
}

public extension String {
    /// Materialize a `Range<String.Index>` from UTF-16 offsets, or nil if the
    /// offsets don't land on character boundaries / are out of range.
    func range(fromUTF16 offsets: UTF16Range) -> Range<String.Index>? {
        let utf16View = utf16
        guard let lowU = utf16View.index(utf16View.startIndex, offsetBy: offsets.lower,
                                         limitedBy: utf16View.endIndex),
              let highU = utf16View.index(utf16View.startIndex, offsetBy: offsets.upper,
                                          limitedBy: utf16View.endIndex),
              let low = lowU.samePosition(in: self),
              let high = highU.samePosition(in: self),
              low <= high
        else { return nil }
        return low..<high
    }
}

import Foundation
// Explicit rather than implicit: on Apple platforms `@Observable` arrives without this,
// but off them the macro is unresolved without it.
public import Observation

/// The single thing the Reader UI observes. Updated by the playback layer
/// regardless of backend (§3.2): AVSpeech's live delegate, Kokoro's derived
/// timeline, and ElevenLabs's native timestamps all land here identically, so
/// the reader binds to this and nothing else.
///
/// Word position is carried as `currentWordOffsets` (UTF-16, into the current
/// segment's text) rather than a `Range<String.Index>`: offsets are stable and
/// `Sendable`-clean, and the view materializes the index range against the text
/// it is already rendering (§3.2).
@MainActor
@Observable
public final class HighlightState {
    public private(set) var currentSegmentID: SegmentID?
    public private(set) var currentWordOffsets: WordOffsets?
    /// How far through the current word the playhead is, 0...1 — a continuous signal
    /// for sub-word effects (the karaoke left-to-right fill). Updated every playback
    /// tick, so read it *only* from the leaf view that needs it (the fill word) to
    /// keep the rest of the reader off the tick-rate render path.
    public private(set) var currentWordProgress: Double = 0
    public private(set) var confidence: TimingConfidence = .exact
    public private(set) var isPlaying: Bool = false

    public init() {}

    /// Advance to a new segment (resets the active word).
    public func enterSegment(_ segmentID: SegmentID?, confidence: TimingConfidence) {
        currentSegmentID = segmentID
        currentWordOffsets = nil
        currentWordProgress = 0
        self.confidence = confidence
    }

    /// Update the active word within the current segment.
    public func highlightWord(_ offsets: WordOffsets?) {
        currentWordOffsets = offsets
    }

    /// Update the continuous 0...1 progress through the current word. Separate from
    /// `highlightWord` so the discrete word position and the sub-word fill can advance
    /// independently (the word holds while its fill sweeps).
    public func updateWordProgress(_ progress: Double) {
        currentWordProgress = progress
    }

    public func setPlaying(_ playing: Bool) {
        isPlaying = playing
    }

    /// Clear all highlight state (e.g. on stop / document close).
    public func reset() {
        currentSegmentID = nil
        currentWordOffsets = nil
        currentWordProgress = 0
        isPlaying = false
    }
}

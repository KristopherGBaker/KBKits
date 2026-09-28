import Foundation

// Japanese pitch accent, as data. These live in KBCore rather than in the UI package
// because pitch accent is linguistics, not rendering: the analysis that PRODUCES a
// pattern (KBJapaneseKit) and the code that DRAWS one (a SwiftUI reader) both need the
// vocabulary, and the analysis must not have to depend on SwiftUI to say what a mora is.
// `PitchDrawing` and `PitchOverlay`, which turn a pattern into marks, stay in
// the UI package: those really are rendering.

/// One mora's pitch level. Japanese pitch accent is two-level (there is no gradient
/// between high and low), so a plain enum captures it fully. Read as geometry, never
/// colour: the karaoke highlight owns colour and moves independently.
public enum PitchLevel: Sendable, Equatable, Hashable {
    case low
    case high
}

/// One mora paired with its pitch level, handed to the renderer already split and
/// leveled. The UI package owns no linguistics: it never splits moras and never
/// computes levels, it draws exactly this.
///
/// `isDrop` marks the accent nucleus: the pitch falls AFTER this mora. It is the only
/// signal that distinguishes an odaka last-high (a drop after the final mora, heard
/// once a particle joins) from a heiban last-high (no drop). Two words whose moras
/// carry identical levels can still differ solely in where `isDrop` lands, so the
/// renderer must never discard it.
public struct MoraPitch: Sendable, Equatable, Hashable {
    public let mora: String
    public let level: PitchLevel
    public let isDrop: Bool

    public init(mora: String, level: PitchLevel, isDrop: Bool) {
        self.mora = mora
        self.level = level
        self.isDrop = isDrop
    }
}

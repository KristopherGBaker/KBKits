/// `KBCore` holds the pure domain types shared by every other Kit, with zero
/// external dependencies.
///
/// Every other package depends only on `KBCore`, and `KBCore` imports nothing
/// platform- or UI-specific (Foundation only). The two load-bearing models live
/// here: the `Document` model (importers normalize into it) and the normalized
/// highlight-sync model (`HighlightTimeline` / `WordToken` / `HighlightState`)
/// that every speech backend feeds and the reader UI observes identically.
public enum KBCore {
    /// Schema version for serialized domain artifacts (timelines, positions,
    /// cached audio). Bumping invalidates persisted data whose shape changed.
    /// Mirrored into `TimingProvenance.schemaVersion` (§3.2).
    public static let schemaVersion = 1
}

import KBCore

/// Whether `WordTokenizer` is backed by the REFERENCE CJK segmenter.
///
/// `CoreFoundationCJKSegmenter` is the behavior every other implementation is compared
/// against: it segments space-less scripts at word boundaries and can produce a Latin
/// transcription. The portable `ScalarCJKSegmenter` deliberately does neither, splitting
/// per character and returning no transliteration, so tests that pin word-level spans or
/// romaji are not merely failing off Apple platforms; they do not apply there.
///
/// Tests gate on this with `@Test(.enabled(if:))` rather than `#if`, so they are reported
/// as skipped instead of vanishing from the run. See `docs/ANDROID.md`.
#if canImport(Darwin)
let hasReferenceCJKSegmenter = true
#else
let hasReferenceCJKSegmenter = false
#endif

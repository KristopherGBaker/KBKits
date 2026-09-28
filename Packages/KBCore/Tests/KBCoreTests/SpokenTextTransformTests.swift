import Testing
import Foundation
@testable import KBCore

@Test func hyphenInCompoundWordBecomesSpace() {
    #expect(SpokenTextTransform.hyphenatedCompoundsToSpaces("staff-level") == "staff level")
    #expect(SpokenTextTransform.hyphenatedCompoundsToSpaces("lip-curlingly") == "lip curlingly")
}

@Test func multipleHyphensInOneWordAllBecomeSpaces() {
    #expect(SpokenTextTransform.hyphenatedCompoundsToSpaces("well-thought-out") == "well thought out")
}

@Test func transformIsLengthPreserving() {
    let input = "A state-of-the-art lip-curlingly good day."
    let output = SpokenTextTransform.hyphenatedCompoundsToSpaces(input)
    #expect(output.utf16.count == input.utf16.count)
    #expect(output == "A state of the art lip curlingly good day.")
}

@Test func nonCompoundHyphensAreLeftAlone() {
    // Number ranges, spaced dashes, and leading/trailing hyphens aren't compounds.
    #expect(SpokenTextTransform.hyphenatedCompoundsToSpaces("1-2") == "1-2")
    #expect(SpokenTextTransform.hyphenatedCompoundsToSpaces("a — b") == "a — b")
    #expect(SpokenTextTransform.hyphenatedCompoundsToSpaces("-start") == "-start")
    #expect(SpokenTextTransform.hyphenatedCompoundsToSpaces("end-") == "end-")
}

@Test func textWithoutHyphensIsUnchanged() {
    let input = "Nothing to change here."
    #expect(SpokenTextTransform.hyphenatedCompoundsToSpaces(input) == input)
}

@Test func segmentTransformLeavesDisplayTextUntouched() {
    let segment = TextSegment(
        id: SegmentID(documentID: DocumentID("doc"), sentenceIndex: 0),
        documentID: DocumentID("doc"), sentenceIndex: 0,
        text: "staff-level", sourceRange: DocRange(lower: 0, upper: 11))
    let transformed = segment.applyingSpokenTransform { text, _ in
        SpokenTextTransform.hyphenatedCompoundsToSpaces(text)
    }
    #expect(transformed.text == "staff level")
    #expect(transformed.displayText == "staff-level")
    #expect(transformed.id == segment.id)
}

@Test func segmentTransformPreservesListInfoAndRubyRuns() {
    // A transform that actually changes the spoken text (so the copy path runs, not the
    // no-op early return) must carry BOTH the additive-optional `listInfo` and the
    // author `rubyRuns` through unchanged — guarding the reconstruction in
    // `applyingSpokenTransform`.
    let listInfo = ListInfo(depth: 1, ordered: true, ordinal: 3, task: .checked)
    let rubyRuns = [RubyRun(lower: 0, upper: 1, reading: "わたくし")]
    let segment = TextSegment(
        id: SegmentID(documentID: DocumentID("doc"), sentenceIndex: 0),
        documentID: DocumentID("doc"), sentenceIndex: 0,
        text: "私-は", sourceRange: DocRange(lower: 0, upper: 3),
        listInfo: listInfo, rubyRuns: rubyRuns)
    let transformed = segment.applyingSpokenTransform { text, _ in
        SpokenTextTransform.hyphenatedCompoundsToSpaces(text)
    }
    #expect(transformed.text == "私 は")  // the transform actually changed the spoken text
    #expect(transformed.listInfo == listInfo)
    #expect(transformed.rubyRuns == rubyRuns)
}

public import KBCore

/// A reader paragraph: its words plus the block role used to lay it out. The value
/// model behind `KaraokeTextView` — SwiftUI-free so `ReaderContent.build` (and the
/// Android reading pipeline) can produce it without the view layer.
public struct KaraokeParagraph: Identifiable, Sendable {
    public let id: Int                // first segment index (also the scroll anchor)
    public let words: [KaraokeWord]
    public let blockStyle: BlockStyle
    public init(id: Int, words: [KaraokeWord], blockStyle: BlockStyle = .body) {
        self.id = id
        self.words = words
        self.blockStyle = blockStyle
    }
}

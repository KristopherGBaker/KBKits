public import Foundation

/// Everything reading or writing an `.apkg` can fail with.
public enum AnkiError: Error, Sendable, Equatable, LocalizedError {
    /// The archive opened but holds no collection database, so it is not an Anki
    /// deck. `found` lists what was in it, to make a mis-picked file obvious.
    case notAnAnkiPackage(found: [String])
    /// The file is not a readable zip archive at all.
    case unreadableArchive(String)
    /// The collection database could not be opened or queried.
    case databaseFailure(String)
    /// A note claims more fields than its note type declares, which means the two
    /// disagree about the format and any mapping would be silently wrong.
    case fieldCountMismatch(noteType: String, declared: Int, found: Int)
    /// The collection describes note types but none of them could be understood, so
    /// there is nothing to map any note's fields against. Distinct from a collection
    /// that describes none at all, which is an honest empty result.
    case unreadableNoteTypes(declared: Int)
    /// Export was asked for a deck with no notes. Writing it would produce a file
    /// that imports as nothing, which is worse than saying so.
    case emptyDeck
    /// Export could not write to the destination.
    case writeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notAnAnkiPackage(let found):
            let listed = found.isEmpty ? "nothing" : found.joined(separator: ", ")
            return "That file is not an Anki deck. It contains \(listed)."
        case .unreadableArchive(let detail):
            return "That file could not be opened as an Anki deck: \(detail)"
        case .databaseFailure(let detail):
            return "The deck's database could not be read: \(detail)"
        case .fieldCountMismatch(let noteType, let declared, let found):
            return """
            A note does not match its note type "\(noteType)": the type declares \
            \(declared) fields and the note has \(found).
            """
        case .unreadableNoteTypes(let declared):
            return """
            This deck's note types could not be read: the file describes \(declared) \
            and none of them could be understood.
            """
        case .emptyDeck:
            return "There are no cards to export."
        case .writeFailure(let detail):
            return "The deck could not be written: \(detail)"
        }
    }
}

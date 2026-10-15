import Foundation

/// One card template: the question and answer sides, in Anki's `{{Field}}` syntax.
public struct AnkiCardTemplate: Sendable, Hashable {
    public let name: String
    /// Question format, e.g. `{{Word}}`.
    public let question: String
    /// Answer format, e.g. `{{FrontSide}}<hr id=answer>{{Meaning}}`.
    public let answer: String

    public init(name: String, question: String, answer: String) {
        self.name = name
        self.question = question
        self.answer = answer
    }
}

/// The note type an export will create in the receiving collection.
public struct AnkiNoteTypeDraft: Sendable, Hashable {
    public let name: String
    public let fieldNames: [String]
    public let templates: [AnkiCardTemplate]
    /// Card CSS. Anki applies it verbatim.
    public let styling: String

    public init(
        name: String,
        fieldNames: [String],
        templates: [AnkiCardTemplate],
        styling: String = AnkiNoteTypeDraft.defaultStyling
    ) {
        self.name = name
        self.fieldNames = fieldNames
        self.templates = templates
        self.styling = styling
    }

    /// A readable default that does not fight Anki's own theme.
    public static let defaultStyling = """
    .card { font-size: 22px; text-align: center; }
    """
}

/// A note to export. Field values are POSITIONAL, in the note type's field order.
public struct AnkiNoteDraft: Sendable, Hashable {
    public let fields: [String]
    public let tags: [String]
    /// Reuse a guid to let a receiving collection recognise a note it already has.
    /// Nil means the writer mints one.
    public let guid: String?

    public init(fields: [String], tags: [String] = [], guid: String? = nil) {
        self.fields = fields
        self.tags = tags
        self.guid = guid
    }
}

/// A complete export: one deck, one note type, its notes.
///
/// One note type per deck is a deliberate limit, not an oversight. An exporter that
/// mixes note types has to answer which fields each note carries, and every caller
/// so far has a single shape per export. Widening this later is additive.
public struct AnkiDeckDraft: Sendable, Hashable {
    /// Anki nests decks by name: "Example::こころ" imports as こころ inside Example.
    public let deckName: String
    public let noteType: AnkiNoteTypeDraft
    public let notes: [AnkiNoteDraft]

    public init(deckName: String, noteType: AnkiNoteTypeDraft, notes: [AnkiNoteDraft]) {
        self.deckName = deckName
        self.noteType = noteType
        self.notes = notes
    }
}

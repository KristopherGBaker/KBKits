import Foundation

/// A note type (Anki calls it a "model"): the named, ordered field list every note
/// of that type fills in.
///
/// Fields are POSITIONAL in the file format (a note stores values, not names), so
/// `fieldNames` is the only thing that gives them meaning. Keep the two together.
public struct AnkiNoteType: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let name: String
    public let fieldNames: [String]

    public init(id: Int64, name: String, fieldNames: [String]) {
        self.id = id
        self.name = name
        self.fieldNames = fieldNames
    }

    /// The position of `field`, or nil when this type has no such field.
    public func index(of field: String) -> Int? {
        fieldNames.firstIndex(of: field)
    }
}

/// A single note: the values, in the note type's field order, plus its tags.
///
/// A note is not a card. Anki generates one card per template that has content, so
/// one note can be several cards; an importer that counts cards will not agree with
/// one that counts notes.
public struct AnkiNote: Sendable, Hashable {
    /// Anki's own stable identifier, preserved on read so a re-import can recognise
    /// a note it has already seen rather than duplicating it.
    public let guid: String
    public let noteTypeID: Int64
    /// Values in the note type's field order. May be shorter than the type's field
    /// list when the note predates a field being added.
    public let fields: [String]
    public let tags: [String]
    /// The ids of all the distinct decks this note's cards touch, sorted ascending.
    ///
    /// Read from Anki's `cards` table (`cards.nid` to this note, `cards.did` to a
    /// deck) for both schema 11 and schema 18. Deduped and sorted. May be empty: a
    /// note with no cards, or one read from a collection that carries no `cards`
    /// table, touches no deck. When a note's cards span several decks the array holds
    /// every one of them, not the first.
    ///
    /// The package deliberately selects no canonical or primary deck out of that set.
    /// A consumer that needs a single deck applies its own explicit selection policy
    /// rather than inheriting a hidden choice made here.
    public let deckIDs: [Int64]

    public init(
        guid: String,
        noteTypeID: Int64,
        fields: [String],
        tags: [String],
        deckIDs: [Int64] = []
    ) {
        self.guid = guid
        self.noteTypeID = noteTypeID
        self.fields = fields
        self.tags = tags
        self.deckIDs = deckIDs
    }

    /// The value of `field` as named by `noteType`, or nil when the type has no such
    /// field or the note stopped short of it.
    public func value(of field: String, in noteType: AnkiNoteType) -> String? {
        guard let index = noteType.index(of: field), index < fields.count else { return nil }
        return fields[index]
    }
}

/// A deck. Anki nests decks by name with `::` separators ("Japanese::Core 2k"), so
/// the tree is spelled in the string rather than modelled.
///
/// A collection lists its decks here, and each ``AnkiNote`` carries the ids of the
/// decks its own cards sit in through ``AnkiNote/deckIDs``, read from Anki's `cards`
/// table for both schema 11 and schema 18. A multi-deck import can therefore be
/// filtered or split by deck rather than landing everything in one place.
public struct AnkiDeck: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

/// Everything an importer needs out of an `.apkg`.
///
/// Deliberately not the whole collection: review logs, deck options, saved searches
/// and media are read past. Scheduling state is excluded outright: importing a
/// foreign scheduler's numbers is a decision the consumer should make explicitly,
/// and nothing here should make it look already made.
public struct AnkiCollection: Sendable, Hashable {
    public let noteTypes: [AnkiNoteType]
    public let decks: [AnkiDeck]
    public let notes: [AnkiNote]

    public init(noteTypes: [AnkiNoteType], decks: [AnkiDeck], notes: [AnkiNote]) {
        self.noteTypes = noteTypes
        self.decks = decks
        self.notes = notes
    }

    /// The note type a note belongs to, or nil when the collection does not
    /// describe it (a corrupt or partial export).
    public func noteType(for note: AnkiNote) -> AnkiNoteType? {
        noteTypes.first { $0.id == note.noteTypeID }
    }
}

import Foundation

/// The legacy (schema 11) collection layout, which is what an export writes.
///
/// Writing the OLD schema on purpose: every Anki that can open a `.apkg` reads
/// schema 11, while schema 18 files are rejected by older versions. An export
/// exists to be opened by someone else's Anki, so the compatible form wins.
enum AnkiCollectionSchema {
    static let version = 11

    /// Anki's own DDL. `revlog` and `graves` stay empty here but must exist: Anki
    /// queries them on import and a missing table is an error, not an empty result.
    static let ddl = """
    CREATE TABLE col (
        id integer primary key, crt integer not null, mod integer not null,
        scm integer not null, ver integer not null, dty integer not null,
        usn integer not null, ls integer not null, conf text not null,
        models text not null, decks text not null, dconf text not null, tags text not null
    );
    CREATE TABLE notes (
        id integer primary key, guid text not null, mid integer not null,
        mod integer not null, usn integer not null, tags text not null,
        flds text not null, sfld integer not null, csum integer not null,
        flags integer not null, data text not null
    );
    CREATE TABLE cards (
        id integer primary key, nid integer not null, did integer not null,
        ord integer not null, mod integer not null, usn integer not null,
        type integer not null, queue integer not null, due integer not null,
        ivl integer not null, factor integer not null, reps integer not null,
        lapses integer not null, left integer not null, odue integer not null,
        odid integer not null, flags integer not null, data text not null
    );
    CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
    CREATE TABLE revlog (
        id integer primary key, cid integer not null, usn integer not null,
        ease integer not null, ivl integer not null, lastIvl integer not null,
        factor integer not null, time integer not null, type integer not null
    );
    CREATE INDEX ix_notes_usn on notes (usn);
    CREATE INDEX ix_cards_usn on cards (usn);
    CREATE INDEX ix_cards_nid on cards (nid);
    CREATE INDEX ix_cards_sched on cards (did, queue, due);
    CREATE INDEX ix_revlog_cid on revlog (cid);
    CREATE INDEX ix_revlog_usn on revlog (usn);
    CREATE INDEX ix_notes_csum on notes (csum);
    """

    /// The `col.models` JSON: note types keyed by id, as strings.
    static func modelsJSON(_ draft: AnkiNoteTypeDraft, id: Int64, deckID: Int64) -> String {
        let fields = draft.fieldNames.enumerated().map { offset, name in
            [
                "name": name, "ord": offset, "sticky": false, "rtl": false,
                "font": "Arial", "size": 20, "media": [], "description": ""
            ] as [String: Any]
        }
        let templates = draft.templates.enumerated().map { offset, template in
            [
                "name": template.name, "ord": offset, "qfmt": template.question,
                "afmt": template.answer, "did": NSNull(), "bqfmt": "", "bafmt": ""
            ] as [String: Any]
        }
        // `req` tells Anki which fields must be non-empty for a template to make a
        // card, and it must describe THE TEMPLATE: hardcoding field 0, as this once
        // did, tells Anki to generate a card from a field the front may never
        // reference, so a note with an empty front produces a blank card and a
        // reversed template produces none at all.
        let requirements = draft.templates.enumerated().map { ordinal, template in
            let referenced = Self.fieldOrdinals(referencedBy: template.question, in: draft.fieldNames)
            return [ordinal, "any", referenced.isEmpty ? [0] : referenced] as [Any]
        }
        let model: [String: Any] = [
            "id": id, "name": draft.name, "type": 0, "mod": 0, "usn": -1,
            "sortf": 0, "did": deckID, "tmpls": templates, "flds": fields,
            "css": draft.styling, "latexPre": "", "latexPost": "", "latexsvg": false,
            "req": requirements, "tags": [], "vers": []
        ]
        return json([String(id): model])
    }

    /// The ordinals of the fields a template's front actually references.
    ///
    /// Anki templates spell a substitution `{{Field}}`, optionally with filters
    /// (`{{furigana:Word}}`) and with section markers (`{{#Tag}}`, `{{/Tag}}`,
    /// `{{^Tag}}`) that open conditionals rather than name a field. Special names
    /// like `FrontSide` are not fields either. Everything else is looked up by name,
    /// so a reference to something the note type does not declare is simply ignored.
    static func fieldOrdinals(referencedBy template: String, in fieldNames: [String]) -> [Int] {
        let special: Set<String> = ["FrontSide", "Tags", "Type", "Deck", "Subdeck", "Card"]
        var ordinals: [Int] = []
        var remainder = Substring(template)
        while let open = remainder.range(of: "{{"),
              let close = remainder.range(of: "}}", range: open.upperBound..<remainder.endIndex) {
            var token = String(remainder[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            remainder = remainder[close.upperBound...]
            guard let first = token.first, !"#/^".contains(first) else { continue }
            // Filters chain left of the field name: `{{text:furigana:Word}}`.
            if let lastColon = token.lastIndex(of: ":") {
                token = String(token[token.index(after: lastColon)...])
            }
            guard !special.contains(token), let index = fieldNames.firstIndex(of: token) else { continue }
            if !ordinals.contains(index) { ordinals.append(index) }
        }
        return ordinals.sorted()
    }

    /// The `col.decks` JSON. The default deck (id 1) must stay present; Anki assumes it.
    static func decksJSON(name: String, id: Int64) -> String {
        json([String(id): deck(name: name, id: id), "1": deck(name: "Default", id: 1)])
    }

    private static func deck(name: String, id: Int64) -> [String: Any] {
        [
            "id": id, "name": name, "mod": 0, "usn": -1, "desc": "", "dyn": 0,
            "collapsed": false, "browserCollapsed": false, "conf": 1,
            "newToday": [0, 0], "revToday": [0, 0], "lrnToday": [0, 0], "timeToday": [0, 0],
            "extendNew": 10, "extendRev": 50
        ]
    }

    /// `col.conf`: collection-wide options. `nextPos` continues the new-card queue.
    static func configJSON(modelID: Int64, deckID: Int64, noteCount: Int) -> String {
        json([
            "nextPos": noteCount + 1, "estTimes": true, "activeDecks": [deckID],
            "sortType": "noteFld", "timeLim": 0, "sortBackwards": false,
            "addToCur": true, "curDeck": deckID, "newBury": true, "newSpread": 0,
            "dueCounts": true, "curModel": modelID, "collapseTime": 1200,
            "dayLearnFirst": false, "schedVer": 2
        ])
    }

    /// `col.dconf`: the deck options preset every deck points at.
    static let deckConfigJSON = json([
        "1": [
            "id": 1, "name": "Default", "mod": 0, "usn": -1, "maxTaken": 60,
            "autoplay": true, "timer": 0, "replayq": true, "dyn": false,
            "new": [
                "bury": false, "delays": [1.0, 10.0], "initialFactor": 2500,
                "ints": [1, 4, 0], "order": 1, "perDay": 20
            ],
            "rev": [
                "bury": false, "ease4": 1.3, "ivlFct": 1.0, "maxIvl": 36500,
                "perDay": 200, "hardFactor": 1.2
            ],
            "lapse": [
                "delays": [10.0], "leechAction": 1, "leechFails": 8,
                "minInt": 1, "mult": 0.0
            ]
        ] as [String: Any]
    ])

    /// Deterministic JSON: sorted keys so the same draft always writes the same bytes,
    /// which is what makes a round-trip test meaningful.
    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

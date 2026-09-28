import Foundation

/// The checked/unchecked state of a GFM task-list item (`- [ ]` / `- [x]`). `nil` on a
/// `ListInfo` means the item is a plain list item, not a task. Display-only metadata —
/// it never affects what's spoken (the checkbox is not injected into the segment text).
public enum TaskState: Sendable, Hashable, Codable {
    case unchecked, checked
}

/// Rich list metadata carried by a `.listItem` segment (M7a): how deeply it nests, whether
/// it belongs to an ordered list (and its ordinal), and any task-checkbox state. Purely
/// additive and display-oriented — M7a captures it in the model; the visual render (indent
/// by `depth`, ordinal numbers, checkbox glyphs) is M7b. A `.listItem` segment whose
/// `TextSegment.listInfo` is `nil` is a flat list item = pre-M7a behavior (e.g. EPUB lists).
public struct ListInfo: Sendable, Hashable, Codable {
    /// 0-based nesting depth: a top-level list item is `0`, an item in a list nested under
    /// another item is `1`, and so on.
    public let depth: Int
    /// Whether this item belongs to an ordered list (`1.`/`2.`) vs an unordered one (`-`/`*`).
    public let ordered: Bool
    /// The item's 1-based ordinal within its ordered list (honoring a non-1 start index);
    /// `nil` for an unordered list.
    public let ordinal: Int?
    /// The GFM task-list checkbox state, or `nil` when the item is not a task-list item.
    public let task: TaskState?

    public init(depth: Int = 0, ordered: Bool = false, ordinal: Int? = nil, task: TaskState? = nil) {
        self.depth = depth
        self.ordered = ordered
        self.ordinal = ordinal
        self.task = task
    }
}

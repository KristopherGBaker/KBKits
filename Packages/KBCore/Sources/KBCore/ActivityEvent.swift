public import Foundation

/// What kind of activity counts toward the streak (PRD E2). Reading and reviewing both keep
/// the chain alive. The raw value is persisted, so don't rename a case once shipped.
public enum ActivityKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// The learner opened/played a document.
    case reading
    /// The learner graded a review card.
    case review
}

/// One recorded activity: a kind + when it happened. The streak only needs the set of active
/// day numbers, but storing each event keeps the door open for richer history later.
public struct ActivityEvent: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: ActivityKind
    public let occurredAt: Date

    public init(id: String, kind: ActivityKind, occurredAt: Date) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

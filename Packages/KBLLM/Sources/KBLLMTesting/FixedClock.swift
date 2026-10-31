import Foundation
import KBLLM

/// A clock frozen at a configured instant. Injecting this makes any time-dependent
/// logic reproducible and keeps the test suite off the wall clock. `sleep` returns
/// immediately, so retry/backoff code runs at test speed without a real delay.
public struct FixedClock: ClockSource {
    public let instant: Date

    public init(instant: Date) {
        self.instant = instant
    }

    public var now: Date {
        instant
    }

    public func sleep(for duration: Duration) async throws {
        // Deterministic tests do not wait: the point of a fixed clock is that time
        // does not advance on its own, so a sleep is a no-op rather than a real delay.
        _ = duration
    }
}

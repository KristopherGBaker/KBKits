import Foundation
import KBLLM

/// A `LanguageModel` that replays a recorded transcript. It implements ONLY `stream`,
/// so it also demonstrates that an adapter needs nothing more; the collected
/// `complete` path is inherited from the core. Replaying the same transcript yields the
/// same ordered events every run, so a test that asserts on model output is
/// deterministic and offline.
///
/// A fixed clock and seeded generator are held so a harness that composes timing or
/// randomness around a replay stays reproducible; the replay itself reads from the
/// recorded transcript, never the wall clock.
public struct ReplayModel: LanguageModel {
    public let transcript: [ModelEvent]
    public let clock: FixedClock
    public let rng: SeededRandomNumberGenerator

    public init(
        transcript: [ModelEvent],
        clock: FixedClock = FixedClock(instant: Date(timeIntervalSince1970: 0)),
        rng: SeededRandomNumberGenerator = SeededRandomNumberGenerator(seed: 0)
    ) {
        self.transcript = transcript
        self.clock = clock
        self.rng = rng
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let events = transcript
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

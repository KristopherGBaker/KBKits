import KBLLM

/// A deterministic generator seeded from a `UInt64`. Two instances built from the same
/// seed produce identical sequences, so a run that draws randomness (idempotency keys,
/// jitter) reproduces exactly. Uses SplitMix64, which is small, well-distributed, and
/// has no platform dependency, so it behaves identically wherever the core is ported.
public struct SeededRandomNumberGenerator: RandomSource {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Namespace marker for the testing-support module. The real surface is `ReplayModel`,
/// `FixedClock`, and `SeededRandomNumberGenerator` in the sibling files, which together
/// let agent-written tests run offline and deterministically.
///
/// This marker is the trap `KBLLM.swift` records: a type sharing its module's name shadows the
/// module, so a consumer writing `KBLLMTesting.ReplayModel` gets this enum and fails. It is kept
/// only because it is public API; new modules add no such marker.
public enum KBLLMTesting {}

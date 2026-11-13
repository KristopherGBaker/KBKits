/// Namespace marker for the runtime module. The real surface is `AgentSession`,
/// `RunEvent`, `RunResult`, the middleware chain, and the error-projection seam in the
/// sibling files; this keeps a stable symbol for the module itself.
///
/// This marker is the trap `KBLLM.swift` records: a type sharing its module's name shadows the
/// module, so a consumer writing `KBLLMRuntime.AgentSession` gets this enum and fails. It is kept
/// only because it is public API; new modules add no such marker.
public enum KBLLMRuntime {}

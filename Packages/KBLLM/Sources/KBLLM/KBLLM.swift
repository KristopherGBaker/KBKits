// The `@Tool`, `@Schema`, and `@ToolGroup` macros are re-exported so a consumer that
// imports the core gets the one obvious way to declare a tool without a second import.
@_exported import KBLLMMacros

// There is deliberately NO `enum KBLLM` namespace marker. A type sharing the module's name
// SHADOWS the module, so a consumer writing `KBLLM.Message` gets the type and fails. That
// matters whenever an importer has a `Message` of its own, which Kaiwa does, and it is the
// same trap that was removed from KBStudyKit for the same reason.

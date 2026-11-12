Required changes:

1. **Replace the public-API fallback.** Zero added `public` lines does not detect removed declarations, changed signatures, or implicit access through extensions. Require a complete before/after public-surface comparison against `3042a89`, including new files. Keep the optional API diagnostic; CUT its forbidden `cd … &&` command prefix.

2. **Correct the serializer claim.** Responses already always uses `.withoutEscapingSlashes`; Chat Completions does not; Anthropic selects it conditionally. Explicitly preserve all three policies and their sorted-key/error-mapping behavior. Identify existing tests and add missing coverage before extraction, including serialization failure → `.invalidRequest(field: "body", …)`.

3. **Strengthen assertions 7–8 against stubs.** Require the long ASCII body’s fragment to equal its **first 512 bytes**, not merely be capped. Redaction must preserve surrounding text while replacing the secret; include a nonempty secret absent from the message → unchanged, alongside empty/nil passthrough.

4. **Resolve assertions 9–10’s unspecified expectations.** Replace “current documented rule” and “current concatenation behavior” with concrete expected empty-secret and slash-case results, established by pre-move tests. Include the promised trailing/leading slash cases and malformed-base rejection before transport opens.

5. **Make F4 observable across environments.** Adapt the existing tests’ removed-type references and test the merged stand-in directly with both reasons. Assert reason-dependent availability and run failure, no events/capabilities, and nil quota/context. Source string hits cannot establish the entitlement reason when that factory branch is unavailable on the runner.

6. **Tighten verification without adding audit scripts.** Review the diff to confirm every enumerated original site calls the shared helper; one credential hit per module is insufficient evidence. CUT the literal `rg -l <same pattern>` placeholder. Narrow the task’s `.sparra/` exception to the named report, and account for task-authored untracked files.

7. **Restore gate discipline explicitly.** Require one scheduled pair of consecutive foreground suite runs on the same final tree, with nothing else building; record failures without rerunning the gate on unchanged content.

The suite probe was environment-blocked before compilation: `swiftc -print-target-info` returned `error: permissionDenied`. No suite pass or behavioral baseline was established.

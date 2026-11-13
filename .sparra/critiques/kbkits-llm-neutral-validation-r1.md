1. **Preserve refusal precedence.** CUT permission to reorder Anthropic’s checks merely by reporting it. Its current order is RULING 19 → schema+search → prefill → search validation → schema/tool validation. Add focused, tests-first cases for overlapping invalid inputs so extraction preserves the winning refusal.

2. **Bind unchanged error values.** Add a numbered assertion preserving existing fields and complete reason strings. Assertions 5–9 mostly check fields/substrings; the existing Responses refusal test ignores reasons entirely. Those checks alone permit wording changes forbidden by the brief.

3. **Repair verification commands.** Step 5’s literal command produces `zsh:1: parse error near '>'`. Replace declaration/function placeholders with executable commands or explicit source-inspection instructions. Specify the actual compiler-based public-API comparison; `NeutralSurfaceTests` and searching for `public` do not establish API equivalence.

4. **Keep the twice-green gate binding.** Add a numbered requirement for two consecutive full-suite passes on the same final tree, with nothing else building and no retry after failure. Conductor ownership is appropriate; reducing acceptance to one green run loses the brief’s determinism gate. CUT redundant filtered gate runs already covered by those full runs.

5. **CUT commit history from assertion 9.** Keep tests-first evidence in the report and conventional commits as workflow instructions, but acceptance must concern worktree content and recorded evidence, consistent with the contract’s final note.

Swift execution was **UN-RUN** here: the compiler’s target-info probe returned `error: permissionDenied`. I cannot confirm the suite commands runnable in this judge environment.

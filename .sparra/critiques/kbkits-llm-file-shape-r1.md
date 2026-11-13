The intended changes match survey F5–F8 and U3. Required changes:

1. **Fix verification syntax and failure propagation.** `$BASE=$(...)` is invalid; executing it produced `zsh:1: … not found`. Use `BASE=$(...)` or remove the unused assignment. Checks #4 and #9 must stop on failed Git commands; failed producers must not become empty-diff/no-match successes.

2. **Tighten the scope assertion.** Check #9 permits everything under `.sparra/` and ignores untracked files. Permit only the exact report path outside `Packages/KBLLM`, and inspect all delivered worktree content without requiring commits or a clean tree. Add a numbered full-diff assertion that changes consist solely of the schema extraction and specified documentation edits; remaining implementation and tests stay unchanged.

3. **Make the API gate executable.** Check #10 supplies neither standalone-copy setup nor a baseline revision for `diagnose-api-breaking-changes`. Specify the complete conductor procedure and invocation, or a concrete compiler-visible declaration comparison allowed by the brief. Require unchanged API, including no additions.

4. **Restore explicit move evidence.** Add the brief’s `git diff -M --stat` command and review to a numbered assertion, alongside the verbatim moved-block comparison. Merely listing “move-as-move diff” in the report does not establish that gate.

5. **Retain Silverpoint’s build gate.** Keep execution conductor-owned, but explicitly require its `make build` against the changed package and record its outcome or refusal. Its current placement under “Out,” without an acceptance assertion, drops a brief-required gate. Do not demand main-checkout-only worktree evidence.

The Swift test probe was **UN-RUN/environment-blocked**: Swift’s target-info invocation returned `error: permissionDenied`. No successful suite or standalone API execution was confirmed.

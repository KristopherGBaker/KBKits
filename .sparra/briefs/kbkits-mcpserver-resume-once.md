# Brief: one resume-once latch in the MCP listener (`kbkits-mcpserver-resume-once`, Silverpoint BACKLOG 88)

Silverpoint's code quality survey of the KBKits packages (`../Silverpoint/docs/code-quality-kbkits.md`) found the
listener's "resume this continuation exactly once, whichever callback fires first" latch written out twice in one file.
Read its finding F10 and unit U4 there first.

## What to do

1. **One private helper** in `Packages/KBMCPServer/Sources/KBMCPServer/MCPHTTPServer.swift` that returns the latch
   closure for a continuation (the `Mutex<Bool>` plus closure the two copies write), used by `start(port:)` and
   `stopAndWait()`. Same behavior: the continuation resumes exactly once, with the same value or error, whichever callback
   fires first; later callbacks do nothing.
2. **Tests**: the existing `ControllerTests`, `LoopbackTests` and HTTP suites pin the listener's lifecycle. Where the
   once-only rule (a second callback after the first resumes nothing and does not crash) has no test, add one before the
   change and show it passing on the current code; if the helper is private and unreachable, say so and rely on the
   lifecycle suites.
3. No public API change; nothing outside `Packages/KBMCPServer` changes.

## Gates

`swift test` in `Packages/KBMCPServer` twice, both green on the same tree with nothing else building, no retry (a
failure is recorded); `rg -t swift -n 'let resumeOnce' Packages/KBMCPServer/Sources` at one definition (or none, with
the helper's name at one definition and two calls); and Silverpoint's `make build` against the changed package (the
conductor runs it).

**How to work:** commit as you go with conventional commits (no attribution lines): tests as `test(mcpserver):`, the
change as `refactor(mcpserver):`. Run every long command in the FOREGROUND with a long timeout, never in the background.
If a command or a commit is refused, leave the work uncommitted and say what was not run. Write the report at
`.sparra/reports/kbkits-mcpserver-resume-once-r1.md` either way, listing each gate and its result.

## Conductor notes for the contract

- **The report is visible to the grader and committed.** The grader grades a temporary worktree of the unit branch; the
  conductor commits the report if the generator cannot.
- **Keep checks proportionate.** The evidence is the compiler, the package's suites and the search. Do not ask for
  hand-written audit scripts or for their robustness against adversarial inputs.
- **Gate discipline.** The gates are the conductor's single run on the final tree, with nothing else building; a failed
  gate is recorded and never rerun on the same tree.
- **Parallel units.** `kbkits-llm-neutral-validation` (U2) and `kbkits-llm-file-shape` (U3) change only `Packages/KBLLM`.

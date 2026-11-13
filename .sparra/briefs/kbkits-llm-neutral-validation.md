# Brief: one copy of the neutral pre-dispatch refusals in the KBLLM core (`kbkits-llm-neutral-validation`, Silverpoint BACKLOG 88)

Silverpoint's code quality survey of the KBKits packages (`../Silverpoint/docs/code-quality-kbkits.md`) found the
refusals every adapter makes before a request leaves written four times. Read its finding F3 and unit U2 there first.
U1 (`kbkits-llm-adapter-plumbing`) has merged: the shared plumbing it added is in `Packages/KBLLM/Sources/KBLLM/AdapterPlumbing.swift`,
and this unit's function can sit beside it or in its own core file.

## What to do

1. **One `package` function in the KBLLM core** owning RULING 19 ("responseSchema and tools cannot be combined"), the
   `webSearch` refusal for an adapter without server-side search, and the shared `validate()` walk over the response schema
   and each tool. The four copies F3 cites (`OpenAIModel+Request.swift`, `OpenAIResponsesModel+Request.swift`,
   `AnthropicModel+Request.swift`, `AppleModel.swift`) become a call to it, made first; each adapter keeps its
   provider-specific refusals (Anthropic's prefill and search-with-schema rules) beside the call. Order of checks and every
   reason string stay as they are; where the copies differ in order or wording, the survey or the tests say which is
   right, and the report names any difference it keeps.
2. **Tests first**: the existing refusal tests (`NeutralSurfaceTests` and the per-adapter suites) pin the strings. Where
   a copy's refusal (for one adapter, one of the rules) has no test, add one before the change and show it passing on the
   current code.
3. **No public API change.** No `public` keyword on the new function; the package's public surface is unchanged
   (`swift package diagnose-api-breaking-changes` cannot run on `Packages/KBLLM` in place because it is not a repository
   root; run it in a standalone copy of the package whose first commit is the base tree, or compare the compiler's view of
   `public` declarations before and after). Silverpoint is not touched.

## Gates

`swift test` in `Packages/KBLLM` twice, both green on the same tree with nothing else building, no retry (a failure is
recorded); `rg -t swift -n 'responseSchema and tools cannot be combined' Packages/KBLLM/Sources` and
`rg -t swift -n 'does not support server-side web search' Packages/KBLLM/Sources` each at one definition; the public-API
check above; and Silverpoint's `make build` still succeeding against the changed package (the conductor runs it).

**How to work:** commit as you go with conventional commits (no attribution lines): tests as `test(kbllm):`, the change
as `refactor(kbllm):`. Run every long command in the FOREGROUND with a long timeout, never in the background. Change
nothing outside `Packages/KBLLM`. If a command or a commit is refused, leave the work uncommitted and say what was not run.
Write the report at `.sparra/reports/kbkits-llm-neutral-validation-r1.md` either way, listing each gate and its result.

## Conductor notes for the contract

- **The report is visible to the grader and committed.** The grader grades a temporary worktree of the unit branch; the
  conductor commits the report if the generator cannot.
- **Keep checks proportionate.** The evidence is the compiler, the package's suites (with any added tests), the two
  searches and the public-API comparison. Do not ask for hand-written audit scripts or for their robustness against
  adversarial inputs.
- **Tests that cannot pass on the old code.** A test added first must pass on the pre-change code; if the old code is
  wrong in a case (U1's NaN serializer crashed), the generator says so, keeps the old behavior out of this unit, and the
  report names it as a separate fix, rather than changing behavior here.
- **Gate discipline.** The gates are the conductor's single run on the final tree, with nothing else building; a failed
  gate is recorded and never rerun on the same tree.
- **Parallel units.** `kbkits-llm-file-shape` (U3: file moves and doc comments in KBLLM) and `kbkits-mcpserver-resume-once`
  (U4, KBMCPServer) may build beside this one; U3 does not touch the four files above.

# Brief: one copy of the adapters' plumbing in the KBLLM core (`kbkits-llm-adapter-plumbing`, Silverpoint BACKLOG 88)

Silverpoint's code quality survey of the KBKits packages (`../Silverpoint/docs/code-quality-kbkits.md`) found the
same helpers copied between KBLLM's adapter modules. Read its findings F1 and F4 and unit U1 there first. F2, the third
part of U1, is already done (`3042a89`, `kbkits-responses-headers`), so this unit is F1 and F4.

## What to do

1. **F1, the shared plumbing.** `BodyPrefix`, `tapping`, `redact`, `composeEndpoint(base:suffix:)`, a
   `CredentialStore.resolvedSecret(forKey:)` and the sorted-keys serializer move into the KBLLM core
   (`Packages/KBLLM/Sources/KBLLM`) at `package` access (the adapters are targets of the same package, so `package`
   reaches them without widening the public API); each adapter module's copy (`KBLLMAnthropic`, `KBLLMOpenAI`, and any
   other module F1 cites) becomes a call. Where two copies differ, the survey says how; a copy whose behavior differs in
   any case is reconciled only if a test shows which behavior is right, and the report says so; otherwise it stays and
   the report names it.
2. **F4, one Private Cloud Compute stand-in.** The two identical stand-ins F4 cites become one internal
   `UnavailableFoundationModelBackend(reason:)`; the factory passes the reason.
3. **Tests first**: the package's suites already cover these paths; where a moved helper's behavior (the tap limit, the
   redaction, a credential edge case such as an empty or missing secret, the endpoint join with and without slashes) has
   no test, add one before the move and show it passing on the current code.
4. **No public API change.** No `public` keyword is added to a moved helper; the package's public surface is unchanged
   (for example `swift package diagnose-api-breaking-changes` against the commit before this unit, if it runs, or the
   compiler's view of `public` declarations compared before and after). Silverpoint is not touched.

## Gates

`swift test` in `Packages/KBLLM` twice, both green on the same tree with nothing else building, no retry (a failure is
recorded); the F1 searches (`final class BodyPrefix`, `func tapping\(`, `static func redact\(`, `static func
composeEndpoint`, `missingCredential\(key: credentialKey\)`) each falling to one definition; the public-API check above;
and Silverpoint's `make build` still succeeding against the changed package (the conductor runs it if you cannot).

**How to work:** commit as you go with conventional commits (no attribution lines): tests as `test(kbllm):`, the moves as
`refactor(kbllm):`. Run every long command in the FOREGROUND with a long timeout, never in the background. Change nothing
outside `Packages/KBLLM`. If a command or a commit is refused, leave the work uncommitted and say what was not run. Write
the report at `.sparra/reports/kbkits-llm-adapter-plumbing-r1.md` either way, listing each gate and its result.

## Conductor notes for the contract

- **The report is visible to the grader and committed.** The grader grades a temporary worktree of the unit branch; the
  conductor commits the report if the generator cannot.
- **Keep checks proportionate.** The evidence is the compiler, the package's suites (with the added tests), the F1
  searches and the public-API comparison. Do not ask for hand-written audit scripts or for their robustness against
  adversarial inputs: earlier Silverpoint units stalled on exactly that.
- **Gate discipline.** The gates are the conductor's single run on the final tree, with nothing else building; a failed
  gate is recorded and never rerun on the same tree.

## Item
Reshape one file and fix three doc defects in `Packages/KBLLM`, per Silverpoint survey F5/F6/F7/F8 (unit U3): `JSONSchema` (type + extension incl. `validate()`) moves verbatim from `Tooling.swift` to new `JSONSchema.swift`; the orphaned "Build the `JSONSchema` factory expression…" doc summary in `MacroSupport.swift` moves onto `schemaExpression(for:description:)`; the `KBLLMRuntime`/`KBLLMTesting` namespace markers each get a doc note naming the module-shadowing trap; `RandomSource` gets a no-consumer note. No symbol added/removed/renamed, no behavior change, nothing outside `Packages/KBLLM` (plus the report).

## I will build
- **F5**: `Packages/KBLLM/Sources/KBLLM/JSONSchema.swift` holding exactly the `JSONSchema` enum + its `public extension` (base `Tooling.swift` lines 3–149), byte-identical except any header/import lines the new file needs; `Tooling.swift` keeps only `ToolDefinition`, `ToolResult`, `Tool`, `ToolBox`.
- **F7**: the 3 summary lines ("Build the `JSONSchema` factory expression… yields a valid schema.") removed from above `unwrapOptional` and placed as the doc block directly above `static func schemaExpression(for:description:)` in `Packages/KBLLM/Sources/KBLLMMacrosPlugin/MacroSupport.swift`; `unwrapOptional` keeps its own "Whether a written type is optional…" doc.
- **F6**: doc note on each of `public enum KBLLMRuntime {}` and `public enum KBLLMTesting {}` stating (a) the trap `KBLLM.swift` records — a type sharing its module's name shadows the module; (b) marker kept because it is public API; (c) new modules add no marker. Declarations themselves unchanged.
- **F8**: doc line on `RandomSource` in `Packages/KBLLM/Sources/KBLLM/Seams.swift`: no KBLLM code draws randomness yet; seam exists for callers and future retry jitter. Declaration unchanged.
- Report `.sparra/reports/kbkits-llm-file-shape-r1.md` listing each gate + result (swift test ×2, `git diff -M --stat` + moved-block diff, F5 search, public-API comparison, Silverpoint `make build`, anything refused).
- Conventional commits as the brief instructs (`refactor(kbllm):` move, `docs(kbllm):` comments) — commit *attempts* are in-scope; final branch/merge state is harness-owned.
- **Out**: F6 deprecation (survey defers to a future major); any code/test changes; U2 (`NeutralSurfaceTests`/adapter files), U4 (KBMCPServer); `HTTPMethod` note (survey: nothing to do). Execution of `swift test` ×2, standalone-copy `diagnose-api-breaking-changes`, and Silverpoint `make build` is conductor-owned (single run, final tree, no retry) — but each outcome (or refusal) MUST be recorded in the report and is gated by assertions 4/9/11; this item makes them passable.

## I will verify by
From the worktree root. Every git-vs-base step sets `MB=$(git merge-base HEAD origin/main)` and chains with `&&` so a failed producer aborts instead of passing as empty output.
1. `swift test --package-path Packages/KBLLM` → builds, all tests pass, exit 0 (conductor runs it twice on the final tree, nothing else building; both green, no retry; judge env denies swift — this is the one conductor-only gate for test health).
2. `rg -t swift -n '^public (indirect )?(struct|enum|protocol|final class|class|actor) ' Packages/KBLLM/Sources/KBLLM/Tooling.swift` → exactly 4 lines: `ToolDefinition`, `ToolResult`, `Tool`, `ToolBox`.
3. `rg -t swift -n '^public (indirect )?(struct|enum|protocol|final class|class|actor) ' Packages/KBLLM/Sources/KBLLM/JSONSchema.swift` → exactly 1 line: `public indirect enum JSONSchema: Sendable, Equatable {`.
4. Move fidelity: `MB=$(git merge-base HEAD origin/main) && git show "$MB":Packages/KBLLM/Sources/KBLLM/Tooling.swift | sed -n '3,149p' > /tmp/jsonschema-base.txt && test -s /tmp/jsonschema-base.txt && START=$(rg -n 'A provider-neutral JSON Schema value' Packages/KBLLM/Sources/KBLLM/JSONSchema.swift | cut -d: -f1) && test -n "$START" && diff /tmp/jsonschema-base.txt <(tail -n +"$START" Packages/KBLLM/Sources/KBLLM/JSONSchema.swift)` → empty output, exit 0 (base lines 3–149 = `/// A provider-neutral…` through the extension's closing `}`).
5. `rg -c 'indirect enum JSONSchema|extension JSONSchema' Packages/KBLLM/Sources/KBLLM/Tooling.swift; rc=$?; test "$rc" -eq 1` → passes (no JSONSchema declaration/extension left behind).
6. `rg -n 'Build the .JSONSchema. factory expression' Packages/KBLLM/Sources/KBLLMMacrosPlugin/MacroSupport.swift` → exactly 1 hit; `rg -n -B4 'static func schemaExpression\(for type: String, description: String\?\) -> String' Packages/KBLLM/Sources/KBLLMMacrosPlugin/MacroSupport.swift` shows those 3 `///` lines directly above it; `rg -n -B8 'static func unwrapOptional' Packages/KBLLM/Sources/KBLLMMacrosPlugin/MacroSupport.swift` shows no "Build the" line, and `unwrapOptional`'s doc begins "Whether a written type is optional".
7. `rg -t swift -n 'public enum KBLLM(Runtime|Testing) \{\}' Packages/KBLLM/Sources` → exactly 2 hits (declarations intact); read both marker files' doc comments for the three F6 points.
8. `rg -n 'public protocol RandomSource: RandomNumberGenerator, Sendable \{\}' Packages/KBLLM/Sources/KBLLM/Seams.swift` → exactly 1 hit; read the doc block above it for the F8 note.
9. Scope, tracked: `MB=$(git merge-base HEAD origin/main) && OUT=$(git diff -M --name-only "$MB") && printf '%s\n' "$OUT" | rg -v '^Packages/KBLLM/|^\.sparra/reports/kbkits-llm-file-shape-r1\.md$|^$'; rc=$?; test "$rc" -eq 1` → passes (tracked changes confined to the package + the exact report path). Untracked: `git ls-files --others --exclude-standard | rg -v '^Packages/KBLLM/|^\.sparra/|^$'; rc=$?; test "$rc" -eq 1` → passes (no stray deliverables outside package/harness state; `.sparra/` untracked files are harness-owned, tolerated, never asserted on).
10. Public API (conductor, judge env denies swift): `T=$(mktemp -d) && MB=$(git merge-base HEAD origin/main) && git archive "$MB" Packages/KBLLM | tar -x -C "$T" && git -C "$T/Packages/KBLLM" init -q && git -C "$T/Packages/KBLLM" add -A && git -C "$T/Packages/KBLLM" commit -qm base && rsync -a --delete --exclude .git Packages/KBLLM/ "$T/Packages/KBLLM/" && swift package --package-path "$T/Packages/KBLLM" diagnose-api-breaking-changes HEAD` → exit 0, no breaking changes reported; full output recorded in the report. (Standalone copy because `Packages/KBLLM` is not a repo root; first commit is the base tree, working copy is the final tree.)
11. Full-diff confinement: `MB=$(git merge-base HEAD origin/main) && OUT=$(git diff "$MB" --name-only -- Packages/KBLLM) && printf '%s\n' "$OUT" | rg -v '^Packages/KBLLM/Sources/(KBLLM/(Tooling|JSONSchema|Seams)\.swift|KBLLMMacrosPlugin/MacroSupport\.swift|KBLLMRuntime/KBLLMRuntime\.swift|KBLLMTesting/KBLLMTesting\.swift)$|^$'; rc=$?; test "$rc" -eq 1` → passes (in-package changes are exactly the schema extraction + the four doc files; all other implementation and tests untouched).
12. Doc-only edits: `MB=$(git merge-base HEAD origin/main) && OUT=$(git diff "$MB" -- Packages/KBLLM/Sources/KBLLMMacrosPlugin/MacroSupport.swift Packages/KBLLM/Sources/KBLLMRuntime/KBLLMRuntime.swift Packages/KBLLM/Sources/KBLLMTesting/KBLLMTesting.swift Packages/KBLLM/Sources/KBLLM/Seams.swift) && printf '%s\n' "$OUT" | rg '^[+-]' | rg -v '^(\+\+\+|---)' | rg -v '^[+-][[:space:]]*(///|$)'; rc=$?; test "$rc" -eq 1` → passes (every changed line in the four doc files is a `///` doc line or blank — no code line touched).
13. Move shown as a move: `git diff -M --stat "$(git merge-base HEAD origin/main)" -- Packages/KBLLM` → runs clean; output (new `JSONSchema.swift`, shrunk `Tooling.swift`, small doc deltas) recorded in the report alongside the verbatim moved-block comparison (#4).
14. Read `.sparra/reports/kbkits-llm-file-shape-r1.md` in the graded worktree for every gate + result.

## Assertions
1. `Packages/KBLLM/Sources/KBLLM/JSONSchema.swift` exists; verify #3 yields exactly the one `JSONSchema` enum declaration.
2. Verify #4 diff is empty: moved `JSONSchema` enum + extension byte-identical to base `Tooling.swift` lines 3–149 (no logic line changed; new file may add only header/import lines before the doc comment).
3. Verify #2 (brief's F5 search) yields exactly the four tool-type lines; verify #5 passes (no `JSONSchema` declaration or extension remains in `Tooling.swift`).
4. `swift test --package-path Packages/KBLLM` exits 0 on the final tree (conductor's two same-tree runs both green, no retry; a failure recorded, not rerun).
5. MacroSupport.swift: the "Build the `JSONSchema` factory expression…" summary appears exactly once, as `///` lines directly above `static func schemaExpression(for type: String, description: String?) -> String`, and `unwrapOptional`'s doc block contains no line of it and still begins "Whether a written type is optional, and the type it wraps."
6. `KBLLMRuntime.swift` marker doc note states all three: the shadowing trap `KBLLM.swift` records (type named after its module shadows the module), kept because public API, and that new modules add no marker; `public enum KBLLMRuntime {}` line unchanged.
7. Same three points on `KBLLMTesting.swift`'s marker; `public enum KBLLMTesting {}` line unchanged.
8. `Seams.swift`: `RandomSource` doc block states no KBLLM code draws randomness yet and the seam exists for callers and future retry jitter; the `public protocol RandomSource: RandomNumberGenerator, Sendable {}` line unchanged (verify #8).
9. Public API unchanged, including no additions: conductor's verify #10 run exits 0 with no breaking change reported (output in the report); no-addition/no-rename is established jointly by assertion 2 (byte-identical move) + assertions 12–13 here (changes confined to six files, non-move changes doc-comment-only).
10. Verify #9 passes both halves: tracked diff vs merge-base touches only `Packages/KBLLM/**` plus (at most) `.sparra/reports/kbkits-llm-file-shape-r1.md`; untracked sweep shows no stray deliverable outside `Packages/KBLLM/`/`.sparra/`.
11. `.sparra/reports/kbkits-llm-file-shape-r1.md` exists in the graded worktree and lists each gate — swift test ×2, `git diff -M --stat` + moved-block diff, F5 search, public-API comparison, and Silverpoint's `make build` against the changed package (conductor-run) — with its result, naming anything refused/not run.
12. Verify #11 passes: in-package diff touches exactly `Tooling.swift`, `JSONSchema.swift`, `Seams.swift`, `MacroSupport.swift`, `KBLLMRuntime.swift`, `KBLLMTesting.swift` — all other implementation and tests byte-unchanged.
13. Verify #12 passes (four doc files changed only in `///`/blank lines) and verify #13's `git diff -M --stat` output is recorded in the report.

Changed/dropped vs standing contract, each tied to a critique point: preamble `$BASE=$(...)` removed and #4 rewritten fail-fast (pt 1); verify #9 split into tracked exact-report-path + untracked sweep, assertion 10 reworded to match (pt 2); verify #11/#12 + assertions 12/13 added as the full-diff "only these edits" gate (pt 2); verify #10 + assertion 9 rewritten with the concrete standalone-copy procedure and no-additions coverage (pt 3); verify #13 + assertion 13 add the brief's `git diff -M --stat` evidence (pt 4); "Out" bullet reworded and assertion 11 extended to record Silverpoint `make build` outcome/refusal (pt 5); verify #1 annotated conductor-only per the blocked swift probe (pt 6). No other assertion dropped.

CONTRACT: AGREED

## Amendment (conductor, after critique round 2; replaces verify 9, 11 and 12 and assertions 10, 12 and 13's scripted halves)

The brief asks for proportionate checks and rules out hand-hardened audit scripts. Scope and "only these edits" are
therefore settled by reading the diff, not by more shell plumbing:

1. **The reviewed diff (critique points 1–3).** The judge runs `git diff -M --stat main...HEAD` and
   `git diff -M main...HEAD -- Packages/KBLLM` and `git status --porcelain --untracked-files=all` in the graded worktree
   and reads them. Acceptance (replacing assertions 10, 12 and 13's scripted halves): the only paths changed or added
   are `Packages/KBLLM/Sources/KBLLM/Tooling.swift`, `Packages/KBLLM/Sources/KBLLM/JSONSchema.swift`,
   `Packages/KBLLM/Sources/KBLLM/Seams.swift`, `Packages/KBLLM/Sources/KBLLMMacrosPlugin/MacroSupport.swift`,
   `Packages/KBLLM/Sources/KBLLMRuntime/KBLLMRuntime.swift`, `Packages/KBLLM/Sources/KBLLMTesting/KBLLMTesting.swift` and
   `.sparra/reports/kbkits-llm-file-shape-r1.md` (other `.sparra/` files present at `main` are the conductor's and are not
   this unit's deliverables); `Tooling.swift` changes only by losing the `JSONSchema` block; `JSONSchema.swift` is that
   block verbatim (verify 4) plus the header and imports it needs; the four documentation files change only in the `///`
   lines the item names. Verify 4 (the verbatim moved block) keeps its fail-fast form.
2. **Silverpoint's build is binding (point 4).** Assertion 11 is strengthened: the conductor's Silverpoint `make build`
   against the changed package must exit 0. A refusal or an environment block is recorded as UN-RUN and is a gate not
   met, not a pass.

## Amendment 2 (conductor, after critique round 3)

1. **Failure propagation.** Verify 4, 10 and 13 run under `set -o pipefail` in one shell, and each starts with
   `MB=$(git merge-base HEAD main) && test -n "$MB" &&` before its first use of `$MB`; a failed producer then fails the
   step.
2. **Final worktree content.** Amendment 1's review reads the final worktree, committed or not:
   `MB=$(git merge-base HEAD main) && test -n "$MB" && git diff -M "$MB"` (the working tree against the merge base: commits,
   staged and unstaged edits) and, for each path `git ls-files --others --exclude-standard` lists that is not present at
   `main`, its contents (`git diff --no-index /dev/null <path>`). The allowed set, the report exception and the treatment
   of conductor metadata are as Amendment 1 says.

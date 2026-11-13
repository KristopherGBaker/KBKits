# Brief: `JSONSchema` gets its own file, and three doc fixes (`kbkits-llm-file-shape`, Silverpoint BACKLOG 88)

Silverpoint's code quality survey of the KBKits packages (`../Silverpoint/docs/code-quality-kbkits.md`) found a file
named for half of what it holds and three documentation defects. Read its findings F5, F6, F7 and F8 and unit U3 there
first. U1 (`kbkits-llm-adapter-plumbing`) has merged, so line numbers in the survey may have moved; find each place by
its text.

## What to do

1. **F5, a pure file move.** `JSONSchema` (the type and its extension, with `validate()`) moves from
   `Packages/KBLLM/Sources/KBLLM/Tooling.swift` into `Packages/KBLLM/Sources/KBLLM/JSONSchema.swift`; `Tooling.swift`
   keeps the four tool types (`ToolDefinition`, `ToolResult`, `Tool`, `ToolBox`). No line of the moved code changes
   (only the imports a new file needs).
2. **F7, a comment move.** In `Packages/KBLLM/Sources/KBLLMMacrosPlugin/MacroSupport.swift`, the three-line summary
   "Build the `JSONSchema` factory expression for a Swift type…" stacked on `unwrapOptional`'s doc moves onto
   `schemaExpression(for:description:)`, so each function carries its own documentation.
3. **F6, a doc note.** The `public enum KBLLMRuntime {}` and `public enum KBLLMTesting {}` markers each get a doc note
   naming the trap `KBLLM.swift` records (a type sharing its module's name shadows the module), saying the marker is kept
   because it is public API, and that new modules add none. Nothing is removed or deprecated.
4. **F8, a doc line.** `RandomSource` in `Seams.swift` gets a line saying no KBLLM code draws randomness yet and the
   seam exists for callers and future retry jitter.

No symbol is added, removed or renamed; no behavior changes; nothing outside `Packages/KBLLM` changes.

## Gates

`swift test` in `Packages/KBLLM` twice, both green on the same tree with nothing else building, no retry (a failure is
recorded); the move shown as a move (`git diff -M --stat` and a diff of the moved lines against the lines removed from
`Tooling.swift` that shows no logic line changed); F5's search (`rg -t swift -n '^public (indirect )?(struct|enum|protocol|final class|class|actor) ' Packages/KBLLM/Sources/KBLLM/Tooling.swift`)
at the four tool types; and the public API unchanged (`swift package diagnose-api-breaking-changes` in a standalone copy
of the package whose first commit is the base tree, since `Packages/KBLLM` is not a repository root, or the compiler's
view of `public` declarations compared). Silverpoint's `make build` against the changed package (the conductor runs it).

**How to work:** commit as you go with conventional commits (no attribution lines): `refactor(kbllm):` for the move,
`docs(kbllm):` for the comments. Run every long command in the FOREGROUND with a long timeout, never in the background.
If a command or a commit is refused, leave the work uncommitted and say what was not run. Write the report at
`.sparra/reports/kbkits-llm-file-shape-r1.md` either way, listing each gate and its result.

## Conductor notes for the contract

- **The report is visible to the grader and committed.** The grader grades a temporary worktree of the unit branch; the
  conductor commits the report if the generator cannot.
- **Keep checks proportionate.** The evidence is the compiler, the package's suites, the diff and the public-API
  comparison. This is a move and comments: no new tests are needed, and do not ask for hand-written audit scripts.
- **Gate discipline.** The gates are the conductor's single run on the final tree, with nothing else building; a failed
  gate is recorded and never rerun on the same tree.
- **Parallel units.** `kbkits-llm-neutral-validation` (U2: the adapters' request files and a core function) and
  `kbkits-mcpserver-resume-once` (U4, KBMCPServer) may build beside this one; they touch none of this unit's files.

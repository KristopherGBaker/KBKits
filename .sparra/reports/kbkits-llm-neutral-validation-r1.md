# kbkits-llm-neutral-validation, round 1 report

Core function: `validateNeutralRules`
Core file: `Packages/KBLLM/Sources/KBLLM/NeutralRefusals.swift`

## Summary

F3's four copies of the neutral pre-dispatch refusals are now one `package` method in the KBLLM core,
`ModelRequest.validateNeutralRules(supportsWebSearch:toolWalk:providerRules:)`, in its own core file
`NeutralRefusals.swift` (beside `AdapterPlumbing.swift`). It owns, in this order:

1. the `webSearch` refusal when `supportsWebSearch` is false (field `webSearch`, reason
   "this model does not support server-side web search (supportsWebSearch is false)");
2. RULING 19 (field `responseSchema+tools`, reason "responseSchema and tools cannot be combined in one request");
3. the adapter's `providerRules` closure (default: none);
4. the `validate()` walk over `responseSchema` and each tool, at the depth `toolWalk` names
   (`.definition` = `ToolDefinition.validate()`, `.parametersOnly` = `tool.parameters.validate()`).

The declaration is `package func validateNeutralRules(...) throws(KBLLMError)`, with a `package enum ToolSchemaWalk`
beside it. The file holds no `public` keyword.

Call sites (each the first statement of its adapter's validation):

- `KBLLMOpenAI/OpenAIModel+Request.swift`: `try request.validateNeutralRules(supportsWebSearch: false)`, now the first
  statement of `buildRequest` (it was after the `body` literal, which has no side effects).
- `KBLLMOpenAI/OpenAIResponsesModel+Request.swift`: same call replaces the private `validate(_:)`, first statement of
  `buildRequest`.
- `KBLLMAnthropic/AnthropicModel+Request.swift`: `validate(_:model:profile:)` calls
  `request.validateNeutralRules(supportsWebSearch: true) { try validateProviderRules(...) }`; the provider rules
  (schema+webSearch, prefill, `webSearch?.validate()`) moved verbatim into `validateProviderRules`, which runs between
  RULING 19 and the walk, exactly where they ran before.
- `KBLLMApple/AppleModel.swift`: `preDispatchRefusal(for:)` calls
  `request.validateNeutralRules(supportsWebSearch: false, toolWalk: .parametersOnly)` and returns the typed error, as
  before. Its capability refusals stay in `capabilityRefusal(for:capabilities:)`, untouched.

## Precedence and kept differences

Precedence is unchanged on every adapter:

- Chat, Responses, Apple: webSearch, then RULING 19, then the walk (as before).
- Anthropic: RULING 19, then responseSchema+webSearch, then prefill, then `webSearch?.validate()`, then the walk (as
  before). Anthropic passes `supportsWebSearch: true`, so the neutral search refusal never fires for it.

Kept differences between the four copies (preserved, not unified):

1. **Tool-walk depth.** Apple walks `tool.parameters.validate()` only; the HTTP adapters walk `tool.validate()`, which
   also refuses a `rawParameters` that is not an object schema. Apple never sends `rawParameters` (FoundationModels
   builds its schema from `parameters`, as `ToolDefinition.rawParameters`'s doc in `Tooling.swift` says), so this is kept
   as a `toolWalk: .parametersOnly` argument. Pinned by the new
   `NeutralRefusalAppleTests.aNonObjectRawSchemaIsNotRefusedBeforeTheBackendRuns`.
2. **No neutral webSearch refusal on Anthropic.** It searches server-side; it passes `supportsWebSearch: true`.
3. **Anthropic's provider rules run between RULING 19 and the walk**, through the `providerRules` closure.

No copy was judged wrong; no behavior was changed, so no separate fix is named.

## Tests added first

Two new suites (no existing test was edited):

- `Tests/KBLLMProvidersTests/NeutralRefusalTests.swift`
  - `webSearchIsRefusedWithTheCompleteReasonByTheAdaptersThatCannotSearch` (Chat, Responses: full reason string)
  - `schemaPlusToolsIsRefusedWithTheCompleteReasonByEveryHTTPAdapter` (Chat, Responses, Anthropic: full reason string)
  - `responsesRefusesANegativeResponseSchemaWithoutOpeningTheTransport` (gap fill, assertion 9)
  - `responsesRefusesANegativeToolParameterWithoutOpeningTheTransport` (gap fill, assertion 9)
  - `webSearchWinsOverSchemaPlusToolsWhereSearchIsUnsupported` (precedence a: Chat, Responses)
  - `schemaPlusToolsWinsOverAnUnhonourableSchema` (precedence b: Chat, Responses, Anthropic)
  - `anthropicRefusesAPrefillBeforeWalkingTheSchema` (precedence c, `claude-sonnet-5-5`, field `messages`)
  - `anthropicRefusesSchemaPlusSearchBeforeAPrefill` (precedence d, field `responseSchema+webSearch`)
  - `anthropicValidatesItsSearchOptionsBeforeWalkingTheTools` (extra: `webSearch.maxUses` wins over a
    negative-`minItems` tool, pinning that the provider rules run before the walk)
- `Tests/KBLLMAppleTests/NeutralRefusalAppleTests.swift`
  - `webSearchIsRefusedWithTheCompleteReason`, `schemaPlusToolsIsRefusedWithTheCompleteReason` (full strings)
  - `webSearchWinsOverSchemaPlusTools` (precedence a: Apple)
  - `schemaPlusToolsWinsOverAnUnhonourableSchema` (precedence b: Apple)
  - `aNonObjectRawSchemaIsNotRefusedBeforeTheBackendRuns` (assertion 10, three raw payloads; inference count 1)

**Pre-change pass evidence: NOT RUN.** The tests were written before the source change, but in this generator session
every `swift` invocation (`swift test --filter NeutralRefusal`, `swift build --build-tests`) was refused by the
permission guard ("This command requires approval"), so I could not show them passing on the pre-change tree. Each
expectation was derived by reading the pre-change source (quoted in the contract's "verified in source" list) and the
existing suites' fixtures and field values.

## Gates

| Gate | Result |
| --- | --- |
| `swift test` in `Packages/KBLLM`, run 1 | NOT RUN: `swift` refused by the permission guard in this session |
| `swift test` in `Packages/KBLLM`, run 2 | NOT RUN: same |
| `rg -t swift -n 'responseSchema and tools cannot be combined' Packages/KBLLM/Sources` | 1 hit: `Sources/KBLLM/NeutralRefusals.swift:51` (was 4) |
| `rg -t swift -n 'does not support server-side web search' Packages/KBLLM/Sources` | 1 hit: `Sources/KBLLM/NeutralRefusals.swift:42` (was 3) |
| Anthropic provider strings still in `AnthropicModel+Request.swift` | `search results carry citations` at :189, `end the conversation on a user turn` at :201 |
| Core function called in all four F3 files | `OpenAIModel+Request.swift:29`, `OpenAIResponsesModel+Request.swift:23`, `AnthropicModel+Request.swift:172`, `AppleModel.swift:183` |
| No `public` in the core file | `rg '\bpublic\b' Sources/KBLLM/NeutralRefusals.swift`: no matches |
| Public-API comparison (compiler) | NOT RUN: needs `swift` (refused). See below |
| Silverpoint `make build` | Conductor-owned; not run here |

The two `swift test` runs, the tests' pre-change runs and the compiler public-API comparison are left to the conductor's
gate run on the final tree.

## Public API

Compiler comparison: not run (swift refused). Source-level evidence instead: the change adds one file whose only
declarations are `package enum ToolSchemaWalk` and `package func validateNeutralRules` in an `extension ModelRequest`
with no access modifier, and it removes or edits only `private static` functions (`OpenAIResponsesModel.validate(_:)`,
`AnthropicModel.validate(_:model:profile:)`, `AppleModel.preDispatchRefusal(for:)`) and the body of the internal
`OpenAIModel.buildRequest`. No line carrying `public` was added, removed or edited. Expected result: unchanged. The
method from the brief (a standalone copy of `Packages/KBLLM` whose first commit is the base tree, then
`swift package diagnose-api-breaking-changes <base>`) is still to be run.

## Not done in this session

- No commits: commits are blocked for the generator, so the `test(kbllm):` and `refactor(kbllm):` commits were not made.
  The work is left uncommitted in the worktree.
- No `swift` command ran (see Gates).
- `git diff` was refused too; the diff was reviewed file by file with the editor.

## Scope

Changed: `Packages/KBLLM/Sources/KBLLM/NeutralRefusals.swift` (new), the four F3 files, the two new test files, and
this report. Nothing outside `Packages/KBLLM`, no existing test, and nothing in Silverpoint.

## Conductor's gate runs (nothing else building, each gate once per tree)

The conductor committed the generator's work as `c5d8892` (`test(kbllm)`: `NeutralRefusalTests.swift` and
`NeutralRefusalAppleTests.swift` only, on the pre-change code) and `c7a0d4a` (`refactor(kbllm)`: the core function and the
four adapters).

**Tests first, on the pre-change code.** `swift test --package-path Packages/KBLLM --filter NeutralRefusal` at `c5d8892`
in a temporary worktree: exit 0, 9 tests in 1 suite and 5 tests in 1 suite passed. Every added test (the full reason
strings, the Responses `minItems` gap, Apple's non-refusal of a non-object `rawParameters`, precedence cases (a)–(d) and
the extra `maxUses` case) passes on the old code.

**Run on `c7a0d4a` (recorded, failed).** `swift test` run 1 and run 2 both exit 1, one issue each:
`FoundationModelsSourceTests.foundationModelsAppearsOnlyInKBLLMApple` found `FoundationModels` in the KBLLM core, in a doc
comment of `NeutralRefusals.swift` ("Apple's builds the FoundationModels schema…"). The existing test is the evidence of
the defect. Searches, the API check and Silverpoint's build passed on that tree.

**Fix.** `990f693` (`fix(kbllm)`): the comment says "the on-device framework's schema" instead; no code changed.

**Run on the final tree `990f693`:**

| Gate | Result |
|---|---|
| `swift test --package-path Packages/KBLLM`, run 1 | exit 0 (15 tests in 3 suites, 145 in 20, 17 in 4, 234 in 34, 80 in 19) |
| `swift test --package-path Packages/KBLLM`, run 2 | exit 0 (the same counts) |
| `rg -t swift -n 'responseSchema and tools cannot be combined' Packages/KBLLM/Sources` | 1 line, `Sources/KBLLM/NeutralRefusals.swift:51` |
| `rg -t swift -n 'does not support server-side web search' Packages/KBLLM/Sources` | 1 line, `Sources/KBLLM/NeutralRefusals.swift:42` |
| Public API: `swift package diagnose-api-breaking-changes` in a standalone repository whose first commit is the merge base's `Packages/KBLLM` and whose working tree is `990f693`'s | exit 0, "No breaking changes detected" in all seven modules |
| `git diff -M --stat main...HEAD` | 7 files, all under `Packages/KBLLM` (the core file, the four adapters, the two test files) |
| Silverpoint `make build` against this tree (temporary Silverpoint worktree at main, `KBKits` linked to this unit's worktree) | exit 0 |

# kbkits-llm-adapter-plumbing, round 1 (Silverpoint BACKLOG 88, unit U1: F1 + F4)

Baseline: `3042a89`. Everything changed is under `Packages/KBLLM`, plus this report. Silverpoint is untouched.

## What was not run by the generator, and why

The generator's environment refused every `swift` invocation (`swift build`, `swift test`), `git commit`,
`python3`, `osascript` and `sed -i` ("requires approval"). There is no Makefile in this repository, so
`make test` / `make build` / `make lint` do not exist (`make: *** No rule to make target 'test'`). So:

- **Nothing here was compiled or run by the generator.** Every swift gate below is the conductor's.
- **Nothing is committed.** The work is left in the tree for the conductor to commit in two steps (below).
  The first step's tree is exactly the pre-move state, which is what the pre-move test run needs.

### Commits for the conductor (conventional, no attribution lines)

1. Pre-move (tests only; sources are still `3042a89`'s):
   `git add Packages/KBLLM/Tests/KBLLMProvidersTests/AdapterPlumbingTests.swift`, then commit as
   `test(kbllm): pin the adapters' shared plumbing before it moves into the core`.
   **Run `swift test --package-path Packages/KBLLM` at this commit**: it is the pre-move evidence the brief asks for.
2. The move plus its tests: everything else under `Packages/KBLLM` (and this report), committed as
   `refactor(kbllm): one copy of the adapters' plumbing in the core, one Private Cloud Compute stand-in`.

## What changed

**F1.** New `Sources/KBLLM/AdapterPlumbing.swift`, all `package` access:

| helper | was | now called from |
|---|---|---|
| `package final class BodyPrefix` (512-byte tap) | `AnthropicModel.swift` (private), `OpenAIStreamParser.swift` (internal) | `AnthropicModel`, `OpenAIModel`, `OpenAIResponsesModel.drain` |
| `package func tapping(_:into:)` | same two files | same three drains |
| `AdapterPlumbing.redact(_:secret:)` | `AnthropicModel.swift`, `OpenAIModel+Request.swift` (Responses already called OpenAI's) | the three `.transport` catches |
| `AdapterPlumbing.composeEndpoint(base:suffix:)` | `AnthropicModel`, `OpenAIModel`, `OpenAIResponsesModel` | each passes its own `Self.pathSuffix` (`/v1/messages`, `/chat/completions`, `/responses`) |
| `CredentialStore.resolvedSecret(forKey:)` | five `do/catch` → `.missingCredential(key: credentialKey)` | `AnthropicModel`, `AnthropicModelList`, `OpenAIModel`, `OpenAIResponsesModel`, `OpenAIModelList` |
| `AdapterPlumbing.serialize(_:options:)` (always adds `.sortedKeys`) | `OpenAIModel+Request`, `OpenAIResponsesModel+Request`, `AnthropicModel+Request` | Chat Completions `[.sortedKeys]`; Responses `[.sortedKeys, .withoutEscapingSlashes]`; Anthropic `verbatim ? [.sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]`, each written at its call site exactly as before |

The adapters' copies are deleted. Each serializer call site keeps its policy comment. `OpenAIStreamParser.swift:107`'s
tool-argument re-serialization is a different thing and is untouched.

**F4.** `PrivateCloudComputeUnsupportedBackend` and `PrivateCloudComputeUnentitledBackend` are now one internal
`UnavailableFoundationModelBackend(reason:)` in `Sources/KBLLMApple/AppleModelBackends.swift`, outside any
`canImport` guard as before. `AppleModelBackends.privateCloudCompute(isSupported:isEntitled:)` passes
`unsupportedReason` ("Private Cloud Compute requires macOS 27 or later") or `unentitledReason` ("Private Cloud
Compute needs the com.apple.developer.private-cloud-compute entitlement"), both internal `static let`s with the
same strings as before.

## Copies that differed

None in behavior. The survey's pairs differ only in access level, and the Anthropic serializer took a
`WritingOptions` parameter where the OpenAI ones hard-coded theirs. That is a signature difference, settled by
passing each adapter's own options at its call site. Nothing needed reconciling and nothing was left unreconciled.

**One behavior change, reported as a deviation:** the core `serialize` checks `JSONSerialization.isValidJSONObject`
before writing. Foundation's documentation says writing an invalid object (a NaN or infinite number, a non-JSON value)
*raises an exception* instead of throwing, and Swift cannot catch that. On Darwin, then, the old `catch` probably
never ran for a NaN, and a NaN `temperature` would have crashed the host process. With the check it fails as
`.invalidRequest(field: "body", reason: "request body could not be serialized")`, which is what the old `catch`
was meant to do. A body that serialized before is a valid JSON object, so for it nothing changes. If the conductor's
pre-move run shows the NaN test *failing*, this is why; if it passes, Darwin already threw and the check adds
nothing.

## Tests

### Added before the move (`Tests/KBLLMProvidersTests/AdapterPlumbingTests.swift`; public API only, identical pre and post)

All of these go through each adapter's real `stream` / `listModels` path over the recording fake transport:

- **Tap:** a 700-byte plain-JSON 200 body gives `.decoding` whose fragment **equals the first 512 bytes**
  (and is 512 bytes long) on Anthropic, Chat Completions and Responses. A 40-byte body's fragment equals the whole body.
- **Redaction:** a foreign error `reset before <secret> after` → `underlying == "ForeignFailure: reset before
  [redacted] after"`. A nonempty secret that isn't in the message leaves it unchanged. An empty secret leaves
  it unchanged. All three adapters.
- **Credential:** a store with no secret → `.missingCredential(key:)` carrying each adapter's own distinct key,
  no events, `openCount == 0`. The same holds for `AnthropicModelList` and `OpenAIModelList`, with zero requests
  sent. An empty secret on Chat Completions and on Responses → the sent request has **no** header whose name
  lowercases to `authorization`.
- **Endpoint:** the URL the transport receives is exactly `base + suffix`: `http://localhost:8080/v1/messages`,
  `http://localhost:1234/v1/chat/completions`, `http://localhost:1234/v1/responses`. A trailing-slash base keeps
  the doubled slash (`http://localhost:8080//v1/messages`, `…/v1//chat/completions`, `…/v1//responses`). A
  malformed base `http://exa mple` → exactly `.invalidRequest(field: "baseURL", reason: "malformed base URL:
  http://exa mple")`, with the transport opened 0 times, on all three.
- **Serializer policies:** Chat Completions' body equals itself rewritten with `[.sortedKeys]` and contains
  `"a\/b"`. Responses' body equals itself rewritten with `[.sortedKeys, .withoutEscapingSlashes]` and contains
  `"a/b"`. On Anthropic, a plain request's body is `[.sortedKeys]` with `"a\/b"`, and a search request's is
  `[.sortedKeys, .withoutEscapingSlashes]` with `"a/b"`.
- **Serializer failure (adapter path, per the amendment):** Chat Completions with `GenerationOptions(temperature:
  .nan)` → `.invalidRequest(field: "body", reason: "request body could not be serialized")`, transport opened 0
  times. It runs as a Swift Testing **exit test** (`#expect(processExitsWith: .success)`, guarded `#if os(macOS) ||
  os(Linux)`). If Foundation raises, the child process dies and the test fails, and the rest of the suite keeps
  running. This uses the Swift 6.2 exit-test API (ST-0008). The generator could not compile it; if the toolchain
  rejects the macro, that is where to look.

Existing tests that already pinned the serializer policies (amendment 2): Anthropic sorted keys,
`PromptCachingTests.bodyKeysAreSorted`; Anthropic escaped vs verbatim slashes,
`WebSearchRequestTests.withoutSearchTheBodyCarriesNoSearchToolAndKeepsItsSerialization`; Responses
`encrypted_content` sent back as received, `OpenAIResponsesRequestTests` (parsed value, not raw bytes). No existing
test pinned Chat Completions' or Responses' raw key order and slash escaping. `eachWireKeepsItsSortedKeyAndSlashPolicy`
above is that pre-move test for all three wires.

**Pre-move pass:** NOT RUN by the generator (swift refused). The conductor's run at commit 1 above is the evidence.

### Added with the move

- `Tests/KBLLMTests/AdapterPlumbingCoreTests.swift` calls the core helpers directly: `BodyPrefix` (700 → first 512;
  short → whole); `tapping` forwards every byte unchanged, keeps the prefix and passes an upstream error through;
  `redact` (every occurrence; absent, empty and **nil** secret leave the text unchanged — an adapter can never produce
  nil); `composeEndpoint` (join, doubled slash, malformed base); `resolvedSecret` (secret returned, empty returned
  as is, a missing one → `.missingCredential(key:)`); `serialize` (always sorted, slash option honored, NaN and
  infinity → the `.invalidRequest` above).
- `Tests/KBLLMAppleTests/PCCEntitlementAppleTests.swift`, adapted: every factory branch now expects
  `UnavailableFoundationModelBackend` with its reason. New `theUnavailableStandInAnswersWithTheReasonItWasGiven`,
  parameterized over both reason strings, builds the stand-in **directly** on any runner and checks:
  `availability == .unavailable(reason:)`, empty `capabilities`, `quotaUsage == nil`, `contextSize() == nil`, and that
  `run` yields 0 chunks and finishes throwing `.unavailable(reason:)` with that same string, both directly and
  through `AppleModel`. New `theFactoryPassesEachDocumentedReason` pins the two strings.
  `LiveAppleSmokeTests:40` now checks `pcc is UnavailableFoundationModelBackend`.

## Gates

| gate | result |
|---|---|
| 1. `swift test --package-path Packages/KBLLM`, twice, final tree, nothing else building | **NOT RUN by generator** (swift refused). Conductor's. |
| Pre-move `swift test` at commit 1 | **NOT RUN by generator**. Conductor's. |
| 2. Six F1 searches, each 1 hit in `Sources`, that hit in `Sources/KBLLM` | **PASS** (searched with the Grep tool; the shell loop as written was refused for its variables). One hit each: `BodyPrefix` :13, `tapping(` :36, `composeEndpoint` :62, `redact(` :72, `could not be serialized` :89, `missingCredential(key: credentialKey)` :108, all in `Sources/KBLLM/AdapterPlumbing.swift` |
| 3. `resolvedSecret(forKey` in the five credential files | **PASS**: all five call it; the only other hit is its definition in the core |
| 3. F1 definitions in `KBLLMAnthropic` + `KBLLMOpenAI` | **PASS**: 0 |
| 3. Every survey site (2+2+2+3+5+3) now calls the core | **PASS** by reading `git diff 3042a89 -- Packages/KBLLM/Sources` (table above) |
| 4. `struct PrivateCloudCompute` in `Sources` | **PASS**: 0. `struct UnavailableFoundationModelBackend`: 1, in `Sources/KBLLMApple`, internal, `let reason: String` |
| 5. Public surface: `git diff 3042a89 -- Packages/KBLLM/Sources` adds or removes no line containing `public` | **PASS** (`git diff … \| grep '^[+-].*public'` → empty). The new untracked `AdapterPlumbing.swift` contains `public` only in a comment. The new members on public types (`AppleModelBackends.unsupportedReason` / `unentitledReason`, `CredentialStore.resolvedSecret`) are internal or `package`. |
| 5. `swift package diagnose-api-breaking-changes 3042a89` | **NOT RUN by generator**. Conductor's. |
| 6. Containment (tracked, untracked) | Changed: 10 files under `Packages/KBLLM/Sources`, 2 under `Packages/KBLLM/Tests`. New: `Packages/KBLLM/Sources/KBLLM/AdapterPlumbing.swift`, `Packages/KBLLM/Tests/KBLLMProvidersTests/AdapterPlumbingTests.swift`, `Packages/KBLLM/Tests/KBLLMTests/AdapterPlumbingCoreTests.swift`, and this report. Nothing else. |
| 7. Behavior tests present (`[redacted]`, `512`, `malformed base`, `missingCredential`, `could not be serialized` in `Tests`) | **PASS**: all in the new test files above |
| 9. Silverpoint `make build` against the changed package | **NOT RUN by generator**. Conductor's. No public declaration changed, so no Silverpoint call site can move. |

Source-scanning suites I checked by hand: `SourceContentTests` bans spellings (networking, clock/RNG, em dash) in
the core, the adapters and `KBLLMProvidersTests`. None of the new or changed files contains any of them, and the
core's import allowlist (Foundation) holds.

## Conductor's gate run (final tree 060bba4, one run, nothing else building)

The conductor committed the generator's work in two commits: `6d66199` (`test(kbllm)`, `AdapterPlumbingTests.swift` only, on the pre-move code) and `060bba4` (`refactor(kbllm)`, the move). Each gate below ran once on that tree; none was rerun.

| Gate | Result |
|---|---|
| Pre-move tests: `AdapterPlumbingTests` at `6d66199` (old code), in a temporary worktree | 12 of 13 pass. The thirteenth, `anUnserializableBodyIsInvalidRequestAndNothingOpens` (a NaN temperature), fails with the child exiting on `SIGABRT`: the old serializer crashes the process. This is the evidence for the one behavior change (see "Copies that differed"): the new core serializer returns `.invalidRequest` instead. |
| `swift test --package-path Packages/KBLLM`, run 1 | exit 0 (17 tests in 4 suites, 225 in 33, 75 in 18) |
| `swift test --package-path Packages/KBLLM`, run 2 | exit 0 (the same counts) |
| F1 searches (`final class BodyPrefix`, `func tapping\(`, `static func redact\(`, `static func composeEndpoint`, `missingCredential\(key: credentialKey\)`, `request body could not be serialized`) | each 1 definition in total, in the KBLLM core; 0 helper definitions left in the adapter modules |
| `resolvedSecret(forKey:)` callers | 5 files |
| F4 | `struct PrivateCloudCompute` stand-ins: 0; `struct UnavailableFoundationModelBackend`: 1 |
| Public API: `swift package diagnose-api-breaking-changes` against `3042a89` | The run from the KBKits repository failed: the command clones the package path as a repository, and `Packages/KBLLM` is not one. It was then run in a standalone repository whose first commit is `3042a89`'s `Packages/KBLLM` tree and whose working tree is `060bba4`'s: exit 0, "No breaking changes detected" in KBLLM, KBLLMAnthropic, KBLLMApple, KBLLMOpenAI, KBLLMRuntime, KBLLMTesting and KBLLMURLSession. |
| `public` in the diff since `3042a89` | 1 added line, a comment (`// the public surface does not grow.`); no declaration |
| Containment | 0 paths changed outside `Packages/KBLLM`, 0 untracked outside |
| Silverpoint `make build` against this tree (a temporary Silverpoint worktree at main with `KBKits` linked to this unit's worktree) | exit 0 |

## Item
F1 + F4 of Silverpoint's KBKits survey (BACKLOG 88 unit U1, F2 excluded — already landed as `3042a89`): the six copied plumbing helpers in KBLLM's HTTP adapters (`BodyPrefix`, `tapping`, `redact`, `composeEndpoint`, the credential fetch mapped onto `.missingCredential`, the sorted-keys serializer) move into the KBLLM core at `package` access and each adapter copy becomes a call; the two identical Private Cloud Compute stand-ins in KBLLMApple become one internal `UnavailableFoundationModelBackend(reason:)` with the factory passing the reason. Behavior-preserving; tests covering the moved behaviors added first where missing; no public API change; nothing outside `Packages/KBLLM` touched. Report at `.sparra/reports/kbkits-llm-adapter-plumbing-r1.md`.

## I will build
- **In scope — F1 move.** Into `Packages/KBLLM/Sources/KBLLM`, at `package` access (no `public`), definitions matching the brief's gate searches:
  - `BodyPrefix` (512-byte bounded tap) — replaces copies in `AnthropicModel.swift` + `OpenAIStreamParser.swift`.
  - `tapping(_:into:)` — same two copies.
  - `redact(_:secret:)` — copies in `AnthropicModel.swift` + `OpenAIModel+Request.swift`.
  - `composeEndpoint(base:suffix:)` — three copies (Anthropic, OpenAI, OpenAIResponses); call sites pass their `pathSuffix`.
  - `CredentialStore.resolvedSecret(forKey:)` wrapping the `do/catch → .missingCredential(key:)` — five sites (AnthropicModel, AnthropicModelList, OpenAIModel, OpenAIResponsesModel, OpenAIModelList) become calls.
  - sorted-keys serializer with the `.invalidRequest(field: "body", reason: "request body could not be serialized")` catch — three copies become calls to one core `serialize` that ALWAYS applies `.sortedKeys` and accepts extra `WritingOptions`; all three existing option policies preserved verbatim: Chat Completions `[.sortedKeys]` only, Responses always `+ .withoutEscapingSlashes`, Anthropic conditional (`verbatim ? [.sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]`). (`OpenAIStreamParser.swift:107`'s tool-args re-serialization is not this helper; untouched.)
  - Copies differing per the survey: reconciled only with a deciding test, else left and named in the report (survey: pairs identical but for access level and the Anthropic options parameter — signature-only, no behavioral conflict expected).
- **In scope — F4.** `PrivateCloudComputeUnsupportedBackend` + `PrivateCloudComputeUnentitledBackend` → one internal `UnavailableFoundationModelBackend(reason:)` in KBLLMApple, declared outside any `canImport` guard (as today); `AppleModelBackends.privateCloudCompute` passes the two existing reason strings verbatim. Existing tests referencing the removed types (`PCCEntitlementAppleTests`, `PCCAvailabilityAppleTests`, `LiveAppleSmokeTests:40`) adapted to the merged type + reason; the merged stand-in also tested DIRECTLY with both reasons (runner-independent — no factory `#available` gate needed).
- **In scope — tests first.** For each moved behavior lacking a test: add one pinning CURRENT behavior before the move —
  - tap: >512-byte ASCII body → fragment EQUALS its first 512 bytes; short body → fragment equals whole body verbatim;
  - redaction: `<prefix><secret><suffix>` → `<prefix>[redacted]<suffix>`; nonempty secret absent from text → unchanged; empty/nil secret → unchanged;
  - credential: store without the key → `.missingCredential(key:)` carrying the adapter's `credentialKey`, transport never opened; empty-string secret on an OpenAI-family adapter → request carries NO `Authorization` header (F2's rule);
  - endpoint: literal `base + suffix` concatenation pinned via the URL the fake transport receives, base with and without trailing slash (trailing-slash base → doubled slash preserved, no normalization); malformed base (`"http://exa mple"` per existing test) → `.invalidRequest(field: "baseURL")`, transport opened zero times;
  - serializer failure: unserializable body (e.g. non-finite double) → `.invalidRequest(field: "body", reason: "request body could not be serialized")`, via an adapter request path if reachable, else directly against the core helper post-move (report says which).
  Report records which tests were added and that they passed pre-move.
- **In scope — report** at `.sparra/reports/kbkits-llm-adapter-plumbing-r1.md`: each gate + result, tests added pre-move + their pre-move pass, unreconciled copies if any (conductor commits it if my commit is refused).
- **Out of scope:** F2 (done, `3042a89`), F3/U2, U3/U4; any change outside `Packages/KBLLM` (plus the report); any Silverpoint edit; any `public` addition. Git history shape (commit granularity/ordering) is harness/process-owned — report records it, contract does not gate on it.

## I will verify by
All from the graded worktree's repo root. Baseline commit = `3042a89` (HEAD at item start). **Judge-env note:** `swiftc` probe returned `permissionDenied`, so every swift invocation (gates 1 and the API diagnostic in 5, plus 9) is the CONDUCTOR's single consolidated gate, evidenced in the report; gates 2–8 are judge-run statically as written.

1. Conductor gate — suite: `swift test --package-path Packages/KBLLM; rc=$?; test "$rc" -eq 0` — ONE scheduled pair of consecutive foreground runs on the same final tree, nothing else building; both exit 0; a failure is recorded, never rerun on unchanged content. Results in the report.
2. F1 searches — per pattern P in {`final class BodyPrefix`, `func tapping\(`, `static func redact\(`, `static func composeEndpoint`, `missingCredential\(key: credentialKey\)`, `request body could not be serialized`}:
   `test "$(rg 'P' Packages/KBLLM/Sources | wc -l)" -eq 1 && test "$(rg 'P' Packages/KBLLM/Sources/KBLLM | wc -l)" -eq 1` (count 1 overall AND that 1 inside the core module).
3. Adapters call, not copy:
   - `test "$(rg -l 'resolvedSecret\(forKey' Packages/KBLLM/Sources/KBLLMAnthropic/AnthropicModel.swift Packages/KBLLM/Sources/KBLLMAnthropic/AnthropicModelList.swift Packages/KBLLM/Sources/KBLLMOpenAI/OpenAIModel.swift Packages/KBLLM/Sources/KBLLMOpenAI/OpenAIResponsesModel.swift Packages/KBLLM/Sources/KBLLMOpenAI/OpenAIModelList.swift | wc -l)" -eq 5`
   - `test "$(rg 'final class BodyPrefix|func tapping\(|static func redact\(|static func composeEndpoint|request body could not be serialized' Packages/KBLLM/Sources/KBLLMAnthropic Packages/KBLLM/Sources/KBLLMOpenAI | wc -l)" -eq 0`
   - read `git diff 3042a89 -- Packages/KBLLM/Sources` and confirm EVERY survey-enumerated site (2× BodyPrefix, 2× tapping, 2× redact, 3× composeEndpoint, 5× credential do/catch, 3× serializer) now calls the core helper.
4. F4: `test "$(rg 'struct PrivateCloudCompute' Packages/KBLLM/Sources | wc -l)" -eq 0`; `test "$(rg 'struct UnavailableFoundationModelBackend' Packages/KBLLM/Sources | wc -l)" -eq 1` (in `Sources/KBLLMApple`, not `public`, reason as parameter); read the adapted KBLLMAppleTests to confirm the direct both-reasons test and factory coverage per assertion 6.
5. Public surface unchanged vs baseline (complete before/after comparison, new files included):
   - `git grep -hE 'public (struct|class|enum|actor|protocol|func|var|let|init|typealias|extension|subscript)' 3042a89 -- Packages/KBLLM/Sources | sort > /tmp/kbllm-pub-before`
   - `rg -IN 'public (struct|class|enum|actor|protocol|func|var|let|init|typealias|extension|subscript)' Packages/KBLLM/Sources | sort > /tmp/kbllm-pub-after`
   - `diff /tmp/kbllm-pub-before /tmp/kbllm-pub-after; rc=$?; test "$rc" -eq 0`
   - Conductor-side diagnostic, if it runs: `swift package --package-path Packages/KBLLM diagnose-api-breaking-changes 3042a89` → no breakage; result in report.
6. Containment (tracked + untracked, `.sparra/` narrowed):
   - `test "$(git diff --name-only 3042a89 | rg -v '^(Packages/KBLLM/|\.sparra/)' | wc -l)" -eq 0`
   - `test "$(git diff --name-only 3042a89 -- .sparra | rg -v '^\.sparra/(reports/kbkits-llm-adapter-plumbing-r1\.md$|contracts/)' | wc -l)" -eq 0` (harness-owned contract files exempt; my only `.sparra/` write is the report)
   - `test "$(git ls-files --others --exclude-standard | rg -v '^(Packages/KBLLM/|\.sparra/)' | wc -l)" -eq 0`
7. Behavior tests present: locate via `rg -n '\[redacted\]' Packages/KBLLM/Tests`, `rg -n '512' Packages/KBLLM/Tests`, `rg -n 'malformed base' Packages/KBLLM/Tests`, `rg -n 'missingCredential' Packages/KBLLM/Tests`, `rg -n 'could not be serialized' Packages/KBLLM/Tests` (each ≥1 hit); read the hit tests to confirm they pin the concrete expectations in assertions 7–10 and 15.
8. Report: `test -f .sparra/reports/kbkits-llm-adapter-plumbing-r1.md` and it names every gate with a result.
9. Conductor-owned (consolidated, not judge-run from the worktree): Silverpoint `make build` against the changed package still succeeds.

## Assertions
1. Conductor-run: `swift test --package-path Packages/KBLLM` exits 0 on one scheduled pair of consecutive foreground runs on the final tree, nothing else building, no retry (a failure recorded, never rerun on unchanged content); the pair's results appear in the report (judge evidence: report + committed test sources, since the judge env denies swift).
2. Each of the six F1 search patterns (verify 2) matches exactly one definition, and that definition lies under `Packages/KBLLM/Sources/KBLLM/` (paired counts, no placeholder command).
3. The moved helpers carry `package` (or tighter) access; the full public-declaration surface of `Packages/KBLLM/Sources` is line-identical to `3042a89` (verify 5 before/after `diff` exits 0 — catches additions, removals, and signature changes, new files included); `swift package --package-path Packages/KBLLM diagnose-api-breaking-changes 3042a89`, if it runs for the conductor, reports no breaking change.
4. All five credential files (verify 3 list) call `resolvedSecret(forKey`; the adapter modules contain ZERO F1-helper definitions (verify 3 count = 0); the diff shows every survey-enumerated site (2+2+2+3+5+3) became a call to the core helper.
5. `rg 'struct PrivateCloudCompute' Packages/KBLLM/Sources` → 0 hits; `struct UnavailableFoundationModelBackend` defined exactly once, in `Sources/KBLLMApple`, not `public`, taking the reason as a parameter.
6. KBLLMAppleTests exercises the merged stand-in DIRECTLY for EACH of the two reason strings ("Private Cloud Compute requires macOS 27 or later"; "Private Cloud Compute needs the com.apple.developer.private-cloud-compute entitlement"): `availability == .unavailable(reason: <that exact string>)`, `capabilities` empty, `quotaUsage == nil`, `contextSize()` nil, and `run(_:)` yields no chunks and finishes throwing `.unavailable(reason: <that same string>)` (two distinct reasons → reason-dependence shown, runner-independent); plus `privateCloudCompute(isSupported: false, …)` returns the merged stand-in with the macOS-27 reason, and the existing runtime-gated entitlement-branch tests are adapted to the merged type, all green in assertion 1.
7. A test feeds the 2xx-no-usable-event path a body **longer than 512 bytes** and asserts the diagnostic fragment EQUALS the body's first 512 bytes, plus a shorter body whose fragment equals the whole body verbatim (degenerate pass-through or mere cap can't satisfy both).
8. A redaction test uses text `<prefix><secret><suffix>` → result equals `<prefix>[redacted]<suffix>` (surrounding text preserved, secret absent); a nonempty secret NOT contained in the text → text unchanged; empty/nil secret → text unchanged.
9. A credential-edge test: a store with no secret for the key → `.missingCredential(key:)` carrying the adapter's `credentialKey`, transport never opened; an empty-string secret on an OpenAI-family adapter → the built request carries NO `Authorization` header (concrete F2 rule, not "documented rule").
10. Endpoint-join tests pin literal concatenation via the URL the fake transport receives: base without trailing slash → exactly `base + suffix`; base WITH trailing slash → the doubled-slash URL (no normalization); malformed base (`"http://exa mple"`) → `.invalidRequest(field: "baseURL")` with the transport opened zero times — positive compose + negative reject both present.
11. Any copy whose behavior differed and was reconciled has a test deciding the behavior; any left unreconciled is named in the report; if neither case arose the report says so.
12. Containment holds for tracked AND untracked files: all three verify-6 checks → 0 (nothing outside `Packages/KBLLM/` except the named report; harness contract files exempt).
13. `.sparra/reports/kbkits-llm-adapter-plumbing-r1.md` exists on the graded tree and lists each gate (suite pair, six searches, public-surface check + optional API diagnostic, F4 merge, Silverpoint `make build`) with its result, which tests were added pre-move and that they passed pre-move, including any gate not run and why.
14. Conductor-owned: Silverpoint `make build` succeeds against the changed package (recorded in the report; not a worktree-judge command).
15. The three serialization call sites keep their option policies verbatim in the diff — Chat Completions `[.sortedKeys]` only, Responses always `+ .withoutEscapingSlashes`, Anthropic `verbatim`-conditional — passed to the single core serializer that always applies `.sortedKeys`; and a test drives an unserializable body to `.invalidRequest(field: "body", reason: "request body could not be serialized")` (adapter path if reachable, else the core helper directly; report says which).

Changes: verify 5 + assertion 3 replaced added-`public`-grep with full before/after public-surface diff and dropped `cd &&` (critique 1); scope serializer bullet rewritten to all three policies + failure-test added to tests-first, new assertion 15 (critique 2); assertion 7 "capped" → "equals first 512 bytes", assertion 8 gains surrounding-text + absent-secret cases (critique 3); assertions 9–10 "current documented rule"/"current concatenation behavior" replaced with concrete no-Authorization-header and literal-concatenation/doubled-slash/zero-opens expectations (critique 4); verify 4 + assertion 6 replaced string-grep/suite-presence evidence with direct both-reasons tests of the merged type (availability, empty capabilities, nil quota/context, throwing run) + adapted existing tests (critique 5); verify 2's `rg -l <same pattern>` placeholder CUT, verify 3 widened to five named files + zero-definition count + full diff review, verify 6/assertion 12 narrowed `.sparra/` to report (+harness contracts) and added untracked check (critique 6); verify 1/assertion 1 rephrased as one scheduled consecutive pair, failure recorded not rerun, and swift invocations consolidated into conductor gates per the judge-env permissionDenied (critique 7 + probe note). none dropped otherwise.

CONTRACT: AGREED

## Amendment (conductor, after critique round 2; overrides the steps it names)

1. **Public API (verify 5, assertion 3).** The regex comparison is withdrawn as a "complete surface comparison". The
   evidence is the compiler's: the conductor runs `swift package --package-path Packages/KBLLM
   diagnose-api-breaking-changes 3042a89` on the final tree and records its full output in the report (it must report no
   breaking change); and the grader reviews `git diff 3042a89 -- Packages/KBLLM/Sources` for any `public` declaration
   added, removed or changed in any form (static members, protocol requirements, members of public extensions, multiline
   signatures, new files). If the diagnostic cannot run, the report says why and the diff review stands alone.
2. **Serializer coverage before the move (scope, assertion 15).** The serialization-failure test is written and run
   BEFORE the extraction, through an adapter's request path: Chat Completions' request builder forwards
   `options.temperature` into the body, so a non-finite temperature (`.nan`) drives it to
   `.invalidRequest(field: "body", reason: "request body could not be serialized")`. The report names the existing tests
   that pin each adapter's sorted-key and slash policy, and any of the three policies without one gets a test before the
   move too. Where the generator's environment denies running them, the conductor's pre-move run (at the test-only
   commit) is the evidence.
3. **Containment of untracked files (verify 6, assertion 12).** The untracked check uses the same narrowing as the tracked
   one: `test "$(git ls-files --others --exclude-standard | rg -v '^(Packages/KBLLM/|\.sparra/(reports/kbkits-llm-adapter-plumbing-r1\.md$|contracts/))' | wc -l)" -eq 0`.
4. **The six searches (verify 2).** As one executable loop:
   `for p in 'final class BodyPrefix' 'func tapping\(' 'static func redact\(' 'static func composeEndpoint' 'missingCredential\(key: credentialKey\)' 'request body could not be serialized'; do all=$(rg -c -- "$p" Packages/KBLLM/Sources | awk -F: '{s+=$NF} END {print s+0}'); core=$(rg -c -- "$p" Packages/KBLLM/Sources/KBLLM | awk -F: '{s+=$NF} END {print s+0}'); echo "$p: $all total, $core in the core"; test "$all" -eq 1 && test "$core" -eq 1 || exit 1; done`

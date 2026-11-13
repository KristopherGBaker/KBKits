## Item
Dedupe the resume-once continuation latch in `Packages/KBMCPServer/Sources/KBMCPServer/MCPHTTPServer.swift` (Silverpoint survey F10 / unit U4): one private helper producing the `Mutex<Bool>`+closure latch, called from both `start(port:)` (lines ~60–68 today) and `stopAndWait()` (~110–117). Behavior identical: continuation resumes exactly once with the first value, later callbacks are no-ops. Add once-only lifecycle tests first (rule currently has no dedicated test; it IS reachable via public `start`/`stop` + `@testable` `stopAndWait`), show them passing pre-change. Report at `.sparra/reports/kbkits-mcpserver-resume-once-r1.md`.

## I will build
- In: one private helper in `MCPHTTPServer.swift` returning the resume-once closure for a `CheckedContinuation`; both inline latch copies replaced by calls to it; no other logic change.
- In: new test suite `ResumeOnceTests` in `Packages/KBMCPServer/Tests/KBMCPServerTests/ResumeOnceTests.swift` with two tests:
  - `startLatchIgnoresLaterCallbacks`: `start(port: 0)` → `.running(port≠0)`; `stop()` drives `.cancelled` into the same `stateUpdateHandler` (second latch fire); then poll until the port refuses connections (existing `refusesConnections`-style helper) and a fresh `start(port: 0)` on a new server returns `.running` — no crash, no double resume.
  - `stopAndWaitLatchSurvivesFallbackTimer`: start, `await stopAndWait()` (returns via `.cancelled`), then `Task.sleep(for: .seconds(2.3))` so the 2 s `asyncAfter` fallback fires into the exhausted latch — process alive, test passes.
  - Both written against the CURRENT code and passing before the refactor; pre-change run recorded in the report.
- In: report `.sparra/reports/kbkits-mcpserver-resume-once-r1.md` listing each gate and its result (test runs ×2, rg search, pre-change test evidence), noting Silverpoint `make build` is conductor-run.
- Out: any change outside `Packages/KBMCPServer` (except the report file); any public API change (helper is `private`); Silverpoint-side work; `kbkits-llm-*` units (KBLLM only); git/commit state (harness-owned — worktree content only here).

## I will verify by
From the KBKits worktree root:
1. `swift test --package-path Packages/KBMCPServer` — run twice back-to-back on the final tree; each prints a passed test summary, exits 0, zero failures.
2. `swift test --package-path Packages/KBMCPServer --filter ResumeOnceTests` — exits 0, executes 2 tests, both pass.
3. `n=$(rg -t swift 'let resumeOnce' Packages/KBMCPServer/Sources | wc -l); test "$n" -le 1` — exits 0 (≤1 definition; if the helper uses another name, that name has exactly 1 definition and exactly 2 call sites in `MCPHTTPServer.swift`, checked by reading the file).
4. `n=$(rg -t swift 'Mutex(<Bool>)?\(false\)' Packages/KBMCPServer/Sources | wc -l); test "$n" -eq 1` — exits 0 (the latch's fresh-`Mutex(false)` construction exists exactly once, in `MCPHTTPServer.swift`'s helper; the duplicated copies are gone).
5. `n=$(rg -c '^ *public ' Packages/KBMCPServer/Sources/KBMCPServer/MCPHTTPServer.swift); test "$n" -eq 6` — exits 0; reading the file confirms the 6 public declarations are exactly today's (`class MCPHTTPServer`, `enum State`, `defaultConnectionTimeout`, `init`, `start(port:)`, `stop()`), and the helper is declared `private`.
6. Read `.sparra/reports/kbkits-mcpserver-resume-once-r1.md`: present, lists each gate with its result, records the pre-change `ResumeOnceTests` pass.
7. Conductor-owned, not asserted here: Silverpoint `make build` against the changed package; single no-retry gate run.

## Assertions
1. `MCPHTTPServer.swift` contains exactly one private helper that constructs the resume-once latch (fresh `Mutex` guard + `@Sendable` closure); `start(port:)` and `stopAndWait()` each obtain their latch closure from it; neither contains an inline latch body anymore.
2. `n=$(rg -t swift 'Mutex(<Bool>)?\(false\)' Packages/KBMCPServer/Sources | wc -l); test "$n" -eq 1` exits 0, and the single hit is in `MCPHTTPServer.swift`.
3. `n=$(rg -t swift 'let resumeOnce' Packages/KBMCPServer/Sources | wc -l); test "$n" -le 1` exits 0; if another helper name is used, it appears at exactly 1 definition and 2 call sites in `MCPHTTPServer.swift`.
4. `swift test --package-path Packages/KBMCPServer` on the final tree exits 0 with zero test failures, twice consecutively on the same tree.
5. `ResumeOnceTests.startLatchIgnoresLaterCallbacks` exists, drives `.ready` then `.cancelled` through one `start` latch via public `start(port: 0)` + `stop()`, and asserts the port refuses connections and a subsequent fresh `start(port: 0)` returns `.running` — passes under `swift test --package-path Packages/KBMCPServer --filter ResumeOnceTests`.
6. `ResumeOnceTests.stopAndWaitLatchSurvivesFallbackTimer` exists, calls `stopAndWait()` (internal, via `@testable import KBMCPServer`), then sleeps ≥2.3 s so the fallback timer fires after the `.cancelled` resume, and passes (no double-resume crash) under the same filter command.
7. Both `ResumeOnceTests` tests were runnable and passing on the pre-refactor code; the report records that pre-change run (command + result).
8. `n=$(rg -c '^ *public ' Packages/KBMCPServer/Sources/KBMCPServer/MCPHTTPServer.swift); test "$n" -eq 6` exits 0, and the public declarations in that file are name-for-name today's six (no public API added, removed, or renamed); the new helper carries `private`.
9. No source or manifest file outside `Packages/KBMCPServer` contains the new helper's name or any change from this item; the only non-package artifact is `.sparra/reports/kbkits-mcpserver-resume-once-r1.md`.
10. `.sparra/reports/kbkits-mcpserver-resume-once-r1.md` exists in the worktree and lists each brief gate (`swift test` ×2, the `rg` search, pre-change test evidence) with its result, and notes Silverpoint `make build` as conductor-run.

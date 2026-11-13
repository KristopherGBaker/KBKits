1. **Fix the test claims.** `LoopbackTests.stopRefusesNewConnections` already exercises start→stop. A fresh server does not prove anything further about the old latch, and sleeping 2.3 seconds proves neither callback order nor fallback execution. Require observable completion if retaining those claims; otherwise use the brief’s permitted private/unreachable explanation and lifecycle-suite fallback.

2. **CUT incidental spelling/count gates:** verification 4–5 and assertions 2/8. Exact `Mutex(false)` spelling and six `public` lines are brittle proxies. Inspect that one private generic helper owns the latch, both consumers call it, and public signatures remain unchanged.

3. **Repair the definition search.** `≤1` permits zero definitions without requiring the alternative check. State explicit alternatives: one latch definition, **or** no inline definitions plus one helper definition and two calls. Keep this check once, without duplicating it across sections.

4. **Make gate discipline explicit.** Require the two final full-suite runs consecutively, in the foreground, with nothing else building; record failures without retrying the same tree. Fold any added tests into those runs instead of mandating another final filtered run. Preserve genuine pre-refactor evidence for any new regression tests.

5. **Narrow assertion 9 to attributable changes.** CUT the requirement that unrelated source contain no occurrence of the helper’s name. Require this item’s changes to stay within `Packages/KBMCPServer`, except its report.

The shell snippets executed; the public-declaration count currently passes. Swift execution was blocked by `swiftc -print-target-info` returning `error: permissionDenied`; neither suite execution nor the proposed filter is confirmed runnable here.

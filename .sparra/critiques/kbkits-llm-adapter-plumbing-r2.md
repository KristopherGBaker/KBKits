Round 1 points 3, 4, 5, and 7 are resolved. Points 1, 2, and 6 remain partially unresolved.

1. **Replace verify 5’s incomplete API fallback.** Its regex misses shipped `public static func` declarations, protocol requirements, implicit-public extension members, and multiline signatures. CUT the claim that this is a complete surface comparison. Require compiler evidence, or complete source-diff review against `3042a89`, including new files and those declaration forms. Use judge-readable evidence; the proposed `/tmp` redirections require denied writes.

2. **Finish the serializer coverage requirement.** The three option policies are now correct, but the contract still permits the failure test only after extraction. Require missing coverage before the move, including serialization failure; OpenAI’s request builder currently forwards `options.temperature` into the serialized body, providing a candidate non-finite-value fixture. Identify existing sorted-key/slash-policy tests and add missing coverage before extraction. Preserve the environment-blocked classification where execution is denied.

3. **Finish containment for untracked files.** Verify 6’s untracked check still exempts everything under `.sparra/`. Apply the named-report restriction to task-authored untracked files too, with the harness-owned contracts exemption. Assertion 12 currently claims stronger containment than its checks establish.

4. **Replace verify 2’s remaining placeholder.** `rg 'P'` searches the literal letter `P`; the displayed command executed and exited 1. Supply an executable loop using the actual six patterns and variable expansion, with both required counts checked for each pattern. This completes Round 1’s runnable-command correction.

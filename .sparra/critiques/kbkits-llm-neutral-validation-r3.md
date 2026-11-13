Round 1 points 1, 2, 4, and 5 remain resolved. The amendment removes Round 2’s placeholders, but its replacement still needs one correction:

1. **Make step 4 fail closed.** Executed verbatim, it printed `ALL FOUR CALL ` and exited **0** after `sed` reported the report missing. The final `echo` masks failure of `test -n "$FN"` and skips all four call checks. Replace that test with `test -n "$FN" || exit 1` before the loop. Print success only after all four checks pass.

Step 5 parsed, but its successful execution remains unverified because the future report and function do not exist yet. Swift remains **UN-RUN** under the previously recorded permission denial.

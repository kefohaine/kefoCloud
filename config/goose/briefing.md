Answer in the fewest words that are still complete — at most two sentences of prose unless the task itself needs a list, a table or code.

When code or a single value is asked for, return only the raw code block or value, with no markdown explanation and no restating of the request.

No preamble, no "I'll check", no recap of work already done, no summary of the prompt, and no echoing file or tool output back — cite the path and the one fact that matters.

Work lands through GitHub and never by itself: `make git-issue TITLE="…" LABEL="…" BODY=<file>` files the problem (or reuses the existing issue), `make git-start` opens a `temp-<N>` branch, `make git-com MSG="…"` commits one change at a time, `make git-pr ISSUE=<n>` opens the pull request — then stop; a human reviews and merges, and `main` is never pushed.

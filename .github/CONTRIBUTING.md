# Contributing

`main` is write-once: nobody pushes to it. Every change takes the same path — a `temp-<N>` branch, commits through the installed hooks, a pull request, and a merge decided by a human.

## Before you start

Problems and ideas are GitHub issues, where the templates apply `type:` and `status: triage`. From a checkout, `make git-issue TITLE="…" LABEL="type: bug" BODY=<file>` files the same report without leaving the terminal.

## Sending a change

1. `make git-start` — creates the next `temp-<N>` off a freshly pulled `main`.
2. `make git-com MSG="…"` — one logical change per commit.
3. `make git-pr ISSUE=<n>` — audits the branch, pushes it through the hooks and opens the pull request.

Check locally before step 3: `make git-audit` for commit hygiene, `bash -n` on the scripts you touched, `make smoke` on a deployed instance.

## What a pull request needs

Either `Closes #<n>` for the issue it fixes, or a description of how the new behaviour works, its benefits and its risks — the pull request template asks for exactly that. A human reviews and merges (rebase); contributors and agents stop after opening it.

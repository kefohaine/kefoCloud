# Contributing

Thanks for considering a contribution!

`main` is write-once: it is never pushed to directly, by anyone. Every change
arrives as a branch named `work-<N>` (work-1, work-2, …), is pushed through the
installed hooks, and is merged only through a pull request a human operator
reviews. Issues live in the repository's Issues tab — they are created, labelled
and closed there (or through the GitHub API), never in a markdown file.

## Reporting bugs
Open an issue with the Bug report template (it applies `type: bug` and
`status: triage`): steps to reproduce, what you expected, and what happened.

## Proposing changes
Open an issue first — the Feature request template applies `type: feature` and
`status: triage`, and asks for how it would work, its benefits and its risks.

## Submitting a pull request
1. `make git-start` — creates and switches to the next `work-<N>` off a freshly pulled `main`.
2. Make your changes, committing one change per commit (`make git-com MSG="…"`; `make git-audit` checks it).
3. Test them (`make smoke` on a deployed instance, `bash -n` on the scripts you touched).
4. `make git-pr` — audits the branch, pushes it through the hooks, and opens the
   pull request (with an authenticated `gh`) or prints the compare URL plus the
   pull request body. Use `make git-pr ISSUE=<n>` when the change fixes an issue.
5. The pull request must either close that issue (`Closes #<n>`) or state how
   the feature works, its benefits and its risks.

A pull request that pushes `main`, or that neither links an issue nor explains a
feature, is closed rather than merged. A human makes the merge decision; an
agent or contributor stops after opening the PR. Every significant commit
carries its `Revert:` line (see `docs/AGENTS.md` rule 10).

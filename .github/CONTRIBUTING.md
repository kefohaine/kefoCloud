# Contributing

Thanks for considering a contribution!

`main` is write-once: it is never pushed to directly, by anyone. Every change
arrives as a branch named `work-<N>` (work-1, work-2, …) and is merged only
through a pull request a human operator reviews.

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
4. `make git-pr` — audits the branch, pushes it and prints the compare URL plus the pull request body.
5. Open the pull request on GitHub and fill it in. It must either close an issue
   (`Closes #<n>`) or state how the feature works, its benefits and its risks.

A pull request that pushes `main`, or that neither links an issue nor explains a
feature, is closed rather than merged. Every significant commit carries its
`Revert:` line (see `docs/AGENTS.md` rule 10).

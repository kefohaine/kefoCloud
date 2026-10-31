<!--
Pick ONE shape and delete the other. A pull request is accepted only if it
either closes an issue from the Issues tab, or adds a new feature explained
with how it works, its benefits and its risks. `main` is never pushed to
directly: every change arrives here as a temp-<N> branch, and a human operator
reviews and merges it.
-->

## Shape A — this fixes an issue

Closes #<!-- issue number: the link GitHub renders between this PR and the issue -->

### What changed
<!-- one bullet per commit — `git log --oneline main..HEAD` -->

### Why
<!-- the behaviour being fixed, and how to reproduce it -->

## Shape B — this adds a feature

### What changed
<!-- one bullet per commit -->

### How it works
<!-- which files implement it, and how an operator uses it -->

### Benefits
<!-- what this makes possible or safer -->

### Risks
<!-- what can break, the blast radius, and the revert recipe -->

## Verification
<!-- the commands you ran and their verdict: make smoke, make git-audit, bash -n, a dry run -->

- [ ] one change per commit (`make git-audit` is clean)
- [ ] every significant commit carries its `Revert:` line
- [ ] docs updated to match (GUIDE / README as applicable)

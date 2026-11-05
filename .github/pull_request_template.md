<!--
Pick ONE shape and delete the other. A pull request is accepted only if it
either closes an issue from the Issues tab, or adds a new feature explained
with how it works, its benefits and its risks. `main` is never pushed to
directly: every change arrives here as a temp-<N> branch, and a human operator
reviews and merges it.
-->

## Issues this pull request closes

<!-- One row per issue, `Closes #<n>` plus a link to the section that fixes it.
     Every closing reference lives in this table and nowhere else: a section
     can then be rewritten without silently dropping a link, and the merge
     closes the issue automatically. -->

| Issue | Fixed by |
|---|---|
| Closes #<!-- n --> — <!-- title --> | [§<!-- n --> <!-- section name -->](#<!-- anchor -->) |

## Shape A — this fixes an issue

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
<!-- what can break and its blast radius -->

## Verification
<!-- the commands you ran and their verdict: make smoke, make git-audit, bash -n, a dry run -->

- [ ] commits within the ten-file limit (`make git-audit` is clean)
- [ ] docs updated to match (WHAT / MANUAL / README as applicable)

## Revert
<!-- one recipe for the whole pull request, appended by `make git-pr` as a
     fenced ```bash block so the tracker renders a copy button beside it -->

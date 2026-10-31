# Issue seed manifest

The repository's Issues tab is the **only** tracker: an open problem and its
resolution live on the issue, never in a markdown file. `import.jsonl` is the
one-time seed for the initial issue set — one JSON object per line
(`{"title", "labels", "body"}`) — and is not edited after that import. Once an
issue exists on GitHub, GitHub owns it.

## Importing (operator, once)

`make git-import-issues` does both halves in one idempotent pass:
`scripts/ops/import-issues.sh` creates every label from `.github/labels.yml`
(an existing label is updated to the manifest's colour and description) and
opens the issues from `import.jsonl` that no issue — open or closed — already
carries by title. Re-running adds only what is missing. `ARGS=--dry-run` prints
what it would do without writing.

It needs one credential: `gh auth login` first (the installer's package set
includes `gh`, and the script calls it through `gh api`), or `GITHUB_TOKEN`/
`GH_TOKEN` with `Issues: read and write` + `Metadata: read`). GitHub's native
`good first issue` and `help wanted` labels are left as they are.

Without a checkout at hand, the same import can be done by hand: labels from
Settings → Labels, then the issues from the manifest, one per line.

## After the import

- New work is filed with the templates in `.github/ISSUE_TEMPLATE/`, which apply
  `type:` and `status: triage` automatically.
- The CLI path is `make git-issue TITLE="…" LABEL="type: bug,…" BODY=<file>`:
  it validates the labels against `.github/labels.yml`, requires a `type:`, adds
  `status: triage`, refuses a title that already exists, and prints the
  new-issue URL when no credential is available.
- An agent manages issues through that recipe or the Issues tab — never by
  appending to `import.jsonl`, which is a seed and not a queue.
- A pull request closes an issue with `Closes #<n>` in its body
  (`make git-pr ISSUE=<n>` writes it); GitHub links the pair and closes the
  issue when a human merges the PR.

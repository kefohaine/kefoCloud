# Issue seed manifest

The repository's Issues tab is the **only** tracker: an open problem and its
resolution live on the issue, never in a markdown file. `import.jsonl` is the
one-time seed for the initial issue set — one JSON object per line
(`{"title", "labels", "body"}`) — and is not edited after that import. Once an
issue exists on GitHub, GitHub owns it.

## Importing (operator, once)

Labels first, or every issue lands unlabelled:

1. Settings → Labels → New label, one row per entry in `.github/labels.yml`
   (name, colour, description verbatim). Keep GitHub's native `good first issue`
   and `help wanted` as they are.
2. With a token that has `Issues: read and write` and `Metadata: read` on this
   repository, run `scripts/ops/import-issues.sh` (`--dry-run` first). Without a
   token, create the issues from the manifest in the GitHub UI, one per line.

## After the import

- New work is filed with the templates in `.github/ISSUE_TEMPLATE/`, which apply
  `type:` and `status: triage` automatically.
- The CLI path is `make git-issue TITLE="…" LABEL="type: bug,…" BODY=<file>`:
  it validates the labels against `.github/labels.yml`, requires a `type:`, adds
  `status: triage`, refuses a title that already exists, and prints the
  new-issue URL when `gh` is absent.
- An agent manages issues through that recipe or the Issues tab — never by
  appending to `import.jsonl`, which is a seed and not a queue.
- A pull request closes an issue with `Closes #<n>` in its body
  (`make git-pr ISSUE=<n>` writes it); GitHub links the pair and closes the
  issue when a human merges the PR.

# Issue-tracker migration manifest

`docs/ISSUES.md` used to be the tracker. It is now the **frozen archive**: every
item still open at migration time lives here as one line of `import.jsonl`, and
everything resolved before it stays in `docs/ISSUES.md` under `## Solved`.

`import.jsonl` is one JSON object per line — `{"title", "labels", "body"}` — and
is the source the Issues tab is populated from. It is a record of the migration,
not a permission store: once an issue exists on GitHub, GitHub is the tracker and
this file is not edited again.

## Importing (operator, once)

Labels first, or every issue lands unlabelled:

1. Settings → Labels → New label, one row per entry in `.github/labels.yml`
   (name, colour, description verbatim). Keep GitHub's native `good first issue`
   and `help wanted` as they are.
2. Create the issues from `import.jsonl`. Without a token on this host the
   practical path is GitHub's own UI, one issue per line; with the `gh` CLI on
   another machine: `while read -r j; do echo "$j" | jq -r .title; done < import.jsonl`
   to check the order, then create each one with its title, labels and body.
3. Close nothing by hand: the three items that were already resolved when this
   file was written are in `docs/ISSUES.md`'s Solved list, not here.

## After the import

- New work is filed with the templates in `.github/ISSUE_TEMPLATE/`, which apply
  `type:` and `status: triage` automatically.
- A pull request closes an issue with `Closes #<n>` in its body (rule 30); the
  issue then closes when the PR is merged, and GitHub links the two.
- Do not re-open `docs/ISSUES.md` as a tracker. A new problem goes to the Issues
  tab; the archive only gains a Solved line when a frozen entry is genuinely
  re-fixed later.

# Contributing

Anyone can contribute, with or without write access here. Work on a branch — in your own fork, or in this clone — and open a pull request against `main`. Where the branch lives is irrelevant; `main` is write-once and changes only through a merged pull request.

## From your own fork

1. Fork on GitHub and clone the fork.
2. Branch off `main` — any name you like (`git switch -c fix/the-thing`).
3. Commit one logical change per commit, authored as your GitHub identity (`<id>+<login>@users.noreply.github.com`; set `git config user.useConfigOnly true` so git never invents one).
4. Push the branch to your fork and open the pull request against `kefohaine/kefoCloud:main`.

## From this clone

`make git-start` creates the next `temp-<N>` branch off a freshly pulled `main`, `make git-com MSG="…"` commits, `make git-pr ISSUE=<n>` pushes and opens the pull request. The `temp-<N>` name is a convenience of these recipes — it means nothing in the history, and any branch name works just as well.

## Before you open it

The same checks run for everyone: `.github/workflows/validate.yml` runs `bash -n` over the shell scripts, `scripts/info/prose-audit.sh` and `scripts/info/git-audit.sh origin/main..HEAD` on every pull request and on every push to a branch of this repository — run those two scripts yourself if you want to know first. `make smoke` on a deployed instance when the change touches a module.

## What a pull request needs

Either `Closes #<n>` for the issue it fixes, or a description of how the new behaviour works, its benefits and its risks — the pull request template asks for exactly that. A human reviews and merges (rebase); contributors and agents stop after opening it.

Problems and ideas are GitHub issues, where the templates apply `type:` and `status: triage`; from a checkout, `make git-issue TITLE="…" LABEL="type: bug" BODY=<file>` files one without leaving the terminal.

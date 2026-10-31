# wizard.d/tasks/07-repo.sh — `Repository Setup`: ensure the checkout, commit identity, git hooks.

# ────────────────────────────── Phase 2 (stack) ───────────────────────────

ensure_repo() {
  if [ -d "$REPO/.git" ]; then
    # Repo already present (re-run or pre-cloned): leave alone an origin that
    # already points at this repo, whatever its protocol — rewriting it to HTTPS
    # on every run clobbers an SSH origin, and `make git-push` needs the key
    # that goes with it.
    local cur
    cur="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
    case "$cur" in
      *github.com[:/]"$GITHUB_USER/$REPO_NAME".git) ;;
      *) git -C "$REPO" remote set-url origin "https://github.com/$GITHUB_USER/$REPO_NAME.git" 2>/dev/null || true ;;
    esac
    detail "repo present at $REPO"
    return
  fi
  mkdir -p /root/github
  # Public repo: clone over HTTPS — no SSH key has to be added to GitHub.
  if git clone https://github.com/$GITHUB_USER/$REPO_NAME.git "$REPO" >>"$LOG" 2>&1; then
    git -C "$REPO" remote set-url origin https://github.com/$GITHUB_USER/$REPO_NAME.git
  else
    fail clone "repo clone failed — check network/DNS, then re-run"
    exit 1
  fi
}

install_hooks() {
  # Git hooks live in .git/hooks — untracked, so a fresh clone has none. Install
  # them here so a new host is guarded (pre-commit edge validation, pre-push
  # smoke) without a manual `make install-hooks` (docs/GUIDE.md). Idempotent;
  # the pre-push smoke gate stays shut until this run records finished=true, and
  # the installer's own push uses --no-verify so the hook never blocks it.
  if make -C "$REPO" install-hooks >>"$LOG" 2>&1; then
    detail "git hooks installed (pre-commit edge guard, pre-push smoke)"
  else
    warn hooks "make install-hooks failed — run it manually to guard the edge"
  fi
}


# AGENTS rule 30: every change is made on a branch, never on main. The installer
# leaves the checkout on the next free temp-<N> (naming in
# scripts/lib/temp-branch.sh) as soon as the repo is present, so a commit made
# in this clone later — by the operator, a recipe or an agent — cannot land on
# main. Idempotent: a checkout already on a temp branch is left alone.
ensure_temp_branch() {
  local cur branch
  . "$REPO/scripts/lib/temp-branch.sh"
  cur="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if temp_branch_is_temp "$cur"; then
    detail "  checkout already on $cur (a temp branch — main is never committed to here)"
    return 0
  fi
  branch="$(temp_branch_next "$REPO")"
  if git -C "$REPO" checkout -b "$branch" >>"$LOG" 2>&1; then
    detail "  checkout moved to $branch — every change reaches main through a pull request"
  else
    warn branch "could not create $branch — commits here would land on ${cur:-<detached>} (run 'make git-start')"
  fi
}

# Repository Setup: clone/present the repo, pin the commit identity, install hooks.
task_repo() {
  task_start
  ensure_repo
  github_set_identity
  install_hooks
  ensure_temp_branch
  task_end
}

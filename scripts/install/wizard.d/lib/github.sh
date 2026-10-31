# wizard.d/lib/github.sh — the opt-in GitHub collaborator flow: key mint, host verification, push/identity/origin.

# 2 — GitHub remote-access opt-in with its sub-prompts. The sub-prompts appear
# ONLY when the opt-in is yes; the minted key's authorization is verified
# automatically by github_access (no manual "press Enter to re-check" step).
# Whether the authenticated account may actually PUSH to this repo is not
# checked here — the push itself is the check (GitHub rejects a non-collaborator).
github_cred_inputs() {
  # Asked on EVERY run until the key is actually authorized (GH_AUTH_OK=1) or a
  # push has succeeded — an unanswered/unauthorized GitHub step must not be
  # silently skipped just because a previous run recorded GH_REMOTE=false. Once
  # authorized (or pushed) the answer is trusted and the prompt is gone.
  if [ "${GH_REMOTE:-}" = "true" ] && [ "${GH_AUTH_OK:-0}" != "1" ] \
     && [ -s "$GH_KEY" ] && github_auth_ok; then
    GH_AUTH_OK=1
    save_state
  fi
  if [ "${GH_AUTH_OK:-0}" != "1" ]; then
    unset GH_REMOTE
    ask_boolean "Are you a collaborator of $REPO_NAME?" GH_REMOTE || exit 1
  fi
  save_state
  [ "${GH_REMOTE}" = "true" ] || return 0
  # One prompt for both halves of the commit identity: "name email". REQUIRED
  # when pushing is on — there is no blank-skip and no root fallback.
  if [ -z "${GITHUB_COMMIT_NAME:-}" ] || [ -z "${GITHUB_COMMIT_EMAIL:-}" ]; then
    local line
    while :; do
      printf '%s[INFO]%s GitHub commit identity, separated by spaces (name email): ' "$C_GREY" "$C_RST"
      read -r line \
        || { echo "A commit identity is required when pushing is enabled."; exit 1; }
      line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      # The email is the LAST token, the name is everything before it — so a
      # multi-word name survives intact.
      if [[ "$line" == *" "* ]] && [ -n "${line% *}" ] && [ -n "${line##* }" ]; then
        GITHUB_COMMIT_NAME="${line% *}"
        GITHUB_COMMIT_EMAIL="${line##* }"
        break
      fi
      echo "   enter both a name and an email — e.g. Jane Doe jane@example.com"
    done
  fi
  save_state
  github_access
}


# ───────────────── GitHub remote access (opt-in, last prompt) ─────────────

# The ONE keypair this installer mints: it has to exist on the box to push to
# the operator's repos. (The operator's own login key is never minted — it is
# pasted at the ask_ssh_key prompt.) The operator authorizes the printed PUBLIC
# key once.
GH_KEY=/root/.ssh/github_key

github_keygen() {
  [ -s "$GH_KEY" ] && return 0                      # never overwrite an existing key
  ssh-keygen -t ed25519 -N "" -C "$(id -un)@$(hostname -s) github_key" -f "$GH_KEY" >/dev/null 2>&1 || return 1
  chmod 600 "$GH_KEY"; chmod 644 "$GH_KEY.pub"
  # ssh does not offer this key by default: name it in the client config.
  grep -qs "IdentityFile $GH_KEY" /root/.ssh/config 2>/dev/null && return 0
  printf 'Host github.com\n  IdentityFile %s\n  IdentitiesOnly yes\n' "$GH_KEY" >> /root/.ssh/config
  chmod 600 /root/.ssh/config
}

# Pin github.com's host keys, but only ones whose fingerprint api.github.com
# publishes — a bare ssh-keyscan trusts whoever answered first.
github_known_hosts() {
  local scan fps published f n=0
  grep -qs 'github\.com' /root/.ssh/known_hosts 2>/dev/null && return 0
  scan="$(ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null)" || return 0
  [ -n "$scan" ] || return 0
  fps="$(printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
  published="$(curl -fsS --max-time 10 https://api.github.com/meta 2>/dev/null \
    | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["ssh_key_fingerprints"].values()))' 2>/dev/null)"
  for f in $fps; do
    n=$((n+1))
    printf '%s\n' "$published" | grep -qxF "$f" || return 0   # unverified — leave it to ssh
  done
  [ "$n" -gt 0 ] && printf '%s\n' "$scan" >> /root/.ssh/known_hosts && chmod 600 /root/.ssh/known_hosts
}

# GitHub answers a successful key test with exit 1 and a "successfully
# authenticated" line, so the MESSAGE is the test, not the exit code — and the
# output has to be captured first: under `set -o pipefail` a `ssh … | grep -q`
# reports ssh's 1 even when grep matched.
github_auth_ok() {
  local out
  [ -s "$GH_KEY" ] || return 1
  # BatchMode prevents any dialog; a rejected key returns 255, a good one 1 —
  # we therefore never check the exit code, only the verified message.
  out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)" || true
  printf '%s' "$out" | grep -q "successfully authenticated"
}

# The push IS the collaborator check: the authenticated key proves only WHICH
# GitHub account it belongs to; GitHub itself rejects a push from an account
# that may not write here, and that rejection is reported as an error. Runs
# only in the installer's tail (after a green smoke), never as a pre-check.
#
# It pushes a WORK BRANCH, never `main` (AGENTS rule 30). The checkout is moved
# onto the next free `work-<N>` (naming lives in scripts/lib/work-branch.sh) and
# that branch is pushed, so the installer's commits reach the operator as a pull
# request and `main` stays untouched on the remote. The checkout STAYS on that
# branch: every later change in this clone is made there, one PR per branch.
#
# NOTE (AGENTS rule 3): raw git is normally reserved for the make recipes — the
# one exception is right here, because the installer must push to a TEMPORARY
# remote with --no-verify (the pre-push hook's live smoke cannot pass before the
# stack exists, and the installer has already run smoke itself). The hook's
# main-refusal is not bypassed in spirit: the destination is a branch.
github_push() {
  [ "${GH_REMOTE:-false}" = "true" ] || return 0
  if [ -z "${GITHUB_USER:-}" ] || [ "${GITHUB_USER:-}" = "exampleuser" ]; then
    warn github_push "cannot tell which account to push to — no origin remote and no GITHUB_USER in $DATA/instance.conf"
    return 1
  fi
  # Identity is required (collected up front); no root fallback, no blank skip.
  if [ -z "${GITHUB_COMMIT_NAME:-}" ] || [ -z "${GITHUB_COMMIT_EMAIL:-}" ]; then
    warn github_push "no Git commit identity — cannot push (re-run the installer and enter name + email)"
    return 1
  fi
  # GitHub is opt-in, so a requested push that CANNOT run is a failure, not a
  # skip: an unauthorized key must not fall through to a success block.
  if ! github_auth_ok; then
    warn github_push "GitHub key is not authorized (ssh -T git@github.com failed) — push skipped"
    return 1
  fi
  export GIT_COMMITTER_NAME="$GITHUB_COMMIT_NAME" GIT_COMMITTER_EMAIL="$GITHUB_COMMIT_EMAIL" \
         GIT_AUTHOR_NAME="$GITHUB_COMMIT_NAME" GIT_AUTHOR_EMAIL="$GITHUB_COMMIT_EMAIL"
  local url="git@github.com:$GITHUB_USER/$REPO_NAME.git"

  # The installer NEVER pushes main: it creates (or reuses) the working branch
  # and pushes that, so the operator merges through a pull request. The name is
  # the next free work-<N>, derived from the branches that exist — local and on
  # origin — never hardcoded and never stored in a file.
  . "$REPO/scripts/lib/work-branch.sh"
  local branch
  branch="$(work_branch_next "$REPO")"
  if ! git -C "$REPO" checkout -B "$branch" >>"$LOG" 2>&1; then
    warn github_push "could not switch the checkout to $branch — push skipped"
    return 1
  fi

  # Idempotent by construction: the push itself creates no persistent remote.
  # `temppush` is a one-shot URL remote — added, pushed, removed — and it is
  # removed BEFORE the push (run both steps, then clean up on every exit path),
  # so a re-run after an abort finds nothing stale to collide with. Git with no
  # origin falls back to the COMMAND-LINE url, which is what a clone whose
  # origin was never set needs; origin is separately pointed at the SSH URL by
  # github_set_origin once the key is authorized (so the operator can push
  # without a login). Every piece of identity is passed with `-c`, so the run
  # does not write shared repo config.
  git -C "$REPO" remote remove temppush 2>/dev/null || true
  local push_out rc
  push_out="$(git -C "$REPO" -c user.name="$GITHUB_COMMIT_NAME" -c user.email="$GITHUB_COMMIT_EMAIL" \
                -c remote.temppush.url="$url" \
                push --no-verify temppush "HEAD:refs/heads/$branch" 2>&1)"
  rc=$?
  git -C "$REPO" remote remove temppush 2>/dev/null || true
  printf '%s\n' "$push_out" >>"$LOG"
  if [ $rc -eq 0 ]; then
    detail "  GitHub: pushed branch $branch to $url (main untouched)"
    detail "  open the pull request: https://github.com/$GITHUB_USER/$REPO_NAME/compare/main...$branch?expand=1"
    return 0
  fi
  if printf '%s' "$push_out" | grep -q 'fetch first'; then
    warn github_push "push rejected — local history diverged from the remote (fetch first); run 'make fetch' or 'git pull --rebase' and re-run the installer"
  else
    warn github_push "push rejected — $url refused $GITHUB_USER for branch $branch (not a collaborator, or the key is not authorized)"
  fi
  return 1
}

# Point origin at the SSH URL once the GitHub key is authorized, so the OPERATOR
# can `git push` themselves with no GitHub login (this host has no HTTPS token).
# The installer's own push is a one-shot `temppush` URL remote and does not need
# origin — but the success block and any later manual push do, and origin stayed
# HTTPS while the push was rejected, leaving `git push` to prompt for a username
# (observed 2026-10-15). Only ever after authorization, so a non-collaborator's
# HTTPS origin is never rewritten.
github_set_origin() {
  local want="git@github.com:$GITHUB_USER/$REPO_NAME.git" cur
  cur="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
  [ "$cur" = "$want" ] && return 0
  git -C "$REPO" remote set-url origin "$want" 2>/dev/null \
    || git -C "$REPO" remote add origin "$want" 2>/dev/null || return 0
  detail "  origin set to $want (push without a GitHub login)"
}

# Write the collected operator identity into the checkout's REPO-LOCAL git
# config. Nothing must ever commit or push as root (AGENTS rule 27): a fresh
# host has no global git identity, so without this a later `git commit` by the
# operator or an agent silently falls back to `root@<host>`. The identity is
# collected up front; a non-collaborator run has none, in which case the
# pre-commit guard refuses a root commit rather than letting one through.
github_set_identity() {
  [ -n "${GITHUB_COMMIT_NAME:-}" ] && [ -n "${GITHUB_COMMIT_EMAIL:-}" ] || return 0
  git -C "$REPO" config user.name  "$GITHUB_COMMIT_NAME" || true
  git -C "$REPO" config user.email "$GITHUB_COMMIT_EMAIL" || true
  # Never let git invent an identity: with useConfigOnly set, an unset name/email
  # is a hard error instead of the silent root@<host> fallback that put root
  # commits in this history. The repo-local config above IS the identity.
  git -C "$REPO" config user.useConfigOnly true || true
  detail "  git identity set to '$GITHUB_COMMIT_NAME <$GITHUB_COMMIT_EMAIL>' (repo-local, no invented fallback)"
}

github_access() {
  [ "${GH_REMOTE:-false}" = "true" ] || { log "  GitHub remote access: not requested — skipped"; return 0; }
  if [ -z "${GITHUB_USER:-}" ] || [ "${GITHUB_USER:-}" = "exampleuser" ]; then
    fail github_auth "cannot tell which account to push to — no origin remote and no GITHUB_USER in $DATA/instance.conf"
    return
  fi
  github_keygen || { fail github_key; return; }
  github_known_hosts
  # Resume shortcut: the key file survives across reboots/reinstalls, so an
  # already-authorized key skips the wait entirely (authorizing once keeps us
  # logged in for the life of the key pair).
  if [ -s "$GH_KEY" ] && github_auth_ok; then
    GH_AUTH_OK=1
    github_set_origin
    detail "  GitHub key authorized (ssh -T git@github.com) — the push runs at the end"
    save_state
    return
  fi
  # Not authorized yet: print the public key, then verify it AUTOMATICALLY —
  # poll ssh until GitHub accepts it. No manual "press Enter to re-check" step;
  # Ctrl-C aborts the installer.
  printf '\n %s── Github SSH Key Prompt %s────────────────────────────────────────%s\n' "$C_GREEN" "$C_GREY" "$C_RST"
  printf '  %sPaste this public key once — the installer verifies it automatically.%s\n' "$C_GREY" "$C_RST"
  printf '  GitHub → Settings → SSH and GPG keys → New SSH key → paste this line:\n\n'
  printf '    %s\n\n' "$(cat "$GH_KEY.pub")"
  printf '  %sSettings is under the avatar menu (top right); "New SSH key" is the%s\n' "$C_GREY" "$C_RST"
  printf '  %sgreen button in the SSH keys box — name it after this host.%s\n' "$C_GREY" "$C_RST"
  printf ' %s─────────────────────────────────────────────────────────────────────%s\n\n' "$C_GREY" "$C_RST"
  local _waited=0
  until github_auth_ok; do
    sleep 5
    _waited=$(( _waited + 5 ))
    [ $(( _waited % 15 )) -eq 0 ] && log "  GitHub: key not authorized yet (${_waited}s) — paste the line above; verification is automatic."
  done
  GH_AUTH_OK=1
  github_set_origin
  save_state
  detail "  GitHub key authorized (ssh -T git@github.com) — the push runs at the end"
}

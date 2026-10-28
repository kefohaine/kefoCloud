# wizard.d/tasks/10-hygiene.sh — `Repo Hygiene`: sweep leftovers the install must not keep.

# Old-project references must not survive in anything the installer deploys
# (compose files, host config, Makefile, recipes). docs/ and scripts/ are out
# of scope by design: docs record the rename as history, and the scripts
# (this installer, the rewrite/import tooling) name the old project by nature
# — counting them made the check unsatisfiable on the repo's own tree.
sweep_hits() {
  # Flag only legacy placeholders that cannot legitimately remain after a
  # rename (the skeleton shipped "exampleuser" as owner and "homelab" as project).
  # Scoped to the two dirs that can actually carry a placeholder: the tracked
  # modules/ and config/ trees. Scanning $REPO root-wide walked data/ (the live
  # instance: maildirs, pgdata, certs — hundreds of thousands of files, ~23 s per
  # pass) and had to be filtered back out afterwards; `-not -path` was a FIND flag
  # handed to grep, so it did nothing and the exclusion rested on the kefoCloud
  # grep alone. docs/ and scripts/ are out of scope by design: docs record the
  # rename as history and these scripts name the old project by nature.
  grep -rlI -e homelab -e exampleuser \
    "$REPO/modules" "$REPO/config" \
    --exclude-dir=.git --exclude-dir=archives \
    --exclude='*.md' --exclude='.env' 2>/dev/null |
    grep -v 'kefoCloud' || true
}

sweep() {
  [ -z "$(sweep_hits)" ] || fail sweep
}

# Repo Hygiene: no stale references to the old project name in the tree.
task_hygiene() {
  task_start
  sweep
  task_end
}

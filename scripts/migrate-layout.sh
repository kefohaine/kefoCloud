#!/bin/bash
# migrate-layout.sh — move an existing deployment onto the canonical layout.
#
#   OLD: user 'op', repo /var/www/custom/projects/homelab/repo, data siblings
#   NEW: user 'root' only (root@kefoserver), repo /root/github/kefoserver,
#        data    /root/github/kefoserver/data
#
# This is DESTRUCTIVE on a live box: it stops every container, moves the whole
# tree and recreates the stack. Run it from a root SSH session (NOT the ttyd
# web shell), and keep a second session open. Dry-run first:
#
#   bash scripts/migrate-layout.sh --dry-run
#   bash scripts/migrate-layout.sh --yes
#
# It never deletes data and never removes a user account; the legacy 'op'
# account is left in place (disable it yourself once root login is confirmed).
set -uo pipefail

NEW_REPO=/root/github/kefoserver
NEW_DATA="$NEW_REPO/data"
OLD_PROJECT=/var/www/custom/projects/homelab
OLD_REPO="$OLD_PROJECT/repo"
HTTPS=https://github.com/kefohaine/kefoserver.git

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1;;
    --yes) :;;
    *) echo "usage: $0 [--dry-run|--yes]"; exit 2;;
  esac
done

run() { echo "+ $*"; [ "$DRY" = 1 ] || "$@"; }
log() { echo "[migrate] $*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root (root@kefoserver)"; exit 1; }

# ── 1. identity: local hostname + tailnet name ─────────────────────────────
log "hostname -> server ; tailnet node -> kefoserver (root@kefoserver)"
run hostnamectl set-hostname server || true
if command -v tailscale >/dev/null 2>&1; then
  run tailscale up --hostname=kefoserver || true
fi

# ── 2. relocate the tree (only if the old path exists) ────────────────────
if [ -d "$OLD_REPO" ]; then
  log "stopping the stack (docker compose down for every service)"
  for f in "$OLD_REPO"/services/*/docker-compose.yml; do
    [ -f "$f" ] || continue
    run docker compose -f "$f" down || true
  done
  log "moving $OLD_PROJECT -> $NEW_REPO (+ data under $NEW_DATA)"
  run install -d -m 0755 /root/github
  run mv "$OLD_REPO" "$NEW_REPO"
  # every former sibling data dir becomes $NEW_DATA/<name>
  run install -d -m 0755 "$NEW_DATA"
  for d in "$OLD_PROJECT"/*; do
    b=$(basename "$d")
    [ "$b" = repo ] && continue
    [ -e "$NEW_DATA/$b" ] && continue
    run mv "$d" "$NEW_DATA/$b"
  done
  run rmdir "$OLD_PROJECT" 2>/dev/null || true
elif [ -d "$NEW_REPO" ]; then
  log "already at $NEW_REPO — skipping the move"
else
  log "no existing deployment found ($OLD_REPO absent) — clone it:"
  echo "  git clone $HTTPS $NEW_REPO"
  exit 1
fi

# ── 3. git remote -> public HTTPS, stay on 'origin' ───────────────────────
if [ -d "$NEW_REPO/.git" ]; then
  run git -C "$NEW_REPO" remote set-url origin "$HTTPS"
  run git -C "$NEW_REPO" remote remove homelab 2>/dev/null || true
fi

# ── 4. host config: units, cron, sshd name the root-only paths ────────────
for pair in "/etc/systemd/system/goose.service:$NEW_REPO" \
            "/etc/systemd/system/ttyd.service:$NEW_REPO"; do
  u=${pair%%:*}; wd=${pair##*:}
  [ -f "$u" ] || continue
  run sed -i -e 's/^User=op$/User=root/' -e 's/^Group=op$/Group=root/' \
      -e "s#^WorkingDirectory=.*#WorkingDirectory=$wd#" "$u"
  run systemctl daemon-reload
done
for c in /etc/cron.d/nextcloud; do
  [ -f "$c" ] && run sed -i 's/^\(\*\/5 \* \* \* \* \)op /\1root /' "$c"
done
run sed -i 's/^AllowUsers .*/AllowUsers root/' /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null || true
run systemctl restart sshd || true

# ── 5. bring the stack back up from the new paths ─────────────────────────
if [ -d "$NEW_REPO" ]; then
  log "recreating the stack from $NEW_REPO"
  ( cd "$NEW_REPO" && run make dok-recreate-all ) || log "recreate failed — inspect: make dok-logs-all"
fi

log "done. Verify: make smoke ; make fetch"
log "Legacy 'op' account left intact — once root@kefoserver login is confirmed,"
log "disable it with: usermod -L op && rm -f /etc/sudoers.d/op-passwordless"

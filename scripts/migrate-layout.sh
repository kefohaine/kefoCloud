#!/bin/bash
#
# migrate-layout.sh — move a legacy 'op' deployment onto the root-only
# kefoserver layout that the repo already encodes:
#
#   OLD: user 'op' (+ root), repo /var/www/custom/projects/homelab/repo,
#        data as siblings of repo/ inside /var/www/custom/projects/homelab
#   NEW: root only (root@kefoserver), repo /root/github/kefoserver,
#        data  /root/github/kefoserver/data/<name>
#
# WHY THIS EXISTS: commit "root-only + kefoserver layout" rewrote the Makefile
# (REPO=/root/github/kefoserver), every compose bind mount, and install.sh to
# the NEW paths while the tree still lived at the OLD path. In that state any
# `docker compose up` mounts non-existent host paths and takes the stack down —
# above all the Caddy edge, which is the only web door. Run this to make the
# filesystem match the repo again.
#
# DESTRUCTIVE — the stack is recreated (downtime). Run it from a ROOT SSH
# session, never from the ttyd web shell, and keep a second session open.
# Everything it writes is recorded in $BK so the move can be reversed by hand.
#
#   bash scripts/migrate-layout.sh --dry-run     # print every step, change nothing
#   bash scripts/migrate-layout.sh --yes         # do it
#   bash scripts/migrate-layout.sh --purge-op    # after root login is verified:
#                                                # delete the legacy 'op' account
#
# It never deletes data. It never runs `tailscale up` (that would reset
# --ssh and could cost the tailnet login path) — it uses `tailscale set`.
#
set -uo pipefail

REPO_NEW=/root/github/kefoserver
DATA_NEW="$REPO_NEW/data"
PROJ_OLD=/var/www/custom/projects/homelab
REPO_OLD="$PROJ_OLD/repo"
HOSTNAME_NEW=kefoserver
GIT_REMOTE_HTTPS=https://github.com/kefohaine/kefoserver.git
GIT_REMOTE_SSH=git@github.com:kefohaine/kefoserver.git

DRY=0
PURGE_OP=0
RESUME=0
for a in "$@"; do
  case "$a" in
    --dry-run)       DRY=1 ;;
    --yes)           : ;;
    --purge-op)      PURGE_OP=1 ;;
    --resume)        RESUME=1 ;;
    *) echo "usage: $0 [--dry-run|--yes] [--purge-op]"; exit 2 ;;
  esac
done

run() { echo "+ $*"; [ "$DRY" = 1 ] || "$@"; }
log() { echo "[migrate] $*"; }
warn() { echo "[migrate][warn] $*"; }
die() { echo "[migrate][FATAL] $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (root@$HOSTNAME_NEW)"

BK="/root/pre-migration-backup-$(date +%Y%m%d-%H%M%S)"

# ── container-unit helpers ─────────────────────────────────────────────────
# Derive the units to touch from the live system, never from a hardcoded
# roster (AGENTS rule 12): a compose file is "deployed" only if one of the
# container names it declares already exists (running or stopped).
unit_container_names() {
  docker compose -f "$1" config --format json 2>/dev/null \
    | jq -r '.services[] | (.container_name // .name)' 2>/dev/null
}
unit_is_deployed() {
  local n
  for n in $(unit_container_names "$1"); do
    docker ps -a --format '{{.Names}}' | grep -qx "$n" && return 0
  done
  return 1
}
compose_up() {  # compose_up <file> <extra-args...>
  local f=$1; shift
  ( cd "$REPO_NEW" && docker compose -f "$f" up -d --force-recreate "$@" )
}

# ── guard: is Caddy healthy right now? (baseline before we touch anything) ─
# Probes through SNI+Host against loopback, so it does not depend on Cloudflare
# or on DNS — it answers "is the local edge serving a real 200/3xx".
edge_healthy() {
  docker inspect -f '{{.State.Running}}' "$DOMAIN_CTN" 2>/dev/null | grep -qx true || return 1
  curl -sk -o /dev/null -m 8 -w '%{http_code}' \
    --resolve "$SMOKE_HOST:443:127.0.0.1" "https://$SMOKE_HOST/" 2>/dev/null \
    | grep -qE '^(200|30[0-9])$'
}

# ── guard: Caddyfile parses with the NEW mounts (no secret needed) ─────────
edge_config_ok() {
  docker compose -f "$REPO_NEW/services/$DOMAIN_CTN/docker-compose.yml" config -q 2>/dev/null || return 1
  docker run --rm --entrypoint caddy \
    -v "$REPO_NEW/services/$DOMAIN_CTN:/etc/caddy:ro" "$DOMAIN_CTN:local" \
    adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1
}

# ── 1. preflight ───────────────────────────────────────────────────────────
preflight() {
  log "preflight"
  for d in "$DATA_NEW"; do
    [ -d "$d" ] && [ "$PURGE_OP" = 0 ] && die "$REPO_NEW already exists — already migrated (use --purge-op for the account step)"
  done
  [ -d "$REPO_OLD" ] || die "$REPO_OLD not found — nothing to migrate"
  [ -d "$REPO_OLD/.git" ] || die "$REPO_OLD is not a git checkout"
  grep -qF 'macoslaptop' /root/.ssh/authorized_keys 2>/dev/null \
    || warn "the operator key (macoslaptop) is NOT in /root/.ssh/authorized_keys — add it before locking 'op'"
  [ -s /root/.ssh/authorized_keys ] || die "no root SSH key on disk"
  df --output=avail -BG /root | tail -1 | tr -dc '0-9' | awk '{exit ($1 < 10)}' || warn "less than 10 GB free on /root"
  [ "$(stat -c '%d' "$PROJ_OLD")" = "$(stat -c '%d' /root)" ] \
    || die "old and new paths are on different filesystems — the move would copy, not rename"
  log "  old repo : $REPO_OLD"
  log "  new repo : $REPO_NEW"
  log "  backup   : $BK"
  # created up front: identity() backs /etc/hosts up before relocate() runs
  if [ "$DRY" = 0 ]; then mkdir -p -m 0755 "$BK"; chmod 0700 "$BK"; fi
}

# ── 2. host identity ───────────────────────────────────────────────────────
identity() {
  log "identity: hostname -> $HOSTNAME_NEW (tailnet name is set separately)"
  run hostnamectl set-hostname "$HOSTNAME_NEW"
  if [ "$DRY" = 0 ]; then
    cp -a /etc/hosts "$BK/hosts.orig"
    sed -i -E "s/^([0-9.]+[[:space:]]+)host([[:space:]]|$)/\1$HOSTNAME_NEW\2/" /etc/hosts
    grep -qE "^127\.0\.1\.1[[:space:]]+$HOSTNAME_NEW" /etc/hosts \
      || printf '127.0.1.1\t%s\n' "$HOSTNAME_NEW" >> /etc/hosts
  fi
  run grep -n "$HOSTNAME_NEW" /etc/hosts

  # `tailscale set` only touches the flags named; `tailscale up` would reset
  # every unset flag to its default (RunSSH included) and can drop the
  # tailnet login path this whole migration depends on.
  if command -v tailscale >/dev/null 2>&1; then
    log "identity: tailnet node -> $HOSTNAME_NEW (keeping --ssh on)"
    run tailscale set --hostname="$HOSTNAME_NEW" --ssh
    if [ "$DRY" = 0 ]; then
      DNSNAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName')
      log "  tailnet DNSName: $DNSNAME"
      case "$DNSNAME" in "$HOSTNAME_NEW".*) : ;; *) warn "tailnet name is '$DNSNAME', expected '$HOSTNAME_NEW.*'";; esac
      tailscale debug prefs 2>/dev/null | jq -r '"  RunSSH: \(.RunSSH)"'
    fi
  fi
}

# ── 3. move the tree ───────────────────────────────────────────────────────
relocate() {
  log "relocate: $PROJ_OLD -> $REPO_NEW (+ data under $DATA_NEW)"
  if [ "$DRY" = 0 ]; then
    mkdir -p -m 0755 "$BK"
    chmod 0700 "$BK"
    for f in /etc/systemd/system/ttyd.service /etc/systemd/system/goose.service \
             /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/cron.d/nextcloud \
             /etc/dnsmasq.d/10-tailnet.conf /etc/sysctl.d/99-homelab.conf \
             /etc/kefohaine-banner.sh; do
      [ -e "$f" ] && cp -a "$f" "$BK/"
    done
    cp -a /root/.ssh/authorized_keys "$BK/root-authorized_keys"
    git -c safe.directory='*' -C "$REPO_OLD" bundle create "$BK/repo.bundle" --all >/dev/null 2>&1 \
      && log "  git bundle saved" || warn "git bundle failed (repo still moves fine)"
  fi
  run mkdir -p -m 0755 /root/github
  run mv "$REPO_OLD" "$REPO_NEW"
  run mkdir -p -m 0755 "$DATA_NEW"
  # every former sibling becomes $DATA_NEW/<name>; the repo itself is skipped
  for d in "$PROJ_OLD"/*; do
    [ -e "$d" ] || continue
    b=$(basename "$d")
    [ "$b" = repo ] && continue
    [ -e "$DATA_NEW/$b" ] && { warn "skip (already present): $b"; continue; }
    run mv "$d" "$DATA_NEW/$b"
  done
  run rmdir "$PROJ_OLD" 2>/dev/null || warn "$PROJ_OLD not empty — inspect it"
  # the repo is root's now — but $DATA_NEW lives INSIDE the repo, so a blanket
  # recursive chown would also seize the data dirs from their container uids
  # (33 www-data, 70 postgres, 201 caddy, 5000 mailserver) and Nextcloud would
  # 404 on its own code. Chown everything at the top level EXCEPT data/.
  run find "$REPO_NEW" -maxdepth 1 -mindepth 1 ! -name data -exec chown -R root:root {} +
  run chmod 0644 "$REPO_NEW/Makefile"
  run find "$REPO_NEW" -type f \( -name '*.sh' -o -name 'mklog' \) -exec chmod 0755 {} +
  log "  running containers keep their bind mounts (same filesystem rename)"
}

# ── 4. purge dead host artifacts (AGENTS rule 14) ──────────────────────────
purge_dead() {
  log "purge: retired host artifacts"
  run rm -f /etc/sysctl.d/99-homelab.conf /etc/kefohaine-banner.sh
  [ "$DRY" = 0 ] && sed -i '\#^\. /etc/kefohaine-banner\.sh$#d' /root/.bashrc
  run rm -f /etc/sudoers.d/op-passwordless
}

# ── 5. apply host config from the repo (units, cron, sshd, dnsmasq, sysctl) ─
host_config() {
  log "host config: make install-config (single source of truth for units/cron/sshd)"
  ( cd "$REPO_NEW" && make install-config ) || die "make install-config failed — inspect output before continuing"
  log "  restarting ttyd + goose so User=root takes effect (kills ttyd shells only)"
  run systemctl restart goose
  run systemctl restart ttyd
}

# ── 6. recreate the stack — the edge (Caddy) LAST, behind a gate ───────────
stack_up() {
  local f ctn names
  log "stack: recreating every DEPLOYED compose unit (edge last)"
  for f in "$REPO_NEW"/services/*/docker-compose.yml "$REPO_NEW"/services/*/docker-compose.db.yml; do
    [ -f "$f" ] || continue
    case "$f" in *"/$DOMAIN_CTN/"*) continue ;; esac   # edge handled below
    if unit_is_deployed "$f"; then
      run compose_up "$f" || die "recreate failed: $f (stack is partially recreated — fix, then re-run)"
    else
      log "  skip (not deployed): ${f#$REPO_NEW/}"
    fi
  done

  log "stack: pre-flight the edge config against the NEW mounts"
  edge_config_ok || die "edge config invalid (compose or Caddyfile) — running Caddy left untouched"
  log "  config OK"

  if docker image inspect "$DOMAIN_CTN:local" >/dev/null 2>&1; then
    run docker tag "$DOMAIN_CTN:local" "$DOMAIN_CTN:rollback"
    log "  previous edge image tagged $DOMAIN_CTN:rollback"
  fi

  log "stack: recreating the edge ($DOMAIN_CTN)"
  if ! run compose_up "$REPO_NEW/services/$DOMAIN_CTN/docker-compose.yml" --build; then
    warn "recreate failed — rolling back to $DOMAIN_CTN:rollback"
    if [ "$DRY" = 0 ] && docker image inspect "$DOMAIN_CTN:rollback" >/dev/null 2>&1; then
      docker tag "$DOMAIN_CTN:rollback" "$DOMAIN_CTN:local"
      compose_up "$REPO_NEW/services/$DOMAIN_CTN/docker-compose.yml"
    fi
    die "edge recreate failed (rollback attempted)"
  fi

  if [ "$DRY" = 0 ]; then
    local i s
    for i in $(seq 1 30); do
      s=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$DOMAIN_CTN" 2>/dev/null)
      [ "$s" = healthy ] || [ "$s" = running ] && break
      sleep 2
    done
    log "  edge state: $s"
    edge_healthy || warn "edge did not answer on :443 — check 'make dok-logs-$DOMAIN_CTN'"
  fi
}

# ── 7. git remote ──────────────────────────────────────────────────────────
git_remote() {
  [ -d "$REPO_NEW/.git" ] || return 0
  log "git: remote -> $GIT_REMOTE_SSH (HTTPS alternative: $GIT_REMOTE_HTTPS)"
  run git -c safe.directory='*' -C "$REPO_NEW" remote remove homelab
  if git -c safe.directory='*' -C "$REPO_NEW" remote get-url origin >/dev/null 2>&1; then
    run git -c safe.directory='*' -C "$REPO_NEW" remote set-url origin "$GIT_REMOTE_SSH"
  else
    run git -c safe.directory='*' -C "$REPO_NEW" remote add origin "$GIT_REMOTE_SSH"
  fi
  run git -c safe.directory='*' -C "$REPO_NEW" config --add safe.directory "$REPO_NEW"
}

# ── 8. lock the legacy account (deletion is a separate, explicit step) ─────
lock_op() {
  id -u op >/dev/null 2>&1 || { log "legacy 'op' account already gone"; return 0; }
  log "op: lock + de-privilege (the account is NOT deleted here)"
  run usermod -L op
  run gpasswd -d op sudo
  run gpasswd -d op docker
  run rm -f /etc/sudoers.d/op-passwordless
  log "  verify root login from the Mac FIRST, then: $0 --purge-op"
}

purge_op() {
  id -u op >/dev/null 2>&1 || { log "legacy 'op' account already gone"; return 0; }
  log "op: full removal (--purge-op)"
  run usermod -L op
  run rm -f /etc/sudoers.d/op-passwordless
  run pkill -u op
  run deluser --remove-home op
  run rm -f /home/op/install.sh
  log "  remaining login-capable accounts:"
  run awk -F: '$3==0 || ($3>=1000 && $7 !~ /(nologin|false)$/) {print "    "$1" uid="$3" shell="$7}' /etc/passwd
}

# ── 9. verify ──────────────────────────────────────────────────────────────
verify() {
  log "verify"
  if [ "$DRY" = 0 ]; then
    ( cd "$REPO_NEW" && make smoke ) && log "  make smoke: PASS" || warn "make smoke reported failures — review above"
    echo "--- containers ---"
    docker ps --format '{{.Names}}\t{{.Status}}'
    echo "--- listeners ---"
    ss -tlnp 2>/dev/null | grep -E ':22|:80|:443|:7681' || true
    echo "--- units ---"
    systemctl is-active sshd tailscaled docker ttyd goose dnsmasq | tr '\n' ' '; echo
  fi
  log "done. Reversal: stop the stack, 'mv $REPO_NEW $REPO_OLD', move $DATA_NEW/* back to $PROJ_OLD, restore the files in $BK."
}

main() {
  if [ "$PURGE_OP" = 1 ]; then purge_op; exit 0; fi
  # --resume: preflight/identity/relocate/host-config already ran (the tree is
  # at $REPO_NEW and the host config is applied) — finish the remaining phases.
  if [ "$RESUME" = 1 ]; then
    log "RESUME — repo already relocated; finishing stack + git + lock + verify"
    [ -d "$REPO_NEW" ] || die "$REPO_NEW missing — cannot resume"
    stack_up
    git_remote
    lock_op
    verify
    exit 0
  fi
  preflight
  [ "$DRY" = 1 ] && log "DRY RUN — nothing will be changed"
  identity
  relocate
  purge_dead
  [ "$DRY" = 1 ] || host_config
  [ "$DRY" = 1 ] || stack_up
  git_remote
  lock_op
  verify
}

# Derive the edge container + a public vhost to probe from the repo/live state
# (never hardcoded — AGENTS rule 12).
DOMAIN_CTN=$(awk '/^CONTAINERS/{print $3; exit}' "$REPO_OLD/Makefile" 2>/dev/null)
DOMAIN_CTN=${DOMAIN_CTN:-fxmq.net}
SMOKE_HOST=$(ls "$REPO_OLD/services/$DOMAIN_CTN/vhosts/" 2>/dev/null \
  | sed -n 's/^\(www\..*\)\.caddy$/\1/p' | head -1)
[ -n "${SMOKE_HOST:-}" ] || SMOKE_HOST=$(ls "$REPO_OLD/services/$DOMAIN_CTN/vhosts/" 2>/dev/null \
  | sed -n 's/^\(.*\)\.caddy$/\1/p' | head -1)
SMOKE_HOST=${SMOKE_HOST:-localhost}

main

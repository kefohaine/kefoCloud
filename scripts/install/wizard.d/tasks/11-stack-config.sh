# wizard.d/tasks/11-stack-config.sh — `Stack Config`: runtime dirs, data/instance.conf, module .env seeding.

prep_dirs() {
  # All external (untracked) state lives under $DATA = $REPO/data, matching
  # the compose bind mounts; the repo tree itself stays clean (.gitignore has /data/).
  mkdir -p $ROOT/data/cloud/html \
               $ROOT/data/cloud/users \
               $ROOT/data/vault/data \
               $ROOT/data/kuma/data \
               $ROOT/data/mailserver/data \
               $ROOT/data/mailserver/mail \
               $ROOT/data/mailserver/filter \
               $ROOT/data/mailserver/dkim \
               $ROOT/data/mailserver/redis \
               $ROOT/data/mailserver/certs \
               $ROOT/data/mailserver/overrides/nginx \
               $ROOT/data/mailserver/overrides/dovecot \
               $ROOT/data/mailserver/overrides/postfix \
               $ROOT/data/mailserver/overrides/rspamd \
               $ROOT/data/mailserver/roundcube \
               $ROOT/data/pgdata \
               $ROOT/data/talk \
               $ROOT/data/download \
               $ROOT/data/pages/www \
               $ROOT/data/pages/tail
  # The web roots are INSTANCE DATA (the repo ships no pages), one directory per
  # vhost: data/pages/www for www.$DOMAIN, data/pages/tail for tail.$DOMAIN.
  # Seed a minimal placeholder homepage ONCE so www.$DOMAIN never falls through
  # to the bare "ok" stub. Existing pages are never touched — the operator owns
  # these dirs (data/pages/tail/tail.html is rendered by `make render`).
  if [ ! -f "$ROOT/data/pages/www/index.html" ]; then
    printf '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n<meta name="viewport" content="width=device-width,initial-scale=1">\n<title>%s</title></head><body>\n<h1>%s</h1>\n<p>This is the placeholder homepage. Drop your pages in <code>%s/pages/www</code> — they are served at the vhost roots (<code>www.%s</code>, <code>tail.%s</code>) and are never overwritten by a render.</p>\n</body></html>\n' \
      "$DOMAIN" "$DOMAIN" "$DATA" "$DOMAIN" "$DOMAIN" > "$ROOT/data/pages/www/index.html"
  fi
  # Recursive chowns only when the ownership is actually wrong: on an installed
  # instance these trees can hold hundreds of thousands of files, and a re-run
  # that walks them all just to find nothing to change is pure cost. The check is
  # per top-level dir and falls back to "fix it" whenever stat cannot tell.
  need_chown() { [ "$(stat -c '%u' "$1" 2>/dev/null || echo x)" != "$2" ]; }
  # A chown that prints would print UNDER the live checklist, uncounted, and one
  # stray line shifts the animator's relative moves by a row — the failed row is
  # then painted over by an [EXEC] frame (2026-10-28). Log it instead; a real
  # ownership problem is surfaced by the verification at the end of this
  # function, which fails the task.
  chown_tree() { sudo chown -R "$2" "$1" >>"$LOG" 2>&1; }
  need_chown $ROOT/data/cloud/html 33        && chown_tree $ROOT/data/cloud/html 33:33
  need_chown $ROOT/data/cloud/users 33       && chown_tree $ROOT/data/cloud/users 33:33
  need_chown $ROOT/data/vault/data 1000      && chown_tree $ROOT/data/vault/data 1000:1000
  # Mailu containers run as root (front/postfix/dovecot/admin drop privileges
  # per-process); their bind mounts stay root-owned. Roundcube remains uid 33.
  # mailserver/redis is the EXCEPTION and must NOT be root-owned: redis:alpine
  # re-execs redis-server as its `redis` user (uid 999/gid 1000) via su-exec, so
  # a root:root 0700 mount makes every BGSAVE fail ("Failed opening the temp RDB
  # file ... Permission denied"). Redis then enters MISCONF, stop-writes-on-
  # bgsave-error rejects every write and — because the mail cache used to share
  # the `redis` DNS name with the Nextcloud cache — Nextcloud's session writes
  # retried forever and php-fpm hung (2026-10-19: smoke FAIL cloud HTTP 000).
  for d in data mail filter dkim certs overrides; do
    need_chown "$ROOT/data/mailserver/$d" 0 && chown_tree "$ROOT/data/mailserver/$d" root:root
  done
  need_chown "$ROOT/data/mailserver/redis" 999 && chown_tree "$ROOT/data/mailserver/redis" 999:1000
  need_chown $ROOT/data/mailserver/roundcube 33 && chown_tree $ROOT/data/mailserver/roundcube 33:33
  # root-owned: talk configs (talk-gen), the public drop folder and the
  # instance web roots (read-only from the edge container).
  # pgdata stays root-owned — the postgres entrypoint chowns it on first boot.
  for d in talk download; do
    need_chown "$ROOT/data/$d" 0 && chown_tree "$ROOT/data/$d" root:root
  done
  # The web root is data/pages/www (one tree per vhost, created above), NOT
  # data/www: the old path never existed, so this chown printed "cannot access
  # .../data/www" to the console and the failure was ignored.
  need_chown "$ROOT/data/pages/www" 0 && chown_tree "$ROOT/data/pages/www" root:root
  # The container-side id above is what the IMAGE runs as, not a guess. One
  # exception, measured rather than assumed: DMS's image creates /var/log/mail
  # owned by its `syslog` user (uid 113), and the daemons it runs write there as
  # `docker` — so forcing that dir to 5000 breaks mail logging. Every other
  # mount is the compose user. A `chown` to an id that does not exist, or an
  # image that changed its runtime user, leaves a mount the app cannot write —
  # which surfaces much later as an opaque app error (Vaultwarden "unable to
  # open database file", Nextcloud "Data directory is invalid") on a stack whose
  # containers all report healthy.
  prep_dirs_verify || fail prep_dirs "$PREP_DIR_ERR"
}

# The ownership verdict for the dirs prep_dirs above just chowned — the only
# proof the chowns worked. Split out of prep_dirs so the tag's re-check can ask
# the question without re-walking the trees.
prep_dirs_verify() {
  local d want got
  for spec in "cloud/html 33" "cloud/users 33" "vault/data 1000" \
              "mailserver/data 0" "mailserver/mail 0" "mailserver/dkim 0" \
              "mailserver/redis 999" "mailserver/roundcube 33" \
              "pages/www 0"; do
    set -- $spec; d="$DATA/$1"; want="$2"
    got=$(stat -c '%u' "$d" 2>/dev/null || echo "")
    [ "$got" = "$want" ] || { PREP_DIR_ERR="$d is owned by uid ${got:-?} — its container runs as uid $want (see prep_dirs in this script)"; return 1; }
  done
  return 0
}

write_instance_conf() {
  # data/instance.conf is the ONE place this instance's values live: templates
  # are rendered from it (make render) and scripts read it (scripts/lib/instance.sh).
  # Values we do not own here (SERVER_IP, EMAIL, TIMEZONE) are PRESERVED from an
  # existing file — re-running the installer must never wipe them.
  local f="$DATA/instance.conf" keep=""
  mkdir -p "$DATA"
  [ -f "$f" ] && keep=$(grep -E '^(SERVER_IP|EMAIL|TIMEZONE)=' "$f" || true)
  {
    echo "# data/instance.conf — the values for THIS host (untracked, mode 0600)."
    echo "# Written by the installer; see config/instance.defaults for what"
    echo "# each token means. Edit by hand and run 'make render' to apply."
    printf 'DOMAIN=%s\n' "$DOMAIN"
    printf 'HOSTNAME=%s\n' "${NODE_NAME:-$(hostname -s)}"
    printf 'OPERATOR=%s\n' "root"
    # Written only when it is real: a placeholder here would render
    # {{GITHUB_USER}} into vhosts as 'exampleuser' instead of staying loud.
    [ -n "${GITHUB_USER:-}" ] && [ "$GITHUB_USER" != "exampleuser" ] \
      && printf 'GITHUB_USER=%s\n' "$GITHUB_USER"
    printf 'REPO_NAME=%s\n' "${REPO_NAME:-$(basename "$REPO")}"
    printf 'REPO_DIR=%s\n' "$REPO"
    printf 'DATA_DIR=%s\n' "$DATA"
    printf 'LOG_DIR=%s\n' "$LOG_DIR"
    # Cloud module optional services: rendered as {{IF VIDEO_CALLING}} /
    # {{IF CLIENT_PUSH}} blocks (talk vhost, cloud /push route).
    printf 'VIDEO_CALLING=%s\n' "${VIDEO_CALLING:-true}"
    printf 'CLIENT_PUSH=%s\n' "${CLIENT_PUSH:-false}"
    [ -n "$keep" ] && printf '%s\n' "$keep"
  } > "$f"
  chmod 600 "$f"
  detail "  instance.conf written ($f) — every template renders from it"
  # compose gets the same values through the marked block in each .env
  bash "$REPO/scripts/render/render-all.sh" >>"$LOG" 2>&1 || fail render
}

seed_stack() {
  cd "$REPO" || exit 1
  # The repo already carries the canonical naming (modules/caddy,
  # container $DOMAIN, vhosts/<host>.caddy, user root) — no domain
  # renames apply. Each module's credentials and secrets are seeded ONLY when
  # that module is on: a module the operator turned off gets no admin creds, no
  # SMTP sender and no stack secrets minted for it (the goose secret, which the
  # host service always needs, is core).
  if mod_on cloud; then
    # Admin creds live in the SAME file talk-gen fills with the stack secrets, so
    # this is per-key and never "write the file only if it is absent": `make
    # render` creates modules/nextcloud/.env first (instance values block), the
    # existence guard therefore never fired, compose interpolated BOTH vars as
    # empty and the image entrypoint refused to install — its fallback is
    # "Next step: Access your instance to finish the web-based installation!"
    # and `occ` then only ever answers "Set an admin Login." Nextcloud stayed
    # uninstalled and the whole occ wiring below was skipped (2026-09-25).
    # PER KEY, never "the file exists so it must be seeded": `make render` creates
    # the file first, and a file-existence guard is what let compose interpolate
    # the admin creds as EMPTY (2026-09-25). A key that is present but has no
    # value is just as broken — empty means the entrypoint refuses to install — so
    # a blank line is treated as unseeded and repaired with one canonical append.
    local ncen=modules/nextcloud/.env
    [ -f "$ncen" ] || { umask 077; : >"$ncen"; }
    chmod 600 "$ncen"
    ncseed() {
      local key="$1" val="$2"
      if grep -q "^$key=" "$ncen"; then
        grep -q "^$key=." "$ncen" || sed -i "s|^$key=$|$key=$val|" "$ncen"
      else
        echo "$key=$val" >>"$ncen"
      fi
    }
    ncseed NEXTCLOUD_ADMIN_USER admin
    if ! grep -q '^NEXTCLOUD_ADMIN_PASSWORD=.' "$ncen"; then
      ncseed NEXTCLOUD_ADMIN_PASSWORD "$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
    fi
    # Read the creds back so the summary prints the password actually in use
    # (older installs may already have them, and this run must not print a
    # freshly generated value that was never written).
    NEXTCLOUD_ADMIN_USER=$(sed -n 's/^NEXTCLOUD_ADMIN_USER=//p' "$ncen" | tail -1)
    NEXTCLOUD_ADMIN_PASSWORD=$(sed -n 's/^NEXTCLOUD_ADMIN_PASSWORD=//p' "$ncen" | tail -1)
    # Stack secrets (PostgreSQL, Redis, signaling, TURN, SMTP mailbox) +
    # Talk service configs — idempotent, appends only missing keys.
    detail "  nextcloud stack secrets via talk-gen"
    make talk-gen >>"$LOG" 2>&1 || fail talk_gen
  fi
  if mod_on mail; then
    # Mailu configuration (gitignored modules/mailserver/.env, read as env_file
    # by every Mailu container). Secrets are minted once and reused on a
    # re-run; the initial admin is created by the admin container itself.
    local menv=modules/mailserver/.env
    [ -f "$menv" ] || { umask 077; : >"$menv"; }
    chmod 600 "$menv"
    mseed() {
      local key="$1" val="$2"
      if grep -q "^$key=" "$menv"; then
        grep -q "^$key=." "$menv" || sed -i "s|^$key=$|$key=$val|" "$menv"
      else
        echo "$key=$val" >>"$menv"
      fi
    }
    mseed MAILU_VERSION 2.0
    mseed TLS_FLAVOR mail
    mseed SUBNET 172.22.0.0/16
    mseed POSTMASTER postmaster
    mseed WEBMAIL none
    mseed MESSAGE_SIZE_LIMIT 52428800
    mseed INITIAL_ADMIN_ACCOUNT admin
    mseed INITIAL_ADMIN_DOMAIN "$DOMAIN"
    mseed INITIAL_ADMIN_MODE ifmissing
    # Installs seeded before this fix carry `update`; force the safe mode so a
    # repair converges instead of reverting the admin password on every start.
    sed -i 's/^INITIAL_ADMIN_MODE=.*/INITIAL_ADMIN_MODE=ifmissing/' "$menv"
    if ! grep -q '^SECRET_KEY=.' "$menv"; then
      mseed SECRET_KEY "$(openssl rand -hex 16)"
    fi
    if ! grep -q '^INITIAL_ADMIN_PW=.' "$menv"; then
      mseed INITIAL_ADMIN_PW "$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
    fi
    detail "  mail platform secrets (Mailu) seeded in $menv"
  fi
  # The goose server secret lives in the INSTANCE tree (root:root 0600) and is
  # read by the unit through EnvironmentFile= — never a tracked file, and never
  # a repo directory: $DATA is untracked instance state, so the secret cannot be
  # confused with (or committed as) config.
  detail "  goose service secret -> $DATA/goose/.env"
  if [ ! -s "$DATA/goose/.env" ]; then
    sudo install -d -m 0700 "$DATA/goose"
    if sudo test -s /etc/goose/goose.env; then
      # pre-2026-10-27 location: adopt the existing secret, never rotate it
      sudo cp -p /etc/goose/goose.env "$DATA/goose/.env"
    else
      printf 'GOOSE_SERVER__SECRET_KEY=%s\n' "$(openssl rand -hex 32)" | sudo tee "$DATA/goose/.env" >/dev/null
    fi
    sudo chown root:"root" "$DATA/goose/.env"
    sudo chmod 0600 "$DATA/goose/.env"
  fi
  if mod_on vault; then
    # Vaultwarden SMTP sender (vaultwarden@$DOMAIN) — SMTP vars for the
    # compose interpolation; the mailbox itself is created after the
    # mailserver container is up (see vaultwarden_setup). Idempotent PER KEY —
    # never "write the file only if it is absent": `make render` already creates
    # modules/vaultwarden/.env (instance values, appended under the
    # '# >>> instance values' banner), so a file-existence guard skipped this
    # whole block, compose interpolated every SMTP_* to empty, vaultwarden
    # crash-looped on "SMTP_SECURITY is invalid" and vaultwarden_setup hit an
    # unbound $SMTP_PASSWORD (2026-09-25).
    local vwenv=modules/vaultwarden/.env
    [ -f "$vwenv" ] || { umask 077; : >"$vwenv"; }
    chmod 600 "$vwenv"
    # Present-but-empty is repaired the same way a missing key is: compose
    # interpolates an empty SMTP_* as "", Vaultwarden rejects "" (SMTP_SECURITY,
    # SMTP_HOST) and crash-loops — the file existing is not evidence the key is
    # usable.
    vwset() {
      local key="$1" val="$2"
      if grep -q "^$key=" "$vwenv"; then
        grep -q "^$key=." "$vwenv" || sed -i "s|^$key=$|$key=$val|" "$vwenv"
      else
        echo "$key=$val" >>"$vwenv"
      fi
    }
    # starttls is the only value Vaultwarden accepts for this variable besides
    # force_tls/off — it must never be left empty.
    vwset SMTP_HOST "mail.$DOMAIN"
    vwset SMTP_PORT 587
    vwset SMTP_SECURITY starttls
    vwset SMTP_USERNAME "vaultwarden@$DOMAIN"
    vwset SMTP_PASSWORD "$(openssl rand -hex 16)"
    vwset SMTP_FROM "vaultwarden@$DOMAIN"
    vwset SMTP_FROM_NAME Vaultwarden
    vwset SMTP_AUTH_MECHANISM Login
    # Default vault account (the one the success block prints). Vaultwarden has
    # no user CLI and signups are closed (SIGNUPS_ALLOWED=false), so the account
    # is seeded straight into its SQLite DB by scripts/modules/vaultwarden-user.sh
    # — the same "no CLI, write the DB" pattern as Uptime Kuma. Stored PER KEY
    # (like NEXTCLOUD_ADMIN_*) so a re-run prints the SAME password, never a
    # freshly generated value that was never written.
    vwset VAULTWARDEN_ADMIN_USER "admin@$DOMAIN"
    if ! grep -q '^VAULTWARDEN_ADMIN_PASSWORD=.' "$vwenv"; then
      vwset VAULTWARDEN_ADMIN_PASSWORD "$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
    fi
    VAULTWARDEN_ADMIN_USER=$(sed -n 's/^VAULTWARDEN_ADMIN_USER=//p' "$vwenv" | tail -1)
    VAULTWARDEN_ADMIN_PASSWORD=$(sed -n 's/^VAULTWARDEN_ADMIN_PASSWORD=//p' "$vwenv" | tail -1)
  fi
  if mod_on photos; then
    # Immich brings its OWN PostgreSQL (pgvecto-rs/vectorchord) — it must never
    # share the Nextcloud one. Credentials are minted once and reused; compose
    # interpolates them from this file.
    local penv=modules/immich/.env
    [ -f "$penv" ] || { umask 077; : >"$penv"; }
    chmod 600 "$penv"
    pseed() {
      local key="$1" val="$2"
      if grep -q "^$key=" "$penv"; then
        grep -q "^$key=." "$penv" || sed -i "s|^$key=$|$key=$val|" "$penv"
      else
        echo "$key=$val" >> "$penv"
      fi
    }
    pseed DB_USERNAME immich
    pseed DB_DATABASE_NAME immich
    if ! grep -q '^DB_PASSWORD=.' "$penv"; then
      pseed DB_PASSWORD "$(openssl rand -hex 24)"
    fi
    detail "  Immich database credentials seeded in $penv"
  fi
  if mod_on beszel; then
    # The agent refuses to start without a public key (KEY). One is minted here
    # and kept; the hub's add-system dialog shows the key it expects, and
    # `make beszel-key KEY=...` pins that one instead.
    local benv=modules/beszel/.env
    [ -f "$benv" ] || { umask 077; : >"$benv"; }
    chmod 600 "$benv"
    if ! grep -q '^BESZEL_KEY=.' "$benv"; then
      local _kd _kpub
      _kd=$(mktemp -d)
      ssh-keygen -q -t ed25519 -N '' -C beszel-agent -f "$_kd/id" >/dev/null 2>&1
      _kpub=$(cat "$_kd/id.pub" 2>/dev/null)
      rm -rf "$_kd"
      [ -n "$_kpub" ] && echo "BESZEL_KEY=$_kpub" >> "$benv"
    fi
    detail "  Beszel agent key seeded in $benv"
  fi
  # The /docs site is static output (Zensical), built from the repo's docs/
  # tree; there is no container to start, so it is built here, before smoke
  # asserts it.
  detail "  building the /docs site (Zensical)"
  make docs-build >>"$LOG" 2>&1 || fail docs_build
}


# ── Phase 2 (stack) — one function per checklist task, in checklist order ──

# Stack Config: render templates, mint secrets, prep dirs and instance.conf.
task_stackcfg() {
  task_start
  cd "$REPO" || exit 1
  docker_net
  caddy_data
  prep_dirs
  write_instance_conf
  seed_stack
  task_end
}

# wizard.d/modules/nextcloud/setup.sh — the cloud module’s occ wiring (install gate, SMTP, proxies, push, manifests, repaint).

# outbound SMTP (nextcloud@$DOMAIN sender mailbox), background cron. All
# steps are idempotent (safe to re-run; never clobbers operator settings).
# Requires the nextcloud + mailserver containers (called after containers_up).
nextcloud_setup() {
  cd "$REPO" || exit 1
  . modules/nextcloud/.env
  # The image entrypoint only installs Nextcloud while /var/www/html has no
  # version.php. A first attempt that fails (empty NEXTCLOUD_ADMIN_* from a
  # skipped seed, DB not yet up, …) still leaves version.php behind, and every
  # later start reads that as "already at the image version" and silently
  # skips BOTH install and upgrade: the container reports healthy, occ reports
  # "installed: false", and no occ step below ever runs (2026-09-25). So do
  # the install here when occ says it is missing — same options the entrypoint
  # would use, taken from the same .env.
  if docker exec -u www-data nextcloud php occ status 2>/dev/null | grep -q "installed: false"; then
    # Require an EXPLICIT "installed: false": a transient occ/DB failure must
    # not be mistaken for a missing install and trigger maintenance:install,
    # which does not even exist once the instance IS installed ("Command
    # 'maintenance:install' is not defined", 2026-10-19).
    log "  nextcloud reports not-installed — running occ maintenance:install"
    if docker exec -u www-data nextcloud php occ maintenance:install -n \
         --admin-user "${NEXTCLOUD_ADMIN_USER:-admin}" \
         --admin-pass "${NEXTCLOUD_ADMIN_PASSWORD:-}" \
         --data-dir /data \
         --database pgsql --database-name "$POSTGRES_DB" \
         --database-user "$POSTGRES_USER" --database-pass "$POSTGRES_PASSWORD" \
         --database-host "$POSTGRES_HOST" >>"$LOG" 2>&1; then
      log "  nextcloud installed"
      # occ does not apply NEXTCLOUD_TRUSTED_DOMAINS (the entrypoint does) —
      # without this entry https://cloud.$DOMAIN answers 400 untrusted domain.
      docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 \
        --value "cloud.$DOMAIN" >/dev/null 2>&1 || true
    else
      fail nextcloud_setup "occ maintenance:install failed — see $LOG"
    fi
  fi
  # Then wait for a usable instance: a cold cache (fresh image pull + the
  # ~3 min Caddy build hogging the box) blew the old 3-minute budget, so every
  # occ step below — Talk signaling/TURN, SMTP, cron — silently never ran
  # (2026-09-25). 30 minutes now, with a secondary HTTP probe to cloud.$DOMAIN
  # and a per-call occ timeout so a hanging occ never stalls the loop.
  local i=0
  while [ $i -lt 1800 ]; do
    if timeout 20 docker exec -u www-data nextcloud php occ status 2>/dev/null | grep -q "installed: true"; then
      break
    fi
    if timeout 10 curl -sk "https://cloud.$DOMAIN/" >/dev/null 2>&1; then
      break     # NC answers HTTPS → ready, even if occ is still warming the cache
    fi
    [ $((i % 30)) -eq 0 ] && log "  waiting for nextcloud to finish installing (${i}s)"
    sleep 2; i=$((i+2))
  done
  if ! timeout 20 docker exec -u www-data nextcloud php occ status 2>/dev/null | grep -q "installed: true"; then
    fail nextcloud_setup "nextcloud not installed/ready after 30 min"
    return
  fi

  # Config-driven app selection for the cloud module (config/cloud/apps.conf).
  # Now that the instance is confirmed installed, ask the operator which apps to
  # install/enable/disable/remove based on the shipped occ app list.
  ask_nc_apps

  # SMTP wiring is gated on the mail module — `mod_on mail` is the single
  # definition of that test, so this step can never disagree with what the
  # module record in wizard.state says or with the mailbox/recheck arms.
  . modules/nextcloud/.env
  if mod_on mail; then
    mailbox_add "nextcloud@$DOMAIN" "${SMTP_PASSWORD:-}" \
      || fail nextcloud_setup "mailbox nextcloud@$DOMAIN not created"
  else
    log "  mail module disabled — skipping mailbox nextcloud@$DOMAIN"
  fi

  # trusted_proxies must be a real ARRAY (NC 34 setup check) — the image
  # env TRUSTED_PROXIES writes a comma-joined string into index 0, which
  # breaks the brute-force throttle. The compose no longer carries it; set
  # it here as indexed entries (Caddy's net subnet + Cloudflare edge ranges).
  docker exec -u www-data nextcloud php occ config:system:delete trusted_proxies >/dev/null 2>&1 || true
  local p i=0
  for p in 172.22.0.0/16 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32; do
    docker exec -u www-data nextcloud php occ config:system:set trusted_proxies "$i" --value "$p" >/dev/null 2>&1
    i=$((i+1))
  done

  # NC SMTP settings — host/port/name/from/domain only when unset (never
  # clobber operator config); secure + authtype fixed unconditionally (the
  # 2026-08-31 "Email could not be sent" cause was secure=ssl on port 587).
  # Output redirected: occ config:system:set echoes secret values to stdout.
  if [ -z "$(docker exec -u www-data nextcloud php occ config:system:get mail_smtphost 2>/dev/null | tr -d '\n')" ]; then
    docker exec -u www-data nextcloud php occ config:system:set mail_smtphost --value "mail.$DOMAIN" >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_smtpport --value 587 >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_smtpname --value "nextcloud@$DOMAIN" >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_smtppassword --value "$SMTP_PASSWORD" >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_from_address --value nextcloud >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_domain --value "$DOMAIN" >/dev/null 2>&1
  fi
  docker exec -u www-data nextcloud php occ config:system:set mail_smtpsecure --value tls >/dev/null 2>&1
  docker exec -u www-data nextcloud php occ config:system:set mail_smtpauthtype --value LOGIN >/dev/null 2>&1
  # Without mail_smtpauth=true NC connects anonymously and the submission
  # server rejects every send ("Client host rejected: Access denied") — the
  # UI test email fails even though the credentials are valid.
  docker exec -u www-data nextcloud php occ config:system:set mail_smtpauth --value true >/dev/null 2>&1

  # mail_roundcube (installed+enabled automatically when mail is on) wraps the
  # Roundcube instance in an iframe and reads that iframe's DOM, so its URL
  # must be same-origin with Nextcloud: cloud.$DOMAIN/roundcube/ is the proxy
  # path on cloud.caddy (cube.$DOMAIN itself is cross-origin and throws).
  # Without externalLocation the app's own page is just the "you did not tell
  # me where to find your configured Roundcube instance" error.
  docker exec -u www-data nextcloud php occ config:app:set mail_roundcube externalLocation \
    --value "https://cloud.$DOMAIN/roundcube" >/dev/null 2>&1 || true
  # userChosenEmail is the app's own default and the only choice that leaves the
  # personal "Email Login Name" editable: with userPreferencesEmail/userIdEmail
  # the field is greyed out and the app silently feeds NC's UID or profile
  # address to the IMAP/SMTP login — and our users have no NC email set, so the
  # wrapper cannot log in at all. Each user then enters the mailbox address and
  # password under Settings → Personal → Embedded RoundCube.
  docker exec -u www-data nextcloud php occ config:app:set mail_roundcube emailAddressChoice \
    --value userChosenEmail >/dev/null 2>&1 || true

  # Single-PHP instance: serverid (int 0-511) silences the "Configuration
  # server ID" setup check; AppAPI is disabled — no external apps are used
  # (the "AppAPI default deploy daemon" check only fires while it's enabled).
  if [ -z "$(docker exec -u www-data nextcloud php occ config:system:get serverid 2>/dev/null | tr -d '\n')" ]; then
    docker exec -u www-data nextcloud php occ config:system:set serverid --value 1 --type integer >/dev/null 2>&1 || true
  fi
  # Web updater: re-asserted as the LAST step of this function (see below) —
  # the image's config/upgrade-disable-web.config.php drop-in loads after
  # config.php, so an occ write here would be silently overridden.
  # Default maintenance window: 3 AM in the instance timezone.
  docker exec -u www-data nextcloud php occ config:system:set maintenance_window_start --value 3 --type integer >/dev/null 2>&1 || true

  talk_wiring

  if [ "${CLIENT_PUSH:-false}" = "true" ]; then
    # notify_push: the app is installed by ask_nc_apps; setup points it at the
    # Caddy route and verifies the backend answers (needs the container up).
    # A still-booting push container fails the first attempt — retry before
    # declaring failure. A redis MISCONF used to fail every attempt too; that
    # was the cloud cache resolving to Mailu's read-only redis, fixed in
    # redis_door_sanity (compose service renamed to mailu-redis).
    local _np_try=0
    until docker exec -u www-data nextcloud php occ notify_push:setup "https://cloud.$DOMAIN/push" >/dev/null 2>&1; do
      _np_try=$((_np_try+1))
      [ "$_np_try" -ge 3 ] && { log "  notify_push:setup failed after 3 attempts — check the notify-push container and the /push route"; break; }
      sleep 5
    done
    [ "$_np_try" -lt 3 ] && docker exec -u www-data nextcloud php occ notify_push:self-test >/dev/null 2>&1 || true
  else
    # wizard.state is the source of truth: CLIENT_PUSH toggled OFF in a repair
    # removes the notify_push app (the container goes with the rendered compose).
    docker exec -u www-data nextcloud php occ app:remove notify_push >>"$LOG" 2>&1 \
      || docker exec -u www-data nextcloud php occ app:disable notify_push >>"$LOG" 2>&1 || true
    log "  client push disabled — notify_push removed"
  fi

  # Background jobs via the host cron (config/cron/nextcloud, installed by install-config).
  docker exec -u www-data nextcloud php occ background:cron >/dev/null 2>&1 || true

  # Silence the recurring "Skipping updater backup clean-up" warning: the
  # cleanup job expects /data/updater-<instanceid>/backups to exist.
  IID=$(docker exec -u www-data nextcloud php occ config:system:get instanceid 2>/dev/null | tr -d '\n')
  [ -n "$IID" ] && docker exec -u www-data nextcloud sh -c "mkdir -p /data/updater-$IID/backups" >/dev/null 2>&1 || true

  # Recovery manifest: users + quotas ($DATA/cloud/recovery/users.txt, kept
  # OUTSIDE the repo — instance state, generated by `make nc-capture`). Missing
  # users are created with a generated password printed ONCE at the end (the
  # pre-wipe passwords lived in the wiped DB — hand the new ones to the users).
  if [ -f "$MANIFEST_DIR/users.txt" ]; then
    while IFS='|' read -r uid quota email disp _; do
      [ -n "$uid" ] || continue
      case "$uid" in \#*) continue ;; esac
      if ! docker exec -u www-data nextcloud php occ user:list 2>/dev/null | grep -q "^  - $uid:"; then
        NP=$(openssl rand -base64 12 | tr -d '/+=' | head -c 12)
        docker exec -e OC_PASS="$NP" -u www-data nextcloud php occ user:add --password-from-env "$uid" >/dev/null 2>&1 \
          && msg "[install] new user $uid — password: $NP (share with them)"
      fi
      [ -n "$quota" ] && docker exec -u www-data nextcloud php occ user:setting "$uid" files quota "$quota" >/dev/null 2>&1
      [ -n "$email" ] && docker exec -u www-data nextcloud php occ user:setting "$uid" settings email "$email" >/dev/null 2>&1
      [ -n "$disp" ] && docker exec -u www-data nextcloud php occ user:setting "$uid" settings displayname "$disp" >/dev/null 2>&1
    done < "$MANIFEST_DIR/users.txt"
  fi

  # The vhost Host must be trusted or NC 400s every request on it. The compose
  # env NEXTCLOUD_TRUSTED_DOMAINS seeds cloud.$DOMAIN on a fresh DB — writing
  # the bare $DOMAIN into index 1 clobbers it.
  if ! docker exec -u www-data nextcloud php occ config:system:get trusted_domains 2>/dev/null | grep -qx "cloud.$DOMAIN"; then
    docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value "cloud.$DOMAIN" >/dev/null 2>&1 || true
  fi

  # Recovery manifest: apps enabled beyond the image defaults
  # ($DATA/cloud/recovery/apps.txt).
  if [ -f "$MANIFEST_DIR/apps.txt" ]; then
    while read -r app; do
      [ -n "$app" ] || continue
      case "$app" in \#*) continue ;; esac
      docker exec -u www-data nextcloud php occ app:enable "$app" >/dev/null 2>&1 || true
    done < "$MANIFEST_DIR/apps.txt"
  fi

  # Fresh installs ship with pending maintenance work that the setup check
  # surfaces as warnings — run it all up front so a fresh install is clean:
  #   - mimetype migrations (occ maintenance:repair --include-expensive)
  #   - missing DB indices/columns/primary keys (the mail app adds several)
  docker exec -u www-data nextcloud php occ maintenance:repair --include-expensive >/dev/null 2>&1 || true
  docker exec -u www-data nextcloud php occ db:add-missing-indices >/dev/null 2>&1 || true
  docker exec -u www-data nextcloud php occ db:add-missing-columns >/dev/null 2>&1 || true
  docker exec -u www-data nextcloud php occ db:add-missing-primary-keys >/dev/null 2>&1 || true

  # Recovery manifest: default quota for new users (cloud/recovery/default-quota)
  if [ -f "$MANIFEST_DIR/default-quota" ]; then
    DQ=$(grep -v '^#' "$MANIFEST_DIR/default-quota" | head -1)
    [ -n "$DQ" ] && docker exec -u www-data nextcloud php occ config:app:set files default_quota --value "$DQ" >/dev/null 2>&1 || true
  fi

  # Recovery manifest: groups (cloud/recovery/groups.txt)
  if [ -f "$MANIFEST_DIR/groups.txt" ]; then
    while IFS='|' read -r grp members _; do
      [ -n "$grp" ] || continue
      case "$grp" in \#*) continue ;; esac
      docker exec -u www-data nextcloud php occ group:addgroup "$grp" >/dev/null 2>&1 || true
      for m in ${members//,/ }; do
        [ -n "$m" ] && docker exec -u www-data nextcloud php occ group:adduser "$grp" "$m" >/dev/null 2>&1 || true
      done
    done < "$MANIFEST_DIR/groups.txt"
  fi

  # Verify what the smoke/operational docs assert. `occ` can be flaky for a few
  # seconds right after a container start (DB warm-up), so retry each check
  # before treating it as a real failure.
  occ_check() {
    local pattern="$1"; shift
    local attempt=0 rc=1
    # 12 attempts x 1 s (12 s) covers the short occ DB warm-up window after a
    # container restart — a warm-up race is TIME, not a fault, so it must not
    # hold the run for a minute (the old 60 s budget made this step feel stuck).
    while [ $attempt -lt 12 ]; do
      if "$@" | grep -q "$pattern"; then rc=0; break; fi
      attempt=$((attempt+1)); [ $attempt -lt 12 ] && sleep 1
    done
    return $rc
  }
  # The wiring only counts as done once ALL of it is visible. A slow boot is a
  # matter of TIME, not an error: verify, and if the wiring is simply not visible
  # yet, re-apply it (idempotent) and wait again — never surface the timeout as
  # an error tag that then clears on a re-check (2026-10-15: 'occ wiring
  # incomplete' was raised, then solved itself; that is a race, not a fault).
  nc_wiring_ok() {
    # SMTP is only wired when the mail module is enabled (see the mailbox step).
    if mod_on mail; then
      occ_check "mail.$DOMAIN" docker exec -u www-data nextcloud php occ config:system:get mail_smtphost 2>/dev/null \
        || return 1
      # The wrapper is only usable if it knows where its Roundcube is and
      # leaves the personal login name editable (see the app-config block
      # above); verified here so repair mode re-applies both.
      occ_check "https://cloud.$DOMAIN/roundcube" docker exec -u www-data nextcloud php occ config:app:get mail_roundcube externalLocation 2>/dev/null \
        || return 1
      occ_check "userChosenEmail" docker exec -u www-data nextcloud php occ config:app:get mail_roundcube emailAddressChoice 2>/dev/null \
        || return 1
    fi
    occ_check "https://talk.$DOMAIN/signaling" docker exec -u www-data nextcloud php occ talk:signaling:list 2>/dev/null \
      || return 1
    occ_check "talk.$DOMAIN:3478" docker exec -u www-data nextcloud php occ talk:turn:list 2>/dev/null \
      || return 1
    return 0
  }
  if ! nc_wiring_ok; then
    # The wiring is idempotent and self-heals, so this step NEVER raises an
    # error: re-apply and re-verify a few times, quietly. A slow cold boot used
    # to surface 'occ wiring incomplete', which then cleared itself on the
    # re-check (2026-10-15) — a race the operator should not have to see.
    local _try=0
    while [ $_try -lt 3 ] && ! nc_wiring_ok; do
      log "  nextcloud occ wiring not confirmed yet — re-applying (attempt $((_try+1))/3)"
      nextcloud_occ_remediate
      _try=$((_try+1))
    done
    if nc_wiring_ok; then
      log "  nextcloud occ wiring confirmed after re-apply"
    else
      log "  WARNING: occ wiring not confirmed after re-apply — non-fatal, no error raised (the wiring is idempotent and settles on its own; check $LOG if a UI symptom appears)"
    fi
  fi

  # LAST (priority step): the web updater is ON, unconditionally.
  # `updatenotification` gates the admin's "Open updater" button on
  # `webUpdaterEnabled` = !upgrade.disable-web, so the key must be false, and
  # the independent updater app must exist at /var/www/html/updater (the FPM
  # image ships no such tree; Caddy must not block the path either — see
  # modules/caddy/vhosts/cloud.caddy). /var/www/html here is the HOST bind
  # mount data/cloud/html, not the image filesystem, so an update the updater
  # performs survives container recreation; only the compose image tag then
  # lags the installed code (that is why nc-core-update.sh refuses a downgrade).
  # Written into the drop-in, not only config.php: every config/*.config.php
  # loads AFTER config.php, so an occ-only write is silently overridden and the
  # key keeps reading back the image default.
  docker exec -u www-data nextcloud php -r 'file_put_contents("/var/www/html/config/upgrade-disable-web.config.php", "<?php\n\$CONFIG = array (\n  \"upgrade.disable-web\" => false,\n);\n");' >/dev/null 2>&1 || true
  docker exec -u www-data nextcloud php occ config:system:set upgrade.disable-web --value false --type boolean >/dev/null 2>&1 || true

  # Updater tree, pinned to the running server's major. The release tarball is
  # self-contained (index.php is the built web updater, vendor/ ships with it).
  # Idempotent: an existing index.php is left alone — keeping it current is the
  # updater's own job, and a rewrite mid-update would be fatal.
  local nc_major upd_tag upd_tmp
  upd_tmp="${ROOT}/data/cloud/html/updater"
  if [ ! -f "$upd_tmp/index.php" ]; then
    nc_major=$(docker exec -u www-data nextcloud php occ config:system:get version 2>/dev/null | tr -d '\r\n')
    nc_major=${nc_major%%.*}
    upd_tag=$(curl -fsSL --max-time 20 "https://api.github.com/repos/nextcloud/updater/tags?per_page=100" 2>/dev/null \
      | sed -n 's/.*"name": *"\(v'"${nc_major:-x}"'\.[0-9.]*\)".*/\1/p' | head -1)
    [ -n "$upd_tag" ] || upd_tag="v${nc_major}.0.0"
    rm -rf "$upd_tmp.tmp" && mkdir -p "$upd_tmp.tmp"
    if curl -fsSL --max-time 120 "https://github.com/nextcloud/updater/archive/refs/tags/${upd_tag}.tar.gz" \
         | tar xz -C "$upd_tmp.tmp" --strip-components=1 2>/dev/null; then
      rm -rf "$upd_tmp" && mv "$upd_tmp.tmp" "$upd_tmp"
      sudo chown -R 33:33 "$upd_tmp"
      log "  web updater tree installed at data/cloud/html/updater ($upd_tag)"
    else
      rm -rf "$upd_tmp.tmp"
      log "  WARNING: could not fetch the web updater tree ($upd_tag) — the Open updater button will 404 until data/cloud/html/updater exists"
    fi
  fi

  # FINAL: recycle the web workers. occ runs in its own process, while app
  # config is cached per PHP-FPM worker in APCu (memcache.local = APCu,
  # cache_app_config defaults to true) — a value set with occ can stay
  # invisible to the running workers, and the web UI keeps serving the OLD
  # value with no trace in the DB (this is what kept the personal "Email Login
  # Name" greyed out: the DB said userChosenEmail, the workers still had
  # userPreferencesEmail). USR2 is php-fpm's graceful reload; php-fpm is PID 1
  # in this image, workers are recycled and re-read the DB — no downtime, no
  # restart of the container (and NO other occ command is needed).
  docker exec nextcloud sh -c 'kill -USR2 1' >>"$LOG" 2>&1 \
    || log "  php-fpm reload failed — app config changes may need a nextcloud restart"
}

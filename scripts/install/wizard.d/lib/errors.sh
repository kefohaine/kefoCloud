# wizard.d/lib/errors.sh — tagged problems/hints, the re-check loop and the pause-and-resolve gate.

# Pause the checklist on a failed task and hand the operator the error BELOW the
# to-do list; once they resolve it, the error block is wiped and the list comes
# back, and the run continues from the next task. The failed row flips to [DONE]
# when its tags clear. If a tag is still unresolved (or there is no terminal to
# re-check on) the function returns non-zero and run_install HARD-STOPS: the
# remaining tasks are left [WAIT] and the installer stops — it never runs on
# past a failure and marks the rest [DONE].
pause_and_resolve() {
  local tag still
  # Stop the animator for the whole exchange: the error block and its prompt are
  # printed BELOW the to-do list, and a live animator would keep repainting the
  # running row inside the block being written (the 2026-10-16 overlap). Every
  # exit path takes the matching _task_resume (which wipes the tail and restores
  # the block), so the checklist always comes back on its own row.
  _task_pause
  while [ ${#ERR_TAGS[@]} -gt 0 ]; do
    _note ""
    _note "$(printf '%s┌─ [FAIL]%s resolve to continue' "$C_RED" "$C_RST")"
    for tag in "${ERR_TAGS[@]}"; do
      _note "$(printf '   %s%s%s — %s%s' "$C_ORANGE" "$tag" "$C_RST" "$(problem "$tag")" "${ERR_DETAIL[$tag]:+ (${ERR_DETAIL[$tag]})}")"
      _note "$(printf '     %shint:%s %s' "$C_GREY" "$C_RST" "$(hint "$tag")")"
    done
    _note "$(printf '%s└──────────────────────────────────────────────%s' "$C_RED" "$C_RST")"
    # No terminal to answer on (piped / cron / CI): the error cannot be resolved
    # here, so stop LOUD instead of running on through the rest of the checklist.
    if [ ! -t 0 ]; then _tail_clear; _task_resume; return 1; fi
    printf '%s[INFO]%s Fix / complete the items above, then press Enter to re-check (Ctrl-C aborts): ' "$C_GREY" "$C_RST"
    # The prompt line wraps to 2+ screen rows at 80 cols — count it via the same
    # physical-row rule as _note, or every Enter cycle drifts the checklist one
    # row down (the "Nextcloud Setupp" tear, 2026-10-19).
    local _pn="[INFO] Fix / complete the items above, then press Enter to re-check (Ctrl-C aborts): "
    local _pnrows=$(_wrapped_rows "$_pn")
    # Aborted (Ctrl-C / EOF) with the error still open → hard stop.
    read -r _ || { _task_count "$_pnrows"; _tail_clear; _task_resume; return 1; }
    _task_count "$_pnrows"
    still=()
    for tag in "${ERR_TAGS[@]}"; do
      # Re-run the tag's own idempotent setup first (a recorded setup failure is
      # not a boolean to probe), then inspect the state it leaves.
      case "$tag" in
        dkim_setup) mail_wait_ready 2>/dev/null || true; dkim_setup ;;
        nextcloud_setup) mail_wait_ready 2>/dev/null || true; nextcloud_setup ;;
        vaultwarden_setup) vaultwarden_setup ;;
      esac
      if recheck "$tag"; then
        _note "$(printf '   %s✓ solved%s: %s' "$C_GREEN" "$C_RST" "$tag")"
      else
        still+=("$tag")
      fi
    done
    ERR_TAGS=("${still[@]}")
    # Wipe the block (errors + this prompt) and redraw the to-do list before
    # looping again (still unresolved) or continuing (resolved).
    _tail_clear
    [ ${#ERR_TAGS[@]} -eq 0 ] && { TASK_STATE[$TASK_CUR]=done; _task_update "$TASK_CUR"; }
  done
  _task_resume
  return 0
}


# ──────────────────────── error problems + hints ──────────────────────────

problem() {
  case "$1" in
    apt)            echo "apt packages not installed" ;;
    goose)          echo "goose binary not installed" ;;
    user)           echo "user 'root' not created" ;;
    ssh_keys)       echo "no SSH key on the box although the installer asks for one up front" ;;
    render)         echo "template rendering failed (see make render)" ;;
    tailscale)      echo "tailscale binary not installed" ;;
    tailscale_up)   echo "tailscale did not connect" ;;
    ts_ip)          echo "no tailscale IP assigned" ;;
    install_config) echo "host services are not up (make install-config failed)" ;;
    fail2ban)       echo "fail2ban is not running (sshd jail dead)" ;;
    caddy)          echo "caddy container is not running" ;;
    nextcloud)      echo "nextcloud container is not running (or talk-hpb/talk-relay are down)" ;;
    nextcloud_db)   echo "postgresql container is not running (docker-compose.db.yml)" ;;
    vaultwarden)    echo "vaultwarden container is not running" ;;
    kuma)           echo "uptimekuma container is not running" ;;
    mailserver)     echo "Mailu front container (mailu-front) is not running (mail platform)" ;;
    datadirectory)  echo "nextcloud datadirectory is not /data" ;;
    talk_gen)       echo "nextcloud stack secrets not generated (make talk-gen failed)" ;;
    kuma_admin)     echo "uptime kuma admin user is missing" ;;
    kuma_seed)      echo "uptime kuma monitors are not seeded" ;;
    zone)           echo "Cloudflare zone '$DOMAIN' not found" ;;
    dns_*)          echo "DNS record for ${1#dns_}.$DOMAIN is missing" ;;
    cert_*)         echo "cert for ${1#cert_}.$DOMAIN is not issued by Let's Encrypt" ;;
    sweep)          echo "old project name is still referenced in the repo tree" ;;
    sslmode)        echo "Cloudflare SSL/TLS mode is not Full (or strict)" ;;
    nextcloud_setup) echo "Nextcloud occ wiring incomplete (Talk signaling/TURN, SMTP, background cron, mail_roundcube externalLocation/emailAddressChoice)" ;;
    dkim_setup)      echo "DKIM key / dkim._domainkey TXT record not published" ;;
    dns_mail_txt)   echo "one or more mail records (MX, SPF, DMARC) are missing" ;;
    vaultwarden_setup) echo "Vaultwarden SMTP sender mailbox missing (vaultwarden@$DOMAIN)" ;;
    vaultwarden_admin) echo "the default vaultwarden account is missing" ;;
    clone)          echo "repo clone failed" ;;
    hooks)          echo "git hooks are not installed in $REPO/.git/hooks" ;;
    github_key)     echo "the GitHub key could not be created" ;;
    github_auth)    echo "GitHub remote access was requested but the key is not authorized / nothing was pushed" ;;
    github_push)    echo "the requested GitHub push did not happen" ;;
    *)              echo "$1" ;;
  esac
}

hint() {
  case "$1" in
    apt)            echo "install git curl make sudo dnsmasq ufw jq apache2-utils sqlite3 python3-yaml, plus docker with the compose plugin (docker-ce from download.docker.com on trixie), then re-check" ;;
    goose)          echo "install bzip2 first (the release is a .tar.bz2: apt-get install -y bzip2), then: curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | CONFIGURE=false GOOSE_BIN_DIR=/usr/local/bin bash, then re-check" ;;
    user)           echo "run: adduser --disabled-password --gecos '' root && usermod -aG sudo,docker root, then re-check" ;;
    ssh_keys)       echo "paste your device's public key into /root/.ssh/authorized_keys (or re-run the installer), then re-check" ;;
    tailscale)      echo "run: curl -fsSL https://tailscale.com/install.sh | sh, then re-check" ;;
    tailscale_up)   echo "check the auth key (admin console -> Settings -> Keys) and run: tailscale up --authkey=<key>, then re-check" ;;
    ts_ip)          echo "wait a few seconds, then run: tailscale ip -4, then re-check" ;;
    install_config) echo "run: make install-config in $REPO, then re-check" ;;
    fail2ban)       echo "ensure /etc/fail2ban/jail.d/sshd.conf has backend = systemd, then: systemctl restart fail2ban; fail2ban-client status sshd" ;;
    caddy)          echo "run: make dok-recreate-caddy, then re-check" ;;
    nextcloud)      echo "run: make dok-recreate-nextcloud, then re-check" ;;
    nextcloud_db)   echo "run: make dok-recreate-nextcloud-db, then re-check" ;;
    talk_gen)       echo "run: make talk-gen in $REPO, then re-check" ;;
    vaultwarden)    echo "run: make dok-recreate-vaultwarden, then re-check" ;;
    kuma)           echo "run: make dok-recreate-uptimekuma, then re-check" ;;
    mailserver)     echo "run: make dok-recreate-mailserver, then re-check" ;;
    homarr)         echo "run: make dok-recreate-homarr, then re-check (SECRET_ENCRYPTION_KEY must be set in modules/homarr/.env)" ;;
    homer)          echo "run: make dok-recreate-homer, then re-check (its config is rendered: make render)" ;;
    datadirectory)  echo "run: docker exec -w /var/www/html nextcloud php occ config:system:set datadirectory --value /data, then re-check" ;;
    kuma_admin)     echo "create the admin account at https://kuma.$DOMAIN in the UI, then re-check" ;;
    kuma_seed)      echo "run: make dok-recreate-uptimekuma (UPTIME_KUMA_DB_TYPE=sqlite makes Kuma create its schema), wait for /app/data/kuma.db to have tables, then: docker exec -i uptimekuma sqlite3 /app/data/kuma.db < modules/uptimekuma/seed-monitors.sql" ;;
    zone)           echo "add $DOMAIN as a zone in the Cloudflare dashboard, then re-check" ;;
    dns_*)          echo "create an A record ${1#dns_}.$DOMAIN -> ${HOST_IP:-<machine IP>} in Cloudflare (turn must be DNS-only/grey-cloud — TURN bypasses the proxy; the rest proxied), then re-check" ;;
    cert_*)         echo "hit https://${1#cert_}.$DOMAIN once to trigger ACME, wait a few seconds, then re-check" ;;
    sweep)          echo "rename or remove the files listed by: grep -rlI $GITHUB_USER $REPO --exclude-dir=.git --exclude-dir=docs --exclude-dir=archives --exclude-dir=scripts, then re-check" ;;
    sslmode)        echo "Cloudflare dashboard -> SSL/TLS -> Overview -> set mode to Full (or Full strict), then re-check" ;;
    nextcloud_setup) echo "the occ wiring is re-applied automatically on each re-check (nextcloud_occ_remediate); if it still fails, ensure the nextcloud/talk containers are up (make dok-recreate-nextcloud) and the mail module's SMTP_PASSWORD exists in modules/nextcloud/.env — see the nextcloud_setup function in this script, then re-check" ;;
    dkim_setup)      echo "re-run the wizard (dkim_setup generates the key through Mailu's ORM when the domain has none), verify the CF token has Zone > DNS > Edit, then dig @<zone NS> TXT dkim._domainkey.$DOMAIN" ;;
    dns_mail_txt)   echo "the installer retries the MX, SPF and DMARC records on re-check; verify the token has Zone > DNS > Edit and inspect Cloudflare DNS for $DOMAIN (MX -> mail.$DOMAIN, TXT v=spf1 a:mail.$DOMAIN mx -all, _dmarc)" ;;
    vaultwarden_setup) echo "the mail step waits for the mailserver's account API (mail_wait_ready) then retries the add — a repeat failure means SMTP_PASSWORD is missing from modules/vaultwarden/.env; verify the mail module is enabled (else this step is skipped) and that the mailserver container is healthy (make smoke), then re-check" ;;
    vaultwarden_admin) echo "run: make vaultwarden-list-users / vaultwarden-add-user EMAIL=… PASS=… (scripts/modules/vaultwarden-user.sh); the account needs the vaultwarden container's DB, then re-check" ;;
    clone)          echo "the clone is HTTPS (the repo is public) — check network/DNS, then re-check" ;;
    hooks)          echo "run: make install-hooks in $REPO (re-run it after editing a hook)" ;;
    github_key)     echo "check /root/.ssh is writable (mkdir -p /root/.ssh && chmod 700 /root/.ssh), then re-check" ;;
    github_auth)    echo "authorize the installer's printed public key at GitHub -> Settings -> SSH and GPG keys -> New SSH key, then re-check" ;;
    github_push)    echo "the log line just above says why — unknown account, missing commit identity, an unauthorized key (paste it at GitHub -> Settings -> SSH and GPG keys), or a rejected push (run 'make fetch' / 'git pull --rebase', then re-run the installer)" ;;
    *)              echo "" ;;
  esac
}

recheck() {
  case "$1" in
    apt) command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && dpkg -s git curl make sudo dnsmasq ufw jq apache2-utils sqlite3 python3-yaml >/dev/null 2>&1 ;;
    goose) command -v goose >/dev/null 2>&1 || [ -x /usr/local/bin/goose ] ;;
    user) id -u "root" >/dev/null 2>&1 ;;
    ssh_keys) [ -s /root/.ssh/authorized_keys ] ;;
    github_key) [ -s /root/.ssh/github_key ] ;;
    github_auth) github_auth_ok ;;
    render) bash "$REPO/scripts/render/render-all.sh" >/dev/null 2>&1 ;;
    tailscale) command -v tailscale >/dev/null 2>&1 ;;
    prep_dirs) prep_dirs >>"$LOG" 2>&1; prep_dirs_verify ;;
    tailscale_up) tailscale ip -4 >/dev/null 2>&1 ;;
    ts_ip) [ -n "$(tailscale ip -4 2>/dev/null | head -1)" ] ;;
    install_config) systemctl is-active --quiet ttyd dnsmasq goose ;;
    fail2ban) systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1 ;;
    caddy) docker ps --format '{{.Names}}' | grep -qx caddy ;;
    nextcloud) docker ps --format '{{.Names}}' | grep -qx nextcloud && docker ps --format '{{.Names}}' | grep -qx talk-hpb && docker ps --format '{{.Names}}' | grep -qx talk-relay ;;
    nextcloud_db) docker ps --format '{{.Names}}' | grep -qx postgresql ;;
    vaultwarden) docker ps --format '{{.Names}}' | grep -qx vaultwarden ;;
    kuma) docker ps --format '{{.Names}}' | grep -qx uptimekuma ;;
    mailserver) docker ps --format '{{.Names}}' | grep -qx mailu-front && docker ps --format '{{.Names}}' | grep -qx roundcube ;;
    datadirectory) if docker exec -w /var/www/html nextcloud php occ status 2>/dev/null | grep -q "installed: true"; then [ "$(docker exec -w /var/www/html nextcloud php occ config:system:get datadirectory 2>/dev/null | tr -d '\n')" = "/data" ]; else true; fi ;;
    kuma_admin) [ "$(docker exec uptimekuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM user WHERE username='admin';" 2>/dev/null | tr -d '\n')" = "1" ] ;;
    kuma_seed) [ "$(docker exec uptimekuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM monitor;" 2>/dev/null | tr -d '\n')" -gt 0 ] ;;
    zone) [ -n "$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')" ] ;;
    dns_*) local h=${1#dns_}; [ -n "$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$h.$DOMAIN" | jq -r '.result[0].id // empty')" ] ;;
    cert_*) local h=${1#cert_}; echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$h.$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | grep -q "Let's Encrypt" ;;
    sweep) [ -z "$(sweep_hits)" ] ;;
    sslmode) ssl_mode_full ;;
    nextcloud_setup) nextcloud_occ_remediate; if ! mod_on mail || { docker exec -u www-data nextcloud php occ config:system:get mail_smtphost 2>/dev/null | grep -q "mail.$DOMAIN" && docker exec -u www-data nextcloud php occ config:app:get mail_roundcube externalLocation 2>/dev/null | grep -qx "https://cloud.$DOMAIN/roundcube" && docker exec -u www-data nextcloud php occ config:app:get mail_roundcube emailAddressChoice 2>/dev/null | grep -qx "userChosenEmail"; }; then docker exec -u www-data nextcloud php occ talk:signaling:list 2>/dev/null | grep -q "https://talk.$DOMAIN/signaling" && docker exec -u www-data nextcloud php occ talk:turn:list 2>/dev/null | grep -q "talk.$DOMAIN:3478" && docker exec -u www-data nextcloud php occ config:system:get trusted_domains 2>/dev/null | grep -qx "cloud.$DOMAIN"; else false; fi ;;
    dkim_setup)      dig +short TXT "dkim._domainkey.$DOMAIN" @"$(dig +short NS "$DOMAIN" | head -1)" 2>/dev/null | tr -d '"' | grep -qE 'p=[A-Za-z0-9+/=]{100,}' ;;
    dns_mail_txt) mod_on mail || return 0; cf_mail_dns; local records; records=$(curl -fsS -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" 2>/dev/null) || return 1; printf '%s' "$records" | jq -e --arg d "$DOMAIN" --arg s "v=spf1 a:mail.$DOMAIN mx -all" --arg m 'v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s;' '[.result[] | {type,name,content}] as $r | [[$d,"MX"],["_dmarc."+$d,"TXT"]] as $fs | [($fs[] | . as $x | any($r[]; .type==$x[1] and .name==$x[0])), any($r[]; .type=="TXT" and .name==$d and .content==$s)] | all' >/dev/null ;;
    vaultwarden_setup) if mod_on mail; then . modules/vaultwarden/.env 2>/dev/null; mailbox_add "vaultwarden@$DOMAIN" "${SMTP_PASSWORD:-}" >/dev/null 2>&1; mailbox_exists "vaultwarden@$DOMAIN"; else false; fi ;;
    vaultwarden_admin) [ -n "${VAULTWARDEN_ADMIN_USER:-}" ] && bash "$REPO/scripts/modules/vaultwarden-user.sh" list 2>/dev/null | grep -qF "$VAULTWARDEN_ADMIN_USER" ;;
    *) false ;;
  esac
}

is_expected() {
  case "$1" in
    zone|clone|sslmode|github_auth) return 0 ;;  # input prerequisites / dashboard steps the script can't do
    *) return 1 ;;
  esac
}

resolve_errors() {
  local remaining=("${ERR_TAGS[@]}")
  while [ ${#remaining[@]} -gt 0 ]; do
    local exp=() unexp=()
    for tag in "${remaining[@]}"; do
      if is_expected "$tag"; then exp+=("$tag"); else unexp+=("$tag"); fi
    done
    if [ ${#exp[@]} -gt 0 ]; then
      _section "Manual steps (expected)" "$C_ORANGE"
      for i in "${!exp[@]}"; do
        _note "$(printf '  %s%d.%s %s%s%s' "$C_ORANGE" "$((i+1))" "$C_RST" "$C_ORANGE" "${exp[$i]}" "$C_RST")"
        _note "$(printf '     %sproblem:%s %s%s' "$C_GREY" "$C_RST" "$(problem "${exp[$i]}")" "${ERR_DETAIL[${exp[$i]}]:+ (${ERR_DETAIL[${exp[$i]}]})}")"
        _note "$(printf '     %shint:%s %s' "$C_GREY" "$C_RST" "$(hint "${exp[$i]}")")"
      done
    fi
    if [ ${#unexp[@]} -gt 0 ]; then
      _section "Unexpected errors (${#unexp[@]})" "$C_RED"
      for i in "${!unexp[@]}"; do
        _note "$(printf '  %s%d.%s %s%s%s' "$C_RED" "$((i+1))" "$C_RST" "$C_RED" "${unexp[$i]}" "$C_RST")"
        _note "$(printf '     %sproblem:%s %s%s' "$C_GREY" "$C_RST" "$(problem "${unexp[$i]}")" "${ERR_DETAIL[${unexp[$i]}]:+ (${ERR_DETAIL[${unexp[$i]}]})}")"
        _note "$(printf '     %shint:%s %s' "$C_GREY" "$C_RST" "$(hint "${unexp[$i]}")")"
      done
    fi
    if [ ! -t 0 ]; then
      # No terminal to answer on (piped/cron/CI run): a re-check prompt would
      # park the run forever with no way to proceed. Record the pending state
      # and stop LOUD instead — the errors above are already printed.
      _note "No terminal to re-check on — recording finished=false and stopping."
      FINISHED=false
      write_state
      exit 1
    fi
    printf '%s[INFO]%s Fix / complete the items above, then press Enter to re-check (Ctrl-C aborts): ' "$C_GREY" "$C_RST"
    read -r input \
      || { _note "No terminal input — aborting."; exit 1; }
    _task_count "$(_wrapped_rows "[INFO] Fix / complete the items above, then press Enter to re-check (Ctrl-C aborts): ")"
    local still=()
    for tag in "${remaining[@]}"; do
      # A recorded setup failure is not a boolean to probe — re-RUN its setup
      # step first (the steps are idempotent), then inspect the state it leaves.
      # Without this a tag whose recheck arm inspects occ config (nextcloud_setup)
      # or a mailbox (vaultwarden_setup) can never heal: nextcloud_setup's own
      # wiring only ran during the failed pass, and the containers it was running
      # against are recreated by then (2026-10-15).
      case "$tag" in
        nextcloud_setup) mail_wait_ready 2>/dev/null || true; nextcloud_setup;;
        vaultwarden_setup) vaultwarden_setup;;
        dkim_setup) mail_wait_ready 2>/dev/null || true; dkim_setup;;
      esac
      if recheck "$tag"; then
        _note "$(printf '   %s✓ solved%s: %s — %s' "$C_GREEN" "$C_RST" "$tag" "$(problem "$tag")")"
      else
        still+=("$tag")
      fi
    done
    remaining=("${still[@]}")
  done
  ERR_TAGS=()
  write_state
  # Host hardening is a HOST concern: applied here, after the stack checks, so a
  # run that leaves sshd, ufw or the installer's temporary SSH rule alone keeps
  # them exactly as they were.
  finalize_hardening
  finalize_install
}

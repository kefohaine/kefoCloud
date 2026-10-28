# wizard.d/modules/nextcloud/occ.sh — re-applies the occ wiring when it is not visible yet (the slow-boot race).

# Automated remediation for a nextcloud_setup failure: re-apply the idempotent
# occ wiring (talk signaling + TURN, mail_*, background cron, trusted_proxies,
# trusted_domains) that a cold cache / slow boot can leave unrun, then re-check.
# Called by recheck() for the nextcloud_setup tag, so a mid-install failure
# heals itself on the next re-check instead of asking the operator to run the
# occ steps by hand.
nextcloud_occ_remediate() {
  docker exec -u www-data nextcloud php occ status 2>/dev/null | grep -q "installed: true" || return 1
  . modules/nextcloud/.env 2>/dev/null || true
  local sig trn
  docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 \
    --value "cloud.$DOMAIN" >/dev/null 2>&1 || true
  docker exec -u www-data nextcloud php occ config:system:delete trusted_proxies >/dev/null 2>&1 || true
  local p i=0
  for p in 172.22.0.0/16 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32; do
    docker exec -u www-data nextcloud php occ config:system:set trusted_proxies "$i" --value "$p" >/dev/null 2>&1
    i=$((i+1))
  done
  if mod_on mail; then
    docker exec -u www-data nextcloud php occ config:system:set mail_smtphost --value "mail.$DOMAIN" >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_smtpport --value 587 >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_smtpname --value "nextcloud@$DOMAIN" >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_smtppassword --value "${SMTP_PASSWORD:-}" >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_from_address --value nextcloud >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_domain --value "$DOMAIN" >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_smtpsecure --value tls >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_smtpauthtype --value LOGIN >/dev/null 2>&1
    docker exec -u www-data nextcloud php occ config:system:set mail_smtpauth --value true >/dev/null 2>&1
    # mail_roundcube app config (externalLocation + emailAddressChoice): the
    # app is re-installed from the appstore on a cold install, which drops its
    # config, so re-assert both here — same values and rationale as the
    # nextcloud_setup block; userChosenEmail is what keeps the personal "Email
    # Login Name" editable and is the only choice that works with an empty NC
    # profile email.
    docker exec -u www-data nextcloud php occ config:app:set mail_roundcube externalLocation \
      --value "https://cloud.$DOMAIN/roundcube" >/dev/null 2>&1 || true
    docker exec -u www-data nextcloud php occ config:app:set mail_roundcube emailAddressChoice \
      --value userChosenEmail >/dev/null 2>&1 || true
  fi
  sig=$(docker exec -u www-data nextcloud php occ talk:signaling:list 2>/dev/null)
  echo "$sig" | grep -q "https://talk.$DOMAIN/signaling" \
    || docker exec -u www-data nextcloud php occ talk:signaling:add "https://talk.$DOMAIN/signaling" "$SIGNALING_SECRET" >/dev/null 2>&1 || true
  trn=$(docker exec -u www-data nextcloud php occ talk:turn:list 2>/dev/null)
  echo "$trn" | grep -q "talk.$DOMAIN:3478" \
    || docker exec -u www-data nextcloud php occ talk:turn:add turn "talk.$DOMAIN:3478" "udp,tcp" --secret "$TURN_SECRET" >/dev/null 2>&1 || true
  echo "$trn" | grep -q "talk.$DOMAIN:5349" \
    || docker exec -u www-data nextcloud php occ talk:turn:add turns "talk.$DOMAIN:5349" "tcp" --secret "$TURN_SECRET" >/dev/null 2>&1 || true
  # Same as nextcloud_setup: force every call through the HPB and our coturn.
  docker exec -u www-data nextcloud php occ config:app:set spreed signaling_mode \
    --value external >/dev/null 2>&1 || true
  docker exec -u www-data nextcloud php occ config:app:set spreed stun_servers \
    --value "[\"stun:talk.$DOMAIN:3478\"]" >/dev/null 2>&1 || true
  docker exec -u www-data nextcloud php occ background:cron >/dev/null 2>&1 || true
  # Same reason as the FINAL block of nextcloud_setup: app config is cached per
  # PHP-FPM worker in APCu, so values written here (occ = its own process) stay
  # invisible to the web UI until the workers are recycled. USR2 = graceful
  # php-fpm reload (php-fpm is PID 1 in this image), no downtime.
  docker exec nextcloud sh -c 'kill -USR2 1' >/dev/null 2>&1 || true
}

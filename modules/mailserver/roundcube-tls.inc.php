<?php
// Roundcube overrides for the mail platform.
// The image entrypoint writes imap_host/smtp_host from env without a TLS
// prefix, and Mailu's imap/smtp reject plaintext auth — so override both to
// STARTTLS against the cert FQDN. The entrypoint includes every
// /var/roundcube/config/*.php into config.docker.inc.php, which loads after the
// env-derived settings. The FQDN is mailu-front's own hostname and is mapped to
// its bridge IP via `extra_hosts` in the compose file, so SNI + cert match.
$config['imap_host'] = 'tls://mail.{{DOMAIN}}:143';
$config['smtp_host'] = 'tls://mail.{{DOMAIN}}:587';

// Anti-spoofing: users may NOT add or edit identities with a different email
// address (level 3 = single identity, address locked to the login mailbox).
// Roundcube's default (0) lets any user add an identity like admin@{{DOMAIN}}
// and send From: it. Level 3 still allows editing name/signature.
$config['identities_level'] = 3;

// Same-origin door for the Nextcloud mail_roundcube app: cloud.{{DOMAIN}}
// proxies /roundcube/ here with the prefix stripped and forwarded in
// X-Forwarded-Prefix (modules/caddy/vhosts/cloud.caddy). Roundcube derives its
// base path from REQUEST_URI, which no longer carries the prefix, so put it
// back — otherwise the iframe's form POSTs and redirects leave the route.
if (($_SERVER['HTTP_X_FORWARDED_PREFIX'] ?? '') === '/roundcube') {
    $config['request_path'] = '/roundcube';
}

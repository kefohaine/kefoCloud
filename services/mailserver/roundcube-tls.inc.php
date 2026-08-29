<?php
// Roundcube overrides for the mail platform.
// docker-mailserver's entrypoint writes imap_host/smtp_host from env without a
// TLS prefix, and dovecot + postfix reject plaintext auth (disable_plaintext_auth,
// submission requires TLS) — so override both to STARTTLS against the cert FQDN.
// The entrypoint includes every /var/roundcube/config/*.php into
// config.docker.inc.php, which is loaded after the env-derived settings.
// The FQDN is mapped to the mail container's bridge IP via `extra_hosts` in
// the compose file, so SNI + cert verification match.
$config['imap_host'] = 'tls://mail.fxmq.net:143';
$config['smtp_host'] = 'tls://mail.fxmq.net:587';

// Anti-spoofing: users may NOT add or edit identities with a different email
// address (level 3 = single identity, address locked to the login mailbox).
// Roundcube's default (0) lets any user add an identity like admin@fxmq.net
// and send From: it. Level 3 still allows editing name/signature.
$config['identities_level'] = 3;

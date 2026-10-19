<?php
// Roundcube overrides for the mail platform.
// The image entrypoint writes imap_host/smtp_host from env without a TLS
// prefix, and Mailu's imap/smtp reject plaintext auth — so override both to
// STARTTLS against the cert FQDN. The entrypoint includes every
// /var/roundcube/config/*.php into config.docker.inc.php, which loads after the
// env-derived settings. The FQDN is mapped to mailu-front's bridge IP via
// `extra_hosts` in the compose file, so SNI + cert verification match.
$config['imap_host'] = 'tls://mail.{{DOMAIN}}:143';
$config['smtp_host'] = 'tls://mail.{{DOMAIN}}:587';

// Anti-spoofing: users may NOT add or edit identities with a different email
// address (level 3 = single identity, address locked to the login mailbox).
// Roundcube's default (0) lets any user add an identity like admin@{{DOMAIN}}
// and send From: it. Level 3 still allows editing name/signature.
$config['identities_level'] = 3;

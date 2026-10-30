-- prosody-extra.cfg.lua — included LAST by Snikket's generated prosody.cfg.lua
-- (SNIKKET_TWEAK_EXTRA_CONFIG). Global scope, so these are defaults for every
-- host and component: the main host, share.<domain> (XEP-0363 uploads) and
-- groups.<domain>.
--
-- Browsers reach this server through the Caddy edge, which terminates TLS on
-- 443 and re-encrypts to Snikket's own 5443. The inner hop IS https, so prosody
-- must classify BOSH/websocket sessions as secure — otherwise it advertises a
-- ws:// endpoint on an https page and the browser refuses the connection.
consider_bosh_secure = true
consider_websocket_secure = true

-- Cross-origin HTTP: web clients hosted on ANOTHER origin (a public Converse.js
-- page, an app shell) must be able to open BOSH and the websocket. Prosody then
-- answers the preflight itself and sends exactly one Access-Control-Allow-Origin.
-- The upload component (/upload, XEP-0363) gets its CORS from the edge vhost.
cross_domain_bosh = true
cross_domain_websocket = true

-- Raw connection throughput: a bigger accept backlog absorbs bursts (many
-- clients reconnecting at once after a network blip) instead of dropping SYNs.
network_settings = {
	tcp_backlog = 511;
}

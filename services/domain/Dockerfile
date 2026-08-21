# Caddy + Cloudflare DNS plugin. The stock caddy:2.x image does NOT
# include caddy-dns/cloudflare ("module not registered" on the vhost's
# `tls { dns cloudflare { ... } }` directive), so we build a custom
# image with the official xcaddy pipeline. xcaddy itself is a Go-based
# Caddy build tool — it pulls the upstream Caddy source, plugs in any
# modules listed via `-with`, and emits a static binary. We then copy
# that binary into the runtime stage so the final image stays tiny.
#
# Pin caddy to the same version as the old stock image (2.11.4) so the
# config semantics stay identical to what the Caddyfile was tested
# against. Pin the cloudflare module to a specific tag rather than
# `@latest` so an upstream breaking change can't silently stop the
# Caddyfile from parsing.
#
# Build is invoked by `make recreate-domain` (the compose file's `build:`
# triggers a rebuild when this Dockerfile changes). On a fresh host
# the first `up-domain` pulls the xcaddy + golang base images, which
# is a one-time ~1 GB download; subsequent builds are <30 s.
FROM golang:1.25-bookworm AS builder
# caddy 2.11.4 requires Go >= 1.25.1 — the `golang:1.25-bookworm` image
# ships exactly that, so the toolchain is satisfied without falling
# back to a GOTOOLCHAIN=auto download. xcaddy is the official Caddy
# build tool that pulls the upstream source and links in extra modules.
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
# Pull caddy-dns/cloudflare from master (commit a8737d0) rather than
# the v0.2.3 tag — PR #123 (March 2026) relaxed the API token regex
# from `^[A-Za-z0-9_-]{35,50}$` to accept the new 53-char token format
# CF started issuing. v0.2.3 rejects the new format with a vague
# "API token ... appears invalid" error during plugin provisioning,
# even though the token works against the CF API directly.
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare@a8737d095ad5a48ca031cea6ab704057dbc2d250 \
    --output /usr/bin/caddy \
    v2.11.4

FROM caddy:2.11.4
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

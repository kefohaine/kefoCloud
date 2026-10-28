# wizard.d/modules/caddy/setup.sh — the edge’s data dir: Cloudflare token file and its ownership (201:201, 0711).

caddy_data() {
  # The compose env_file path is $(REPO)/caddy_data (sibling of repo/), not inside the clone.
  sudo mkdir -p $ROOT/data/caddy_data
  printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" | sudo tee $ROOT/data/caddy_data/CF_API_TOKEN >/dev/null
  sudo chown -R 201:201 $ROOT/data/caddy_data
  # 0711, never the root umask's 0700: `docker compose` runs as root and
  # reads env_file host-side, so it needs +x on the dir or it dies with
  # "open .../CF_API_TOKEN: permission denied" and Caddy never starts.
  sudo chmod 0711 $ROOT/data/caddy_data
  sudo chown root:root $ROOT/data/caddy_data/CF_API_TOKEN
  sudo chmod 0644 $ROOT/data/caddy_data/CF_API_TOKEN
}

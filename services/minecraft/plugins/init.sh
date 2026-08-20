#!/bin/bash
# Fetch Geyser + Floodgate Spigot JARs if missing.
# Runs inside the minecraft container before the server starts.
# itzg/minecraft-server does not auto-install cross-platform plugins; this
# fills the gap so a fresh volume still ends up Java + Bedrock.

set -eu

PLUGINS_DIR="/data/plugins"
mkdir -p "$PLUGINS_DIR"

fetch() {
    local name="$1" url="$2"
    local dest="$PLUGINS_DIR/$name"
    if [ -s "$dest" ]; then
        echo "[mc-plugins] $name already present, skipping"
        return 0
    fi
    echo "[mc-plugins] downloading $name from $url"
    if ! curl -fsSL -o "$dest.tmp" "$url"; then
        echo "[mc-plugins] FAILED to download $name (network?)" >&2
        rm -f "$dest.tmp"
        return 1
    fi
    mv "$dest.tmp" "$dest"
    chown 1000:1000 "$dest"
}

# v2 download API on download.geysermc.org — v4 path 404s.
fetch "Geyser-Spigot.jar"    "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot"
fetch "floodgate-spigot.jar" "https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot"

echo "[mc-plugins] ready"

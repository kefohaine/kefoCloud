import json
import os
import re
import socket
import struct
import subprocess
import tarfile
import tempfile
import threading
import time
import zipfile
from pathlib import Path
from urllib.parse import quote, unquote

import yaml
from flask import (
    Flask,
    Response,
    jsonify,
    redirect,
    render_template,
    request,
    send_file,
    stream_with_context,
)

# The mc dashboard is served at https://server.jehpok.com/mc/ — Caddy's
# `@mc` matcher routes the /mc/* prefix without stripping, so every route
# here lives under /mc/. (Share's admin uses the same pattern: /share
# routes in the app, no strip_prefix in Caddy.)

SERVER_DIR = Path(os.environ.get("SERVER_DIR", "/server")).resolve()
WORLD_DIR = SERVER_DIR / "world"
LOGS_DIR = SERVER_DIR / "logs"
LATEST_LOG = LOGS_DIR / "latest.log"
PLUGINS_DIR = SERVER_DIR / "plugins"

RCON_HOST = os.environ.get("RCON_HOST", "minecraft")
RCON_PORT = int(os.environ.get("RCON_PORT", "25575"))
RCON_PASSWORD = os.environ.get("RCON_PASSWORD", "change-me-via-dashboard")

CONTAINER = os.environ.get("MC_CONTAINER", "minecraft")

# Host-side backup directory (outside the bind mount — tar creates the
# archive here, so the file isn't subject to dashboard bind-mount semantics).
HOST_BACKUP_DIR = Path("/var/www/custom/projects/jehpok")
HOST_WORLD_SOURCE = HOST_BACKUP_DIR / "minecraft" / "data" / "world"

app = Flask(__name__)


# ── rcon ─────────────────────────────────────────────────────────────────────
#
# The `mcrcon` PyPI package used `signal.alarm()` to enforce its socket
# timeout, which raises "signal only works in main thread of the main
# interpreter" from inside a Flask request handler. Roll our own with
# socket.settimeout instead. RCON protocol:
#   length(4 LE) + request_id(4 LE) + type(4 LE) + payload + \x00 + \x00

RCON_TYPE_CMD = 2
RCON_TYPE_AUTH = 3


# ── persistent rcon connection ─────────────────────────────────────────────
#
# The dashboard polls stats / list / tps / version every 2 s, which produces
# 4-6 rcon connections per second. Each one logs
#   "RCON Client /<ip> started" / "shutting down"
# which floods latest.log. A single shared, thread-safe connection removes
# that noise. Idle timeout keeps an unused socket from sitting open across
# long gaps (e.g. dashboard hidden in a background tab). Auto-reconnect
# handles the game-container restart case.

RCON_IDLE_TIMEOUT = 30.0  # seconds; close connection after this much idle


class _RconPool:
    def __init__(self):
        self._lock = threading.Lock()
        self._sock = None
        self._last_used = 0.0
        self._next_id = 1  # per-connection request id counter

    @staticmethod
    def _packet(req_id, type_, body):
        body_bytes = body.encode("utf-8") + b"\x00\x00"
        length = 4 + 4 + len(body_bytes)
        return struct.pack("<iii", length, req_id, type_) + body_bytes

    @staticmethod
    def _read_packet(sock):
        header = b""
        while len(header) < 4:
            chunk = sock.recv(4 - len(header))
            if not chunk:
                raise RuntimeError("rcon: connection closed before header")
            header += chunk
        (length,) = struct.unpack("<i", header)
        body = b""
        while len(body) < length:
            chunk = sock.recv(length - len(body))
            if not chunk:
                raise RuntimeError("rcon: connection closed mid-body")
            body += chunk
        req_id, type_ = struct.unpack("<ii", body[:8])
        return req_id, type_, body[8:-2].decode("utf-8", errors="replace")

    def _open(self, timeout):
        s = socket.create_connection((RCON_HOST, RCON_PORT), timeout=timeout)
        s.settimeout(timeout)
        s.sendall(self._packet(self._next_id, RCON_TYPE_AUTH, RCON_PASSWORD))
        self._next_id += 1
        auth_id, _, _ = self._read_packet(s)
        if auth_id == -1:
            s.close()
            raise RuntimeError("rcon: authentication failed")
        return s

    def _close_quiet(self):
        if self._sock is not None:
            try:
                self._sock.close()
            except Exception:
                pass
            self._sock = None

    def cmd(self, body, timeout=3.0):
        """Run one rcon command over a shared connection. Auto-reconnects
        once on failure."""
        with self._lock:
            now = time.monotonic()
            # Close stale idle connections.
            if (self._sock is not None
                    and now - self._last_used > RCON_IDLE_TIMEOUT):
                self._close_quiet()

            if self._sock is None:
                self._sock = self._open(timeout)
                self._next_id = 2  # request id 1 was used for AUTH

            req_id = self._next_id
            self._next_id += 1
            try:
                self._sock.sendall(self._packet(req_id, RCON_TYPE_CMD, body))
                _, _, resp = self._read_packet(self._sock)
            except Exception:
                # Connection is poisoned — drop it and let the caller retry
                # via the single reconnect attempt below.
                self._close_quiet()
                self._sock = self._open(timeout)
                req_id = self._next_id
                self._next_id += 1
                self._sock.sendall(self._packet(req_id, RCON_TYPE_CMD, body))
                _, _, resp = self._read_packet(self._sock)

            self._last_used = time.monotonic()
            return resp


_rcon_pool = _RconPool()


def rcon(cmd, timeout=3.0):
    """Public rcon entry point. Thread-safe; uses the shared connection."""
    return _rcon_pool.cmd(cmd, timeout=timeout)


def parse_tps(text):
    """Parse the `/tps` output. Returns float tps (or None)."""
    plain = re.sub(r"§.", "", text)
    m = re.search(r"TPS from last 1m.*?:\s*([\d.]+)", plain)
    return float(m.group(1)) if m else None


def _docker_client():
    import docker as _docker
    return _docker.DockerClient(base_url="unix:///var/run/docker.sock")


def container_running():
    try:
        return _docker_client().containers.get(CONTAINER).status == "running"
    except Exception:
        return False


# Paper's `version` doesn't change at runtime — only when the image changes
# or the game container restarts. Cache it keyed on the container StartedAt
# timestamp so we re-read only when the game container has been restarted.
# Drops one rcon round-trip from every 2 s stats poll.
_version_cache = {"started_at": None, "version": None}
_version_lock = threading.Lock()


def _paper_version():
    """Return Paper version string. Cached; refreshed only when the game
    container has been restarted since the last read."""
    try:
        c = _docker_client().containers.get(CONTAINER)
        started = c.attrs["State"].get("StartedAt", "")
    except Exception:
        started = ""
    with _version_lock:
        if started == _version_cache["started_at"] and _version_cache["version"]:
            return _version_cache["version"]
    # Cache miss — fetch via rcon. Outside the lock so concurrent first
    # requests can both try; the cache write is last-writer-wins which is
    # fine since the version string is deterministic.
    try:
        ver_resp = rcon("version")
        # Paper's /version returns e.g.
        #   "This server is running Paper version 26.2-112-main@c9e894d ..."
        # with §X color codes (rcon does its own coloring). Older Paper
        # builds used the form "Paper version git-Paper-XXX (MC: 1.20.4)".
        # Strip the color codes first, then accept either shape.
        plain = re.sub(r"§.", "", ver_resp)
        m = re.search(r"Paper version ([^\s(]+)", plain)
        if m:
            with _version_lock:
                _version_cache["started_at"] = started
                _version_cache["version"] = m.group(1)
            return m.group(1)
    except Exception:
        pass
    return None


def stats():
    """Live stats from rcon + container status via Docker SDK."""
    out = {
        "online": None, "max": None, "tps": None,
        "running": False, "version": None, "uptime_s": None, "raw": "",
    }
    try:
        c = _docker_client().containers.get(CONTAINER)
        out["running"] = c.status == "running"
        # Uptime from container start time (docker-side, not rcon-side)
        try:
            started = c.attrs["State"]["StartedAt"]
            # Format: "2026-08-20T15:49:54.123456789Z"
            from datetime import datetime, timezone
            t = datetime.fromisoformat(started.replace("Z", "+00:00"))
            out["uptime_s"] = int((datetime.now(timezone.utc) - t).total_seconds())
        except Exception:
            pass
    except Exception:
        out["running"] = False
    if not out["running"]:
        return out
    try:
        out["raw"] = rcon("list")
    except ConnectionRefusedError:
        return out
    except Exception as e:
        out["error"] = f"rcon: {e}"
        return out
    m = re.search(r"There are (\d+) of a max of (\d+) players online", out["raw"])
    if m:
        out["online"] = int(m.group(1))
        out["max"] = int(m.group(2))
    try:
        tps_resp = rcon("tps")
        out["tps"] = parse_tps(tps_resp)
    except Exception:
        pass
    out["version"] = _paper_version()
    return out
    return out


# ── server.properties ────────────────────────────────────────────────────────
#
# Removed because Paper no longer honors them from server.properties:
#   - `pvp`: vanilla removed it in 1.21.2; now `/gamerule pvp`.
#   - `spawn-protection`: Paper stopped enforcing it around 1.16.5.
#   - `enable-command-block`: moved to paper-world-defaults.yml in Paper 1.19+.
# Removed because misconfiguration can lock the dashboard out or break
# startup:
#   - `server-port`, `enable-rcon`, `level-seed`, `level-type`,
#     `view-distance`, `simulation-distance`.
# Added:
#   - `enforce-whitelist`: kicks already-online players when the whitelist
#     changes.
EDITABLE_FIELDS = [
    "max-players", "gamemode", "difficulty", "hardcore",
    "white-list", "enforce-whitelist",
    "view-distance", "simulation-distance", "motd",
    "online-mode", "allow-flight",
]

SELECT_OPTIONS = {
    "gamemode": ["survival", "creative", "adventure", "spectator"],
    "difficulty": ["peaceful", "easy", "normal", "hard"],
}

SERVER_PROPERTIES = SERVER_DIR / "server.properties"


def read_properties():
    if not SERVER_PROPERTIES.exists():
        return {}
    out = {}
    for line in SERVER_PROPERTIES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def write_properties(values):
    """Rewrite server.properties with the supplied keys preserved in place.
    Atomic via tmp file + rename. Comments and ordering preserved."""
    if not SERVER_PROPERTIES.exists():
        SERVER_PROPERTIES.parent.mkdir(parents=True, exist_ok=True)
        SERVER_PROPERTIES.write_text("# Generated by dashboard\n")
    text = SERVER_PROPERTIES.read_text()
    new_lines = []
    seen = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            new_lines.append(line)
            continue
        k = stripped.split("=", 1)[0].strip()
        if k in values:
            new_lines.append(f"{k}={values[k]}")
            seen.add(k)
        else:
            new_lines.append(line)
    for k, v in values.items():
        if k not in seen:
            new_lines.append(f"{k}={v}")
    tmp = SERVER_PROPERTIES.with_suffix(".properties.tmp")
    tmp.write_text("\n".join(new_lines) + "\n")
    tmp.replace(SERVER_PROPERTIES)


# ── container control ────────────────────────────────────────────────────────

def container_action(action):
    """Start / stop / restart the game container via the Docker SDK."""
    if action not in ("start", "stop", "restart"):
        return False, "unknown action"
    try:
        c = _docker_client().containers.get(CONTAINER)
    except Exception as e:
        return False, f"container not found: {e}"
    if action == "start":
        c.start()
    elif action == "stop":
        c.stop()
    elif action == "restart":
        c.restart()
    return True, f"{action}ed"


# ── path safety ──────────────────────────────────────────────────────────────

# Subtrees that are part of Paper runtime / library caches. The Files tab
# refuses to navigate into or delete from these — they are managed by the
# itzg image and rewriting them at runtime corrupts the Paper install.
PROTECTED_SUBDIRS = {"libraries", "versions", "cache", ".paper"}
PROTECTED_FILES = {"session.lock"}  # in /world

# World is large (100MB+) and structurally sensitive. The Files tab
# refuses to list, open, delete, or upload individual files inside it —
# all world operations go through the dedicated /mc/api/world/* routes.
WORLD_EXCLUDED = True

# Max text file size the Files tab will let you read inline (256 KB).
TEXT_FILE_MAX = 256 * 1024

# Max size the Files tab will let you upload via the .jar / .zip forms.
UPLOAD_MAX = 200 * 1024 * 1024  # 200 MB; server zip is the worst case


def resolve_safe(rel):
    """Resolve a relative path inside SERVER_DIR and verify it does not
    escape. Returns the resolved Path, or None if unsafe. `rel` may be
    empty or "." (returns SERVER_DIR)."""
    if rel is None:
        rel = ""
    s = str(rel).strip()
    if not s or s == "/":
        return SERVER_DIR
    # Reject absolute paths and obvious traversal up front.
    if s.startswith("/") or s.startswith("~"):
        return None
    # Split, drop empty parts, walk each component against the root.
    parts = [p for p in s.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        return None
    candidate = SERVER_DIR
    for p in parts:
        candidate = candidate / p
    try:
        # Use realpath to catch symlinks; require the resolved path to
        # still be inside SERVER_DIR.
        resolved = candidate.resolve(strict=False)
        root_resolved = SERVER_DIR.resolve(strict=False)
        resolved.relative_to(root_resolved)  # raises if outside
        return resolved
    except (ValueError, OSError):
        return None


def is_protected(path):
    """True if path is inside a protected subtree or matches a protected
    filename (Paper runtime data the dashboard must not touch)."""
    try:
        rel = path.resolve().relative_to(SERVER_DIR.resolve())
    except (ValueError, OSError):
        return False
    parts = rel.parts
    if not parts:
        return False
    # The first path component is the subdir under /server/.
    if parts[0] in PROTECTED_SUBDIRS:
        return True
    if parts[-1] in PROTECTED_FILES:
        return True
    return False


def is_in_world(path):
    try:
        path.resolve().relative_to(WORLD_DIR.resolve())
        return True
    except (ValueError, OSError):
        return False


def atomic_write(path, content):
    """Write `content` to `path` atomically (tmp + rename)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    if isinstance(content, str):
        tmp.write_text(content)
    else:
        tmp.write_bytes(content)
    tmp.replace(path)


# ── players / stats ──────────────────────────────────────────────────────────

def load_json(path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def parse_player_stats(uuid):
    """Return playtime_min, mob_kills, deaths, blocks_broken from
    /world/players/stats/<uuid>.json. None on any missing file."""
    p = WORLD_DIR / "players" / "stats" / f"{uuid}.json"
    data = load_json(p)
    if not isinstance(data, dict):
        return None
    def _stat(key, default=0):
        # stats/<uuid>.json is flat: {"minecraft:custom:...": int, ...}
        v = data.get(f"minecraft:custom:minecraft:{key}")
        if isinstance(v, (int, float)):
            return int(v)
        return default
    playtime_ticks = _stat("play_one_minute", 0)
    playtime_min = round(playtime_ticks / 1200, 1)
    mob_kills = _stat("mob_kills", 0)
    deaths = _stat("deaths", 0)
    blocks_broken = 0
    for k, v in data.items():
        if k.startswith("minecraft:mined:") and isinstance(v, (int, float)):
            blocks_broken += int(v)
    return {
        "playtime_min": playtime_min,
        "mob_kills": mob_kills,
        "deaths": deaths,
        "blocks_broken": blocks_broken,
    }


def parse_player_advancements(uuid):
    """Return advancement progress as a float 0..1 (no criteria detail)."""
    p = WORLD_DIR / "players" / "advancements" / f"{uuid}.json"
    data = load_json(p)
    if not isinstance(data, dict):
        return None
    # Stored as { "<advancement_id>": { "done": bool, "criteria": {...} } }
    # In Paper 1.20.4+ the format changed to array of done criteria. Handle
    # both shapes defensively.
    total = 0
    done = 0
    for adv, val in data.items():
        if isinstance(val, dict):
            total += 1
            if val.get("done"):
                done += 1
    if total == 0:
        return None
    return {"done": done, "total": total, "pct": round(done / total * 100, 1)}


def usercache_map():
    """Return {uuid_lower: name} from usercache.json (most recent name)."""
    data = load_json(SERVER_DIR / "usercache.json")
    out = {}
    if isinstance(data, list):
        for e in data:
            uuid = (e.get("uuid") or "").lower()
            name = e.get("name")
            if uuid and name:
                out[uuid] = name
    return out


def list_known_players():
    """Return list of {uuid, name} from usercache, de-duped by uuid."""
    cache = usercache_map()
    return [{"uuid": u, "name": n} for u, n in cache.items()]


def parse_roster(path):
    """Parse a roster JSON file (ops.json, whitelist.json,
    banned-players.json, banned-ips.json) and return list of names/uuid
    pairs. Format is `[ {uuid:..., name:...}, ... ]`."""
    data = load_json(path)
    out = []
    if isinstance(data, list):
        for e in data:
            if isinstance(e, dict):
                out.append({
                    "uuid": (e.get("uuid") or "").lower(),
                    "name": e.get("name", "?"),
                })
    return out


def list_online_names():
    """Parse rcon `list` output and return names of online players. Paper
    `list` returns 'There are X of a max of Y players online: name1, name2'
    or 'There are 0 of a max of Y players online'."""
    if not container_running():
        return []
    try:
        resp = rcon("list")
    except Exception:
        return []
    m = re.search(r"online:\s*(.+)", resp)
    if not m:
        return []
    rest = m.group(1).strip()
    if not rest:
        return []
    # Names are comma-separated. Handle quoted names too.
    parts = []
    for piece in rest.split(","):
        n = piece.strip()
        if n:
            parts.append(n)
    return parts


def players_api():
    """Return the JSON for /mc/api/players."""
    cache = usercache_map()
    online_names = list_online_names()

    # Build online list: name + uuid from cache.
    online = []
    online_lower = set()
    for name in online_names:
        uuid = ""
        # Reverse lookup: name -> uuid via usercache
        for u, n in cache.items():
            if n == name:
                uuid = u
                break
        online.append({"name": name, "uuid": uuid})
        online_lower.add(name.lower())

    # Known players: usercache minus currently-online. Stats from disk.
    known = []
    for uuid, name in cache.items():
        if name.lower() in online_lower:
            continue
        entry = {"uuid": uuid, "name": name}
        stats = parse_player_stats(uuid)
        if stats:
            entry.update(stats)
        known.append(entry)

    ops = [r["name"] for r in parse_roster(SERVER_DIR / "ops.json")]
    whitel = [r["name"] for r in parse_roster(SERVER_DIR / "whitelist.json")]
    banned = [r["name"] for r in parse_roster(SERVER_DIR / "banned-players.json")]

    return jsonify({
        "online": online,
        "known": known,
        "ops": sorted(set(ops)),
        "whitelisted": sorted(set(whitel)),
        "banned": sorted(set(banned)),
    })


# ── routes ───────────────────────────────────────────────────────────────────

@app.errorhandler(404)
def not_found(e):
    return Response("not found", status=404, mimetype="text/plain")


@app.errorhandler(413)
def too_large(e):
    return Response("upload too large", status=413, mimetype="text/plain")


# Cap upload size at the module level (Flask reads MAX_CONTENT_LENGTH).
app.config["MAX_CONTENT_LENGTH"] = UPLOAD_MAX


@app.route("/mc/healthz")
def healthz():
    return "ok", 200


# ── HTML index ──────────────────────────────────────────────────────────────

@app.route("/mc/")
def index():
    s = stats()
    props = read_properties()
    log_tail = ""
    if LATEST_LOG.exists():
        try:
            log_tail = "\n".join(
                LATEST_LOG.read_text(errors="ignore").splitlines()[-60:]
            )
        except Exception:
            pass
    return render_template(
        "dashboard.html",
        stats=s,
        props=props,
        editable=EDITABLE_FIELDS,
        select_options=SELECT_OPTIONS,
        log_tail=log_tail,
        control_flash=request.args.get("control_flash"),
        rcon_flash=request.args.get("rcon_flash"),
        config_flash=request.args.get("config_flash"),
    )


# ── legacy POST routes (kept for the no-JS fallback flow) ────────────────────

@app.route("/mc/control", methods=["POST"])
def control():
    action = (request.form.get("action") or "").strip()
    if action not in ("start", "stop", "restart"):
        return redirect("/mc/?control_flash=request+rejected+unknown+action")
    container_action(action)
    return redirect(f"/mc/?control_flash={quote(action + ' request sent')}")


@app.route("/mc/config", methods=["POST"])
def save_config():
    values = {}
    for k in EDITABLE_FIELDS:
        v = request.form.get(k)
        if v is not None and v != "":
            values[k] = v
    write_properties(values)
    return redirect("/mc/?config_flash=config+saved")


@app.route("/mc/rcon", methods=["POST"])
def run_rcon():
    cmd = (request.form.get("cmd") or "").strip()
    if not cmd:
        return redirect("/mc/?rcon_flash=empty+command")
    try:
        out = rcon(cmd)
    except Exception as e:
        return redirect(f"/mc/?rcon_flash=rcon+request+failed:+{quote(str(e))}")
    return redirect(f"/mc/?rcon_flash=rcon+request+sent:+{quote(out[:120])}")


# JSON variant used by the dashboard's Quick rcon box. Returns the cmd that
# was sent alongside the rcon output so the UI can show both.
@app.route("/mc/api/rcon", methods=["POST"])
def api_rcon_run():
    payload = request.form if request.form else (request.json or {})
    cmd = (payload.get("cmd") or "").strip()
    if not cmd:
        return jsonify(error="empty command"), 400
    if not container_running():
        return jsonify(error="server is not running"), 409
    try:
        out = rcon(cmd)
    except Exception as e:
        return jsonify(error=f"rcon: {e}"), 500
    return jsonify(ok=True, cmd=cmd, output=out[:1200])


# ── JSON APIs ───────────────────────────────────────────────────────────────

@app.route("/mc/api/stats")
def api_stats():
    s = stats()
    return jsonify(
        running=s["running"],
        online=s["online"],
        max=s["max"],
        tps=s["tps"],
        version=s["version"],
        uptime_s=s["uptime_s"],
        error=s.get("error"),
    )


@app.route("/mc/api/players")
def api_players():
    return players_api()


@app.route("/mc/api/players/<uuid>/stats")
def api_player_stats(uuid):
    uuid_l = uuid.lower()
    cache = usercache_map()
    name = cache.get(uuid_l, "")
    if not name:
        return jsonify(error="unknown player"), 404
    stats = parse_player_stats(uuid_l) or {}
    adv = parse_player_advancements(uuid_l) or {}
    return jsonify(uuid=uuid_l, name=name, stats=stats, advancements=adv)


@app.route("/mc/api/players/<uuid>/<action>", methods=["POST"])
def api_player_action(uuid, action):
    name = ""
    cache = usercache_map()
    name = cache.get(uuid.lower(), "")
    if not name:
        return jsonify(error="unknown player"), 404
    payload = request.form if request.form else (request.json or {})
    reason = (payload.get("reason") or "").strip()
    gamemode = (payload.get("gamemode") or "").strip()
    cmd_map = {
        "kick": f"kick {name}" + (f" {reason}" if reason else ""),
        "ban": f"ban {name}" + (f" {reason}" if reason else ""),
        "pardon": f"pardon {name}",
        "op": f"op {name}",
        "deop": f"deop {name}",
        "whitelist_add": f"whitelist add {name}",
        "whitelist_remove": f"whitelist remove {name}",
    }
    if action in cmd_map:
        c = cmd_map[action]
    elif action == "gamemode":
        if gamemode not in ("survival", "creative", "adventure", "spectator"):
            return jsonify(error="invalid gamemode"), 400
        c = f"gamemode {gamemode} {name}"
    else:
        return jsonify(error="unknown action"), 400
    if not container_running():
        return jsonify(error="server is not running"), 409
    try:
        out = rcon(c)
    except Exception as e:
        return jsonify(error=f"rcon: {e}"), 500
    return jsonify(ok=True, output=out[:400], command=c)


@app.route("/mc/api/log")
def api_log():
    n = int(request.args.get("tail", 100))
    n = max(1, min(n, 2000))
    if not LATEST_LOG.exists():
        return jsonify(lines=[])
    try:
        text = LATEST_LOG.read_text(errors="ignore")
        lines = text.splitlines()[-n:]
        return jsonify(lines=lines)
    except Exception as e:
        return jsonify(error=str(e)), 500


@app.route("/mc/api/log/stream")
def api_log_stream():
    """Long-lived chunked response that tails latest.log. Closes when the
    client disconnects or the file rotates. Not SSE — plain text frames
    separated by newlines."""
    def gen():
        if not LATEST_LOG.exists():
            return
        last_size = LATEST_LOG.stat().st_size if LATEST_LOG.exists() else 0
        while True:
            try:
                size = LATEST_LOG.stat().st_size if LATEST_LOG.exists() else 0
            except OSError:
                return
            if size < last_size:
                # File rotated — re-read.
                last_size = 0
            if size > last_size:
                with LATEST_LOG.open("rb") as f:
                    f.seek(last_size)
                    chunk = f.read(size - last_size)
                    if chunk:
                        yield chunk
                last_size = size
            time.sleep(0.5)
    return Response(stream_with_context(gen()), mimetype="text/plain")


# ── file browser ─────────────────────────────────────────────────────────────

@app.route("/mc/api/files")
def api_files_list():
    rel = request.args.get("path", "")
    target = resolve_safe(rel)
    if target is None:
        return jsonify(error="invalid path"), 400
    if is_protected(target):
        return jsonify(error="protected subtree"), 403
    if is_in_world(target):
        # Files tab doesn't navigate into world; that's the World tab.
        return jsonify(error="use the World tab for world files"), 403
    if not target.exists():
        return jsonify(error="not found"), 404
    if not target.is_dir():
        return jsonify(error="not a directory"), 400
    entries = []
    for child in sorted(target.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
        # Hide protected subdirs/files entirely.
        if is_protected(child):
            continue
        try:
            st = child.stat()
        except OSError:
            continue
        entries.append({
            "name": child.name,
            "path": str(child.relative_to(SERVER_DIR)),
            "is_dir": child.is_dir(),
            "size": st.st_size if child.is_file() else None,
            "mtime": int(st.st_mtime),
        })
    rel_disp = "" if rel in ("", ".", "/") else str(rel)
    return jsonify(path=rel_disp, entries=entries)


@app.route("/mc/api/files/raw")
def api_files_read():
    rel = request.args.get("path", "")
    target = resolve_safe(rel)
    if target is None or is_protected(target) or is_in_world(target) or not target.is_file():
        return jsonify(error="not allowed"), 403
    try:
        if target.stat().st_size > TEXT_FILE_MAX:
            return jsonify(error=f"file too large (> {TEXT_FILE_MAX} bytes)"), 413
        text = target.read_text(errors="replace")
    except Exception as e:
        return jsonify(error=str(e)), 500
    return jsonify(path=str(rel), content=text, size=len(text))


@app.route("/mc/api/files/save", methods=["POST"])
def api_files_save():
    rel = request.form.get("path") or ""
    content = request.form.get("content") or ""
    target = resolve_safe(rel)
    if target is None or is_protected(target) or is_in_world(target) or not target.is_file():
        return jsonify(error="not allowed"), 403
    # Validate YAML parseability for known YAML configs.
    yaml_files = {"bukkit.yml", "spigot.yml", "commands.yml",
                  "config/paper-global.yml", "config/paper-world-defaults.yml"}
    if str(target.relative_to(SERVER_DIR)) in yaml_files:
        try:
            yaml.safe_load(content)
        except yaml.YAMLError as e:
            return jsonify(error=f"yaml parse error: {e}"), 400
    try:
        atomic_write(target, content)
    except Exception as e:
        return jsonify(error=str(e)), 500
    return jsonify(ok=True)


@app.route("/mc/api/files/download")
def api_files_download():
    rel = request.args.get("path", "")
    target = resolve_safe(rel)
    if target is None or is_protected(target) or is_in_world(target) or not target.is_file():
        return jsonify(error="not allowed"), 403
    return send_file(str(target), as_attachment=True)


@app.route("/mc/api/files/upload", methods=["POST"])
def api_files_upload():
    """Plugin .jar upload: lands in /server/plugins/. World .zip upload: lands
    in /server/world/ (must be stopped)."""
    kind = request.form.get("kind", "plugin")
    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify(error="no file"), 400
    fname = Path(f.filename).name  # strip any path components
    if kind == "world":
        return _upload_world_zip(f, fname)
    # default: plugin
    if not fname.lower().endswith(".jar"):
        return jsonify(error="only .jar files accepted for plugins"), 400
    dest = PLUGINS_DIR / fname
    try:
        PLUGINS_DIR.mkdir(parents=True, exist_ok=True)
        f.save(str(dest))
    except Exception as e:
        return jsonify(error=str(e)), 500
    return jsonify(ok=True, path=f"plugins/{fname}")


def _upload_world_zip(file_storage, fname):
    if container_running():
        return jsonify(error="stop the server first"), 409
    if not fname.lower().endswith(".zip"):
        return jsonify(error="only .zip accepted for world upload"), 400
    # Write to a temp dir, validate every entry, then mv into /server/world.
    with tempfile.TemporaryDirectory(dir="/tmp") as td:
        zip_path = Path(td) / fname
        file_storage.save(str(zip_path))
        extract_dir = Path(td) / "extract"
        extract_dir.mkdir()
        try:
            with zipfile.ZipFile(zip_path) as zf:
                for member in zf.infolist():
                    name = member.filename
                    # Reject absolute paths, parent traversal, symlinks.
                    if name.startswith("/") or ".." in name.split("/"):
                        return jsonify(error=f"unsafe entry: {name}"), 400
                    if member.is_dir():
                        continue
                    target = extract_dir / name
                    if not str(target.resolve()).startswith(str(extract_dir.resolve())):
                        return jsonify(error=f"path traversal: {name}"), 400
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with zf.open(member) as src, target.open("wb") as dst:
                        dst.write(src.read())
        except zipfile.BadZipFile:
            return jsonify(error="not a valid zip"), 400
        # Replace existing world.
        if WORLD_DIR.exists():
            import shutil
            shutil.rmtree(WORLD_DIR)
        import shutil
        shutil.move(str(extract_dir), str(WORLD_DIR))
    return jsonify(ok=True, path="world/")


@app.route("/mc/api/files/delete", methods=["POST"])
def api_files_delete():
    rel = request.form.get("path", "")
    target = resolve_safe(rel)
    if target is None or is_protected(target) or is_in_world(target):
        return jsonify(error="not allowed"), 403
    if not target.exists():
        return jsonify(error="not found"), 404
    if target == SERVER_DIR:
        return jsonify(error="cannot delete server root"), 400
    import shutil
    try:
        if target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink()
    except Exception as e:
        return jsonify(error=str(e)), 500
    return jsonify(ok=True)


# ── world ops ────────────────────────────────────────────────────────────────

@app.route("/mc/api/world/download", methods=["POST"])
def api_world_download():
    if container_running():
        return jsonify(error="stop the server first"), 409
    if not HOST_WORLD_SOURCE.exists():
        return jsonify(error="world directory not found"), 404

    def gen():
        # Stream tar.gz from the host-side source so the dashboard bind
        # mount (/server) doesn't matter for the archive contents.
        proc = subprocess.Popen(
            ["tar", "czf", "-", "-C", str(HOST_WORLD_SOURCE.parent), "world"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        try:
            while True:
                chunk = proc.stdout.read(64 * 1024)
                if not chunk:
                    break
                yield chunk
        finally:
            proc.wait()

    fname = f"world-{time.strftime('%Y%m%d-%H%M%S')}.tar.gz"
    return Response(
        stream_with_context(gen()),
        mimetype="application/gzip",
        headers={
            "Content-Disposition": f'attachment; filename="{fname}"',
            "Cache-Control": "no-store",
        },
    )


@app.route("/mc/api/world/regenerate", methods=["POST"])
def api_world_regenerate():
    """Backup current world (always) → delete world dir → start container.
    Returns the backup path so the UI can offer a download link."""
    if container_running():
        return jsonify(error="stop the server first"), 409
    backup_name = f"minecraft-backup-{time.strftime('%Y%m%d-%H%M%S')}.tar.gz"
    backup_path = HOST_BACKUP_DIR / backup_name
    # 1. Tar the host-side world.
    try:
        subprocess.run(
            ["sudo", "tar", "czf", str(backup_path),
             "-C", str(HOST_WORLD_SOURCE.parent), "world"],
            check=True,
        )
        subprocess.run(["sudo", "chown", "debian:debian", str(backup_path)], check=False)
    except subprocess.CalledProcessError as e:
        return jsonify(error=f"backup failed: {e}"), 500
    # 2. Remove the world inside the bind mount.
    import shutil
    if WORLD_DIR.exists():
        shutil.rmtree(WORLD_DIR)
    # 3. Start the container so Paper recreates the world on first run.
    try:
        ok, msg = container_action("start")
    except Exception as e:
        return jsonify(backup=str(backup_path), error=f"start failed: {e}"), 500
    return jsonify(ok=ok, backup=str(backup_path), container=msg)


@app.route("/mc/api/world/backup", methods=["POST"])
def api_world_backup():
    """Snapshot just the world without removing it. Safe while running
    only via daily.sh, which stops the container first."""
    if container_running():
        return jsonify(error="stop the server first"), 409
    backup_name = f"minecraft-backup-{time.strftime('%Y%m%d-%H%M%S')}.tar.gz"
    backup_path = HOST_BACKUP_DIR / backup_name
    if not HOST_WORLD_SOURCE.exists():
        return jsonify(error="world directory not found"), 404
    try:
        subprocess.run(
            ["sudo", "tar", "czf", str(backup_path),
             "-C", str(HOST_WORLD_SOURCE.parent), "world"],
            check=True,
        )
        subprocess.run(["sudo", "chown", "debian:debian", str(backup_path)], check=False)
    except subprocess.CalledProcessError as e:
        return jsonify(error=f"backup failed: {e}"), 500
    return jsonify(ok=True, backup=str(backup_path))


@app.route("/mc/api/world/backups")
def api_world_backups():
    """List existing world backups on the host side."""
    out = []
    if HOST_BACKUP_DIR.exists():
        for p in HOST_BACKUP_DIR.glob("minecraft-backup-*.tar.gz"):
            try:
                st = p.stat()
                out.append({
                    "name": p.name,
                    "path": str(p),
                    "size": st.st_size,
                    "mtime": int(st.st_mtime),
                })
            except OSError:
                continue
    out.sort(key=lambda x: x["mtime"], reverse=True)
    return jsonify(backups=out)


@app.route("/mc/api/world/backup/download")
def api_world_backup_download():
    name = request.args.get("name", "")
    if not name or "/" in name or ".." in name:
        return jsonify(error="bad name"), 400
    p = HOST_BACKUP_DIR / name
    if not p.exists() or not p.name.startswith("minecraft-backup-"):
        return jsonify(error="not found"), 404
    return send_file(str(p), as_attachment=True)


# ── container / properties JSON ────────────────────────────────────────────────

@app.route("/mc/api/server_props")
def api_server_props():
    return jsonify(props=read_properties(), editable=EDITABLE_FIELDS,
                   select_options=SELECT_OPTIONS)


@app.route("/mc/api/server_props", methods=["POST"])
def api_server_props_save():
    payload = request.json or {}
    values = {k: v for k, v in payload.items() if k in EDITABLE_FIELDS and v != ""}
    try:
        write_properties(values)
    except Exception as e:
        return jsonify(error=str(e)), 500
    return jsonify(ok=True, saved=list(values.keys()))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
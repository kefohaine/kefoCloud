import os
import re
import socket
import struct
from pathlib import Path
from urllib.parse import quote
from flask import Flask, request, redirect, render_template, Response, jsonify

# The mc dashboard is served at https://server.jehpok.com/mc/ — Caddy's
# `@mc` matcher routes the /mc/* prefix without stripping, so every route
# here lives under /mc/. (Share's admin uses the same pattern: /share
# routes in the app, no strip_prefix in Caddy.)

SERVER_DIR = Path(os.environ.get("SERVER_DIR", "/server"))
SERVER_PROPERTIES = SERVER_DIR / "server.properties"
LOGS_DIR = SERVER_DIR / "logs"
LATEST_LOG = LOGS_DIR / "latest.log"

RCON_HOST = os.environ.get("RCON_HOST", "minecraft")
RCON_PORT = int(os.environ.get("RCON_PORT", "25575"))
RCON_PASSWORD = os.environ.get("RCON_PASSWORD", "change-me-via-dashboard")

CONTAINER = os.environ.get("MC_CONTAINER", "minecraft")

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


def rcon(cmd, timeout=3.0):
    """Run one rcon command and return the response string. Raises on error."""
    payload = b""
    request_id = 1

    def _packet(req_id, type_, body):
        body_bytes = body.encode("utf-8") + b"\x00\x00"
        length = 4 + 4 + len(body_bytes)
        return struct.pack("<iii", length, req_id, type_) + body_bytes

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

    sock = socket.create_connection((RCON_HOST, RCON_PORT), timeout=timeout)
    try:
        sock.settimeout(timeout)
        sock.sendall(_packet(request_id, RCON_TYPE_AUTH, RCON_PASSWORD))
        auth_id, auth_type, _ = _read_packet(sock)
        if auth_id == -1:
            raise RuntimeError("rcon: authentication failed")
        request_id += 1
        sock.sendall(_packet(request_id, RCON_TYPE_CMD, cmd))
        _, _, resp = _read_packet(sock)
        return resp
    finally:
        try:
            sock.close()
        except Exception:
            pass


def parse_tps(text):
    """Parse the `/tps` output. Returns float tps (or None)."""
    # Paper prints color codes inside the rcon response, e.g.
    #   "§6TPS from last 1m, 5m, 15m: §a19.9§r, §a19.9§r, §a19.9"
    # §X / §xY are vanilla section-sign color codes that would derail a
    # plain regex on the 1m value (the "§a" between ":" and "19.9" would
    # prevent `[\d.]+` from matching). Strip them first.
    plain = re.sub(r"§.", "", text)
    m = re.search(r"TPS from last 1m.*?:\s*([\d.]+)", plain)
    return float(m.group(1)) if m else None


def _docker_client():
    """Lazy docker SDK client bound to /var/run/docker.sock."""
    import docker as _docker
    return _docker.DockerClient(base_url="unix:///var/run/docker.sock")


def stats():
    """Live stats from rcon + container status via Docker SDK."""
    out = {"online": None, "max": None, "tps": None, "running": False, "raw": ""}
    # Check container state first — if it's not running, every other rcon
    # call will fail. Surface "offline" rather than letting the user see a
    # wall of N/A values for a server they could just start.
    try:
        c = _docker_client().containers.get(CONTAINER)
        out["running"] = c.status == "running"
    except Exception:
        out["running"] = False
    if not out["running"]:
        return out
    try:
        out["raw"] = rcon("list")
    except ConnectionRefusedError:
        # Container is up (docker check passed) but rcon port isn't bound
        # yet — Paper binds rcon late in startup, after the compose
        # healthcheck on the Java port already marked the container
        # healthy. Treat as "starting", not an error.
        return out
    except Exception as e:
        out["error"] = f"rcon: {e}"
        return out
    m = re.search(r"There are (\d+) of a max of (\d+) players online", out["raw"])
    if m:
        out["online"] = int(m.group(1))
        out["max"] = int(m.group(2))
    try:
        tps = rcon("tps")
        out["tps"] = parse_tps(tps)
    except Exception:
        pass
    return out


# ── config (server.properties) ────────────────────────────────────────────────

# Fields exposed in the dashboard. Each is a key Paper still reads from
# server.properties (1.20+, 1.21+, Paper 26.x) AND is safe to edit without
# risking an unmanageable or unbootable server.
#
# Removed because Paper no longer honors them from server.properties:
#   - `pvp`: vanilla removed it in 1.21.2; now `/gamerule pvp`.
#   - `spawn-protection`: Paper stopped enforcing it around 1.16.5
#     (PR #581); the value is logged but does nothing.
#   - `enable-command-block`: canonical toggle moved to
#     `paper-world-defaults.yml → gameplay.allow-command-blocks` (Paper
#     1.19+, PR #9545); the server.properties key is no longer authoritative.
#
# Removed because misconfiguration can lock the dashboard out or break
# startup (the user can't recover via the dashboard itself):
#   - `server-port`: a typo means rcon + game traffic listen on the wrong
#     port; the dashboard only knows the default. Recovery requires the
#     ttyd host shell, not the dashboard.
#   - `enable-rcon`: setting `false` cuts the only channel the dashboard
#     uses for stats and rcon. Recovery requires ttyd.
#   - `level-seed`: a non-numeric / blank value on next restart triggers
#     world regeneration from a new random seed (irreversible).
#   - `level-type`: an invalid value (typo, removed namespace) crashes
#     Paper at startup with "java.lang.IllegalArgumentException".
#   - `view-distance`, `simulation-distance`: out-of-range integers (Paper
#     validates 2..32) crash startup; large valid values blow up memory.
#
# Added:
#   - `enforce-whitelist`: kicks already-online players when the whitelist
#     changes (complementary to `white-list`, which gates new connections).
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
    if not SERVER_PROPERTIES.exists():
        SERVER_PROPERTIES.write_text("# Generated by dashboard\n")
    text = SERVER_PROPERTIES.read_text()
    new_text_lines = []
    seen = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            new_text_lines.append(line)
            continue
        k = stripped.split("=", 1)[0].strip()
        if k in values:
            new_text_lines.append(f"{k}={values[k]}")
            seen.add(k)
        else:
            new_text_lines.append(line)
    for k, v in values.items():
        if k not in seen:
            new_text_lines.append(f"{k}={v}")
    SERVER_PROPERTIES.write_text("\n".join(new_text_lines) + "\n")


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


# ── routes ───────────────────────────────────────────────────────────────────

@app.errorhandler(404)
def not_found(e):
    return Response("not found", status=404, mimetype="text/plain")


@app.route("/mc/healthz")
def healthz():
    return "ok", 200


@app.route("/mc/api/stats")
def api_stats():
    """Live stats as JSON. Used by the dashboard's Refresh button to
    repaint the cards without reloading the whole page (preserves form
    state — server.properties edits, rcon input)."""
    s = stats()
    return jsonify(
        running=s["running"],
        online=s["online"],
        max=s["max"],
        tps=s["tps"],
        error=s.get("error"),
    )


@app.route("/mc/")
def index():
    s = stats()
    props = read_properties()
    log_tail = ""
    if LATEST_LOG.exists():
        try:
            log_tail = "\n".join(LATEST_LOG.read_text(errors="ignore").splitlines()[-60:])
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


@app.route("/mc/control", methods=["POST"])
def control():
    action = (request.form.get("action") or "").strip()
    if action not in ("start", "stop", "restart"):
        return redirect("/mc/?control_flash=request+rejected+unknown+action")
    # Fire the request and acknowledge — do not claim what happened. The
    # status cards (Refresh to update) are the only source of truth for
    # whether the container actually started/stopped/restarted; the flash
    # only says the request was accepted and dispatched.
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
    # Pure write — do NOT trigger a restart. Restart is an independent
    # control: click it when you want it. Some server.properties keys
    # are hot-reloaded by Paper, so a save without restart is valid;
    # the user can decide which keys need a restart to take effect.
    return redirect("/mc/?config_flash=config+saved")


@app.route("/mc/rcon", methods=["POST"])
def run_rcon():
    cmd = (request.form.get("cmd") or "").strip()
    if not cmd:
        return redirect("/mc/?rcon_flash=empty+command")
    # Dispatch the rcon command; the response text is rcon output, not a
    # claim about server state. Treat it the same as the control buttons:
    # acknowledge the request, surface a snippet of the response for
    # feedback, don't claim more than "the command ran".
    try:
        out = rcon(cmd)
    except Exception as e:
        return redirect(f"/mc/?rcon_flash=rcon+request+failed:+{quote(str(e))}")
    return redirect(f"/mc/?rcon_flash=rcon+request+sent:+{quote(out[:120])}")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)

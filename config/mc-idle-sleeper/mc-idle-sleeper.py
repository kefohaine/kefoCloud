#!/usr/bin/env python3
"""Sleep the PufferPanel Minecraft server after N seconds of zero players.

Runs every minute via mc-idle-sleeper.timer. Queries the game server directly
(127.0.0.1:25566) for its player count, and stops it through the panel daemon
API when idle past MC_IDLE_TIMEOUT seconds (default 300). lazymc's own internal
idle-stop is disabled (sleep_after=86400) because its stop path is broken with
this Paper version; this script is the authoritative sleeper.
"""
import http.cookiejar
import json, os, socket, struct, sys, time, urllib.request

TIMEOUT = int(os.environ.get("MC_IDLE_TIMEOUT", "300"))
API = "http://172.22.0.8:8080"
STATE = "/var/lib/mc-idle-sleeper/state.json"
CRED = "/etc/lazymc/panel-cred"

def varint(n):
    out = b""
    while True:
        b = n & 0x7F; n >>= 7
        out += bytes([b | 0x80]) if n else bytes([b])
        if not n: break
    return out

def read_varint(s):
    v = 0; sh = 0
    while True:
        b = s.recv(1)
        if not b: raise EOFError
        b = b[0]; v |= (b & 0x7F) << sh
        if not (b & 0x80): break
        sh += 7
    return v

def players_online():
    """Status-ping 127.0.0.1:25566; return (up, player_count)."""
    s = socket.create_connection(("127.0.0.1", 25566), timeout=4)
    s.settimeout(4)
    host = b"localhost"
    hs = b"\x00" + varint(776) + varint(len(host)) + host + struct.pack(">H", 25566) + b"\x01"
    s.sendall(varint(len(hs)) + hs)
    s.sendall(varint(1) + b"\x00")
    read_varint(s); read_varint(s)
    sl = read_varint(s)
    body = b""
    while len(body) < sl:
        c = s.recv(sl - len(body))
        if not c: break
        body += c
    s.close()
    j = json.loads(body)
    return True, j.get("players", {}).get("online", 0)

def panel_stop():
    cred = {}
    for line in open(CRED):
        k, _, v = line.strip().partition("=")
        cred[k] = v
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    req = urllib.request.Request(API + "/auth/login", data=json.dumps(
        {"email": cred["email"], "password": cred["password"]}).encode(),
        headers={"Content-Type": "application/json"})
    op.open(req, timeout=15)
    req2 = urllib.request.Request(API + "/api/servers/2ecfbe8c/stop", data=b"", method="POST")
    with op.open(req2, timeout=15) as r:
        return r.status

def load_state():
    try:
        return json.load(open(STATE))
    except Exception:
        return {"last_active": None}

def save_state(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump(st, open(STATE, "w"))

def main():
    st = load_state()
    try:
        up, n = players_online()
    except Exception:
        up, n = False, 0
    if not up:
        if st.get("last_active") is not None:
            save_state({"last_active": None})  # server down, reset
        return
    now = time.time()
    if n > 0:
        save_state({"last_active": now})
        return
    if st.get("last_active") is None:
        save_state({"last_active": now})
        return
    if now - st["last_active"] >= TIMEOUT:
        try:
            panel_stop()
        except Exception as e:
            print("mc-idle-sleeper: stop failed:", e, file=sys.stderr)
        else:
            print(f"mc-idle-sleeper: stopped server after {int(now - st['last_active'])}s idle")
        finally:
            save_state({"last_active": None})

if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# scripts/modules/matrix-admin.sh — accounts and health for the Matrix module.
#
# The web UI is a client (Element); an account is a Matrix user id
# (@name:$DOMAIN). Reads and writes go through Synapse's own PSQL store and its
# admin API, never by editing the database directly.
#
# Auth: the admin bot created at install (SYNAPSE_ADMIN_USER / its password in
# modules/matrix/.env) logs in to the local client API and the admin API calls
# carry that access token. Usage:
#
#   matrix-admin.sh users                     list every account
#   matrix-admin.sh add <user> [<pass>]       create an account (pass printed once)
#   matrix-admin.sh add <user> [<pass>] admin create it with the server-admin flag
#   matrix-admin.sh passwd <user> [<pass>]    reset a password (sessions out)
#   matrix-admin.sh admin <user> <true|false> grant / revoke server admin
#   matrix-admin.sh del <user>                deactivate an account
#   matrix-admin.sh status                    containers + /health
#   matrix-admin.sh logs [<lines>]            tail the Synapse container
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh"

ENV="$REPO_DIR/modules/matrix/.env"
[ -f "$ENV" ] || { echo "matrix-admin: $ENV is missing — run 'make matrix-gen'" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV"

die() { printf 'matrix-admin: %s\n' "$*" >&2; exit 1; }

# full_id <user> — accept both `name` and `@name:domain`.
full_id() {
  case "$1" in
    @*:*) printf '%s' "$1" ;;
    @*)   printf '%s:%s' "$1" "$DOMAIN" ;;
    *)    printf '@%s:%s' "$1" "$DOMAIN" ;;
  esac
}

# _api <command> [args...] — run one admin operation inside the Synapse
# container (python3 is always present there; curl is not).
_api() {
  docker exec -i \
    -e MX_USER="$SYNAPSE_ADMIN_USER" \
    -e MX_PASS="$SYNAPSE_ADMIN_PASSWORD" \
    -e MX_ARGS="$*" \
    matrix-synapse python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

BASE = "http://127.0.0.1:8008"
USER, PASS = os.environ["MX_USER"], os.environ["MX_PASS"]
args = os.environ["MX_ARGS"].split()


def call(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(BASE + path, method=method, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")
    except OSError as e:
        return 0, {"error": str(e)}


def token():
    code, out = call("POST", "/_matrix/client/v3/login", {
        "type": "m.login.password",
        "identifier": {"type": "m.id.user", "user": USER},
        "password": PASS,
    })
    if code != 200 or "access_token" not in out:
        sys.exit("matrix-admin: admin login failed (%s) — the admin account in modules/matrix/.env is missing or its password is stale; `make matrix-users` lists what exists" % code)
    return out["access_token"]


cmd = args[0] if args else "status"
if cmd == "health":
    code, _ = call("GET", "/health")
    print("ok" if code == 200 else "unhealthy")
    sys.exit(0 if code == 200 else 1)

tok = token()
if cmd == "reset_password":
    code, out = call("POST", "/_synapse/admin/v1/reset_password/" + args[1],
                     {"new_password": args[2], "logout_devices": True}, tok)
elif cmd == "deactivate":
    code, out = call("POST", "/_synapse/admin/v1/deactivate/" + args[1], {"erase": False}, tok)
elif cmd == "admin":
    code, out = call("PUT", "/_synapse/admin/v1/users/" + args[1] + "/admin",
                     {"admin": args[2] == "true"}, tok)
else:
    sys.exit("matrix-admin: unknown api command " + cmd)
print(code, json.dumps(out))
sys.exit(0 if 200 <= code < 300 else 1)
PY
}

# _sql <query> — read the store through its own psql client (users live there).
_sql() { docker exec matrix-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }

case "${1:-status}" in
  users)
    printf '%-32s %-5s %-11s %s\n' USER ADMIN DEACTIVATED CREATED
    _sql "select name, admin, deactivated, to_char(to_timestamp(creation_ts), 'YYYY-MM-DD') from users order by name" \
      | awk -F'|' '{printf "%-32s %-5s %-11s %s\n", $1, $2, $3, $4}'
    ;;
  add)
    user=${2:-}; [ -n "$user" ] || die "usage: matrix-admin.sh add <user> [<pass>] [admin]"
    pass=${3:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)}
    # A plain account by default: `-a` makes every new user a SERVER ADMIN, and
    # the admin flag is then only ever taken away. Only the fourth argument
    # (`make matrix-admin`) asks for one.
    opts=(-u "$user" -p "$pass")
    [ "${4:-}" = admin ] && opts+=(-a)
    docker exec matrix-synapse register_new_matrix_user "${opts[@]}" \
      -c /data/homeserver.yaml http://127.0.0.1:8008 >/dev/null 2>&1 \
      || die "cannot create $user (does the account already exist?)"
    printf 'created %s\npassword: %s\n' "$(full_id "$user")" "$pass"
    ;;
  passwd)
    user=${2:-}; [ -n "$user" ] || die "usage: matrix-admin.sh passwd <user> [<pass>]"
    pass=${3:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)}
    _api reset_password "$(full_id "$user")" "$pass" >/dev/null \
      || die "password reset failed for $(full_id "$user") — is the admin bot an admin?"
    printf 'reset %s\npassword: %s\n' "$(full_id "$user")" "$pass"
    ;;
  admin)
    user=${2:-}; flag=${3:-}
    case "$flag" in true|false) ;; *) die "usage: matrix-admin.sh admin <user> <true|false>" ;; esac
    _api admin "$(full_id "$user")" "$flag" >/dev/null || die "admin flag change failed"
    echo "$(full_id "$user") admin=$flag"
    ;;
  del)
    user=${2:-}; [ -n "$user" ] || die "usage: matrix-admin.sh del <user>"
    _api deactivate "$(full_id "$user")" >/dev/null || die "deactivation failed"
    echo "deactivated $(full_id "$user")"
    ;;
  status)
    docker ps -a --filter name='^matrix-' --format '  {{.Names}}\t{{.Status}}'
    printf '  health: '; _api health || true
    ;;
  logs)
    docker logs matrix-synapse --tail "${2:-50}" -f
    ;;
  *)
    die "usage: matrix-admin.sh users|add|passwd|admin|del|status|logs"
    ;;
esac

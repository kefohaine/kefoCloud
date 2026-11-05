#!/usr/bin/env bash
# scripts/modules/matrix-admin.sh — accounts and health for the Matrix module.
#
# The web UI is a client (Element); an account is a Matrix user id
# (@name:matrix.$DOMAIN). Reads and writes go through Synapse's own PSQL store and its
# admin API, never by editing the database directly.
#
# Auth: homeserver authentication is delegated to MAS (ESS CE), so Synapse has
# no password login to take. The admin API calls carry MAS_SYNAPSE_SECRET from
# modules/matrix/.env — the shared secret MAS itself uses for /_synapse/admin —
# and account creation, passwords and locking go through `mas-cli manage`
# inside the MAS container. Usage:
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

# The homeserver NAME (user-id suffix) — not the public domain: since the
# homeserver answers on matrix.$DOMAIN, that hostname IS the identity domain.
SERVER_NAME="matrix.$DOMAIN"

die() { printf 'matrix-admin: %s\n' "$*" >&2; exit 1; }

# full_id <user> — accept both `name` and `@name:domain`.
full_id() {
  case "$1" in
    @*:*) printf '%s' "$1" ;;
    @*)   printf '%s:%s' "$1" "$SERVER_NAME" ;;
    *)    printf '@%s:%s' "$1" "$SERVER_NAME" ;;
  esac
}

# _api <command> [args...] — run one admin operation inside the Synapse
# container (python3 is always present there; curl is not). Under delegated
# auth Synapse has no admin_token: the credential is a MAS compatibility token
# carrying the Synapse admin scope, minted for the admin account on each call.
_api() {
  local mx_token
  mx_token=$(docker exec matrix-mas mas-cli manage -c /data/config.yaml \
    issue-compatibility-token --yes-i-want-to-grant-synapse-admin-privileges \
    "$SYNAPSE_ADMIN_USER" 2>&1 \
    | sed -n 's/.*Compatibility token issued: \([^ ]*\).*/\1/p' | tail -1)
  [ -n "$mx_token" ] || die "cannot mint an admin token for $SYNAPSE_ADMIN_USER — is it a MAS admin (make matrix-flag-admin)?"
  docker exec -i \
    -e MX_TOKEN="$mx_token" \
    -e MX_ARGS="$*" \
    matrix-synapse python3 - <<'PY'
import json, os, sys, urllib.error, urllib.parse, urllib.request

BASE = "http://127.0.0.1:8008"
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
    # A MAS compatibility token with the Synapse admin scope (minted by the
    # caller). Synapse has no admin_token under delegated auth.
    static = os.environ.get("MX_TOKEN") or ""
    if not static:
        sys.exit("matrix-admin: no admin token was supplied")
    return static


cmd = args[0] if args else "status"
if cmd == "health":
    # Synapse answers /health with the plain-text body "OK", so it cannot go
    # through call(), which parses JSON on every response.
    try:
        with urllib.request.urlopen(BASE + "/health", timeout=10) as r:
            ok = r.status == 200
    except (urllib.error.URLError, OSError):
        ok = False
    print("ok" if ok else "unhealthy")
    sys.exit(0 if ok else 1)

tok = token()
if cmd == "reset_password":
    code, out = call("POST", "/_synapse/admin/v1/reset_password/" + args[1],
                     {"new_password": args[2], "logout_devices": True}, tok)
elif cmd == "deactivate":
    code, out = call("POST", "/_synapse/admin/v1/deactivate/" + urllib.parse.quote(args[1], safe=""), {"erase": False}, tok)
elif cmd == "admin":
    code, out = call("PUT", "/_synapse/admin/v2/users/" + urllib.parse.quote(args[1], safe=""),
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
    # (`make matrix-add-admin`) asks for one.
    # Users are MAS's: Synapse's own registration endpoint is gone once auth is
    # delegated. -a makes the account a MAS admin (Element Admin needs that) as
    # well as a Synapse server admin.
    opts=(--yes -p "$pass")
    [ "${4:-}" = admin ] && opts+=(-a)
    docker exec matrix-mas mas-cli manage -c /data/config.yaml register-user "${opts[@]}" "$user" >/dev/null 2>&1 \
      || die "cannot create $user (does the account already exist?)"
    if [ "${4:-}" = admin ]; then
      _api admin "$(full_id "$user")" true >/dev/null \
        || die "created $user but the Synapse server-admin flag did not apply (is matrix-synapse healthy?)"
    fi
    printf 'created %s\npassword: %s\n' "$(full_id "$user")" "$pass"
    ;;
  passwd)
    user=${2:-}; [ -n "$user" ] || die "usage: matrix-admin.sh passwd <user> [<pass>]"
    pass=${3:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)}
    docker exec matrix-mas mas-cli manage -c /data/config.yaml set-password "$user" "$pass" >/dev/null 2>&1 \
      || die "password reset failed for $(full_id "$user")"
    printf 'reset %s\npassword: %s\n' "$(full_id "$user")" "$pass"
    ;;
  admin)
    user=${2:-}; flag=${3:-}
    case "$flag" in true|false) ;; *) die "usage: matrix-admin.sh admin <user> <true|false>" ;; esac
    out=$(_api admin "$(full_id "$user")" "$flag" 2>&1) || die "admin flag change failed: $out"
    echo "$(full_id "$user") admin=$flag"
    ;;
  del)
    user=${2:-}; [ -n "$user" ] || die "usage: matrix-admin.sh del <user>"
    docker exec matrix-mas mas-cli manage -c /data/config.yaml lock-user "$user" >/dev/null 2>&1 \
      || die "lock failed for $(full_id "$user")"
    _api deactivate "$(full_id "$user")" >/dev/null 2>&1 || true
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

#!/usr/bin/env bash
#
# scripts/panel-user.sh — PufferPanel account management. `add` uses the
# panel CLI (`pufferpanel user add`); `list`/`del` read/write the users table
# in puffer/data/pufferpanel.db (passwords live in the DB and are never
# printed). Use the make recipes: panel-list-users, panel-add-user
# USER=… NAME=… [PASS=…] [ADMIN=1], panel-del-user USER=….
#
# Subcommands: list | add <email> <name> <pass> [admin] | passwd <email> <newpass> | del <email>
#
# passwd writes a bcrypt hash straight into the users table (the CLI's
# `user edit` is broken in this build) using mkpasswd (whois package) with the
# password on stdin, so it never appears in argv. The panel caches users at
# boot — restart it (make dok-restart-pufferpanel) to apply.

set -uo pipefail

DB=/var/www/custom/projects/homelab/puffer/data/pufferpanel.db

case "${1:-}" in
  list)
    python3 - "$DB" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
for r in c.execute("SELECT id, username, email FROM users ORDER BY id"):
    print(f"info:  id={r[0]} username={r[1]} email={r[2]}")
EOF
    ;;
  add)
    [ $# -ge 4 ] || { echo "usage: panel-user.sh add <email> <name> <pass> [admin]"; exit 1; }
    args=(user add --email "$2" --name "$3" --password "$4")
    [ "${5:-}" = admin ] && args+=(--admin)
    docker exec pufferpanel /pufferpanel/bin/pufferpanel "${args[@]}"
    ;;
  passwd)
    [ $# -eq 3 ] || { echo "usage: panel-user.sh passwd <email|username> <newpassword>"; exit 1; }
    HASH="$(printf '%s' "$3" | mkpasswd -m bcrypt -s 2>/dev/null)"
    [ -n "$HASH" ] || { echo "error: bcrypt hashing failed (mkpasswd from the whois package is required)"; exit 1; }
    sudo python3 - "$DB" "$2" "$HASH" <<'EOF' || exit 1
import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); c = db.cursor()
row = c.execute("SELECT id FROM users WHERE email = ? OR username = ?", (sys.argv[2], sys.argv[2])).fetchone()
if not row: print(f"error: no panel user matching '{sys.argv[2]}'"); sys.exit(1)
c.execute("UPDATE users SET password = ? WHERE id = ?", (sys.argv[3], row[0]))
db.commit(); print(f"info:  panel password updated for '{sys.argv[2]}' (restart the panel to apply)")
EOF
    ;;
  del)
    [ $# -eq 2 ] || { echo "usage: panel-user.sh del <email>"; exit 1; }
    sudo python3 - "$DB" "$2" <<'EOF' || exit 1
import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); c = db.cursor()
row = c.execute("SELECT id FROM users WHERE email = ?", (sys.argv[2],)).fetchone()
if not row: print(f"error: no panel user with email {sys.argv[2]}"); sys.exit(1)
uid = row[0]
c.execute("DELETE FROM permissions WHERE user_id = ?", (uid,))
c.execute("DELETE FROM user_settings WHERE user_id = ?", (uid,))
c.execute("DELETE FROM users WHERE id = ?", (uid,))
db.commit(); print(f"info:  panel user {sys.argv[2]} deleted (permissions + settings removed)")
EOF
    ;;
  *) echo "usage: panel-user.sh list|add <email> <name> <pass> [admin]|passwd <email> <newpass>|del <email>"; exit 1 ;;
esac

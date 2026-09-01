#!/usr/bin/env bash
#
# scripts/panel-user.sh — PufferPanel account management. `add` uses the
# panel CLI (`pufferpanel user add`); `list`/`del` read/write the users table
# in puffer/data/pufferpanel.db (passwords live in the DB and are never
# printed). Use the make recipes: panel-list-users, panel-add-user
# USER=… NAME=… [PASS=…] [ADMIN=1], panel-del-user USER=….
#
# Subcommands: list | add <email> <name> <pass> [admin] | del <email>

set -uo pipefail

DB=/var/www/custom/projects/homelab/puffer/data/pufferpanel.db

case "${1:-}" in
  list)
    python3 - "$DB" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
for r in c.execute("SELECT id, username, email FROM users ORDER BY id"):
    print(f"{r[0]}\t{r[1]}\t{r[2]}")
EOF
    ;;
  add)
    [ $# -ge 4 ] || { echo "usage: panel-user.sh add <email> <name> <pass> [admin]"; exit 1; }
    args=(user add --email "$2" --name "$3" --password "$4")
    [ "${5:-}" = admin ] && args+=(--admin)
    docker exec pufferpanel /pufferpanel/bin/pufferpanel "${args[@]}"
    ;;
  del)
    [ $# -eq 2 ] || { echo "usage: panel-user.sh del <email>"; exit 1; }
    sudo python3 - "$DB" "$2" <<'EOF' || exit 1
import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); c = db.cursor()
row = c.execute("SELECT id FROM users WHERE email = ?", (sys.argv[2],)).fetchone()
if not row: print("no panel user with email", sys.argv[2]); sys.exit(1)
uid = row[0]
c.execute("DELETE FROM permissions WHERE user_id = ?", (uid,))
c.execute("DELETE FROM user_settings WHERE user_id = ?", (uid,))
c.execute("DELETE FROM users WHERE id = ?", (uid,))
db.commit(); print("panel user", sys.argv[2], "deleted")
EOF
    ;;
  *) echo "usage: panel-user.sh list|add <email> <name> <pass> [admin]|del <email>"; exit 1 ;;
esac

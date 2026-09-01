#!/usr/bin/env bash
#
# scripts/kuma-user.sh — Uptime Kuma account management (Kuma has no CLI, so
# users live in its SQLite DB at kuma/data/kuma.db). Passwords are hashed
# with bcryptjs inside the uptimekuma container (bcryptjs ships with Kuma)
# and written via the host's python3 sqlite — the hash crosses the boundary,
# never the plaintext. Use the make recipes: kuma-list-users, kuma-add-user
# USER=… PASS=…, kuma-passwd USER=… PASS=…, kuma-del-user USER=….
#
# Subcommands: list | add <user> <pass> | passwd <user> <pass> | del <user>

set -uo pipefail

DB=/var/www/custom/projects/homelab/kuma/data/kuma.db

hash_pass() { # hash_pass <plaintext> — bcrypt via the container (no argv leak)
  docker exec -e KUMA_PASS="$1" uptimekuma node -e \
    "console.log(require('bcryptjs').hashSync(process.env.KUMA_PASS, 10))"
}

case "${1:-}" in
  list)
    python3 - "$DB" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
for r in c.execute("SELECT id, username, active FROM user ORDER BY id"):
    print(f"{r[0]}\t{r[1]}\t{'active' if r[2] else 'disabled'}")
EOF
    ;;
  add)
    [ $# -eq 3 ] || { echo "usage: kuma-user.sh add <user> <pass>"; exit 1; }
    HASH=$(hash_pass "$3") || exit 1
    sudo python3 - "$DB" "$2" "$HASH" <<'EOF' || exit 1
import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); c = db.cursor()
try:
    c.execute("INSERT INTO user (username, password, active, timezone) VALUES (?,?,1,'Europe/Paris')", (sys.argv[2], sys.argv[3]))
except sqlite3.IntegrityError:
    print(f"user '{sys.argv[2]}' already exists"); sys.exit(1)
db.commit(); print(f"kuma user '{sys.argv[2]}' created")
EOF
    ;;
  passwd)
    [ $# -eq 3 ] || { echo "usage: kuma-user.sh passwd <user> <pass>"; exit 1; }
    HASH=$(hash_pass "$3") || exit 1
    sudo python3 - "$DB" "$2" "$HASH" <<'EOF' || exit 1
import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); c = db.cursor()
row = c.execute("SELECT id FROM user WHERE username = ?", (sys.argv[2],)).fetchone()
if not row: print(f"user '{sys.argv[2]}' not found"); sys.exit(1)
c.execute("UPDATE user SET password = ? WHERE id = ?", (sys.argv[3], row[0]))
db.commit(); print(f"kuma password updated for '{sys.argv[2]}'")
EOF
    ;;
  del)
    [ $# -eq 2 ] || { echo "usage: kuma-user.sh del <user>"; exit 1; }
    sudo python3 - "$DB" "$2" <<'EOF' || exit 1
import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); c = db.cursor()
row = c.execute("SELECT id FROM user WHERE username = ?", (sys.argv[2],)).fetchone()
if not row: print(f"user '{sys.argv[2]}' not found"); sys.exit(1)
uid = row[0]
for t in ("notification", "monitor"):
    c.execute(f"DELETE FROM {t} WHERE user_id = ?", (uid,))
c.execute("DELETE FROM user WHERE id = ?", (uid,))
db.commit(); print(f"kuma user '{sys.argv[2]}' and their monitors/notifications deleted")
EOF
    ;;
  *) echo "usage: kuma-user.sh list|add <user> <pass>|passwd <user> <pass>|del <user>"; exit 1 ;;
esac

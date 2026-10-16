#!/usr/bin/env bash
#
# scripts/modules/vaultwarden-user.sh — Vaultwarden account management (Vaultwarden
# has no user CLI, so users live in its SQLite DB at vault/data/db.sqlite3).
# A Bitwarden account is not just a password: the server stores the client's
# master-password *authentication hash* (PBKDF2 of the master key) plus the
# user's symmetric key and RSA key pair, each encrypted client-side. This
# script reproduces that client-side crypto (Bitwarden's KDF + "type 2"
# AES-256-CBC/HMAC-SHA256 EncString) so a usable account can be created
# without the web vault — the plaintext password never leaves this process and
# is never written down. Use the make recipes: vaultwarden-list-users,
# vaultwarden-add-user EMAIL=… PASS=…, vaultwarden-del-user EMAIL=….
#
# Subcommands: list | add <email> <pass> | ensure <email> <pass> | del <email>
# (add fails if the account exists; ensure is add-if-missing, for install.sh)

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
DB="$ROOT/data/vault/data/db.sqlite3"

[ -f "$DB" ] || { echo "error: $DB not found (is the vaultwarden container up?)" >&2; exit 1; }

MODE="${1:-}"; shift 2>/dev/null || true

# Reads are fine as the caller; writes to the live DB need root (mirrors
# scripts/modules/kuma-user.sh). `list` opens the DB read-only either way.
case "$MODE" in
  list) RUN=(python3) ;;
  *)    RUN=(sudo python3) ;;
esac

"${RUN[@]}" - "$DB" "$MODE" "$@" <<'PYEOF'
import base64, hashlib, hmac, os, subprocess, sys, tempfile, uuid, datetime, sqlite3

DEFAULT_ITER = 600_000   # Bitwarden's PBKDF2 default; must match the client.
KDF_TYPE = 0             # 0 = PBKDF2-SHA256


def b64(b):
    return base64.b64encode(b).decode()


def pbkdf2(pw, salt, it, dklen=32):
    return hashlib.pbkdf2_hmac("sha256", pw, salt, it, dklen)


def hkdf_expand(prk, info, length):
    # Bitwarden stretches the master key with HKDF-Expand ONLY (no extract):
    # T(i) = HMAC(prk, T(i-1) || info || i). See clients' hkdfExpand.
    out, t, i = b"", b"", 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:length]


def aes_cbc(pt, key, iv, decrypt=False):
    args = ["openssl", "enc"]
    if decrypt:
        args.append("-d")
    args += ["-aes-256-cbc", "-K", key.hex(), "-iv", iv.hex()]
    return subprocess.run(args, input=pt, capture_output=True, check=True).stdout


def enc_str(plain, ek, mk):
    # Bitwarden "type 2" EncString: 2.<b64 iv>|<b64 ciphertext>|<b64 hmac>
    iv = os.urandom(16)
    ct = aes_cbc(plain, ek, iv)
    mac = hmac.new(mk, iv + ct, hashlib.sha256).digest()
    return "2." + b64(iv) + "|" + b64(ct) + "|" + b64(mac)


def gen_rsa():
    pem = os.path.join(tempfile.mkdtemp(), "k.pem")
    subprocess.run(["openssl", "genpkey", "-algorithm", "RSA",
                    "-pkeyopt", "rsa_keygen_bits:2048", "-out", pem],
                   check=True, capture_output=True)
    pkcs8 = subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-inform", "PEM",
                            "-outform", "DER", "-in", pem], check=True,
                           capture_output=True).stdout
    spki = subprocess.run(["openssl", "pkey", "-pubout", "-inform", "PEM",
                           "-outform", "DER", "-in", pem], check=True,
                          capture_output=True).stdout
    return pkcs8, spki


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")


def build_row(email, password, name):
    email = email.strip().lower()
    mk = pbkdf2(password.encode(), email.encode(), DEFAULT_ITER, 32)   # salt = email
    ek = hkdf_expand(mk, b"enc", 32)
    mk2 = hkdf_expand(mk, b"mac", 32)
    user_key = os.urandom(64)
    uek, umk = user_key[:32], user_key[32:]
    priv, pub = gen_rsa()
    salt = os.urandom(64)
    # The server stores PBKDF2(masterPasswordHash, salt, iterations); the client's
    # masterPasswordHash is base64(PBKDF2(masterKey, password, 1)).
    auth = base64.b64encode(pbkdf2(mk, password.encode(), 1, 32))
    ts = now()
    return {
        "uuid": str(uuid.uuid4()),
        "created_at": ts, "updated_at": ts,
        "email": email, "name": name,
        "password_hash": pbkdf2(auth, salt, DEFAULT_ITER, 32),
        "salt": salt, "password_iterations": DEFAULT_ITER,
        "akey": enc_str(user_key, ek, mk2),
        "private_key": enc_str(priv, uek, umk),
        "public_key": b64(pub),
        "security_stamp": str(uuid.uuid4()),
        "equivalent_domains": "", "excluded_globals": "",
        "client_kdf_type": KDF_TYPE, "client_kdf_iter": DEFAULT_ITER,
        "verified_at": ts, "enabled": 1,
    }


def main():
    db, mode = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True) if mode == "list" \
        else sqlite3.connect(db, timeout=30)
    cols = {r[1]: (r[3], r[4]) for r in con.execute("PRAGMA table_info(users)")}
    # Vaultwarden renamed the encrypted user key column at some point — accept both.
    key_col = "key" if "key" in cols else "akey"

    def find(email):
        return con.execute("SELECT uuid FROM users WHERE email = ?",
                           (email.strip().lower(),)).fetchone()

    if mode == "list":
        for r in con.execute("SELECT email, name, enabled FROM users ORDER BY email"):
            print(f"info:  {r[0]}  ({r[1]}){'  [disabled]' if not r[2] else ''}")
        return

    if mode == "del":
        if len(args) != 1:
            sys.exit("usage: vaultwarden-user.sh del <email>")
        row = find(args[0])
        if not row:
            sys.exit(f"error: account '{args[0]}' not found")
        uid = row[0]
        # Delete every row the account owns — derived from the live schema.
        for (t,) in con.execute("SELECT name FROM sqlite_master WHERE type='table'"):
            tcols = [c[1] for c in con.execute(f"PRAGMA table_info({t})")]
            if "user_uuid" in tcols:
                con.execute(f"DELETE FROM {t} WHERE user_uuid = ?", (uid,))
        con.execute("DELETE FROM users WHERE uuid = ?", (uid,))
        con.commit()
        print(f"info:  account '{args[0]}' deleted")
        return

    if mode not in ("add", "ensure") or len(args) != 2:
        sys.exit("usage: vaultwarden-user.sh list|add <email> <pass>|ensure <email> <pass>|del <email>")

    email, password = args
    if find(email):
        if mode == "add":
            sys.exit(f"error: account '{email}' already exists")
        print(f"info:  account '{email}' already exists")
        return

    row = build_row(email, password, email.split("@")[0])
    if key_col != "akey":
        row[key_col] = row.pop("akey")
    # Only fill columns that exist; refuse to guess past a required one.
    fill = {k: v for k, v in row.items() if k in cols}
    missing = [c for c, (notnull, default) in cols.items()
               if notnull and default is None and c not in fill]
    if missing:
        sys.exit(f"error: schema has required columns this script does not set: {missing}")
    q = f"INSERT INTO users ({','.join(fill)}) VALUES ({','.join('?' * len(fill))})"
    con.execute(q, list(fill.values()))
    con.commit()
    print(f"info:  account '{email}' created")


main()
PYEOF

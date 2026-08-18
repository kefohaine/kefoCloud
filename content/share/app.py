import os
import sqlite3
import secrets
import string
import time
import socket
from urllib.parse import urlparse
from flask import Flask, request, redirect, abort, render_template, jsonify, url_for

BASE_DIR = os.environ.get("LINK_DB_DIR", "/data")
DB_PATH = os.path.join(BASE_DIR, "links.db")
FILES_DIR = os.path.join(BASE_DIR, "files")
os.makedirs(FILES_DIR, exist_ok=True)
ALLOWED_CHARS = string.ascii_lowercase + string.digits + "-_."
SLUG_ALPHABET = "acdefhjkmnpqrtwxy3479"
LIFESPAN_SECONDS = 365 * 24 * 3600


def gen_slug(length=6):
    return "".join(secrets.choice(SLUG_ALPHABET) for _ in range(length))


def delete_file_if_linked(target):
    """If target is a /files/<name> URL on this host, remove the file from disk."""
    if "/files/" not in target:
        return
    name = target.split("/files/", 1)[1]
    if not name or "/" in name or ".." in name:
        return
    path = os.path.join(FILES_DIR, name)
    if os.path.isfile(path):
        try:
            os.remove(path)
        except OSError:
            pass

app = Flask(__name__)


def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    os.makedirs(BASE_DIR, exist_ok=True)
    conn = db()
    conn.execute(
        "CREATE TABLE IF NOT EXISTS links ("
        "  slug TEXT PRIMARY KEY,"
        "  target TEXT NOT NULL,"
        "  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),"
        "  hits INTEGER NOT NULL DEFAULT 0"
        ")"
    )
    cols = [r[1] for r in conn.execute("PRAGMA table_info(links)").fetchall()]
    if "expires_at" not in cols:
        conn.execute("ALTER TABLE links ADD COLUMN expires_at INTEGER")
        conn.execute("UPDATE links SET expires_at = created_at + 31536000 WHERE expires_at IS NULL")
    conn.commit()
    conn.close()


init_db()


def purge_expired():
    """Delete expired links and their linked files. Called on every resolve."""
    now = int(time.time())
    conn = db()
    rows = conn.execute("SELECT target FROM links WHERE expires_at < ?", (now,)).fetchall()
    if rows:
        conn.execute("DELETE FROM links WHERE expires_at < ?", (now,))
        conn.commit()
    conn.close()
    for r in rows:
        delete_file_if_linked(r["target"])


def valid_slug(s):
    return s and all(c.isalnum() or c in "-_" for c in s) and len(s) <= 64


@app.errorhandler(404)
def not_found(e):
    if request.path.startswith("/api/") or request.path.startswith("/share/"):
        return jsonify(error="not found"), 404
    return e


def resolves(url):
    """Check if the URL's hostname resolves via DNS. Always tests https://."""
    try:
        host = urlparse(url).hostname
        if not host:
            return False
        socket.getaddrinfo(host, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
        return True
    except (socket.gaierror, Exception):
        return False


def normalize_target(target):
    """Prepend https:// if no scheme present."""
    target = target.strip()
    if not target.startswith(("http://", "https://")):
        target = "https://" + target
    return target


@app.route("/check", methods=["POST"])
def check_url():
    target = (request.form.get("target") or "").strip()
    if not target:
        return jsonify(valid=False, error="target is required"), 400
    target = normalize_target(target)
    if not resolves(target):
        return jsonify(valid=False, error="URL does not resolve"), 422
    return jsonify(valid=True)


@app.route("/", methods=["GET", "POST"])
def index():
    if request.method == "GET":
        return render_template("public.html", short=None, error=None)
    # POST — create a short link from the public form (auto-slug only).
    target = (request.form.get("target") or "").strip()
    if not target:
        return render_template("public.html", short=None, error="target is required"), 400
    target = normalize_target(target)
    if not resolves(target):
        return render_template("public.html", short=None, error="URL does not resolve", dns_error=True), 422
    slug = gen_slug()
    conn = db()
    try:
        conn.execute(
            "INSERT INTO links (slug, target, expires_at) VALUES (?, ?, ?)",
            (slug, target, int(time.time()) + LIFESPAN_SECONDS),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        conn.close()
        return render_template("public.html", short=None, error="slug collision, retry"), 503
    conn.close()
    host = request.host
    return render_template("public.html", short=f"https://{host}/{slug}", error=None)


@app.route("/upload", methods=["POST"])
def upload_file():
    f = request.files.get("file")
    if not f or not f.filename:
        return render_template("public.html", short=None, error="no file provided"), 400
    # Sanitize filename: lowercase, drop anything not in ALLOWED_CHARS, avoid traversal.
    safe = "".join(c for c in f.filename.lower() if c in ALLOWED_CHARS).lstrip(".")
    if not safe:
        safe = "file"
    # Avoid clobbering existing files: append a short suffix if needed.
    name, ext = os.path.splitext(safe)
    dest = os.path.join(FILES_DIR, safe)
    suffix = ""
    while os.path.exists(dest):
        suffix = secrets.token_hex(2)
        dest = os.path.join(FILES_DIR, f"{name}-{suffix}{ext}")
    safe = os.path.basename(dest)
    f.save(dest)
    # Auto-short link to the file URL.
    host = request.host
    target = f"https://{host}/files/{safe}"
    slug = gen_slug()
    conn = db()
    try:
        conn.execute(
            "INSERT INTO links (slug, target, expires_at) VALUES (?, ?, ?)",
            (slug, target, int(time.time()) + LIFESPAN_SECONDS),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        conn.close()
        os.remove(dest)
        return render_template("public.html", short=None, error="slug collision, retry"), 503
    conn.close()
    return render_template("public.html", short=f"https://{host}/{slug}", error=None)


@app.route("/share", methods=["GET"])
def admin_page():
    conn = db()
    rows = conn.execute(
        "SELECT slug, target, created_at, hits FROM links ORDER BY created_at DESC"
    ).fetchall()
    conn.close()
    return render_template("admin.html", links=rows)


@app.route("/share", methods=["POST"])
def admin_create():
    data = request.form
    slug = (data.get("slug") or "").strip()
    target = (data.get("target") or "").strip()

    if not slug:
        slug = gen_slug()
    if not valid_slug(slug):
        return render_template("admin.html", links=all_rows(), error="slug must be 1-64 alnum/-/_"), 400
    if not target:
        return render_template("admin.html", links=all_rows(), error="target is required"), 400
    target = normalize_target(target)
    if not resolves(target):
        return render_template("admin.html", links=all_rows(), error="URL does not resolve"), 422

    conn = db()
    try:
        conn.execute(
            "INSERT INTO links (slug, target, expires_at) VALUES (?, ?, ?)",
            (slug, target, int(time.time()) + LIFESPAN_SECONDS),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        conn.close()
        return render_template("admin.html", links=all_rows(), error=f"'{slug}' already exists"), 400
    conn.close()
    return redirect("/share", code=303)


@app.route("/share/all", methods=["DELETE", "POST"])
def admin_delete_all():
    if request.method == "POST" and request.form.get("_method") != "DELETE":
        abort(405)
    conn = db()
    rows = conn.execute("SELECT target FROM links").fetchall()
    conn.execute("DELETE FROM links")
    conn.commit()
    conn.close()
    for r in rows:
        delete_file_if_linked(r["target"])
    return redirect("/share", code=303)


@app.route("/share/<slug>", methods=["DELETE", "POST"])
def admin_delete(slug):
    if request.method == "POST" and request.form.get("_method") != "DELETE":
        abort(405)
    conn = db()
    row = conn.execute("SELECT target FROM links WHERE slug = ?", (slug,)).fetchone()
    conn.execute("DELETE FROM links WHERE slug = ?", (slug,))
    conn.commit()
    conn.close()
    if row:
        delete_file_if_linked(row["target"])
    if request.headers.get("Accept") == "application/json":
        return jsonify(ok=True)
    return redirect("/share", code=303)


def all_rows():
    conn = db()
    rows = conn.execute(
        "SELECT slug, target, created_at, hits FROM links ORDER BY created_at DESC"
    ).fetchall()
    conn.close()
    return rows


@app.route("/<slug>")
def resolve(slug):
    if not valid_slug(slug):
        abort(404)
    purge_expired()
    conn = db()
    row = conn.execute("SELECT target, hits FROM links WHERE slug = ?", (slug,)).fetchone()
    if row:
        conn.execute("UPDATE links SET hits = hits + 1 WHERE slug = ?", (slug,))
        conn.commit()
        target = row["target"]
        conn.close()
        return redirect(target, code=307)
    conn.close()
    abort(404)


@app.route("/api/links", methods=["POST"])
def api_list():
    conn = db()
    rows = conn.execute(
        "SELECT slug, target, created_at, hits FROM links ORDER BY created_at DESC"
    ).fetchall()
    conn.close()
    return jsonify([dict(r) for r in rows])


@app.route("/healthz")
def healthz():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
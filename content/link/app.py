import os
import sqlite3
import secrets
from flask import Flask, request, redirect, abort, render_template, jsonify, url_for

BASE_DIR = os.environ.get("LINK_DB_DIR", "/data")
DB_PATH = os.path.join(BASE_DIR, "links.db")

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
    conn.commit()
    conn.close()


init_db()


def valid_slug(s):
    return s and all(c.isalnum() or c in "-_" for c in s) and len(s) <= 64


@app.errorhandler(404)
def not_found(e):
    if request.path.startswith("/api/") or request.path.startswith("/link/"):
        return jsonify(error="not found"), 404
    return e


@app.route("/")
def index():
    if request.host.startswith("link."):
        return "ok", 200
    return redirect("/link", code=308)


@app.route("/link", methods=["GET"])
def admin_page():
    conn = db()
    rows = conn.execute(
        "SELECT slug, target, created_at, hits FROM links ORDER BY created_at DESC"
    ).fetchall()
    conn.close()
    return render_template("admin.html", links=rows)


@app.route("/link", methods=["POST"])
def admin_create():
    data = request.form
    slug = (data.get("slug") or "").strip()
    target = (data.get("target") or "").strip()

    if not slug:
        slug = secrets.token_urlsafe(4)
    if not valid_slug(slug):
        return render_template("admin.html", links=all_rows(), error="slug must be 1-64 alnum/-/_"), 400
    if not target:
        return render_template("admin.html", links=all_rows(), error="target is required"), 400
    if not target.startswith(("http://", "https://")):
        target = "https://" + target

    conn = db()
    try:
        conn.execute("INSERT INTO links (slug, target) VALUES (?, ?)", (slug, target))
        conn.commit()
    except sqlite3.IntegrityError:
        conn.close()
        return render_template("admin.html", links=all_rows(), error=f"'{slug}' already exists"), 400
    conn.close()
    return redirect("/link", code=303)


@app.route("/link/<slug>", methods=["DELETE", "POST"])
def admin_delete(slug):
    if request.method == "POST" and request.form.get("_method") != "DELETE":
        abort(405)
    conn = db()
    conn.execute("DELETE FROM links WHERE slug = ?", (slug,))
    conn.commit()
    conn.close()
    if request.headers.get("Accept") == "application/json":
        return jsonify(ok=True)
    return redirect("/link", code=303)


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
    conn = db()
    row = conn.execute("SELECT target, hits FROM links WHERE slug = ?", (slug,)).fetchone()
    if row:
        conn.execute("UPDATE links SET hits = hits + 1 WHERE slug = ?", (slug,))
        conn.commit()
        target = row["target"]
        conn.close()
        return redirect(target, code=301)
    conn.close()
    abort(404)


@app.route("/api/links")
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
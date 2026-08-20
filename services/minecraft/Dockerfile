FROM python:3.12-slim
WORKDIR /app
# flask: dashboard HTTP server (see content/minecraft/app.py)
# gunicorn: WSGI server with sync workers; replaces Flask's dev server so
#   multiple requests run in parallel and large uploads (world .zip)
#   don't block other tabs. Sync workers + threadless rcon pool is the
#   right model here — each worker handles one request at a time, so the
#   in-process rcon connection is safe to share.
# docker: Python SDK for the Docker Engine API; talks to /var/run/docker.sock
#   (bind-mounted by compose) so the dashboard can start/stop/restart the
#   game container without needing the docker CLI inside this image.
# pyyaml: parse + edit Paper/Bukkit/Spigot YAML config files (bukkit.yml,
#   spigot.yml, paper-global.yml, paper-world-defaults.yml) from the Settings tab.
RUN pip install --no-cache-dir \
      flask==3.0.3 \
      gunicorn==23.0.0 \
      docker==7.1.0 \
      pyyaml==6.0.1
EXPOSE 5000
# 2 workers + 4 threads each = 8 concurrent requests. Plenty for a single-user
# tailnet dashboard. timeout=120 covers slow rcon + world tar streams.
# `--chdir /app/src` so gunicorn finds `app` (the Flask app object defined
# in /app/src/app.py — content/minecraft bind-mounted by compose).
CMD ["gunicorn", "--chdir", "/app/src", "--bind", "0.0.0.0:5000", \
     "--workers", "2", "--threads", "4", "--timeout", "120", \
     "--access-logfile", "-", "app:app"]

# mc.fxmq.net homepage + status pings. Stdlib-only Python HTTP server —
# no Flask, no pip installs (probes are socket-level, the page is static).
FROM python:3.12-alpine
WORKDIR /app
COPY app.py index.html ./
EXPOSE 5000
CMD ["python", "-u", "app.py"]

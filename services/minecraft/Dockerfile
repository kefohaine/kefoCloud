FROM python:3.12-slim
WORKDIR /app
# flask: dashboard HTTP server (see content/minecraft/app.py)
# docker: Python SDK for the Docker Engine API; talks to /var/run/docker.sock
#   (bind-mounted by compose) so the dashboard can start/stop/restart the
#   game container without needing the docker CLI inside this image.
RUN pip install --no-cache-dir flask==3.0.3 docker==7.1.0
EXPOSE 5000
CMD ["python", "/app/src/app.py"]

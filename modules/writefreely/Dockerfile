# WriteFreely — upstream releases no Docker image for current versions, so the
# official linux release tarball is pinned here by version AND sha256. The
# binary is self-contained (SQLite driver included); the image only adds
# ca-certificates for federation over HTTPS.
FROM debian:trixie-slim

ARG WF_VERSION=0.17.2
ARG WF_SHA256=332efcf09236a8ca5ffd91379c00d96a6f59ac52812d792cfcf6ee49a67dd3d9

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/wf.tgz \
      "https://github.com/writefreely/writefreely/releases/download/v${WF_VERSION}/writefreely_${WF_VERSION}_linux_amd64.tar.gz" \
 && echo "${WF_SHA256}  /tmp/wf.tgz" | sha256sum -c - \
 && mkdir -p /opt/writefreely \
 && tar -xzf /tmp/wf.tgz -C /opt/writefreely --strip-components=1 \
 && rm /tmp/wf.tgz

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]

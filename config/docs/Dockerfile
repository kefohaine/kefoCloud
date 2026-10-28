# Builder image for the /docs site. Zensical is a Python package and there is
# no official container, so it is pinned here and built once (`make docs-build`
# rebuilds only when this file or the pin changes).
FROM python:3.12-slim

ARG ZENSICAL_VERSION=0.0.73
RUN pip install --no-cache-dir "zensical==${ZENSICAL_VERSION}"

WORKDIR /work

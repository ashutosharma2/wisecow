# syntax=docker/dockerfile:1
#
# Wisecow: a tiny HTTP server built from bash + netcat that serves
# `fortune | cowsay` on port 4499.
#
# Base image is pinned by digest for reproducible builds; Dependabot
# keeps the digest current (see .github/dependabot.yml).
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

LABEL org.opencontainers.image.title="wisecow" \
      org.opencontainers.image.description="Cow wisdom web server (fortune + cowsay over netcat)" \
      org.opencontainers.image.licenses="Apache-2.0"

# Runtime dependencies:
#   fortune-mod + fortunes-min  -> `fortune` and a fortune database
#   cowsay                      -> `cowsay` (perl script)
#   netcat-openbsd              -> `nc -lN` used by wisecow.sh (-N is OpenBSD-only)
#   tini                        -> minimal init: reaps zombies, forwards SIGTERM
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        fortune-mod fortunes-min cowsay netcat-openbsd tini \
 && rm -rf /var/lib/apt/lists/*

# Debian installs fortune and cowsay under /usr/games, which is not on PATH.
ENV PATH="/usr/games:${PATH}"

# Unprivileged user with a fixed UID so Kubernetes can enforce runAsNonRoot.
RUN groupadd --system --gid 10001 wisecow \
 && useradd --system --uid 10001 --gid wisecow --no-create-home \
        --shell /usr/sbin/nologin wisecow

# The app is read-only; the working directory only holds the named pipe
# ("response") that wisecow.sh creates at startup, so it must be writable.
COPY --chmod=0555 wisecow.sh /app/wisecow.sh
RUN mkdir -p /app/run && chown wisecow:wisecow /app/run
WORKDIR /app/run

USER 10001:10001
EXPOSE 4499

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/wisecow.sh"]

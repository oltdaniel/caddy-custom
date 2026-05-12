# Modeled on caddyserver/caddy-docker:2.11/alpine, but the binary is supplied
# from a local xcaddy build instead of being downloaded from a release.
#
# Build context layout expected by this Dockerfile:
#   binaries/<platform>/caddy        e.g. binaries/amd64/caddy, binaries/arm-v7/caddy
#   dist/caddy-dist/config/Caddyfile
#   dist/caddy-dist/welcome/index.html
#
# When invoked through `docker buildx build --platform=...`, BuildKit sets
# TARGETARCH and TARGETVARIANT for each target platform; we look up the
# matching pre-built binary by joining them.

ARG BASE_IMAGE=alpine:3.23
FROM ${BASE_IMAGE}

ARG TARGETARCH
ARG TARGETVARIANT
ARG CADDY_VERSION=unknown

RUN apk add --no-cache \
    ca-certificates \
    libcap \
    mailcap

RUN set -eux; \
    mkdir -p /config/caddy /data/caddy /etc/caddy /usr/share/caddy; \
    chmod 1777 /config/caddy /data/caddy

# Copy the platform-specific binary. The directory naming matches what
# build.sh writes: arm/v7 -> "arm-v7", arm/v6 -> "arm-v6", everything else
# is just TARGETARCH (e.g. "amd64", "arm64", "ppc64le").
COPY binaries/ /tmp/binaries/
RUN set -eux; \
    if [ -n "${TARGETVARIANT}" ]; then \
        platform_dir="${TARGETARCH}-${TARGETVARIANT}"; \
    else \
        platform_dir="${TARGETARCH}"; \
    fi; \
    cp "/tmp/binaries/${platform_dir}/caddy" /usr/bin/caddy; \
    rm -rf /tmp/binaries; \
    chmod 0755 /usr/bin/caddy; \
    setcap cap_net_bind_service=+ep /usr/bin/caddy; \
    /usr/bin/caddy version

COPY dist/caddy-dist/config/Caddyfile /etc/caddy/Caddyfile
COPY dist/caddy-dist/welcome/index.html /usr/share/caddy/index.html

ENV XDG_CONFIG_HOME=/config
ENV XDG_DATA_HOME=/data

LABEL org.opencontainers.image.title="Caddy (custom build)"
LABEL org.opencontainers.image.description="Custom xcaddy-built Caddy with locally selected plugins"
LABEL org.opencontainers.image.url="https://caddyserver.com"
LABEL org.opencontainers.image.licenses="Apache-2.0"

EXPOSE 80
EXPOSE 443
EXPOSE 443/udp
EXPOSE 2019

WORKDIR /srv
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]

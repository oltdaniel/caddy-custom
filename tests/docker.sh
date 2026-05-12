#!/usr/bin/env bash
# tests/docker.sh — smoke + structural test for the built container image.
#
# Looks up the image in the local daemon (default tag: caddy-custom:latest;
# override with $TEST_DOCKER_IMAGE=name:tag). Checks:
#   - container starts on the image's default CMD
#   - `caddy version` runs
#   - GET / returns the welcome page
#   - /usr/bin/caddy, /etc/caddy/Caddyfile, /usr/share/caddy/index.html exist
#
# Container runtime: docker or podman (auto-detected; honours $CONTAINER_RUNTIME).

set -euo pipefail

TEST_TAG=docker
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE="${TEST_DOCKER_IMAGE:-caddy-custom:latest}"

detect_runtime

"${RUNTIME}" image inspect "${IMAGE}" >/dev/null 2>&1 \
  || fail "image ${IMAGE} not found locally (run ./build.sh docker, or set TEST_DOCKER_IMAGE)"

CONTAINER="caddy-test-docker-$$"
trap 'cleanup_container "${CONTAINER}"' EXIT

log "runtime=${RUNTIME} image=${IMAGE}"
"${RUNTIME}" run -d --name "${CONTAINER}" "${IMAGE}" >/dev/null

for path in /usr/bin/caddy /etc/caddy/Caddyfile /usr/share/caddy/index.html; do
  "${RUNTIME}" exec "${CONTAINER}" test -e "${path}" \
    || fail "expected path missing in image: ${path}"
done
pass "image contains /usr/bin/caddy, /etc/caddy/Caddyfile, /usr/share/caddy/index.html"

assert_caddy_version "${CONTAINER}"
wait_http_ready "${CONTAINER}"
assert_welcome "${CONTAINER}"

log "docker test PASSED"

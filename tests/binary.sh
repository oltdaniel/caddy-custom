#!/usr/bin/env bash
# tests/binary.sh — smoke + structural test for out/binaries/<host-arch>/caddy.
#
# Runs the binary inside a throw-away alpine container so the host's filesystem
# is untouched. Checks:
#   - `caddy version` returns non-empty output
#   - the bundled dist/caddy-dist/config/Caddyfile validates
#   - caddy serves the welcome page on :80
#
# Container runtime: docker or podman (auto-detected; honours $CONTAINER_RUNTIME).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TAG=binary
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_IMAGE="${TEST_BASE_IMAGE:-alpine:3.23}"

detect_runtime
ARCH="$(host_arch_go)"

BIN="${ROOT_DIR}/out/binaries/${ARCH}/caddy"
CFG="${ROOT_DIR}/dist/caddy-dist/config/Caddyfile"
WELCOME="${ROOT_DIR}/dist/caddy-dist/welcome/index.html"
[[ -x "${BIN}" ]]     || fail "binary missing: ${BIN} (run ./build.sh binary)"
[[ -f "${CFG}" ]]     || fail "Caddyfile missing: ${CFG}"
[[ -f "${WELCOME}" ]] || fail "welcome page missing: ${WELCOME}"

CONTAINER="caddy-test-binary-$$"
trap 'cleanup_container "${CONTAINER}"' EXIT

log "runtime=${RUNTIME} arch=${ARCH} base=${TEST_IMAGE}"
log "starting container with binary mounted (caddy run in foreground)"
"${RUNTIME}" run -d --name "${CONTAINER}" \
  -v "${BIN}:/usr/bin/caddy:ro" \
  -v "${CFG}:/etc/caddy/Caddyfile:ro" \
  -v "${WELCOME}:/usr/share/caddy/index.html:ro" \
  "${TEST_IMAGE}" \
  caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

assert_caddy_version "${CONTAINER}"

"${RUNTIME}" exec "${CONTAINER}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
  || fail "caddy validate failed on bundled Caddyfile"
pass "bundled Caddyfile validates"

wait_http_ready "${CONTAINER}"
assert_welcome "${CONTAINER}"

log "binary test PASSED"

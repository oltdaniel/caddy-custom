#!/usr/bin/env bash
# tests/deb.sh — smoke + structural test for the built .deb package.
#
# Installs the package into a throw-away debian container (no host pollution),
# then checks:
#   - apt-get install succeeds (postinstall scripts run cleanly without systemd)
#   - caddy user/group were created
#   - all expected files landed (binary, Caddyfile, systemd units, sysusers, welcome)
#   - `caddy version` returns non-empty output
#   - caddy run in foreground serves the welcome page on :80
#
# Container runtime: docker or podman (auto-detected; honours $CONTAINER_RUNTIME).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TAG=deb
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_IMAGE="${TEST_BASE_IMAGE:-debian:stable-slim}"

detect_runtime
DEB_ARCH="$(host_arch_go)"

# nfpm emits e.g. caddy_2.11.2-1_amd64.deb. Pick the newest matching.
DEB="$(ls -1t "${ROOT_DIR}/out/packages/"caddy_*_"${DEB_ARCH}".deb 2>/dev/null | head -n1 || true)"
[[ -n "${DEB}" && -f "${DEB}" ]] \
  || fail "no .deb for ${DEB_ARCH} in out/packages (run ./build.sh deb)"

CONTAINER="caddy-test-deb-$$"
trap 'cleanup_container "${CONTAINER}"' EXIT

log "runtime=${RUNTIME} arch=${DEB_ARCH} base=${TEST_IMAGE} deb=$(basename "${DEB}")"
"${RUNTIME}" run -d --name "${CONTAINER}" \
  -v "${DEB}:/tmp/caddy.deb:ro" \
  "${TEST_IMAGE}" \
  sleep 600 >/dev/null

# apt-get install resolves dependencies (libc6 etc.) and runs the postinst hooks.
# wget comes along so we can curl from inside the container — debian:*-slim
# ships with neither curl nor wget.
"${RUNTIME}" exec "${CONTAINER}" sh -eu -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -yqq wget /tmp/caddy.deb
' >/dev/null 2>&1 || fail "apt-get install failed"
pass "package installed via apt-get"

"${RUNTIME}" exec "${CONTAINER}" id caddy >/dev/null \
  || fail "user 'caddy' was not created by postinstall"
"${RUNTIME}" exec "${CONTAINER}" getent group caddy >/dev/null \
  || fail "group 'caddy' was not created by postinstall"
pass "caddy user + group created"

for path in /usr/bin/caddy \
            /etc/caddy/Caddyfile \
            /lib/systemd/system/caddy.service \
            /lib/systemd/system/caddy-api.service \
            /usr/lib/sysusers.d/caddy.conf \
            /usr/share/caddy/index.html; do
  "${RUNTIME}" exec "${CONTAINER}" test -e "${path}" || fail "missing path: ${path}"
done
pass "all expected paths present"

assert_caddy_version "${CONTAINER}"

log "starting caddy in background"
"${RUNTIME}" exec -d "${CONTAINER}" caddy run --config /etc/caddy/Caddyfile --adapter caddyfile

wait_http_ready "${CONTAINER}"
assert_welcome "${CONTAINER}"

log "deb test PASSED"

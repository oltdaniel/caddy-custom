#!/usr/bin/env bash
# tests/apk.sh — smoke + structural test for the built .apk package.
#
# Installs the package into a throw-away alpine container (no host pollution),
# then checks:
#   - apk add succeeds (pre-install hook creates caddy user/group)
#   - caddy user/group exist
#   - all expected files landed (binary, Caddyfile, OpenRC init script, welcome)
#   - `caddy version` returns non-empty output
#   - caddy run in foreground serves the welcome page on :80
#
# Container runtime: docker or podman (auto-detected; honours $CONTAINER_RUNTIME).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TAG=apk
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_IMAGE="${TEST_BASE_IMAGE:-alpine:3.23}"

detect_runtime
APK_ARCH="$(host_arch_apk)"

# nfpm emits e.g. caddy_2.11.2-r1_x86_64.apk. Pick the newest matching.
APK="$(ls -1t "${ROOT_DIR}/out/packages/"caddy_*_"${APK_ARCH}".apk 2>/dev/null | head -n1 || true)"
[[ -n "${APK}" && -f "${APK}" ]] \
  || fail "no .apk for ${APK_ARCH} in out/packages (run ./build.sh apk)"

CONTAINER="caddy-test-apk-$$"
trap 'cleanup_container "${CONTAINER}"' EXIT

log "runtime=${RUNTIME} arch=${APK_ARCH} base=${TEST_IMAGE} apk=$(basename "${APK}")"
"${RUNTIME}" run -d --name "${CONTAINER}" \
  -v "${APK}:/tmp/caddy.apk:ro" \
  "${TEST_IMAGE}" \
  sleep 600 >/dev/null

# --allow-untrusted: the local .apk is unsigned. Real deployments install from
# a signed repo; here we just want to verify the package contents are sane.
"${RUNTIME}" exec "${CONTAINER}" apk add --no-cache --allow-untrusted /tmp/caddy.apk >/dev/null 2>&1 \
  || fail "apk add failed"
pass "package installed via apk"

"${RUNTIME}" exec "${CONTAINER}" id caddy >/dev/null \
  || fail "user 'caddy' was not created by pre-install"
"${RUNTIME}" exec "${CONTAINER}" getent group caddy >/dev/null \
  || fail "group 'caddy' was not created by pre-install"
pass "caddy user + group created"

for path in /usr/bin/caddy \
            /etc/caddy/Caddyfile \
            /etc/init.d/caddy \
            /usr/share/caddy/index.html; do
  "${RUNTIME}" exec "${CONTAINER}" test -e "${path}" || fail "missing path: ${path}"
done
pass "all expected paths present"

assert_caddy_version "${CONTAINER}"

log "starting caddy in background"
"${RUNTIME}" exec -d "${CONTAINER}" caddy run --config /etc/caddy/Caddyfile --adapter caddyfile

wait_http_ready "${CONTAINER}"
assert_welcome "${CONTAINER}"

log "apk test PASSED"

# tests/lib.sh — common helpers sourced by tests/*.sh. Not directly executable.
#
# Callers should set TEST_TAG (e.g. "binary", "deb") before sourcing so log
# lines get a useful prefix. Functions that need the container runtime read
# the RUNTIME variable that detect_runtime sets.

: "${TEST_TAG:=test}"

log()  { printf '\033[1;34m[test:%s]\033[0m %s\n' "${TEST_TAG}" "$*" >&2; }
pass() { printf '\033[1;32m  ok\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m  fail\033[0m %s\n' "$*" >&2; exit 1; }

# detect_runtime picks docker or podman (honours $CONTAINER_RUNTIME).
# Sets the global RUNTIME on success; fails the test otherwise.
detect_runtime() {
  RUNTIME="${CONTAINER_RUNTIME:-}"
  if [[ -n "${RUNTIME}" ]]; then return 0; fi
  if command -v docker >/dev/null 2>&1; then RUNTIME=docker
  elif command -v podman >/dev/null 2>&1; then RUNTIME=podman
  else fail "neither docker nor podman is available (set CONTAINER_RUNTIME to override)"
  fi
}

# host_arch_go emits the Go-style host arch (amd64/arm64) used in nfpm deb
# names, build.yaml architectures[].name, and out/binaries/<arch>/.
host_arch_go() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) fail "unsupported host arch $(uname -m)" ;;
  esac
}

# host_arch_apk emits the apk-style host arch (x86_64/aarch64) used in nfpm
# apk file names.
host_arch_apk() {
  case "$(uname -m)" in
    x86_64|amd64)  echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) fail "unsupported host arch $(uname -m)" ;;
  esac
}

# cleanup_container removes the named container; intended for use in EXIT traps.
cleanup_container() { "${RUNTIME}" rm -f "$1" >/dev/null 2>&1 || true; }

# wait_http_ready <container> — polls wget against http://localhost:80/ inside
# <container>, up to ~10s. Fails the test on timeout.
wait_http_ready() {
  local container="$1"
  for _ in $(seq 1 20); do
    if "${RUNTIME}" exec "${container}" wget -qO- http://localhost:80/ >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  fail "caddy did not start serving on :80 within 10s"
}

# assert_caddy_version <container> — runs `caddy version` and asserts non-empty
# output; prints the version line on success.
assert_caddy_version() {
  local container="$1" ver_out
  ver_out="$("${RUNTIME}" exec "${container}" caddy version 2>&1 | head -1)" \
    || fail "caddy version failed: ${ver_out}"
  [[ -n "${ver_out}" ]] || fail "caddy version produced no output"
  pass "caddy version → ${ver_out}"
}

# assert_welcome <container> — fetches GET / and asserts the welcome page
# (looks for the "Congratulations" string from caddy-dist's index.html).
assert_welcome() {
  local container="$1" body
  body="$("${RUNTIME}" exec "${container}" wget -qO- http://localhost:80/)"
  echo "${body}" | grep -q "Congratulations" \
    || fail "GET / did not return the welcome page (body=${#body} bytes)"
  pass "GET / serves welcome page (${#body} bytes)"
}

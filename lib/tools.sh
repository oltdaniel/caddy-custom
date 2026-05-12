#!/usr/bin/env bash
# lib/tools.sh — bootstrap and verify build-time tools (yq, nfpm, xcaddy).
# Logic only. Pinned versions + SHA256 live in lib/tools.pins.sh so the
# template-sync workflow can replace this file without touching pins.
# Sourced by lib/common.sh; do not use directly.

# shellcheck source=./tools.pins.sh
source "${ROOT_DIR}/lib/tools.pins.sh"

# ensure_yq downloads and verifies yq (mikefarah/yq v4).
ensure_yq() {
  if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q 'mikefarah'; then
    YQ="$(command -v yq)"
    return
  fi
  if [[ -x "${TOOLS_DIR}/yq" ]]; then
    YQ="${TOOLS_DIR}/yq"
    return
  fi

  local arch ver expected got
  arch="$(host_arch_for_tool)"
  ver="${TOOLS_PINS[yq_version]}"
  expected="${TOOLS_PINS[yq_sha256_${arch}]}"
  [[ -n "${ver}" ]]      || die "yq version missing in lib/tools.pins.sh"
  [[ -n "${expected}" ]] || die "yq sha256 for ${arch} missing in lib/tools.pins.sh"

  log "downloading yq v${ver} (${arch}) into ${TOOLS_DIR}"
  curl -fsSL -o "${TOOLS_DIR}/yq" \
    "https://github.com/mikefarah/yq/releases/download/v${ver}/yq_linux_${arch}"
  got="$(sha256sum "${TOOLS_DIR}/yq" | awk '{print $1}')"
  [[ "${got}" == "${expected}" ]] \
    || { rm -f "${TOOLS_DIR}/yq"; die "yq sha256 mismatch: expected ${expected}, got ${got}"; }
  chmod +x "${TOOLS_DIR}/yq"
  YQ="${TOOLS_DIR}/yq"
}

# ensure_nfpm downloads and verifies nfpm.
ensure_nfpm() {
  if command -v nfpm >/dev/null 2>&1; then
    NFPM="$(command -v nfpm)"
    return
  fi
  if [[ -x "${TOOLS_DIR}/nfpm" ]]; then
    NFPM="${TOOLS_DIR}/nfpm"
    return
  fi

  local arch ver expected got nfpm_arch tarball
  arch="$(host_arch_for_tool)"
  ver="${TOOLS_PINS[nfpm_version]}"
  expected="${TOOLS_PINS[nfpm_sha256_${arch}]}"
  [[ -n "${ver}" ]]      || die "nfpm version missing in lib/tools.pins.sh"
  [[ -n "${expected}" ]] || die "nfpm sha256 for ${arch} missing in lib/tools.pins.sh"

  case "${arch}" in
    amd64) nfpm_arch=x86_64 ;;
    arm64) nfpm_arch=arm64 ;;
    *)     die "no nfpm release for ${arch}" ;;
  esac
  tarball="nfpm_${ver}_Linux_${nfpm_arch}.tar.gz"

  log "downloading nfpm v${ver} (${arch}) into ${TOOLS_DIR}"
  curl -fsSL -o "${TOOLS_DIR}/nfpm.tar.gz" \
    "https://github.com/goreleaser/nfpm/releases/download/v${ver}/${tarball}"
  got="$(sha256sum "${TOOLS_DIR}/nfpm.tar.gz" | awk '{print $1}')"
  [[ "${got}" == "${expected}" ]] \
    || { rm -f "${TOOLS_DIR}/nfpm.tar.gz"; die "nfpm sha256 mismatch: expected ${expected}, got ${got}"; }
  tar -xzf "${TOOLS_DIR}/nfpm.tar.gz" -C "${TOOLS_DIR}" nfpm
  rm -f "${TOOLS_DIR}/nfpm.tar.gz"
  chmod +x "${TOOLS_DIR}/nfpm"
  NFPM="${TOOLS_DIR}/nfpm"
}

# ensure_xcaddy downloads and verifies the xcaddy release tarball.
# Building Caddy still requires the Go toolchain on PATH (xcaddy invokes it),
# but installing xcaddy itself no longer does — same pattern as yq/nfpm.
ensure_xcaddy() {
  if command -v xcaddy >/dev/null 2>&1; then
    XCADDY="$(command -v xcaddy)"
    return
  fi
  if [[ -x "${TOOLS_DIR}/xcaddy" ]]; then
    XCADDY="${TOOLS_DIR}/xcaddy"
    return
  fi

  local arch ver expected got tarball
  arch="$(host_arch_for_tool)"
  ver="${TOOLS_PINS[xcaddy_version]}"
  expected="${TOOLS_PINS[xcaddy_sha256_${arch}]}"
  [[ -n "${ver}" ]]      || die "xcaddy version missing in lib/tools.pins.sh"
  [[ -n "${expected}" ]] || die "xcaddy sha256 for ${arch} missing in lib/tools.pins.sh"

  tarball="xcaddy_${ver}_linux_${arch}.tar.gz"

  log "downloading xcaddy v${ver} (${arch}) into ${TOOLS_DIR}"
  curl -fsSL -o "${TOOLS_DIR}/xcaddy.tar.gz" \
    "https://github.com/caddyserver/xcaddy/releases/download/v${ver}/${tarball}"
  got="$(sha256sum "${TOOLS_DIR}/xcaddy.tar.gz" | awk '{print $1}')"
  [[ "${got}" == "${expected}" ]] \
    || { rm -f "${TOOLS_DIR}/xcaddy.tar.gz"; die "xcaddy sha256 mismatch: expected ${expected}, got ${got}"; }
  tar -xzf "${TOOLS_DIR}/xcaddy.tar.gz" -C "${TOOLS_DIR}" xcaddy
  rm -f "${TOOLS_DIR}/xcaddy.tar.gz"
  chmod +x "${TOOLS_DIR}/xcaddy"
  XCADDY="${TOOLS_DIR}/xcaddy"
}

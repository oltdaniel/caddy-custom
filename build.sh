#!/usr/bin/env bash
# Top-level entry point for building custom Caddy artifacts.
#
# Usage:
#   ./build.sh [target ...]
#
# Targets:
#   tools   — download yq/nfpm/xcaddy into ./tools/
#   binary  — build per-arch xcaddy binaries (and tarballs) into ./out/
#   deb     — build .deb packages (requires `binary`)
#   apk     — build .apk packages (requires `binary`)
#   docker  — build container image(s) (requires `binary`)
#   all     — everything that is enabled in build.yaml.formats (default)
#   clean   — remove ./out/

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR

# shellcheck source=lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=lib/build-binary.sh
source "${ROOT_DIR}/lib/build-binary.sh"
# shellcheck source=lib/build-packages.sh
source "${ROOT_DIR}/lib/build-packages.sh"
# shellcheck source=lib/build-docker.sh
source "${ROOT_DIR}/lib/build-docker.sh"

run_tools() {
  ensure_yq
  ensure_nfpm
  ensure_xcaddy
  log "tools ready in ${TOOLS_DIR}"
}

run_clean() {
  rm -rf "${OUT_DIR}"
  log "removed ${OUT_DIR}"
}

run_all() {
  cfg_bool '.formats.binary' && build_binaries
  cfg_bool '.formats.deb'    && build_deb
  cfg_bool '.formats.apk'    && build_apk
  cfg_bool '.formats.docker' && build_docker
}

main() {
  local targets=("$@")
  [[ ${#targets[@]} -eq 0 ]] && targets=(all)

  for t in "${targets[@]}"; do
    case "${t}" in
      tools)  run_tools ;;
      binary) build_binaries ;;
      deb)    build_deb ;;
      apk)    build_apk ;;
      docker) build_docker ;;
      all)    run_all ;;
      clean)  run_clean ;;
      -h|--help|help)
        sed -n '2,16p' "$0"
        exit 0
        ;;
      *) die "unknown target: ${t}" ;;
    esac
  done
}

main "$@"

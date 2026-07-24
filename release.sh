#!/usr/bin/env bash
# Upload built artifacts to a package backend (Forgejo or GitHub).
#
# Usage (in CI, the runner injects the host + owner/repo env vars):
#   FORGEJO_TOKEN=... ./release.sh [target ...]                 # provider=forgejo (default)
#   GITHUB_TOKEN=... RELEASE_PROVIDER=github ./release.sh [...] # provider=github
#
# For local runs, export the same env vars manually:
#   FORGEJO_SERVER_URL=https://forgejo.example.com \
#   FORGEJO_REPOSITORY=owner/repo \
#   FORGEJO_TOKEN=... ./release.sh [target ...]
#   GITHUB_REPOSITORY=owner/repo \
#   GITHUB_TOKEN=... RELEASE_PROVIDER=github ./release.sh [...]
#
# The active provider is selected (in order):
#   1. RELEASE_PROVIDER env var
#   2. .release.provider in build.yaml
#   3. "forgejo" (fallback)
#
# Targets (default: all):
#   binary  — per-arch tarballs from ./out/
#   deb     — .deb files from ./out/packages/
#   apk     — .apk files from ./out/packages/
#   docker  — multi-arch container manifest
#   all     — every target above whose artifacts exist
#   check   — print "true" / "false" depending on whether the current
#             pkg_version is already published; useful for gating CI rebuilds.
#
# Provider notes:
#   forgejo — uploads to the matching Forgejo registries (generic, debian,
#             alpine, container). Requires FORGEJO_TOKEN with write:package.
#   github  — attaches binary/deb/apk to a GitHub Release auto-tagged
#             v<pkg_version>; pushes the container to ghcr.io. Requires
#             GITHUB_TOKEN with `contents: write` and `packages: write`.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR

# shellcheck source=lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

provider="${RELEASE_PROVIDER:-$(cfg '.release.provider')}"
[[ -z "${provider}" ]] && provider="forgejo"

case "${provider}" in
  forgejo)
    # shellcheck source=lib/release-forgejo.sh
    source "${ROOT_DIR}/lib/release-forgejo.sh"
    ;;
  github)
    # shellcheck source=lib/release-github.sh
    source "${ROOT_DIR}/lib/release-github.sh"
    ;;
  *)
    die "unknown release provider: ${provider} (expected: forgejo, github)"
    ;;
esac

run_all() {
  cfg_bool '.formats.binary' && upload_binary
  cfg_bool '.formats.deb'    && upload_deb
  cfg_bool '.formats.apk'    && upload_apk
  cfg_bool '.formats.docker' && push_docker
  return 0
}

main() {
  local targets=("$@")
  [[ ${#targets[@]} -eq 0 ]] && targets=(all)

  log "release provider: ${provider}"

  for t in "${targets[@]}"; do
    case "${t}" in
      binary) upload_binary ;;
      deb)    upload_deb ;;
      apk)    upload_apk ;;
      docker) push_docker ;;
      all)    run_all ;;
      check)  check_published ;;
      -h|--help|help)
        sed -n '2,27p' "$0"
        exit 0
        ;;
      *) die "unknown target: ${t}" ;;
    esac
  done
}

main "$@"

# Common helpers sourced by every lib/*.sh script.
# Expects ROOT_DIR to be set to the repo root by the caller.

set -euo pipefail

: "${ROOT_DIR:?ROOT_DIR must be set before sourcing common.sh}"
: "${CONFIG_FILE:=${ROOT_DIR}/build.yaml}"

OUT_DIR="${ROOT_DIR}/out"
BIN_DIR="${OUT_DIR}/binaries"
PKG_DIR="${OUT_DIR}/packages"
TOOLS_DIR="${ROOT_DIR}/tools"

mkdir -p "${OUT_DIR}" "${BIN_DIR}" "${PKG_DIR}" "${TOOLS_DIR}"

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# host_arch_for_tool emits the arch suffix used by released binaries (yq, nfpm,
# xcaddy all follow the same pattern).
host_arch_for_tool() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l) echo arm ;;
    *) die "unsupported host arch: $(uname -m)" ;;
  esac
}

# Source tool bootstrap functions (ensure_yq, ensure_nfpm, ensure_xcaddy)
# shellcheck source=./tools.sh
source "${ROOT_DIR}/lib/tools.sh"

# cfg reads a value from build.yaml. Empty string if the key is missing/null.
cfg() {
  ensure_yq
  local val
  val="$("${YQ}" -r "$1 // \"\"" "${CONFIG_FILE}")"
  printf '%s' "${val}"
}

# cfg_list emits one element per line for an array key.
cfg_list() {
  ensure_yq
  "${YQ}" -r "$1 // [] | .[]" "${CONFIG_FILE}"
}

# cfg_bool returns 0/1 exit status for a boolean key (default false).
cfg_bool() {
  ensure_yq
  local val
  val="$("${YQ}" -r "$1 // false" "${CONFIG_FILE}")"
  [[ "${val}" == "true" ]]
}

# caddy_version returns the *upstream* Caddy version to build against,
# resolving the special value "latest" (or empty) to the current release
# tag from the caddyserver/caddy GitHub repo. A leading 'v' is stripped
# from explicit values so callers always get a clean semver string.
#
# Branches, commit SHAs, and "nightly" are rejected — pkg_version needs a
# real release tag to fold into deb/apk/Docker-safe versions. Pin a
# specific version (e.g. "2.11.2") if you need that.
#
# The resolved value is cached for the lifetime of the script invocation.
caddy_version() {
  if [[ -n "${_CADDY_VERSION_CACHE:-}" ]]; then
    printf '%s' "${_CADDY_VERSION_CACHE}"
    return
  fi
  ensure_yq
  local v
  v="$(cfg '.caddy.version')"
  case "${v}" in
    ""|latest)
      log "resolving latest Caddy release from caddyserver/caddy"
      local tmp; tmp="$(mktemp)"
      curl --fail-with-body -sS -o "${tmp}" \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/caddyserver/caddy/releases/latest \
        || die "failed to fetch caddyserver/caddy latest release"
      v="$("${YQ}" -p json -o yaml -r '.tag_name // ""' "${tmp}")"
      rm -f "${tmp}"
      [[ -n "${v}" ]] || die "could not parse latest tag from GitHub API response"
      v="${v#v}"
      log "  -> ${v}"
      ;;
    v*)
      v="${v#v}"
      ;;
  esac
  if ! [[ "${v}" =~ ^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.+-]+)?$ ]]; then
    die "caddy.version: '${v}' is not a release version. Branches, commit SHAs, and 'nightly' are unsupported — pkg_version requires a semver tag. Use 'latest' or an explicit version like '2.11.2'."
  fi
  _CADDY_VERSION_CACHE="${v}"
  printf '%s' "${v}"
}

# pkg_version emits the *package* version: caddy.version, optionally suffixed
# with .<suffix> where suffix comes from caddy.version_suffix.
#   ""       — no suffix; pkg_version equals caddy.version
#   "auto"   — <YYYYMMDD>.<commit-count> (today + git rev-list --count HEAD).
#              Same commit produces the same version, so release.sh check can
#              short-circuit rebuilds. Falls back to <date>.0 when not in a git
#              repo or HEAD is unreachable.
#   <other>  — used verbatim (digits/letters/dots only).
# The suffix is folded into the upstream version (not the release/pkgrel)
# because apk requires release to be digits only — appending another dotted
# numeric segment is the only form valid in deb, apk, and rpm simultaneously.
pkg_version() {
  local base suffix
  base="$(caddy_version)"
  suffix="$(cfg '.caddy.version_suffix')"
  if [[ "${suffix}" == "auto" ]]; then
    local date count
    date="$(date -u +%Y%m%d)"
    if count="$(git -C "${ROOT_DIR}" rev-list --count HEAD 2>/dev/null)" && [[ -n "${count}" ]]; then
      suffix="${date}.${count}"
    else
      warn "auto suffix: git commit count unavailable — using ${date}.0 (rebuilds will collide)"
      suffix="${date}.0"
    fi
  fi
  if [[ -n "${suffix}" ]]; then
    printf '%s.%s' "${base}" "${suffix}"
  else
    printf '%s' "${base}"
  fi
}

# arch_field reads <field> for the architecture entry whose .name == <name>.
arch_field() {
  ensure_yq
  local name="$1" field="$2"
  "${YQ}" -r ".architectures[] | select(.name == \"${name}\") | .${field} // \"\"" \
    "${CONFIG_FILE}"
}

# arch_names lists all configured architecture names (one per line).
arch_names() {
  ensure_yq
  "${YQ}" -r '.architectures[].name' "${CONFIG_FILE}"
}

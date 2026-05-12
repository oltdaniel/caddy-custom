#!/usr/bin/env bash
# check-updates.sh — detect and optionally apply pin bumps for caddy-packages.
# Compares versions against upstream (proxy.golang.org, GitHub releases) and
# syncs files under dist/ from caddyserver/dist and alpine/aports.
# Exit code: 0 if all current, 1 if any drift detected.
# Modes: default (markdown report to stdout), --json (JSON), --apply (update files + report).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
ensure_yq

mode="report"
case "${1:-}" in
  --apply) mode="apply" ;;
  --json)  mode="json" ;;
  "")      ;;
  *)       die "usage: $0 [--apply|--json]" ;;
esac

# --- helpers ---
go_proxy_latest() {
  local module="$1"
  curl -fsSL "https://proxy.golang.org/${module}/@latest" | "${YQ}" -p=json -r '.Version // ""'
}

go_proxy_latest_commit() {
  local module="$1"
  curl -fsSL "https://proxy.golang.org/${module}/@latest" | "${YQ}" -p=json -r '.Origin.Hash // ""'
}

gh_release_tag() {
  local owner_repo="$1"
  curl -fsSL "https://api.github.com/repos/${owner_repo}/releases/latest" \
    -H 'Accept: application/vnd.github+json' | "${YQ}" -p=json -r '.tag_name // ""'
}

gh_release_checksums() {
  local owner_repo="$1" tag="$2"
  curl -fsSL "https://github.com/${owner_repo}/releases/download/${tag}/checksums.txt"
}

extract_sha256() {
  local filename="$1"
  awk -v fname="${filename}" '$2 == fname { print $1; exit }' || echo ""
}

is_commit_sha() {
  local ref="$1"
  [[ "$ref" =~ ^[0-9a-f]{40}$ ]]
}

format_timestamp() {
  date -u +"%Y-%m-%d %H:%M UTC"
}

# gh_raw_base maps a https://github.com/<o>/<r> URL to the matching
# raw.githubusercontent.com base. Used as "<base>/<commit>/<path>".
gh_raw_base() { printf '%s' "${1/github.com/raw.githubusercontent.com}"; }

# gh_api_base maps a https://github.com/<o>/<r> URL to the matching
# api.github.com/repos base.
gh_api_base() { printf '%s' "${1/github.com/api.github.com/repos}"; }

# gh_latest_commit returns the most recent commit SHA on <branch> of <api_base>,
# optionally filtered to commits that touched <path>. The /commits list
# endpoint handles both cases uniformly (single-item array).
gh_latest_commit() {
  local api_base="$1" branch="$2" path="${3:-}"
  local url="${api_base}/commits?per_page=1&sha=${branch}"
  [[ -n "${path}" ]] && url="${url}&path=${path}"
  curl -fsSL -H 'Accept: application/vnd.github+json' "${url}" \
    | "${YQ}" -p=json -r '.[0].sha // ""'
}

# check_dist_source diffs each file under <local_root> against the same path on
# upstream@<upstream_commit>, recording drift in the named pending/changed
# arrays. Fetched bytes are kept in tmpfiles so apply_patches can install them
# without re-downloading.
#
#   $1 source key (used only for log/warn messages)
#   $2 local_root        absolute path, e.g. ROOT_DIR/dist/caddy-dist
#   $3 raw_url_prefix    everything before the commit SHA in the raw URL
#   $4 upstream_subpath  prefix prepended to each tracked file inside the repo
#                        (empty for caddy-dist; "community/caddy" for aports)
#   $5 upstream_commit   commit SHA to diff against
#   $6 pending_arr_name  nameref for "local_path|tmp_path" entries
#   $7 changed_arr_name  nameref for relative-path entries
check_dist_source() {
  local source_key="$1" local_root="$2" raw_prefix="$3" subpath="$4" upstream="$5"
  local -n _pending="$6" _changed="$7"
  local local_file rel remote_path tmp
  while IFS= read -r local_file; do
    rel="${local_file#${local_root}/}"
    if [[ -n "${subpath}" ]]; then
      remote_path="${subpath}/${rel}"
    else
      remote_path="${rel}"
    fi
    tmp="$(mktemp)"
    if ! curl -fsSL -o "${tmp}" "${raw_prefix}/${upstream}/${remote_path}" 2>/dev/null; then
      warn "${source_key}: could not fetch ${remote_path} @ ${upstream:0:8}"
      rm -f "${tmp}"
      continue
    fi
    if ! cmp -s "${tmp}" "${local_file}"; then
      _changed+=("${rel}")
      _pending+=("${local_file}|${tmp}")
    else
      rm -f "${tmp}"
    fi
  done < <(find "${local_root}" -type f | sort)
}

cleanup_dist_pending() {
  local entry
  for entry in "${caddy_dist_pending[@]:-}" "${aports_pending[@]:-}"; do
    [[ -z "${entry}" ]] && continue
    rm -f "${entry#*|}"
  done
}
trap cleanup_dist_pending EXIT

# --- collect updates ---
declare -a updates=()

# Caddy
log "checking Caddy..."
caddy_current="$(cfg '.caddy.version')"
caddy_latest="$(go_proxy_latest 'github.com/caddyserver/caddy/v2')"
caddy_latest="${caddy_latest#v}"
if [[ -n "${caddy_latest}" && "${caddy_current}" != "${caddy_latest}" ]]; then
  updates+=("caddy|${caddy_current}|${caddy_latest}|")
fi

# xcaddy (pinned in lib/tools.pins.sh — same flow as yq/nfpm; release tag is
# the source of truth, SHA256 is computed from the linux_{amd64,arm64}
# tarballs at apply time since upstream only publishes SHA-512).
log "checking xcaddy..."
xcaddy_current="${TOOLS_PINS[xcaddy_version]}"
xcaddy_latest_tag="$(gh_release_tag 'caddyserver/xcaddy')"
xcaddy_latest_tag="${xcaddy_latest_tag#v}"
if [[ -n "${xcaddy_latest_tag}" && "${xcaddy_current}" != "${xcaddy_latest_tag}" ]]; then
  updates+=("xcaddy|${xcaddy_current}|${xcaddy_latest_tag}|New SHA256 computed (amd64, arm64)")
fi

# Plugins
log "checking plugins..."
while IFS= read -r plugin_entry; do
  [[ -z "${plugin_entry}" ]] && continue

  plugin_module="${plugin_entry%%@*}"
  plugin_current_ref="${plugin_entry#*@}"

  if is_commit_sha "${plugin_current_ref}"; then
    # Current pin is a commit hash; check for newer commits
    plugin_latest="$(go_proxy_latest_commit "${plugin_module}")"
    if [[ -n "${plugin_latest}" && "${plugin_current_ref}" != "${plugin_latest}" ]]; then
      updates+=("${plugin_module}|@${plugin_current_ref}|@${plugin_latest}|New commits available")
    fi
  else
    # Current pin is a tag; check for newer tags
    plugin_latest="$(go_proxy_latest "${plugin_module}")"
    plugin_latest="${plugin_latest#v}"
    plugin_current_clean="${plugin_current_ref#v}"
    if [[ -n "${plugin_latest}" && "${plugin_current_clean}" != "${plugin_latest}" ]]; then
      updates+=("${plugin_module}|@${plugin_current_ref}|@v${plugin_latest}|Released")
    fi
  fi
done < <(cfg_list '.xcaddy.plugins')

# nfpm + yq are pinned in lib/tools.pins.sh (TOOLS_PINS), not build.yaml: yq
# needs to bootstrap before cfg() works, and keeping both alongside xcaddy is
# simpler than splitting the source of truth. Read the current value from the
# array directly — using cfg() returns "" for nfpm and a hardcoded literal for
# yq would silently drift from lib/tools.pins.sh.

# nfpm
log "checking nfpm..."
nfpm_current="${TOOLS_PINS[nfpm_version]}"
nfpm_latest_tag="$(gh_release_tag 'goreleaser/nfpm')"
nfpm_latest_tag="${nfpm_latest_tag#v}"
if [[ -n "${nfpm_latest_tag}" && "${nfpm_current}" != "${nfpm_latest_tag}" ]]; then
  updates+=("nfpm|${nfpm_current}|${nfpm_latest_tag}|New SHA256 fetched (amd64, arm64)")
  nfpm_checksums="$(gh_release_checksums 'goreleaser/nfpm' "v${nfpm_latest_tag}")"
fi

# yq
log "checking yq..."
yq_current="${TOOLS_PINS[yq_version]}"
yq_latest_tag="$(gh_release_tag 'mikefarah/yq')"
yq_latest_tag="${yq_latest_tag#v}"
if [[ -n "${yq_latest_tag}" && "${yq_current}" != "${yq_latest_tag}" ]]; then
  updates+=("yq|${yq_current}|${yq_latest_tag}|New SHA256 fetched (amd64, arm64)")
  yq_checksums="$(gh_release_checksums 'mikefarah/yq' "v${yq_latest_tag}")"
fi

# dist/caddy-dist
log "checking dist/caddy-dist..."
caddy_dist_repo_url="$(cfg '.dist.caddy_dist.repo_url')"
caddy_dist_branch="$(cfg '.dist.caddy_dist.branch')"
caddy_dist_pinned="$(cfg '.dist.caddy_dist.commit')"
caddy_dist_upstream="$(gh_latest_commit "$(gh_api_base "${caddy_dist_repo_url}")" "${caddy_dist_branch}")"
declare -a caddy_dist_pending=()
declare -a caddy_dist_changed=()
if [[ -n "${caddy_dist_upstream}" ]]; then
  check_dist_source "caddy-dist" \
    "${ROOT_DIR}/dist/caddy-dist" \
    "$(gh_raw_base "${caddy_dist_repo_url}")" \
    "" \
    "${caddy_dist_upstream}" \
    caddy_dist_pending caddy_dist_changed
fi
if [[ ${#caddy_dist_changed[@]} -gt 0 ]]; then
  files_csv="$(IFS=', '; printf '%s' "${caddy_dist_changed[*]}")"
  updates+=("dist/caddy-dist|${caddy_dist_pinned:0:8}|${caddy_dist_upstream:0:8}|${#caddy_dist_changed[@]} file(s): ${files_csv}")
fi

# dist/aports (path-scoped so unrelated aports commits don't bump the pin)
log "checking dist/aports..."
aports_repo_url="$(cfg '.dist.aports.repo_url')"
aports_branch="$(cfg '.dist.aports.branch')"
aports_path="$(cfg '.dist.aports.path')"
aports_pinned="$(cfg '.dist.aports.commit')"
aports_upstream="$(gh_latest_commit "$(gh_api_base "${aports_repo_url}")" "${aports_branch}" "${aports_path}")"
declare -a aports_pending=()
declare -a aports_changed=()
if [[ -n "${aports_upstream}" ]]; then
  check_dist_source "aports" \
    "${ROOT_DIR}/dist/aports" \
    "$(gh_raw_base "${aports_repo_url}")" \
    "${aports_path}" \
    "${aports_upstream}" \
    aports_pending aports_changed
fi
if [[ ${#aports_changed[@]} -gt 0 ]]; then
  files_csv="$(IFS=', '; printf '%s' "${aports_changed[*]}")"
  updates+=("dist/aports|${aports_pinned:0:8}|${aports_upstream:0:8}|${#aports_changed[@]} file(s): ${files_csv}")
fi

# --- output ---
print_markdown() {
  {
    echo "## caddy-packages auto-update report"
    echo ""
    echo "Generated: $(format_timestamp)"
    echo ""

    if [[ ${#updates[@]} -gt 0 ]]; then
      echo "### Updates available"
      echo ""
      echo "| Component | Current | Latest | Note |"
      echo "| --- | --- | --- | --- |"
      for update in "${updates[@]}"; do
        IFS='|' read -r comp curr latest note <<< "${update}"
        echo "| ${comp} | ${curr} | ${latest} | ${note} |"
      done
      echo ""
    fi

    echo "### Current"
    echo ""
    echo "- caddy ${caddy_current}"
    echo "- xcaddy ${xcaddy_current}"
    cfg_list '.xcaddy.plugins' | while read -r p; do
      [[ -z "${p}" ]] && continue
      echo "- ${p}"
    done
    echo "- yq ${yq_current}"
    echo "- nfpm ${nfpm_current}"
    echo "- dist/caddy-dist ${caddy_dist_pinned:0:8} (${caddy_dist_repo_url}@${caddy_dist_branch})"
    echo "- dist/aports ${aports_pinned:0:8} (${aports_repo_url}@${aports_branch} ${aports_path})"
  } >&1
}

print_json() {
  local json_updates="[]"
  for update in "${updates[@]}"; do
    IFS='|' read -r comp curr latest note <<< "${update}"
    json_updates="$(echo "${json_updates}" | "${YQ}" -p=json '. += [{"component": "'${comp}'", "current": "'${curr}'", "latest": "'${latest}'", "note": "'${note}'"}]')"
  done
  echo "${json_updates}" | "${YQ}" -o=json '.'
}

apply_patches() {
  local tmp_tools="${ROOT_DIR}/lib/tools.pins.sh.tmp"
  cp "${ROOT_DIR}/lib/tools.pins.sh" "${tmp_tools}"

  # Caddy
  if [[ -n "${caddy_latest}" && "${caddy_current}" != "${caddy_latest}" ]]; then
    "${YQ}" -i ".caddy.version = \"${caddy_latest}\"" "${CONFIG_FILE}"
  fi

  # Plugins: update each entry's @ref
  while IFS= read -r plugin_entry; do
    [[ -z "${plugin_entry}" ]] && continue

    plugin_module="${plugin_entry%%@*}"
    plugin_current_ref="${plugin_entry#*@}"

    if is_commit_sha "${plugin_current_ref}"; then
      plugin_latest="$(go_proxy_latest_commit "${plugin_module}")"
      if [[ -n "${plugin_latest}" && "${plugin_current_ref}" != "${plugin_latest}" ]]; then
        "${YQ}" -i "(.xcaddy.plugins[] | select(. == \"${plugin_entry}\")) = \"${plugin_module}@${plugin_latest}\"" "${CONFIG_FILE}"
      fi
    else
      plugin_latest="$(go_proxy_latest "${plugin_module}")"
      plugin_latest="${plugin_latest#v}"
      plugin_current_clean="${plugin_current_ref#v}"
      if [[ -n "${plugin_latest}" && "${plugin_current_clean}" != "${plugin_latest}" ]]; then
        "${YQ}" -i "(.xcaddy.plugins[] | select(. == \"${plugin_entry}\")) = \"${plugin_module}@v${plugin_latest}\"" "${CONFIG_FILE}"
      fi
    fi
  done < <(cfg_list '.xcaddy.plugins')

  # yq: update via sed in lib/tools.sh
  if [[ -n "${yq_latest_tag}" && "${yq_current}" != "${yq_latest_tag}" ]]; then
    # Update version
    sed -i "s/\[yq_version\]=\"${yq_current}\"/[yq_version]=\"${yq_latest_tag}\"/" "${tmp_tools}"

    # Extract per-arch SHA256
    local amd64_sha arm64_sha
    amd64_sha="$(echo "${yq_checksums}" | extract_sha256 "yq_linux_amd64")"
    arm64_sha="$(echo "${yq_checksums}" | extract_sha256 "yq_linux_arm64")"

    if [[ -n "${amd64_sha}" ]]; then
      sed -i "s/\[yq_sha256_amd64\]=\"[a-f0-9]*\"/[yq_sha256_amd64]=\"${amd64_sha}\"/" "${tmp_tools}"
    fi
    if [[ -n "${arm64_sha}" ]]; then
      sed -i "s/\[yq_sha256_arm64\]=\"[a-f0-9]*\"/[yq_sha256_arm64]=\"${arm64_sha}\"/" "${tmp_tools}"
    fi
  fi

  # xcaddy: update via sed in lib/tools.sh. SHA256 is computed locally from
  # the downloaded artifact (upstream ships SHA-512 only).
  if [[ -n "${xcaddy_latest_tag}" && "${xcaddy_current}" != "${xcaddy_latest_tag}" ]]; then
    sed -i "s/\[xcaddy_version\]=\"${xcaddy_current}\"/[xcaddy_version]=\"${xcaddy_latest_tag}\"/" "${tmp_tools}"

    local xcaddy_tmp xcaddy_arch xcaddy_sha
    xcaddy_tmp="$(mktemp)"
    for xcaddy_arch in amd64 arm64; do
      if curl -fsSL -o "${xcaddy_tmp}" \
          "https://github.com/caddyserver/xcaddy/releases/download/v${xcaddy_latest_tag}/xcaddy_${xcaddy_latest_tag}_linux_${xcaddy_arch}.tar.gz"; then
        xcaddy_sha="$(sha256sum "${xcaddy_tmp}" | awk '{print $1}')"
        sed -i "s/\[xcaddy_sha256_${xcaddy_arch}\]=\"[a-f0-9]*\"/[xcaddy_sha256_${xcaddy_arch}]=\"${xcaddy_sha}\"/" "${tmp_tools}"
      else
        warn "xcaddy: failed to fetch linux_${xcaddy_arch} tarball for v${xcaddy_latest_tag}"
      fi
    done
    rm -f "${xcaddy_tmp}"
  fi

  # nfpm: update via sed in lib/tools.sh
  if [[ -n "${nfpm_latest_tag}" && "${nfpm_current}" != "${nfpm_latest_tag}" ]]; then
    # Update version
    sed -i "s/\[nfpm_version\]=\"${nfpm_current}\"/[nfpm_version]=\"${nfpm_latest_tag}\"/" "${tmp_tools}"

    # Extract per-arch SHA256
    local amd64_sha arm64_sha
    amd64_sha="$(echo "${nfpm_checksums}" | extract_sha256 "nfpm_${nfpm_latest_tag}_Linux_x86_64.tar.gz")"
    arm64_sha="$(echo "${nfpm_checksums}" | extract_sha256 "nfpm_${nfpm_latest_tag}_Linux_arm64.tar.gz")"

    if [[ -n "${amd64_sha}" ]]; then
      sed -i "s/\[nfpm_sha256_amd64\]=\"[a-f0-9]*\"/[nfpm_sha256_amd64]=\"${amd64_sha}\"/" "${tmp_tools}"
    fi
    if [[ -n "${arm64_sha}" ]]; then
      sed -i "s/\[nfpm_sha256_arm64\]=\"[a-f0-9]*\"/[nfpm_sha256_arm64]=\"${arm64_sha}\"/" "${tmp_tools}"
    fi
  fi

  mv "${tmp_tools}" "${ROOT_DIR}/lib/tools.pins.sh"

  # dist/caddy-dist: install pending files + bump pin
  if [[ ${#caddy_dist_changed[@]} -gt 0 ]]; then
    local entry local_path tmp_path
    for entry in "${caddy_dist_pending[@]}"; do
      local_path="${entry%%|*}"; tmp_path="${entry#*|}"
      mv -f "${tmp_path}" "${local_path}"
    done
    "${YQ}" -i ".dist.caddy_dist.commit = \"${caddy_dist_upstream}\"" "${CONFIG_FILE}"
  fi

  # dist/aports: install pending files + bump pin
  if [[ ${#aports_changed[@]} -gt 0 ]]; then
    local entry local_path tmp_path
    for entry in "${aports_pending[@]}"; do
      local_path="${entry%%|*}"; tmp_path="${entry#*|}"
      mv -f "${tmp_path}" "${local_path}"
    done
    "${YQ}" -i ".dist.aports.commit = \"${aports_upstream}\"" "${CONFIG_FILE}"
  fi
}

# --- main ---
case "${mode}" in
  report)
    print_markdown
    [[ ${#updates[@]} -gt 0 ]] && exit 1 || exit 0
    ;;
  json)
    print_json
    [[ ${#updates[@]} -gt 0 ]] && exit 1 || exit 0
    ;;
  apply)
    apply_patches
    print_markdown
    [[ ${#updates[@]} -gt 0 ]] && exit 1 || exit 0
    ;;
esac

# Forgejo backend for release.sh.
#
# Each artifact is sent to two places:
#   - the matching Forgejo package registry
#       binary -> generic, deb -> debian, apk -> alpine, docker -> container
#   - a Forgejo Release tagged v<pkg_version>, with binary/deb/apk attached
#     as release assets (Docker stays in the container registry only)
#
# Mirrors the GitHub backend's release-tag flow so users get the same
# discovery surface (release page with attached assets) on both providers.
#
# FORGEJO_TOKEN scopes required:
#   write:package    — package registry uploads + container login
#   write:repository — release create / asset upload
# (read:package + read:repository are sufficient for `release.sh check`.)

forgejo_url() {
  local u
  u="$(cfg '.release.forgejo.url')"
  printf '%s' "${u%/}"
}

forgejo_host() {
  local u; u="$(forgejo_url)"
  u="${u#https://}"
  u="${u#http://}"
  printf '%s' "${u%%/*}"
}

require_forgejo_token() {
  [[ -n "${FORGEJO_TOKEN:-}" ]] || die "FORGEJO_TOKEN is not set"
}

require_forgejo_owner() {
  local o; o="$(cfg '.release.forgejo.owner')"
  [[ -n "${o}" ]] || die "release.forgejo.owner is empty in build.yaml"
  printf '%s' "${o}"
}

# Repo name for the Releases API. Falls back to GITHUB_REPOSITORY's repo
# segment, which Forgejo Actions populates automatically (Gitea/GitHub
# Actions compatibility).
forgejo_repo() {
  local v
  v="$(cfg '.release.forgejo.repo')"
  if [[ -z "${v}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    v="${GITHUB_REPOSITORY##*/}"
  fi
  [[ -n "${v}" ]] || die "release.forgejo.repo is empty (and GITHUB_REPOSITORY is unset)"
  printf '%s' "${v}"
}

# curl_put uploads a file via PUT with token auth. Used for the package
# registry endpoints, which all accept PUT --upload-file.
forgejo_put() {
  local url="$1" file="$2"
  curl --fail-with-body -sS \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    -X PUT \
    --upload-file "${file}" \
    "${url}"
}

# json_get reads a JSON file via yq's json parser and emits a single value.
forgejo_json_get() {
  ensure_yq
  "${YQ}" -p json -o yaml -r "$1 // \"\"" "$2"
}

# Ensure a Release with the given tag exists. Echoes its numeric id on
# stdout. Idempotent.
forgejo_ensure_release() {
  local tag="$1"
  local owner repo url tmp status body id
  owner="$(require_forgejo_owner)"
  repo="$(forgejo_repo)"
  url="$(forgejo_url)"
  tmp="$(mktemp)"

  status="$(curl -sS -o "${tmp}" -w '%{http_code}' \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    "${url}/api/v1/repos/${owner}/${repo}/releases/tags/${tag}")"

  if [[ "${status}" == "200" ]]; then
    id="$(forgejo_json_get '.id' "${tmp}")"
    rm -f "${tmp}"
    [[ -n "${id}" ]] || die "could not parse release id from existing release ${tag}"
    printf '%s' "${id}"
    return
  fi
  rm -f "${tmp}"

  log "creating Forgejo release ${tag} on ${owner}/${repo}"
  body="$(printf '{"tag_name":"%s","name":"%s","target_commitish":"%s","draft":false,"prerelease":false}' \
    "${tag}" "${tag}" "${GITHUB_SHA:-main}")"
  tmp="$(mktemp)"
  curl --fail-with-body -sS -o "${tmp}" \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST -d "${body}" \
    "${url}/api/v1/repos/${owner}/${repo}/releases"
  id="$(forgejo_json_get '.id' "${tmp}")"
  rm -f "${tmp}"
  [[ -n "${id}" ]] || die "could not create release ${tag}"
  printf '%s' "${id}"
}

# Upload one file as a release asset. Idempotent: deletes a same-named
# asset first, then re-uploads. (Forgejo returns 409 on duplicate names.)
#   $1: numeric release id
#   $2: file path
forgejo_upload_attachment() {
  local rel_id="$1" file="$2"
  local fname owner repo url tmp existing_id
  fname="$(basename "${file}")"
  owner="$(require_forgejo_owner)"
  repo="$(forgejo_repo)"
  url="$(forgejo_url)"

  tmp="$(mktemp)"
  curl --fail-with-body -sS -o "${tmp}" \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    "${url}/api/v1/repos/${owner}/${repo}/releases/${rel_id}/assets"
  existing_id="$(ensure_yq && "${YQ}" -p json -o yaml -r \
    ".[] | select(.name == \"${fname}\") | .id" "${tmp}" \
    | head -n1)"
  rm -f "${tmp}"

  if [[ -n "${existing_id}" && "${existing_id}" != "null" ]]; then
    log "  replacing existing asset ${fname}"
    curl --fail-with-body -sS \
      -H "Authorization: token ${FORGEJO_TOKEN}" \
      -X DELETE \
      "${url}/api/v1/repos/${owner}/${repo}/releases/${rel_id}/assets/${existing_id}" >/dev/null
  fi

  log "  attaching ${fname} to release"
  curl --fail-with-body -sS -o /dev/null \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    -X POST \
    -F "attachment=@${file}" \
    "${url}/api/v1/repos/${owner}/${repo}/releases/${rel_id}/assets?name=${fname}"
}

# Attach a list of files to the per-version release tag.
forgejo_attach_to_release() {
  local files=("$@")
  [[ ${#files[@]} -gt 0 ]] || return 0

  local pkg_ver tag rel_id file
  pkg_ver="$(pkg_version)"
  tag="v${pkg_ver}"
  rel_id="$(forgejo_ensure_release "${tag}")"
  for file in "${files[@]}"; do
    forgejo_upload_attachment "${rel_id}" "${file}"
  done
}

# --- Targets ---------------------------------------------------------------

# check_published prints "true" / "false" on stdout (any logging goes to
# stderr) — true means a Release tagged v<pkg_version> already exists, so
# the build can be skipped. Auth is optional for public repos.
check_published() {
  local owner repo url pkg_ver tag status
  owner="$(require_forgejo_owner)"
  repo="$(forgejo_repo)"
  url="$(forgejo_url)"
  pkg_ver="$(pkg_version)"
  tag="v${pkg_ver}"

  local target="${url}/api/v1/repos/${owner}/${repo}/releases/tags/${tag}"
  log "checking ${target}"
  local auth=()
  [[ -n "${FORGEJO_TOKEN:-}" ]] && auth=(-H "Authorization: token ${FORGEJO_TOKEN}")
  status="$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" "${target}")"
  case "${status}" in
    200) log "already published — skip"; printf 'true\n' ;;
    404) log "not published yet";        printf 'false\n' ;;
    *)   die "unexpected HTTP ${status} from forgejo" ;;
  esac
}

upload_binary() {
  require_forgejo_token
  local owner url pkg_ver pkg_name file fname
  owner="$(require_forgejo_owner)"
  url="$(forgejo_url)"
  pkg_ver="$(pkg_version)"
  pkg_name="$(cfg '.release.generic.package_name')"
  [[ -n "${pkg_name}" ]] || die "release.generic.package_name is empty"

  shopt -s nullglob
  local files=("${OUT_DIR}/caddy_${pkg_ver}"_linux_*.tar.gz)
  shopt -u nullglob
  [[ ${#files[@]} -gt 0 ]] || { warn "no binary tarballs in ${OUT_DIR} for version ${pkg_ver} — skipping"; return 0; }

  for file in "${files[@]}"; do
    fname="$(basename "${file}")"
    log "uploading ${fname} -> generic/${pkg_name}/${pkg_ver}"
    forgejo_put \
      "${url}/api/packages/${owner}/generic/${pkg_name}/${pkg_ver}/${fname}" \
      "${file}"
  done
  forgejo_attach_to_release "${files[@]}"
}

upload_deb() {
  require_forgejo_token
  local owner url distribution component pkg_ver file fname
  owner="$(require_forgejo_owner)"
  url="$(forgejo_url)"
  distribution="$(cfg '.release.deb.distribution')"
  component="$(cfg '.release.deb.component')"
  pkg_ver="$(pkg_version)"
  [[ -n "${distribution}" && -n "${component}" ]] \
    || die "release.deb.distribution and .component must both be set"

  shopt -s nullglob
  local files=("${PKG_DIR}"/*_"${pkg_ver}"-*.deb)
  shopt -u nullglob
  [[ ${#files[@]} -gt 0 ]] || { warn "no .deb files in ${PKG_DIR} for version ${pkg_ver} — skipping"; return 0; }

  for file in "${files[@]}"; do
    fname="$(basename "${file}")"
    log "uploading ${fname} -> debian/${distribution}/${component}"
    forgejo_put \
      "${url}/api/packages/${owner}/debian/pool/${distribution}/${component}/upload" \
      "${file}"
  done
  forgejo_attach_to_release "${files[@]}"
}

upload_apk() {
  require_forgejo_token
  local owner url branch repository pkg_ver file fname
  owner="$(require_forgejo_owner)"
  url="$(forgejo_url)"
  branch="$(cfg '.release.apk.branch')"
  repository="$(cfg '.release.apk.repository')"
  pkg_ver="$(pkg_version)"
  [[ -n "${branch}" && -n "${repository}" ]] \
    || die "release.apk.branch and .repository must both be set"

  shopt -s nullglob
  local files=("${PKG_DIR}"/*_"${pkg_ver}"-*.apk)
  shopt -u nullglob
  [[ ${#files[@]} -gt 0 ]] || { warn "no .apk files in ${PKG_DIR} for version ${pkg_ver} — skipping"; return 0; }

  for file in "${files[@]}"; do
    fname="$(basename "${file}")"
    log "uploading ${fname} -> alpine/${branch}/${repository}"
    forgejo_put \
      "${url}/api/packages/${owner}/alpine/${branch}/${repository}" \
      "${file}"
  done
  forgejo_attach_to_release "${files[@]}"
}

push_docker() {
  require_forgejo_token
  command -v docker >/dev/null 2>&1 || die "docker required for the docker target"
  docker buildx version >/dev/null 2>&1 || die "docker buildx is required"

  local owner host base_image image_name caddy_version pkg_ver
  owner="$(require_forgejo_owner)"
  host="$(forgejo_host)"
  base_image="$(cfg '.docker.base_image')"
  image_name="$(cfg '.docker.image')"
  caddy_version="$(caddy_version)"
  pkg_ver="$(pkg_version)"
  [[ -n "${image_name}" ]] || die "docker.image is empty in build.yaml"

  local remote_image="${host}/${owner}/${image_name}"

  local ctx="${OUT_DIR}/docker-context"
  [[ -d "${ctx}" ]] || die "missing ${ctx} — run './build.sh binary docker' first"

  local platforms=() arch dp
  for arch in $(arch_names); do
    dp="$(arch_field "${arch}" docker_platform)"
    [[ -z "${dp}" ]] && continue
    platforms+=("${dp}")
  done
  local platform_csv
  platform_csv="$(IFS=,; echo "${platforms[*]}")"

  local tag_args=()
  tag_args+=(-t "${remote_image}:${pkg_ver}")
  if [[ "${pkg_ver}" != "${caddy_version}" ]]; then
    tag_args+=(-t "${remote_image}:${caddy_version}")
  fi
  while IFS= read -r t; do
    [[ -z "${t}" ]] && continue
    tag_args+=(-t "${remote_image}:${t}")
  done < <(cfg_list '.docker.tags')

  log "logging in to ${host} as ${owner}"
  printf '%s' "${FORGEJO_TOKEN}" | docker login "${host}" -u "${owner}" --password-stdin

  log "pushing ${remote_image} (${platform_csv})"
  docker buildx build \
    --platform "${platform_csv}" \
    --build-arg "BASE_IMAGE=${base_image}" \
    --build-arg "CADDY_VERSION=${caddy_version}" \
    --push \
    "${tag_args[@]}" \
    "${ctx}"
}

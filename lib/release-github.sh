# GitHub backend for release.sh.
# Attaches binary/deb/apk artifacts to an auto-tagged GitHub Release named
# v<pkg_version>; pushes the docker image to ghcr.io.
#
# Requires GITHUB_TOKEN with `contents: write` (Releases) and, for docker,
# `packages: write` (ghcr).
#
# Owner and repo come from GITHUB_REPOSITORY ("owner/repo"), set
# automatically by the GitHub Actions runner. For local runs, export
# it manually — see README.

github_owner() {
  local r="${GITHUB_REPOSITORY:-}"
  [[ -n "${r}" ]] || die "GITHUB_REPOSITORY is unset (owner/repo; auto-provided in CI, export manually for local runs)"
  printf '%s' "${r%%/*}"
}

github_repo() {
  local r="${GITHUB_REPOSITORY:-}"
  [[ -n "${r}" ]] || die "GITHUB_REPOSITORY is unset (owner/repo; auto-provided in CI, export manually for local runs)"
  printf '%s' "${r##*/}"
}

github_api() {
  printf '%s' "${GITHUB_API_URL:-https://api.github.com}"
}

require_github_token() {
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN is not set"
}

# json_get reads a JSON file via yq's json parser and emits a single value.
#   $1: jq-style path (e.g. '.upload_url')
#   $2: file path
json_get() {
  ensure_yq
  "${YQ}" -p json -o yaml -r "$1 // \"\"" "$2"
}

# Ensure a release with the given tag exists. Echo its upload URL on stdout
# (with the {?name,label} URI template stripped). Idempotent.
gh_ensure_release() {
  local tag="$1"
  local owner repo api body upload_url status tmp
  owner="$(github_owner)"
  repo="$(github_repo)"
  api="$(github_api)"
  tmp="$(mktemp)"

  status="$(curl -sS -o "${tmp}" -w '%{http_code}' \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${api}/repos/${owner}/${repo}/releases/tags/${tag}")"

  if [[ "${status}" == "200" ]]; then
    upload_url="$(json_get '.upload_url' "${tmp}")"
    rm -f "${tmp}"
    upload_url="${upload_url%%\{*}"
    [[ -n "${upload_url}" ]] || die "could not parse upload_url from existing release ${tag}"
    printf '%s' "${upload_url}"
    return
  fi
  rm -f "${tmp}"

  log "creating GitHub release ${tag} on ${owner}/${repo}"
  body="$(printf '{"tag_name":"%s","name":"%s","target_commitish":"%s","draft":false,"prerelease":false}' \
    "${tag}" "${tag}" "${GITHUB_SHA:-main}")"
  tmp="$(mktemp)"
  curl --fail-with-body -sS -o "${tmp}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -X POST -d "${body}" \
    "${api}/repos/${owner}/${repo}/releases"
  upload_url="$(json_get '.upload_url' "${tmp}")"
  rm -f "${tmp}"
  upload_url="${upload_url%%\{*}"
  [[ -n "${upload_url}" ]] || die "could not create release ${tag}"
  printf '%s' "${upload_url}"
}

# Upload one asset to a release. Idempotent: deletes a same-named asset first,
# then uploads. (GitHub returns 422 on duplicate filenames.)
#   $1: upload URL (without query params)
#   $2: file path
#   $3: tag name (used to look up existing assets)
gh_upload_asset() {
  local upload_url="$1" file="$2" tag="$3"
  local fname owner repo api tmp existing_id
  fname="$(basename "${file}")"
  owner="$(github_owner)"
  repo="$(github_repo)"
  api="$(github_api)"

  tmp="$(mktemp)"
  curl --fail-with-body -sS -o "${tmp}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${api}/repos/${owner}/${repo}/releases/tags/${tag}"
  existing_id="$(ensure_yq && "${YQ}" -p json -o yaml -r \
    ".assets[] | select(.name == \"${fname}\") | .id" "${tmp}" \
    | head -n1)"
  rm -f "${tmp}"

  if [[ -n "${existing_id}" && "${existing_id}" != "null" ]]; then
    log "  replacing existing asset ${fname}"
    curl --fail-with-body -sS \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -X DELETE \
      "${api}/repos/${owner}/${repo}/releases/assets/${existing_id}" >/dev/null
  fi

  log "  uploading ${fname}"
  curl --fail-with-body -sS -o /dev/null \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    -X POST \
    --data-binary "@${file}" \
    "${upload_url}?name=${fname}"
}

# Upload a list of files to the per-version release tag. Treats an empty list
# as a soft-skip (matching the Forgejo backend's behaviour).
gh_upload_glob() {
  local label="$1"; shift
  local files=("$@")
  [[ ${#files[@]} -gt 0 ]] || { warn "no ${label} artifacts — skipping"; return 0; }

  require_github_token
  local pkg_ver tag upload_url file
  pkg_ver="$(pkg_version)"
  tag="v${pkg_ver}"
  upload_url="$(gh_ensure_release "${tag}")"
  log "uploading ${#files[@]} ${label} asset(s) -> ${tag}"
  for file in "${files[@]}"; do
    gh_upload_asset "${upload_url}" "${file}" "${tag}"
  done
}

# --- Targets ---------------------------------------------------------------

# check_published prints "true" / "false" on stdout (any logging goes to
# stderr) — true means a Release tagged v<pkg_version> already exists, so the
# build can be skipped. Auth is optional for public repos.
check_published() {
  local owner repo api pkg_ver tag status
  owner="$(github_owner)"
  repo="$(github_repo)"
  api="$(github_api)"
  pkg_ver="$(pkg_version)"
  tag="v${pkg_ver}"

  log "checking GitHub release ${owner}/${repo} ${tag}"
  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  status="$(curl -sS -o /dev/null -w '%{http_code}' \
    "${auth[@]}" \
    -H "Accept: application/vnd.github+json" \
    "${api}/repos/${owner}/${repo}/releases/tags/${tag}")"
  case "${status}" in
    200) log "already published — skip"; printf 'true\n' ;;
    404) log "not published yet";        printf 'false\n' ;;
    *)   die "unexpected HTTP ${status} from github" ;;
  esac
}

upload_binary() {
  local pkg_ver
  pkg_ver="$(pkg_version)"
  shopt -s nullglob
  local files=("${OUT_DIR}/caddy_${pkg_ver}"_linux_*.tar.gz)
  shopt -u nullglob
  gh_upload_glob "binary" "${files[@]}"
}

upload_deb() {
  local pkg_ver
  pkg_ver="$(pkg_version)"
  shopt -s nullglob
  local files=("${PKG_DIR}"/*_"${pkg_ver}"-*.deb)
  shopt -u nullglob
  gh_upload_glob "deb" "${files[@]}"
}

upload_apk() {
  local pkg_ver
  pkg_ver="$(pkg_version)"
  shopt -s nullglob
  local files=("${PKG_DIR}"/*_"${pkg_ver}"-*.apk)
  shopt -u nullglob
  gh_upload_glob "apk" "${files[@]}"
}

push_docker() {
  command -v docker >/dev/null 2>&1 || die "docker required for the docker target"
  docker buildx version >/dev/null 2>&1 || die "docker buildx is required"
  require_github_token

  local owner repo host base_image subpkg image_path caddy_version pkg_ver owner_lc
  owner="$(github_owner)"
  repo="$(github_repo)"
  host="ghcr.io"
  base_image="$(cfg '.docker.base_image')"
  subpkg="$(cfg '.release.github.container_subpackage')"
  if [[ -n "${subpkg}" ]]; then
    image_path="${repo}/${subpkg}"
  else
    image_path="$(cfg '.docker.image')"
    [[ -n "${image_path}" ]] || die "docker.image is empty"
  fi
  caddy_version="$(caddy_version)"
  pkg_ver="$(pkg_version)"

  # ghcr requires the namespace to be lowercase.
  owner_lc="$(printf '%s' "${owner}" | tr '[:upper:]' '[:lower:]')"
  local remote_image="${host}/${owner_lc}/${image_path}"

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
  printf '%s' "${GITHUB_TOKEN}" | docker login "${host}" -u "${owner}" --password-stdin

  log "pushing ${remote_image} (${platform_csv})"
  docker buildx build \
    --platform "${platform_csv}" \
    --build-arg "BASE_IMAGE=${base_image}" \
    --build-arg "CADDY_VERSION=${caddy_version}" \
    --push \
    "${tag_args[@]}" \
    "${ctx}"
}

# Build a multi-arch Docker image consuming the locally built binaries.
# Source common.sh first.

build_docker() {
  command -v docker >/dev/null 2>&1 || die "docker required for the docker target"
  docker buildx version >/dev/null 2>&1 || die "docker buildx is required"

  local image base_image caddy_version pkg_ver multiarch
  image="$(cfg '.docker.image')"
  base_image="$(cfg '.docker.base_image')"
  caddy_version="$(caddy_version)"
  pkg_ver="$(pkg_version)"
  multiarch="$(cfg '.docker.multiarch_manifest')"
  [[ -z "${image}" ]] && die "docker.image is empty in build.yaml"

  # Collect platforms from architectures that declared docker_platform.
  local platforms=() arch dp
  for arch in $(arch_names); do
    dp="$(arch_field "${arch}" docker_platform)"
    [[ -z "${dp}" ]] && continue
    platforms+=("${dp}")
  done
  [[ ${#platforms[@]} -gt 0 ]] || die "no architectures with docker_platform set"

  # Stage build context. The Dockerfile expects binaries/<TARGETARCH[-vTARGETVARIANT]>/caddy.
  local ctx="${OUT_DIR}/docker-context"
  rm -rf "${ctx}"
  mkdir -p "${ctx}/binaries" "${ctx}/dist/caddy-dist/config" "${ctx}/dist/caddy-dist/welcome"
  cp "${ROOT_DIR}/templates/Dockerfile" "${ctx}/Dockerfile"
  cp "${ROOT_DIR}/dist/caddy-dist/config/Caddyfile" "${ctx}/dist/caddy-dist/config/Caddyfile"
  cp "${ROOT_DIR}/dist/caddy-dist/welcome/index.html" "${ctx}/dist/caddy-dist/welcome/index.html"

  local goarch goarm src dest
  for arch in $(arch_names); do
    dp="$(arch_field "${arch}" docker_platform)"
    [[ -z "${dp}" ]] && continue
    goarch="$(arch_field "${arch}" goarch)"
    goarm="$(arch_field "${arch}" goarm)"
    if [[ "${goarch}" == "arm" && -n "${goarm}" ]]; then
      src="${BIN_DIR}/${goarch}-v${goarm}"
      dest="${ctx}/binaries/${goarch}-v${goarm}"
    else
      src="${BIN_DIR}/${goarch}"
      dest="${ctx}/binaries/${goarch}"
    fi
    [[ -x "${src}/caddy" ]] || die "missing binary ${src}/caddy — run binary target first"
    mkdir -p "${dest}"
    cp "${src}/caddy" "${dest}/caddy"
  done

  # Tag list. Always tag the suffixed package version. Also tag the bare
  # upstream version (e.g. "2.11.2") when a suffix is in use, so that tag
  # tracks the latest build of that upstream Caddy version.
  local tag_args=()
  tag_args+=(-t "${image}:${pkg_ver}")
  if [[ "${pkg_ver}" != "${caddy_version}" ]]; then
    tag_args+=(-t "${image}:${caddy_version}")
  fi
  while IFS= read -r t; do
    [[ -z "${t}" ]] && continue
    tag_args+=(-t "${image}:${t}")
  done < <(cfg_list '.docker.tags')

  if [[ "${multiarch}" == "true" ]]; then
    local platform_csv
    platform_csv="$(IFS=,; echo "${platforms[*]}")"
    log "building multi-arch image for: ${platform_csv}"
    local out_flag="--load"
    if [[ ${#platforms[@]} -gt 1 ]]; then
      # buildx can't --load multi-platform images into the daemon; export OCI tar.
      out_flag="--output=type=oci,dest=${OUT_DIR}/${image//\//_}-${pkg_ver}.oci.tar"
      log "  (multi-arch image cannot be loaded into local docker; writing OCI archive)"
    fi
    docker buildx build \
      --platform "${platform_csv}" \
      --build-arg "BASE_IMAGE=${base_image}" \
      --build-arg "CADDY_VERSION=${caddy_version}" \
      ${out_flag} \
      "${tag_args[@]}" \
      "${ctx}"
  else
    # One image per arch, suffixed.
    local p suffix
    for p in "${platforms[@]}"; do
      suffix="${p//\//-}"
      log "building image for ${p} (suffix ${suffix})"
      docker buildx build \
        --platform "${p}" \
        --build-arg "BASE_IMAGE=${base_image}" \
        --build-arg "CADDY_VERSION=${caddy_version}" \
        --load \
        -t "${image}:${pkg_ver}-${suffix}" \
        "${ctx}"
    done
  fi
}

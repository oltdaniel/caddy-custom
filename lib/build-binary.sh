# Build Caddy binaries via xcaddy for every architecture in build.yaml.
# Source common.sh first.

build_binaries() {
  ensure_xcaddy
  local caddy_version pkg_ver build_tags skip_cleanup
  # Upstream Caddy version (no suffix) — xcaddy resolves it as a Go module.
  caddy_version="$(caddy_version)"
  # Package version (with optional suffix) — used in tarball filenames.
  pkg_ver="$(pkg_version)"
  build_tags="$(cfg '.xcaddy.build_tags')"
  skip_cleanup="$(cfg '.xcaddy.skip_cleanup')"

  # Collect --with / --replace / extra flag arguments once. We rebuild the
  # array per-arch only because the env vars (GOOS/GOARCH/...) change.
  local with_args=() replace_args=() extra_args=()
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    [[ "${p}" == *"@"* ]] || die "plugin '${p}' is not pinned (must include @<tag-or-sha>); see README"
    with_args+=(--with "${p}")
  done < <(cfg_list '.xcaddy.plugins')
  while IFS= read -r r; do
    [[ -z "${r}" ]] && continue
    replace_args+=(--replace "${r}")
  done < <(cfg_list '.xcaddy.replacements')
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    extra_args+=("${f}")
  done < <(cfg_list '.xcaddy.extra_flags')

  local arch goos goarch goarm out_dir out_path
  for arch in $(arch_names); do
    goos="$(arch_field "${arch}" goos)"
    goarch="$(arch_field "${arch}" goarch)"
    goarm="$(arch_field "${arch}" goarm)"

    # Output path matches what the Dockerfile expects under binaries/.
    # arm + GOARM=7 -> arm-v7, arm + GOARM=6 -> arm-v6, otherwise just goarch.
    if [[ "${goarch}" == "arm" && -n "${goarm}" ]]; then
      out_dir="${BIN_DIR}/${goarch}-v${goarm}"
    else
      out_dir="${BIN_DIR}/${goarch}"
    fi
    out_path="${out_dir}/caddy"
    mkdir -p "${out_dir}"

    log "building caddy v${caddy_version} for ${arch} (${goos}/${goarch}${goarm:+ GOARM=$goarm})"

    local -a env=(
      "GOOS=${goos}"
      "GOARCH=${goarch}"
      "CGO_ENABLED=0"
      "XCADDY_SKIP_CLEANUP=${skip_cleanup:-0}"
      "XCADDY_SETCAP=0"
    )
    [[ -n "${goarm}" ]] && env+=("GOARM=${goarm}")

    local -a build_args=(build "v${caddy_version}" --output "${out_path}")
    [[ ${#with_args[@]} -gt 0 ]]    && build_args+=("${with_args[@]}")
    [[ ${#replace_args[@]} -gt 0 ]] && build_args+=("${replace_args[@]}")
    [[ ${#extra_args[@]} -gt 0 ]]   && build_args+=("${extra_args[@]}")
    [[ -n "${build_tags}" ]]        && build_args+=(--build-tags "${build_tags}")

    env "${env[@]}" "${XCADDY}" "${build_args[@]}"

    log "  -> ${out_path} ($(du -h "${out_path}" | cut -f1))"
  done

  # Per-arch tarballs for the binary distribution format.
  local tarball
  for arch in $(arch_names); do
    goarch="$(arch_field "${arch}" goarch)"
    goarm="$(arch_field "${arch}" goarm)"
    if [[ "${goarch}" == "arm" && -n "${goarm}" ]]; then
      out_dir="${BIN_DIR}/${goarch}-v${goarm}"
    else
      out_dir="${BIN_DIR}/${goarch}"
    fi
    tarball="${OUT_DIR}/caddy_${pkg_ver}_linux_${arch}.tar.gz"
    tar -C "${out_dir}" -czf "${tarball}" caddy
    log "  packaged ${tarball}"
  done
}

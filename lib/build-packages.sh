# Build deb and apk packages via nfpm. Source common.sh first.

# render_nfpm_yaml writes a per-arch nfpm config to $1 by substituting placeholders
# in templates/nfpm.yaml.tmpl.
render_nfpm_yaml() {
  local out="$1" arch="$2"

  local goarch goarm bin_dir nfpm_arch
  goarch="$(arch_field "${arch}" goarch)"
  goarm="$(arch_field "${arch}" goarm)"
  nfpm_arch="$(arch_field "${arch}" nfpm_arch)"

  if [[ "${goarch}" == "arm" && -n "${goarm}" ]]; then
    bin_dir="${BIN_DIR}/${goarch}-v${goarm}"
  else
    bin_dir="${BIN_DIR}/${goarch}"
  fi

  # Render multi-line description with two-space indentation per line.
  local description description_indented
  description="$(cfg '.package.description')"
  description_indented="$(printf '%s\n' "${description}" | sed 's/^/  /')"

  # Render dependency lists as YAML list items indented to fit under `depends:`.
  local depends_deb depends_apk
  depends_deb="$(cfg_list '.package.depends_deb' | sed 's/^/      - /')"
  depends_apk="$(cfg_list '.package.depends_apk' | sed 's/^/      - /')"
  [[ -z "${depends_deb}" ]] && depends_deb="      []"
  [[ -z "${depends_apk}" ]] && depends_apk="      []"

  export PKG_NAME="$(cfg '.package.name')"
  export PKG_ARCH="${nfpm_arch}"
  export PKG_VERSION="$(pkg_version)"
  export PKG_SECTION="$(cfg '.package.section')"
  export PKG_PRIORITY="$(cfg '.package.priority')"
  export PKG_MAINTAINER="$(cfg '.package.maintainer')"
  export PKG_DESCRIPTION_INDENTED="${description_indented}"
  export PKG_VENDOR="$(cfg '.package.vendor')"
  export PKG_HOMEPAGE="$(cfg '.package.homepage')"
  export PKG_LICENSE="$(cfg '.package.license')"
  export BIN_PATH="${bin_dir}/caddy"
  export DEPENDS_DEB="${depends_deb}"
  export DEPENDS_APK="${depends_apk}"

  envsubst < "${ROOT_DIR}/templates/nfpm.yaml.tmpl" > "${out}"
}

build_deb() {
  ensure_nfpm
  command -v envsubst >/dev/null 2>&1 || die "envsubst required (gettext package)"
  local arch cfg_path
  for arch in $(arch_names); do
    cfg_path="${OUT_DIR}/nfpm-${arch}.yaml"
    render_nfpm_yaml "${cfg_path}" "${arch}"
    log "building deb for ${arch}"
    (cd "${ROOT_DIR}" && "${NFPM}" pkg --packager deb --config "${cfg_path}" --target "${PKG_DIR}/")
  done
}

build_apk() {
  ensure_nfpm
  command -v envsubst >/dev/null 2>&1 || die "envsubst required (gettext package)"
  local arch cfg_path
  for arch in $(arch_names); do
    cfg_path="${OUT_DIR}/nfpm-${arch}.yaml"
    render_nfpm_yaml "${cfg_path}" "${arch}"
    log "building apk for ${arch}"
    (cd "${ROOT_DIR}" && "${NFPM}" pkg --packager apk --config "${cfg_path}" --target "${PKG_DIR}/")
  done
}

# lib/tools.pins.sh — pinned versions + SHA256 for build-time tools.
# Data-only file, sourced by lib/tools.sh. Kept separate so the
# template-sync workflow can overwrite lib/tools.sh (logic) without
# touching the pins, which auto-update mutates via check-updates.sh.
declare -A TOOLS_PINS=(
  [yq_version]="4.53.2"
  [yq_sha256_amd64]="d56bf5c6819e8e696340c312bd70f849dc1678a7cda9c2ad63eebd906371d56b"
  [yq_sha256_arm64]="03061b2a50c7a498de2bbb92d7cb078ce433011f085a4994117c2726be4106ea"
  [nfpm_version]="2.46.3"
  [nfpm_sha256_amd64]="9170d25ea056d7329def38134b2bcad98d02d221f8331610dcd619e84d28c565"
  [nfpm_sha256_arm64]="7871d72bb1035924eab56031f962ae3f004b1f7695151789ef018bdbc507a2fa"
  [xcaddy_version]="0.4.5"
  [xcaddy_sha256_amd64]="2f96dde11b8ecbb7d652c20e05fddbfd2f58c622b464104309eae512406193cf"
  [xcaddy_sha256_arm64]="6ecb9665a2d654697fe79c379bff5d90a9e8aa9165d4b63f8cb21614c5e5e323"
)

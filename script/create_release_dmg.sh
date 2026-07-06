#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release_common.sh"

usage() {
  cat <<EOF
usage: $0 [--release-tag <tag>] [--build-number <number>] [--codesign-identity <identity>] [--configuration <debug|release>] [--output-dir <dir>] [--app-bundle <path>] [--validate-gatekeeper]
EOF
}

release_tag=""
build_number=""
codesign_identity="-"
configuration="release"
output_dir="$BEADAZZLE_DIST_DIR"
app_bundle=""
validate_gatekeeper=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-tag)
      release_tag="${2:?missing value for --release-tag}"
      shift 2
      ;;
    --build-number)
      build_number="${2:?missing value for --build-number}"
      shift 2
      ;;
    --codesign-identity)
      codesign_identity="${2:?missing value for --codesign-identity}"
      shift 2
      ;;
    --configuration)
      configuration="${2:?missing value for --configuration}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --app-bundle)
      app_bundle="${2:?missing value for --app-bundle}"
      shift 2
      ;;
    --validate-gatekeeper)
      validate_gatekeeper=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      beadazzle_release_die "unknown argument: $1"
      ;;
  esac
done

beadazzle_release_require_command hdiutil
beadazzle_release_prepare_dist_dir "$output_dir"
beadazzle_release_resolve_version_context "$release_tag" "$build_number"

if [[ -z "$app_bundle" ]]; then
  app_bundle="$($SCRIPT_DIR/build_app_bundle.sh \
    --release-tag "$BEADAZZLE_RELEASE_LABEL" \
    --build-number "$BEADAZZLE_BUNDLE_VERSION" \
    --codesign-identity "$codesign_identity" \
    --configuration "$configuration" \
    --output-dir "$output_dir")"
fi

[[ -d "$app_bundle" ]] || beadazzle_release_die "app bundle not found: $app_bundle"

dmg_path="$output_dir/$BEADAZZLE_ARTIFACT_BASENAME.dmg"
checksum_path="$dmg_path.sha256"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/beadazzle-dmg-stage.XXXXXX")"
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/beadazzle-dmg-mount.XXXXXX")"

cleanup() {
  /usr/bin/hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
  rm -rf "$staging_dir" "$mount_dir"
}
trap cleanup EXIT

cp -R "$app_bundle" "$staging_dir/$BEADAZZLE_APP_NAME.app"
ln -s /Applications "$staging_dir/Applications"
rm -f "$dmg_path" "$checksum_path"

/usr/bin/hdiutil create \
  -volname "$BEADAZZLE_APP_NAME" \
  -srcfolder "$staging_dir" \
  -ov \
  -format UDZO \
  "$dmg_path" >/dev/null

beadazzle_release_sign_file "$codesign_identity" "$dmg_path"
beadazzle_release_verify_file_signature "$dmg_path"

/usr/bin/hdiutil attach "$dmg_path" -mountpoint "$mount_dir" -nobrowse -readonly -quiet
[[ -d "$mount_dir/$BEADAZZLE_APP_NAME.app" ]] || beadazzle_release_die "mounted DMG is missing $BEADAZZLE_APP_NAME.app"
[[ -L "$mount_dir/Applications" ]] || beadazzle_release_die "mounted DMG is missing Applications symlink"
/usr/bin/hdiutil detach "$mount_dir" -quiet

if [[ $validate_gatekeeper -eq 1 ]]; then
  beadazzle_release_validate_spctl_open "$dmg_path"
fi

beadazzle_release_write_checksum "$dmg_path" "$checksum_path"

printf '%s\n%s\n' "$dmg_path" "$checksum_path"
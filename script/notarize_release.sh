#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release_common.sh"

usage() {
  cat <<EOF
usage: $0 [--app-bundle <path>] [--dmg-path <path>] [--checksum-path <path>] [--apple-id <id>] [--team-id <id>] [--password <app-specific-password>]
EOF
}

app_bundle=""
dmg_path=""
checksum_path=""
apple_id="${APPLE_ID:-}"
apple_team_id="${APPLE_TEAM_ID:-}"
apple_password="${APPLE_APP_SPECIFIC_PASSWORD:-}"
temp_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle)
      app_bundle="${2:?missing value for --app-bundle}"
      shift 2
      ;;
    --dmg-path)
      dmg_path="${2:?missing value for --dmg-path}"
      shift 2
      ;;
    --checksum-path)
      checksum_path="${2:?missing value for --checksum-path}"
      shift 2
      ;;
    --apple-id)
      apple_id="${2:?missing value for --apple-id}"
      shift 2
      ;;
    --team-id)
      apple_team_id="${2:?missing value for --team-id}"
      shift 2
      ;;
    --password)
      apple_password="${2:?missing value for --password}"
      shift 2
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

[[ -n "$app_bundle" || -n "$dmg_path" ]] || beadazzle_release_die "provide --app-bundle, --dmg-path, or both"
[[ -n "$apple_id" ]] || beadazzle_release_die "missing Apple ID; pass --apple-id or set APPLE_ID"
[[ -n "$apple_team_id" ]] || beadazzle_release_die "missing Apple team ID; pass --team-id or set APPLE_TEAM_ID"
[[ -n "$apple_password" ]] || beadazzle_release_die "missing Apple app-specific password; pass --password or set APPLE_APP_SPECIFIC_PASSWORD"

beadazzle_release_require_command xcrun
beadazzle_release_require_command ditto

cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT

submit_for_notarization() {
  local label="$1"
  local artifact_path="$2"

  printf 'Submitting %s for notarization...\n' "$label" >&2
  /usr/bin/xcrun notarytool submit \
    "$artifact_path" \
    --apple-id "$apple_id" \
    --team-id "$apple_team_id" \
    --password "$apple_password" \
    --wait >&2
}

if [[ -n "$app_bundle" ]]; then
  [[ -d "$app_bundle" ]] || beadazzle_release_die "app bundle not found: $app_bundle"

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/beadazzle-notary.XXXXXX")"
  app_archive="$temp_dir/$BEADAZZLE_APP_NAME.app.zip"
  /usr/bin/ditto -c -k --keepParent --sequesterRsrc "$app_bundle" "$app_archive"

  submit_for_notarization "$app_bundle" "$app_archive"
  /usr/bin/xcrun stapler staple "$app_bundle" >&2
  beadazzle_release_verify_app_bundle_signature "$app_bundle"
  beadazzle_release_validate_spctl_app "$app_bundle"

  rm -rf "$temp_dir"
  temp_dir=""
fi

if [[ -n "$dmg_path" ]]; then
  [[ -f "$dmg_path" ]] || beadazzle_release_die "DMG not found: $dmg_path"

  if [[ -z "$checksum_path" ]]; then
    checksum_path="$dmg_path.sha256"
  fi

  submit_for_notarization "$dmg_path" "$dmg_path"
  /usr/bin/xcrun stapler staple "$dmg_path" >&2
  beadazzle_release_verify_file_signature "$dmg_path"
  beadazzle_release_validate_spctl_open "$dmg_path"
  beadazzle_release_write_checksum "$dmg_path" "$checksum_path"
fi
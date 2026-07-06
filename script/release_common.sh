#!/usr/bin/env bash

if [[ -n "${BEADAZZLE_RELEASE_COMMON_LOADED:-}" ]]; then
  return 0
fi

readonly BEADAZZLE_RELEASE_COMMON_LOADED=1
readonly BEADAZZLE_APP_NAME="Beadazzle"
readonly BEADAZZLE_BUNDLE_ID="app.beadazzle.macos"
readonly BEADAZZLE_MIN_SYSTEM_VERSION="14.0"
readonly BEADAZZLE_DEFAULT_RELEASE_LABEL="0.1.0-local"
readonly BEADAZZLE_DEFAULT_BUILD_NUMBER="1"

BEADAZZLE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BEADAZZLE_SCRIPT_DIR
BEADAZZLE_ROOT_DIR="$(cd "$BEADAZZLE_SCRIPT_DIR/.." && pwd)"
readonly BEADAZZLE_ROOT_DIR
readonly BEADAZZLE_DIST_DIR="$BEADAZZLE_ROOT_DIR/dist"

beadazzle_release_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

beadazzle_release_require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || beadazzle_release_die "missing required command: $command_name"
}

beadazzle_release_is_ad_hoc_identity() {
  [[ "$1" == "-" ]]
}

beadazzle_release_resolve_version_context() {
  local requested_release="${1:-${BEADAZZLE_RELEASE_VERSION:-${GITHUB_REF_NAME:-}}}"
  local requested_build_number="${2:-${BEADAZZLE_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-}}}"
  local detected_release="$requested_release"

  if [[ -z "$detected_release" ]] && command -v git >/dev/null 2>&1; then
    detected_release="$(git -C "$BEADAZZLE_ROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
  fi

  if [[ -z "$detected_release" ]]; then
    detected_release="$BEADAZZLE_DEFAULT_RELEASE_LABEL"
  fi

  detected_release="${detected_release#refs/tags/}"
  detected_release="${detected_release#v}"

  local version_regex='^([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
  if [[ "$detected_release" =~ $version_regex ]]; then
    :
  else
    beadazzle_release_die "release version must look like v1.2.3 or 1.2.3-beta.1; got: $detected_release"
  fi

  local major_version="${BASH_REMATCH[1]}"
  local minor_version="${BASH_REMATCH[2]}"
  local patch_version="${BASH_REMATCH[3]}"

  if [[ -z "$requested_build_number" ]]; then
    requested_build_number="$BEADAZZLE_DEFAULT_BUILD_NUMBER"
  fi

  local build_regex='^[0-9]+(\.[0-9]+){0,2}$'
  if [[ ! "$requested_build_number" =~ $build_regex ]]; then
    beadazzle_release_die "build number must contain only digits and up to two dots; got: $requested_build_number"
  fi

  BEADAZZLE_RELEASE_LABEL="$detected_release"
  BEADAZZLE_BUNDLE_SHORT_VERSION="$major_version.$minor_version.$patch_version"
  BEADAZZLE_BUNDLE_VERSION="$requested_build_number"
  BEADAZZLE_ARTIFACT_BASENAME="$BEADAZZLE_APP_NAME-$BEADAZZLE_RELEASE_LABEL"
}

beadazzle_release_prepare_dist_dir() {
  mkdir -p "$1"
}

beadazzle_release_sign_app_bundle() {
  local identity="$1"
  local app_bundle="$2"
  local -a command=(/usr/bin/codesign --force --deep --sign "$identity")

  if ! beadazzle_release_is_ad_hoc_identity "$identity"; then
    command+=(--options runtime --timestamp)
  fi

  "${command[@]}" "$app_bundle"
}

beadazzle_release_sign_file() {
  local identity="$1"
  local target_path="$2"
  local -a command=(/usr/bin/codesign --force --sign "$identity")

  if ! beadazzle_release_is_ad_hoc_identity "$identity"; then
    command+=(--timestamp)
  fi

  "${command[@]}" "$target_path"
}

beadazzle_release_verify_app_bundle_signature() {
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$1"
}

beadazzle_release_verify_file_signature() {
  /usr/bin/codesign --verify --verbose=2 "$1"
}

beadazzle_release_validate_spctl_app() {
  /usr/sbin/spctl -a -vv --type exec "$1"
}

beadazzle_release_validate_spctl_open() {
  /usr/sbin/spctl -a -vv --type open "$1"
}

beadazzle_release_write_checksum() {
  local artifact_path="$1"
  local checksum_path="$2"
  local artifact_dir
  artifact_dir="$(dirname "$artifact_path")"
  local artifact_name
  artifact_name="$(basename "$artifact_path")"
  local checksum_name
  checksum_name="$(basename "$checksum_path")"

  (
    cd "$artifact_dir"
    /usr/bin/shasum -a 256 "$artifact_name" > "$checksum_name"
  )
}
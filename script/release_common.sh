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
readonly BEADAZZLE_APP_ICON_SOURCE="$BEADAZZLE_ROOT_DIR/Resources/AppIcon.png"

# Sparkle auto-update configuration.
# The appcast is published to GitHub Pages by the release workflow.
readonly BEADAZZLE_SPARKLE_FEED_URL="https://mosnar.github.io/beadazzle/appcast.xml"
# EdDSA public key baked into Info.plist so the app can verify update signatures.
# Not secret. Generated once with Sparkle's `generate_keys`; paste the public key
# here (or override via the BEADAZZLE_SPARKLE_PUBLIC_KEY env var in CI).
BEADAZZLE_SPARKLE_PUBLIC_KEY="${BEADAZZLE_SPARKLE_PUBLIC_KEY:-}"

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

# Generate an .icns from a square source PNG into the bundle Resources dir.
# Returns non-zero (without generating) when the source PNG is absent so callers
# can skip wiring CFBundleIconFile.
beadazzle_release_write_app_icon() {
  local source_png="$1"
  local resources_dir="$2"
  local icon_name="${3:-AppIcon}"

  [[ -f "$source_png" ]] || return 1

  beadazzle_release_require_command sips
  beadazzle_release_require_command iconutil

  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/beadazzle-iconset.XXXXXX")"
  local iconset_dir="$work_dir/$icon_name.iconset"
  mkdir -p "$iconset_dir"

  local size retina
  for size in 16 32 128 256 512; do
    retina=$((size * 2))
    /usr/bin/sips -z "$size" "$size" "$source_png" \
      --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    /usr/bin/sips -z "$retina" "$retina" "$source_png" \
      --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
  done

  mkdir -p "$resources_dir"
  /usr/bin/iconutil -c icns "$iconset_dir" -o "$resources_dir/$icon_name.icns"
  rm -rf "$work_dir"
}

beadazzle_release_sign_app_bundle() {
  local identity="$1"
  local app_bundle="$2"
  # No --deep: nested code (Sparkle.framework) is signed inside-out beforehand
  # via beadazzle_release_sign_sparkle. This seals the outer bundle and its main
  # executable while leaving the already-valid nested signatures intact.
  local -a command=(/usr/bin/codesign --force --sign "$identity")

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

# Locate the macOS Sparkle.framework SwiftPM extracts from its XCFramework.
# Prefers the build artifacts dir over the index-build copy.
beadazzle_release_locate_sparkle_framework() {
  local framework
  framework="$(/usr/bin/find "$BEADAZZLE_ROOT_DIR/.build" -type d -name 'Sparkle.framework' -path '*.xcframework/macos*' 2>/dev/null \
    | grep -v '/index-build/' \
    | head -n1)"
  [[ -n "$framework" ]] || beadazzle_release_die "could not locate Sparkle.framework under .build; run 'swift build' first"
  printf '%s\n' "$framework"
}

# Copy Sparkle.framework into the bundle, drop the XPC services (only needed by
# sandboxed apps; Beadazzle is not sandboxed), and add an rpath so the main
# executable resolves @rpath/Sparkle.framework at launch.
beadazzle_release_embed_sparkle() {
  local app_contents="$1"
  local frameworks_dir="$app_contents/Frameworks"
  local main_binary="$app_contents/MacOS/$BEADAZZLE_APP_NAME"
  local source_framework
  source_framework="$(beadazzle_release_locate_sparkle_framework)"

  local framework="$frameworks_dir/Sparkle.framework"
  mkdir -p "$frameworks_dir"
  rm -rf "$framework"
  /usr/bin/ditto "$source_framework" "$framework"

  # Drop the XPC services (unused by non-sandboxed apps). Remove both the real
  # directory and the top-level symlink that points at it, otherwise the dangling
  # symlink breaks later xattr/codesign passes over the framework.
  rm -rf "$framework/Versions/Current/XPCServices"
  rm -f "$framework/XPCServices"

  # Adding an rpath invalidates the ad-hoc signature SwiftPM applies to the main
  # binary, but it is re-signed after embedding. Ignore "would duplicate" on reruns.
  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$main_binary" 2>/dev/null || true
}

# Sign Sparkle's nested code inside-out (helpers before the framework bundle).
# Deliberately avoids `codesign --deep`, which Apple deprecates and which does
# not correctly apply hardened-runtime options to nested bundles.
beadazzle_release_sign_sparkle() {
  local identity="$1"
  local frameworks_dir="$2"
  local framework="$frameworks_dir/Sparkle.framework"
  local versioned="$framework/Versions/Current"

  [[ -d "$framework" ]] || beadazzle_release_die "Sparkle.framework not embedded before signing: $framework"

  [[ -e "$versioned/Autoupdate" ]] && beadazzle_release_sign_hardened "$identity" "$versioned/Autoupdate"
  [[ -d "$versioned/Updater.app" ]] && beadazzle_release_sign_hardened "$identity" "$versioned/Updater.app"
  beadazzle_release_sign_hardened "$identity" "$framework"
}

# Sign a single target with the hardened runtime + secure timestamp for real
# Developer ID identities (skipped for the ad-hoc "-" identity used locally).
beadazzle_release_sign_hardened() {
  local identity="$1"
  local target_path="$2"
  local -a command=(/usr/bin/codesign --force --sign "$identity")

  if ! beadazzle_release_is_ad_hoc_identity "$identity"; then
    command+=(--options runtime --timestamp)
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
  /usr/sbin/spctl -a -vv --type open --context context:primary-signature "$1"
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
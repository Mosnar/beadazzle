#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release_common.sh"

usage() {
  cat <<EOF
usage: $0 [--release-tag <tag>] [--build-number <number>] [--codesign-identity <identity>] [--configuration <debug|release>] [--output-dir <dir>] [--validate-gatekeeper]
EOF
}

release_tag=""
build_number=""
codesign_identity="-"
configuration="debug"
output_dir="$BEADAZZLE_DIST_DIR"
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

case "$configuration" in
  debug|release)
    ;;
  *)
    beadazzle_release_die "configuration must be debug or release; got: $configuration"
    ;;
esac

beadazzle_release_require_command swift
beadazzle_release_prepare_dist_dir "$output_dir"
beadazzle_release_resolve_version_context "$release_tag" "$build_number"

app_bundle="$output_dir/$BEADAZZLE_APP_NAME.app"
app_contents="$app_bundle/Contents"
app_macos="$app_contents/MacOS"
app_binary="$app_macos/$BEADAZZLE_APP_NAME"
info_plist="$app_contents/Info.plist"

build_arguments=(build)
if [[ "$configuration" == "release" ]]; then
  build_arguments+=(-c release)
fi

swift "${build_arguments[@]}" >&2

show_bin_arguments=(build --show-bin-path)
if [[ "$configuration" == "release" ]]; then
  show_bin_arguments+=(-c release)
fi

build_binary="$(swift "${show_bin_arguments[@]}" 2>/dev/null)/$BEADAZZLE_APP_NAME"

rm -rf "$app_bundle"
mkdir -p "$app_macos"
cp "$build_binary" "$app_binary"
chmod +x "$app_binary"

cat >"$info_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$BEADAZZLE_APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BEADAZZLE_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$BEADAZZLE_APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$BEADAZZLE_BUNDLE_SHORT_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BEADAZZLE_BUNDLE_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$BEADAZZLE_MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUFeedURL</key>
  <string>$BEADAZZLE_SPARKLE_FEED_URL</string>
</dict>
</plist>
PLIST

if [[ -n "$BEADAZZLE_SPARKLE_PUBLIC_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $BEADAZZLE_SPARKLE_PUBLIC_KEY" "$info_plist" >/dev/null
else
  printf 'warning: BEADAZZLE_SPARKLE_PUBLIC_KEY is unset; built app will hide update controls\n' >&2
fi

beadazzle_release_embed_sparkle "$app_contents"

app_resources="$app_contents/Resources"
if beadazzle_release_write_app_icon "$BEADAZZLE_APP_ICON_SOURCE" "$app_resources"; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$info_plist" >/dev/null
fi

/usr/bin/xattr -cr "$app_bundle"
# File Provider/Finder metadata can survive `xattr -c` on some local synced
# folders and makes codesign reject the generated app bundle.
/usr/bin/xattr -d -r com.apple.FinderInfo "$app_bundle" 2>/dev/null || true
/usr/bin/xattr -d -r 'com.apple.fileprovider.fpfs#P' "$app_bundle" 2>/dev/null || true
beadazzle_release_sign_sparkle "$codesign_identity" "$app_contents/Frameworks"
beadazzle_release_sign_app_bundle "$codesign_identity" "$app_bundle"
beadazzle_release_verify_app_bundle_signature "$app_bundle"

if [[ $validate_gatekeeper -eq 1 ]]; then
  beadazzle_release_validate_spctl_app "$app_bundle"
fi

printf '%s\n' "$app_bundle"

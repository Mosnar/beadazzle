#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release_common.sh"

usage() {
  cat <<EOF
usage: $0 --dmg-path <path> --release-tag <tag> --notes-html <path> \\
          --generate-appcast <path> --output-dir <dir>

Builds/updates the Sparkle appcast for a release and writes appcast.xml into
--output-dir (ready to publish to GitHub Pages).

Behavior:
  - Seeds from the currently published appcast so prior entries are preserved.
  - Signs the DMG with the EdDSA private key read from the SPARKLE_ED_PRIVATE_KEY
    environment variable (base64, as printed by Sparkle's generate_keys).
  - Points download URLs at the tag's GitHub release asset.
  - Assigns pre-release tags (those containing a hyphen, e.g. v1.2.3-beta.1) to
    the Sparkle "beta" channel; final releases go to the default channel.
EOF
}

dmg_path=""
release_tag=""
notes_html=""
generate_appcast=""
output_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg-path)
      dmg_path="${2:?missing value for --dmg-path}"
      shift 2
      ;;
    --release-tag)
      release_tag="${2:?missing value for --release-tag}"
      shift 2
      ;;
    --notes-html)
      notes_html="${2:?missing value for --notes-html}"
      shift 2
      ;;
    --generate-appcast)
      generate_appcast="${2:?missing value for --generate-appcast}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:?missing value for --output-dir}"
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

[[ -n "$dmg_path" ]] || { usage >&2; beadazzle_release_die "missing --dmg-path"; }
[[ -n "$release_tag" ]] || { usage >&2; beadazzle_release_die "missing --release-tag"; }
[[ -n "$generate_appcast" ]] || { usage >&2; beadazzle_release_die "missing --generate-appcast"; }
[[ -n "$output_dir" ]] || { usage >&2; beadazzle_release_die "missing --output-dir"; }
[[ -f "$dmg_path" ]] || beadazzle_release_die "DMG not found: $dmg_path"
[[ -x "$generate_appcast" ]] || beadazzle_release_die "generate_appcast not executable: $generate_appcast"
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || beadazzle_release_die "missing SPARKLE_ED_PRIVATE_KEY environment value"

beadazzle_release_require_command curl

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/beadazzle-appcast.XXXXXX")"
key_file="$(mktemp "${TMPDIR:-/tmp}/beadazzle-ed-key.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
  rm -f "$key_file"
}
trap cleanup EXIT

# Stage the DMG being released.
dmg_name="$(basename "$dmg_path")"
cp "$dmg_path" "$work_dir/$dmg_name"

# Release notes: generate_appcast embeds a sibling <archive-basename>.html file
# as the item's description.
if [[ -n "$notes_html" && -f "$notes_html" ]]; then
  cp "$notes_html" "$work_dir/${dmg_name%.dmg}.html"
fi

# Preserve previously published entries by seeding the existing appcast.
if curl -fsSL "$BEADAZZLE_SPARKLE_FEED_URL" -o "$work_dir/appcast.xml"; then
  printf 'Seeded existing appcast from %s\n' "$BEADAZZLE_SPARKLE_FEED_URL" >&2
else
  printf 'No existing appcast found; starting a fresh feed\n' >&2
  rm -f "$work_dir/appcast.xml"
fi

# Write the private key to a file for --ed-key-file (avoids leaking via argv).
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$key_file"

download_prefix="https://github.com/Mosnar/beadazzle/releases/download/$release_tag/"

generate_args=(
  "$work_dir"
  --ed-key-file "$key_file"
  --download-url-prefix "$download_prefix"
)

# A semver pre-release identifier always contains a hyphen (e.g. -beta.1).
if [[ "$release_tag" == *-* ]]; then
  generate_args+=(--channel beta)
fi

"$generate_appcast" "${generate_args[@]}" >&2

[[ -f "$work_dir/appcast.xml" ]] || beadazzle_release_die "generate_appcast did not produce appcast.xml"

mkdir -p "$output_dir"
cp "$work_dir/appcast.xml" "$output_dir/appcast.xml"
printf '%s\n' "$output_dir/appcast.xml"

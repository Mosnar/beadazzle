#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release_common.sh"

usage() {
  cat <<EOF
usage: $0 --version <tag> [--changelog <path>]

Prints the CHANGELOG.md section body for the given version to stdout.
The version may be given with or without a leading 'v' (e.g. v0.1.0-beta.1).
Exits non-zero if no matching section exists, so a release can fail loudly
when notes are missing.
EOF
}

version=""
changelog="$BEADAZZLE_ROOT_DIR/CHANGELOG.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:?missing value for --version}"
      shift 2
      ;;
    --changelog)
      changelog="${2:?missing value for --changelog}"
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

[[ -n "$version" ]] || { usage >&2; beadazzle_release_die "missing --version"; }
[[ -f "$changelog" ]] || beadazzle_release_die "changelog not found: $changelog"

# Match the heading regardless of a leading 'v'.
version="${version#v}"

# Grab lines between "## [<version>]" and the next "## [" heading, dropping
# link-reference definitions ([x]: url) and any leading blank lines.
section="$(awk -v target="$version" '
  /^## \[/ {
    header = $0
    sub(/^## \[/, "", header)
    sub(/\].*/, "", header)
    grab = (header == target) ? 1 : 0
    next
  }
  grab { print }
' "$changelog" | grep -v '^\[[^]]*\]: ' | awk 'NF { seen = 1 } seen { print }')"

if [[ -z "${section//[[:space:]]/}" ]]; then
  beadazzle_release_die "no changelog section found for version: $version"
fi

printf '%s\n' "$section"

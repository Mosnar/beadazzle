#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release_common.sh"

assert_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'assertion failed for %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_version() {
  local release_tag="$1"
  local build_number="$2"
  local expected_label="$3"
  local expected_short_version="$4"
  local expected_bundle_version="$5"

  beadazzle_release_resolve_version_context "$release_tag" "$build_number"

  assert_equal "$BEADAZZLE_RELEASE_LABEL" "$expected_label" "release label"
  assert_equal "$BEADAZZLE_BUNDLE_SHORT_VERSION" "$expected_short_version" "bundle short version"
  assert_equal "$BEADAZZLE_BUNDLE_VERSION" "$expected_bundle_version" "bundle version"
}

assert_version "v1.2.3" "42" "1.2.3" "1.2.3" "42"
assert_version "1.2.3-beta.4" "105" "1.2.3-beta.4" "1.2.3" "105"
assert_version "refs/tags/v2.0.1+build.7" "9.3" "2.0.1+build.7" "2.0.1" "9.3"

if (beadazzle_release_resolve_version_context "not-a-version" "1") >/dev/null 2>&1; then
  printf 'expected invalid release version parsing to fail\n' >&2
  exit 1
fi

if (beadazzle_release_resolve_version_context "1.2.3" "abc") >/dev/null 2>&1; then
  printf 'expected invalid build number parsing to fail\n' >&2
  exit 1
fi

printf 'ok\n'
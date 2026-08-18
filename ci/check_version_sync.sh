#!/bin/bash
# Asserts every version-carrying file in sdks/godot/ agrees with VERSION.
#
# Checked:
#   - sdks/godot/VERSION
#   - addons/fractal/plugin.cfg            version="X.Y.Z"
#   - addons/fractal/core/version.gd       const VERSION := "X.Y.Z"
#   - CHANGELOG.md                          newest "## X.Y.Z" heading
#   - each version.gd NATIVE_BINARY_VERSIONS[<platform>] <= VERSION (sort -V)
#, platforms are independent now (see ci/version_lib.sh's host-platform
#     gating), so each entry is checked on its own, not against each other.
#
# Run from anywhere; paths are resolved relative to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${FRACTAL_SDK_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$ROOT_DIR"

# shellcheck source=./native_paths.sh
source "$SCRIPT_DIR/native_paths.sh"

fail() {
  echo "check_version_sync: $1" >&2
  exit 1
}

[ -f VERSION ] || fail "VERSION file missing"
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION file '$VERSION' is not valid semver"

PLUGIN_CFG="addons/fractal/plugin.cfg"
[ -f "$PLUGIN_CFG" ] || fail "$PLUGIN_CFG missing"
PLUGIN_VERSION="$(sed -n 's/^version="\([^"]*\)".*/\1/p' "$PLUGIN_CFG" | head -1)"
[ -n "$PLUGIN_VERSION" ] || fail "$PLUGIN_CFG has no version= line"
[ "$PLUGIN_VERSION" = "$VERSION" ] || fail "$PLUGIN_CFG version ($PLUGIN_VERSION) != VERSION ($VERSION)"

VERSION_GD="addons/fractal/core/version.gd"
[ -f "$VERSION_GD" ] || fail "$VERSION_GD missing"
GD_VERSION="$(sed -n 's/.*const VERSION := "\([^"]*\)".*/\1/p' "$VERSION_GD" | head -1)"
[ -n "$GD_VERSION" ] || fail "$VERSION_GD has no VERSION constant"
[ "$GD_VERSION" = "$VERSION" ] || fail "$VERSION_GD VERSION ($GD_VERSION) != VERSION file ($VERSION)"

NATIVE_BINARY_VERSIONS_SUMMARY=()
for platform_key in "${FRACTAL_NATIVE_PLATFORM_KEYS[@]}"; do
  platform_nbv="$(sed -n "s/.*\"$platform_key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$VERSION_GD" | head -1)"
  [ -n "$platform_nbv" ] || fail "$VERSION_GD has no NATIVE_BINARY_VERSIONS entry for $platform_key"
  [[ "$platform_nbv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "NATIVE_BINARY_VERSIONS[$platform_key] '$platform_nbv' is not valid semver"
  HIGHEST="$(printf '%s\n%s\n' "$platform_nbv" "$VERSION" | sort -V | tail -1)"
  [ "$HIGHEST" = "$VERSION" ] || fail "NATIVE_BINARY_VERSIONS[$platform_key] ($platform_nbv) is ahead of VERSION ($VERSION)"
  NATIVE_BINARY_VERSIONS_SUMMARY+=("$platform_key=$platform_nbv")
done

CHANGELOG="CHANGELOG.md"
[ -f "$CHANGELOG" ] || fail "$CHANGELOG missing"
CHANGELOG_VERSION="$(sed -n 's/^## \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$CHANGELOG" | head -1)"
[ -n "$CHANGELOG_VERSION" ] || fail "$CHANGELOG has no '## X.Y.Z' heading"
[ "$CHANGELOG_VERSION" = "$VERSION" ] || fail "$CHANGELOG newest heading ($CHANGELOG_VERSION) != VERSION ($VERSION)"

CHANGELOG_BODY="$(awk '/^## /{n++} n==1 && !/^## /' "$CHANGELOG" | sed '/^[[:space:]]*$/d')"
[ "$CHANGELOG_BODY" != "_Release notes pending._" ] || fail "$CHANGELOG newest entry ($VERSION) still has the '_Release notes pending._' stub, write real release notes"

echo "check_version_sync: OK (VERSION=$VERSION, ${NATIVE_BINARY_VERSIONS_SUMMARY[*]})"

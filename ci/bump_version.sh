#!/bin/bash
# Mechanically bumps the Godot SDK version across all lockstep files:
# VERSION, plugin.cfg, version.gd's VERSION constant (NOT any
# NATIVE_BINARY_VERSIONS entry, those are build_local.sh's job for the host
# platform, or fetch_native_artifacts.sh's for the others, since they only
# change when binaries are actually rebuilt), and a CHANGELOG.md stub.
#
# Non-interactive, no git mutations (caller stages/commits). The human
# picks the semver level; this script does the arithmetic and edits.
#
# Usage: bump_version.sh patch|minor|major
#
# Computes the target from the merge-base version, not the working-tree
# VERSION, so re-running with a different level re-levels the pending bump
# instead of stacking on top of an already-bumped working tree. Falls back
# to the working-tree VERSION when VERSION doesn't exist yet at the
# merge-base (bootstrap mode, e.g. this branch's own history).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${FRACTAL_SDK_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
if ! REPO_ROOT="$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
fi

fail() {
  echo "bump_version: $1" >&2
  exit 1
}

LEVEL="${1:-}"
case "$LEVEL" in
  patch|minor|major) ;;
  *) fail "usage: bump_version.sh patch|minor|major" ;;
esac

# shellcheck source=./version_lib.sh
source "$SCRIPT_DIR/version_lib.sh"

CURRENT=""
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  BASE_REF="${FRACTAL_BASE_REF:-origin/main}"
  if git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE_REF" > /dev/null; then
    BASE="$(git -C "$REPO_ROOT" merge-base HEAD "$BASE_REF" 2>/dev/null || true)"
    [ -n "$BASE" ] && CURRENT="$(cd "$REPO_ROOT" && fractal_version_at_ref "$BASE")"
  fi
fi

if [ -z "$CURRENT" ]; then
  [ -f "$ROOT_DIR/VERSION" ] || fail "no merge-base VERSION and no working-tree VERSION, nothing to bump from"
  CURRENT="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
fi

[[ "$CURRENT" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "current version '$CURRENT' is not valid semver"
MAJOR="${BASH_REMATCH[1]}" MINOR="${BASH_REMATCH[2]}" PATCH="${BASH_REMATCH[3]}"

case "$LEVEL" in
  major) TARGET="$((MAJOR + 1)).0.0" ;;
  minor) TARGET="$MAJOR.$((MINOR + 1)).0" ;;
  patch) TARGET="$MAJOR.$MINOR.$((PATCH + 1))" ;;
esac

echo "bump_version: $CURRENT -> $TARGET ($LEVEL)"

echo "$TARGET" > "$ROOT_DIR/VERSION"

sed -i.bak "s/^version=\"[^\"]*\"/version=\"$TARGET\"/" "$ROOT_DIR/addons/fractal/plugin.cfg"
rm -f "$ROOT_DIR/addons/fractal/plugin.cfg.bak"

sed -i.bak "s/const VERSION := \"[^\"]*\"/const VERSION := \"$TARGET\"/" "$ROOT_DIR/addons/fractal/core/version.gd"
rm -f "$ROOT_DIR/addons/fractal/core/version.gd.bak"

CHANGELOG="$ROOT_DIR/CHANGELOG.md"
[ -f "$CHANGELOG" ] || fail "$CHANGELOG missing"

EXISTING_HEADING="$(grep -m1 -oP '^## \K[0-9]+\.[0-9]+\.[0-9]+' "$CHANGELOG" || true)"
EXISTING_BODY="$(awk '/^## /{n++} n==1 && !/^## /' "$CHANGELOG" | sed '/^[[:space:]]*$/d')"

if [ -n "$EXISTING_HEADING" ] && [ "$EXISTING_BODY" = "_Release notes pending._" ]; then
  # Re-level: rewrite the stub heading this script previously inserted.
  sed -i.bak "0,/^## $EXISTING_HEADING\$/s//## $TARGET/" "$CHANGELOG"
  rm -f "$CHANGELOG.bak"
else
  # Insert immediately before the first "## X.Y.Z" heading, preserving any
  # title/preamble text above it (e.g. "# Changelog" + intro paragraph).
  FIRST_HEADING_LINE="$(grep -n '^## ' "$CHANGELOG" | head -1 | cut -d: -f1)"
  [ -n "$FIRST_HEADING_LINE" ] || FIRST_HEADING_LINE="$(($(wc -l < "$CHANGELOG") + 1))"
  TMP="$(mktemp)"
  {
    head -n "$((FIRST_HEADING_LINE - 1))" "$CHANGELOG"
    echo "## $TARGET"
    echo
    echo "_Release notes pending._"
    echo
    tail -n +"$FIRST_HEADING_LINE" "$CHANGELOG"
  } > "$TMP"
  mv "$TMP" "$CHANGELOG"
fi

"$SCRIPT_DIR/check_version_sync.sh"

echo
echo "bump_version: done. Write real release notes in CHANGELOG.md under '## $TARGET' before CI will pass."

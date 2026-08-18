#!/bin/bash
# One-time backfill: publishes GitHub Releases for the Godot SDK tags that
# predate the release-publishing pipeline (godot_sdk_tag.yml's `release`
# job). Run locally once, after that job has merged, with `gh` authed
# against an account that can push releases to isopod-fractal-analytics/godot-sdk.
#
# For each tag, builds the zip with *this* checkout's (HEAD's) ZipBuilder
# not the tag's own controller code, pointed at a worktree of that tag, so
# the backfilled assets get today's bugfixes (unix-perms preservation, entry
# naming) rather than reproducing old bugs. The one thing that DOES vary per
# tag is the shipped-files allowlist: v2.x tags shipped the whole addons/
# tree (no SHIPPED_ADDON_GLOBS allowlist existed yet), so those two use
# globs: ["**/*"] to faithfully reproduce what those tags actually served.
#
# Idempotent: skips any tag that already has a release published.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO="isopod-fractal-analytics/godot-sdk"

cd "$ROOT_DIR"

# tag:globs, globs is "default" to use GodotSdk::ZipBuilder::SHIPPED_ADDON_GLOBS,
# or a Ruby array literal to override.
TAGS=(
  "godot-sdk/v2.0.0:2.0.0:whole_tree"
  "godot-sdk/v2.0.1:2.0.1:whole_tree"
  "godot-sdk/v3.0.0:3.0.0:default"
  "godot-sdk/v3.0.1:3.0.1:default"
)

for entry in "${TAGS[@]}"; do
  IFS=":" read -r TAG VERSION MODE <<< "$entry"

  RELEASE_TAG="v$VERSION"
  ASSET="fractal-analytics-godot-$VERSION.zip"

  if gh release view "$RELEASE_TAG" -R "$REPO" > /dev/null 2>&1; then
    echo "== $RELEASE_TAG already released, skipping =="
    continue
  fi

  echo "== Building $RELEASE_TAG from $TAG (mode: $MODE) =="

  WORKTREE_DIR="$(mktemp -d)"
  git worktree add --detach "$WORKTREE_DIR" "$TAG" > /dev/null

  BUILD_SCRIPT=$(mktemp)
  if [ "$MODE" = "whole_tree" ]; then
    cat > "$BUILD_SCRIPT" <<'RUBY'
require "./lib/godot_sdk/zip_builder"
sdk_root = ARGV[0]
output = ARGV[1]
zip_data = GodotSdk::ZipBuilder.build(sdk_root, globs: ["**/*"])
File.binwrite(output, zip_data.read)
RUBY
  else
    cat > "$BUILD_SCRIPT" <<'RUBY'
require "./lib/godot_sdk/zip_builder"
sdk_root = ARGV[0]
output = ARGV[1]
zip_data = GodotSdk::ZipBuilder.build(sdk_root)
File.binwrite(output, zip_data.read)
RUBY
  fi

  bundle exec ruby "$BUILD_SCRIPT" "$WORKTREE_DIR/sdks/godot" "$ROOT_DIR/$ASSET"
  rm -f "$BUILD_SCRIPT"
  git worktree remove --force "$WORKTREE_DIR"

  echo "== Publishing $RELEASE_TAG =="
  gh release create "$RELEASE_TAG" "$ASSET" -R "$REPO" \
    --target main \
    --title "Godot SDK v$VERSION" \
    --notes "Built from monorepo tag $TAG (backfilled $(date -u +%Y-%m-%d))."

  rm -f "$ASSET"
done

echo "Backfill complete."

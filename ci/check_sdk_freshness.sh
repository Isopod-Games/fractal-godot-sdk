#!/bin/bash
# CI-enforced Godot SDK version freshness: native binary staleness +
# version-bump enforcement. See fractal_freshness_check in version_lib.sh
# for the four rules. Run from anywhere; paths resolve relative to this
# script and to the repo root.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"

fail() {
  echo "check_sdk_freshness: $1" >&2
  exit 1
}

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "check_sdk_freshness: not inside a git worktree, skipping"
  exit 0
fi

cd "$REPO_ROOT"

# shellcheck source=./native_paths.sh
source "$ROOT_DIR/ci/native_paths.sh"
# shellcheck source=./version_lib.sh
source "$ROOT_DIR/ci/version_lib.sh"

BASE_REF="${FRACTAL_BASE_REF:-origin/main}"
if ! git rev-parse --verify --quiet "$BASE_REF" > /dev/null; then
  fail "cannot resolve '$BASE_REF', run 'git fetch origin main' first"
fi

BASE="$(git merge-base HEAD "$BASE_REF")"

if [ -n "$(git status --porcelain -- sdks/godot 2>/dev/null)" ]; then
  DIRTY_SHIPPED="$(git status --porcelain -- sdks/godot | awk '{print $2}' | grep -E "$FRACTAL_SDK_SHIPPED_PATHS_REGEX|$FRACTAL_NATIVE_PATHS_REGEX|$FRACTAL_NATIVE_BIN_REGEX" || true)"
  if [ -n "$DIRTY_SHIPPED" ]; then
    echo "check_sdk_freshness: WARNING, uncommitted changes touch native/shipped paths (these rules only see commits):" >&2
    echo "$DIRTY_SHIPPED" | sed 's/^/    /' >&2
  fi
fi

fractal_freshness_check "$BASE" HEAD

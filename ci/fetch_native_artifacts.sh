#!/bin/bash
# Downloads the three per-platform native_build.yml artifacts for the
# current branch's latest successful run, stages them into
# addons/fractal_native/bin/<target>/, and bumps each platform's
# NATIVE_BINARY_VERSIONS entry to match VERSION. Never commits — prints the
# suggested `git add`/`git commit` for the developer to run themselves.
#
# The cross-platform matrix (native_build.yml) is optional now — a local
# build (build_local.sh) is sufficient for the platform you're on. Use this
# script when you want to backfill the other two platforms' binaries too
# (e.g. before a release), not as a required step for every native change.
#
# Usage: fetch_native_artifacts.sh [--run-id <id>]
#
# Guards against the build-order trap: a native_build run only proves the
# binaries match the source *at the commit it built*. If VERSION was bumped
# or native source changed again after that commit, the fetched binaries
# would silently claim a version they don't match. Refuses unless the run's
# head commit has the same VERSION as the working tree and no native source
# changed between the run's commit and HEAD.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=./native_paths.sh
source "$ROOT_DIR/ci/native_paths.sh"

fail() {
  echo "fetch_native_artifacts: $1" >&2
  exit 1
}

RUN_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

gh auth status > /dev/null 2>&1 || fail "gh is not authenticated — run 'gh auth login'"

if [ -z "$RUN_ID" ]; then
  BRANCH="$(git branch --show-current)"
  [ -n "$BRANCH" ] || fail "detached HEAD — pass --run-id explicitly"

  RUN_ID="$(gh run list --workflow=native_build.yml --branch "$BRANCH" \
    --status success --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
  [ -n "$RUN_ID" ] || fail "no successful native_build.yml run found for branch '$BRANCH' — push and let it run first, or pass --run-id"
fi

RUN_SHA="$(gh run view "$RUN_ID" --json headSha -q '.headSha' 2>/dev/null || true)"
[ -n "$RUN_SHA" ] || fail "could not resolve headSha for run #$RUN_ID"

WORKING_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
RUN_VERSION="$(git show "$RUN_SHA:sdks/godot/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"

if [ "$RUN_VERSION" != "$WORKING_VERSION" ]; then
  fail "run #$RUN_ID built VERSION $RUN_VERSION, working tree is at $WORKING_VERSION. Bump first, push, let native_build.yml rebuild, then fetch."
fi

NATIVE_CHANGED_SINCE_RUN="$(git diff --name-only "$RUN_SHA..HEAD" 2>/dev/null | grep -E "$FRACTAL_NATIVE_PATHS_REGEX" || true)"
if [ -n "$NATIVE_CHANGED_SINCE_RUN" ]; then
  {
    echo "run #$RUN_ID's binaries are stale — native source changed since it built:"
    echo "$NATIVE_CHANGED_SINCE_RUN" | sed 's/^/    /'
    echo "Bump first, push, let native_build.yml rebuild, then fetch."
  } >&2
  exit 1
fi

echo "fetch_native_artifacts: using run #$RUN_ID (headSha $RUN_SHA, VERSION $RUN_VERSION)"

ARTIFACT_DIR="$(mktemp -d)"
trap 'rm -rf "$ARTIFACT_DIR"' EXIT

VERSION_GD="$ROOT_DIR/addons/fractal/core/version.gd"
for target in "${FRACTAL_NATIVE_PLATFORM_KEYS[@]}"; do
  gh run download "$RUN_ID" --name "fractal_native-$target" --dir "$ARTIFACT_DIR/$target"
  mkdir -p "$ROOT_DIR/addons/fractal_native/bin/$target"
  cp "$ARTIFACT_DIR/$target"/* "$ROOT_DIR/addons/fractal_native/bin/$target/"
  find "$ROOT_DIR/addons/fractal_native/bin/$target" -name "crashpad_handler*" -exec chmod +x {} \;

  sed -i.bak "s/\"$target\": \"[^\"]*\"/\"$target\": \"$WORKING_VERSION\"/" "$VERSION_GD"
  rm -f "$VERSION_GD.bak"
done

echo
echo "fetch_native_artifacts: staged. Review, then:"
echo "  git add sdks/godot/addons/fractal_native/bin sdks/godot/addons/fractal/core/version.gd"
echo "  git commit -m \"Rebuild Godot SDK native binaries for v$WORKING_VERSION\""

#!/bin/bash
# Dispatches the native_build matrix on GitHub when native source has changed
# relative to main. Waits for the run to complete (~45 min when triggered),
# then offers to run fetch_native_artifacts.sh to stage the binaries and bump
# each platform's NATIVE_BINARY_VERSIONS entry, still doesn't commit; that's
# on you.
#
# Optional: a local build (build_local.sh, run via FRACTAL_BUILD_NATIVE=1
# bin/ci) is sufficient for check_sdk_freshness.sh on the platform you're on.
# Use this to additionally backfill the other two platforms.
# Skips silently when nothing in the native addon has changed.
#
# Usage: dispatch_matrix.sh [--yes]
#   --yes   skip the post-build fetch prompt, fetch automatically
set -euo pipefail

YES=false
for arg in "$@"; do
  [ "$arg" = "--yes" ] && YES=true
done

# shellcheck source=../../ci/native_paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../ci" && pwd)/native_paths.sh"

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../ci" && pwd)"

BRANCH=$(git branch --show-current)

CHANGED=$(git diff --name-only "origin/main...HEAD" 2>/dev/null \
  | grep -E "$FRACTAL_NATIVE_PATHS_REGEX" \
  || true)

if [ -z "$CHANGED" ]; then
  echo "Skipped, no native source changes relative to main"
  exit 0
fi

echo "==> Native source changed, dispatching matrix build on GitHub (branch: $BRANCH)..."
gh workflow run native_build.yml --ref "$BRANCH"

# Poll until GitHub registers the new run (usually a few seconds)
RUN_ID=""
for i in $(seq 1 12); do
  sleep 5
  RUN_ID=$(gh run list --workflow=native_build.yml --branch "$BRANCH" \
    --limit 1 --json databaseId,status \
    -q '.[] | select(.status != "completed") | .databaseId' 2>/dev/null || true)
  [ -n "$RUN_ID" ] && break
done

if [ -z "$RUN_ID" ]; then
  echo "ERROR: could not find dispatched run, check GitHub Actions tab" >&2
  exit 1
fi

echo "Run #$RUN_ID queued, waiting for completion (~45 min)..."
gh run watch "$RUN_ID" --exit-status
echo "Matrix build passed."

FETCH=true
if [ "$YES" != true ]; then
  read -r -p "Fetch and stage binaries now? [Y/n] " REPLY
  [[ "$REPLY" =~ ^[Nn] ]] && FETCH=false
fi

if [ "$FETCH" = true ]; then
  "$CI_DIR/fetch_native_artifacts.sh" --run-id "$RUN_ID"
else
  echo "Skipped fetch, run manually later with:"
  echo "  sdks/godot/ci/fetch_native_artifacts.sh --run-id $RUN_ID"
fi

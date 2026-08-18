#!/bin/bash
# Headless Godot test runner for the Fractal SDK.
#
# Usage:
#   ./ci/godot_tests.sh                                 # default: unit + integration
#   ./ci/godot_tests.sh res://tests/e2e                 # specific paths
#   GODOT_BIN=/path/to/godot ./ci/godot_tests.sh        # override binary
set -euo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"

if ! command -v "$GODOT_BIN" > /dev/null 2>&1 && [ ! -x "$GODOT_BIN" ]; then
  for candidate in /opt/godot/godot "$HOME/.local/bin/godot" "$HOME/godot/godot"; do
    if [ -x "$candidate" ]; then
      GODOT_BIN="$candidate"
      break
    fi
  done
fi

# Resolve to project root (one level up from this script).
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Default test paths if none supplied.
if [ "$#" -eq 0 ]; then
    SUITES=(-a res://tests/unit -a res://tests/integration)
else
    SUITES=()
    for arg in "$@"; do
        SUITES+=(-a "$arg")
    done
fi

cd "$PROJECT_DIR"

# Make sure imports are up-to-date so script types resolve before discovery.
"$GODOT_BIN" --headless --path . --import || true

# AnalyticsGlue (the test_game autoload) self-configures a live Fractal
# singleton on _ready() unless FRACTAL_CI_MODE is set, see
# test_game/scripts/analytics_glue.gd. Without this, that singleton runs
# for the entire headless test session, retrying real network requests
# against an unreachable localhost collector and read/writing the same
# shared `user://fractal` persistence root that every gdUnit test suite's
# own fresh Errors/Analytics instances use, racing with them and causing
# intermittent cross-suite failures/crashes.
export FRACTAL_CI_MODE=1

exec "$GODOT_BIN" --headless --path . \
    -d -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd \
    --ignoreHeadlessMode \
    "${SUITES[@]}" \
    -c

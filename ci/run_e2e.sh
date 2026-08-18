#!/bin/bash
# Local E2E integration runner for the Fractal Godot SDK.
#
# Expects ClickHouse and Postgres to already be running (bin/ci starts them
# in earlier steps). Builds the Go collector, starts a Rails test server on
# port 3099 and the collector on port 8099, drives the Godot SDK through
# normal + crash-replay phases, then asserts event counts in ClickHouse.
#
# Ports 3099 and 8099 are chosen to avoid conflicts with dev services:
#   - Grafana maps to host port 3002 in docker-compose.yml
#   - The dev collector runs on port 8080 (collector/.env)
#
# If the native GDExtension lib is present for the current platform the
# native crash-replay phases (native_crash + native_verify) also run.
#
# Env overrides:
#   GODOT_BIN              path to Godot 4.x headless binary (default: godot)
#   CLICKHOUSE_USER        (default: fractal)
#   CLICKHOUSE_PASSWORD    (default: password)
#   CLICKHOUSE_PORT        HTTP port used for assertions (default: 8123)
#   CLICKHOUSE_TCP_PORT    native port used by the collector (default: 9000)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SDK_DIR="$REPO_ROOT/sdks/godot"
COLLECTOR_BIN=/tmp/fractal-e2e-collector
RAILS_PORT=3099
COLLECTOR_PORT=8099
METRICS_PORT=9191

CH_USER="${CLICKHOUSE_USER:-fractal}"
CH_PASS="${CLICKHOUSE_PASSWORD:-password}"
CH_HTTP="${CLICKHOUSE_PORT:-8123}"
CH_TCP="${CLICKHOUSE_TCP_PORT:-9000}"
CH_DB=fractal_clickhouse_test

GODOT_BIN="${GODOT_BIN:-godot}"

# ── Resolve Godot binary ────────────────────────────────────────────────────
if ! command -v "$GODOT_BIN" >/dev/null 2>&1 && [ ! -x "$GODOT_BIN" ]; then
  for candidate in /opt/godot/godot "$HOME/.local/bin/godot" "$HOME/godot/godot"; do
    if [ -x "$candidate" ]; then
      GODOT_BIN="$candidate"
      break
    fi
  done
fi
if ! command -v "$GODOT_BIN" >/dev/null 2>&1 && [ ! -x "$GODOT_BIN" ]; then
  echo "ERROR: Godot binary not found. Install Godot 4 and set GODOT_BIN, or add godot to PATH." >&2
  exit 1
fi

# ── Cleanup on exit ─────────────────────────────────────────────────────────
RAILS_PID=""
COLLECTOR_PID=""
cleanup() {
  [ -n "$COLLECTOR_PID" ] && kill "$COLLECTOR_PID" 2>/dev/null || true
  [ -n "$RAILS_PID" ]    && kill "$RAILS_PID"    2>/dev/null || true
  # Wait for the tracked launcher PIDs to exit. This is NOT sufficient on its
  # own: `bin/rails server` launches Puma as a separate process that outlives
  # the launcher and gets reparented (PPID 1), so RAILS_PID/COLLECTOR_PID can
  # exit while the real server is still alive and holding a DB connection.
  [ -n "$COLLECTOR_PID" ] && wait "$COLLECTOR_PID" 2>/dev/null || true
  [ -n "$RAILS_PID" ]    && wait "$RAILS_PID"    2>/dev/null || true
  # Kill whatever is actually still bound to our ports (the orphaned Puma
  # process described above), same defensive pattern used before startup.
  fuser -k "${RAILS_PORT}/tcp" 2>/dev/null || true
  fuser -k "${COLLECTOR_PORT}/tcp" 2>/dev/null || true
  sleep 1
  # Reset the test DB so e2e seed data does not pollute the unit/request
  # test suite that runs afterwards in CI (or locally). Postgres can take a
  # moment to reap the just-killed backends, so db:test:prepare can
  # transiently fail with "database is being accessed by other users"
  # retry instead of silently swallowing it, or the unit/request suite
  # inherits stale committed e2e data on its next run.
  for attempt in 1 2 3 4 5; do
    (cd "$REPO_ROOT" && RAILS_ENV=test bin/rails db:test:prepare) 2>/tmp/fractal-e2e-cleanup.log && exit_status=0 && break
    exit_status=$?
    sleep 1
  done
  if [ "$exit_status" -ne 0 ]; then
    echo "ERROR: db:test:prepare failed after retries during e2e cleanup, test DB may still hold e2e data:" >&2
    cat /tmp/fractal-e2e-cleanup.log >&2
    exit 1
  fi
}
trap cleanup EXIT

# ── 1. Build Go collector ────────────────────────────────────────────────────
echo "==> Building collector..."
(cd "$REPO_ROOT/collector" && go build -o "$COLLECTOR_BIN" ./cmd/main.go)

# ── 2. Prepare test DB + seed e2e data ──────────────────────────────────────
# Defensively kill anything still bound to our ports first. If a previous run
# was killed before its EXIT trap could fire (e.g. interrupted mid-flight),
# its Rails/collector process keeps running and holds a Postgres connection
# open against fractal_test, which makes db:test:prepare fail with
# "database is being accessed by other users".
echo "==> Clearing stale processes on ports $RAILS_PORT/$COLLECTOR_PORT..."
fuser -k "${RAILS_PORT}/tcp" 2>/dev/null || true
fuser -k "${COLLECTOR_PORT}/tcp" 2>/dev/null || true
sleep 1
echo "==> Preparing test databases..."
(cd "$REPO_ROOT" && RAILS_ENV=test bin/rails db:test:prepare)
echo "==> Seeding e2e test data..."
(cd "$REPO_ROOT" && RAILS_ENV=test bin/rails runner sdks/godot/ci/e2e_seed.rb)

# ── 3. Start Rails test server on port 3002 ─────────────────────────────────
echo "==> Starting Rails test server on port $RAILS_PORT..."
(cd "$REPO_ROOT" && RAILS_ENV=test PUMA_CONTROL_PORT=9393 bin/rails server -p "$RAILS_PORT" -b 0.0.0.0 \
  > /tmp/fractal-e2e-rails.log 2>&1) &
RAILS_PID=$!
for i in $(seq 1 30); do
  if curl -sf "http://localhost:$RAILS_PORT/up" >/dev/null 2>&1; then
    echo "Rails ready"; break
  fi
  [ $i -eq 30 ] && { echo "ERROR: Rails test server did not start" >&2; exit 1; }
  sleep 2
done

# ── 4. Start Go collector on port 8099 ──────────────────────────────────────
echo "==> Starting collector on port $COLLECTOR_PORT..."
# Kill any stale process holding the collector or metrics ports before starting.
fuser -k "${COLLECTOR_PORT}/tcp" 2>/dev/null || true
fuser -k "${METRICS_PORT}/tcp"   2>/dev/null || true
DATABASE_URL="postgres:///fractal_test" \
CLICKHOUSE_HOST=localhost \
CLICKHOUSE_PORT="$CH_TCP" \
CLICKHOUSE_USER="$CH_USER" \
CLICKHOUSE_PASSWORD="$CH_PASS" \
CLICKHOUSE_DATABASE="$CH_DB" \
PORT="$COLLECTOR_PORT" METRICS_PORT="$METRICS_PORT" ALLOWED_ORIGINS='*' \
  "$COLLECTOR_BIN" > /tmp/fractal-e2e-collector.log 2>&1 &
COLLECTOR_PID=$!
for i in $(seq 1 30); do
  if curl -sf "http://localhost:$COLLECTOR_PORT/health" >/dev/null 2>&1; then
    echo "Collector ready"; break
  fi
  [ $i -eq 30 ] && { echo "ERROR: Collector did not start" >&2; cat /tmp/fractal-e2e-collector.log; exit 1; }
  sleep 1
done

E2E_ENV=(
  "FRACTAL_CI_MODE=1"
  "FRACTAL_API_KEY=ci-e2e-fixed-api-key"
  "FRACTAL_COLLECTOR=http://localhost:$COLLECTOR_PORT"
  "FRACTAL_API=http://localhost:$RAILS_PORT"
)

run_driver() {
  local mode="$1"
  env "${E2E_ENV[@]}" FRACTAL_DRIVE_MODE="$mode" \
    "$GODOT_BIN" --headless res://tests/e2e/live_integration_drive.tscn
}

# ── 5. Normal phase ──────────────────────────────────────────────────────────
echo "==> Godot e2e: normal mode..."
(cd "$SDK_DIR" && run_driver normal)

# ── 6. Crash-replay phase 1: SIGKILL mid-session ─────────────────────────────
echo "==> Godot e2e: crash (SIGKILL) mode..."
(cd "$SDK_DIR" && run_driver crash || true)

SESSION_MARKER="$HOME/.local/share/godot/app_userdata/Fractal SDK Workspace/fractal/session.json"
if [ ! -f "$SESSION_MARKER" ] || ! grep -q '"clean":false' "$SESSION_MARKER"; then
  echo "ERROR: expected unclean session marker at $SESSION_MARKER" >&2
  ls -la "$(dirname "$SESSION_MARKER")" 2>/dev/null || true
  exit 1
fi
echo "Crash phase 1 OK, unclean marker on disk"

# ── 7. Crash-replay phase 2: relaunch + verify AbnormalShutdown ─────────────
echo "==> Godot e2e: verify_replay mode..."
(cd "$SDK_DIR" && run_driver verify_replay)

# ── 8. Native crash phases (only if the lib is built for this platform) ───────
UNAME="$(uname -s)"
MACHINE="$(uname -m)"
case "$UNAME" in
  Linux*)  PLATFORM=linux  ;;
  Darwin*) PLATFORM=macos  ;;
  *)       PLATFORM=unknown ;;
esac
case "$MACHINE" in
  x86_64)        ARCH=x86_64 ;;
  arm64|aarch64) ARCH=arm64  ;;
  *)             ARCH=unknown ;;
esac

NATIVE_LIB="$SDK_DIR/addons/fractal_native/bin/$PLATFORM-$ARCH"
if ls "$NATIVE_LIB"/libfractal_native.* >/dev/null 2>&1 || ls "$NATIVE_LIB"/fractal_native.dll >/dev/null 2>&1; then
  echo "==> Godot e2e: native_crash mode (lib found at $NATIVE_LIB)..."
  # timeout 30: on WSL2 the Godot process can spin in its crash handler after
  # Crashpad writes the minidump and never self-terminate. The dump is written
  # within ~1 s; 30 s gives ample margin before we forcibly kill the process.
  # timeout cannot call bash functions, so we inline the Godot invocation.
  (cd "$SDK_DIR" && timeout 30 \
    env "${E2E_ENV[@]}" FRACTAL_DRIVE_MODE=native_crash \
    "$GODOT_BIN" --headless res://tests/e2e/live_integration_drive.tscn || true)

  DUMP_DIR="$HOME/.local/share/godot/app_userdata/Fractal SDK Workspace/fractal/minidumps"
  # Use find -print0 + while read to handle the spaces in "Fractal SDK Workspace".
  DUMP_FOUND=0
  while IFS= read -r -d '' d; do
    sz=$(wc -c < "$d")
    echo "minidump: $d ($sz bytes)"
    [ "$sz" -ge 4096 ] || { echo "ERROR: minidump too small ($sz bytes)" >&2; exit 1; }
    DUMP_FOUND=1
  done < <(find "$DUMP_DIR" -name "*.dmp" -print0 2>/dev/null)
  [ "$DUMP_FOUND" -eq 1 ] || { echo "ERROR: no minidump written under $DUMP_DIR" >&2; exit 1; }
  echo "Native phase 1 OK"

  # Kill any crashpad_handler left over from the native_crash phase and remove
  # its stale .run.lock. On WSL2 the lock file persists after the handler dies;
  # sentry_init in the next launch spin-loops if it finds the file present.
  pkill -f "crashpad_handler" 2>/dev/null || true
  sleep 1
  find "$DUMP_DIR" -name "*.run.lock" -delete 2>/dev/null || true

  echo "==> Godot e2e: native_verify mode..."
  (cd "$SDK_DIR" && run_driver native_verify)
else
  echo "Skipping native crash phases, lib not found at $NATIVE_LIB (run with FRACTAL_BUILD_NATIVE=1 to build it)"
fi

# ── 9. Assert ClickHouse event counts ────────────────────────────────────────
echo "==> Asserting ClickHouse results..."
sleep 3

ch_query() {
  curl -sf -u "${CH_USER}:${CH_PASS}" \
    --data-binary "$1" \
    "http://localhost:${CH_HTTP}/?database=${CH_DB}"
}

ci_clicks=$(ch_query "SELECT count() FROM analytics_events WHERE event_type = 'ci_click'")
shop_opens=$(ch_query "SELECT count() FROM analytics_events WHERE event_type = 'ci_shop_open'")
purchases=$(ch_query "SELECT count() FROM analytics_events WHERE event_type = 'ci_item_purchased'")
ci_errors=$(ch_query "SELECT count() FROM error_events WHERE error_type = 'CIIntegrationError' AND player_id_str = 'ci_drive_player'")
abnormal=$(ch_query "SELECT count() FROM error_events WHERE error_type = 'AbnormalShutdown' AND player_id_str = 'ci_drive_player'")

echo "ci_click:           $ci_clicks  (expected >= 12)"
echo "ci_shop_open:       $shop_opens (expected >= 1)"
echo "ci_item_purchased:  $purchases  (expected >= 1)"
echo "CIIntegrationError: $ci_errors  (expected >= 1, player_id_str = ci_drive_player)"
echo "AbnormalShutdown:   $abnormal   (expected >= 1, player_id_str = ci_drive_player)"

if ls "$NATIVE_LIB"/libfractal_native.* >/dev/null 2>&1 || ls "$NATIVE_LIB"/fractal_native.dll >/dev/null 2>&1; then
  native_crash=$(ch_query "SELECT count() FROM error_events WHERE error_type = 'NativeCrash' AND player_id_str = 'ci_drive_player'")
  echo "NativeCrash:        $native_crash (expected >= 1, player_id_str = ci_drive_player)"
fi

[ "$ci_clicks"  -ge 12 ] || { echo "FAIL: insufficient ci_clicks"             >&2; exit 1; }
[ "$shop_opens" -ge 1  ] || { echo "FAIL: ci_shop_open missing"               >&2; exit 1; }
[ "$purchases"  -ge 1  ] || { echo "FAIL: ci_item_purchased missing"          >&2; exit 1; }
[ "$ci_errors"  -ge 1  ] || { echo "FAIL: CIIntegrationError missing or unattributed" >&2; exit 1; }
[ "$abnormal"   -ge 1  ] || { echo "FAIL: AbnormalShutdown missing or unattributed"   >&2; exit 1; }

if ls "$NATIVE_LIB"/libfractal_native.* >/dev/null 2>&1 || ls "$NATIVE_LIB"/fractal_native.dll >/dev/null 2>&1; then
  [ "${native_crash:-0}" -ge 1 ] || { echo "FAIL: NativeCrash missing or unattributed" >&2; exit 1; }
fi

echo "All e2e assertions passed."

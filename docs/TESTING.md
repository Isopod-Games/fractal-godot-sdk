# Testing

Tests live under `tests/` and run against vendored gdUnit4 (`addons/gdUnit4/`). The suite is split into three tiers:

- **`tests/unit/`** — fast, no I/O. Cover individual classes (event queue, persistence, breadcrumbs, config, platform detection, translation loader).
- **`tests/integration/`** — spin up an in-process HTTP mock server (`tests/integration/mock_server.gd`) and exercise full subsystem flows: analytics batch posting, error capture, translations sync with ETag/304/cache-fallback paths.
- **`tests/e2e/`** — load the test game scenes via gdUnit4's `scene_runner`, simulate button presses, assert the SDK observed the right events.

## Running locally

```bash
# All tiers
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  -d -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd \
  --ignoreHeadlessMode \
  -a res://tests/unit -a res://tests/integration -a res://tests/e2e -c

# Just unit tests (fastest)
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  -d -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd \
  --ignoreHeadlessMode \
  -a res://tests/unit
```

The `--ignoreHeadlessMode` flag is required because gdUnit4 (correctly) warns that input events don't propagate in headless mode. Our tests trigger UI by emitting `Button.pressed` directly rather than synthesizing `InputEvent`s, so the warning is harmless.

The `-c` (continue) flag tells gdUnit4 to keep running tests after a failure. Without it, the first failure aborts the run (fail-fast).

`gdUnit4` writes per-run reports under `reports/report_N/` (HTML + XML). Files are gitignored.

## Convenience script

`ci/godot_tests.sh` wraps the headless invocation:

```bash
./ci/godot_tests.sh                       # default: unit + integration
./ci/godot_tests.sh res://tests/e2e       # specific path
```

Set `GODOT_BIN=/path/to/Godot` to use a different binary.

## Mock HTTP server

`tests/integration/mock_server.gd` implements just enough HTTP/1.1 to satisfy the SDK:

```gdscript
var server := preload("res://tests/integration/mock_server.gd").new()
add_child(server)
server.start()
server.enqueue_response("POST", "/v1/batch", 202, "{}")
# ... point Fractal at server.url() ...
# Inspect `server.requests` to assert what was sent.
```

It's not a general-purpose server — it parses one request per connection, sends a pre-canned response, and uses `put_partial_data` + a deferred disconnect so Godot's `HTTPRequest` cleanly reads the response before the socket closes. Keep its scope minimal.

## A gotcha: signals + gdUnit4's `assert_signal`

We observed that gdUnit4 v6.1.3's `assert_signal(...).is_emitted(...)` can miss signals emitted from synchronously-chained callbacks (e.g., `HTTPRequest.request_completed` → analytics's `_on_request_completed` → `batch_sent.emit`). The integration tests connect directly to the signal and poll an array instead:

```gdscript
var results: Array = []
my_node.batch_sent.connect(func(n): results.append(n))
# ... drive the action ...
var ok := await FractalTestHelpersClass.wait_for(
    get_tree(), func(): return not results.is_empty(), 5000,
)
assert_bool(ok).is_true()
```

This pattern lives in `tests/helpers/test_helpers.gd` (`wait_for`) and is reused across integration and e2e suites.

## Test counts

| Tier | Count |
| --- | --- |
| Unit (`tests/unit/`) | 84 |
| Integration (`tests/integration/`) | 25 |
| E2E (`tests/e2e/test_test_game.gd`) | 3 |
| **Total SDK tests** | **112** |

Backend Go tests cover the minidump endpoint, the symbol upload endpoint, and the inline symbolicator (15 cases across `minidump_handler_test.go`, `symbols_handler_test.go`, `symbolicator_test.go`). Plus 8 rspec cases for the Rails translations endpoint.

## E2E driver modes

`tests/e2e/live_integration_drive.gd` is the headless driver `ci/run_e2e.sh` uses against the full Postgres + ClickHouse + Rails + collector stack. Behavior is selected via env var:

| `FRACTAL_DRIVE_MODE` | Behavior |
| --- | --- |
| `normal` (default) | Fires 12 clicks + shop_open + item_purchased + 1 warning error + a translations sync. Asserts via signals that batches/errors/syncs were acknowledged; CI then queries ClickHouse for row counts. |
| `crash` | Configures the SDK with the session marker enabled, writes one breadcrumb, then `OS.kill(OS.get_process_id())`. Process exits with SIGKILL leaving an unclean `session.json`. CI's next step asserts `clean: false` is in the marker file. |
| `verify_replay` | Fresh process. `configure()` finds the unclean marker from the previous pass, emits an `AbnormalShutdown` event to `/v1/errors`, asserts via `error_sent` that the POST landed, exits 0. |

`run_e2e.sh` chains `normal → crash → verify_replay` and finishes by querying ClickHouse for `count() FROM error_events WHERE error_type = 'AbnormalShutdown' AND player_id_str = 'ci_drive_player' >= 1` — catching any regression in the heartbeat, replay, or player-attribution paths.

## Backend specs

```bash
# Translations sync endpoint (rspec)
bundle exec rspec spec/requests/api/v1/translations/sync_spec.rb

# Minidump endpoint, symbol upload, symbolicator (Go)
cd collector && go test -v ./internal/ingest/
```

Both require Postgres + ClickHouse running and the test data seeded via `bin/rails runner ci/e2e_seed.rb`.

(Requires the Rails master key + ClickHouse running locally; see project README.)

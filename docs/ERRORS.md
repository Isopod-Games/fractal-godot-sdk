# Errors — `Fractal.errors`

Sentry-like error capture. Errors are POSTed to `{collector_url}/v1/errors` with breadcrumbs, severity, user/tag/context. The submission is **retry-safe across launches** (persisted error queue), and crashes — including SIGSEGV, OOM, force-quit, and any non-graceful exit — produce a synthetic `AbnormalShutdown` event on the next launch via a session-marker heartbeat.

The wire protocol and on-disk schemas are documented as a cross-engine spec at [[CRASH_PROTOCOL.md](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md)](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md). Future Unity/Unreal SDKs implement against the same contract.

When `errors_enabled = false`, every method is a no-op.

## What we catch

| Crash class | Mechanism | Stack trace? |
| --- | --- | --- |
| `OS.crash("...")` (explicit) | NOTIFICATION_CRASH → `crash_report.json` → next-launch replay as `UnhandledCrash` | yes (engine-side breadcrumbs) |
| GDScript runtime error (null deref, divide-by-zero) | auto-captured via live log tailing — see [Layer 4](#layer-4-live-log-tailing--scripterror) — reported as `ScriptError` with no `capture_error(...)` call needed. If it kills the process instead, the heartbeat path also catches it as `AbnormalShutdown` with log-scraper enrichment | auto (live tail) |
| Native segfault (SIGSEGV / SIGABRT / SIGBUS) | heartbeat path → `AbnormalShutdown` (Phase A) **or** Phase B native GDExtension produces a true minidump (planned) | log-scrape (Phase A) / full minidump (Phase B) |
| OOM-kill / kill -9 / force-quit | heartbeat path → `AbnormalShutdown` | best-effort |
| Graceful exit (Cmd+Q, window close) | NOTIFICATION_WM_CLOSE_REQUEST → marks session clean → no false-positive next launch | n/a |

## API

```gdscript
# Capture a handled error.
Fractal.errors.capture_error(error_type: String, message: String, opts: Dictionary = {}) -> void
# opts:
#   severity: String   # "fatal" | "error" | "warning" | "info"   (default "error")
#   handled: bool                                                  (default true)
#   stack_trace: String
#   extra: Dictionary                                              # arbitrary context
#   tags: Dictionary                                               # filterable tags

# Capture a free-form message at a given severity.
Fractal.errors.capture_message(message: String, severity := "info") -> void

# Add a breadcrumb (included with the next error).
Fractal.errors.add_breadcrumb(message: String, category := "default", level := "info", data := {}) -> void

# User / tag / context — applied to every subsequent error.
Fractal.errors.set_user(id: String, opts := {}) -> void
Fractal.errors.set_tag(key: String, value) -> void
Fractal.errors.set_context(key: String, value: Dictionary) -> void
Fractal.errors.set_release(version: String) -> void
Fractal.errors.set_environment(env: String) -> void

Fractal.errors.is_enabled() -> bool
```

### Signals

```gdscript
signal error_captured(error_type: String)
signal error_sent
signal error_failed(message: String)
```

## Crash replay (three layers)

The SDK has three independent layers, each catching crashes the others can't.

### Layer 1: NOTIFICATION_CRASH → `UnhandledCrash`

When Godot fires `NOTIFICATION_CRASH` (programmatic `OS.crash()` and some engine-side fatals), the SDK writes a synchronous crash report to `user://fractal/crash_report.json` with the active breadcrumbs, user/tag/context, and platform info. On the next launch, `configure()` reads the file, posts an `UnhandledCrash` (`severity: fatal`, `handled: false`), then deletes it. This handler is tiny — synchronous file I/O only — since the engine is already in its death throes.

### Layer 2: heartbeat session marker → `AbnormalShutdown`

Layer 1 only catches crashes that fire `NOTIFICATION_CRASH`. Real native crashes (SIGSEGV, OOM-kill, kill -9, force-quit) bypass it entirely. So the SDK also writes a session marker to `user://fractal/session.json` and ticks it every `errors_heartbeat_interval_s` (default 10s) with a fresh `last_heartbeat_at` and the current breadcrumb buffer. On graceful shutdown the marker flips `clean: true`. On the **next launch**, `configure()` checks for a previous marker — if it exists with `clean: false`, that's an abnormal shutdown.

The synthetic event produced is `AbnormalShutdown` (`severity: fatal`, `handled: false`) with all the breadcrumbs/user/tags from the dead session. We also try a best-effort stack-trace enrichment by scraping Godot's own log file at `OS.get_user_data_dir()/logs/` for the last `SCRIPT ERROR:` / `ERROR:` block.

Toggle: `errors_session_marker_enabled` (default `true`). Disable for tests where you don't want the heartbeat timer running, or for environments where you handle crashes another way.

### Layer 3: persistent error queue (retry-safe submission)

Every error is **persisted to disk before** the HTTP POST attempts. On 2xx response, the queue is cleared. On any failure (4xx, 5xx, network), the queue stays — the next launch's `configure()` drains and retries it. This means crashes that happen during error submission don't lose data. File: `user://fractal/errors_queue.json`. Cap: 100 entries (FIFO drop).

### Layer 4: live log tailing → `ScriptError`

Non-fatal GDScript runtime errors (null deref, divide-by-zero, etc.) don't kill the process — Godot just logs an `ERROR:` / `SCRIPT ERROR:` / `CRITICAL:` block and keeps running — so they're invisible to Layers 1–2. The SDK tails the **current session's** log file on the existing heartbeat (no second timer) and auto-reports new error blocks as `ScriptError` events (`severity: error`, `handled: false`, `tags.capture_method: "live_log"`), with no `capture_error(...)` call needed.

**Prerequisite:** `debug/file_logging/enable_file_logging` must be on in Project Settings — without it there's no log file to tail. If it's off while `errors_live_log_capture_enabled` is true, the SDK logs a local `push_error` (not sent to Fractal, so it won't show up in your dashboard — check the Godot console/output log) with the exact setting path to enable, and disables live capture for the session. `capture_error(...)` and crash capture (Layers 1–3) are unaffected.

**Repeat throttling:** an error firing every frame would overrun the local 100-entry error queue and blow the collector's rate limit. So the SDK groups blocks by signature (message + stack trace) within each heartbeat window and sends **one event per signature per heartbeat**, carrying `occurrence_count` — the number of real occurrences that one event represents *this window* (delta, not cumulative). The backend aggregates `sum(occurrence_count)` instead of `count()` so dashboard totals stay accurate even though the wire traffic is throttled. Every other event type omits `occurrence_count` and defaults to 1, so this is purely additive — it doesn't change counting for anything else.

**Visibility latency:** bounded by `errors_heartbeat_interval_s` (default 10s) — tune that if you need faster visibility.

**No double-reporting:** the live tailer's markers exclude `--- Debugger Break ---` and `handle_crash:` (Layer 1–2 territory), and its cursor starts at session-start EOF, so it never replays a previous session's log (that's the `AbnormalShutdown` next-launch scrape's job).

Toggle: `errors_live_log_capture_enabled` (default `true`, gated by `errors_enabled`).

### Phase B (planned): native minidumps

For studios that need real native crash capture with full register state and symbolicated stack traces, an optional `addons/fractal_native/` GDExtension wraps Crashpad. When present and `errors_native_enabled = true`, SIGSEGV/SIGABRT/SIGBUS produce a minidump that uploads to `/v1/minidumps` on next launch. See [[CRASH_PROTOCOL.md](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md)](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md) for the wire contract and bundled-binary plan.

## Auto-breadcrumbs

If you set `errors_auto_breadcrumb_scene_changes = true` in your config, the SDK adds a breadcrumb whenever `SceneTree.tree_changed` fires:

```
{"category": "navigation", "message": "scene_changed", "level": "info", "data": {"scene": "MainMenu"}}
```

## Coexistence with native Sentry GDExtensions

If your project already uses a native Sentry GDExtension (e.g., RogueRollers' `addons/sentry/`), `Fractal.errors` is a separate, additive channel — it ships errors to your Fractal backend instead of Sentry's. The two don't conflict:

- The Sentry GDExtension hooks low-level `OS.print_error` and uncaught crashes via crashpad.
- `Fractal.errors` handles `NOTIFICATION_CRASH` for replay-on-next-launch and exposes a clean `capture_error(...)` API.

Pick one or both. If you only want one, set `errors_enabled = false` to disable Fractal's channel.

## Error payload shape

```json
{
  "sent_at": "2026-04-29T10:00:00Z",
  "context": {"player_id": "godot_3fa85f64-5717-4562-b3fc-2c963f66afa6", "session_token": "sess_a1b2c3d4", "platform": "macos", "app_version": "1.0.0", "environment": "production"},
  "errors": [
    {
      "error_type": "NullReferenceException",
      "message": "shop item missing",
      "stack_trace": "at ShopController.purchase (line 42)",
      "severity": "error",
      "handled": true,
      "extra": {"item_id": 99},
      "breadcrumbs": [{"timestamp": "...", "category": "ui", "message": "clicked start", "level": "info"}],
      "tags": {"build": "release"},
      "timestamp": "2026-04-29T09:59:58Z",
      "user": {"id": "player-123"},
      "release": "1.0.0",
      "environment": "production"
    }
  ]
}
```

`context.player_id` is always populated — `Fractal.errors` resolves and persists its own player ID on `configure()` (shared with analytics via `FractalPersistence.resolve_player_id()`), so attribution works even when `analytics_enabled = false` or errors configures first. `context.session_token` is populated only when an analytics session is active (`Fractal.analytics.start_session()` has been called); otherwise it's `""`. Call `Fractal.errors.set_player_id(id)` to override the resolved ID for games that run errors without analytics.

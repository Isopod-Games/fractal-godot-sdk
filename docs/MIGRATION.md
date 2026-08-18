# Migration guide

## Migrating from v2 to v3

The backend dropped all roguelike-specific analytics (the roguelike controller, its endpoints, and roguelike widget types) in favor of a fully generic `event_aggregate` endpoint that queries event payloads dynamically. `Fractal.analytics.roguelike` was the one piece of the SDK still hardcoded to roguelike event shapes, and it added no wire-protocol value over calling `track()` directly, so v3 removes it. There is no other breaking change.

### Replace the roguelike helper calls

| v2 | v3 |
| --- | --- |
| `Fractal.analytics.roguelike.run_start(character)` | `Fractal.analytics.track("run_start", {"character": character})` |
| `Fractal.analytics.roguelike.floor_enter(floor_number)` | `Fractal.analytics.track("floor_enter", {"floor_number": floor_number})` |
| `Fractal.analytics.roguelike.enemy_kill(floor_number, enemy_type)` | `Fractal.analytics.track("enemy_kill", {"floor_number": floor_number, "enemy_type": enemy_type})` |
| `Fractal.analytics.roguelike.item_pickup(item_name, item_type, floor_number)` | `Fractal.analytics.track("item_pickup", {"item_name": item_name, "item_type": item_type, "floor_number": floor_number})` |
| `Fractal.analytics.roguelike.upgrade_chosen(upgrade_name, upgrade_type, floor_number)` | `Fractal.analytics.track("upgrade_chosen", {"upgrade_name": upgrade_name, "upgrade_type": upgrade_type, "floor_number": floor_number})` |
| `Fractal.analytics.roguelike.boss_kill(floor_number, boss_name)` | `Fractal.analytics.track("boss_kill", {"floor_number": floor_number, "boss_name": boss_name})` |
| `Fractal.analytics.roguelike.run_end(data)` | `Fractal.analytics.track("run_end", data)`, `run_end` no longer fills in defaults or validates required keys; pass the full payload yourself |

Nothing else changes, the analytics endpoint shape, batching behavior, and every other `Fractal.analytics.*` method are unaffected.

## Migrating from `FractalAnalytics` (v1) to `Fractal` (v2)

*(Historical, v1 predates the current `Fractal` autoload structure.)*

The v2 redesign consolidates analytics, error tracking, and translations sync under a single `Fractal` autoload with toggleable subsystems. The autoload was renamed from `FractalAnalytics` to `Fractal`, and the addon folder from `addons/fractal_analytics/` to `addons/fractal/`.

## Reinstall the addon

1. Delete `addons/fractal_analytics/` from your project.
2. Copy `addons/fractal/` from this repo.
3. Project Settings -> Plugins: disable the old `Fractal Analytics` plugin (if still listed) and enable the new `Fractal` plugin.
4. Update the autoload list, the new plugin registers `Fractal` automatically; remove any manual `FractalAnalytics` entry.

## Replace the API calls

| v1 | v2 |
| --- | --- |
| `FractalAnalytics.initialize("key", {...})` | `Fractal.configure({"api_key": "key", ...})` |
| `FractalAnalytics.track(type, payload)` | `Fractal.analytics.track(type, payload)` |
| `FractalAnalytics.flush()` | `Fractal.analytics.flush()` |
| `FractalAnalytics.start_session()` | `Fractal.analytics.start_session()` |
| `FractalAnalytics.end_session()` | `Fractal.analytics.end_session()` |
| `FractalAnalytics.set_player_id(id)` | `Fractal.analytics.set_player_id(id)` |
| `FractalAnalytics.get_player_id()` | `Fractal.analytics.get_player_id()` |
| `FractalAnalytics.set_debug(b)` | `Fractal.configure({"debug": b})` |
| `FractalAnalytics.roguelike.run_start(...)` | `Fractal.analytics.roguelike.run_start(...)` (removed in v3. See [above](#migrating-from-v2-to-v3)) |
| `FractalAnalytics.capture_error(type, msg, opts)` | `Fractal.errors.capture_error(type, msg, opts)` |
| `FractalAnalytics.add_breadcrumb(msg, cat, level)` | `Fractal.errors.add_breadcrumb(msg, cat, level)` |

## What's new

- **Translations sync**: `Fractal.translations.sync()` pulls live translations from Fractal at runtime. Configure `translations_enabled = true` and `translations_locales = [...]` to opt in.
- **Toggleable subsystems**: `analytics_enabled`, `errors_enabled`, `translations_enabled`. Disabled subsystems become no-ops; you don't have to gate calls.
- **Sentry-like error API**: `set_user`, `set_tag`, `set_context`, `set_release`, `set_environment`, `capture_message`. See [docs/ERRORS.md](ERRORS.md).
- **Heartbeat-based abnormal-shutdown detection**: SIGSEGV / OOM-kill / kill -9 / force-quit are now reported automatically as `AbnormalShutdown` events on the next launch. The previous version only caught explicit `OS.crash()` calls. New toggles: `errors_session_marker_enabled` (default true), `errors_heartbeat_interval_s` (default 10).
- **Retry-safe error submission**: every captured error is persisted to `user://fractal/errors_queue.json` before the POST. If the request fails or the process dies, the next launch retries from disk. No more lost errors across crashes-during-submission or network outages.
- **Cross-engine wire spec**: the on-disk schemas and HTTP payloads are now documented at [[CRASH_PROTOCOL.md](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md)](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md) so future Unity/Unreal SDKs implement the same contract.
- **Better config story**: `FractalConfig` Resource (saveable to `.tres`) plus runtime `configure()` overrides via Dictionary. See [docs/CONFIG.md](CONFIG.md).

## What changed under the hood

- `user://` files moved from `user://fractal_*.{cfg,json}` to `user://fractal/{player.cfg, analytics_queue.json, errors_queue.json, crash_report.json, session.json, translations/, translations_etags.cfg}`. **Existing v1 files won't auto-migrate.** If you're shipping v2 to existing players, the worst that happens is a new `player.id` gets generated. If that matters to you, write a one-time migration step that reads the old paths.
- The errors endpoint (`POST /v1/errors`) shape didn't change. Existing data in your error tracking dashboard continues to work.
- The analytics endpoint (`POST /v1/batch`) shape didn't change.

## v1 isn't going to silently break

If you don't migrate, calls to `FractalAnalytics.*` stop working entirely (the autoload no longer exists under that name). The plugin registers `Fractal` exclusively. There's no shim.

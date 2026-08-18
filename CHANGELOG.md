# Changelog

All notable changes to the Fractal Godot SDK are documented here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [Semantic Versioning](https://semver.org/). Tags are pushed as
`godot-sdk/vX.Y.Z`.

## 3.0.4

### Fixed

- `session_start`'s session token is no longer derived from a freshly-seeded
  `RandomNumberGenerator` alone. Two independent app launches whose
  `randomize()` seeds happened to collide could mint the byte-identical
  session token, which the collector hashes deterministically into
  `session_id`, merging two genuinely separate playthroughs into one
  ClickHouse session. A microsecond-precision wall-clock read is now folded
  into the token so a collision requires two launches to occur at the exact
  same microsecond. Found while investigating issue #355 (a fragmented
  player session split across two session_ids).

## 3.0.3

### Fixed

- A permanently-rejected analytics batch (4xx other than 429, e.g. a
  blocked/invalid API key) is now moved to an on-disk dead-letter queue
  (`user://fractal/analytics_dead_letter.json`) and reported via
  `push_error`, instead of being silently dropped with only a
  `push_warning`. Mirrors the dead-letter handling already added for the
  errors subsystem in 3.0.2. Found while investigating a production report
  of missing player data where a build's analytics batches could have been
  rejected and discarded with no trace anywhere, client or server.

## 3.0.2

### Fixed

- Error/crash events (`/v1/errors` batches, `NOTIFICATION_CRASH` reports, and
  native Crashpad minidumps) now carry the same `player_id` as analytics
  events, instead of always shipping an empty string. Errors resolves its
  own persisted player ID on `configure()`, via a new shared
  `FractalPersistence.resolve_player_id()`, so attribution works even when
  `analytics_enabled` is false or errors configures first. A new
  `Fractal.errors.set_player_id()` lets games running errors without
  analytics override it. The collector still accepts an empty `player_id`
  for back-compat with SDKs already in the field, but now logs a warning and
  increments `collector_errors_unattributed_total` instead of swallowing the
  gap silently.

## 3.0.1

### Fixed

- A batch of errors permanently rejected by the collector (4xx other than
  402/429, malformed payload, blocked key, etc.) is no longer retried
  forever. It's now moved to a local dead-letter file
  (`user://fractal/errors_dead_letter.json`) so one poison event can't
  silently wedge all future error uploads behind it.
- The local `push_warning` logged when `errors_live_log_capture_enabled` is
  on but `debug/file_logging/enable_file_logging` is off is now a `push_error`
  with the exact setting path and a docs link, so it's actually noticed.

## 3.0.0

### Added

- Event timestamps now carry millisecond precision (`_iso_now()`), and every
  tracked event includes a per-run `client_seq` counter. Together these fix
  same-second (and same-millisecond) events sorting incorrectly in the
  backend's Player Journey view, where ties previously fell back to
  alphabetical `event_type` ordering.

### Breaking

- Removed `Fractal.analytics.roguelike` (`run_start`, `run_end`,
  `floor_enter`, `enemy_kill`, `item_pickup`, `upgrade_chosen`, `boss_kill`).
  These were thin wrappers around `track()` with no wire-protocol value, and
  the backend has been fully genre-agnostic since it dropped
  roguelike-specific analytics in favor of the generic `event_aggregate`
  endpoint. Replace each call with the equivalent `track(event_type,
  payload)` call. See [docs/MIGRATION.md](docs/MIGRATION.md) for the exact
  mapping.

### Fixed

- The collector previously returned `202 Accepted` (with a `{"dropped": true}`
  body no client inspected) when a project's plan lacked the `error_tracking`
  feature, silently discarding error/crash/minidump/symbol uploads for every
  free-plan project. It now returns `402 Payment Required`. The errors and
  minidump subsystems treat 402 as a permanent, non-retryable rejection: they
  log one `push_error` developer warning, drop the queued payload (no disk
  retention, no retry), and go quiet for the rest of the session.
- `FractalHttpClient.request_failed` now carries the HTTP status code
  (`request_failed(error: String, response_code: int)`) so subscribers can
  distinguish a 402 gate from other 4xx failures.
- Fixed a `client_seq` poison loop: the collector rejected the whole-number
  floats (`0.0`) that Godot's JSON round-trip produced for persisted/restored
  events (`json: cannot unmarshal number 0.0 into ... uint32`), and analytics
  kept re-persisting the rejected batch every session, permanently stalling
  delivery (`batches_sent` stuck at 0). The collector now accepts whole-number
  floats for `client_seq`; `FractalPersistence.load_events()` casts it back to
  `int` on load (healing already-poisoned queues in the field); and analytics
  now drops the batch (with a `push_warning`) on any permanent 4xx instead of
  persisting it for retry. `FractalHttpClient`'s 4xx branch also now logs the
  status and body in debug mode.

## 2.1.0

- Translations sync now uses a key-only URL (`/api/v1/translations/sync`)
  the API key alone identifies your project, so `FractalConfig.project_id`
  is no longer required. The legacy nested URL
  (`/api/v1/projects/:project_id/translations/sync`) still works for
  already-shipped builds.
- `FractalConfig.project_id` is deprecated: kept on the resource for
  back-compat, no longer validated by `is_valid()`, and setting it now
  emits a one-time `push_warning` when translations are enabled. Safe to
  remove from your config.

## 2.0.1

- Native SDK freshness checks are now per-platform: a local build for the
  host platform satisfies `check_sdk_freshness.sh`, and the cross-platform
  GitHub Actions matrix becomes optional backfill for the other platforms
  rather than a required release gate. `NATIVE_BINARY_VERSIONS` is now a
  per-platform dict, since the three binaries can legitimately drift.
- Fixed spurious native build diffs: `build_local.sh` skips unchanged
  `crashpad_handler` copies and aligns the `.gdextension` dependency-key
  format so rebuilds are diff-clean.
- Comment-only edits to `addons/fractal_native/src/` no longer trip the
  native-staleness check.

## 2.0.0

Back-filled baseline entry, this release predates the changelog itself.

- Analytics, error tracking, and translations sync subsystems, each
  independently toggleable via `FractalConfig`.
- Three-layer native crash capture: `OS.crash()` notification replay,
  session-marker heartbeat (catches SIGSEGV / OOM-kill / force-quit), and
  optional `addons/fractal_native/` GDExtension (Crashpad via sentry-native)
  for full minidumps.
- Persistent error queue survives crashes mid-submission.
- Cross-engine wire protocol documented in [CRASH_PROTOCOL.md](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md).
- CI-enforced version freshness (`ci/check_sdk_freshness.sh`) replaces the manual release script: native binary staleness and missing version bumps now fail `bin/ci` loudly, `bump_version.sh` does the mechanical version edits, and merging a `VERSION` bump to `main` auto-tags `godot-sdk/vX.Y.Z`.

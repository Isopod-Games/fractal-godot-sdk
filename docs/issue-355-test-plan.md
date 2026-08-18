# Issue #355 test plan: fragmented player session (single playthrough split across two session_ids)

## Bug

Reported: a single playthrough for player `godot_4c05b7a7-a373-4406-8b8f-c27e8ca13cf9`
(project 3, Rogue Rollers) shows events dispersed across two ClickHouse
`session_id`s instead of one. Live prod query (see issue comment
https://github.com/jmperez127/fractal/issues/355#issuecomment-5167825197)
found two concrete anomalies for that player on 2026-07-29:

1. Two **different** `session_id`s each have a `session_start` event at the
   exact same millisecond (`14:32:04.262`), both with `client_seq=0`.
2. One of those `session_id`s (`13625425192104020315`) has a **second**
   `session_start` ~50 minutes later (`15:22:14.605`), also with
   `client_seq=0`, under the same `session_id`.

## Root cause

`session_id` in ClickHouse is not sent by the SDK, the collector derives it
deterministically from the SDK's `session_token` string:

```go
// collector/internal/ingest/handler.go:192-196
sessionToken := batch.Context.SessionToken
...
sessionID := hashStringToUint64(sessionToken)  // FNV-1a 64-bit
```

(mirrored in `error_handler.go:145` for the errors pipeline). FNV-1a is
deterministic, identical token ⇒ identical `session_id`, and a true hash
collision between two *different* tokens is ~1-in-2^64. So finding #2 (same
`session_id` reappearing) means the SDK emitted the **literal same
`session_token` string twice**.

`client_seq` (`addons/fractal/analytics/event_queue.gd:19,37,40`)
is a counter (`_seq`) private to one in-memory `FractalEventQueue` instance,
which is constructed exactly once, in `analytics.gd::_ready()`
(`addons/fractal/analytics/analytics.gd:36-37`). A Godot autoload's
`_ready()` runs once per process. `_seq` is never reset by flushing, clearing,
or `end_session()`/`start_session()`, only a brand-new process (a fresh game
launch) creates a brand-new queue with `_seq` back at 0. So a second
`session_start` with `client_seq=0` under the same `session_id`, 50 minutes
after the first, cannot be the same process continuing, it is a **second,
separate app launch** that happened to mint the identical `session_token`.

The token itself comes from `analytics.gd::_generate_session_token()`
(lines 220-226):

```gdscript
func _generate_session_token() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var hex := ""
	for i in range(8):
		hex += "%02x" % rng.randi_range(0, 255)
	return "sess_" + hex
```

This is the *only* thing determining the token: a fresh `RandomNumberGenerator`
instance, seeded solely via `randomize()` (time-based entropy), with no other
differentiator. Two independent process launches, each seeding their own
short-lived RNG instance from clock-derived entropy, are not guaranteed to
land on different seeds, and if the seed collides, the entire output sequence
(deterministic from the seed) collides too, producing a byte-identical
`session_token`. That explains anomaly #2 (same token, 50 min apart, two
launches). Anomaly #1 (different `session_id`s at the identical millisecond)
is the flip side: two near-simultaneous launches whose seeds didn't collide,
but whose client-stamped `session_start` timestamps (`event_queue.gd::_iso_now()`,
millisecond resolution) landed in the same millisecond.

The fix does not need to pin Godot engine's exact `randomize()` internals
it needs to stop trusting a single time-seeded RNG draw as the sole source of
token uniqueness. Folding a live, microsecond-precision wall-clock read
(`Time.get_unix_time_from_system()`) into the token means two truly distinct
launches cannot produce the same token even if their RNG seeds coincide.

## Repro steps

1. Construct two `RandomNumberGenerator` instances and set the *same*
   explicit `seed` on each (simulating two separate process launches whose
   `randomize()` entropy happened to collide, the mechanism above).
2. Generate a session token from each (`analytics._generate_session_token()`,
   refactored to accept an injected RNG for determinism).
3. **Expected:** the two tokens differ (so they hash to different
   `session_id`s and never fragment a session).
4. **Actual (pre-fix):** the two tokens are byte-identical, since the hex
   portion is the only content and is fully determined by the RNG seed.

## Verification

- New test: `tests/unit/test_analytics_session_token.gd`
  - `test_colliding_rng_seed_still_produces_distinct_tokens`, proves two
    "launches" with an identical RNG seed no longer produce the same token.
- Run via the project's gdUnit4 harness (`ci/` runner /
  `config/ci.rb`).
- Confirm existing session-token consumers still pass: `test_platform_detector.gd`
  and `test_errors_flow.gd::test_session_token_present_only_with_active_analytics_session`
  only assert on the `sess_` prefix, not exact format, so they're unaffected.

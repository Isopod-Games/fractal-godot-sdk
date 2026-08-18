# Analytics — `Fractal.analytics`

Event tracking subsystem. Events are batched and sent to `POST {collector_url}/v1/batch` with the `X-API-Key` header. When the batch send fails, events are persisted to disk (`user://fractal/analytics_queue.json`) and replayed on the next session.

## API

```gdscript
# Track an event.
Fractal.analytics.track(event_type: String, payload: Dictionary = {}) -> void

# Force-send the queue immediately. Returns when the request is in flight.
Fractal.analytics.flush() -> void

# Sessions.
Fractal.analytics.start_session() -> void
Fractal.analytics.end_session() -> void

# Player ID — auto-generated `godot_<uuid>` and persisted, but you can override.
Fractal.analytics.set_player_id(id: String) -> void
Fractal.analytics.get_player_id() -> String
Fractal.analytics.get_session_token() -> String

# Per-user properties merged into batch context.
Fractal.analytics.set_user_property(key: String, value) -> void

# Diagnostics.
Fractal.analytics.get_pending_event_count() -> int
Fractal.analytics.is_enabled() -> bool
```

### Signals

```gdscript
signal event_tracked(event_type: String)
signal batch_sent(event_count: int)
signal batch_failed(error: String)
```

## Batch shape

The SDK posts:

```json
{
  "sent_at": "2026-04-29T10:00:00Z",
  "context": {
    "player_id": "godot_a1b2c3d4-...",
    "session_token": "sess_...",
    "platform": "macos",
    "app_version": "1.0.0",
    "os": "macOS",
    "os_version": "14.0",
    "environment": "production",
    "user_properties": {"region": "us"}
  },
  "events": [
    {"event_type": "level_complete", "event_timestamp": "2026-04-29T09:59:58Z", "payload": {"level": 5}}
  ]
}
```

## Batching behavior

- A batch is sent when the queue reaches `analytics_batch_size` (default 10).
- A 5-second timer also calls `check_flush(...)`, which forces a send if `analytics_flush_interval` (default 30s) has elapsed since the last send.
- The queue caps at `analytics_max_queue_size` (default 1000); when full, the oldest events are dropped and `queue_overflow` is logged.
- On send failure, the events are persisted to `user://fractal/analytics_queue.json` for retry on next launch.
- On HTTP 5xx / 429, the send is retried with exponential backoff (1s → 2s → 4s → 8s → 16s, capped at 60s, max 5 retries).
- On HTTP 4xx (other than 429), the request fails fast with no retry — the events are still persisted for you to inspect.

## Game-specific events

There are no genre-specific helpers — the analytics API is fully generic. Game-specific events are just `track()` calls with whatever payload shape makes sense for your game:

```gdscript
Fractal.analytics.track("run_end", {
    "character": "knight",
    "floors_reached": 7,
    "score": 1234,
    "duration_seconds": 600.5,
    "victory": false,
    "death_cause": "lava",
})
```

## When analytics is disabled

If `analytics_enabled = false`, every method on `Fractal.analytics` returns immediately:

- `track()` does nothing — no queueing, no signals, no HTTP.
- `flush()` does nothing.
- `get_player_id()` still returns the persisted ID — both `Fractal.analytics` and `Fractal.errors` resolve the same on-disk ID via the shared `FractalPersistence.resolve_player_id()` contract, so whichever subsystem configures first creates it and the other reuses it. This holds even if `analytics_enabled = false`, since `Fractal.errors` resolves its own copy independently.

This means game code can call `Fractal.analytics.track(...)` unconditionally — disabled = silent.

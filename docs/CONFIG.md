# Configuration

Configuration goes through `Fractal.configure(...)`, which accepts either a `FractalConfig` Resource or a `Dictionary` of overrides. Calling it more than once is supported, each subsystem is reconfigured with the new settings (useful for runtime toggles, e.g. consent UIs).

## Fields

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `api_key` | String | `""` | API key issued by Fractal. Required. |
| `project_id` | String | `""` | **Deprecated, unused.** The API key alone identifies your project. Kept for resource back-compat; safe to remove. |
| `collector_url` | String | `"https://collector.getfractal.dev"` | Base URL of the Go collector. Used by analytics + errors. Override only for a self-hosted collector. |
| `api_url` | String | `"http://localhost:3001"` | Base URL of the Rails API. Used by translations sync. |
| `app_version` | String | `"1.0.0"` | Sent with every request, useful for filtering. |
| `environment` | String | `"development"` | One of `development \| staging \| production`. Tagged onto errors and analytics. |
| `debug` | bool | `false` | Print SDK debug logs to stdout. |
| `analytics_enabled` | bool | `true` | Toggle analytics. When `false`, every `Fractal.analytics.*` call is a no-op. |
| `errors_enabled` | bool | `true` | Toggle error capture. When `false`, every `Fractal.errors.*` call is a no-op. |
| `translations_enabled` | bool | `false` | Toggle translations sync. When `false`, every `Fractal.translations.*` call is a no-op. |
| `analytics_batch_size` | int | `10` | Trigger a batch send when the queue reaches this size. |
| `analytics_flush_interval` | float | `30.0` | Force a flush every N seconds even if the batch isn't full. |
| `analytics_max_queue_size` | int | `1000` | Hard cap on queued events. Oldest are dropped first. |
| `errors_max_breadcrumbs` | int | `20` | Ring buffer size for breadcrumbs included with each captured error. |
| `errors_auto_breadcrumb_scene_changes` | bool | `false` | Auto-add a breadcrumb on every scene change. |
| `errors_session_marker_enabled` | bool | `true` | Track an active-session marker on disk (`user://fractal/session.json`). When `true`, abnormal shutdowns (SIGSEGV / OOM / kill -9 / force-quit) get reported on the next launch as `AbnormalShutdown` events. |
| `errors_heartbeat_interval_s` | float | `10.0` | How often the heartbeat refreshes the session marker. Lower = tighter "last alive" timestamp on the synthetic event, slightly more disk I/O. |
| `errors_native_enabled` | bool | `false` | Opt in to the native `addons/fractal_native/` GDExtension (Crashpad-based). Catches SIGSEGV with full minidumps. No-op if the addon isn't installed for the current platform. See [docs/ERRORS.md](ERRORS.md) and `addons/fractal_native/README.md`. |
| `translations_locales` | PackedStringArray | `[]` | Locales to sync. Empty = whatever `TranslationServer.get_loaded_locales()` returns. |
| `translations_sync_on_startup` | bool | `true` | Sync once when `configure()` is called. |
| `translations_sync_interval_hours` | float | `0.0` | Periodic re-sync interval. `0` disables periodic sync. |

## Two ways to configure

### Resource file (recommended for shipped builds)

Create `fractal_config.tres` in your project (right-click any folder -> New Resource -> FractalConfig), edit fields in the inspector, then:

```gdscript
Fractal.configure(preload("res://fractal_config.tres"))
```

### Dictionary (recommended for environment overrides)

Useful when you want to read values from env vars, command-line args, or feature flags:

```gdscript
Fractal.configure({
    "api_key": OS.get_environment("FRACTAL_API_KEY"),
    "environment": "production" if OS.has_feature("template") else "development",
    "analytics_enabled": _user_consented_to_analytics(),
})
```

You can mix the two, load defaults from the `.tres`, then call `configure()` again with a dictionary override.

## Validation

`FractalConfig.is_valid()` returns `{"valid": bool, "errors": PackedStringArray}`. `Fractal.configure()` calls this internally and `push_error`s for each validation failure (then returns without applying). Common validation errors:

- `"api_key is required"`
- `"collector_url is required when analytics_enabled or errors_enabled is true"`
- `"api_url is required when translations_enabled is true"`

## Runtime toggle pattern

```gdscript
# Player turned analytics off in settings.
func _on_analytics_consent_changed(consented: bool) -> void:
    Fractal.configure({"analytics_enabled": consented})
```

When you flip a toggle, the disabled subsystem stops queuing and stops sending immediately. The enabled subsystems are reconfigured with their existing state preserved.

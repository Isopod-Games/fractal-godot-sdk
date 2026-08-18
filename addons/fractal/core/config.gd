@tool
class_name FractalConfig
extends Resource
## Configuration resource for the Fractal SDK.
##
## Save as `fractal_config.tres` in your project (any path) and pass it to
## `Fractal.configure(config)` at startup. Each subsystem is independently
## toggleable; disabled subsystems become no-ops.

@export_group("Credentials")
## API key issued by Fractal for your project.
@export var api_key: String = ""

## DEPRECATED: no longer required. The translations sync endpoint is
## key-only, the API key alone identifies your project. Kept for resource
## back-compat with existing .tres files; safe to leave blank or remove.
@export var project_id: String = ""

@export_group("Endpoints")
## Collector base URL for analytics + errors. Defaults to Fractal's hosted
## collector; override only for a self-hosted collector.
@export var collector_url: String = "https://collector.getfractal.dev"

## Rails API base URL for translations. Example: "https://fractal.isopodgames.com"
@export var api_url: String = "http://localhost:3001"

@export_group("App")
## Your game version (sent with every request).
@export var app_version: String = "1.0.0"

## Environment tag attached to errors and analytics (development|staging|production).
@export var environment: String = "development"

## Print SDK debug logs to stdout.
@export var debug: bool = false

@export_group("Subsystem toggles")
@export var analytics_enabled: bool = true
@export var errors_enabled: bool = true
@export var translations_enabled: bool = false

@export_group("Analytics")
@export var analytics_batch_size: int = 10
@export var analytics_flush_interval: float = 30.0
@export var analytics_max_queue_size: int = 1000

@export_group("Errors")
@export var errors_max_breadcrumbs: int = 20
## Auto-add a breadcrumb on every scene change (set false to opt out).
@export var errors_auto_breadcrumb_scene_changes: bool = false
## Track an active-session marker on disk so abnormal shutdowns
## (SIGSEGV, OOM, kill -9, force-quit) get reported on the next launch.
@export var errors_session_marker_enabled: bool = true
## How often the heartbeat refreshes the session marker (seconds).
## Lower = tighter "last alive" timestamp, slightly more disk I/O.
@export var errors_heartbeat_interval_s: float = 10.0
## Phase B placeholder, when a `FractalNative` GDExtension is bundled,
## flip this to capture true minidumps for native crashes (SIGSEGV etc.).
@export var errors_native_enabled: bool = false
## Tail the current session's Godot log on the heartbeat and auto-report
## non-fatal GDScript runtime errors (SCRIPT ERROR: / ERROR: / CRITICAL:)
## as ScriptError events, with no capture_error() call needed. Requires
## `debug/file_logging/enable_file_logging` to be on in Project Settings.
@export var errors_live_log_capture_enabled: bool = true

@export_group("Translations")
## Sync translations once on startup (recommended for shipped builds).
@export var translations_sync_on_startup: bool = true
## Periodic re-sync interval. 0 = no periodic sync.
@export var translations_sync_interval_hours: float = 0.0
## Locales to sync. If empty, the SDK falls back to TranslationServer.get_loaded_locales().
@export var translations_locales: PackedStringArray = PackedStringArray()


## Returns a deep copy with `overrides` (Dictionary) merged on top.
## Used by `Fractal.configure(opts: Dictionary)` for runtime overrides.
func merged(overrides: Dictionary) -> FractalConfig:
	var copy: FractalConfig = duplicate(true)
	for key in overrides.keys():
		if key in copy:
			copy.set(key, overrides[key])
	return copy


## Returns true if all credentials needed for the enabled subsystems are present.
func is_valid() -> Dictionary:
	var errors: PackedStringArray = PackedStringArray()
	if api_key.is_empty():
		errors.append("api_key is required")
	if collector_url.is_empty() and (analytics_enabled or errors_enabled):
		errors.append("collector_url is required when analytics_enabled or errors_enabled is true")
	if translations_enabled:
		if api_url.is_empty():
			errors.append("api_url is required when translations_enabled is true")
	return {
		"valid": errors.is_empty(),
		"errors": errors,
	}

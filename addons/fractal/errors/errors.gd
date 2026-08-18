extends Node
## Errors subsystem, `Fractal.errors`.
##
## Sentry-like error/crash capture. Public API:
##   capture_error(error_type, message, opts)
##   capture_message(message, severity)
##   add_breadcrumb(message, category, level, data)
##   set_user(id, opts) / set_tag(k, v) / set_context(k, dict)
##   set_release(version) / set_environment(env)
##
## Crash detection layers (each catches things the others can't):
##   1. NOTIFICATION_CRASH, explicit OS.crash() and some engine-side
##                                 fatals. Writes a crash report to disk.
##   2. Session marker heartbeat, catches *any* abnormal exit (SIGSEGV,
##                                 OOM, kill -9. Godot panic) by detecting
##                                 a previous session that never marked
##                                 itself clean. Best-effort log-scrape
##                                 enrichment on next launch.
##   3. Persistent error queue, every error is persisted before POST,
##                                 so a crash during submission doesn't
##                                 lose data. Retried on next launch.
##
## When `errors_enabled` is false, every method short-circuits.

signal error_captured(error_type: String)
signal error_sent
signal error_failed(message: String)

const FractalConfigClass := preload("res://addons/fractal/core/config.gd")
const FractalVersionClass := preload("res://addons/fractal/core/version.gd")
const FractalBreadcrumbsClass := preload("res://addons/fractal/errors/breadcrumbs.gd")
const FractalHttpClientClass := preload("res://addons/fractal/core/http_client.gd")
const FractalPlatformDetectorClass := preload("res://addons/fractal/core/platform_detector.gd")
const FractalPersistenceClass := preload("res://addons/fractal/core/persistence.gd")
const FractalSessionMarkerClass := preload("res://addons/fractal/errors/session_marker.gd")
const FractalLogScraperClass := preload("res://addons/fractal/errors/log_scraper.gd")

# Optional native module path. The GDExtension may not be installed in this
# project; ResourceLoader.exists() guards the preload so missing-addon
# environments parse cleanly.
const _NATIVE_HELPERS_PATH := "res://addons/fractal_native/fractal_native.gd"

var _enabled: bool = false
var _config: FractalConfigClass = null
var _http: FractalHttpClientClass
var _breadcrumbs: FractalBreadcrumbsClass
var _session_marker: FractalSessionMarkerClass
var _heartbeat_timer: Timer
var _player_id: String = ""
var _analytics = null
var _warned_no_player_id: bool = false
var _user: Dictionary = {}
var _tags: Dictionary = {}
var _context: Dictionary = {}
var _release: String = ""
var _environment: String = ""
var _buffer: Array = []
var _send_in_flight: bool = false
# Set permanently once the collector returns 402 (plan lacks error_tracking).
# Stops all further flushes/POSTs for the rest of the session, no retry storm
# against a gate that won't lift until the developer upgrades.
var _feature_gated: bool = false
# Drain persisted state at most once per process. Without this, a second
# configure() call (e.g., AnalyticsGlue -> driver re-configure) would re-read
# our OWN freshly-written session.json and falsely infer an abnormal shutdown.
var _drained_once: bool = false
# True iff the native GDExtension is loaded and armed for native crash capture.
var _native_armed: bool = false

# Live log tailing (non-fatal GDScript runtime error auto-capture).
var _live_capture_enabled: bool = false
# Guards _init_live_log_capture() to once per process, mirroring _drained_once
#, a re-configure() must not reset the cursor and lose un-polled content.
var _live_inited: bool = false
var _log_path: String = ""
var _log_cursor: int = -1
# sig -> { "message": String, "stack_trace": String, "total": int }. Tracks
# cumulative occurrences per signature across the session for debug/inspection;
# the wire payload carries only the per-poll delta (see _poll_log_for_errors).
var _live_signatures: Dictionary = {}


func _ready() -> void:
	_breadcrumbs = FractalBreadcrumbsClass.new()
	_session_marker = FractalSessionMarkerClass.new()
	_http = FractalHttpClientClass.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_http.request_failed.connect(_on_request_failed)

	_heartbeat_timer = Timer.new()
	_heartbeat_timer.one_shot = false
	_heartbeat_timer.timeout.connect(_on_heartbeat)
	add_child(_heartbeat_timer)


func configure(config: FractalConfigClass) -> void:
	_config = config
	_enabled = config.errors_enabled
	if not _enabled:
		_heartbeat_timer.stop()
		return

	_breadcrumbs = FractalBreadcrumbsClass.new(config.errors_max_breadcrumbs)
	_http.configure(config.api_key, config.debug)
	_release = config.app_version
	_environment = config.environment
	_player_id = FractalPersistenceClass.resolve_player_id()

	# Toggle auto-breadcrumbs on scene change, symmetric so reconfiguring
	# from `true` to `false` actually disconnects the listener.
	var tree := get_tree()
	if tree:
		if config.errors_auto_breadcrumb_scene_changes:
			if not tree.tree_changed.is_connected(_on_tree_changed):
				tree.tree_changed.connect(_on_tree_changed)
		else:
			if tree.tree_changed.is_connected(_on_tree_changed):
				tree.tree_changed.disconnect(_on_tree_changed)

	# Native crash capture (Phase B), opt-in, no-op if the GDExtension
	# isn't installed. Initialized BEFORE _drain_persisted_errors so that
	# any fresh native breadcrumbs/tags are wired before drain emits any
	# replays.
	if config.errors_native_enabled and ResourceLoader.exists(_NATIVE_HELPERS_PATH):
		_arm_native(config)

	_live_capture_enabled = config.errors_live_log_capture_enabled
	if _live_capture_enabled and not _live_inited:
		_live_inited = true
		_init_live_log_capture()

	# Session marker + heartbeat. Drain persisted state BEFORE starting a
	# new session so the "previous session was abnormal" signal stays.
	_drain_persisted_errors()
	if config.errors_session_marker_enabled:
		_session_marker.start_new(_static_session_fields())
	else:
		_session_marker.clear()

	# Heartbeat must run if EITHER the session marker OR live capture is
	# enabled, they share the same timer (no second timer for live
	# capture; visibility latency is bounded by errors_heartbeat_interval_s).
	if config.errors_session_marker_enabled or _live_capture_enabled:
		var interval: float = max(1.0, config.errors_heartbeat_interval_s)
		_heartbeat_timer.wait_time = interval
		if _heartbeat_timer.is_stopped():
			_heartbeat_timer.start()
	else:
		_heartbeat_timer.stop()


# ─── Public API ───────────────────────────────────────────────────────────

func capture_error(error_type: String, message: String, opts: Dictionary = {}) -> void:
	if not _enabled:
		return
	if error_type.is_empty() or message.is_empty():
		push_warning("Fractal.errors.capture_error: error_type and message required")
		return
	var event := _build_event(error_type, message, opts)
	_buffer.append(event)
	error_captured.emit(error_type)
	_flush()


func capture_message(message: String, severity: String = "info") -> void:
	if not _enabled:
		return
	capture_error("Message", message, {"severity": severity, "handled": true})


func add_breadcrumb(message: String, category: String = "default", level: String = "info", data: Dictionary = {}) -> void:
	if not _enabled:
		return
	_breadcrumbs.add(message, category, level, data)


## Injection point for the sibling analytics subsystem so errors can prefer
## its live player ID (picks up a post-configure set_player_id()).
func set_analytics(node) -> void:
	_analytics = node


## Overrides the resolved player ID, for games running errors without
## analytics that still want to set their own ID.
func set_player_id(id: String) -> void:
	if id.is_empty():
		push_warning("Fractal.errors.set_player_id: id cannot be empty")
		return
	_player_id = id
	FractalPersistenceClass.save_player_id(id)


func set_user(id: String, opts: Dictionary = {}) -> void:
	_user = {"id": id}
	for key in opts.keys():
		_user[key] = opts[key]


func set_tag(key: String, value) -> void:
	_tags[key] = value


func set_context(key: String, value: Dictionary) -> void:
	_context[key] = value


func set_release(version: String) -> void:
	_release = version


func set_environment(env: String) -> void:
	_environment = env


func is_enabled() -> bool:
	return _enabled


# ─── Lifecycle hooks called by the Fractal autoload ──────────────────────

func handle_crash() -> void:
	# Inside NOTIFICATION_CRASH we have a tiny window, synchronous file I/O only.
	if _config == null:
		return
	# Persist any buffered errors blocked by _send_in_flight so they survive
	# the crash and are retried on next launch.
	if not _buffer.is_empty():
		FractalPersistenceClass.append_to_error_queue(_buffer)
	var report := {
		"timestamp": _iso_now(),
		"player_id": _effective_player_id(),
		"session_token": _effective_session_token(),
		"app_version": _release,
		"environment": _environment,
		"platform": FractalPlatformDetectorClass.get_platform(),
		"os": FractalPlatformDetectorClass.get_os(),
		"os_version": FractalPlatformDetectorClass.get_os_version(),
		"breadcrumbs": _breadcrumbs.all() if _breadcrumbs else [],
		"user": _user,
		"tags": _tags,
		"context": _context,
		"sdk_version": FractalVersionClass.VERSION,
	}
	FractalPersistenceClass.save_crash_report(report)
	if _session_marker:
		_session_marker.mark_crashed_via("notification")


## Called on graceful shutdown. Marks the session clean so the next launch
## doesn't infer an abnormal shutdown. Also persists any in-flight buffered
## errors so they survive the exit.
func mark_clean_shutdown() -> void:
	if not _enabled:
		return
	# Flush the final partial live-capture window so its occurrences aren't
	# lost. (On a crash the last window may be lost, acceptable, since the
	# crash itself is covered by the AbnormalShutdown layer.)
	if _live_capture_enabled:
		_poll_log_for_errors()
	if not _buffer.is_empty():
		FractalPersistenceClass.append_to_error_queue(_buffer)
		_buffer.clear()
	if _session_marker:
		_session_marker.mark_clean()


## Public alias kept for back-compat with v2.0 callers and the integration
## test. Internally this is the broader "drain anything the previous run
## left behind" entry point.
func replay_previous_crash() -> void:
	_drain_persisted_errors()


# ─── Internal ─────────────────────────────────────────────────────────────

func _effective_player_id() -> String:
	# Prefer the live analytics value so a post-configure set_player_id() is
	# picked up; fall back to our own resolved ID when analytics is disabled.
	if _analytics and not _analytics.get_player_id().is_empty():
		return _analytics.get_player_id()
	if _player_id.is_empty() and not _warned_no_player_id:
		_warned_no_player_id = true
		push_error("[Fractal] errors: no player_id could be resolved, shipping an unattributed error batch")
	return _player_id


func _effective_session_token() -> String:
	# In-memory only and assigned by start_session(); legitimately empty when
	# analytics is off or no session has started.
	return _analytics.get_session_token() if _analytics else ""


## Merges the resolved player ID into the "user" metadata sent with native
## minidumps, with an explicit set_user() id winning.
func _metadata_user() -> Dictionary:
	var merged := {"id": _effective_player_id()}
	for k in _user.keys():
		merged[k] = _user[k]
	return merged


func _drain_persisted_errors() -> void:
	if not _enabled:
		return
	# Re-configure within the same process must not re-drain, otherwise
	# we'd re-read the session marker we just wrote and falsely infer an
	# abnormal shutdown for our own active session.
	if _drained_once:
		return
	_drained_once = true
	# 1. Anything queued but not yet POSTed in a previous session, these
	#    are pre-built error events in canonical wire shape.
	var queued: Array = FractalPersistenceClass.load_error_queue()
	if not queued.is_empty():
		for e in queued:
			_buffer.append(e)
		FractalPersistenceClass.clear_error_queue()

	# 2. Explicit crash via NOTIFICATION_CRASH, old-style crash_report.json.
	var crash_report: Dictionary = FractalPersistenceClass.load_crash_report()
	if not crash_report.is_empty():
		FractalPersistenceClass.clear_crash_report()
		_buffer.append(_build_event(
			"UnhandledCrash",
			"Game crashed unexpectedly in previous session (at %s)" % crash_report.get("timestamp", "unknown"),
			{
				"severity": "fatal",
				"handled": false,
				"extra": {
					"crash_session_timestamp": crash_report.get("timestamp", ""),
					"app_version": crash_report.get("app_version", ""),
					"os": crash_report.get("os", ""),
					"os_version": crash_report.get("os_version", ""),
					"platform": crash_report.get("platform", ""),
				},
				"breadcrumbs": crash_report.get("breadcrumbs", []),
				"tags": {"crash_type": "unhandled"},
			},
		))

	# 3. Heartbeat-inferred abnormal shutdown, previous session never
	#    marked itself clean. Skip if NOTIFICATION_CRASH already produced
	#    an UnhandledCrash above (better data) or if we were never enabled.
	if _config and _config.errors_session_marker_enabled and crash_report.is_empty():
		var prev: Dictionary = _session_marker.load_previous()
		if not prev.is_empty() and not prev.get("clean", false):
			_buffer.append(_build_abnormal_shutdown_event(prev))

	if not _buffer.is_empty():
		_flush()


func _build_abnormal_shutdown_event(prev: Dictionary) -> Dictionary:
	var trace := ""
	if _config and _config.errors_session_marker_enabled:
		var logs_dir: String = OS.get_user_data_dir().path_join("logs")
		trace = FractalLogScraperClass.extract_latest_trace(logs_dir)

	var crashed_via: String = prev.get("crashed_via", "heartbeat")
	var message := "Previous session ended abnormally (last heartbeat %s, detected via %s)" % [
		prev.get("last_heartbeat_at", "unknown"), crashed_via,
	]

	# Treat as fatal so the dashboard severity filters surface it. Use a
	# distinct error_type from UnhandledCrash so the two paths are
	# distinguishable in the backend.
	return _build_event("AbnormalShutdown", message, {
		"severity": "fatal",
		"handled": false,
		"stack_trace": trace,
		"breadcrumbs": prev.get("breadcrumbs", []),
		"extra": {
			"crashed_via": crashed_via,
			"previous_session_id": prev.get("session_id", ""),
			"started_at": prev.get("started_at", ""),
			"last_heartbeat_at": prev.get("last_heartbeat_at", ""),
			"runtime": prev.get("runtime", {}),
			"prev_app_version": prev.get("app_version", ""),
			"prev_environment": prev.get("environment", ""),
			"prev_platform": prev.get("platform", ""),
			"prev_sdk_version": prev.get("sdk_version", ""),
		},
		"tags": {"crash_type": "abnormal_shutdown"},
	})


func _static_session_fields() -> Dictionary:
	return {
		"app_version": _release,
		"environment": _environment,
		"platform": FractalPlatformDetectorClass.get_platform(),
		"os": FractalPlatformDetectorClass.get_os(),
		"os_version": FractalPlatformDetectorClass.get_os_version(),
		"player_id": _effective_player_id(),
		"user": _user,
		"tags": _tags,
		"sdk_version": FractalVersionClass.VERSION,
	}


func _build_event(error_type: String, message: String, opts: Dictionary) -> Dictionary:
	var event := {
		"error_type": error_type,
		"message": message,
		"stack_trace": opts.get("stack_trace", ""),
		"severity": opts.get("severity", "error"),
		"handled": opts.get("handled", true),
		"extra": opts.get("extra", {}),
		"breadcrumbs": opts.get("breadcrumbs", _breadcrumbs.all()),
		"tags": _merge_tags(opts.get("tags", {})),
		"timestamp": _iso_now(),
		"runtime": _session_marker._runtime if _session_marker else {"name": "godot", "version": ""},
	}
	if not _user.is_empty():
		event["user"] = _user.duplicate(true)
	if not _context.is_empty():
		event["context"] = _context.duplicate(true)
	if not _release.is_empty():
		event["release"] = _release
	if not _environment.is_empty():
		event["environment"] = _environment
	var occ: int = int(opts.get("occurrence_count", 1))
	if occ > 1:
		event["occurrence_count"] = occ
	return event


func _merge_tags(extra: Dictionary) -> Dictionary:
	var merged := _tags.duplicate(true)
	for k in extra.keys():
		merged[k] = extra[k]
	return merged


func _flush() -> void:
	if _feature_gated:
		return
	if _buffer.is_empty() or _send_in_flight:
		return
	if _config == null:
		return

	# Merge any previously-failed batch from disk with the current buffer so
	# that clear_error_queue() in _on_request_completed only removes events
	# that were actually transmitted, not a prior failed batch sitting on disk.
	var persisted: Array = FractalPersistenceClass.load_error_queue()
	var batch: Array = persisted + _buffer.duplicate()
	_buffer.clear()
	_send_in_flight = true

	# Persist the full merged batch before POST. On success we clear in
	# _on_request_completed; on failure the queue stays for the next session.
	FractalPersistenceClass.save_error_queue(batch)

	var payload := {
		"sent_at": _iso_now(),
		"context": FractalPlatformDetectorClass.get_context(_effective_player_id(), _effective_session_token(), _release, _environment),
		"errors": batch,
	}
	var url: String = _config.collector_url.trim_suffix("/") + "/v1/errors"
	_http.request(HTTPClient.METHOD_POST, url, PackedStringArray(), JSON.stringify(payload))


func _on_request_completed(_status: int, _headers: PackedStringArray, _body: String) -> void:
	_send_in_flight = false
	# Successful flight: clear the persisted queue. If a SECOND batch is
	# already buffered (rare but possible during shutdown bursts), it
	# repopulates the queue when we _flush() it below.
	FractalPersistenceClass.clear_error_queue()
	if not _buffer.is_empty():
		_flush()
	else:
		error_sent.emit()


func _on_request_failed(error: String, response_code: int = 0) -> void:
	_send_in_flight = false
	if response_code == 402:
		push_error("[Fractal] Error tracking is not included in your plan, errors are NOT being recorded. Upgrade to enable.")
		_feature_gated = true
		FractalPersistenceClass.clear_error_queue()
		error_failed.emit(error)
		return
	if response_code >= 400 and response_code < 500 and response_code != 429:
		# Permanently rejected, the collector will never accept this exact
		# batch (malformed payload, blocked key, etc.). Retrying it on every
		# future flush would silently wedge all later uploads behind one
		# poison event forever, so dead-letter it instead: don't lose the
		# data, but don't retry it either.
		var rejected: Array = FractalPersistenceClass.load_error_queue()
		FractalPersistenceClass.clear_error_queue()
		FractalPersistenceClass.append_to_dead_letter_error_queue(rejected)
		push_error("[Fractal] Error batch permanently rejected and moved to dead-letter queue: %s" % error)
		error_failed.emit(error)
		return
	# 5xx/429/network, queue stays on disk for the next session to retry.
	error_failed.emit(error)


func _on_tree_changed() -> void:
	# Best-effort breadcrumb when the active scene changes.
	var tree := get_tree()
	if tree == null:
		return
	var current := tree.current_scene
	if current == null:
		return
	add_breadcrumb("scene_changed", "navigation", "info", {"scene": current.name})


func _on_heartbeat() -> void:
	if _session_marker != null and _config != null and _config.errors_session_marker_enabled:
		var crumbs: Array = _breadcrumbs.all() if _breadcrumbs else []
		_session_marker.tick(crumbs, _user, _tags)
	if _live_capture_enabled:
		_poll_log_for_errors()


## Locates the active session's log file and records its current EOF as the
## tailing cursor. Starting at EOF means we never replay pre-session content
##, the next-launch AbnormalShutdown scrape (extract_latest_trace) owns that.
func _init_live_log_capture() -> void:
	if not ProjectSettings.get_setting("debug/file_logging/enable_file_logging", false):
		push_error(
			"[Fractal] errors_live_log_capture_enabled is on but ScriptErrors will NOT be captured " +
			"automatically, enable Project Settings > Debug > File Logging > Enable File Logging " +
			"(debug/file_logging/enable_file_logging) to fix this. capture_error() still works without it. " +
			"See sdks/godot/docs/ERRORS.md#layer-4-live-log-tailing--scripterror"
		)
		_live_capture_enabled = false
		return
	_log_path = ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log")
	var file := FileAccess.open(_log_path, FileAccess.READ)
	if file == null:
		_log_cursor = 0
		return
	_log_cursor = file.get_length()
	file.close()


## Polls the live log for new error blocks since the last cursor, groups
## them by signature, and emits one ScriptError event per signature per
## poll carrying the per-poll occurrence delta, bounding egress to one
## event per signature per heartbeat regardless of how often it fires.
func _poll_log_for_errors() -> void:
	if _log_path.is_empty():
		return
	var r: Dictionary = FractalLogScraperClass.extract_new_blocks(_log_path, _log_cursor)
	_log_cursor = r.get("cursor", _log_cursor)
	var blocks: Array = r.get("blocks", [])
	if blocks.is_empty():
		return

	var deltas: Dictionary = {}  # sig -> delta count this poll
	var details: Dictionary = {}  # sig -> {message, stack_trace}
	for block in blocks:
		var lines: PackedStringArray = String(block).split("\n", false)
		if lines.is_empty():
			continue
		var message: String = lines[0].strip_edges()
		var stack_trace: String = ""
		if lines.size() > 1:
			stack_trace = "\n".join(lines.slice(1))
		var sig: String = (message + "\n" + stack_trace).sha256_text()
		deltas[sig] = deltas.get(sig, 0) + 1
		details[sig] = {"message": message, "stack_trace": stack_trace}

	for sig in deltas.keys():
		var delta: int = deltas[sig]
		var detail: Dictionary = details[sig]
		if _live_signatures.has(sig):
			_live_signatures[sig]["total"] += delta
		else:
			_live_signatures[sig] = {
				"message": detail.message,
				"stack_trace": detail.stack_trace,
				"total": delta,
			}
		capture_error("ScriptError", detail.message, {
			"severity": "error",
			"handled": false,
			"stack_trace": detail.stack_trace,
			"occurrence_count": delta,
			"tags": {"capture_method": "live_log"},
		})


# ─── Native (Phase B) ─────────────────────────────────────────────────────

func _arm_native(config: FractalConfigClass) -> void:
	var helpers = load(_NATIVE_HELPERS_PATH)
	if helpers == null or not helpers.is_available():
		if config.debug:
			print("[Fractal] native crash capture unavailable on this platform")
		return
	var native = Engine.get_singleton("FractalNative")
	if native == null:
		return
	var has_get_version: bool = native.has_method("get_version")
	var reported_version: String = native.get_version() if has_get_version else ""
	if not FractalVersionClass.native_binary_matches(has_get_version, reported_version):
		push_error(
			"Fractal: native extension version %s does not match expected %s, update the entire addons/ folder. Native crash capture disabled; heartbeat crash detection still active." % [
				reported_version if has_get_version else "<missing get_version>",
				FractalVersionClass.native_binary_version_for(FractalVersionClass.current_platform_key()),
			]
		)
		return
	if not has_get_version and config.debug:
		print("[Fractal] arming pre-versioning native binary (predates get_version())")
	if not helpers.ensure_handler_executable(helpers.handler_path()):
		push_warning("Fractal: crashpad_handler is not executable and could not be repaired, native crash capture disabled")
		return
	var ok: bool = native.init(
		helpers.handler_path(),
		helpers.database_path(),
		config.app_version,
		config.environment,
	)
	if not ok:
		push_warning("Fractal: native crash capture init failed")
		return
	_native_armed = true
	# Mirror current scope into the native side so a crash carries them.
	var native_user := _metadata_user()
	native.set_user(native_user.get("id", ""), native_user)
	for k in _tags.keys():
		native.set_tag(k, str(_tags[k]))
	# Drain any minidumps left by a previous crash.
	_drain_pending_minidumps(native, helpers)


func _drain_pending_minidumps(native, helpers) -> void:
	var dumps: PackedStringArray = native.pending_minidumps(helpers.database_path())
	for dump_path in dumps:
		_upload_minidump(dump_path, native)


# Drain any pending native minidumps without calling sentry_init / arming
# Crashpad. Safe to call when the caller only needs to upload leftovers from a
# prior crash session, not arm for new crashes (e.g. the native_verify CI
# phase, where sentry_init would spin-loop on WSL2 with pending dumps held by
# the previous crashpad_handler).
func drain_pending_native() -> void:
	var helpers = load(_NATIVE_HELPERS_PATH)
	if helpers == null or not helpers.is_available():
		return
	var native_singleton = Engine.get_singleton("FractalNative")
	if native_singleton == null:
		return
	_drain_pending_minidumps(native_singleton, helpers)


func _upload_minidump(dump_path: String, native) -> void:
	if _config == null:
		return
	if _feature_gated:
		return
	var file := FileAccess.open(dump_path, FileAccess.READ)
	if file == null:
		push_warning("Fractal: cannot read minidump %s" % dump_path)
		return
	var bytes: PackedByteArray = file.get_buffer(file.get_length())
	file.close()

	var metadata := {
		"event_id": _uuid_from_bytes(bytes),
		"runtime": {"name": "godot", "version": _runtime_version()},
		"app_version": _release,
		"environment": _environment,
		"user": _metadata_user(),
		"tags": _tags,
		"breadcrumbs": _breadcrumbs.all() if _breadcrumbs else [],
		"platform": FractalPlatformDetectorClass.get_platform(),
		"os_version": FractalPlatformDetectorClass.get_os_version(),
		"sdk_version": FractalVersionClass.VERSION,
	}

	var boundary: String = "----FractalMinidump%s" % _hex_uuid()
	var body: PackedByteArray = _build_multipart_body(boundary, dump_path, bytes, metadata)
	var url: String = _config.collector_url.trim_suffix("/") + "/v1/minidumps"
	var headers := PackedStringArray([
		"Content-Type: multipart/form-data; boundary=%s" % boundary,
	])

	var http: FractalHttpClientClass = FractalHttpClientClass.new()
	add_child(http)
	http.configure(_config.api_key, _config.debug)
	# Note: minidump POST uses raw HTTPRequest path but with multipart body
	# instead of JSON. Using request_raw via a custom one-shot helper.
	http.request_completed.connect(func(_status, _h, _b):
		if _status >= 200 and _status < 300:
			if Engine.has_singleton("FractalNative"):
				native.delete_minidump(dump_path)
		http.queue_free()
	)
	http.request_failed.connect(func(_e, response_code = 0):
		if response_code == 402:
			if not _feature_gated:
				push_error("[Fractal] Error tracking is not included in your plan, errors are NOT being recorded. Upgrade to enable.")
			_feature_gated = true
			if Engine.has_singleton("FractalNative"):
				native.delete_minidump(dump_path)
		http.queue_free()
	)
	var err := http.request_raw_bytes(HTTPClient.METHOD_POST, url, headers, body)
	if err != OK:
		push_warning("Fractal: minidump request_raw failed: %s" % error_string(err))
		http.queue_free()


func _build_multipart_body(boundary: String, dump_path: String, dump_bytes: PackedByteArray, metadata: Dictionary) -> PackedByteArray:
	var body := PackedByteArray()
	var prefix := "--%s\r\nContent-Disposition: form-data; name=\"dump_format\"\r\n\r\ncrashpad\r\n" % boundary
	body.append_array(prefix.to_utf8_buffer())
	var meta_part := "--%s\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n%s\r\n" % [boundary, JSON.stringify(metadata)]
	body.append_array(meta_part.to_utf8_buffer())
	var dump_header := "--%s\r\nContent-Disposition: form-data; name=\"minidump\"; filename=\"%s\"\r\nContent-Type: application/octet-stream\r\n\r\n" % [boundary, dump_path.get_file()]
	body.append_array(dump_header.to_utf8_buffer())
	body.append_array(dump_bytes)
	body.append_array("\r\n--%s--\r\n".replace("%s", boundary).to_utf8_buffer())
	return body


static func _uuid_from_bytes(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	var h: PackedByteArray = ctx.finish()  # 32-byte SHA-256 digest
	h[6] = (h[6] & 0x0f) | 0x40  # version 4
	h[8] = (h[8] & 0x3f) | 0x80  # variant 10xx
	return "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x" % [
		h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
		h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]]


static func _hex_uuid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s := ""
	for i in range(8):
		s += "%02x" % rng.randi_range(0, 255)
	return s


static func _runtime_version() -> String:
	var v: Dictionary = Engine.get_version_info()
	return "%d.%d.%d" % [v.major, v.minor, v.patch]


static func _iso_now() -> String:
	var dt := Time.get_datetime_dict_from_system(true)
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]

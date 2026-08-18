class_name FractalSessionMarker
extends RefCounted
## Tracks an active SDK session in user://fractal/session.json.
##
## Lifecycle:
##   1. On configure(), `load_previous()` returns whatever the previous run
##      left behind. If `clean != true`, the caller infers an abnormal
##      shutdown and emits a synthetic AbnormalShutdown error.
##   2. `start_new()` overwrites the file with a fresh session (clean=false).
##   3. `tick()` rewrites the file with an updated last_heartbeat_at and the
##      latest breadcrumb/user/tag snapshot. Atomic write via temp+rename.
##   4. `mark_clean()` rewrites with clean=true on graceful shutdown.
##   5. `mark_crashed_via(reason)` rewrites with crashed_via=<reason> when
##      NOTIFICATION_CRASH or any other in-process crash signal fires.
##
## Schema is the cross-engine contract documented in
## sdks/shared/CRASH_PROTOCOL.md — Unity / Unreal / JS SDKs MUST write the
## same JSON shape into their respective persistent-data directories so the
## backend's `/v1/errors` ingestion stays uniform.

const SESSION_PATH := "user://fractal/session.json"
const SESSION_TMP_PATH := "user://fractal/session.json.tmp"

var _runtime: Dictionary = {"name": "godot", "version": ""}
var _state: Dictionary = {}


func _init() -> void:
	if Engine.has_method("get_version_info"):
		var v: Dictionary = Engine.get_version_info()
		_runtime["version"] = "%d.%d.%d" % [v.major, v.minor, v.patch]


## Returns the previous session marker, or {} if none exists.
## Callers inspect `clean` (bool) and `crashed_via` (string) to decide
## whether the previous session ended abnormally.
func load_previous() -> Dictionary:
	if not FileAccess.file_exists(SESSION_PATH):
		return {}
	var file := FileAccess.open(SESSION_PATH, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	if text.is_empty():
		return {}
	var json := JSON.new()
	if json.parse(text) != OK:
		# Corrupt marker — drop it.
		_remove_file()
		return {}
	var data: Variant = json.data
	return data if data is Dictionary else {}


## Begin a fresh session and persist it. Caller passes the static fields
## (app_version, environment, platform, os, os_version, user, tags) that
## won't change during the run; breadcrumbs are pulled live on each tick.
func start_new(static_fields: Dictionary) -> void:
	_state = {
		"session_id": "ses_%s" % _hex(8),
		"started_at": _iso_now(),
		"last_heartbeat_at": _iso_now(),
		"runtime": _runtime,
		"clean": false,
	}
	for key in static_fields.keys():
		_state[key] = static_fields[key]
	_state["breadcrumbs"] = []
	_write()


## Rewrite the marker with a fresh heartbeat timestamp and the supplied
## breadcrumb snapshot. Cheap — call from a Timer at low frequency (~10s).
func tick(breadcrumbs: Array, user: Dictionary, tags: Dictionary) -> void:
	if _state.is_empty():
		return
	_state["last_heartbeat_at"] = _iso_now()
	_state["breadcrumbs"] = breadcrumbs
	_state["user"] = user
	_state["tags"] = tags
	_write()


## Mark the current session as a clean exit. Called from
## NOTIFICATION_WM_CLOSE_REQUEST / NOTIFICATION_EXIT_TREE.
func mark_clean() -> void:
	if _state.is_empty():
		return
	_state["last_heartbeat_at"] = _iso_now()
	_state["clean"] = true
	_write()


## Record that the current session is dying through an in-process crash
## handler (e.g., NOTIFICATION_CRASH). Stays clean=false so the next run
## still treats it as abnormal.
func mark_crashed_via(reason: String) -> void:
	if _state.is_empty():
		return
	_state["crashed_via"] = reason
	_state["last_heartbeat_at"] = _iso_now()
	_write()


func clear() -> void:
	_remove_file()
	_state.clear()


func current_session_id() -> String:
	return _state.get("session_id", "")


# ─── Internal ─────────────────────────────────────────────────────────────

func _write() -> void:
	var dir := SESSION_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	# Atomic write: write to .tmp then rename. Avoids torn JSON if the
	# process dies mid-write.
	var file := FileAccess.open(SESSION_TMP_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Fractal: failed to open session marker tmp file")
		return
	file.store_string(JSON.stringify(_state))
	file.close()
	var err: int = DirAccess.rename_absolute(SESSION_TMP_PATH, SESSION_PATH)
	if err != OK:
		# rename failed (rare on local fs); fall back to direct write.
		var direct := FileAccess.open(SESSION_PATH, FileAccess.WRITE)
		if direct:
			direct.store_string(JSON.stringify(_state))
			direct.close()


func _remove_file() -> void:
	if FileAccess.file_exists(SESSION_PATH):
		DirAccess.remove_absolute(SESSION_PATH)
	if FileAccess.file_exists(SESSION_TMP_PATH):
		DirAccess.remove_absolute(SESSION_TMP_PATH)


static func _iso_now() -> String:
	var dt := Time.get_datetime_dict_from_system(true)
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]


static func _hex(n_bytes: int) -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s := ""
	for i in range(n_bytes):
		s += "%02x" % rng.randi_range(0, 255)
	return s

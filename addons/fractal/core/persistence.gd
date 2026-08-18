class_name FractalPersistence
extends RefCounted
## Persistent storage for player ID, offline event queue, crash reports, and translation cache.
##
## All files live under user://fractal/ to keep one tidy namespace.

const ROOT := "user://fractal"
const PLAYER_CONFIG_PATH := "user://fractal/player.cfg"
const QUEUE_PATH := "user://fractal/analytics_queue.json"
const EVENTS_DEAD_LETTER_PATH := "user://fractal/analytics_dead_letter.json"
const ERROR_QUEUE_PATH := "user://fractal/errors_queue.json"
const ERROR_DEAD_LETTER_PATH := "user://fractal/errors_dead_letter.json"
const CRASH_REPORT_PATH := "user://fractal/crash_report.json"
const TRANSLATIONS_DIR := "user://fractal/translations"
const TRANSLATIONS_ETAG_PATH := "user://fractal/translations_etags.cfg"
const MAX_PERSISTED_EVENTS := 500
const MAX_PERSISTED_ERRORS := 100


# ─── Player ID ────────────────────────────────────────────────────────────

static func load_player_id() -> String:
	_ensure_root()
	var config := ConfigFile.new()
	if config.load(PLAYER_CONFIG_PATH) != OK:
		return ""
	return config.get_value("player", "id", "")


static func save_player_id(player_id: String) -> void:
	_ensure_root()
	var config := ConfigFile.new()
	config.set_value("player", "id", player_id)
	if config.save(PLAYER_CONFIG_PATH) != OK:
		push_warning("Fractal: failed to save player ID")


static func generate_player_id() -> String:
	return "godot_" + _generate_uuid()


## Returns the persisted player ID, creating and persisting one on first call.
## Shared by analytics and errors so both converge on the same ID regardless
## of which subsystem configures first or whether the other is enabled.
static func resolve_player_id() -> String:
	var id := load_player_id()
	if id.is_empty():
		id = generate_player_id()
		save_player_id(id)
	return id


# ─── Analytics queue ──────────────────────────────────────────────────────

static func load_events() -> Array:
	if not FileAccess.file_exists(QUEUE_PATH):
		return []
	var file := FileAccess.open(QUEUE_PATH, FileAccess.READ)
	if file == null:
		return []
	var text := file.get_as_text()
	file.close()
	if text.is_empty():
		return []
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("Fractal: failed to parse persisted queue: %s" % json.get_error_message())
		return []
	var data: Variant = json.data
	if not data is Array:
		return []
	# JSON has no int/float distinction — Godot parses all numbers as float,
	# which would silently poison client_seq for restored events.
	for event in data:
		if event is Dictionary and event.has("client_seq"):
			event["client_seq"] = int(event["client_seq"])
	return data


static func save_events(events: Array) -> void:
	_ensure_root()
	if events.is_empty():
		clear_events()
		return
	var to_save: Array = events
	if events.size() > MAX_PERSISTED_EVENTS:
		to_save = events.slice(-MAX_PERSISTED_EVENTS)
	var file := FileAccess.open(QUEUE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Fractal: failed to save queue")
		return
	file.store_string(JSON.stringify(to_save))
	file.close()


static func clear_events() -> void:
	if FileAccess.file_exists(QUEUE_PATH):
		DirAccess.remove_absolute(QUEUE_PATH)


# ─── Dead-letter analytics queue ──────────────────────────────────────────
# Holds batches the collector permanently rejected (4xx other than 429) —
# retrying these forever would wedge all future uploads behind one poison
# batch. Never auto-retried; kept on disk so the batch can be inspected
# out-of-band. Mirrors the error dead-letter queue below.

static func load_dead_letter_events() -> Array:
	if not FileAccess.file_exists(EVENTS_DEAD_LETTER_PATH):
		return []
	var file := FileAccess.open(EVENTS_DEAD_LETTER_PATH, FileAccess.READ)
	if file == null:
		return []
	var text := file.get_as_text()
	file.close()
	if text.is_empty():
		return []
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("Fractal: failed to parse dead-letter event queue: %s" % json.get_error_message())
		return []
	var data: Variant = json.data
	return data if data is Array else []


static func append_to_dead_letter_events(events: Array) -> void:
	if events.is_empty():
		return
	_ensure_root()
	var existing := load_dead_letter_events()
	existing.append_array(events)
	if existing.size() > MAX_PERSISTED_EVENTS:
		existing = existing.slice(-MAX_PERSISTED_EVENTS)
	var file := FileAccess.open(EVENTS_DEAD_LETTER_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Fractal: failed to save dead-letter event queue")
		return
	file.store_string(JSON.stringify(existing))
	file.close()


# ─── Error queue (retry-safe across launches) ─────────────────────────────
# Mirrors the analytics queue: each entry is a fully-built error event
# (the same shape POSTed to /v1/errors). Drained on configure and on every
# successful flush. Cap at MAX_PERSISTED_ERRORS — when full, oldest go.

static func load_error_queue() -> Array:
	if not FileAccess.file_exists(ERROR_QUEUE_PATH):
		return []
	var file := FileAccess.open(ERROR_QUEUE_PATH, FileAccess.READ)
	if file == null:
		return []
	var text := file.get_as_text()
	file.close()
	if text.is_empty():
		return []
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("Fractal: failed to parse persisted error queue: %s" % json.get_error_message())
		return []
	var data: Variant = json.data
	return data if data is Array else []


static func save_error_queue(errors: Array) -> void:
	_ensure_root()
	if errors.is_empty():
		clear_error_queue()
		return
	var to_save: Array = errors
	if errors.size() > MAX_PERSISTED_ERRORS:
		to_save = errors.slice(-MAX_PERSISTED_ERRORS)
	var file := FileAccess.open(ERROR_QUEUE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Fractal: failed to save error queue")
		return
	file.store_string(JSON.stringify(to_save))
	file.close()


static func append_to_error_queue(events: Array) -> void:
	if events.is_empty():
		return
	var existing := load_error_queue()
	existing.append_array(events)
	save_error_queue(existing)


static func clear_error_queue() -> void:
	if FileAccess.file_exists(ERROR_QUEUE_PATH):
		DirAccess.remove_absolute(ERROR_QUEUE_PATH)


# ─── Dead-letter error queue ───────────────────────────────────────────────
# Holds batches the collector permanently rejected (4xx other than 402/429) —
# retrying these forever would wedge all future uploads behind one poison
# event. Never auto-retried; kept on disk so the bad payload can be inspected
# out-of-band.

static func load_dead_letter_error_queue() -> Array:
	if not FileAccess.file_exists(ERROR_DEAD_LETTER_PATH):
		return []
	var file := FileAccess.open(ERROR_DEAD_LETTER_PATH, FileAccess.READ)
	if file == null:
		return []
	var text := file.get_as_text()
	file.close()
	if text.is_empty():
		return []
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("Fractal: failed to parse dead-letter error queue: %s" % json.get_error_message())
		return []
	var data: Variant = json.data
	return data if data is Array else []


static func append_to_dead_letter_error_queue(errors: Array) -> void:
	if errors.is_empty():
		return
	_ensure_root()
	var existing := load_dead_letter_error_queue()
	existing.append_array(errors)
	if existing.size() > MAX_PERSISTED_ERRORS:
		existing = existing.slice(-MAX_PERSISTED_ERRORS)
	var file := FileAccess.open(ERROR_DEAD_LETTER_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Fractal: failed to save dead-letter error queue")
		return
	file.store_string(JSON.stringify(existing))
	file.close()


# ─── Crash report ─────────────────────────────────────────────────────────

static func save_crash_report(report: Dictionary) -> void:
	_ensure_root()
	var file := FileAccess.open(CRASH_REPORT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(report))
	file.close()


static func load_crash_report() -> Dictionary:
	if not FileAccess.file_exists(CRASH_REPORT_PATH):
		return {}
	var file := FileAccess.open(CRASH_REPORT_PATH, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		clear_crash_report()
		return {}
	var data: Variant = json.data
	return data if data is Dictionary else {}


static func clear_crash_report() -> void:
	if FileAccess.file_exists(CRASH_REPORT_PATH):
		DirAccess.remove_absolute(CRASH_REPORT_PATH)


# ─── Translations cache ───────────────────────────────────────────────────

static func translation_cache_path(locale: String) -> String:
	return TRANSLATIONS_DIR.path_join("%s.json" % locale)


static func save_translation_cache(locale: String, translations: Dictionary) -> void:
	_ensure_translations_dir()
	var file := FileAccess.open(translation_cache_path(locale), FileAccess.WRITE)
	if file == null:
		push_warning("Fractal: failed to write translation cache for %s" % locale)
		return
	file.store_string(JSON.stringify(translations))
	file.close()


static func load_translation_cache(locale: String) -> Dictionary:
	var path := translation_cache_path(locale)
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		# Corrupt cache — drop it.
		DirAccess.remove_absolute(path)
		return {}
	var data: Variant = json.data
	return data if data is Dictionary else {}


static func save_translation_etag(locale: String, etag: String) -> void:
	_ensure_root()
	var config := ConfigFile.new()
	config.load(TRANSLATIONS_ETAG_PATH)  # ok if missing
	config.set_value("etags", locale, etag)
	config.save(TRANSLATIONS_ETAG_PATH)


static func load_translation_etag(locale: String) -> String:
	var config := ConfigFile.new()
	if config.load(TRANSLATIONS_ETAG_PATH) != OK:
		return ""
	return config.get_value("etags", locale, "")


static func clear_translation_cache() -> void:
	var dir := DirAccess.open(TRANSLATIONS_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	if FileAccess.file_exists(TRANSLATIONS_ETAG_PATH):
		DirAccess.remove_absolute(TRANSLATIONS_ETAG_PATH)


# ─── Internal ─────────────────────────────────────────────────────────────

static func _ensure_root() -> void:
	if not DirAccess.dir_exists_absolute(ROOT):
		DirAccess.make_dir_recursive_absolute(ROOT)


static func _ensure_translations_dir() -> void:
	if not DirAccess.dir_exists_absolute(TRANSLATIONS_DIR):
		DirAccess.make_dir_recursive_absolute(TRANSLATIONS_DIR)


static func _generate_uuid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var b: Array[int] = []
	for i in range(16):
		b.append(rng.randi_range(0, 255))
	b[6] = (b[6] & 0x0f) | 0x40  # version 4
	b[8] = (b[8] & 0x3f) | 0x80  # variant 10xx
	return "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x" % [
		b[0], b[1], b[2], b[3],
		b[4], b[5],
		b[6], b[7],
		b[8], b[9],
		b[10], b[11], b[12], b[13], b[14], b[15],
	]

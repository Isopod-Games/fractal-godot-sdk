extends Node
## Translations subsystem, `Fractal.translations`.
##
## Pulls translations from the Fractal API at runtime and registers them with
## Godot's TranslationServer. Bundled `.translation` files remain the offline
## fallback. ETag/304 makes periodic re-sync cheap.

signal sync_started(locale: String)
signal sync_succeeded(locale: String, message_count: int)
signal sync_failed(locale: String, error: String)
signal language_changed(locale: String)

const FractalConfigClass := preload("res://addons/fractal/core/config.gd")
const FractalHttpClientClass := preload("res://addons/fractal/core/http_client.gd")
const FractalPersistenceClass := preload("res://addons/fractal/core/persistence.gd")
const FractalTranslationLoaderClass := preload("res://addons/fractal/translations/translation_loader.gd")

var _enabled: bool = false
var _config: FractalConfigClass = null
var _http: FractalHttpClientClass = null
var _loader: FractalTranslationLoaderClass

var _periodic_timer: Timer = null
var _pending_locale: String = ""
var _warned_project_id_deprecated: bool = false


func _ready() -> void:
	_loader = FractalTranslationLoaderClass.new()
	_periodic_timer = Timer.new()
	_periodic_timer.one_shot = false
	_periodic_timer.timeout.connect(sync)
	add_child(_periodic_timer)


func _exit_tree() -> void:
	# Remove our Translation registrations from the global TranslationServer so
	# we don't leak between successive configures (or tests).
	if _loader:
		_loader.clear()


func configure(config: FractalConfigClass) -> void:
	_config = config
	_enabled = config.translations_enabled

	if not _enabled:
		_periodic_timer.stop()
		return

	if not config.project_id.is_empty() and not _warned_project_id_deprecated:
		_warned_project_id_deprecated = true
		push_warning("Fractal.translations: config.project_id is deprecated and no longer used, the API key alone identifies your project. Safe to remove from your config.")

	# Load any cached translations from a previous session up-front so the UI
	# isn't waiting on the network for first paint.
	for locale in _resolve_locales():
		var cached: Dictionary = FractalPersistenceClass.load_translation_cache(locale)
		if not cached.is_empty():
			_loader.apply(locale, cached)

	if config.translations_sync_interval_hours > 0.0:
		_periodic_timer.wait_time = config.translations_sync_interval_hours * 3600.0
		_periodic_timer.start()
	else:
		_periodic_timer.stop()


# ─── Public API ───────────────────────────────────────────────────────────

func sync() -> void:
	if not _enabled:
		return
	for locale in _resolve_locales():
		sync_locale(locale)


func sync_locale(locale: String) -> void:
	if not _enabled:
		return
	if locale.is_empty():
		push_warning("Fractal.translations.sync_locale: locale required")
		return
	if _config == null or _config.api_url.is_empty():
		push_warning("Fractal.translations.sync_locale: api_url required")
		return

	# One HTTP client per request keeps locales independent and lets multiple
	# locales sync concurrently.
	var http: FractalHttpClientClass = FractalHttpClientClass.new()
	add_child(http)
	http.configure(_config.api_key, _config.debug)

	var url: String = "%s/api/v1/translations/sync?locale=%s" % [
		_config.api_url.trim_suffix("/"),
		locale,
	]
	var headers: PackedStringArray = PackedStringArray()
	var stored_etag: String = FractalPersistenceClass.load_translation_etag(locale)
	if not stored_etag.is_empty():
		headers.append("If-None-Match: " + stored_etag)

	http.request_completed.connect(_on_request_completed.bind(locale, http))
	http.request_failed.connect(_on_request_failed.bind(locale, http))

	sync_started.emit(locale)
	http.request(HTTPClient.METHOD_GET, url, headers, "", false)


func set_locale(locale: String) -> void:
	TranslationServer.set_locale(locale)
	language_changed.emit(locale)
	get_tree().root.propagate_notification(NOTIFICATION_TRANSLATION_CHANGED)


func get_locale() -> String:
	return TranslationServer.get_locale()


func available_locales() -> PackedStringArray:
	return _loader.registered_locales()


func is_enabled() -> bool:
	return _enabled


# ─── Internal ─────────────────────────────────────────────────────────────

func _resolve_locales() -> PackedStringArray:
	if _config and _config.translations_locales.size() > 0:
		return _config.translations_locales
	return TranslationServer.get_loaded_locales()


func _on_request_completed(status: int, response_headers: PackedStringArray, body: String, locale: String, http: FractalHttpClientClass) -> void:
	http.queue_free()

	if status == 304:
		var cached: Dictionary = FractalPersistenceClass.load_translation_cache(locale)
		if cached.is_empty():
			# We have an ETag but no cache, recover by clearing the ETag and re-fetching.
			FractalPersistenceClass.save_translation_etag(locale, "")
			sync_failed.emit(locale, "cache missing for 304 response")
			return
		var count: int = _loader.apply(locale, cached)
		sync_succeeded.emit(locale, count)
		return

	var json := JSON.new()
	if json.parse(body) != OK:
		sync_failed.emit(locale, "failed to parse response: %s" % json.get_error_message())
		return

	var data: Variant = json.data
	if not (data is Dictionary):
		sync_failed.emit(locale, "response was not a JSON object")
		return

	var translations: Dictionary = data.get("translations", {})
	if not (translations is Dictionary):
		sync_failed.emit(locale, "response missing 'translations' object")
		return

	var etag: String = _extract_etag(response_headers)
	if etag.is_empty():
		etag = data.get("etag", "")

	FractalPersistenceClass.save_translation_cache(locale, translations)
	if not etag.is_empty():
		FractalPersistenceClass.save_translation_etag(locale, etag)

	var count: int = _loader.apply(locale, translations)
	sync_succeeded.emit(locale, count)


func _on_request_failed(error: String, _response_code: int, locale: String, http: FractalHttpClientClass) -> void:
	http.queue_free()
	# On any failure, fall back to whatever we have cached. The UI will keep
	# rendering with bundled translations and (if present) cached overrides.
	var cached: Dictionary = FractalPersistenceClass.load_translation_cache(locale)
	if not cached.is_empty():
		_loader.apply(locale, cached)
	sync_failed.emit(locale, error)


static func _extract_etag(headers: PackedStringArray) -> String:
	for header in headers:
		var lower: String = header.to_lower()
		if lower.begins_with("etag:"):
			return header.substr(5).strip_edges()
	return ""

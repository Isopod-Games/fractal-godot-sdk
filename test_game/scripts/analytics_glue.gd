extends Node
## Bridges GameState signals to Fractal SDK calls + handles one-time SDK init.
##
## Registered as the `AnalyticsGlue` autoload (see project.godot). This is the
## single place where the test game tells Fractal "this happened", keeping
## analytics tied to here makes assertions in tests straightforward.

const TRANSLATION_CSV := "res://test_game/localization/strings.csv"

var _configured: bool = false
var _analytics_enabled: bool = true
var _errors_enabled: bool = true


func _ready() -> void:
	# Load translations from the bundled CSV directly via TranslationServer so we
	# don't depend on the Godot editor having pre-imported the CSV. This makes
	# the test_game work in headless smoke runs.
	_register_translations_from_csv()

	# CI bypass: when FRACTAL_CI_MODE is set, the live integration driver
	# fully controls Fractal.configure(...), skip the placeholder init here
	# so the driver's call is the FIRST configure (and therefore the one
	# that drives the persisted-state drain).
	if not OS.get_environment("FRACTAL_CI_MODE").is_empty():
		return

	# One-time SDK init. Failures (e.g., collector unreachable) are silent, the
	# SDK queues + retries, so the game keeps running without nagging the player.
	Fractal.configure(_build_config())
	Fractal.analytics.start_session()
	_configured = true

	# Wire game signals to SDK calls. GameState is its own autoload, so we look
	# it up via the scene tree to keep this script independent of load order.
	var game_state := get_node_or_null("/root/GameState")
	if game_state:
		game_state.achievement_unlocked.connect(_on_achievement_unlocked)
		game_state.prestiged.connect(_on_prestiged)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _configured:
		Fractal.analytics.end_session()


# ─── Public toggles (called by settings UI) ───────────────────────────────

func set_analytics_enabled(enabled: bool) -> void:
	_analytics_enabled = enabled
	Fractal.configure(_build_config())


func set_errors_enabled(enabled: bool) -> void:
	_errors_enabled = enabled
	Fractal.configure(_build_config())


func is_analytics_enabled() -> bool:
	return _analytics_enabled


func is_errors_enabled() -> bool:
	return _errors_enabled


# ─── Internal ─────────────────────────────────────────────────────────────

func _build_config() -> Dictionary:
	return {
		"api_key": "dev-key-clicker",
		"collector_url": "http://localhost:8080",
		"api_url": "http://localhost:3001",
		"project_id": "demo",
		"app_version": "0.1.0",
		"environment": "development",
		"analytics_enabled": _analytics_enabled,
		"errors_enabled": _errors_enabled,
		"translations_enabled": true,
		"translations_locales": PackedStringArray(["en", "es", "fr"]),
		"translations_sync_on_startup": false,
		"debug": true,
	}


func _on_achievement_unlocked(achievement: String) -> void:
	Fractal.analytics.track("achievement_unlocked", {"name": achievement})
	Fractal.errors.add_breadcrumb("achievement: " + achievement, "game", "info")


func _on_prestiged() -> void:
	Fractal.analytics.track("prestiged", {})


func _register_translations_from_csv() -> void:
	if not FileAccess.file_exists(TRANSLATION_CSV):
		push_warning("AnalyticsGlue: translation CSV missing at %s" % TRANSLATION_CSV)
		return
	var file := FileAccess.open(TRANSLATION_CSV, FileAccess.READ)
	if file == null:
		return
	var header_line := file.get_csv_line()
	if header_line.size() < 2:
		file.close()
		return
	# Header: keys, en, es, fr, locale columns start at index 1.
	var locales: Array[String] = []
	for i in range(1, header_line.size()):
		locales.append(header_line[i])

	var translations_per_locale: Dictionary = {}
	for locale in locales:
		translations_per_locale[locale] = Translation.new()
		translations_per_locale[locale].locale = locale

	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() < 2 or row[0].is_empty():
			continue
		var key: String = row[0]
		for i in range(1, min(row.size(), header_line.size())):
			var locale := header_line[i]
			if i < row.size():
				translations_per_locale[locale].add_message(key, row[i])
	file.close()

	for locale in locales:
		TranslationServer.add_translation(translations_per_locale[locale])

	# Default to English on first run, game scripts use tr() throughout.
	if "en" in locales:
		TranslationServer.set_locale("en")

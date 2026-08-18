extends SceneTree
## Headless prod smoke test for the Fractal SDK (v2 API).
##
## Run with:
##   FRACTAL_API_KEY=<key> godot --headless --path sdks/godot --script test_prod.gd
##
## Optional env vars:
##   FRACTAL_COLLECTOR    defaults to https://collector.getfractal.dev
##   FRACTAL_API_URL      defaults to https://getfractal.dev
##   FRACTAL_PROJECT_ID   numeric project ID (find it in Project Settings → SDK Integration);
##                        if omitted, translations sync is skipped

var _analytics_done := false
var _errors_done := false
var _translations_done := false
var _translations_enabled := false
var _batches_sent := 0
var _total_events_sent := 0
var _expected_events := 0


func _initialize() -> void:
	print("\n=== Fractal SDK v2 - Prod Test ===\n")
	call_deferred("_run_test")


func _run_test() -> void:
	var api_key := OS.get_environment("FRACTAL_API_KEY")
	if api_key.is_empty():
		print("[Test] ERROR: FRACTAL_API_KEY env var not set")
		quit(1)
		return

	var collector_url := OS.get_environment("FRACTAL_COLLECTOR")
	if collector_url.is_empty():
		collector_url = "https://collector.getfractal.dev"

	var api_url := OS.get_environment("FRACTAL_API_URL")
	if api_url.is_empty():
		api_url = "https://getfractal.dev"

	var project_id := OS.get_environment("FRACTAL_PROJECT_ID")
	_translations_enabled = not project_id.is_empty()
	_translations_done = not _translations_enabled
	if not _translations_enabled:
		print("[Test] FRACTAL_PROJECT_ID not set — skipping translations test")

	var fractal: Node = root.get_node("Fractal")

	fractal.analytics.batch_sent.connect(_on_batch_sent)
	fractal.analytics.batch_failed.connect(_on_batch_failed)
	fractal.errors.error_sent.connect(_on_error_sent)
	fractal.errors.error_failed.connect(_on_error_failed)
	fractal.translations.sync_succeeded.connect(_on_translation_sync_succeeded)
	fractal.translations.sync_failed.connect(_on_translation_sync_failed)

	var config := {
		"api_key": api_key,
		"collector_url": collector_url,
		"app_version": "1.0.0",
		"environment": "production",
		"debug": true,
		"analytics_enabled": true,
		"errors_enabled": true,
		"translations_enabled": _translations_enabled,
		"api_url": api_url,
		"translations_locales": PackedStringArray(["en"]),
		"translations_sync_on_startup": false,
		"errors_session_marker_enabled": false,
		"analytics_batch_size": 20,
		"analytics_flush_interval": 60.0,
	}
	if _translations_enabled:
		config["project_id"] = project_id
	fractal.configure(config)

	# Analytics
	fractal.analytics.start_session()
	fractal.analytics.track("godot_sdk_test", {
		"source": "headless_prod_test",
		"message": "Hello from the Fractal Godot SDK v2!",
	})
	fractal.analytics.track("run_start", {"character": "Mage"})
	fractal.analytics.track("floor_enter", {"floor_number": 1})
	fractal.analytics.track("enemy_kill", {"floor_number": 1, "enemy_type": "Goblin"})
	fractal.analytics.track("item_pickup", {
		"item_name": "Health Potion",
		"item_type": "consumable",
		"floor_number": 1,
	})
	fractal.analytics.track("boss_kill", {"floor_number": 3, "boss_name": "Dragon Lord"})
	fractal.analytics.track("run_end", {
		"character": "Mage",
		"floors_reached": 3,
		"score": 3000,
		"duration_seconds": 180,
		"victory": true,
		"enemies_killed": 25,
		"gold_earned": 300,
		"items_collected": 4,
	})
	fractal.analytics.end_session()

	_expected_events = fractal.analytics.get_pending_event_count()
	print("\n%d analytics events queued. Flushing...\n" % _expected_events)
	fractal.analytics.flush()

	# Errors
	fractal.errors.add_breadcrumb("prod_test started", "test", "info")
	fractal.errors.capture_error("ProdTestError", "Intentional error from headless prod test", {
		"severity": "warning",
		"handled": true,
		"extra": {"source": "test_prod.gd"},
	})

	# Translations
	if _translations_enabled:
		fractal.translations.sync()

	# Safety timeout
	await create_timer(15.0).timeout
	print("[Test] TIMEOUT — check network/collector")
	quit(1)


func _check_done() -> void:
	if _analytics_done and _errors_done and _translations_done:
		var parts := "analytics + errors"
		if _translations_enabled:
			parts += " + translations"
		print("\n=== Success: %s delivered to prod ===\n" % parts)
		quit(0)


func _on_batch_sent(count: int) -> void:
	_batches_sent += 1
	_total_events_sent += count
	print("[Analytics] Batch #%d sent: %d events" % [_batches_sent, count])
	var fractal: Node = root.get_node("Fractal")
	if fractal.analytics.get_pending_event_count() == 0:
		print("[Analytics] %d/%d events delivered" % [_total_events_sent, _expected_events])
		_analytics_done = true
		_check_done()


func _on_batch_failed(error: String) -> void:
	print("[Analytics] FAILED: %s" % error)
	quit(1)


func _on_error_sent() -> void:
	print("[Errors] error report sent")
	_errors_done = true
	_check_done()


func _on_error_failed(message: String) -> void:
	print("[Errors] FAILED: %s" % message)
	quit(1)


func _on_translation_sync_succeeded(locale: String, message_count: int) -> void:
	print("[Translations] sync succeeded: locale=%s messages=%d" % [locale, message_count])
	_translations_done = true
	_check_done()


func _on_translation_sync_failed(locale: String, error: String) -> void:
	print("[Translations] FAILED: locale=%s error=%s" % [locale, error])
	quit(1)

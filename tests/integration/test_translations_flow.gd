extends GdUnitTestSuite

const FractalMockServerClass = preload("res://tests/integration/mock_server.gd")
const FractalConfigClass = preload("res://addons/fractal/core/config.gd")
const FractalTranslationsClass = preload("res://addons/fractal/translations/translations.gd")
const FractalPersistenceClass = preload("res://addons/fractal/core/persistence.gd")
const FractalTestHelpersClass = preload("res://tests/helpers/test_helpers.gd")

var server: Node
var translations: Node


func before_test() -> void:
	if DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		FractalTestHelpersClass.remove_dir_recursive(FractalPersistenceClass.ROOT)

	server = FractalMockServerClass.new()
	add_child(server)
	server.start()

	translations = FractalTranslationsClass.new()
	add_child(translations)
	await get_tree().process_frame


func after_test() -> void:
	if translations:
		translations.queue_free()
	if server:
		server.stop()
		server.queue_free()
	if DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		FractalTestHelpersClass.remove_dir_recursive(FractalPersistenceClass.ROOT)


func _make_config() -> FractalConfig:
	var config: FractalConfig = FractalConfigClass.new()
	config.api_key = "test-key"
	config.collector_url = server.url()
	config.api_url = server.url()
	config.translations_enabled = true
	config.translations_locales = PackedStringArray(["es"])
	config.translations_sync_on_startup = false
	config.analytics_enabled = false
	config.errors_enabled = false
	return config


func test_sync_populates_translation_server() -> void:
	var response_body: String = JSON.stringify({
		"locale": "es",
		"etag": "etag-123",
		"translations": {"ui.start": "Comenzar", "ui.quit": "Salir"},
	})
	server.enqueue_response("GET", "/api/v1/translations/sync", 200, response_body, {"ETag": "etag-123"})

	translations.configure(_make_config())

	var succeeded: Array = []
	translations.sync_succeeded.connect(func(locale, count): succeeded.append({"locale": locale, "count": count}))
	translations.sync()

	var ok: bool = await FractalTestHelpersClass.wait_for(get_tree(), func(): return not succeeded.is_empty(), 5000)
	assert_bool(ok).is_true()
	assert_str(succeeded[0].locale).is_equal("es")
	assert_int(succeeded[0].count).is_equal(2)

	# Translation server populated.
	var prev: String = TranslationServer.get_locale()
	TranslationServer.set_locale("es")
	assert_str(TranslationServer.translate("ui.start")).is_equal("Comenzar")
	TranslationServer.set_locale(prev)

	# Cache + ETag persisted.
	var cached: Dictionary = FractalPersistenceClass.load_translation_cache("es")
	assert_str(cached["ui.start"]).is_equal("Comenzar")
	assert_str(FractalPersistenceClass.load_translation_etag("es")).is_equal("etag-123")


func test_sync_uses_cache_on_304() -> void:
	# Pre-seed cache + etag.
	FractalPersistenceClass.save_translation_cache("es", {"ui.start": "CachedComenzar"})
	FractalPersistenceClass.save_translation_etag("es", "etag-prev")

	# Mock server responds 304 (no body).
	server.enqueue_response("GET", "/api/v1/translations/sync", 304, "")

	translations.configure(_make_config())

	var succeeded: Array = []
	translations.sync_succeeded.connect(func(_locale, count): succeeded.append(count))
	translations.sync()

	var ok: bool = await FractalTestHelpersClass.wait_for(get_tree(), func(): return not succeeded.is_empty(), 5000)
	assert_bool(ok).is_true()

	# Verify the request sent If-None-Match header.
	assert_int(server.requests.size()).is_equal(1)
	assert_str(server.requests[0].headers.get("if-none-match", "")).is_equal("etag-prev")

	var prev: String = TranslationServer.get_locale()
	TranslationServer.set_locale("es")
	assert_str(TranslationServer.translate("ui.start")).is_equal("CachedComenzar")
	TranslationServer.set_locale(prev)


func test_sync_failure_falls_back_to_cache() -> void:
	# Pre-seed cache; server returns 500.
	FractalPersistenceClass.save_translation_cache("es", {"ui.start": "CachedFallback"})
	# Note: 500 will trigger the http_client retry path. Use 400 to fail fast.
	server.enqueue_response("GET", "/api/v1/translations/sync", 400, "bad")

	translations.configure(_make_config())

	var failed: Array = []
	translations.sync_failed.connect(func(_locale, err): failed.append(err))
	translations.sync()

	var ok: bool = await FractalTestHelpersClass.wait_for(get_tree(), func(): return not failed.is_empty(), 5000)
	assert_bool(ok).is_true()

	# Cached translation should still be applied.
	var prev: String = TranslationServer.get_locale()
	TranslationServer.set_locale("es")
	assert_str(TranslationServer.translate("ui.start")).is_equal("CachedFallback")
	TranslationServer.set_locale(prev)


func test_no_op_when_disabled() -> void:
	var config: FractalConfig = _make_config()
	config.translations_enabled = false
	translations.configure(config)
	translations.sync()
	for i in range(3):
		await get_tree().process_frame
	assert_int(server.requests.size()).is_equal(0)


func test_project_id_deprecation_warning_fires_once() -> void:
	# Regression: repeated configure() calls (e.g. the documented runtime-toggle
	# pattern) must not re-warn every time project_id is still set.
	var config: FractalConfig = _make_config()
	config.project_id = "legacy-project-id"

	assert_bool(translations._warned_project_id_deprecated).is_false()

	translations.configure(config)
	assert_bool(translations._warned_project_id_deprecated).is_true()

	translations.configure(config)
	assert_bool(translations._warned_project_id_deprecated).is_true()

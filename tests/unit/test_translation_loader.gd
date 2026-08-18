extends GdUnitTestSuite

const FractalTranslationLoaderClass = preload("res://addons/fractal/translations/translation_loader.gd")


var loader: FractalTranslationLoader


func before_test() -> void:
	loader = FractalTranslationLoaderClass.new()


func after_test() -> void:
	loader.clear()


func test_apply_registers_messages() -> void:
	var count: int = loader.apply("xx", {"hello": "Hola", "bye": "Adios"})
	assert_int(count).is_equal(2)
	# Switch locale to xx and confirm lookup hits.
	var prev: String = TranslationServer.get_locale()
	TranslationServer.set_locale("xx")
	assert_str(TranslationServer.translate("hello")).is_equal("Hola")
	assert_str(TranslationServer.translate("bye")).is_equal("Adios")
	TranslationServer.set_locale(prev)


func test_apply_replaces_previous_for_same_locale() -> void:
	loader.apply("xx", {"hello": "Old"})
	loader.apply("xx", {"hello": "New"})  # same locale, different value
	var prev: String = TranslationServer.get_locale()
	TranslationServer.set_locale("xx")
	assert_str(TranslationServer.translate("hello")).is_equal("New")
	TranslationServer.set_locale(prev)


func test_apply_skips_non_string_values() -> void:
	# Translation.add_message takes Strings only; non-string values should be ignored.
	var count: int = loader.apply("xx", {"a": "valid", "b": 42, "c": null})
	assert_int(count).is_equal(1)


func test_clear_unregisters_all() -> void:
	loader.apply("xx", {"hello": "Hola"})
	loader.apply("yy", {"hello": "Bonjour"})
	loader.clear()
	# Translations should no longer resolve via this loader.
	var prev: String = TranslationServer.get_locale()
	TranslationServer.set_locale("xx")
	assert_str(TranslationServer.translate("hello")).is_equal("hello")  # falls through to key
	TranslationServer.set_locale(prev)


func test_registered_locales_reflects_state() -> void:
	loader.apply("xx", {"a": "b"})
	loader.apply("yy", {"a": "b"})
	var locales: PackedStringArray = loader.registered_locales()
	assert_int(locales.size()).is_equal(2)
	assert_array(locales).contains(["xx", "yy"])

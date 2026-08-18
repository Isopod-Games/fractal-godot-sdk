@tool
extends Node
## Fractal SDK autoload — single facade for analytics, errors, and translations.
##
## Configure once at startup, then use the subsystem accessors:
##
##     Fractal.configure(preload("res://fractal_config.tres"))
##     Fractal.analytics.track("level_complete", {"level": 5})
##     Fractal.errors.capture_error("NPE", "Object reference was null")
##     Fractal.translations.sync()
##
## Each subsystem honors its `*_enabled` toggle: disabled subsystems no-op
## without making any HTTP requests.

signal initialized

const FractalConfigClass := preload("res://addons/fractal/core/config.gd")
const FractalAnalyticsClass := preload("res://addons/fractal/analytics/analytics.gd")
const FractalErrorsClass := preload("res://addons/fractal/errors/errors.gd")
const FractalTranslationsClass := preload("res://addons/fractal/translations/translations.gd")

## Subsystems. Always non-null after configure() — they short-circuit when disabled.
var analytics
var errors
var translations

var _config
var _initialized: bool = false


func _ready() -> void:
	# Lazily-instantiated subsystems get a stub config so accessors never null-deref
	# even if the user forgets to call configure(). Real init happens in configure().
	_config = FractalConfigClass.new()
	analytics = FractalAnalyticsClass.new()
	errors = FractalErrorsClass.new()
	translations = FractalTranslationsClass.new()
	add_child(analytics)
	add_child(errors)
	add_child(translations)
	errors.set_analytics(analytics)


func _notification(what: int) -> void:
	if not _initialized:
		return
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_EXIT_TREE:
			if analytics:
				analytics.shutdown()
			if errors:
				errors.mark_clean_shutdown()
		NOTIFICATION_CRASH:
			if errors:
				errors.handle_crash()


## Configures the SDK. Accepts either a `FractalConfig` Resource or a Dictionary
## of overrides (merged on top of defaults). Calling configure() repeatedly is
## supported — the SDK will reconfigure each subsystem with the new settings.
func configure(config_or_dict) -> void:
	if config_or_dict is Dictionary:
		_config = _config.merged(config_or_dict)
	elif config_or_dict is FractalConfigClass:
		_config = config_or_dict
	else:
		push_error("Fractal.configure: expected FractalConfig resource or Dictionary, got %s" % typeof(config_or_dict))
		return

	var validation: Dictionary = _config.is_valid()
	if not validation.valid:
		for err in validation.errors:
			push_error("Fractal config: %s" % err)
		return

	analytics.configure(_config)
	errors.configure(_config)
	translations.configure(_config)

	_initialized = true
	if _config.debug:
		print("[Fractal] initialized (analytics=%s, errors=%s, translations=%s)" % [
			_config.analytics_enabled, _config.errors_enabled, _config.translations_enabled,
		])

	# Errors subsystem drains its own persisted state (queued errors,
	# crash report, abnormal-shutdown inference) inside configure() —
	# the explicit call from here is no longer needed.
	if _config.translations_enabled and _config.translations_sync_on_startup:
		translations.sync()

	initialized.emit()


func is_initialized() -> bool:
	return _initialized


func get_config():
	return _config

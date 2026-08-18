extends GdUnitTestSuite
## Validates errors.gd::_init_live_log_capture's handling of the
## debug/file_logging/enable_file_logging prerequisite, regression coverage
## for upgrading the local push_warning to an actionable push_error.

const FractalErrorsClass = preload("res://addons/fractal/errors/errors.gd")
const SETTING := "debug/file_logging/enable_file_logging"

var errors: Node
var _original_setting: Variant


func before_test() -> void:
	_original_setting = ProjectSettings.get_setting(SETTING, false)
	errors = FractalErrorsClass.new()
	add_child(errors)
	await get_tree().process_frame


func after_test() -> void:
	ProjectSettings.set_setting(SETTING, _original_setting)
	if errors:
		errors.queue_free()


func test_push_error_and_disables_capture_when_file_logging_off() -> void:
	ProjectSettings.set_setting(SETTING, false)

	await assert_error(func(): errors._init_live_log_capture()) \
		.is_push_error(
			"[Fractal] errors_live_log_capture_enabled is on but ScriptErrors will NOT be captured " +
			"automatically, enable Project Settings > Debug > File Logging > Enable File Logging " +
			"(debug/file_logging/enable_file_logging) to fix this. capture_error() still works without it. " +
			"See sdks/godot/docs/ERRORS.md#layer-4-live-log-tailing--scripterror"
		)

	assert_bool(errors._live_capture_enabled).is_false()


func test_no_error_when_file_logging_on() -> void:
	ProjectSettings.set_setting(SETTING, true)

	await assert_error(func(): errors._init_live_log_capture()).is_success()

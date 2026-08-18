extends Control
## Settings/debug menu — language picker, translation sync, error throw triggers.

const MENU_SCENE := "res://test_game/scenes/main_menu.tscn"

# Order matches OptionButton items (id == index by default).
const LOCALES: Array[String] = ["en", "es", "fr"]

@onready var language_label: Label = %LanguageLabel
@onready var language_picker: OptionButton = %LanguagePicker
@onready var sync_button: Button = %SyncButton
@onready var throw_error_button: Button = %ThrowErrorButton
@onready var throw_fatal_button: Button = %ThrowFatalButton
@onready var force_crash_button: Button = %ForceCrashButton
@onready var kill_app_button: Button = %KillAppButton
@onready var force_segfault_button: Button = %ForceSegfaultButton
@onready var crash_confirm: ConfirmationDialog = %CrashConfirm
@onready var analytics_toggle: CheckButton = %AnalyticsToggle
@onready var errors_toggle: CheckButton = %ErrorsToggle
@onready var back_button: Button = %BackButton


func _ready() -> void:
	_populate_language_picker()
	_refresh_text()
	_sync_toggle_states()

	language_picker.item_selected.connect(_on_language_selected)
	sync_button.pressed.connect(_on_sync_pressed)
	throw_error_button.pressed.connect(_on_throw_error)
	throw_fatal_button.pressed.connect(_on_throw_fatal)
	force_crash_button.pressed.connect(_on_force_crash_pressed)
	kill_app_button.pressed.connect(_on_kill_app_pressed)
	force_segfault_button.pressed.connect(_on_force_segfault_pressed)
	crash_confirm.confirmed.connect(_on_crash_confirmed)
	analytics_toggle.toggled.connect(_on_analytics_toggled)
	errors_toggle.toggled.connect(_on_errors_toggled)
	back_button.pressed.connect(func(): get_tree().change_scene_to_file(MENU_SCENE))


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_refresh_text()


func _populate_language_picker() -> void:
	language_picker.clear()
	language_picker.add_item("English", 0)
	language_picker.add_item("Español", 1)
	language_picker.add_item("Français", 2)
	var current: String = TranslationServer.get_locale()
	for i in range(LOCALES.size()):
		if LOCALES[i] == current:
			language_picker.select(i)
			return
	language_picker.select(0)


func _refresh_text() -> void:
	language_label.text = tr("settings.language")
	sync_button.text = tr("settings.sync")
	throw_error_button.text = tr("settings.throw_error")
	throw_fatal_button.text = tr("settings.throw_fatal")
	force_crash_button.text = tr("settings.force_crash")
	back_button.text = tr("settings.back")
	crash_confirm.dialog_text = tr("settings.force_crash") + "?"


func _sync_toggle_states() -> void:
	var glue := get_node_or_null("/root/AnalyticsGlue")
	if glue:
		analytics_toggle.button_pressed = glue.is_analytics_enabled()
		errors_toggle.button_pressed = glue.is_errors_enabled()
	analytics_toggle.text = "Analytics enabled"
	errors_toggle.text = "Errors enabled"


func _on_language_selected(index: int) -> void:
	if index < 0 or index >= LOCALES.size():
		return
	Fractal.translations.set_locale(LOCALES[index])


func _on_sync_pressed() -> void:
	Fractal.translations.sync()


func _on_throw_error() -> void:
	Fractal.errors.capture_error("DebugError", "user clicked throw button", {
		"severity": "warning",
		"handled": true,
	})


func _on_throw_fatal() -> void:
	Fractal.errors.capture_error("DebugFatal", "user clicked fatal button", {
		"severity": "fatal",
		"handled": false,
	})


func _on_force_crash_pressed() -> void:
	# Confirmation dialog — guarded so the player can't trash their session
	# from a stray click.
	crash_confirm.popup_centered()


func _on_crash_confirmed() -> void:
	OS.crash("user requested crash")


func _on_kill_app_pressed() -> void:
	# Sends SIGKILL to our own process — exits without firing
	# NOTIFICATION_CRASH or NOTIFICATION_WM_CLOSE_REQUEST. The next launch
	# detects this via the heartbeat session marker and reports an
	# AbnormalShutdown error.
	OS.kill(OS.get_process_id())


func _on_force_segfault_pressed() -> void:
	# Phase B path: dereferences null in the native GDExtension. Crashpad
	# catches the SIGSEGV out-of-process and writes a real minidump. Next
	# launch drains the dump and uploads to /v1/minidumps as a NativeCrash.
	if not Engine.has_singleton("FractalNative"):
		push_warning("FractalNative GDExtension not installed — segfault button is a no-op")
		return
	var native = Engine.get_singleton("FractalNative")
	native._force_segfault_for_testing()


func _on_analytics_toggled(pressed: bool) -> void:
	var glue := get_node_or_null("/root/AnalyticsGlue")
	if glue:
		glue.set_analytics_enabled(pressed)


func _on_errors_toggled(pressed: bool) -> void:
	var glue := get_node_or_null("/root/AnalyticsGlue")
	if glue:
		glue.set_errors_enabled(pressed)

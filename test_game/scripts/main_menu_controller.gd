extends Control
## Main menu, title + Play/Settings buttons.

const CLICKER_SCENE := "res://test_game/scenes/clicker.tscn"
const SETTINGS_SCENE := "res://test_game/scenes/settings.tscn"

@onready var title_label: Label = %TitleLabel
@onready var play_button: Button = %PlayButton
@onready var settings_button: Button = %SettingsButton

# Static so it survives scene-change cycles within one process, we want
# `app_open` exactly once per app launch, not once per "return to main menu".
static var _emitted_app_open: bool = false


func _ready() -> void:
	_refresh_text()
	play_button.pressed.connect(_on_play_pressed)
	settings_button.pressed.connect(_on_settings_pressed)

	if not _emitted_app_open:
		_emitted_app_open = true
		Fractal.analytics.track("app_open", {})


func _notification(what: int) -> void:
	# `_notification` can fire before `_ready` (e.g. translation registered while the
	# scene is still being constructed), bail until @onready vars are populated.
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_refresh_text()


func _refresh_text() -> void:
	title_label.text = tr("menu.title")
	play_button.text = tr("menu.play")
	settings_button.text = tr("menu.settings")


func _on_play_pressed() -> void:
	get_tree().change_scene_to_file(CLICKER_SCENE)


func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file(SETTINGS_SCENE)

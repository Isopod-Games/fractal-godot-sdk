extends Control
## Achievements list — translated names + locked/unlocked indicator per row.

const CLICKER_SCENE := "res://test_game/scenes/clicker.tscn"

@onready var list_container: VBoxContainer = %ListContainer
@onready var back_button: Button = %BackButton

var _game_state: Node
var _row_labels: Array[Label] = []


func _ready() -> void:
	_game_state = get_node("/root/GameState")
	back_button.pressed.connect(func(): get_tree().change_scene_to_file(CLICKER_SCENE))
	_build_rows()
	_refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_refresh()


func _build_rows() -> void:
	for ach_key in _game_state.ALL_ACHIEVEMENTS:
		var label := Label.new()
		label.set_meta("achievement_key", ach_key)
		list_container.add_child(label)
		_row_labels.append(label)


func _refresh() -> void:
	back_button.text = tr("settings.back")
	for label in _row_labels:
		var key: String = label.get_meta("achievement_key")
		var unlocked: bool = _game_state.is_unlocked(key)
		var marker := "[x]" if unlocked else "(locked)"
		label.text = "%s  %s" % [marker, tr(key)]

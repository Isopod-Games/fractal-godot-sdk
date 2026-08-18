extends Control
## Core gameplay scene — TAP button, counters, milestones, and auto-tap timer.

const MENU_SCENE := "res://test_game/scenes/main_menu.tscn"
const SHOP_SCENE := "res://test_game/scenes/shop.tscn"
const ACHIEVEMENTS_SCENE := "res://test_game/scenes/achievements.tscn"
const SETTINGS_SCENE := "res://test_game/scenes/settings.tscn"

const MILESTONES: Array[int] = [10, 100, 1000]

@onready var tap_button: Button = %TapButton
@onready var coins_label: Label = %CoinsLabel
@onready var per_tap_label: Label = %PerTapLabel
@onready var auto_tap_label: Label = %AutoTapLabel
@onready var shop_button: Button = %ShopButton
@onready var achievements_button: Button = %AchievementsButton
@onready var settings_button: Button = %SettingsButton
@onready var menu_button: Button = %MenuButton
@onready var auto_tap_timer: Timer = %AutoTapTimer

var _game_state: Node
var _milestones_fired: Array[int] = []


func _ready() -> void:
	_game_state = get_node("/root/GameState")
	_game_state.coins_changed.connect(_on_coins_changed)

	tap_button.pressed.connect(_on_tap)
	shop_button.pressed.connect(func(): get_tree().change_scene_to_file(SHOP_SCENE))
	achievements_button.pressed.connect(func(): get_tree().change_scene_to_file(ACHIEVEMENTS_SCENE))
	settings_button.pressed.connect(func(): get_tree().change_scene_to_file(SETTINGS_SCENE))
	menu_button.pressed.connect(func(): get_tree().change_scene_to_file(MENU_SCENE))

	auto_tap_timer.wait_time = 1.0
	auto_tap_timer.timeout.connect(_on_auto_tap_tick)
	auto_tap_timer.start()

	_refresh_text()
	_refresh_counters()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_refresh_text()


func _refresh_text() -> void:
	tap_button.text = tr("clicker.tap")
	shop_button.text = tr("clicker.shop")
	achievements_button.text = tr("clicker.achievements")
	settings_button.text = tr("clicker.settings")
	menu_button.text = tr("clicker.menu")


func _refresh_counters() -> void:
	coins_label.text = "Coins: %d" % _game_state.coins
	per_tap_label.text = "Per tap: %d" % _game_state.per_tap
	auto_tap_label.text = "Auto: %d/sec" % _game_state.auto_tap_rate


func _on_tap() -> void:
	_game_state.register_click()
	_game_state.add_coins(_game_state.per_tap)
	Fractal.analytics.track("click", {"coins": _game_state.coins})


func _on_auto_tap_tick() -> void:
	if _game_state.auto_tap_rate <= 0:
		return
	_game_state.add_coins(_game_state.auto_tap_rate)


func _on_coins_changed(_amount: int) -> void:
	_refresh_counters()
	for milestone in MILESTONES:
		if _game_state.coins >= milestone and not (milestone in _milestones_fired):
			_milestones_fired.append(milestone)
			Fractal.analytics.track("milestone_reached", {"milestone": milestone})

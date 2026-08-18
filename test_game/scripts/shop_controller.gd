extends Control
## Shop scene, buy upgrades with coins. Each purchase fires analytics.

const CLICKER_SCENE := "res://test_game/scenes/clicker.tscn"

const TAP_POWER_COST := 10
const AUTO_CLICKER_COST := 50
const PRESTIGE_COST := 1000

@onready var coins_label: Label = %CoinsLabel
@onready var tap_power_button: Button = %TapPowerButton
@onready var auto_clicker_button: Button = %AutoClickerButton
@onready var prestige_button: Button = %PrestigeButton
@onready var back_button: Button = %BackButton

var _game_state: Node


func _ready() -> void:
	_game_state = get_node("/root/GameState")
	_game_state.coins_changed.connect(_on_coins_changed)

	tap_power_button.pressed.connect(func(): _try_purchase("tap_power", TAP_POWER_COST, _game_state.upgrade_tap_power))
	auto_clicker_button.pressed.connect(func(): _try_purchase("auto_clicker", AUTO_CLICKER_COST, _game_state.upgrade_auto_clicker))
	prestige_button.pressed.connect(func(): _try_purchase("prestige", PRESTIGE_COST, _game_state.prestige))
	back_button.pressed.connect(func(): get_tree().change_scene_to_file(CLICKER_SCENE))

	_refresh_text()
	_refresh_counters()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_refresh_text()


func _refresh_text() -> void:
	tap_power_button.text = tr("shop.tap_power")
	auto_clicker_button.text = tr("shop.auto_clicker")
	prestige_button.text = tr("shop.prestige")
	back_button.text = tr("settings.back")


func _refresh_counters() -> void:
	coins_label.text = "Coins: %d" % _game_state.coins


func _try_purchase(item: String, cost: int, on_success: Callable) -> void:
	if _game_state.spend_coins(cost):
		on_success.call()
		Fractal.analytics.track("item_purchased", {"item": item, "cost": cost})
	else:
		Fractal.analytics.track("purchase_failed", {
			"item": item,
			"coins": _game_state.coins,
			"cost": cost,
		})


func _on_coins_changed(_amount: int) -> void:
	_refresh_counters()

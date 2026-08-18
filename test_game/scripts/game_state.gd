extends Node
## Click Empire game state — coins, upgrades, and achievement tracking.
##
## NOT given a class_name to avoid colliding with SDK class_names.
## Loaded as the `GameState` autoload (registered in project.godot).
## Persists to user://click_empire_save.json across sessions.

signal coins_changed(amount: int)
signal achievement_unlocked(name: String)
signal prestiged

const SAVE_PATH := "user://click_empire_save.json"

const ACHIEVEMENT_FIRST_CLICK := "achievement.first_click"
const ACHIEVEMENT_HUNDRED_COINS := "achievement.hundred_coins"
const ACHIEVEMENT_THOUSAND_COINS := "achievement.thousand_coins"
const ACHIEVEMENT_FIRST_UPGRADE := "achievement.first_upgrade"
const ACHIEVEMENT_FIRST_PRESTIGE := "achievement.first_prestige"

const ALL_ACHIEVEMENTS: Array[String] = [
	ACHIEVEMENT_FIRST_CLICK,
	ACHIEVEMENT_HUNDRED_COINS,
	ACHIEVEMENT_THOUSAND_COINS,
	ACHIEVEMENT_FIRST_UPGRADE,
	ACHIEVEMENT_FIRST_PRESTIGE,
]

var coins: int = 0
var per_tap: int = 1
var auto_tap_rate: int = 0
var unlocked_achievements: Array[String] = []


func _ready() -> void:
	load_state()


func add_coins(amount: int) -> void:
	if amount <= 0:
		return
	coins += amount
	coins_changed.emit(coins)
	_check_coin_milestones()


func spend_coins(amount: int) -> bool:
	if amount <= 0:
		return false
	if coins < amount:
		return false
	coins -= amount
	coins_changed.emit(coins)
	return true


func upgrade_tap_power() -> void:
	per_tap += 1
	_unlock(ACHIEVEMENT_FIRST_UPGRADE)
	save_state()


func upgrade_auto_clicker() -> void:
	auto_tap_rate += 1
	_unlock(ACHIEVEMENT_FIRST_UPGRADE)
	save_state()


func prestige() -> void:
	coins = 0
	per_tap = per_tap * 2 if per_tap >= 1 else 2
	auto_tap_rate = 0
	_unlock(ACHIEVEMENT_FIRST_PRESTIGE)
	coins_changed.emit(coins)
	prestiged.emit()
	save_state()


func register_click() -> void:
	_unlock(ACHIEVEMENT_FIRST_CLICK)


func is_unlocked(achievement: String) -> bool:
	return achievement in unlocked_achievements


# ─── Internal ─────────────────────────────────────────────────────────────

func _check_coin_milestones() -> void:
	if coins >= 100:
		_unlock(ACHIEVEMENT_HUNDRED_COINS)
	if coins >= 1000:
		_unlock(ACHIEVEMENT_THOUSAND_COINS)


func _unlock(achievement: String) -> void:
	if achievement in unlocked_achievements:
		return
	unlocked_achievements.append(achievement)
	achievement_unlocked.emit(achievement)
	save_state()


# ─── Persistence ──────────────────────────────────────────────────────────

func save_state() -> void:
	var data := {
		"coins": coins,
		"per_tap": per_tap,
		"auto_tap_rate": auto_tap_rate,
		"unlocked_achievements": unlocked_achievements,
	}
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("GameState: failed to open save file for writing")
		return
	file.store_string(JSON.stringify(data))
	file.close()


func load_state() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("GameState: failed to parse save file")
		return
	var data: Variant = json.data
	if not (data is Dictionary):
		return
	coins = int(data.get("coins", 0))
	per_tap = int(data.get("per_tap", 1))
	auto_tap_rate = int(data.get("auto_tap_rate", 0))
	var loaded_achievements: Array = data.get("unlocked_achievements", [])
	unlocked_achievements.clear()
	for a in loaded_achievements:
		if a is String:
			unlocked_achievements.append(a)

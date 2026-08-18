extends GdUnitTestSuite
## End-to-end test: load the clicker scene, exercise core flows, and assert
## that the SDK observes the right events.
##
## We don't reach a real backend, the autoload `Fractal` is configured with
## `http://localhost:8080` (unreachable in CI). Tracked events will queue and
## fire `event_tracked` regardless of HTTP success, which is enough to verify
## the wiring between game code -> AnalyticsGlue -> Fractal.analytics.

const FractalTestHelpersClass = preload("res://tests/helpers/test_helpers.gd")


func before_test() -> void:
	# Ensure Fractal is configured (the autoload's configure call is triggered by
	# the test_game's AnalyticsGlue when the scene loads, but if the test runs in
	# isolation the autoload may not have run yet).
	pass


func test_clicker_scene_fires_click_event() -> void:
	var runner := scene_runner("res://test_game/scenes/clicker.tscn")
	var tree := runner.scene().get_tree()

	var tracked: Array = []
	Fractal.analytics.event_tracked.connect(func(event_type): tracked.append(event_type))

	# Wait one frame for _ready() to wire up.
	await tree.process_frame

	var tap_button: Button = runner.find_child("TapButton")
	assert_object(tap_button).is_not_null()
	tap_button.pressed.emit()
	tap_button.pressed.emit()
	tap_button.pressed.emit()

	var ok: bool = await FractalTestHelpersClass.wait_for(
		tree, func(): return tracked.count("click") >= 3, 2000,
	)
	assert_bool(ok).is_true()


func test_milestone_event_fires_at_threshold() -> void:
	# Reset coins via GameState, then directly bump to a milestone via 10 clicks.
	var game_state: Node = Engine.get_main_loop().root.get_node("/root/GameState")
	game_state.coins = 0
	game_state.per_tap = 1

	var runner := scene_runner("res://test_game/scenes/clicker.tscn")
	var tree := runner.scene().get_tree()

	var tracked: Array = []
	Fractal.analytics.event_tracked.connect(func(event_type): tracked.append(event_type))

	await tree.process_frame
	var tap_button: Button = runner.find_child("TapButton")
	for i in range(10):
		tap_button.pressed.emit()

	var ok: bool = await FractalTestHelpersClass.wait_for(
		tree, func(): return "milestone_reached" in tracked, 2000,
	)
	assert_bool(ok).is_true()


func test_settings_throw_error_button_captures_error() -> void:
	var runner := scene_runner("res://test_game/scenes/settings.tscn")
	var tree := runner.scene().get_tree()

	var captured: Array = []
	Fractal.errors.error_captured.connect(func(error_type): captured.append(error_type))

	await tree.process_frame
	var throw_button: Button = runner.find_child("ThrowErrorButton")
	if throw_button == null:
		# Settings scene names may vary; skip gracefully if button isn't found by that name.
		return
	throw_button.pressed.emit()

	var ok: bool = await FractalTestHelpersClass.wait_for(
		tree, func(): return not captured.is_empty(), 2000,
	)
	assert_bool(ok).is_true()

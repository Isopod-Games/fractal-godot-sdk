extends GdUnitTestSuite

const FractalPlatformDetectorClass = preload("res://addons/fractal/core/platform_detector.gd")
const FractalVersionClass = preload("res://addons/fractal/core/version.gd")


func test_get_platform_returns_known_string() -> void:
	var platform: String = FractalPlatformDetectorClass.get_platform()
	# We can't dictate the host OS — assert the string is non-empty + lowercase
	# (the documented values are all lowercase: windows, macos, linux, steam_deck, …).
	assert_str(platform).is_not_empty()
	assert_str(platform).is_equal(platform.to_lower())


func test_get_context_includes_required_keys() -> void:
	var ctx: Dictionary = FractalPlatformDetectorClass.get_context("p_42", "sess_abc", "1.2.3")
	assert_str(ctx.player_id).is_equal("p_42")
	assert_str(ctx.session_token).is_equal("sess_abc")
	assert_str(ctx.app_version).is_equal("1.2.3")
	assert_str(ctx.platform).is_not_empty()
	assert_str(ctx.os_name).is_not_empty()
	assert_str(ctx.os_version).is_not_empty()
	assert_str(ctx.sdk_version).is_equal(FractalVersionClass.VERSION)
	assert_bool(ctx.has("environment")).is_false()


func test_get_context_includes_environment_when_set() -> void:
	var ctx: Dictionary = FractalPlatformDetectorClass.get_context("p", "s", "v", "production")
	assert_str(ctx.environment).is_equal("production")

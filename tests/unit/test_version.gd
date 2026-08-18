extends GdUnitTestSuite
## Tests for FractalVersion. File-level agreement across VERSION / plugin.cfg
## / CHANGELOG.md is enforced by ci/check_version_sync.sh, not here.

const FractalVersionClass = preload("res://addons/fractal/core/version.gd")


func test_version_is_valid_semver() -> void:
	var regex := RegEx.new()
	regex.compile("^\\d+\\.\\d+\\.\\d+$")
	assert_bool(regex.search(FractalVersionClass.VERSION) != null).is_true()


func test_native_binary_versions_are_valid_semver() -> void:
	var regex := RegEx.new()
	regex.compile("^\\d+\\.\\d+\\.\\d+$")
	for platform_key in FractalVersionClass.NATIVE_BINARY_VERSIONS:
		assert_bool(regex.search(FractalVersionClass.NATIVE_BINARY_VERSIONS[platform_key]) != null).is_true()


func test_version_matches_plugin_cfg() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://addons/fractal/plugin.cfg")
	assert_int(err).is_equal(OK)
	var plugin_version: String = cfg.get_value("plugin", "version", "")
	assert_str(plugin_version).is_equal(FractalVersionClass.VERSION)


func test_native_binary_matches_missing_get_version_matches_pre_versioning_expected() -> void:
	assert_bool(FractalVersionClass.native_binary_matches(false, "", "2.0.0")).is_true()


func test_native_binary_matches_missing_get_version_fails_once_expected_moves_past_pre_versioning() -> void:
	assert_bool(FractalVersionClass.native_binary_matches(false, "", "2.1.0")).is_false()


func test_native_binary_matches_on_exact_version() -> void:
	assert_bool(FractalVersionClass.native_binary_matches(true, "2.0.0", "2.0.0")).is_true()


func test_current_platform_key_has_platform_arch_shape() -> void:
	var regex := RegEx.new()
	regex.compile("^[a-z_]+-[a-z0-9_]+$")
	assert_bool(regex.search(FractalVersionClass.current_platform_key()) != null).is_true()


func test_native_binary_version_for_known_platform() -> void:
	assert_str(FractalVersionClass.native_binary_version_for("linux-x86_64")).is_equal(FractalVersionClass.NATIVE_BINARY_VERSIONS["linux-x86_64"])


func test_native_binary_version_for_unknown_platform_is_empty() -> void:
	assert_str(FractalVersionClass.native_binary_version_for("bogus-platform")).is_equal("")


func test_native_binary_matches_fails_on_mismatch() -> void:
	assert_bool(FractalVersionClass.native_binary_matches(true, "0.0.1-bogus")).is_false()


func test_native_binary_matches_fails_when_reported_lags_expected() -> void:
	assert_bool(FractalVersionClass.native_binary_matches(true, "2.0.0", "2.1.0")).is_false()

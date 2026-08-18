extends GdUnitTestSuite
## Binary-drift tripwire: when the FractalNative GDExtension singleton is
## loaded (true on Linux CI with the committed .so), it must match this
## platform's FractalVersion.NATIVE_BINARY_VERSIONS entry per
## native_binary_matches() — same helper errors.gd::_arm_native uses at
## runtime.
##
## This passes leniently today against the pre-get_version() committed .so
## (PRE_VERSIONING_NATIVE exemption) and flips to a strict version-string
## comparison automatically after the first native rebuild.
##
## When FRACTAL_EXPECT_NATIVE_VERSION is set (only ever set by
## native_build.yml's matrix), the binary was just built fresh from this
## checkout, so the correct invariant is "reported version == source
## VERSION" rather than the committed table — the table is legitimately
## behind until ci/fetch_native_artifacts.sh bumps it.

const FractalVersionClass = preload("res://addons/fractal/core/version.gd")


func test_native_binary_version_matches_expected() -> void:
	if not Engine.has_singleton("FractalNative"):
		# No native binary loaded on this platform/build — nothing to check.
		return
	var native = Engine.get_singleton("FractalNative")
	var has_get_version: bool = native.has_method("get_version")
	var reported: String = native.get_version() if has_get_version else ""
	var fresh_expected := OS.get_environment("FRACTAL_EXPECT_NATIVE_VERSION")
	if fresh_expected != "":
		assert_bool(FractalVersionClass.native_binary_matches(has_get_version, reported, fresh_expected)).is_true()
	else:
		assert_bool(FractalVersionClass.native_binary_matches(has_get_version, reported)).is_true()

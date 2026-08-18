extends GdUnitTestSuite
## Tests for the GDScript-side helpers around the FractalNative GDExtension.
## We don't actually invoke the C++ binding here, the unit tests run on
## platforms where the binary may not be shipped. We exercise the path
## resolution + availability-check logic, which is platform-agnostic.

const FractalNativeHelpers = preload("res://addons/fractal_native/fractal_native.gd")


func test_handler_path_returns_absolute_path() -> void:
	# Per-platform path returned should be an absolute filesystem path
	# (globalize_path res:// -> user's project dir + addons/...). On
	# unsupported OSes the helper returns "".
	var path: String = FractalNativeHelpers.handler_path()
	if path.is_empty():
		# Unsupported platform, that's OK, tested via is_available below.
		return
	assert_str(path).contains("addons/fractal_native/bin/")
	assert_str(path).contains("crashpad_handler")
	assert_bool(path.begins_with("/") or path.contains(":")).is_true()


func test_database_path_creates_directory() -> void:
	var path: String = FractalNativeHelpers.database_path()
	assert_str(path).is_not_empty()
	assert_str(path).ends_with("fractal/minidumps")
	# Directory exists after the call.
	var rel: String = "user://fractal/minidumps"
	assert_bool(DirAccess.dir_exists_absolute(rel)).is_true()


func test_ensure_handler_executable_repairs_stripped_bit() -> void:
	if OS.get_name() == "Windows":
		# No unix exec-bit concept on Windows, helper is a no-op true.
		assert_bool(FractalNativeHelpers.ensure_handler_executable("C:\\nonexistent.exe")).is_true()
		return

	var tmp_path: String = "user://test_crashpad_handler_tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	f.store_string("#!/bin/sh\n")
	f.close()
	var abs_path: String = ProjectSettings.globalize_path(tmp_path)

	# Strip all exec bits, then confirm the helper restores the owner bit.
	FileAccess.set_unix_permissions(abs_path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	assert_bool(FractalNativeHelpers.ensure_handler_executable(abs_path)).is_true()
	var repaired_perms: int = FileAccess.get_unix_permissions(abs_path)
	assert_bool(repaired_perms & FileAccess.UNIX_EXECUTE_OWNER != 0).is_true()

	# Already-executable path is a no-op that still returns true.
	assert_bool(FractalNativeHelpers.ensure_handler_executable(abs_path)).is_true()

	DirAccess.remove_absolute(abs_path)


func test_is_available_consistent_with_environment() -> void:
	# is_available() returns true iff the GDExtension singleton is
	# registered AND the bundled handler exists on disk. Both conditions
	# are checked together; never one without the other.
	var avail: bool = FractalNativeHelpers.is_available()
	if avail:
		assert_bool(Engine.has_singleton("FractalNative")).is_true()
		assert_bool(FileAccess.file_exists(FractalNativeHelpers.handler_path())).is_true()
	else:
		# Either the singleton isn't registered (binary not loaded for this
		# platform) or the handler binary is missing. Both are expected
		# fallback states; the SDK degrades to heartbeat-only.
		var has_singleton: bool = Engine.has_singleton("FractalNative")
		var has_handler: bool = not FractalNativeHelpers.handler_path().is_empty() \
		                        and FileAccess.file_exists(FractalNativeHelpers.handler_path())
		assert_bool(has_singleton and has_handler).is_false()

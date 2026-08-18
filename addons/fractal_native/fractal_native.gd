## Fractal Native — GDScript-side helpers around the FractalNative GDExtension.
##
## The real implementation is the C++ singleton registered as `FractalNative`.
## This file is a thin convenience layer that:
##   1. Detects whether the GDExtension is available (it might not be — the
##      addon ships with binaries for {macos,linux,windows} x x86_64/arm64
##      but not every platform combo, and pure-GDScript Fractal still works
##      without it).
##   2. Resolves the on-disk paths for the crashpad_handler executable and
##      the minidump database directory.
##   3. Drains and uploads any minidumps left behind by a previous crash.
##
## When `FractalNative` is missing, all helpers return safe defaults.

class_name FractalNativeHelpers
extends RefCounted


## Returns the absolute path to the bundled crashpad_handler for the
## current platform. Empty string if the addon doesn't bundle one for this
## platform.
static func handler_path() -> String:
	var os_name: String = OS.get_name()
	var arch_suffix: String = "x86_64"
	# Arch detection: PROCESSOR_NAME contains "Apple M" on Apple Silicon.
	if "Apple M" in OS.get_processor_name() or OS.get_name() == "macOS":
		arch_suffix = "arm64" if OS.get_processor_name().begins_with("Apple") else "x86_64"

	var platform_dir: String
	var bin_name: String = "crashpad_handler"
	match os_name:
		"macOS":
			platform_dir = "macos-arm64" if arch_suffix == "arm64" else "macos-x86_64"
		"Linux":
			platform_dir = "linux-x86_64"
		"Windows":
			platform_dir = "windows-x86_64"
			bin_name = "crashpad_handler.exe"
		_:
			return ""

	# ProjectSettings.globalize_path resolves res:// to the absolute fs path
	# at runtime — sentry-native needs an absolute path to the handler.
	var rel: String = "res://addons/fractal_native/bin/%s/%s" % [platform_dir, bin_name]
	return ProjectSettings.globalize_path(rel)


## Returns the absolute path to the minidump database directory under
## user://. Created on first use.
static func database_path() -> String:
	var rel := "user://fractal/minidumps"
	if not DirAccess.dir_exists_absolute(rel):
		DirAccess.make_dir_recursive_absolute(rel)
	return ProjectSettings.globalize_path(rel)


## Ensures the crashpad_handler at `handler` has the owner-exec bit set,
## repairing existing installs whose zip predates the exec-bit fix in the
## SDK download endpoint. Returns true if the handler is (now) executable,
## false if it couldn't be made so — callers must not arm native capture
## on a false result (see errors.gd `_arm_native`).
##
## Windows has no unix exec-bit concept, so this is a no-op there.
static func ensure_handler_executable(handler: String) -> bool:
	if OS.get_name() == "Windows":
		return true
	var perms: int = FileAccess.get_unix_permissions(handler)
	if perms & FileAccess.UNIX_EXECUTE_OWNER != 0:
		return true
	var repaired: int = perms | FileAccess.UNIX_EXECUTE_OWNER | FileAccess.UNIX_EXECUTE_GROUP | FileAccess.UNIX_EXECUTE_OTHER
	FileAccess.set_unix_permissions(handler, repaired)
	return FileAccess.get_unix_permissions(handler) & FileAccess.UNIX_EXECUTE_OWNER != 0


## Returns true if the C++ singleton is loaded and the bundled handler is
## present on disk. False means we should fall back to the heartbeat-only
## path (already implemented in errors.gd).
static func is_available() -> bool:
	if not Engine.has_singleton("FractalNative"):
		return false
	var handler := handler_path()
	if handler.is_empty() or not FileAccess.file_exists(handler):
		return false
	return true

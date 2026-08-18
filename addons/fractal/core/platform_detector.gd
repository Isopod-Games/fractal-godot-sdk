class_name FractalPlatformDetector
extends RefCounted
## Detects the current platform and OS information for analytics/error context.

const FractalVersionClass := preload("res://addons/fractal/core/version.gd")


static func get_platform() -> String:
	var os_name := OS.get_name()
	match os_name:
		"Windows":
			return "windows"
		"macOS":
			return "macos"
		"Linux":
			if _is_steam_deck():
				return "steam_deck"
			return "linux"
		"Android":
			return "android"
		"iOS":
			return "ios"
		"Web":
			return "web"
		_:
			return os_name.to_lower()


static func get_os() -> String:
	return OS.get_name()


static func get_os_version() -> String:
	var version := OS.get_version()
	return version if not version.is_empty() else "unknown"


## Returns the CPU model name.
static func get_cpu_model() -> String:
	return OS.get_processor_name()


## Returns the number of CPU cores/threads.
static func get_cpu_cores() -> int:
	return OS.get_processor_count()


## Returns the GPU/renderer name.
static func get_gpu_model() -> String:
	return RenderingServer.get_video_adapter_name()


## Returns physical RAM in megabytes, or 0 if unavailable.
static func get_memory_mb() -> int:
	var info := OS.get_memory_info()
	var physical: int = info.get("physical", 0)
	if physical < 0:
		return 0
	return physical / (1024 * 1024)


## Returns the complete context dictionary for batch requests.
static func get_context(player_id: String, session_token: String, app_version: String, environment: String = "") -> Dictionary:
	var ctx := {
		"player_id": player_id,
		"session_token": session_token,
		"platform": get_platform(),
		"app_version": app_version,
		"os_name": get_os(),
		"os_version": get_os_version(),
		"cpu_model": get_cpu_model(),
		"cpu_cores": get_cpu_cores(),
		"gpu_model": get_gpu_model(),
		"memory_mb": get_memory_mb(),
		"sdk_version": FractalVersionClass.VERSION
	}
	if not environment.is_empty():
		ctx["environment"] = environment
	return ctx


static func _is_steam_deck() -> bool:
	if OS.has_environment("SteamDeck"):
		return true
	if FileAccess.file_exists("/etc/steamos-release"):
		return true
	if "AMD Custom APU 0405" in OS.get_processor_name():
		return true
	return false

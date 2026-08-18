#ifndef FRACTAL_NATIVE_H
#define FRACTAL_NATIVE_H

// FractalNative — GDExtension that wraps sentry-native (Crashpad backend)
// to capture native crashes (SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL on
// Unix; SetUnhandledExceptionFilter on Windows). When a crash occurs, the
// out-of-process crashpad_handler writes a minidump to the configured
// database path (`user://fractal/minidumps/`). On the next launch, the
// GDScript layer drains that directory and uploads via /v1/minidumps.
//
// Sentry-native is configured WITHOUT a Sentry DSN — we only use it for
// its crash backend, not its uploader. The metadata (user, tags,
// breadcrumbs) is written by the GDScript layer alongside the dump for
// the upload to pair correctly.

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

class FractalNative : public Object {
	GDCLASS(FractalNative, Object)

protected:
	static void _bind_methods();

public:
	FractalNative();
	~FractalNative();

	// Initialize Crashpad. Returns true if successful, false otherwise.
	// Calling init() twice is a no-op (returns true if previously
	// initialized successfully).
	//
	// handler_path:  absolute filesystem path to crashpad_handler executable
	//                (extracted from the addon at runtime)
	// database_path: absolute filesystem path to the minidump database
	//                directory (will be created if missing)
	// release:       app version string, written into the minidump's metadata
	// environment:   "development" | "staging" | "production"
	bool init(const String &handler_path,
	          const String &database_path,
	          const String &release,
	          const String &environment);

	bool is_initialized() const;

	// Returns the native binary's version, embedded at build time from
	// ../../VERSION via a generated header (src/gen/fractal_version.gen.h).
	// Compared against FractalVersion.NATIVE_BINARY_VERSION at arm-time to
	// catch a stale/mismatched binary (see errors.gd::_arm_native).
	String get_version() const;

	// Scope mutators — applied to all subsequent crashes.
	void set_user(const String &id, const Dictionary &extra);
	void set_tag(const String &key, const String &value);
	void add_breadcrumb(const String &message,
	                    const String &category,
	                    const String &level);

	// Returns absolute paths to minidumps that haven't been claimed yet.
	// Each call returns only NEW dumps since the previous call; on success
	// the caller is expected to upload + delete each.
	PackedStringArray pending_minidumps(const String &database_path);

	// Removes a minidump file after successful upload.
	void delete_minidump(const String &path);

	// Cleanly flushes and shuts down sentry. Called from GDScript on
	// graceful exit so the database path can be reclaimed cleanly.
	void shutdown();

	// FOR TESTING ONLY: deliberately segfault the process. Wired to a
	// debug button in test_game and used by the integration verification
	// to prove the crashpad pipeline actually catches native crashes.
	// Never hits the bound public API in shipping code.
	void _force_segfault_for_testing();

private:
	bool _initialized = false;
	String _database_path;

	// Helper: list .dmp files in a directory.
	PackedStringArray _list_dump_files(const String &dir) const;
};

} // namespace godot

#endif // FRACTAL_NATIVE_H

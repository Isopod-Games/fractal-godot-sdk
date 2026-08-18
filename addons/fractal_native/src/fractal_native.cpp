#include "fractal_native.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <sentry.h>

#include "gen/fractal_version.gen.h"

namespace godot {

void FractalNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("init", "handler_path", "database_path", "release", "environment"), &FractalNative::init);
	ClassDB::bind_method(D_METHOD("is_initialized"), &FractalNative::is_initialized);
	ClassDB::bind_method(D_METHOD("get_version"), &FractalNative::get_version);
	ClassDB::bind_method(D_METHOD("set_user", "id", "extra"), &FractalNative::set_user);
	ClassDB::bind_method(D_METHOD("set_tag", "key", "value"), &FractalNative::set_tag);
	ClassDB::bind_method(D_METHOD("add_breadcrumb", "message", "category", "level"), &FractalNative::add_breadcrumb);
	ClassDB::bind_method(D_METHOD("pending_minidumps", "database_path"), &FractalNative::pending_minidumps);
	ClassDB::bind_method(D_METHOD("delete_minidump", "path"), &FractalNative::delete_minidump);
	ClassDB::bind_method(D_METHOD("shutdown"), &FractalNative::shutdown);
	ClassDB::bind_method(D_METHOD("_force_segfault_for_testing"), &FractalNative::_force_segfault_for_testing);
}

FractalNative::FractalNative() {}

FractalNative::~FractalNative() {
	if (_initialized) {
		sentry_close();
	}
}

bool FractalNative::init(const String &handler_path,
                         const String &database_path,
                         const String &release,
                         const String &environment) {
	if (_initialized) {
		return true;
	}

	sentry_options_t *options = sentry_options_new();
	if (options == nullptr) {
		ERR_PRINT("FractalNative: sentry_options_new returned null");
		return false;
	}

	// Empty DSN: sentry-native runs in offline mode. It writes minidumps
	// to the database path but never POSTs them anywhere. Our GDScript
	// layer drains the directory and uploads to Fractal's own endpoint.
	sentry_options_set_dsn(options, "");

	sentry_options_set_handler_path(options, handler_path.utf8().get_data());
	sentry_options_set_database_path(options, database_path.utf8().get_data());
	if (!release.is_empty()) {
		sentry_options_set_release(options, release.utf8().get_data());
	}
	if (!environment.is_empty()) {
		sentry_options_set_environment(options, environment.utf8().get_data());
	}

	// We never want sentry-native uploading to Sentry. Belt-and-suspenders
	// alongside the empty DSN.
	sentry_options_set_auto_session_tracking(options, 0);

	int rc = sentry_init(options);
	if (rc != 0) {
		ERR_PRINT(vformat("FractalNative: sentry_init failed (rc=%d)", rc));
		// sentry_init can install its in-process crash handler before the
		// step that actually failed (e.g. spawning the out-of-process
		// crashpad_handler). Left in place, that handler intercepts the
		// next real crash and waits forever on a handler process that was
		// never started, freezing the app instead of crashing. Tear it
		// down fully so a failed init leaves nothing armed.
		sentry_close();
		return false;
	}

	_initialized = true;
	_database_path = database_path;
	UtilityFunctions::print(vformat("[FractalNative] crashpad armed (db=%s)", database_path));
	return true;
}

bool FractalNative::is_initialized() const {
	return _initialized;
}

String FractalNative::get_version() const {
	return String(FRACTAL_SDK_VERSION);
}

void FractalNative::set_user(const String &id, const Dictionary &extra) {
	if (!_initialized) return;
	sentry_value_t user = sentry_value_new_object();
	sentry_value_set_by_key(user, "id", sentry_value_new_string(id.utf8().get_data()));
	Array keys = extra.keys();
	for (int i = 0; i < keys.size(); ++i) {
		String key = keys[i];
		String val = extra[keys[i]];
		sentry_value_set_by_key(user, key.utf8().get_data(),
		                        sentry_value_new_string(val.utf8().get_data()));
	}
	sentry_set_user(user);
}

void FractalNative::set_tag(const String &key, const String &value) {
	if (!_initialized) return;
	sentry_set_tag(key.utf8().get_data(), value.utf8().get_data());
}

void FractalNative::add_breadcrumb(const String &message,
                                   const String &category,
                                   const String &level) {
	if (!_initialized) return;
	sentry_value_t crumb = sentry_value_new_breadcrumb(
		category.utf8().get_data(),
		message.utf8().get_data());
	if (!level.is_empty()) {
		sentry_value_set_by_key(crumb, "level",
		                        sentry_value_new_string(level.utf8().get_data()));
	}
	sentry_add_breadcrumb(crumb);
}

PackedStringArray FractalNative::pending_minidumps(const String &database_path) {
	// Crashpad writes minidumps under <database>/pending/ once the handler
	// has finished writing them. In offline mode (no DSN), sentry-native
	// doesn't move them to completed/ since there's no upload — we drain
	// from both directories to be safe across sentry-native versions.
	PackedStringArray out = _list_dump_files(database_path + String("/pending"));
	out.append_array(_list_dump_files(database_path + String("/completed")));
	return out;
}

void FractalNative::delete_minidump(const String &path) {
	Ref<DirAccess> dir = DirAccess::open(path.get_base_dir());
	if (dir.is_valid()) {
		dir->remove(path);
	}
}

void FractalNative::shutdown() {
	if (_initialized) {
		sentry_close();
		_initialized = false;
	}
}

// Compiled with -O0 around the deref so the optimizer doesn't elide it
// (a smart compiler would notice the UB and turn the function into a
// no-op or a trap).
#if defined(__GNUC__) || defined(__clang__)
__attribute__((optimize("O0")))
#endif
void FractalNative::_force_segfault_for_testing() {
	volatile int *p = nullptr;
	*p = 0xDEADBEEF;
}

PackedStringArray FractalNative::_list_dump_files(const String &dir) const {
	PackedStringArray out;
	Ref<DirAccess> d = DirAccess::open(dir);
	if (d.is_null()) {
		return out;
	}
	d->list_dir_begin();
	String entry = d->get_next();
	while (!entry.is_empty()) {
		if (!d->current_is_dir() && entry.ends_with(".dmp")) {
			out.push_back(dir + String("/") + entry);
		}
		entry = d->get_next();
	}
	d->list_dir_end();
	return out;
}

} // namespace godot

#include "register_types.h"
#include "fractal_native.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/classes/engine.hpp>

using namespace godot;

static FractalNative *fractal_native_singleton = nullptr;

void initialize_fractal_native_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(FractalNative);
	fractal_native_singleton = memnew(FractalNative);
	Engine::get_singleton()->register_singleton("FractalNative", fractal_native_singleton);
}

void uninitialize_fractal_native_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	Engine::get_singleton()->unregister_singleton("FractalNative");
	memdelete(fractal_native_singleton);
	fractal_native_singleton = nullptr;
}

extern "C" {
GDExtensionBool GDE_EXPORT fractal_native_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                                                       const GDExtensionClassLibraryPtr p_library,
                                                       GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_fractal_native_module);
	init_obj.register_terminator(uninitialize_fractal_native_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}

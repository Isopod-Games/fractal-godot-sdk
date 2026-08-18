class_name FractalTranslationLoader
extends RefCounted
## Bridges a `{key: string}` dictionary into Godot's TranslationServer.
##
## A reference to each Translation we register is kept on this loader instance
## so we can remove it before re-applying the same locale (avoiding stale keys
## from a previous sync leaking through).

var _registered: Dictionary = {}  # locale -> Translation


## Registers a flat `{key: value}` dictionary as a Translation for `locale`.
## Returns the count of messages added. If the same locale was previously
## registered through this loader, the old Translation is removed first.
func apply(locale: String, messages: Dictionary) -> int:
	if locale.is_empty():
		push_warning("Fractal.translations: cannot apply empty locale")
		return 0
	if _registered.has(locale):
		var prev: Translation = _registered[locale]
		TranslationServer.remove_translation(prev)
		_registered.erase(locale)

	var translation := Translation.new()
	translation.locale = locale
	for key in messages.keys():
		var value: Variant = messages[key]
		if value is String:
			translation.add_message(key, value)
	TranslationServer.add_translation(translation)
	_registered[locale] = translation
	return translation.get_message_count()


func clear() -> void:
	for locale in _registered.keys():
		TranslationServer.remove_translation(_registered[locale])
	_registered.clear()


func registered_locales() -> PackedStringArray:
	var out := PackedStringArray()
	for locale in _registered.keys():
		out.append(locale)
	return out

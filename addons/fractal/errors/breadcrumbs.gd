class_name FractalBreadcrumbs
extends RefCounted
## Fixed-size ring buffer of recent events, included with every captured error.

const DEFAULT_MAX := 20

var _max: int = DEFAULT_MAX
var _crumbs: Array = []


func _init(max_breadcrumbs: int = DEFAULT_MAX) -> void:
	_max = max(1, max_breadcrumbs)


func add(message: String, category: String = "default", level: String = "info", data: Dictionary = {}) -> void:
	var crumb := {
		"timestamp": _iso_now(),
		"category": category,
		"message": message,
		"level": level,
	}
	if not data.is_empty():
		crumb["data"] = data
	_crumbs.append(crumb)
	while _crumbs.size() > _max:
		_crumbs.pop_front()


func all() -> Array:
	return _crumbs.duplicate()


func clear() -> void:
	_crumbs.clear()


func size() -> int:
	return _crumbs.size()


static func _iso_now() -> String:
	var dt := Time.get_datetime_dict_from_system(true)
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]

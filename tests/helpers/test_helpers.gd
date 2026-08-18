class_name FractalTestHelpers
extends RefCounted
## Shared utilities for Fractal SDK tests.


## Recursively delete a `user://` directory.
static func remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var sub: String = path.path_join(entry)
		if dir.current_is_dir():
			remove_dir_recursive(sub)
		else:
			DirAccess.remove_absolute(sub)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


## Wait until `predicate` returns true or `timeout_ms` elapses.
## Yields once per frame. Returns whether the condition was met.
static func wait_for(tree: SceneTree, predicate: Callable, timeout_ms: int = 5000) -> bool:
	var elapsed := 0
	while not predicate.call() and elapsed < timeout_ms:
		await tree.process_frame
		elapsed += 16
	return predicate.call()

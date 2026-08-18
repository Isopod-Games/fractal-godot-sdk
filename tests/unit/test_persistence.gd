extends GdUnitTestSuite

const FractalPersistenceClass = preload("res://addons/fractal/core/persistence.gd")


func before_test() -> void:
	# Start each test from a clean user://fractal/ namespace so tests don't bleed.
	if DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		_remove_dir_recursive(FractalPersistenceClass.ROOT)


func after_test() -> void:
	if DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		_remove_dir_recursive(FractalPersistenceClass.ROOT)


func test_player_id_round_trip() -> void:
	assert_str(FractalPersistenceClass.load_player_id()).is_empty()
	var id: String = FractalPersistenceClass.generate_player_id()
	assert_str(id).starts_with("godot_")
	FractalPersistenceClass.save_player_id(id)
	assert_str(FractalPersistenceClass.load_player_id()).is_equal(id)


func test_resolve_player_id_creates_and_persists_on_first_call() -> void:
	assert_str(FractalPersistenceClass.load_player_id()).is_empty()
	var id: String = FractalPersistenceClass.resolve_player_id()
	assert_str(id).starts_with("godot_")
	assert_str(FractalPersistenceClass.load_player_id()).is_equal(id)


func test_resolve_player_id_is_stable_on_second_call() -> void:
	var first: String = FractalPersistenceClass.resolve_player_id()
	var second: String = FractalPersistenceClass.resolve_player_id()
	assert_str(second).is_equal(first)


func test_generate_player_id_is_unique() -> void:
	var a: String = FractalPersistenceClass.generate_player_id()
	var b: String = FractalPersistenceClass.generate_player_id()
	assert_str(a).is_not_equal(b)


func test_generate_player_id_is_valid_uuid_v4() -> void:
	var id: String = FractalPersistenceClass.generate_player_id()
	# Strip "godot_" prefix; remainder must be a valid UUID v4.
	var uuid: String = id.substr(6)
	assert_int(uuid.length()).is_equal(36)
	var re := RegEx.new()
	re.compile("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	assert_bool(re.search(uuid) != null).is_true()


func test_event_queue_round_trip() -> void:
	var events: Array = [{"event_type": "a"}, {"event_type": "b"}]
	FractalPersistenceClass.save_events(events)
	var loaded: Array = FractalPersistenceClass.load_events()
	assert_int(loaded.size()).is_equal(2)
	assert_str(loaded[0].event_type).is_equal("a")


func test_client_seq_survives_round_trip_as_int() -> void:
	FractalPersistenceClass.save_events([{"event_type": "a", "client_seq": 0}, {"event_type": "b", "client_seq": 5}])
	var loaded: Array = FractalPersistenceClass.load_events()
	assert_int(loaded.size()).is_equal(2)
	assert_int(typeof(loaded[0].client_seq)).is_equal(TYPE_INT)
	assert_int(loaded[0].client_seq).is_equal(0)
	assert_int(typeof(loaded[1].client_seq)).is_equal(TYPE_INT)
	assert_int(loaded[1].client_seq).is_equal(5)


func test_save_empty_events_clears_file() -> void:
	FractalPersistenceClass.save_events([{"event_type": "x"}])
	FractalPersistenceClass.save_events([])
	assert_array(FractalPersistenceClass.load_events()).is_empty()


func test_crash_report_round_trip() -> void:
	var report: Dictionary = {"timestamp": "2026-04-29T12:00:00Z", "breadcrumbs": []}
	FractalPersistenceClass.save_crash_report(report)
	var loaded: Dictionary = FractalPersistenceClass.load_crash_report()
	assert_str(loaded.timestamp).is_equal("2026-04-29T12:00:00Z")
	FractalPersistenceClass.clear_crash_report()
	assert_dict(FractalPersistenceClass.load_crash_report()).is_empty()


func test_translation_cache_round_trip() -> void:
	var translations: Dictionary = {"ui.start": "Start", "ui.quit": "Quit"}
	FractalPersistenceClass.save_translation_cache("en", translations)
	var loaded: Dictionary = FractalPersistenceClass.load_translation_cache("en")
	assert_str(loaded["ui.start"]).is_equal("Start")
	assert_str(loaded["ui.quit"]).is_equal("Quit")


func test_translation_etag_round_trip() -> void:
	FractalPersistenceClass.save_translation_etag("es", "etag-abc-123")
	assert_str(FractalPersistenceClass.load_translation_etag("es")).is_equal("etag-abc-123")
	# Different locale doesn't collide.
	assert_str(FractalPersistenceClass.load_translation_etag("en")).is_empty()


func test_corrupt_translation_cache_is_dropped() -> void:
	# Write garbage to the cache path.
	if not DirAccess.dir_exists_absolute(FractalPersistenceClass.TRANSLATIONS_DIR):
		DirAccess.make_dir_recursive_absolute(FractalPersistenceClass.TRANSLATIONS_DIR)
	var path: String = FractalPersistenceClass.translation_cache_path("fr")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("not json {{{")
	file.close()
	assert_dict(FractalPersistenceClass.load_translation_cache("fr")).is_empty()
	# Cache file should have been removed by the loader.
	assert_bool(FileAccess.file_exists(path)).is_false()


func _remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var sub: String = path.path_join(entry)
		if dir.current_is_dir():
			_remove_dir_recursive(sub)
		else:
			DirAccess.remove_absolute(sub)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

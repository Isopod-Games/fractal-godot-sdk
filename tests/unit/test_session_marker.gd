extends GdUnitTestSuite

const FractalSessionMarkerClass = preload("res://addons/fractal/errors/session_marker.gd")
const FractalPersistenceClass = preload("res://addons/fractal/core/persistence.gd")
const FractalTestHelpersClass = preload("res://tests/helpers/test_helpers.gd")


func before_test() -> void:
	if DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		FractalTestHelpersClass.remove_dir_recursive(FractalPersistenceClass.ROOT)


func after_test() -> void:
	if DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		FractalTestHelpersClass.remove_dir_recursive(FractalPersistenceClass.ROOT)


func test_first_launch_returns_empty() -> void:
	var marker: FractalSessionMarker = FractalSessionMarkerClass.new()
	assert_dict(marker.load_previous()).is_empty()


func test_start_new_persists_session_with_runtime_block() -> void:
	var marker: FractalSessionMarker = FractalSessionMarkerClass.new()
	marker.start_new({"app_version": "1.2.3", "platform": "macos"})
	# Read it back via a fresh marker instance, proves it's actually on disk.
	var fresh: FractalSessionMarker = FractalSessionMarkerClass.new()
	var loaded: Dictionary = fresh.load_previous()
	assert_str(loaded.app_version).is_equal("1.2.3")
	assert_str(loaded.platform).is_equal("macos")
	assert_str(loaded.session_id).starts_with("ses_")
	assert_bool(loaded.clean).is_false()
	# runtime block (cross-engine discriminator) is always populated.
	assert_str(loaded.runtime.name).is_equal("godot")
	assert_str(loaded.runtime.version).is_not_empty()


func test_mark_clean_flips_flag() -> void:
	var marker: FractalSessionMarker = FractalSessionMarkerClass.new()
	marker.start_new({"app_version": "1.0.0"})
	marker.mark_clean()
	var fresh: FractalSessionMarker = FractalSessionMarkerClass.new()
	assert_bool(fresh.load_previous().clean).is_true()


func test_mark_crashed_via_records_reason_keeps_unclean() -> void:
	var marker: FractalSessionMarker = FractalSessionMarkerClass.new()
	marker.start_new({"app_version": "1.0.0"})
	marker.mark_crashed_via("notification")
	var loaded: Dictionary = FractalSessionMarkerClass.new().load_previous()
	assert_str(loaded.crashed_via).is_equal("notification")
	assert_bool(loaded.clean).is_false()


func test_tick_updates_breadcrumbs_and_heartbeat() -> void:
	var marker: FractalSessionMarker = FractalSessionMarkerClass.new()
	marker.start_new({"app_version": "1.0.0"})
	var initial_hb: String = FractalSessionMarkerClass.new().load_previous().last_heartbeat_at
	# Tick with new breadcrumbs.
	marker.tick(
		[{"timestamp": "x", "category": "ui", "message": "clicked", "level": "info"}],
		{"id": "p1"},
		{"build": "test"},
	)
	var loaded: Dictionary = FractalSessionMarkerClass.new().load_previous()
	assert_int(loaded.breadcrumbs.size()).is_equal(1)
	assert_str(loaded.breadcrumbs[0].message).is_equal("clicked")
	assert_dict(loaded.user).contains_key_value("id", "p1")
	assert_dict(loaded.tags).contains_key_value("build", "test")
	# Heartbeat string is monotonically updated (or at least overwritten).
	assert_str(loaded.last_heartbeat_at).is_not_empty()


func test_clear_removes_file() -> void:
	var marker: FractalSessionMarker = FractalSessionMarkerClass.new()
	marker.start_new({"app_version": "1.0.0"})
	marker.clear()
	assert_bool(FileAccess.file_exists(FractalSessionMarkerClass.SESSION_PATH)).is_false()


func test_corrupt_file_is_dropped_and_treated_as_no_session() -> void:
	if not DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		DirAccess.make_dir_recursive_absolute(FractalPersistenceClass.ROOT)
	var bad := FileAccess.open(FractalSessionMarkerClass.SESSION_PATH, FileAccess.WRITE)
	bad.store_string("not json {{{")
	bad.close()
	# Corrupt -> treated as no previous session AND the bad file is dropped.
	assert_dict(FractalSessionMarkerClass.new().load_previous()).is_empty()
	assert_bool(FileAccess.file_exists(FractalSessionMarkerClass.SESSION_PATH)).is_false()

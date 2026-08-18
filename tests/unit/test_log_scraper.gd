extends GdUnitTestSuite

const FractalLogScraperClass = preload("res://addons/fractal/errors/log_scraper.gd")

const TMP_DIR := "user://test_log_scraper"


func before_test() -> void:
	if not DirAccess.dir_exists_absolute(TMP_DIR):
		DirAccess.make_dir_recursive_absolute(TMP_DIR)


func after_test() -> void:
	# Clean up any test fixture files we created.
	var dir := DirAccess.open(TMP_DIR)
	if dir:
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if not dir.current_is_dir():
				DirAccess.remove_absolute(TMP_DIR.path_join(entry))
			entry = dir.get_next()
		dir.list_dir_end()
	DirAccess.remove_absolute(TMP_DIR)


func _write_log(name: String, content: String) -> String:
	var path: String = TMP_DIR.path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return path


func test_missing_file_returns_empty() -> void:
	assert_str(FractalLogScraperClass.extract_trace_from_file(TMP_DIR.path_join("does_not_exist.log"))).is_empty()


func test_log_with_no_errors_returns_empty() -> void:
	var path: String = _write_log("clean.log", "Godot Engine v4.5\nLoaded scene\nFrame ticked\n")
	assert_str(FractalLogScraperClass.extract_trace_from_file(path)).is_empty()


func test_single_script_error_block_is_extracted() -> void:
	var content := """Godot Engine v4.5
Loaded scene
SCRIPT ERROR: Invalid call. Nonexistent function 'foo' in base 'Node'.
          at: do_thing (res://game.gd:42)
"""
	var path: String = _write_log("single.log", content)
	var trace: String = FractalLogScraperClass.extract_trace_from_file(path)
	assert_str(trace).contains("SCRIPT ERROR:")
	assert_str(trace).contains("res://game.gd:42")


func test_multiple_blocks_keeps_latest() -> void:
	var content := """SCRIPT ERROR: First error
          at: a (res://a.gd:1)
Some normal log
ERROR: Second error
          at: b (res://b.gd:2)
"""
	var path: String = _write_log("multi.log", content)
	var trace: String = FractalLogScraperClass.extract_trace_from_file(path)
	assert_str(trace).contains("Second error")
	assert_str(trace).contains("res://b.gd:2")
	# First error should NOT be in the captured block (latest wins).
	assert_str(trace).not_contains("First error")


func test_extract_latest_trace_finds_most_recent_log_file() -> void:
	_write_log("old.log", "ERROR: old\n  at: x\n")
	# Tiny delay to ensure mtime ordering on filesystems with low resolution.
	OS.delay_msec(1100)
	_write_log("new.log", "ERROR: new\n  at: y\n")
	var trace: String = FractalLogScraperClass.extract_latest_trace(TMP_DIR)
	assert_str(trace).contains("new")
	assert_str(trace).not_contains("old")


func test_truncates_huge_block_at_cap() -> void:
	# Fabricate a stack trace that exceeds MAX_TRACE_BYTES (~64KB). Each
	# frame line is ~50 chars, so 2000 frames = ~100KB > the cap.
	var huge := "ERROR: huge\n"
	for i in range(2000):
		huge += "          at: frame_%d (res://x.gd:%d)\n" % [i, i]
	var path: String = _write_log("huge.log", huge)
	var trace: String = FractalLogScraperClass.extract_trace_from_file(path)
	assert_int(trace.length()).is_less_equal(FractalLogScraperClass.MAX_TRACE_BYTES)
	assert_str(trace).contains("ERROR: huge")


func test_logs_dir_missing_returns_empty() -> void:
	assert_str(FractalLogScraperClass.extract_latest_trace("user://does_not_exist_dir")).is_empty()


# ─── extract_new_blocks (live tailing) ────────────────────────────────────

func test_extract_new_blocks_multi_block_extraction() -> void:
	var content := "SCRIPT ERROR: First error\n          at: a (res://a.gd:1)\nERROR: Second error\n          at: b (res://b.gd:2)\n"
	var path: String = _write_log("multi_blocks.log", content)
	var r: Dictionary = FractalLogScraperClass.extract_new_blocks(path, 0)
	var blocks: Array = r["blocks"]
	assert_int(blocks.size()).is_equal(2)
	assert_str(blocks[0]).contains("First error")
	assert_str(blocks[1]).contains("Second error")


func test_extract_new_blocks_cursor_advancement() -> void:
	var path: String = _write_log("cursor.log", "SCRIPT ERROR: One\n          at: a (res://a.gd:1)\n")
	var r1: Dictionary = FractalLogScraperClass.extract_new_blocks(path, 0)
	assert_int(r1["blocks"].size()).is_equal(1)
	var cursor: int = r1["cursor"]

	var r2: Dictionary = FractalLogScraperClass.extract_new_blocks(path, cursor)
	assert_array(r2["blocks"]).is_empty()

	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	file.seek_end()
	file.store_string("SCRIPT ERROR: Two\n          at: b (res://b.gd:2)\n")
	file.close()

	var r3: Dictionary = FractalLogScraperClass.extract_new_blocks(path, r2["cursor"])
	assert_int(r3["blocks"].size()).is_equal(1)
	assert_str(r3["blocks"][0]).contains("Two")
	assert_str(r3["blocks"][0]).not_contains("One")


func test_extract_new_blocks_excludes_crash_layer_markers() -> void:
	var content := "--- Debugger Break ---\n          at: x (res://x.gd:1)\nhandle_crash: oops\n          at: y (res://y.gd:2)\n"
	var path: String = _write_log("crash_markers.log", content)
	var r: Dictionary = FractalLogScraperClass.extract_new_blocks(path, 0)
	assert_array(r["blocks"]).is_empty()


func test_extract_new_blocks_filters_self_log_lines() -> void:
	var content := "ERROR: Fractal: internal SDK warning\n          at: z (res://z.gd:1)\nSCRIPT ERROR: real bug\n          at: w (res://w.gd:2)\n"
	var path: String = _write_log("self_log.log", content)
	var r: Dictionary = FractalLogScraperClass.extract_new_blocks(path, 0)
	var blocks: Array = r["blocks"]
	assert_int(blocks.size()).is_equal(1)
	assert_str(blocks[0]).contains("real bug")


func test_extract_new_blocks_rotation_resets_cursor() -> void:
	var path: String = _write_log("rotate.log", "SCRIPT ERROR: small\n          at: a (res://a.gd:1)\n")
	# Cursor far beyond the (small, post-rotation) file size.
	var r: Dictionary = FractalLogScraperClass.extract_new_blocks(path, 999999)
	assert_int(r["blocks"].size()).is_equal(1)
	assert_str(r["blocks"][0]).contains("small")


func test_extract_new_blocks_defers_block_clipped_by_cap() -> void:
	# A preceding line so the block's marker does NOT sit at offset 0 of
	# the read window (offset 0 is the degenerate "single block fills the
	# whole window" case, which is handled differently. See the off > 0
	# guard in extract_new_blocks).
	var prefix := "Godot Engine v4.5\n"
	# Marker plus a couple of continuation lines, all within a small forced
	# cap, with more bytes (another block) waiting beyond the cap.
	var clipped_block := "SCRIPT ERROR: clipped\n          at: a (res://a.gd:1)\n          at: b (res://b.gd:2)\n"
	var rest := "          at: c (res://c.gd:3)\n          at: d (res://d.gd:4)\n"
	var more := "SCRIPT ERROR: later\n          at: z (res://z.gd:9)\n"
	var path: String = _write_log("clipped.log", prefix + clipped_block + rest + more)

	# Cap small enough to land inside `clipped_block`, before its full
	# stack trace (and well before `more`) has been read.
	var small_cap: int = (prefix + clipped_block).length() - 10

	var r: Dictionary = FractalLogScraperClass.extract_new_blocks(path, 0, small_cap)
	# The clipped block must NOT be emitted this poll, emitting it would
	# mean a silently truncated stack trace.
	assert_array(r["blocks"]).is_empty()
	# Cursor must not have advanced past the block's marker, so the whole
	# block is re-read in full next poll.
	assert_int(r["cursor"]).is_equal(prefix.to_utf8_buffer().size())

	# Poll again with the default (large) cap, now the whole file is
	# visible, so the full stack trace must land in a single block, not
	# split or dropped.
	var r2: Dictionary = FractalLogScraperClass.extract_new_blocks(path, r["cursor"])
	var blocks: Array = r2["blocks"]
	assert_int(blocks.size()).is_equal(2)
	assert_str(blocks[0]).contains("clipped")
	assert_str(blocks[0]).contains("res://a.gd:1")
	assert_str(blocks[0]).contains("res://c.gd:3")
	assert_str(blocks[0]).contains("res://d.gd:4")
	assert_str(blocks[1]).contains("later")


func test_extract_new_blocks_partial_line_not_consumed() -> void:
	var path: String = _write_log("partial.log", "SCRIPT ERROR: complete\n          at: a (res://a.gd:1)\n")
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	file.seek_end()
	# Append a line with NO trailing newline, simulates a half-flushed write.
	file.store_string("ERROR: incomplete line with no newline yet")
	file.close()

	var r: Dictionary = FractalLogScraperClass.extract_new_blocks(path, 0)
	assert_int(r["blocks"].size()).is_equal(1)
	assert_str(r["blocks"][0]).contains("complete")
	# Cursor must not have advanced past the incomplete trailing line.
	var size: int = FileAccess.open(path, FileAccess.READ).get_length()
	assert_int(r["cursor"]).is_less(size)

	# Completing the line on a later poll should now surface it.
	var file2 := FileAccess.open(path, FileAccess.READ_WRITE)
	file2.seek_end()
	file2.store_string("\n")
	file2.close()
	var r2: Dictionary = FractalLogScraperClass.extract_new_blocks(path, r["cursor"])
	assert_int(r2["blocks"].size()).is_equal(1)
	assert_str(r2["blocks"][0]).contains("incomplete line")

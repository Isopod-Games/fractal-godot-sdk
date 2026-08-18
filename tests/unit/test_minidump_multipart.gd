extends GdUnitTestSuite
## Validates the multipart body construction in errors.gd::_build_multipart_body.
## This is the wire format for POST /v1/minidumps, a regression here would
## silently break native crash uploads.

const FractalErrorsClass = preload("res://addons/fractal/errors/errors.gd")

var errors: Node


func before_test() -> void:
	errors = FractalErrorsClass.new()
	add_child(errors)
	await get_tree().process_frame


func after_test() -> void:
	if errors:
		errors.queue_free()


func _make_dump_bytes() -> PackedByteArray:
	# Minidumps start with the magic "MDMP", fake one for the parser test.
	return PackedByteArray([0x4d, 0x44, 0x4d, 0x50, 0x93, 0xa7, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04])


func test_multipart_contains_three_parts_in_order() -> void:
	var dump_bytes := _make_dump_bytes()
	var meta := {
		"event_id": "abc123",
		"runtime": {"name": "godot", "version": "4.5.0"},
		"app_version": "1.0.0",
	}
	var body: PackedByteArray = errors._build_multipart_body(
		"BOUNDARY", "/tmp/test.dmp", dump_bytes, meta,
	)
	var s: String = body.get_string_from_utf8()
	# Three named form parts, in this order.
	var dump_format_idx: int = s.find('name="dump_format"')
	var metadata_idx: int = s.find('name="metadata"')
	var minidump_idx: int = s.find('name="minidump"')
	assert_int(dump_format_idx).is_greater(-1)
	assert_int(metadata_idx).is_greater(dump_format_idx)
	assert_int(minidump_idx).is_greater(metadata_idx)


func test_multipart_dump_format_is_crashpad() -> void:
	var body: PackedByteArray = errors._build_multipart_body(
		"BOUNDARY", "/tmp/x.dmp", _make_dump_bytes(), {},
	)
	var s: String = body.get_string_from_utf8()
	# The dump_format part body must literally contain "crashpad".
	var idx: int = s.find('name="dump_format"')
	var section: String = s.substr(idx, 200)
	assert_str(section).contains("crashpad")


func test_multipart_filename_taken_from_path() -> void:
	var body: PackedByteArray = errors._build_multipart_body(
		"B", "/some/dir/dump_xyz.dmp", _make_dump_bytes(), {},
	)
	var s: String = body.get_string_from_utf8()
	assert_str(s).contains('filename="dump_xyz.dmp"')


func test_multipart_metadata_is_valid_json() -> void:
	var meta := {
		"event_id": "evt-1",
		"runtime": {"name": "godot", "version": "4.5"},
		"app_version": "9.9.9",
		"breadcrumbs": [{"message": "hello", "category": "test"}],
	}
	var body: PackedByteArray = errors._build_multipart_body(
		"B", "/x.dmp", _make_dump_bytes(), meta,
	)
	var s: String = body.get_string_from_utf8()
	# Find the start of the metadata payload, after the empty line that
	# separates headers from body inside that part.
	var meta_header_idx: int = s.find('name="metadata"')
	var body_start: int = s.find("\r\n\r\n", meta_header_idx) + 4
	var body_end: int = s.find("\r\n--B", body_start)
	var meta_str: String = s.substr(body_start, body_end - body_start)

	var json := JSON.new()
	assert_int(json.parse(meta_str)).is_equal(OK)
	var parsed: Dictionary = json.data
	assert_str(parsed.event_id).is_equal("evt-1")
	assert_str(parsed.runtime.name).is_equal("godot")
	assert_str(parsed.app_version).is_equal("9.9.9")
	assert_int(parsed.breadcrumbs.size()).is_equal(1)


func test_multipart_dump_bytes_round_trip_intact() -> void:
	# Embed a binary pattern that includes \r\n. The multipart parser on
	# the server side uses the boundary to split, bytes within a part
	# must NOT be mangled.
	var dump_bytes := PackedByteArray([0x00, 0x0d, 0x0a, 0xff, 0x00, 0x4d, 0x44, 0x4d, 0x50])
	var body: PackedByteArray = errors._build_multipart_body(
		"BNDRY", "/test.dmp", dump_bytes, {},
	)
	# The dump bytes appear verbatim in the body, immediately after the
	# minidump part headers + the empty separator line.
	var s_prefix: String = body.get_string_from_utf8()  # may have replacement chars in the binary section
	var minidump_idx: int = s_prefix.find('name="minidump"')
	# Walk past the part headers to the first \r\n\r\n separator.
	# We compute this on UTF-8 bytes for a clean offset.
	var ascii_view: PackedByteArray = body.slice(0, minidump_idx + 200)
	# Find \r\n\r\n in the byte array directly.
	var sep_offset: int = -1
	for i in range(minidump_idx, ascii_view.size() - 3):
		if ascii_view[i] == 0x0d and ascii_view[i+1] == 0x0a and ascii_view[i+2] == 0x0d and ascii_view[i+3] == 0x0a:
			sep_offset = i + 4
			break
	assert_int(sep_offset).is_greater(-1)
	# The next len(dump_bytes) bytes of `body` MUST equal dump_bytes exactly.
	for i in range(dump_bytes.size()):
		assert_int(body[sep_offset + i]).is_equal(dump_bytes[i])


func test_multipart_terminator_uses_boundary() -> void:
	var body: PackedByteArray = errors._build_multipart_body(
		"MYBOUNDARY", "/x.dmp", _make_dump_bytes(), {},
	)
	# Closing boundary line is at the END of the body: --MYBOUNDARY--\r\n
	# Comparing on bytes directly because the embedded dump may contain
	# non-UTF-8 sequences that break get_string_from_utf8().
	var terminator: PackedByteArray = "\r\n--MYBOUNDARY--\r\n".to_utf8_buffer()
	var tail: PackedByteArray = body.slice(body.size() - terminator.size(), body.size())
	for i in range(terminator.size()):
		assert_int(tail[i]).is_equal(terminator[i])

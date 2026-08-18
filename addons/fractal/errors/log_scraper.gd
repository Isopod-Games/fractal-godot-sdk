class_name FractalLogScraper
extends RefCounted
## Best-effort stack-trace extraction from Godot's log files.
##
## Used to enrich a synthetic AbnormalShutdown event with whatever Godot
## flushed to disk before dying. Quietly returns "" if nothing useful is
## found — the synthetic event is still emitted with breadcrumbs from the
## session marker.
##
## Cross-engine note: this implementation is Godot-specific (parses
## "SCRIPT ERROR:" / "ERROR:" lines and Godot stack-trace formatting).
## Sibling implementations for Unity / Unreal / JS will tail their
## respective log formats but produce the same `stack_trace` string for
## the wire payload.

## Maximum bytes to read from any single log file. Beyond this, we sample
## the tail (which is where recent errors live).
const MAX_READ_BYTES: int = 256 * 1024

## Maximum length of the extracted stack-trace string included in the
## persisted event. Hard-capped so a runaway log can't blow out our payload.
const MAX_TRACE_BYTES: int = 64 * 1024

const ERROR_MARKERS: Array[String] = [
	"SCRIPT ERROR:",
	"USER SCRIPT ERROR:",
	"ERROR:",
	"CRITICAL:",
	"--- Debugger Break ---",
	"handle_crash:",
]

# Live-tail markers: deliberately EXCLUDE "--- Debugger Break ---" and
# "handle_crash:", which belong to the crash layers and would otherwise be
# double-reported alongside UnhandledCrash/AbnormalShutdown.
const LIVE_ERROR_MARKERS: Array[String] = [
	"SCRIPT ERROR:",
	"USER SCRIPT ERROR:",
	"ERROR:",
	"CRITICAL:",
]

# Drop the SDK's own log lines. Matches the SDK's actual log signatures,
# NOT a bare "Fractal" substring (a user class named `Fractal` would
# otherwise be wrongly filtered).
const SELF_LOG_FILTERS: Array[String] = ["Fractal:", "Fractal.", "[Fractal]"]

# Cap bytes read per poll so a huge delta (error flood / heartbeat-starved
# frame) can't stall the game thread or allocate a giant PackedByteArray
# in one go.
const MAX_POLL_BYTES: int = 1 * 1024 * 1024  # 1 MB


## Returns the most recent error block from the most recently modified log
## file under the user's logs directory, or "" if nothing was found.
##
## `logs_dir`: usually `OS.get_user_data_dir().path_join("logs")` for the
## active project. Allowing it to be passed in keeps the function pure
## and testable without a real Godot user dir.
static func extract_latest_trace(logs_dir: String) -> String:
	var path: String = _find_most_recent_log(logs_dir)
	if path.is_empty():
		return ""
	return extract_trace_from_file(path)


## Read `path` and return its last error block, capped at MAX_TRACE_BYTES.
## Public so tests can hand it a fixture file directly.
static func extract_trace_from_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var size: int = file.get_length()
	# For large logs, jump to the tail — recent errors live there.
	if size > MAX_READ_BYTES:
		file.seek(size - MAX_READ_BYTES)
	var text := file.get_as_text()
	file.close()
	return _extract_last_error_block(text)


## Reads NEW bytes from `path` since byte `cursor` and returns every
## complete error block found in that delta:
##   { "cursor": <new offset to persist>, "blocks": Array[String] }
##
## Unlike `extract_trace_from_file` (built for one-shot AbnormalShutdown
## enrichment, which returns only the LAST block from a bounded tail read),
## this is cursor-based and returns EVERY block in the new bytes, since
## it's polled repeatedly on the heartbeat to live-tail the current session.
static func extract_new_blocks(path: String, cursor: int, max_poll_bytes: int = MAX_POLL_BYTES) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"cursor": cursor, "blocks": []}
	var size: int = file.get_length()

	var start: int = cursor
	# Log rotated/truncated (or recreated smaller) — restart from scratch.
	if start > size or start < 0:
		start = 0

	var read_len: int = min(size - start, max_poll_bytes)
	if read_len <= 0:
		file.close()
		return {"cursor": start, "blocks": []}
	var more_pending: bool = (size - start) > read_len

	file.seek(start)
	var bytes: PackedByteArray = file.get_buffer(read_len)
	file.close()
	var text: String = bytes.get_string_from_utf8()

	# Advance the cursor only past the last complete line in the bytes we
	# actually read. This handles a half-flushed final line (Godot writes
	# concurrently) and a capped read landing mid-line — the remainder is
	# read on the next poll. If there's no newline at all, don't advance.
	var last_newline: int = text.rfind("\n")
	if last_newline < 0:
		return {"cursor": start, "blocks": []}

	var complete_text: String = text.substr(0, last_newline + 1)
	var new_cursor: int = start + complete_text.to_utf8_buffer().size()
	var extracted: Dictionary = _extract_live_blocks(complete_text)
	var blocks: Array[String] = extracted["blocks"]
	var off: int = extracted["incomplete_tail_offset"]

	# If the read was byte-capped AND the trailing block ran to the end of
	# the window with no terminator, it may just be missing its tail (the
	# rest hasn't been polled yet). Defer it — drop it from this poll's
	# result and rewind the cursor to its marker — so it's re-read whole
	# next poll instead of being silently truncated. `off > 0` guards
	# against the degenerate case of a single unterminated block filling
	# the entire window (a >1MB single stack trace, effectively
	# impossible given Godot's ~1024-frame depth cap): rewinding there
	# would stall the cursor forever, so we keep the (already
	# MAX_TRACE_BYTES-truncated) block and advance normally instead.
	if more_pending and off > 0:
		blocks.pop_back()
		new_cursor = start + complete_text.substr(0, off).to_utf8_buffer().size()

	# Note: when off >= 0 but more_pending is false (we've read to true EOF),
	# the trailing block is NOT deferred — it's assumed complete. This relies
	# on Godot writing an error's marker + full stack trace in one flush, so a
	# write split exactly at a line boundary mid-trace could in theory still
	# surface a truncated block. Same assumption the MAX_TRACE_BYTES cap above
	# already relies on.
	return {"cursor": new_cursor, "blocks": blocks}


# ─── Internal ─────────────────────────────────────────────────────────────

## Splits `text` into every error block: a block starts at a line whose
## left-stripped form begins with a LIVE_ERROR_MARKERS entry and contains
## none of SELF_LOG_FILTERS; it consumes following indented lines (the
## stack trace) until a non-indented line ends it.
##
## Returns `{ "blocks": Array[String], "incomplete_tail_offset": int }`.
## `incomplete_tail_offset` is the char offset (into `text`) of the
## trailing block's marker line iff that block ran all the way to the end
## of `text` with no non-indented terminator line (i.e. it may be missing
## its tail because `text` was cut off, not because the block actually
## ended) — only the last block in `text` can satisfy this. Otherwise -1.
static func _extract_live_blocks(text: String) -> Dictionary:
	var blocks: Array[String] = []
	if text.is_empty():
		return {"blocks": blocks, "incomplete_tail_offset": -1}
	var lines: PackedStringArray = text.split("\n", false)
	var incomplete_tail_offset: int = -1
	var search_pos: int = 0
	var i: int = 0
	while i < lines.size():
		var marker_offset: int = text.find(lines[i], search_pos)
		search_pos = marker_offset + lines[i].length() + 1
		var stripped: String = lines[i].strip_edges(true, false)
		var is_marker: bool = false
		for marker in LIVE_ERROR_MARKERS:
			if stripped.begins_with(marker):
				is_marker = true
				break
		if not is_marker:
			i += 1
			continue
		var is_self_log: bool = false
		for filt in SELF_LOG_FILTERS:
			if stripped.contains(filt):
				is_self_log = true
				break
		if is_self_log:
			i += 1
			continue

		var block_lines: PackedStringArray = PackedStringArray([lines[i]])
		var j: int = i + 1
		while j < lines.size():
			var next_line: String = lines[j]
			if next_line.begins_with(" ") or next_line.begins_with("\t"):
				block_lines.append(next_line)
				search_pos = text.find(next_line, search_pos) + next_line.length() + 1
				j += 1
			else:
				break
		incomplete_tail_offset = marker_offset if j >= lines.size() else -1
		var block: String = "\n".join(block_lines)
		if block.length() > MAX_TRACE_BYTES:
			block = block.substr(0, MAX_TRACE_BYTES)
		blocks.append(block)
		i = j
	return {"blocks": blocks, "incomplete_tail_offset": incomplete_tail_offset}


static func _extract_last_error_block(text: String) -> String:
	if text.is_empty():
		return ""
	# Find the last line index that starts with any error marker.
	var lines: PackedStringArray = text.split("\n", false)
	var last_marker_idx: int = -1
	for i in range(lines.size()):
		var line: String = lines[i].strip_edges(true, false)
		for marker in ERROR_MARKERS:
			if line.begins_with(marker):
				last_marker_idx = i
				break
	if last_marker_idx < 0:
		return ""
	# Capture from the marker line through the rest of the captured tail.
	var block_lines: PackedStringArray = PackedStringArray()
	for i in range(last_marker_idx, lines.size()):
		block_lines.append(lines[i])
	var block: String = "\n".join(block_lines)
	if block.length() > MAX_TRACE_BYTES:
		# Keep the head of the block (the actual error line) — the
		# back-trace tail is less important than identifying the error.
		block = block.substr(0, MAX_TRACE_BYTES)
	return block


static func _find_most_recent_log(logs_dir: String) -> String:
	if logs_dir.is_empty() or not DirAccess.dir_exists_absolute(logs_dir):
		return ""
	var dir := DirAccess.open(logs_dir)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	var newest_path: String = ""
	var newest_mtime: int = 0
	while entry != "":
		if not dir.current_is_dir() and (entry.ends_with(".log") or entry.ends_with(".txt")):
			var full: String = logs_dir.path_join(entry)
			var mtime: int = FileAccess.get_modified_time(full)
			if mtime > newest_mtime:
				newest_mtime = mtime
				newest_path = full
		entry = dir.get_next()
	dir.list_dir_end()
	return newest_path

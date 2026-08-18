class_name FractalEventQueue
extends RefCounted
## Manages event batching and queue for sending to the collector.

signal batch_ready(events: Array)
signal queue_overflow(dropped_count: int)

const DEFAULT_BATCH_SIZE := 10
const DEFAULT_FLUSH_INTERVAL := 30.0
const DEFAULT_MAX_QUEUE_SIZE := 1000

var batch_size: int = DEFAULT_BATCH_SIZE
var flush_interval: float = DEFAULT_FLUSH_INTERVAL
var max_queue_size: int = DEFAULT_MAX_QUEUE_SIZE

var _events: Array = []
var _last_flush_time: float = 0.0
var _debug: bool = false
var _seq: int = 0


func configure(opts: Dictionary) -> void:
	if opts.has("batch_size"):
		batch_size = opts.batch_size
	if opts.has("flush_interval"):
		flush_interval = opts.flush_interval
	if opts.has("max_queue_size"):
		max_queue_size = opts.max_queue_size
	if opts.has("debug"):
		_debug = opts.debug


func add_event(event_type: String, payload: Dictionary = {}) -> void:
	var event := {
		"event_type": event_type,
		"event_timestamp": _iso_now(),
		"client_seq": _seq,
		"payload": payload,
	}
	_seq += 1
	_events.append(event)

	if _events.size() > max_queue_size:
		var dropped: int = _events.size() - max_queue_size
		_events = _events.slice(-max_queue_size)
		queue_overflow.emit(dropped)

	if _events.size() >= batch_size:
		_emit_batch()


func check_flush(current_time: float) -> void:
	if _events.is_empty():
		return
	if current_time - _last_flush_time >= flush_interval:
		_emit_batch()


func flush() -> void:
	if _events.is_empty():
		return
	_emit_batch()


func get_pending_events() -> Array:
	return _events.duplicate()


func set_events(events: Array) -> void:
	_events = events


func clear_sent_events(count: int) -> void:
	if count >= _events.size():
		_events.clear()
	else:
		_events = _events.slice(count)


func get_event_count() -> int:
	return _events.size()


func is_empty() -> bool:
	return _events.is_empty()


func _emit_batch() -> void:
	if _events.is_empty():
		return
	var to_send := _events.slice(0, batch_size)
	_last_flush_time = Time.get_unix_time_from_system()
	batch_ready.emit(to_send)


static func _iso_now() -> String:
	# Single clock read (unix time) drives both the calendar breakdown and the
	# millisecond component, avoiding a race where two separate reads straddle
	# a second boundary and produce an inconsistent timestamp.
	var unix := Time.get_unix_time_from_system()
	# Unix time is always UTC by definition, so this needs no separate utc flag
	# (unlike get_datetime_dict_from_system(), which does).
	var dt := Time.get_datetime_dict_from_unix_time(int(unix))
	var ms := int(fmod(unix, 1.0) * 1000)
	return "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, ms]

extends Node
## Analytics subsystem, `Fractal.analytics`.
##
## Public API:
##   track(event_type, payload)
##   flush()
##   start_session() / end_session()
##   set_player_id(id) / get_player_id()
##   set_user_property(key, value)
##
## When the `analytics_enabled` toggle is false, every method short-circuits
## without queuing or sending anything.

signal event_tracked(event_type: String)
signal batch_sent(event_count: int)
signal batch_failed(error: String)

const FractalConfigClass := preload("res://addons/fractal/core/config.gd")
const FractalEventQueueClass := preload("res://addons/fractal/analytics/event_queue.gd")
const FractalHttpClientClass := preload("res://addons/fractal/core/http_client.gd")
const FractalPlatformDetectorClass := preload("res://addons/fractal/core/platform_detector.gd")
const FractalPersistenceClass := preload("res://addons/fractal/core/persistence.gd")

var _enabled: bool = false
var _config: FractalConfigClass = null
var _player_id: String = ""
var _session_token: String = ""
var _user_properties: Dictionary = {}

var _queue: FractalEventQueueClass
var _http: FractalHttpClientClass
var _flush_timer: Timer
var _pending_batch: Array = []


func _ready() -> void:
	_queue = FractalEventQueueClass.new()
	_queue.batch_ready.connect(_on_batch_ready)
	_queue.queue_overflow.connect(_on_queue_overflow)

	_http = FractalHttpClientClass.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_http.request_failed.connect(_on_request_failed)

	_flush_timer = Timer.new()
	_flush_timer.wait_time = 5.0
	_flush_timer.timeout.connect(_on_flush_tick)
	add_child(_flush_timer)


func configure(config: FractalConfigClass) -> void:
	_config = config
	_enabled = config.analytics_enabled
	if not _enabled:
		_flush_timer.stop()
		return

	_queue.configure({
		"batch_size": config.analytics_batch_size,
		"flush_interval": config.analytics_flush_interval,
		"max_queue_size": config.analytics_max_queue_size,
		"debug": config.debug,
	})
	_http.configure(config.api_key, config.debug)

	if _player_id.is_empty():
		_player_id = FractalPersistenceClass.resolve_player_id()

	# Restore any events persisted from a previous session, but only on
	# first-time configure (queue empty). On reconfigure we keep the live
	# queue intact so events tracked between configure() calls aren't lost.
	if _queue.is_empty():
		var persisted := FractalPersistenceClass.load_events()
		if not persisted.is_empty():
			_queue.set_events(persisted)
			if config.debug:
				print("[Fractal] restored %d persisted analytics events" % persisted.size())

	if _flush_timer.is_stopped():
		_flush_timer.start()


# ─── Public API ───────────────────────────────────────────────────────────

func track(event_type: String, payload: Dictionary = {}) -> void:
	if not _enabled:
		return
	if event_type.is_empty():
		push_warning("Fractal.analytics.track: event_type cannot be empty")
		return
	_queue.add_event(event_type, payload)
	event_tracked.emit(event_type)


func flush() -> void:
	if not _enabled:
		return
	_queue.flush()


func start_session() -> void:
	if not _enabled:
		return
	_session_token = _generate_session_token()
	track("session_start")


func end_session() -> void:
	if not _enabled:
		return
	track("session_end")
	flush()


func set_player_id(player_id: String) -> void:
	if player_id.is_empty():
		push_warning("Fractal.analytics.set_player_id: id cannot be empty")
		return
	_player_id = player_id
	FractalPersistenceClass.save_player_id(player_id)


func get_player_id() -> String:
	return _player_id


func set_user_property(key: String, value) -> void:
	_user_properties[key] = value


func get_session_token() -> String:
	return _session_token


func get_pending_event_count() -> int:
	return _queue.get_event_count()


func is_enabled() -> bool:
	return _enabled


## Called by the Fractal autoload on shutdown, persists pending events for retry.
func shutdown() -> void:
	if not _enabled:
		return
	var pending := _queue.get_pending_events()
	if not pending.is_empty():
		FractalPersistenceClass.save_events(pending)


# ─── Internal ─────────────────────────────────────────────────────────────

func _on_batch_ready(events: Array) -> void:
	if _http.is_busy():
		return
	_pending_batch = events
	_send_batch(events)


func _send_batch(events: Array) -> void:
	var ctx: Dictionary = FractalPlatformDetectorClass.get_context(
		_player_id, _session_token, _config.app_version, _config.environment,
	)
	if not _user_properties.is_empty():
		ctx["user_properties"] = _user_properties
	var payload := {
		"sent_at": _iso_now(),
		"context": ctx,
		"events": events,
	}
	var url: String = _config.collector_url.trim_suffix("/") + "/v1/batch"
	_http.request(HTTPClient.METHOD_POST, url, PackedStringArray(), JSON.stringify(payload))


func _on_request_completed(_status: int, _headers: PackedStringArray, _body: String) -> void:
	var sent_count: int = _pending_batch.size()
	_queue.clear_sent_events(sent_count)
	_pending_batch.clear()
	batch_sent.emit(sent_count)
	if _queue.is_empty():
		FractalPersistenceClass.clear_events()
	else:
		_queue.flush()


func _on_request_failed(error: String, response_code: int = 0) -> void:
	var dropped_count: int = _pending_batch.size()
	var permanently_rejected: bool = response_code >= 400 and response_code < 500 and response_code != 429
	if permanently_rejected:
		# Permanent 4xx (never retried by http_client.gd), the collector will
		# never accept this batch (blocked key, malformed payload, etc.).
		# Retrying it every session would wedge future uploads behind one
		# poison batch forever, so dead-letter it instead: don't lose the
		# data, but don't retry it either.
		FractalPersistenceClass.append_to_dead_letter_events(_pending_batch)
		_queue.clear_sent_events(dropped_count)
		push_error("Fractal.analytics: batch permanently rejected and moved to dead-letter queue: %s" % error)
	_pending_batch.clear()
	batch_failed.emit(error)
	# Persist whatever's still queued so it survives the next session.
	var pending := _queue.get_pending_events()
	if not pending.is_empty():
		FractalPersistenceClass.save_events(pending)
	elif permanently_rejected:
		FractalPersistenceClass.clear_events()
	# Do not flush here, the 5s timer handles it; an immediate flush after
	# exhausted retries would restart a new backoff cycle with no delay.


func _on_queue_overflow(dropped_count: int) -> void:
	push_warning("Fractal.analytics: queue overflow, dropped %d events" % dropped_count)


func _on_flush_tick() -> void:
	_queue.check_flush(Time.get_unix_time_from_system())


func _generate_session_token(rng: RandomNumberGenerator = null) -> String:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	var hex := ""
	for i in range(8):
		hex += "%02x" % rng.randi_range(0, 255)
	# Fold in a microsecond wall-clock read so two launches whose randomize()
	# seeds collide (issue #355) still can't mint the same session_token.
	var micros := int(Time.get_unix_time_from_system() * 1000000)
	return "sess_%d_%s" % [micros, hex]


static func _iso_now() -> String:
	var dt := Time.get_datetime_dict_from_system(true)
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]

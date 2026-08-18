extends GdUnitTestSuite

const FractalMockServerClass = preload("res://tests/integration/mock_server.gd")
const FractalConfigClass = preload("res://addons/fractal/core/config.gd")
const FractalErrorsClass = preload("res://addons/fractal/errors/errors.gd")
const FractalPersistenceClass = preload("res://addons/fractal/core/persistence.gd")
const FractalSessionMarkerClass = preload("res://addons/fractal/errors/session_marker.gd")
const FractalTestHelpersClass = preload("res://tests/helpers/test_helpers.gd")

var server: Node
var errors: Node


func before_test() -> void:
	if DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		FractalTestHelpersClass.remove_dir_recursive(FractalPersistenceClass.ROOT)

	server = FractalMockServerClass.new()
	add_child(server)
	server.start()

	errors = FractalErrorsClass.new()
	add_child(errors)
	await get_tree().process_frame


func after_test() -> void:
	if errors:
		errors.queue_free()
	if server:
		server.stop()
		server.queue_free()
	if DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		FractalTestHelpersClass.remove_dir_recursive(FractalPersistenceClass.ROOT)
	if DirAccess.dir_exists_absolute(TMP_DIR):
		FractalTestHelpersClass.remove_dir_recursive(TMP_DIR)


func _make_config() -> FractalConfig:
	var config: FractalConfig = FractalConfigClass.new()
	config.api_key = "test-key"
	config.collector_url = server.url()
	config.app_version = "9.9.9"
	config.environment = "test"
	config.analytics_enabled = false
	# Disable session marker by default in these tests so the heartbeat
	# Timer + abnormal-shutdown inference don't interfere with tests that
	# focus on capture/replay behavior. Tests that need it opt in.
	config.errors_session_marker_enabled = false
	# Disable live log capture by default — tests that exercise it set up
	# a fixture log + cursor manually and opt in.
	config.errors_live_log_capture_enabled = false
	return config


const TMP_DIR := "user://test_errors_flow"


func _write_log(name: String, content: String) -> String:
	if not DirAccess.dir_exists_absolute(TMP_DIR):
		DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var path: String = TMP_DIR.path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return path


func _append_log(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	file.seek_end()
	file.store_string(content)
	file.close()


func test_capture_error_posts_to_v1_errors() -> void:
	server.enqueue_response("POST", "/v1/errors", 202, "{}")

	errors.configure(_make_config())
	errors.add_breadcrumb("clicked start", "ui", "info")
	errors.set_tag("build", "release")
	errors.capture_error("NullReferenceException", "ouch", {
		"severity": "error",
		"handled": false,
		"stack_trace": "at line 42",
	})

	var sent: Array = []
	errors.error_sent.connect(func(): sent.append(true))
	var ok: bool = await FractalTestHelpersClass.wait_for(get_tree(), func(): return not sent.is_empty(), 5000)
	assert_bool(ok).is_true()

	assert_int(server.requests.size()).is_equal(1)
	var req: Dictionary = server.requests[0]
	assert_str(req.method).is_equal("POST")
	assert_str(req.path).is_equal("/v1/errors")

	var json := JSON.new()
	assert_int(json.parse(req.body)).is_equal(OK)
	var payload: Dictionary = json.data
	var error: Dictionary = payload.errors[0]
	assert_str(error.error_type).is_equal("NullReferenceException")
	assert_str(error.message).is_equal("ouch")
	assert_str(error.severity).is_equal("error")
	assert_bool(error.handled).is_false()
	assert_str(error.stack_trace).is_equal("at line 42")
	assert_dict(error.tags).contains_key_value("build", "release")
	assert_int(error.breadcrumbs.size()).is_equal(1)
	assert_str(error.breadcrumbs[0].message).is_equal("clicked start")
	assert_str(error.release).is_equal("9.9.9")
	assert_str(error.environment).is_equal("test")
	assert_bool(payload.context.player_id.begins_with("godot_")).is_true()


func test_capture_error_still_attributed_when_analytics_disabled() -> void:
	# The important regression case: _make_config() sets analytics_enabled = false,
	# yet errors must still resolve and send its own player_id.
	server.enqueue_response("POST", "/v1/errors", 202, "{}")

	errors.configure(_make_config())
	errors.capture_error("NullReferenceException", "ouch")

	var sent: Array = []
	errors.error_sent.connect(func(): sent.append(true))
	var ok: bool = await FractalTestHelpersClass.wait_for(get_tree(), func(): return not sent.is_empty(), 5000)
	assert_bool(ok).is_true()

	var json := JSON.new()
	json.parse(server.requests[0].body)
	var payload: Dictionary = json.data
	assert_bool(String(payload.context.player_id).begins_with("godot_")).is_true()


func test_pre_seeded_player_id_is_reused_not_regenerated() -> void:
	FractalPersistenceClass.save_player_id("godot_existing-id")
	server.enqueue_response("POST", "/v1/errors", 202, "{}")

	errors.configure(_make_config())
	errors.capture_error("NullReferenceException", "ouch")

	var sent: Array = []
	errors.error_sent.connect(func(): sent.append(true))
	var ok: bool = await FractalTestHelpersClass.wait_for(get_tree(), func(): return not sent.is_empty(), 5000)
	assert_bool(ok).is_true()

	var json := JSON.new()
	json.parse(server.requests[0].body)
	var payload: Dictionary = json.data
	assert_str(payload.context.player_id).is_equal("godot_existing-id")


func test_session_token_present_only_with_active_analytics_session() -> void:
	const FractalAnalyticsClass = preload("res://addons/fractal/analytics/analytics.gd")
	var analytics: Node = FractalAnalyticsClass.new()
	add_child(analytics)
	await get_tree().process_frame
	errors.set_analytics(analytics)

	var config: FractalConfig = _make_config()
	config.analytics_enabled = true
	server.enqueue_response("POST", "/v1/batch", 202, "{}")
	analytics.configure(config)

	errors.configure(config)

	# No session started yet — session_token should be empty.
	server.enqueue_response("POST", "/v1/errors", 202, "{}")
	errors.capture_error("NoSessionError", "no session yet")
	var sent1: Array = []
	errors.error_sent.connect(func(): sent1.append(true))
	await FractalTestHelpersClass.wait_for(get_tree(), func(): return not sent1.is_empty(), 5000)
	var json1 := JSON.new()
	json1.parse(server.requests[-1].body)
	assert_str(json1.data.context.session_token).is_equal("")

	# Start a session — subsequent errors carry a sess_ token.
	analytics.start_session()
	server.enqueue_response("POST", "/v1/errors", 202, "{}")
	var sent2: Array = []
	errors.error_sent.connect(func(): sent2.append(true))
	errors.capture_error("WithSessionError", "session active")
	await FractalTestHelpersClass.wait_for(get_tree(), func(): return not sent2.is_empty(), 5000)
	var json2 := JSON.new()
	json2.parse(server.requests[-1].body)
	assert_bool(String(json2.data.context.session_token).begins_with("sess_")).is_true()

	analytics.queue_free()


func test_handle_crash_writes_player_id_to_crash_report() -> void:
	errors.configure(_make_config())
	errors.handle_crash()
	var report: Dictionary = FractalPersistenceClass.load_crash_report()
	assert_bool(String(report.get("player_id", "")).begins_with("godot_")).is_true()


func test_no_op_when_disabled() -> void:
	var config: FractalConfig = _make_config()
	config.errors_enabled = false
	errors.configure(config)
	errors.capture_error("X", "y")
	for i in range(3):
		await get_tree().process_frame
	assert_int(server.requests.size()).is_equal(0)


func test_replay_previous_crash() -> void:
	# Pre-seed a crash report on disk before configure() runs replay.
	var crash_report: Dictionary = {
		"timestamp": "2026-04-29T00:00:00Z",
		"app_version": "9.9.9",
		"environment": "test",
		"breadcrumbs": [{"timestamp": "2026-04-29T00:00:00Z", "category": "x", "message": "y", "level": "info"}],
	}
	FractalPersistenceClass.save_crash_report(crash_report)

	server.enqueue_response("POST", "/v1/errors", 202, "{}")

	errors.configure(_make_config())
	errors.replay_previous_crash()

	var sent: Array = []
	errors.error_sent.connect(func(): sent.append(true))
	var ok: bool = await FractalTestHelpersClass.wait_for(get_tree(), func(): return not sent.is_empty(), 5000)
	assert_bool(ok).is_true()

	assert_int(server.requests.size()).is_equal(1)
	var json := JSON.new()
	json.parse(server.requests[0].body)
	var payload: Dictionary = json.data
	var error: Dictionary = payload.errors[0]
	assert_str(error.error_type).is_equal("UnhandledCrash")
	assert_str(error.severity).is_equal("fatal")
	assert_bool(error.handled).is_false()

	# Crash report file should be cleared after replay.
	assert_dict(FractalPersistenceClass.load_crash_report()).is_empty()


func test_permanent_4xx_dead_letters_and_does_not_retry() -> void:
	# Server returns 400 (no retry — synchronous fail-fast, permanently rejected).
	server.enqueue_response("POST", "/v1/errors", 400, "bad")

	errors.configure(_make_config())
	var failed: Array = []
	errors.error_failed.connect(func(_e): failed.append(true))
	errors.capture_error("PoisonError", "first attempt", {"severity": "warning"})

	var ok_failed: bool = await FractalTestHelpersClass.wait_for(
		get_tree(), func(): return not failed.is_empty(), 5000,
	)
	assert_bool(ok_failed).is_true()

	# A permanently-rejected batch must NOT sit on disk for retry — it would
	# silently wedge all future uploads behind this one poison event.
	assert_array(FractalPersistenceClass.load_error_queue()).is_empty()

	# It must be preserved for inspection in the dead-letter queue instead.
	var dead_lettered: Array = FractalPersistenceClass.load_dead_letter_error_queue()
	assert_int(dead_lettered.size()).is_equal(1)
	assert_str(dead_lettered[0].error_type).is_equal("PoisonError")

	# Simulate next session: tear down errors module + spin up a new one
	# pointed at the same DB. Server would accept anything now (202), but
	# nothing should be sent — there's nothing left in the retry queue.
	errors.queue_free()
	await get_tree().process_frame
	server.enqueue_response("POST", "/v1/errors", 202, "{}")

	errors = FractalErrorsClass.new()
	add_child(errors)
	await get_tree().process_frame
	errors.configure(_make_config())   # configure() drains the (now-empty) queue.
	await get_tree().process_frame
	await get_tree().process_frame

	assert_int(server.requests.size()).is_equal(1)


func test_handle_crash_persists_in_flight_buffer() -> void:
	# Capture two errors back-to-back without awaiting a server response so the
	# second error accumulates in _buffer while the first is in-flight.
	# handle_crash() must persist that second error to disk before it's lost.
	errors.configure(_make_config())

	# No server response enqueued — the first flush stays in-flight indefinitely.
	errors.capture_error("InFlightError", "sent but no response yet")
	# _send_in_flight=true now; second error goes into _buffer.
	errors.capture_error("BufferedError", "blocked by in-flight")

	# Simulate NOTIFICATION_CRASH — synchronous, no await.
	errors.handle_crash()

	var queued: Array = FractalPersistenceClass.load_error_queue()
	var types: Array = []
	for e in queued:
		types.append(e.error_type)
	assert_bool(types.has("BufferedError")).is_true()


func test_flush_merges_previously_failed_batch() -> void:
	# Configure with an empty queue first so startup drain has nothing to do.
	errors.configure(_make_config())

	# Simulate a batch left on disk by an earlier transient failure this
	# session (network/5xx) — _flush() persists the merged batch before POST
	# and only clears it on success, so a still-pending retry looks like this.
	FractalPersistenceClass.save_error_queue([{
		"error_type": "OldError", "message": "first attempt", "severity": "error",
		"handled": true, "platform": "", "app_version": "", "timestamp": "2026-01-01T00:00:00Z",
	}])

	# Next flush: capture a new error; server succeeds. The POST must include
	# both the previously-failed OldError and the new NewError.
	server.enqueue_response("POST", "/v1/errors", 202, "{}")
	var sent: Array = []
	errors.error_sent.connect(func(): sent.append(true))
	errors.capture_error("NewError", "second attempt")

	await FractalTestHelpersClass.wait_for(get_tree(), func(): return not sent.is_empty(), 5000)

	assert_int(server.requests.size()).is_equal(1)
	var json := JSON.new()
	json.parse(server.requests[0].body)
	var types: Array = []
	for e in json.data.errors:
		types.append(e.error_type)
	assert_bool(types.has("OldError")).is_true()
	assert_bool(types.has("NewError")).is_true()

	assert_array(FractalPersistenceClass.load_error_queue()).is_empty()


func test_abnormal_shutdown_inferred_from_unclean_session_marker() -> void:
	# Pre-seed a session marker that was never marked clean — exactly the
	# state left behind by SIGSEGV / kill -9 / OOM.
	var marker: FractalSessionMarker = FractalSessionMarkerClass.new()
	marker.start_new({
		"app_version": "9.9.9",
		"platform": "macos",
		"os": "macOS",
		"os_version": "14.0",
		"environment": "test",
	})
	marker.tick(
		[{"timestamp": "2026-04-30T00:00:00Z", "category": "ui", "message": "clicked play", "level": "info"}],
		{},
		{},
	)
	# Note: NO mark_clean() — simulates abnormal exit.

	server.enqueue_response("POST", "/v1/errors", 202, "{}")

	var config: FractalConfig = _make_config()
	config.errors_session_marker_enabled = true   # opt in for this test
	# Use a long heartbeat interval so the timer doesn't fire during the test.
	config.errors_heartbeat_interval_s = 60.0
	errors.configure(config)

	var sent: Array = []
	errors.error_sent.connect(func(): sent.append(true))
	var ok: bool = await FractalTestHelpersClass.wait_for(
		get_tree(), func(): return not sent.is_empty(), 5000,
	)
	assert_bool(ok).is_true()

	assert_int(server.requests.size()).is_equal(1)
	var json := JSON.new()
	json.parse(server.requests[0].body)
	var error: Dictionary = json.data.errors[0]
	assert_str(error.error_type).is_equal("AbnormalShutdown")
	assert_str(error.severity).is_equal("fatal")
	assert_bool(error.handled).is_false()
	# Breadcrumb from the dead session was preserved.
	assert_int(error.breadcrumbs.size()).is_equal(1)
	assert_str(error.breadcrumbs[0].message).is_equal("clicked play")
	# Cross-engine runtime discriminator is present.
	assert_str(error.runtime.name).is_equal("godot")


# ─── Live log tailing (non-fatal GDScript runtime error auto-capture) ────

func test_live_capture_first_poll_sends_script_error() -> void:
	var path: String = _write_log("live1.log", "SCRIPT ERROR: Invalid call.\n          at: do_thing (res://game.gd:42)\n")
	server.enqueue_response("POST", "/v1/errors", 202, "{}")

	errors.configure(_make_config())
	errors._live_capture_enabled = true
	errors._log_path = path
	errors._log_cursor = 0

	var sent: Array = []
	errors.error_sent.connect(func(): sent.append(true))
	errors._on_heartbeat()
	var ok: bool = await FractalTestHelpersClass.wait_for(get_tree(), func(): return not sent.is_empty(), 5000)
	assert_bool(ok).is_true()

	assert_int(server.requests.size()).is_equal(1)
	var json := JSON.new()
	json.parse(server.requests[0].body)
	var error: Dictionary = json.data.errors[0]
	assert_str(error.error_type).is_equal("ScriptError")
	assert_bool(error.handled).is_false()
	assert_str(error.tags.capture_method).is_equal("live_log")
	assert_int(int(error.get("occurrence_count", 1))).is_equal(1)


func test_live_capture_dedups_repeats_into_one_update_with_count() -> void:
	var path: String = _write_log("live2.log", "SCRIPT ERROR: Invalid call.\n          at: do_thing (res://game.gd:42)\n")
	server.enqueue_response("POST", "/v1/errors", 202, "{}")

	errors.configure(_make_config())
	errors._live_capture_enabled = true
	errors._log_path = path
	errors._log_cursor = 0

	var sent: Array = []
	errors.error_sent.connect(func(): sent.append(true))
	errors._on_heartbeat()
	await FractalTestHelpersClass.wait_for(get_tree(), func(): return not sent.is_empty(), 5000)
	assert_int(server.requests.size()).is_equal(1)

	# Append N identical occurrences before the next poll.
	var n := 5
	var block := ""
	for i in range(n):
		block += "SCRIPT ERROR: Invalid call.\n          at: do_thing (res://game.gd:42)\n"
	_append_log(path, block)

	sent.clear()
	server.enqueue_response("POST", "/v1/errors", 202, "{}")
	errors._on_heartbeat()
	var ok2: bool = await FractalTestHelpersClass.wait_for(get_tree(), func(): return not sent.is_empty(), 5000)
	assert_bool(ok2).is_true()

	# Exactly ONE update event for the second poll, not N events.
	assert_int(server.requests.size()).is_equal(2)
	var json := JSON.new()
	json.parse(server.requests[1].body)
	assert_int(json.data.errors.size()).is_equal(1)
	assert_int(int(json.data.errors[0].occurrence_count)).is_equal(n)


func test_live_capture_distinct_error_sent_as_own_event() -> void:
	var path: String = _write_log("live3.log", "SCRIPT ERROR: First.\n          at: a (res://a.gd:1)\nERROR: Second.\n          at: b (res://b.gd:2)\n")
	# Two distinct signatures means two capture_error() calls; the second
	# may land in its own POST if the first is still in flight when it's
	# queued (HTTP client's send_in_flight guard), so enqueue for both.
	server.enqueue_response("POST", "/v1/errors", 202, "{}")
	server.enqueue_response("POST", "/v1/errors", 202, "{}")

	errors.configure(_make_config())
	errors._live_capture_enabled = true
	errors._log_path = path
	errors._log_cursor = 0

	errors._on_heartbeat()
	var ok: bool = await FractalTestHelpersClass.wait_for(
		get_tree(), func(): return _total_messages_sent() >= 2, 5000,
	)
	assert_bool(ok).is_true()
	var messages: Array = _total_messages_sent_list()
	assert_bool(messages.has("SCRIPT ERROR: First.")).is_true()
	assert_bool(messages.has("ERROR: Second.")).is_true()


func _total_messages_sent_list() -> Array:
	var messages: Array = []
	for req in server.requests:
		var json := JSON.new()
		if json.parse(req.body) == OK:
			for e in json.data.get("errors", []):
				messages.append(e.message)
	return messages


func _total_messages_sent() -> int:
	return _total_messages_sent_list().size()


func test_live_capture_never_sends_sdk_self_log_lines() -> void:
	var path: String = _write_log("live4.log", "ERROR: Fractal: internal warning\n          at: z (res://z.gd:1)\n")
	errors.configure(_make_config())
	errors._live_capture_enabled = true
	errors._log_path = path
	errors._log_cursor = 0

	errors._on_heartbeat()
	for i in range(3):
		await get_tree().process_frame
	assert_int(server.requests.size()).is_equal(0)


func test_feature_gate_402_drops_queue_and_stops_retrying() -> void:
	server.enqueue_response("POST", "/v1/errors", 402, "{\"error\":\"This project's plan does not include error tracking\",\"code\":\"feature_not_available\",\"feature\":\"error_tracking\",\"dropped\":true}")

	errors.configure(_make_config())
	var failed: Array = []
	errors.error_failed.connect(func(_e): failed.append(true))
	errors.capture_error("GatedError", "should not be recorded")

	var ok: bool = await FractalTestHelpersClass.wait_for(get_tree(), func(): return not failed.is_empty(), 5000)
	assert_bool(ok).is_true()

	# Queue is dropped, not retained for retry.
	assert_array(FractalPersistenceClass.load_error_queue()).is_empty()
	assert_bool(errors._feature_gated).is_true()

	# A subsequent capture must not POST again — the gate is permanent for the session.
	errors.capture_error("SecondGatedError", "also should not be recorded")
	assert_int(server.requests.size()).is_equal(1)


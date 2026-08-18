extends GdUnitTestSuite

const FractalMockServerClass = preload("res://tests/integration/mock_server.gd")
const FractalConfigClass = preload("res://addons/fractal/core/config.gd")
const FractalAnalyticsClass = preload("res://addons/fractal/analytics/analytics.gd")
const FractalPersistenceClass = preload("res://addons/fractal/core/persistence.gd")

var server: Node
var analytics: Node


func before_test() -> void:
	# Clean persistence between tests.
	if DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		_remove_dir_recursive(FractalPersistenceClass.ROOT)

	server = FractalMockServerClass.new()
	add_child(server)
	server.start()

	analytics = FractalAnalyticsClass.new()
	add_child(analytics)
	# Wait one frame so analytics._ready() runs.
	await get_tree().process_frame


func after_test() -> void:
	if analytics:
		analytics.queue_free()
	if server:
		server.stop()
		server.queue_free()
	if DirAccess.dir_exists_absolute(FractalPersistenceClass.ROOT):
		_remove_dir_recursive(FractalPersistenceClass.ROOT)


func test_track_sends_batch_with_expected_payload() -> void:
	server.enqueue_response("POST", "/v1/batch", 202, "{}")

	var config: FractalConfig = FractalConfigClass.new()
	config.api_key = "test-key"
	config.collector_url = server.url()
	config.app_version = "9.9.9"
	config.environment = "test"
	config.analytics_batch_size = 3
	config.errors_enabled = false
	analytics.configure(config)

	analytics.track("level_complete", {"level": 5})
	analytics.track("level_complete", {"level": 6})
	analytics.track("level_complete", {"level": 7})

	# Wait for HTTP request to complete (real socket — give it generous time).
	# Use direct signal connection rather than gdUnit4's signal collector which
	# can race with synchronous emissions from connected callbacks.
	var sent_counts: Array = []
	analytics.batch_sent.connect(func(n): sent_counts.append(n))
	var elapsed := 0
	while sent_counts.is_empty() and elapsed < 10000:
		await get_tree().process_frame
		elapsed += 16
	assert_int(sent_counts.size()).is_equal(1)
	assert_int(sent_counts[0]).is_equal(3)

	assert_int(server.requests.size()).is_equal(1)
	var req: Dictionary = server.requests[0]
	assert_str(req.method).is_equal("POST")
	assert_str(req.path).is_equal("/v1/batch")
	assert_str(req.headers["x-api-key"]).is_equal("test-key")
	assert_str(req.headers["content-type"]).is_equal("application/json")

	var json := JSON.new()
	assert_int(json.parse(req.body)).is_equal(OK)
	var payload: Dictionary = json.data
	assert_array(payload.events).has_size(3)
	assert_str(payload.events[0].event_type).is_equal("level_complete")
	assert_str(payload.context.app_version).is_equal("9.9.9")
	assert_str(payload.context.environment).is_equal("test")
	assert_str(payload.context.player_id).starts_with("godot_")


func test_track_no_op_when_disabled() -> void:
	var config: FractalConfig = FractalConfigClass.new()
	config.api_key = "test-key"
	config.collector_url = server.url()
	config.analytics_enabled = false
	analytics.configure(config)

	analytics.track("should_not_send", {})
	# Give the system a few frames in case anything was queued.
	for i in range(3):
		await get_tree().process_frame

	assert_int(server.requests.size()).is_equal(0)
	assert_int(analytics.get_pending_event_count()).is_equal(0)


func test_permanent_4xx_drops_batch() -> void:
	# 400 — permanent client error, never retried. The batch must be dropped
	# (not persisted) so a poisoned payload can't loop forever on relaunch.
	server.enqueue_response("POST", "/v1/batch", 400, "bad request")

	var config: FractalConfig = FractalConfigClass.new()
	config.api_key = "test-key"
	config.collector_url = server.url()
	config.analytics_batch_size = 2
	config.errors_enabled = false
	analytics.configure(config)

	var failures: Array = []
	analytics.batch_failed.connect(func(err): failures.append(err))

	analytics.track("a")
	analytics.track("b")

	var elapsed := 0
	while failures.is_empty() and elapsed < 5000:
		await get_tree().process_frame
		elapsed += 16
	assert_int(failures.size()).is_equal(1)

	# The rejected batch must be dropped, not persisted for retry.
	assert_int(analytics.get_pending_event_count()).is_equal(0)
	assert_array(FractalPersistenceClass.load_events()).is_empty()


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

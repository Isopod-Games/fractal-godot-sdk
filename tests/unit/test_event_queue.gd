extends GdUnitTestSuite

const FractalEventQueueClass = preload("res://addons/fractal/analytics/event_queue.gd")

var queue: FractalEventQueue


func before_test() -> void:
	queue = FractalEventQueueClass.new()
	queue.configure({"batch_size": 3, "max_queue_size": 5, "flush_interval": 30.0})


func test_add_event_emits_batch_when_size_reached() -> void:
	var batches: Array = []
	queue.batch_ready.connect(func(events): batches.append(events))

	queue.add_event("a")
	queue.add_event("b")
	assert_int(batches.size()).is_equal(0)
	queue.add_event("c")
	assert_int(batches.size()).is_equal(1)
	assert_int(batches[0].size()).is_equal(3)


func test_event_structure() -> void:
	queue.add_event("level_complete", {"level": 5})
	var pending: Array = queue.get_pending_events()
	assert_int(pending.size()).is_equal(1)
	var event: Dictionary = pending[0]
	assert_str(event.event_type).is_equal("level_complete")
	assert_dict(event.payload).is_equal({"level": 5})
	# Timestamp is ISO 8601 with ms: "YYYY-MM-DDTHH:MM:SS.sssZ", 24 chars, ends with Z, parses back.
	assert_str(event.event_timestamp).has_length(24)
	assert_str(event.event_timestamp).ends_with("Z")
	var timestamp_regex := RegEx.new()
	timestamp_regex.compile("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$")
	assert_bool(timestamp_regex.search(event.event_timestamp) != null).is_true()
	assert_int(int(Time.get_unix_time_from_datetime_string(event.event_timestamp))).is_greater(0)
	assert_int(event.client_seq).is_equal(0)


func test_client_seq_increments_per_run() -> void:
	queue.add_event("a")
	queue.add_event("b")
	queue.add_event("c")
	var pending: Array = queue.get_pending_events()
	assert_int(pending[0].client_seq).is_equal(0)
	assert_int(pending[1].client_seq).is_equal(1)
	assert_int(pending[2].client_seq).is_equal(2)


func test_overflow_drops_oldest() -> void:
	# Use a queue where batch_size is large enough that batching doesn't drain the
	# queue, so we can observe the overflow behavior in isolation.
	var q: FractalEventQueue = FractalEventQueueClass.new()
	q.configure({"batch_size": 100, "max_queue_size": 5})
	# Use an Array to capture the count by reference (lambdas in GDScript don't
	# rebind primitive locals between calls).
	var dropped: Array[int] = [0]
	q.queue_overflow.connect(func(n): dropped[0] += n)
	for i in range(8):
		q.add_event("x_%d" % i, {})
	assert_int(q.get_event_count()).is_equal(5)
	assert_int(dropped[0]).is_equal(3)
	# The five remaining events are the most recent ones (3..7).
	var pending: Array = q.get_pending_events()
	assert_str(pending[0].event_type).is_equal("x_3")
	assert_str(pending[4].event_type).is_equal("x_7")


func test_clear_sent_events() -> void:
	for i in range(5):
		queue.add_event("e", {})
	queue.clear_sent_events(2)
	assert_int(queue.get_event_count()).is_equal(3)


func test_flush_emits_all_pending() -> void:
	var batches: Array = []
	queue.batch_ready.connect(func(events): batches.append(events))
	queue.add_event("a")
	queue.add_event("b")
	queue.flush()
	assert_int(batches.size()).is_equal(1)


func test_flush_empty_does_not_emit() -> void:
	var batches: Array = []
	queue.batch_ready.connect(func(events): batches.append(events))
	queue.flush()
	assert_int(batches.size()).is_equal(0)

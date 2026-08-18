extends GdUnitTestSuite
## Validates analytics.gd::_on_request_failed's poison-queue handling: a
## permanently-rejected 4xx batch (blocked key, malformed payload, etc.) must
## be moved to the dead-letter queue and cleared from the retry queue, while
## 5xx/network failures must keep the current retry-next-session behavior.
##
## Mirrors tests/unit/test_errors_dead_letter.gd. See issue #336/#337.

const FractalAnalyticsClass = preload("res://addons/fractal/analytics/analytics.gd")
const FractalPersistenceClass = preload("res://addons/fractal/core/persistence.gd")

var analytics: Node


func before_test() -> void:
	FractalPersistenceClass.clear_events()
	analytics = FractalAnalyticsClass.new()
	add_child(analytics)
	await get_tree().process_frame


func after_test() -> void:
	FractalPersistenceClass.clear_events()
	if FileAccess.file_exists(FractalPersistenceClass.EVENTS_DEAD_LETTER_PATH):
		DirAccess.remove_absolute(FractalPersistenceClass.EVENTS_DEAD_LETTER_PATH)
	if analytics:
		analytics.queue_free()


func test_400_moves_persisted_batch_to_dead_letter_and_clears_retry_queue() -> void:
	var batch: Array = [{"event_name": "level_complete", "properties": {"level": 5}}]
	analytics._pending_batch = batch
	FractalPersistenceClass.save_events(batch)

	await assert_error(func(): analytics._on_request_failed("HTTP 400: bad payload", 400)) \
		.is_push_error("Fractal.analytics: batch permanently rejected and moved to dead-letter queue: HTTP 400: bad payload")

	assert_array(FractalPersistenceClass.load_events()).is_empty()
	assert_array(FractalPersistenceClass.load_dead_letter_events()).contains(batch)


func test_500_retains_persisted_batch_for_retry() -> void:
	var batch: Array = [{"event_name": "level_complete", "properties": {"level": 6}}]
	analytics._pending_batch = batch
	FractalPersistenceClass.save_events(batch)

	await assert_error(func(): analytics._on_request_failed("Server error: 500", 500)).is_success()

	assert_array(FractalPersistenceClass.load_events()).contains(batch)
	assert_array(FractalPersistenceClass.load_dead_letter_events()).is_empty()

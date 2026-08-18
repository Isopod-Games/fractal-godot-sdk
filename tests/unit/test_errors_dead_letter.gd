extends GdUnitTestSuite
## Validates errors.gd::_on_request_failed's poison-queue handling: a
## permanently-rejected 4xx batch (bad payload, blocked key, etc.) must be
## moved to the dead-letter queue and cleared from the retry queue, while
## 5xx/network failures must keep the current retry-next-session behavior.

const FractalErrorsClass = preload("res://addons/fractal/errors/errors.gd")
const FractalPersistenceClass = preload("res://addons/fractal/core/persistence.gd")

var errors: Node


func before_test() -> void:
	FractalPersistenceClass.clear_error_queue()
	errors = FractalErrorsClass.new()
	add_child(errors)
	await get_tree().process_frame


func after_test() -> void:
	FractalPersistenceClass.clear_error_queue()
	if FileAccess.file_exists(FractalPersistenceClass.ERROR_DEAD_LETTER_PATH):
		DirAccess.remove_absolute(FractalPersistenceClass.ERROR_DEAD_LETTER_PATH)
	if errors:
		errors.queue_free()


func test_400_moves_persisted_batch_to_dead_letter_and_clears_retry_queue() -> void:
	var batch: Array = [{"error_type": "PoisonError", "message": "malformed payload"}]
	FractalPersistenceClass.save_error_queue(batch)

	await assert_error(func(): errors._on_request_failed("HTTP 400: bad payload", 400)) \
		.is_push_error("[Fractal] Error batch permanently rejected and moved to dead-letter queue: HTTP 400: bad payload")

	assert_array(FractalPersistenceClass.load_error_queue()).is_empty()
	assert_array(FractalPersistenceClass.load_dead_letter_error_queue()).contains(batch)


func test_500_retains_persisted_batch_for_retry() -> void:
	var batch: Array = [{"error_type": "TransientError", "message": "server hiccup"}]
	FractalPersistenceClass.save_error_queue(batch)

	await assert_error(func(): errors._on_request_failed("Server error: 500", 500)).is_success()

	assert_array(FractalPersistenceClass.load_error_queue()).contains(batch)
	assert_array(FractalPersistenceClass.load_dead_letter_error_queue()).is_empty()

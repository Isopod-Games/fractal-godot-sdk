class_name FractalHttpClient
extends Node
## Generic async HTTP client used by all Fractal subsystems.
##
## Each subsystem instantiates its own client so concurrent requests don't
## serialize through a shared HTTPRequest. The client supports POST/GET, custom
## headers, and exponential-backoff retry on 5xx/429 responses.

signal request_completed(status: int, response_headers: PackedStringArray, body: String)
signal request_failed(error: String, response_code: int)

const DEFAULT_TIMEOUT := 30.0
const MAX_RETRIES := 5
const INITIAL_RETRY_DELAY := 1.0
const MAX_RETRY_DELAY := 60.0

var _api_key: String = ""
var _debug: bool = false

var _http_request: HTTPRequest = null
var _retry_timer: Timer = null

# Pending request state
var _pending_url: String = ""
var _pending_method: int = HTTPClient.METHOD_GET
var _pending_headers: PackedStringArray = PackedStringArray()
var _pending_body: String = ""
var _pending_retry: bool = true
var _retry_count: int = 0


func _ready() -> void:
	_http_request = HTTPRequest.new()
	_http_request.timeout = DEFAULT_TIMEOUT
	_http_request.request_completed.connect(_on_request_completed)
	add_child(_http_request)

	_retry_timer = Timer.new()
	_retry_timer.one_shot = true
	_retry_timer.timeout.connect(_send)
	add_child(_retry_timer)


func configure(api_key: String, debug: bool = false) -> void:
	_api_key = api_key
	_debug = debug


## Sends an HTTP request. Headers are appended to a default set that includes
## `Content-Type: application/json` and `X-API-Key`. Pass `retry = false` for
## one-shot requests (e.g., translation sync) where you don't want backoff.
func request(method: int, url: String, extra_headers: PackedStringArray = PackedStringArray(), body: String = "", retry: bool = true) -> void:
	if _api_key.is_empty():
		request_failed.emit("API key not configured", 0)
		return
	# Cancel any in-flight retry from a previous request — without this, a
	# pending retry timer would later fire `_send()` with the new request's
	# payload, duplicating the new batch.
	if _retry_timer:
		_retry_timer.stop()
	_pending_url = url
	_pending_method = method
	_pending_headers = _build_headers(extra_headers)
	_pending_body = body
	_pending_retry = retry
	_retry_count = 0
	_send()


func is_busy() -> bool:
	return _http_request != null and _http_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED


## One-shot non-retrying request with a raw byte body. The caller supplies
## the full Content-Type header (we only inject X-API-Key). Used for
## multipart uploads (minidumps) where the body shape isn't JSON.
func request_raw_bytes(method: int, url: String, headers: PackedStringArray, body: PackedByteArray) -> int:
	_pending_retry = false
	_retry_count = 0
	var with_auth := PackedStringArray(["X-API-Key: " + _api_key])
	with_auth.append_array(headers)
	return _http_request.request_raw(url, with_auth, method, body)


func _build_headers(extra: PackedStringArray) -> PackedStringArray:
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"X-API-Key: " + _api_key,
	])
	headers.append_array(extra)
	return headers


func _send() -> void:
	if _debug:
		print("[Fractal] %s %s (attempt %d)" % [_method_name(_pending_method), _pending_url, _retry_count + 1])
	var err := _http_request.request(_pending_url, _pending_headers, _pending_method, _pending_body)
	if err != OK:
		_handle_error("Failed to send request: %s" % error_string(err), true)


func _on_request_completed(result: int, response_code: int, response_headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_handle_error("Request failed with result: %d" % result, _pending_retry)
		return

	# Treat 2xx and 304 (Not Modified) as success — the latter matters for translations sync.
	if (response_code >= 200 and response_code < 300) or response_code == 304:
		var body_text := body.get_string_from_utf8()
		if _debug:
			print("[Fractal] %d %s" % [response_code, _pending_url])
		_clear_pending()
		request_completed.emit(response_code, response_headers, body_text)
		return

	if response_code >= 500 or response_code == 429:
		_handle_error("Server error: %d" % response_code, _pending_retry)
		return

	# 4xx (other than 429) — don't retry, report failure with the body for debugging.
	var body_text := body.get_string_from_utf8()
	if _debug:
		print("[Fractal] %d %s: %s" % [response_code, _pending_url, body_text])
	_clear_pending()
	request_failed.emit("HTTP %d: %s" % [response_code, body_text], response_code)


func _handle_error(message: String, should_retry: bool) -> void:
	if _debug:
		print("[Fractal] error: %s" % message)
	if should_retry and _retry_count < MAX_RETRIES:
		_retry_count += 1
		var delay := _calculate_retry_delay()
		if _debug:
			print("[Fractal] retrying in %.1fs (%d/%d)" % [delay, _retry_count, MAX_RETRIES])
		_retry_timer.start(delay)
		return
	_clear_pending()
	request_failed.emit(message, 0)


func _calculate_retry_delay() -> float:
	var base := INITIAL_RETRY_DELAY * pow(2.0, _retry_count - 1)
	var jitter := randf_range(0.0, base * 0.1)
	return minf(base + jitter, MAX_RETRY_DELAY)


func _clear_pending() -> void:
	_pending_url = ""
	_pending_body = ""
	_pending_headers = PackedStringArray()
	_retry_count = 0


func _method_name(m: int) -> String:
	match m:
		HTTPClient.METHOD_GET: return "GET"
		HTTPClient.METHOD_POST: return "POST"
		HTTPClient.METHOD_PUT: return "PUT"
		HTTPClient.METHOD_DELETE: return "DELETE"
		_: return str(m)

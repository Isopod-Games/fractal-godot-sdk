class_name FractalMockServer
extends Node
## Minimal in-process HTTP/1.1 mock server for integration tests.
##
## Usage:
##     var server = FractalMockServer.new()
##     add_child(server)
##     server.start()
##     server.set_response("POST", "/v1/batch", 202, "")
##     # ... point Fractal SDK at server.url() ...
##     await server.received_request   # await one request
##     assert that server.requests has the expected payload
##
## Not a general-purpose server, only enough to satisfy this SDK's traffic.

signal received_request(request: Dictionary)

var _server: TCPServer
var _port: int = 0
var _peers: Array = []  # active StreamPeerTCPs being read
var _responses: Array = []  # ordered list of pre-canned responses
var _pending_disconnects: Array = []  # peers awaiting a delayed disconnect

# Each request captured: { method, path, query, headers, body }
var requests: Array = []


func _ready() -> void:
	set_process(false)


func start() -> void:
	_server = TCPServer.new()
	# Port 0 = OS picks a random free port.
	var err: int = _server.listen(0, "127.0.0.1")
	if err != OK:
		push_error("FractalMockServer: failed to listen: %s" % error_string(err))
		return
	_port = _server.get_local_port()
	set_process(true)


func stop() -> void:
	set_process(false)
	if _server:
		_server.stop()
		_server = null
	_peers.clear()


func url() -> String:
	return "http://127.0.0.1:%d" % _port


## Queue a response for the next matching request.
## response_headers is an optional Dictionary {header_name: value}.
func enqueue_response(method: String, path: String, status: int, body: String = "", response_headers: Dictionary = {}) -> void:
	_responses.append({
		"method": method.to_upper(),
		"path": path,
		"status": status,
		"body": body,
		"headers": response_headers,
	})


func _process(_delta: float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var peer: StreamPeerTCP = _server.take_connection()
		_peers.append({"peer": peer, "buffer": PackedByteArray()})

	for entry in _peers.duplicate():
		var peer: StreamPeerTCP = entry.peer
		peer.poll()
		var status: int = peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			var available: int = peer.get_available_bytes()
			if available > 0:
				var data: PackedByteArray = peer.get_data(available)[1]
				entry.buffer.append_array(data)
			var parsed: Dictionary = _try_parse_request(entry.buffer)
			if parsed.get("complete", false):
				_handle_request(peer, parsed.request)
				_peers.erase(entry)
		elif status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
			_peers.erase(entry)

	for entry in _pending_disconnects.duplicate():
		entry.peer.poll()
		entry.ticks -= 1
		if entry.ticks <= 0:
			entry.peer.disconnect_from_host()
			_pending_disconnects.erase(entry)


func _try_parse_request(buffer: PackedByteArray) -> Dictionary:
	var text: String = buffer.get_string_from_utf8()
	var header_end: int = text.find("\r\n\r\n")
	if header_end < 0:
		return {"complete": false}
	var head: String = text.substr(0, header_end)
	var body: String = text.substr(header_end + 4)

	var lines: PackedStringArray = head.split("\r\n")
	if lines.size() < 1:
		return {"complete": false}
	var request_line: PackedStringArray = lines[0].split(" ")
	if request_line.size() < 3:
		return {"complete": false}

	var method: String = request_line[0]
	var full_path: String = request_line[1]
	var query: String = ""
	var path: String = full_path
	var qmark: int = full_path.find("?")
	if qmark >= 0:
		path = full_path.substr(0, qmark)
		query = full_path.substr(qmark + 1)

	var headers: Dictionary = {}
	for i in range(1, lines.size()):
		var line: String = lines[i]
		var colon: int = line.find(":")
		if colon < 0:
			continue
		var key: String = line.substr(0, colon).strip_edges().to_lower()
		var value: String = line.substr(colon + 1).strip_edges()
		headers[key] = value

	# If Content-Length specified, ensure we have the full body.
	if headers.has("content-length"):
		var expected: int = int(headers["content-length"])
		if body.length() < expected:
			return {"complete": false}
		body = body.substr(0, expected)

	return {
		"complete": true,
		"request": {
			"method": method,
			"path": path,
			"query": query,
			"headers": headers,
			"body": body,
		}
	}


func _handle_request(peer: StreamPeerTCP, request: Dictionary) -> void:
	requests.append(request)

	# Find the next matching pre-canned response.
	var response: Dictionary = {"status": 404, "body": "no mock configured", "headers": {}}
	for i in range(_responses.size()):
		var r: Dictionary = _responses[i]
		if r.method == request.method and r.path == request.path:
			response = r
			_responses.remove_at(i)
			break

	var body: String = response.get("body", "")
	var headers: Dictionary = response.get("headers", {})
	var status: int = response.get("status", 200)
	var status_text: String = _status_text(status)

	var body_bytes: PackedByteArray = body.to_utf8_buffer()
	var response_text: String = "HTTP/1.1 %d %s\r\n" % [status, status_text]
	if not headers.has("Content-Type") and body_bytes.size() > 0:
		response_text += "Content-Type: application/json\r\n"
	response_text += "Content-Length: %d\r\n" % body_bytes.size()
	for h_name in headers.keys():
		response_text += "%s: %s\r\n" % [h_name, headers[h_name]]
	response_text += "Connection: close\r\n\r\n"

	var bytes: PackedByteArray = response_text.to_utf8_buffer()
	bytes.append_array(body_bytes)

	var sent: int = 0
	while sent < bytes.size():
		var slice: PackedByteArray = bytes.slice(sent, bytes.size())
		var result: Array = peer.put_partial_data(slice)
		var err_code: int = result[0]
		var n: int = result[1]
		if err_code != OK:
			push_warning("[MockServer] put_partial_data error: %s" % error_string(err_code))
			break
		if n == 0:
			peer.poll()
			break
		sent += n
	peer.poll()
	# Defer disconnect to a follow-up tick so Godot's HTTPRequest has a chance
	# to consume the response before the socket closes.
	_pending_disconnects.append({"peer": peer, "ticks": 60})
	received_request.emit(request)


static func _status_text(code: int) -> String:
	match code:
		200: return "OK"
		201: return "Created"
		202: return "Accepted"
		204: return "No Content"
		304: return "Not Modified"
		400: return "Bad Request"
		401: return "Unauthorized"
		402: return "Payment Required"
		404: return "Not Found"
		429: return "Too Many Requests"
		500: return "Internal Server Error"
		_: return "Unknown"

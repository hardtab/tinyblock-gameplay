extends Node

signal session_changed(authenticated: bool)

const SESSION_PATH := "user://backend_session.json"
const PENDING_DISCOVERY_PATH := "user://pending_discovery.json"
const REQUEST_TIMEOUT := 20.0
const REQUEST_ATTEMPTS := 3

var api_url := ""
var access_token := ""
var installation_id := ""


func _ready() -> void:
	api_url = str(ProjectSettings.get_setting("tinyblock/backend_api_url", "")).trim_suffix("/")
	_load_session()


func is_configured() -> bool:
	return not api_url.is_empty()


func ensure_session() -> Dictionary:
	if not is_configured():
		return {"ok": false, "error": "backend_not_configured"}
	if not access_token.is_empty():
		return {"ok": true, "access_token": access_token}
	if installation_id.is_empty():
		installation_id = "install_%s" % Crypto.new().generate_random_bytes(16).hex_encode()
	var response := await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/auth/guest",
		{"installation_id": installation_id, "device": {"platform": OS.get_name()}},
		false
	)
	if not response.get("ok", false):
		return response
	access_token = str(response.get("body", {}).get("access_token", ""))
	if access_token.is_empty():
		return {"ok": false, "error": "invalid_auth_response"}
	_save_session()
	session_changed.emit(true)
	return {"ok": true, "access_token": access_token}


func resolve_discovery(inputs: Array, context: Dictionary = {}, command_id: String = "", requested_output_kind: String = "block") -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	if command_id.is_empty():
		command_id = new_command_id()
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/discoveries/resolve",
		{
			"command_id": command_id,
			"station_id": "crafting_grid",
			"requested_output_kind": requested_output_kind if requested_output_kind in ["block", "plant", "creature", "item"] else "block",
			"inputs": inputs,
			"context": context,
		},
		true,
		["Idempotency-Key: %s" % command_id]
	)


func get_discovery_job(job_id: String) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(HTTPClient.METHOD_GET, "/v1/discovery-jobs/%s" % job_id.uri_encode(), {}, true)


func new_command_id() -> String:
	return "cmd_%s" % Crypto.new().generate_random_bytes(16).hex_encode()


func save_pending_discovery(record: Dictionary) -> bool:
	var file := FileAccess.open(PENDING_DISCOVERY_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(record))
	file.close()
	return true


func load_pending_discovery() -> Dictionary:
	if not FileAccess.file_exists(PENDING_DISCOVERY_PATH):
		return {}
	var file := FileAccess.open(PENDING_DISCOVERY_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		clear_pending_discovery()
		return {}
	return (parsed as Dictionary).duplicate(true)


func clear_pending_discovery() -> void:
	if FileAccess.file_exists(PENDING_DISCOVERY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PENDING_DISCOVERY_PATH))


func get_world_generation_region(world_seed: int, region_x: int, biomes: Array) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/world-generation/region",
		{"world_seed": world_seed, "region_x": region_x, "biomes": biomes},
		true
	)


func create_multiplayer_session(world_id: String, world_name: String, world_mode: String, access_mode: String, dedicated_server: bool = false, max_players: int = 0) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	var payload := {
		"world_id": world_id,
		"world_name": world_name,
		"world_mode": world_mode,
		"access_mode": access_mode,
		"protocol_version": MultiplayerClient.PROTOCOL_VERSION,
		"dedicated_server": dedicated_server,
	}
	if dedicated_server and max_players > 0:
		payload["max_players"] = max_players
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/multiplayer/sessions",
		payload,
		true
	)


func list_multiplayer_sessions(limit: int = 20) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_GET,
		"/v1/multiplayer/sessions?limit=%d" % clampi(limit, 1, 50),
		{},
		true
	)


func join_multiplayer_session(session_id: String = "", join_code: String = "") -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/multiplayer/sessions/join",
		{
			"session_id": session_id,
			"join_code": join_code,
			"protocol_version": MultiplayerClient.PROTOCOL_VERSION,
		},
		true
	)


func get_content_batch(content_ids: Array) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/content/batch",
		{"content_ids": content_ids},
		true
	)


func wait_for_discovery(job_id: String, poll_after_ms: int = 1500, max_wait_seconds: float = 125.0) -> Dictionary:
	var deadline_ms := Time.get_ticks_msec() + int(max_wait_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_ms:
		await get_tree().create_timer(maxf(0.5, float(poll_after_ms) / 1000.0)).timeout
		var response := await get_discovery_job(job_id)
		if not response.get("ok", false):
			return response
		var body: Dictionary = response.get("body", {})
		match str(body.get("status", "")):
			"completed", "failed":
				return response
		poll_after_ms = int(body.get("poll_after_ms", poll_after_ms))
	return {"ok": false, "error": "discovery_timeout"}


func _request_json(method: HTTPClient.Method, path: String, body: Dictionary, authorized: bool, extra_headers: Array[String] = []) -> Dictionary:
	var last: Dictionary = {"ok": false, "error": "request_failed"}
	for attempt in REQUEST_ATTEMPTS:
		last = await _request_json_once(method, path, body, authorized, extra_headers)
		var status_code := int(last.get("status_code", 0))
		var retryable := str(last.get("error", "")) == "transport_error" or status_code >= 500
		if last.get("ok", false) or not retryable or attempt == REQUEST_ATTEMPTS - 1:
			return last
		await get_tree().create_timer(0.4 * pow(2.0, attempt)).timeout
	return last


func _request_json_once(method: HTTPClient.Method, path: String, body: Dictionary, authorized: bool, extra_headers: Array[String] = []) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = REQUEST_TIMEOUT
	add_child(request)
	var headers := PackedStringArray(["Accept: application/json"])
	if method != HTTPClient.METHOD_GET:
		headers.append("Content-Type: application/json")
	if authorized:
		if access_token.is_empty():
			request.queue_free()
			return {"ok": false, "error": "not_authenticated"}
		headers.append("Authorization: Bearer %s" % access_token)
	for header in extra_headers:
		headers.append(header)
	var payload := "" if method == HTTPClient.METHOD_GET else JSON.stringify(body)
	var start_error := request.request(api_url + path, headers, method, payload)
	if start_error != OK:
		request.queue_free()
		return {"ok": false, "error": "request_start_failed", "code": start_error}
	var completed: Array = await request.request_completed
	request.queue_free()
	var transport_result := int(completed[0])
	var status_code := int(completed[1])
	var raw_body := (completed[3] as PackedByteArray).get_string_from_utf8()
	if transport_result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "transport_error", "code": transport_result}
	var parsed: Variant = {}
	if not raw_body.is_empty():
		parsed = JSON.parse_string(raw_body)
	if not parsed is Dictionary:
		parsed = {"raw": raw_body}
	if status_code == 401 and authorized:
		access_token = ""
		_save_session()
		session_changed.emit(false)
	return {
		"ok": status_code >= 200 and status_code < 300,
		"status_code": status_code,
		"body": parsed,
		"error": "http_%d" % status_code if status_code < 200 or status_code >= 300 else "",
	}


func _load_session() -> void:
	if not FileAccess.file_exists(SESSION_PATH):
		return
	var file := FileAccess.open(SESSION_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return
	installation_id = str(parsed.get("installation_id", ""))
	access_token = str(parsed.get("access_token", ""))


func _save_session() -> void:
	var file := FileAccess.open(SESSION_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"installation_id": installation_id,
		"access_token": access_token,
	}))

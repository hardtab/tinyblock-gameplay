extends Node

signal session_changed(authenticated: bool)

const SESSION_PATH := "user://backend_session.json"
const PENDING_DISCOVERY_PATH := "user://pending_discovery.json"
const REQUEST_TIMEOUT := 20.0
const REQUEST_ATTEMPTS := 3
const BACKEND_API_URL_ENV := "TINYBLOCK_BACKEND_API_URL"
const MANAGED_CONTROL_DIR_ENV := "TINYBLOCK_MANAGED_CONTROL_DIR"

var api_url := ""
var access_token := ""
var installation_id := ""
var _managed_runtime := false
var _configuration_error := ""
var _managed_auth_rejected := false


func _ready() -> void:
	_managed_runtime = _is_managed_dedicated_runtime()
	var override_url := OS.get_environment(BACKEND_API_URL_ENV).strip_edges()
	if _managed_runtime and override_url.is_empty():
		_fail_managed_configuration("managed_backend_api_url_missing")
		return
	if not override_url.is_empty():
		api_url = _normalize_api_base_url(override_url)
		if api_url.is_empty():
			if _managed_runtime:
				_fail_managed_configuration("managed_backend_api_url_invalid")
			else:
				_configuration_error = "backend_api_url_invalid"
			return
	else:
		var configured_url := str(ProjectSettings.get_setting("tinyblock/backend_api_url", "")).strip_edges()
		api_url = _normalize_api_base_url(configured_url)
		if api_url.is_empty():
			_configuration_error = "backend_not_configured" if configured_url.is_empty() else "backend_api_url_invalid"
			return
	if _managed_runtime:
		_load_managed_session()
	else:
		_load_session()


func _is_managed_dedicated_runtime() -> bool:
	if not OS.get_environment(MANAGED_CONTROL_DIR_ENV).strip_edges().is_empty():
		return true
	var arguments := OS.get_cmdline_args()
	arguments.append_array(OS.get_cmdline_user_args())
	var dedicated := OS.has_feature("dedicated_server") or arguments.has("--tinyblock-server")
	if not dedicated:
		return false
	for index in range(maxi(0, arguments.size() - 1)):
		if arguments[index] == "--world" and str(arguments[index + 1]).begins_with("world_managed_"):
			return true
	return false


func _normalize_api_base_url(raw_url: String) -> String:
	var candidate := raw_url.strip_edges()
	if candidate.is_empty() or candidate.contains("?") or candidate.contains("#") or candidate.contains("\\"):
		return ""
	for code in candidate.to_utf8_buffer():
		if code <= 32 or code >= 127:
			return ""
	var separator := candidate.find("://")
	if separator <= 0:
		return ""
	var scheme := candidate.substr(0, separator).to_lower()
	if scheme not in ["https", "http"]:
		return ""
	var remainder := candidate.substr(separator + 3)
	var path_offset := remainder.find("/")
	var authority := remainder if path_offset < 0 else remainder.substr(0, path_offset)
	var base_path := "" if path_offset < 0 else remainder.substr(path_offset)
	if authority.is_empty() or authority.contains("@") or authority.find(":") != authority.rfind(":"):
		return ""
	var host := authority
	var port_suffix := ""
	var port_offset := authority.rfind(":")
	if port_offset >= 0:
		host = authority.substr(0, port_offset)
		var port_text := authority.substr(port_offset + 1)
		if port_text.is_empty():
			return ""
		for code in port_text.to_utf8_buffer():
			if code < 48 or code > 57:
				return ""
		var port := int(port_text)
		if port < 1 or port > 65535:
			return ""
		port_suffix = ":%d" % port
	if not _is_valid_api_host(host):
		return ""
	if scheme == "http" and host.to_lower() not in ["localhost", "127.0.0.1"]:
		return ""
	for segment in base_path.split("/"):
		if segment in [".", ".."]:
			return ""
	if base_path == "/":
		base_path = ""
	elif base_path.ends_with("/"):
		base_path = base_path.trim_suffix("/")
	for code in base_path.to_utf8_buffer():
		if not (code >= 48 and code <= 57) and not (code >= 65 and code <= 90) and not (code >= 97 and code <= 122) and code not in [45, 46, 47, 95, 126]:
			return ""
	return "%s://%s%s%s" % [scheme, host.to_lower(), port_suffix, base_path]


func _is_valid_api_host(host: String) -> bool:
	if host.is_empty() or host.begins_with(".") or host.ends_with(".") or host.contains(".."):
		return false
	for label in host.split("."):
		if label.is_empty() or label.begins_with("-") or label.ends_with("-"):
			return false
		for code in label.to_utf8_buffer():
			if not (code >= 48 and code <= 57) and not (code >= 65 and code <= 90) and not (code >= 97 and code <= 122) and code != 45:
				return false
	return true


func _fail_managed_configuration(error_code: String) -> void:
	_configuration_error = error_code
	api_url = ""
	access_token = ""
	installation_id = ""


func _network_block_error() -> String:
	if not _configuration_error.is_empty():
		return _configuration_error
	if api_url.is_empty():
		return "backend_not_configured"
	if _managed_runtime:
		if _managed_auth_rejected:
			return "managed_runtime_auth_rejected"
		if access_token.is_empty() or installation_id.is_empty():
			return "managed_runtime_auth_missing"
	return ""


func is_configured() -> bool:
	return not api_url.is_empty()


func ensure_session() -> Dictionary:
	var blocked := _network_block_error()
	if not blocked.is_empty():
		return {"ok": false, "error": blocked}
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


func create_multiplayer_session(world_id: String, world_name: String, world_mode: String, access_mode: String, dedicated_server: bool = false, max_players: int = 0, protocol_version: int = MultiplayerClient.PROTOCOL_VERSION) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	var payload := {
		"world_id": world_id,
		"world_name": world_name,
		"world_mode": world_mode,
		"access_mode": access_mode,
		"protocol_version": protocol_version,
		"host_client_version": MultiplayerClient.client_version(),
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


func join_multiplayer_session(session_id: String = "", join_code: String = "", protocol_version: int = MultiplayerClient.PROTOCOL_VERSION) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/multiplayer/sessions/join",
		{
			"session_id": session_id,
			"join_code": join_code,
			"protocol_version": protocol_version,
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


func get_store_status() -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	var path := "/v1/store/status"
	if not installation_id.is_empty():
		# The server checks this ID against the authenticated owner and uses its
		# original creation timestamp to preserve earlier free cosmetics.
		path += "?installation_id=" + installation_id.uri_encode()
	return await _request_json(HTTPClient.METHOD_GET, path, {}, true)


func get_testflight_store_status(app_transaction_jws: String) -> Dictionary:
	if app_transaction_jws.strip_edges().is_empty():
		return {"ok": false, "error": "testflight_attestation_unavailable"}
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/store/status/testflight",
		{"app_transaction_jws": app_transaction_jws},
		true
	)


func verify_store_purchase(platform: String, product_id: String, store_payload: String, app_transaction_jws: String = "") -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	var normalized_platform := platform.strip_edges().to_lower()
	var payload := {"platform": normalized_platform, "product_id": product_id}
	if normalized_platform == "ios":
		payload["signed_transaction_jws"] = store_payload
	elif normalized_platform == "android":
		payload["purchase_token"] = store_payload
	else:
		return {"ok": false, "error": "unsupported_store_platform"}
	if not app_transaction_jws.strip_edges().is_empty():
		payload["app_transaction_jws"] = app_transaction_jws
	return await _request_json(HTTPClient.METHOD_POST, "/v1/store/purchases/verify", payload, true)


func reconcile_store_invalidation(platform: String, product_id: String, store_payload: String, kind: String, app_transaction_jws: String = "") -> Dictionary:
	var normalized_platform := platform.strip_edges().to_lower()
	if normalized_platform != "ios" or kind.strip_edges().to_lower() != "refund":
		return {"ok": false, "error": "unsupported_store_invalidation"}
	if product_id.strip_edges().is_empty() or store_payload.strip_edges().is_empty():
		return {"ok": false, "error": "invalid_store_invalidation"}
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	var payload := {
		"platform": normalized_platform,
		"product_id": product_id,
		"signed_transaction_jws": store_payload,
		"kind": "refund",
	}
	if not app_transaction_jws.strip_edges().is_empty():
		payload["app_transaction_jws"] = app_transaction_jws
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/store/purchases/reconcile",
		payload,
		true
	)


func restore_store_purchase(platform: String, product_id: String, store_payload: String, app_transaction_jws: String = "") -> Dictionary:
	var normalized_platform := platform.strip_edges().to_lower()
	var payload := {"platform": normalized_platform, "product_id": product_id}
	if normalized_platform == "ios":
		payload["signed_transaction_jws"] = store_payload
	elif normalized_platform == "android":
		payload["purchase_token"] = store_payload
	else:
		return {"ok": false, "error": "unsupported_store_platform"}
	if not app_transaction_jws.strip_edges().is_empty():
		payload["app_transaction_jws"] = app_transaction_jws
	var response: Dictionary = await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/auth/store-restore",
		payload,
		false
	)
	if not response.get("ok", false):
		return response
	var body: Dictionary = response.get("body", {}) if response.get("body", {}) is Dictionary else {}
	var restored_token := str(body.get("access_token", ""))
	if restored_token.is_empty():
		return {"ok": false, "error": "invalid_store_restore_response"}
	access_token = restored_token
	_save_session()
	session_changed.emit(true)
	return response


func create_store_capability_claim(session_id: String) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/store/capabilities/claim",
		{"session_id": session_id},
		true
	)


func validate_store_capability_claim(session_id: String, player_id: String, capability_token: String) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/store/capabilities/validate",
		{"session_id": session_id, "player_id": player_id, "capability_token": capability_token},
		true
	)


func managed_create_server(world_name: String, access_mode: String) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	var command_id := new_command_id()
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/managed-servers",
		{"world_name": world_name.strip_edges(), "access_mode": access_mode if access_mode in ["public", "invite_code"] else "public"},
		true,
		["Idempotency-Key: %s" % command_id]
	)


func managed_list_mine() -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(HTTPClient.METHOD_GET, "/v1/managed-servers/mine", {}, true)


func managed_list_public(limit: int = 20) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_GET,
		"/v1/managed-servers/public?limit=%d" % clampi(limit, 1, 50),
		{},
		true
	)


func managed_resolve_invite(invite_code: String) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/managed-servers/invites/resolve",
		{"invite_code": invite_code.strip_edges()},
		true
	)


func managed_get_status(world_id: String) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	return await _request_json(
		HTTPClient.METHOD_GET,
		"/v1/managed-servers/%s/status" % world_id.uri_encode(),
		{},
		true
	)


func managed_set_access(world_id: String, access_mode: String) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	if access_mode not in ["public", "invite_code"]:
		return {"ok": false, "error": "invalid_access_mode"}
	return await _request_json(
		HTTPClient.METHOD_PATCH,
		"/v1/managed-servers/%s/access" % world_id.uri_encode(),
		{"access_mode": access_mode},
		true
	)


func managed_join(world_id: String, invite_code: String = "") -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	var payload := {"protocol_version": MultiplayerClient.MANAGED_PROTOCOL_VERSION}
	if not invite_code.strip_edges().is_empty():
		payload["invite_code"] = invite_code.strip_edges()
	var command_id := new_command_id()
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/managed-servers/%s/join" % world_id.uri_encode(),
		payload,
		true,
		["Idempotency-Key: %s" % command_id]
	)


func managed_reset(world_id: String, world_name: String) -> Dictionary:
	var auth := await ensure_session()
	if not auth.get("ok", false):
		return auth
	var command_id := new_command_id()
	return await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/managed-servers/%s/reset" % world_id.uri_encode(),
		{"world_name": world_name.strip_edges()},
		true,
		["Idempotency-Key: %s" % command_id]
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
	var blocked := _network_block_error()
	if not blocked.is_empty():
		return {"ok": false, "error": blocked}
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
		if _managed_runtime:
			_managed_auth_rejected = true
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


func _load_managed_session() -> void:
	if not FileAccess.file_exists(SESSION_PATH):
		_fail_managed_configuration("managed_runtime_auth_missing")
		return
	var file := FileAccess.open(SESSION_PATH, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > 16384:
		_fail_managed_configuration("managed_runtime_auth_invalid")
		return
	var contents := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(contents)
	if not parsed is Dictionary:
		_fail_managed_configuration("managed_runtime_auth_invalid")
		return
	var session_url := _normalize_api_base_url(str(parsed.get("api_url", "")))
	if session_url.is_empty():
		_fail_managed_configuration("managed_runtime_auth_invalid")
		return
	if session_url != api_url:
		_fail_managed_configuration("managed_backend_api_url_mismatch")
		return
	var session_token := str(parsed.get("access_token", ""))
	var session_installation_id := str(parsed.get("installation_id", ""))
	if not _is_safe_runtime_value(session_token, 8192) or not _is_safe_runtime_value(session_installation_id, 128):
		_fail_managed_configuration("managed_runtime_auth_invalid")
		return
	access_token = session_token
	installation_id = session_installation_id


func _is_safe_runtime_value(value: String, maximum_length: int) -> bool:
	if value.is_empty() or value.length() > maximum_length:
		return false
	for code in value.to_utf8_buffer():
		if code <= 32 or code >= 127:
			return false
	return true


func _save_session() -> void:
	var file := FileAccess.open(SESSION_PATH, FileAccess.WRITE)
	if file == null:
		return
	var session := {
		"installation_id": installation_id,
		"access_token": access_token,
	}
	if _managed_runtime:
		session["api_url"] = api_url
	file.store_string(JSON.stringify(session))
	file.close()

class_name BotAiClient
extends Node

## OpenRouter Jev brain for low-stakes bot decisions (emoji replies, discover combos).
##
## Uses the TypeSafe Decisions API (`/api/alpha/decisions`) rather than free-form
## chat completions, matching the SuperCheap Jev transport. Every emoji still
## passes the in-game allowlist before the executor sends it.

signal emoji_reply_ready(emoji: String, context: Dictionary)
signal discover_combo_ready(combo_id: String, context: Dictionary)
signal request_failed(reason: String, context: Dictionary)

const EmojiReactions = preload("res://gameplay/scripts/emoji_reactions.gd")

const DEFAULT_BASE_URL := "https://openrouter.ai"
const DEFAULT_MODEL := "typesafe/jev-1.13"
const REQUEST_TIMEOUT_SEC := 12.0

var base_url := DEFAULT_BASE_URL
var api_key := ""
var model := DEFAULT_MODEL
var enabled := false
var _http: HTTPRequest
var _pending := false
var _pending_kind := ""
var _pending_context: Dictionary = {}


func _ready() -> void:
	_ensure_http()


func configure(options: Dictionary = {}) -> void:
	var raw_base := str(options.get("base_url", base_url)).strip_edges()
	base_url = raw_base.trim_suffix("/") if not raw_base.is_empty() else DEFAULT_BASE_URL
	api_key = str(options.get("api_key", api_key)).strip_edges()
	model = str(options.get("model", model)).strip_edges()
	if model.is_empty():
		model = DEFAULT_MODEL
	var want_enabled := bool(options.get("enabled", not api_key.is_empty()))
	enabled = want_enabled and not api_key.is_empty()
	_ensure_http()


func is_available() -> bool:
	return enabled and not api_key.is_empty()


func is_busy() -> bool:
	return _pending


func request_emoji_reply(context: Dictionary) -> bool:
	if not is_available() or _pending:
		return false
	var incoming := str(context.get("incoming_emoji", ""))
	var criteria := {}
	for emoji in EmojiReactions.DEFAULT_EMOJIS:
		criteria[emoji] = "Reply with %s" % emoji
	var body := {
		"model": model,
		"state": {
			"task": "tinyblock_emoji_reply",
			"incoming_emoji": incoming if not incoming.is_empty() else "greeting",
			"role": "friendly multiplayer guest in Tiny Block",
		},
		"questions": {
			"emoji": {
				"type": "choice",
				"criteria": criteria,
				"instructions": "Pick exactly one emoji reply that fits a friendly sandbox co-op guest.",
			},
		},
	}
	return _start_decision_request("emoji", body, context)


func request_discover_combo(context: Dictionary) -> bool:
	if not is_available() or _pending:
		return false
	var combos: Array = context.get("combos", []) if context.get("combos", []) is Array else []
	if combos.is_empty():
		return false
	var criteria := {}
	for raw_combo in combos:
		if not raw_combo is Dictionary:
			continue
		var combo := raw_combo as Dictionary
		var combo_id := str(combo.get("id", ""))
		if combo_id.is_empty():
			continue
		criteria[combo_id] = str(combo.get("label", combo_id))
	if criteria.is_empty():
		return false
	criteria["skip"] = "Do not invent a discovery right now"
	var body := {
		"model": model,
		"state": {
			"task": "tinyblock_discover_combo",
			"inventory": context.get("inventory_summary", {}),
			"role": "curious Tiny Block guest experimenting at the crafting grid",
		},
		"questions": {
			"combo": {
				"type": "choice",
				"criteria": criteria,
				"instructions": "Choose one safe crafting combination to try in Discover, or skip.",
			},
		},
	}
	return _start_decision_request("discover", body, context)


func _start_decision_request(kind: String, body: Dictionary, context: Dictionary) -> bool:
	_ensure_http()
	if _http == null:
		return false
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
		"Authorization: Bearer %s" % api_key,
	])
	_pending = true
	_pending_kind = kind
	_pending_context = context.duplicate(true)
	var err := _http.request(_decisions_url(), headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_pending = false
		_pending_kind = ""
		_pending_context.clear()
		request_failed.emit("request_start_failed", context.duplicate(true))
		return false
	return true


func _ensure_http() -> void:
	if _http != null:
		return
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT_SEC
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func _decisions_url() -> String:
	if base_url.ends_with("/api/alpha/decisions"):
		return base_url
	return "%s/api/alpha/decisions" % base_url


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var context := _pending_context.duplicate(true)
	var kind := _pending_kind
	_pending = false
	_pending_kind = ""
	_pending_context.clear()
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		request_failed.emit("http_%s_%d" % [str(result), response_code], context)
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Dictionary:
		request_failed.emit("invalid_json", context)
		return
	var answers: Dictionary = (parsed as Dictionary).get("answers", {}) if (parsed as Dictionary).get("answers", {}) is Dictionary else {}
	if kind == "emoji":
		var emoji_answer: Dictionary = answers.get("emoji", {}) if answers.get("emoji", {}) is Dictionary else {}
		var emoji := EmojiReactions.sanitize(str(emoji_answer.get("choice", "")))
		if emoji.is_empty():
			request_failed.emit("emoji_not_allowed", context)
			return
		emoji_reply_ready.emit(emoji, context)
		return
	if kind == "discover":
		var combo_answer: Dictionary = answers.get("combo", {}) if answers.get("combo", {}) is Dictionary else {}
		var combo_id := str(combo_answer.get("choice", ""))
		if combo_id.is_empty() or combo_id == "skip":
			request_failed.emit("discover_skipped", context)
			return
		discover_combo_ready.emit(combo_id, context)
		return
	request_failed.emit("unknown_kind", context)

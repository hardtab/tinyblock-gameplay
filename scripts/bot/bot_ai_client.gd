class_name BotAiClient
extends Node

## Optional OpenAI-compatible brain used for social emoji replies.
##
## The guest keeps rule-based gameplay. Only low-stakes emoji selection may call
## an external model, and every reply is still sanitized against the in-game
## emoji allowlist before it reaches the executor.

signal emoji_reply_ready(emoji: String, context: Dictionary)
signal request_failed(reason: String, context: Dictionary)

const EmojiReactions = preload("res://gameplay/scripts/emoji_reactions.gd")

const DEFAULT_MODEL := "gpt-4o-mini"
const REQUEST_TIMEOUT_SEC := 8.0

var base_url := ""
var api_key := ""
var model := DEFAULT_MODEL
var enabled := false
var _http: HTTPRequest
var _pending := false
var _pending_context: Dictionary = {}


func _ready() -> void:
	_ensure_http()


func configure(options: Dictionary = {}) -> void:
	base_url = str(options.get("base_url", base_url)).strip_edges().trim_suffix("/")
	api_key = str(options.get("api_key", api_key)).strip_edges()
	model = str(options.get("model", model)).strip_edges()
	if model.is_empty():
		model = DEFAULT_MODEL
	enabled = bool(options.get("enabled", not base_url.is_empty())) and not base_url.is_empty()
	_ensure_http()


func is_available() -> bool:
	return enabled and not base_url.is_empty()


func is_busy() -> bool:
	return _pending


func request_emoji_reply(context: Dictionary) -> bool:
	if not is_available() or _pending:
		return false
	_ensure_http()
	if _http == null:
		return false
	var incoming := str(context.get("incoming_emoji", ""))
	var allowlist := ",".join(EmojiReactions.DEFAULT_EMOJIS)
	var system_prompt := (
		"You are a friendly Tiny Block multiplayer guest. "
		+ "Reply with exactly one emoji from this allowlist and nothing else: "
		+ allowlist
	)
	var user_prompt := "A nearby player sent %s. Choose one fitting reply emoji." % (incoming if not incoming.is_empty() else "a greeting")
	var body := {
		"model": model,
		"temperature": 0.4,
		"max_tokens": 8,
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": user_prompt},
		],
	}
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
	])
	if not api_key.is_empty():
		headers.append("Authorization: Bearer %s" % api_key)
	_pending = true
	_pending_context = context.duplicate(true)
	var err := _http.request(_completions_url(), headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_pending = false
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


func _completions_url() -> String:
	if base_url.ends_with("/chat/completions"):
		return base_url
	return "%s/chat/completions" % base_url


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var context := _pending_context.duplicate(true)
	_pending = false
	_pending_context.clear()
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		request_failed.emit("http_%s_%d" % [str(result), response_code], context)
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Dictionary:
		request_failed.emit("invalid_json", context)
		return
	var choices: Array = (parsed as Dictionary).get("choices", []) if (parsed as Dictionary).get("choices", []) is Array else []
	var content := ""
	if not choices.is_empty() and choices[0] is Dictionary:
		var message: Dictionary = (choices[0] as Dictionary).get("message", {}) if (choices[0] as Dictionary).get("message", {}) is Dictionary else {}
		content = str(message.get("content", ""))
	var emoji := _extract_allowed_emoji(content)
	if emoji.is_empty():
		request_failed.emit("emoji_not_allowed", context)
		return
	emoji_reply_ready.emit(emoji, context)


func _extract_allowed_emoji(raw_text: String) -> String:
	var text := raw_text.strip_edges()
	var direct := EmojiReactions.sanitize(text)
	if not direct.is_empty():
		return direct
	for emoji in EmojiReactions.DEFAULT_EMOJIS:
		if text.find(emoji) >= 0:
			return emoji
	return ""

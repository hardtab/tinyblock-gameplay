class_name WorldStore
extends RefCounted

const SAVE_SCHEMA_VERSION := 1

var save_dir: String
var save_path: String
var backup_path: String
var temp_path: String
var remote_adapter: Object


func _init(custom_save_dir: String = "user://worlds", custom_remote_adapter: Object = null) -> void:
	save_dir = custom_save_dir
	remote_adapter = custom_remote_adapter
	# Legacy single-world paths are retained for one-time migration and compatibility.
	save_path = save_dir.path_join("current.json")
	backup_path = save_dir.path_join("current.json.bak")
	temp_path = save_dir.path_join("current.json.tmp")


func _valid_world_id(world_id: String) -> bool:
	if not world_id.begins_with("world_") or world_id.length() > 96:
		return false
	for character in world_id:
		if character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-":
			return false
	return true


func _world_path(world_id: String) -> String:
	return save_dir.path_join("%s.json" % world_id)


func _world_backup_path(world_id: String) -> String:
	return save_dir.path_join("%s.json.bak" % world_id)


func _world_temp_path(world_id: String) -> String:
	return save_dir.path_join("%s.json.tmp" % world_id)


func _world_repair_source_path(world_id: String) -> String:
	return save_dir.path_join("%s.json.repair-source.bak" % world_id)


func _ensure_save_dir() -> bool:
	return DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_dir)) == OK


func _migrate_legacy_world() -> void:
	if not FileAccess.file_exists(save_path):
		return
	var legacy := _load_file(save_path)
	if not legacy.get("ok", false):
		return
	var world_id := str((legacy.get("state", {}) as Dictionary).get("world_id", ""))
	if not _valid_world_id(world_id):
		return
	var destination := _world_path(world_id)
	if FileAccess.file_exists(destination):
		return
	if not _ensure_save_dir():
		return
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(save_path), ProjectSettings.globalize_path(destination)) != OK:
		return
	if FileAccess.file_exists(backup_path):
		DirAccess.rename_absolute(ProjectSettings.globalize_path(backup_path), ProjectSettings.globalize_path(_world_backup_path(world_id)))


func list_worlds() -> Array[Dictionary]:
	if _remote_available():
		return remote_adapter.call("data_list_worlds")
	_migrate_legacy_world()
	var worlds: Array[Dictionary] = []
	var directory := DirAccess.open(save_dir)
	if directory == null:
		return worlds
	for file_name in directory.get_files():
		if not file_name.ends_with(".json") or file_name == "current.json":
			continue
		var loaded := _load_file(save_dir.path_join(file_name))
		if not loaded.get("ok", false):
			continue
		var state := loaded.get("state", {}) as Dictionary
		var world_id := str(state.get("world_id", ""))
		if not _valid_world_id(world_id) or file_name != "%s.json" % world_id:
			continue
		var generation: Dictionary = state.get("generation", {}) if state.get("generation", {}) is Dictionary else {}
		var multiplayer: Dictionary = state.get("multiplayer", {}) if state.get("multiplayer", {}) is Dictionary else {}
		var mode := str(generation.get("mode", "skyblock"))
		var access_mode := str(multiplayer.get("access_mode", "offline"))
		if access_mode not in ["offline", "public", "invite_code"]:
			access_mode = "offline"
		var saved_block_count := (state.get("tiles", []) as Array).size() if state.get("tiles", []) is Array else 0
		if mode == "one_block" and state.get("one_block", {}) is Dictionary:
			saved_block_count = maxi(0, int((state.get("one_block", {}) as Dictionary).get("mined", 0)))
		elif mode == "challenge_run" and state.get("challenge", {}) is Dictionary:
			saved_block_count = maxi(0, int((state.get("challenge", {}) as Dictionary).get("best_distance", 0)))
		worlds.append({
			"world_id": world_id,
			"mode": mode,
			"access_mode": access_mode,
			"modified_unix": int(FileAccess.get_modified_time(save_dir.path_join(file_name))),
			"block_count": saved_block_count,
		})
	worlds.sort_custom(func(a: Dictionary, b: Dictionary): return int(a["modified_unix"]) > int(b["modified_unix"]))
	return worlds


func has_current_world() -> bool:
	return not list_worlds().is_empty()


func save_world(state: Dictionary) -> bool:
	if int(state.get("schema_version", -1)) != SAVE_SCHEMA_VERSION:
		return false
	var world_id := str(state.get("world_id", ""))
	if _remote_available():
		return bool(remote_adapter.call("data_save_world", state))
	if not _valid_world_id(world_id) or not _ensure_save_dir():
		return false
	var primary := _world_path(world_id)
	var backup := _world_backup_path(world_id)
	var temporary := _world_temp_path(world_id)
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(state))
	file.flush()
	file.close()
	if FileAccess.file_exists(primary):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(backup))
		if DirAccess.copy_absolute(ProjectSettings.globalize_path(primary), ProjectSettings.globalize_path(backup)) != OK:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
			return false
		if DirAccess.remove_absolute(ProjectSettings.globalize_path(primary)) != OK:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
			return false
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(primary)) != OK:
		return false
	return true


func save_current(state: Dictionary) -> bool:
	return save_world(state)


func save_repaired_world(state: Dictionary) -> bool:
	if int(state.get("schema_version", -1)) != SAVE_SCHEMA_VERSION:
		return false
	var world_id := str(state.get("world_id", ""))
	if _remote_available():
		return bool(remote_adapter.call("data_save_world", state))
	if not _valid_world_id(world_id) or not _ensure_save_dir():
		return false
	var primary := _world_path(world_id)
	var temporary := _world_temp_path(world_id)
	var repair_source := _world_repair_source_path(world_id)
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(state))
	file.flush()
	file.close()
	# Preserve the exact broken source separately and leave the known-good .bak
	# untouched. A normal save would rotate the broken primary over that backup.
	if FileAccess.file_exists(primary):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(repair_source))
		if DirAccess.copy_absolute(ProjectSettings.globalize_path(primary), ProjectSettings.globalize_path(repair_source)) != OK:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
			return false
		if DirAccess.remove_absolute(ProjectSettings.globalize_path(primary)) != OK:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
			return false
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(primary)) != OK:
		return false
	return true


func load_world(world_id: String) -> Dictionary:
	if not _valid_world_id(world_id):
		return {"ok": false, "error": "invalid_world_id"}
	if _remote_available():
		return remote_adapter.call("data_load_world", world_id) as Dictionary
	var primary := _load_file(_world_path(world_id))
	if primary.get("ok", false):
		primary["source"] = "primary"
		return primary
	var backup := _load_file(_world_backup_path(world_id))
	if backup.get("ok", false):
		backup["source"] = "backup"
		return backup
	return {"ok": false, "error": "No valid local world save was found."}


func load_world_backup(world_id: String) -> Dictionary:
	if not _valid_world_id(world_id):
		return {"ok": false, "error": "invalid_world_id"}
	if _remote_available():
		return {"ok": false, "error": "missing"}
	var backup := _load_file(_world_backup_path(world_id))
	if backup.get("ok", false):
		backup["source"] = "backup"
	return backup


func load_current() -> Dictionary:
	var worlds := list_worlds()
	if worlds.is_empty():
		return {"ok": false, "error": "No valid local world save was found."}
	return load_world(str(worlds[0]["world_id"]))


func load_backup() -> Dictionary:
	var worlds := list_worlds()
	if worlds.is_empty():
		return {"ok": false, "error": "missing"}
	return load_world_backup(str(worlds[0]["world_id"]))


func delete_world(world_id: String) -> bool:
	if not _valid_world_id(world_id):
		return false
	if _remote_available():
		return bool(remote_adapter.call("data_delete_world", world_id))
	var removed := false
	for path in [_world_path(world_id), _world_backup_path(world_id), _world_temp_path(world_id), _world_repair_source_path(world_id)]:
		if not FileAccess.file_exists(path):
			continue
		if DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) != OK:
			return false
		removed = true
	return removed


func _remote_available() -> bool:
	return remote_adapter != null and bool(remote_adapter.call("data_available"))


func _load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "missing"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "unreadable"}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return {"ok": false, "error": "invalid_json"}
	var parsed = parser.data
	if not parsed is Dictionary:
		return {"ok": false, "error": "invalid_json"}
	var state := parsed as Dictionary
	if int(state.get("schema_version", -1)) != SAVE_SCHEMA_VERSION or not _valid_world_id(str(state.get("world_id", ""))):
		return {"ok": false, "error": "invalid_schema"}
	return {"ok": true, "state": state}

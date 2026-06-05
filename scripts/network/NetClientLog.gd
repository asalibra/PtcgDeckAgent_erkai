class_name NetClientLog
extends RefCounted

const LOG_DIR := "user://logs"
const LOG_PATH := "user://logs/net_client_runtime.jsonl"


static func begin_session(context: String, fields: Dictionary = {}) -> void:
	log_event("session_start", fields.merged({"context": context}, true))


static func log_event(event_name: String, fields: Dictionary = {}) -> void:
	_ensure_log_dir()
	var entry := {
		"ts": Time.get_datetime_string_from_system(),
		"event": event_name,
	}
	for key_variant: Variant in fields.keys():
		entry[str(key_variant)] = _json_safe(fields[key_variant])
	_append_line(JSON.stringify(entry))


static func log_error(event_name: String, message: String, fields: Dictionary = {}) -> void:
	var merged := fields.duplicate(true)
	merged["message"] = message
	log_event(event_name, merged)


static func _ensure_log_dir() -> void:
	var absolute_dir := ProjectSettings.globalize_path(LOG_DIR)
	DirAccess.make_dir_recursive_absolute(absolute_dir)


static func _append_line(line: String) -> void:
	var file := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line(line)
	file.close()


static func _json_safe(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_ARRAY:
			var result: Array = []
			for item: Variant in value:
				result.append(_json_safe(item))
			return result
		TYPE_DICTIONARY:
			var result := {}
			for key_variant: Variant in value.keys():
				result[str(key_variant)] = _json_safe(value[key_variant])
			return result
		_:
			return str(value)
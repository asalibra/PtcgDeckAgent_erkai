class_name ReviewLLMConfig
extends RefCounted

## 复盘 LLM 独立配置管理。
## 与对战 LLM（GameManager 中的 ZenMux 配置）分开，可使用不同模型。

const CONFIG_PATH := "user://review_llm_config.json"

var endpoint: String = ""
var api_key: String = ""
var model: String = ""
var timeout_seconds: float = 60.0


func load_from_disk() -> bool:
	if not FileAccess.file_exists(CONFIG_PATH):
		return false
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return false
	var data: Dictionary = json.data if json.data is Dictionary else {}
	endpoint = str(data.get("endpoint", ""))
	api_key = str(data.get("api_key", ""))
	model = str(data.get("model", ""))
	timeout_seconds = float(data.get("timeout_seconds", 60.0))
	return true


func save_to_disk() -> void:
	var dir := CONFIG_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if f == null:
		return
	var data := {
		"endpoint": endpoint,
		"api_key": api_key,
		"model": model,
		"timeout_seconds": timeout_seconds,
	}
	f.store_string(JSON.stringify(data, "\t"))
	f.close()


func is_configured() -> bool:
	return endpoint != "" and api_key != "" and model != ""


func get_api_config() -> Dictionary:
	return {
		"endpoint": endpoint,
		"api_key": api_key,
		"model": model,
		"timeout_seconds": timeout_seconds,
	}

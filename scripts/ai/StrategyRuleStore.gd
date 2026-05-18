class_name StrategyRuleStore
extends RefCounted

## 策略规则存储与加载。
## 按卡组存通用规则，按卡组对存对局特定规则。
## 存储路径：user://strategy_rules/{deck_id}.json 和 user://strategy_rules/{deck_id}_vs_{opponent_id}.json

const RULES_DIR := "user://strategy_rules"


static func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(RULES_DIR):
		DirAccess.make_dir_recursive_absolute(RULES_DIR)


static func get_rules_path(deck_id: String, opponent_id: String = "") -> String:
	_ensure_dir()
	if opponent_id != "":
		return RULES_DIR.path_join("%s_vs_%s.json" % [deck_id, opponent_id])
	return RULES_DIR.path_join("%s.json" % deck_id)


static func load_rules(deck_id: String, opponent_id: String = "") -> Dictionary:
	var path := get_rules_path(deck_id, opponent_id)
	if not FileAccess.file_exists(path):
		return _empty_rules(deck_id)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _empty_rules(deck_id)
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return _empty_rules(deck_id)
	var data: Dictionary = json.data if json.data is Dictionary else {}
	if not data.has("rules"):
		data["rules"] = []
	if not data.has("matchup_rules"):
		data["matchup_rules"] = {}
	return data


static func save_rules(deck_id: String, rules: Dictionary, opponent_id: String = "") -> void:
	_ensure_dir()
	var path := get_rules_path(deck_id, opponent_id)
	rules["last_updated"] = _now_iso()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(rules, "\t"))
	f.close()


static func load_rules_text(deck_id: String, opponent_id: String = "") -> String:
	## 返回拼好的自然语言规则文本，供 prompt 注入
	var general := load_rules(deck_id)
	var lines: Array[String] = []

	# 通用规则
	var general_rules: Array = general.get("rules", [])
	if general_rules.size() > 0:
		lines.append("## 已学习的通用策略规则")
		for rule: Dictionary in general_rules:
			var conf: float = float(rule.get("confidence", 0.5))
			lines.append("- %s (confidence: %d%%)" % [str(rule.get("text", "")), int(conf * 100)])

	# 对局特定规则
	if opponent_id != "":
		var matchup := load_rules(deck_id, opponent_id)
		var matchup_rules: Array = matchup.get("rules", [])
		if matchup_rules.size() > 0:
			lines.append("")
			lines.append("## 面对 %s 的对局策略" % opponent_id)
			for rule: Dictionary in matchup_rules:
				var conf: float = float(rule.get("confidence", 0.5))
				lines.append("- %s (confidence: %d%%)" % [str(rule.get("text", "")), int(conf * 100)])

	# 也检查通用文件中的 matchup_rules
	var matchup_in_general: Dictionary = general.get("matchup_rules", {})
	if opponent_id != "" and matchup_in_general.has(opponent_id):
		var mu_rules: Array = matchup_in_general[opponent_id]
		if mu_rules.size() > 0 and lines.size() == 0:
			lines.append("## 面对 %s 的对局策略" % opponent_id)
		for rule: Dictionary in mu_rules:
			var conf: float = float(rule.get("confidence", 0.5))
			lines.append("- %s (confidence: %d%%)" % [str(rule.get("text", "")), int(conf * 100)])

	return "\n".join(lines)


static func merge_rules(existing: Dictionary, new_rules: Array) -> Dictionary:
	## 合并新规则到已有规则：同 ID 覆盖，新规则追加
	if not existing.has("rules"):
		existing["rules"] = []
	var existing_rules: Array = existing.get("rules", [])
	var rule_map: Dictionary = {}
	for rule: Dictionary in existing_rules:
		var rid: String = str(rule.get("id", ""))
		if rid != "":
			rule_map[rid] = rule
	for new_rule: Dictionary in new_rules:
		var rid: String = str(new_rule.get("id", ""))
		if rid == "":
			rid = "rule_%d" % (existing_rules.size() + 1)
			new_rule["id"] = rid
		new_rule["updated"] = _now_iso()
		if rule_map.has(rid):
			# 覆盖：保留更高的 source_matches
			var old: Dictionary = rule_map[rid]
			new_rule["source_matches"] = int(old.get("source_matches", 0)) + int(new_rule.get("source_matches", 1))
		else:
			new_rule["source_matches"] = int(new_rule.get("source_matches", 1))
			new_rule["created"] = _now_iso()
		rule_map[rid] = new_rule
	existing["rules"] = rule_map.values()
	existing["last_updated"] = _now_iso()
	return existing


static func merge_matchup_rules(existing: Dictionary, opponent_id: String, new_rules: Array) -> Dictionary:
	## 合并对局特定规则
	if not existing.has("matchup_rules"):
		existing["matchup_rules"] = {}
	var matchup: Dictionary = existing.get("matchup_rules", {})
	if not matchup.has(opponent_id):
		matchup[opponent_id] = []
	var merged := merge_rules({"rules": matchup[opponent_id]}, new_rules)
	matchup[opponent_id] = merged.get("rules", [])
	existing["matchup_rules"] = matchup
	existing["last_updated"] = _now_iso()
	return existing


static func _empty_rules(deck_id: String) -> Dictionary:
	return {
		"version": 1,
		"deck_id": deck_id,
		"last_updated": "",
		"rules": [],
		"matchup_rules": {},
	}


static func _now_iso() -> String:
	return Time.get_datetime_string_from_system(false, true)

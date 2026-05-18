class_name SelfPlayReviewPipeline
extends RefCounted

## 自博弈复盘管线。
## 串联：对局记录 → LLM 复盘 → 规则提取 → 规则存储。
## 支持单局模式和批量模式。

const BattleReviewServiceScript = preload("res://scripts/engine/BattleReviewService.gd")
const BattleReviewDataBuilderScript = preload("res://scripts/engine/BattleReviewDataBuilder.gd")
const BattleReviewPromptBuilderScript = preload("res://scripts/engine/BattleReviewPromptBuilder.gd")
const BattleReviewArtifactStoreScript = preload("res://scripts/engine/BattleReviewArtifactStore.gd")

signal pipeline_started()
signal match_reviewed(match_id: String, rules_count: int)
signal pipeline_finished(total_rules: int)
signal pipeline_error(message: String)

var _review_config: ReviewLLMConfig
var _extractor: StrategyRuleExtractor


func configure(review_config: ReviewLLMConfig) -> void:
	_review_config = review_config
	_extractor = StrategyRuleExtractor.new()
	_extractor.configure(review_config)


func is_ready() -> bool:
	return _review_config != null and _review_config.is_configured() and _extractor.is_ready()


func review_single_match(
	match_dir: String,
	deck_id: String,
	opponent_id: String,
	parent_node: Node,
	callback: Callable,
) -> void:
	## 单局模式：对局结束后立即复盘并提取规则
	if not is_ready():
		push_warning("[SelfPlayReviewPipeline] 复盘 LLM 未配置")
		pipeline_error.emit("复盘 LLM 未配置")
		callback.call(0)
		return

	pipeline_started.emit()

	# 1. 读取对局数据
	var data_builder := BattleReviewDataBuilderScript.new()
	var match_meta := _read_match_meta(match_dir)
	match_meta["player_0_archetype"] = deck_id
	match_meta["player_1_archetype"] = opponent_id

	# 2. 调用 BattleReviewService 做两阶段复盘
	var review_service := BattleReviewServiceScript.new()
	var api_config := _review_config.get_api_config()

	review_service.generate_review(parent_node, match_dir, api_config)

	# 等待复盘完成（通过信号）
	var _on_completed = func(review: Dictionary) -> void:
		# 3. 从复盘结果中提取策略规则
		_extractor.extract_from_review(review, match_meta, parent_node, func(rules: Array) -> void:
			# 4. 存储规则
			var rule_count := 0
			if rules.size() > 0:
				var existing := StrategyRuleStore.load_rules(deck_id)
				var merged := StrategyRuleStore.merge_rules(existing, rules)
				StrategyRuleStore.save_rules(deck_id, merged)
				rule_count = rules.size()

			# 如果有对局特定规则
			if opponent_id != "" and rules.size() > 0:
				var matchup_rules: Array[Dictionary] = []
				for rule: Dictionary in rules:
					if str(rule.get("category", "")) == "matchup":
						matchup_rules.append(rule)
				if matchup_rules.size() > 0:
					var existing_matchup := StrategyRuleStore.load_rules(deck_id, opponent_id)
					var merged_matchup := StrategyRuleStore.merge_rules(existing_matchup, matchup_rules)
					StrategyRuleStore.save_rules(deck_id, merged_matchup, opponent_id)

			match_reviewed.emit(match_dir.get_file(), rule_count)
			callback.call(rule_count)
		)

	var _on_review_completed = _on_completed
	review_service.review_completed.connect(_on_review_completed, CONNECT_ONE_SHOT)


func review_batch(
	match_dirs: Array[String],
	deck_id: String,
	opponent_id: String,
	parent_node: Node,
	callback: Callable,
) -> void:
	## 批量模式：逐局复盘，汇总规则
	if not is_ready():
		push_warning("[SelfPlayReviewPipeline] 复盘 LLM 未配置")
		pipeline_error.emit("复盘 LLM 未配置")
		callback.call(0)
		return

	if match_dirs.size() == 0:
		callback.call(0)
		return

	pipeline_started.emit()

	var all_rules: Array[Dictionary] = []
	var all_metas: Array[Dictionary] = []
	var review_results: Array[Dictionary] = []
	var pending: int = match_dirs.size()

	for match_dir in match_dirs:
		var meta := _read_match_meta(match_dir)
		meta["player_0_archetype"] = deck_id
		meta["player_1_archetype"] = opponent_id
		all_metas.append(meta)

		# 对每局做复盘
		var review_service := BattleReviewServiceScript.new()
		var api_config := _review_config.get_api_config()

		var captured_dir: String = match_dir
		var captured_meta: Dictionary = meta

		review_service.review_completed.connect(func(review: Dictionary) -> void:
			review_results.append(review)

			# 提取该局的规则
			_extractor.extract_from_review(review, captured_meta, parent_node, func(rules: Array) -> void:
				for rule: Dictionary in rules:
					all_rules.append(rule)
				pending -= 1
				match_reviewed.emit(captured_dir.get_file(), rules.size())

				if pending <= 0:
					# 所有局完成，去重并存储
					var deduped := _extractor._deduplicate_rules(all_rules)
					_store_rules(deck_id, opponent_id, deduped)
					pipeline_finished.emit(deduped.size())
					callback.call(deduped.size())
			)
		, CONNECT_ONE_SHOT)

		review_service.generate_review(parent_node, match_dir, api_config)


func _store_rules(deck_id: String, opponent_id: String, rules: Array[Dictionary]) -> void:
	## 将规则存储到对应的文件
	var general_rules: Array[Dictionary] = []
	var matchup_rules: Array[Dictionary] = []

	for rule: Dictionary in rules:
		if str(rule.get("category", "")) == "matchup" and opponent_id != "":
			matchup_rules.append(rule)
		else:
			general_rules.append(rule)

	# 存通用规则
	if general_rules.size() > 0:
		var existing := StrategyRuleStore.load_rules(deck_id)
		var merged := StrategyRuleStore.merge_rules(existing, general_rules)
		StrategyRuleStore.save_rules(deck_id, merged)

	# 存对局特定规则
	if matchup_rules.size() > 0 and opponent_id != "":
		var existing_matchup := StrategyRuleStore.load_rules(deck_id, opponent_id)
		var merged_matchup := StrategyRuleStore.merge_rules(existing_matchup, matchup_rules)
		StrategyRuleStore.save_rules(deck_id, merged_matchup, opponent_id)


func _read_match_meta(match_dir: String) -> Dictionary:
	## 读取对局元数据
	var match_json_path := match_dir.path_join("match.json")
	if not FileAccess.file_exists(match_json_path):
		return {}
	var f := FileAccess.open(match_json_path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	return json.data if json.data is Dictionary else {}

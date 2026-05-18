class_name StrategyRuleExtractor
extends RefCounted

## 从 LLM 复盘结果中提取可泛化的策略规则。
## 输入：BattleReviewService 的复盘结果 + 对局元数据
## 输出：结构化规则列表（自然语言文本 + 分类 + 置信度）

const ZenMuxClientScript = preload("res://scripts/network/ZenMuxClient.gd")

var _client: RefCounted = null
var _config: ReviewLLMConfig = null


func configure(config: ReviewLLMConfig) -> void:
	_config = config
	if config != null and config.is_configured():
		_client = ZenMuxClientScript.new()


func is_ready() -> bool:
	return _client != null and _config != null and _config.is_configured()


func extract_from_review(
	review_result: Dictionary,
	match_meta: Dictionary,
	parent_node: Node,
	callback: Callable,
) -> void:
	## 从单局复盘结果中提取策略规则
	if not is_ready():
		callback.call([])
		return

	var deck_id: String = str(match_meta.get("player_0_archetype", "unknown"))
	var opponent_id: String = str(match_meta.get("player_1_archetype", "unknown"))
	var winner_index: int = int(match_meta.get("winner_index", -1))
	var total_turns: int = int(match_meta.get("total_turns", 0))

	var payload := _build_extraction_payload(
		review_result, deck_id, opponent_id, winner_index, total_turns
	)
	var request := _build_request(payload)

	var err: int = _client.request_json(
		parent_node,
		_config.endpoint,
		_config.api_key,
		request,
		func(response: Dictionary) -> void:
			var rules := _parse_rules(response, deck_id, opponent_id)
			callback.call(rules)
	)
	if err != OK:
		callback.call([])


func extract_from_batch(
	review_results: Array[Dictionary],
	match_metas: Array[Dictionary],
	parent_node: Node,
	callback: Callable,
) -> void:
	## 从多局复盘结果中批量提取规则，然后做跨局总结
	if not is_ready() or review_results.size() == 0:
		callback.call([])
		return

	# 先逐局提取
	var all_rules: Array[Dictionary] = []
	var pending: int = review_results.size()

	for i in review_results.size():
		var review: Dictionary = review_results[i]
		var meta: Dictionary = match_metas[i] if i < match_metas.size() else {}
		extract_from_review(review, meta, parent_node, func(rules: Array) -> void:
			for rule: Dictionary in rules:
				all_rules.append(rule)
			pending -= 1
			if pending <= 0:
				# 所有局提取完毕，做跨局去重和总结
				var deduped := _deduplicate_rules(all_rules)
				callback.call(deduped)
		)


func _build_extraction_payload(
	review_result: Dictionary,
	deck_id: String,
	opponent_id: String,
	winner_index: int,
	total_turns: int,
) -> Dictionary:
	## 构建规则提取的 LLM 请求 payload
	var turn_reviews: Array = review_result.get("turn_reviews", [])
	var review_summary := ""
	for tr: Dictionary in turn_reviews:
		var judgment: String = str(tr.get("judgment", ""))
		var turn_goal: String = str(tr.get("turn_goal", ""))
		var best_line: String = str(tr.get("best_line", ""))
		var takeaway: String = str(tr.get("coach_takeaway", ""))
		var why_short: String = str(tr.get("why_current_line_falls_short", ""))
		var player_idx: int = int(tr.get("player_index", 0))
		var turn_num: int = int(tr.get("turn_number", 0))
		review_summary += "回合%d (玩家%d): 判定=%s\n目标: %s\n错误: %s\n最优路线: %s\n教练总结: %s\n\n" % [
			turn_num, player_idx, judgment, turn_goal, why_short, best_line, takeaway
		]

	return {
		"deck_id": deck_id,
		"opponent_id": opponent_id,
		"winner_index": winner_index,
		"total_turns": total_turns,
		"review_summary": review_summary,
	}


func _build_request(payload: Dictionary) -> Dictionary:
	var instructions := PackedStringArray()
	instructions.append("""你是一名世界级PTCG策略分析师。你的任务是从对局复盘中提取可泛化的策略规则。

## 要求
1. 只提取**可泛化**的规则，不要提取单局特殊情况（如"这局运气好抽到了X"）
2. 规则要**具体到可操作**（如"第1-3回合优先给雷公V贴能"而非"注意能量分配"）
3. 每条规则需要分类和置信度
4. 用中文输出规则文本
5. 置信度基于复盘分析的确定性：明确的最优路线=0.9+, 接近最优的判断=0.7-0.85, 不确定的=0.5-0.65

## 分类
- energy_routing: 能量贴附优先级
- tempo: 节奏控制（何时进攻、何时防守）
- setup: 开局和部署策略
- targeting: 目标选择（攻击目标、搜索目标）
- defense: 防守和撤退策略
- evolution: 进化时机
- resource: 资源管理（手牌、牌库、弃牌）
- matchup: 对局特定策略""")

	var request := {
		"model": _config.model,
		"instructions": instructions,
		"response_format": {
			"type": "json_schema",
			"json_schema": {
				"name": "strategy_rules",
				"strict": true,
				"schema": {
					"type": "object",
					"properties": {
						"rules": {
							"type": "array",
							"items": {
								"type": "object",
								"properties": {
									"text": {"type": "string"},
									"category": {"type": "string"},
									"confidence": {"type": "number"},
									"reasoning": {"type": "string"},
								},
								"required": ["text", "category", "confidence"],
							},
						},
					},
					"required": ["rules"],
				},
			},
		},
		"match": payload,
	}
	return request


func _parse_rules(response: Dictionary, deck_id: String, opponent_id: String) -> Array[Dictionary]:
	## 解析 LLM 返回的规则列表
	var content: String = ""
	if response.has("choices"):
		var choices: Array = response["choices"]
		if choices.size() > 0:
			content = str(choices[0].get("message", {}).get("content", ""))
	elif response.has("output_text"):
		content = str(response["output_text"])

	if content.strip_edges() == "":
		return []

	var json := JSON.new()
	# 尝试解析 JSON（容错处理）
	var clean := content.strip_edges()
	if clean.begins_with("```"):
		var lines := clean.split("\n")
		clean = ""
		var in_block := false
		for line in lines:
			if line.strip_edges().begins_with("```") and not in_block:
				in_block = true
				continue
			elif line.strip_edges().begins_with("```") and in_block:
				break
			elif in_block:
				clean += line + "\n"
		clean = clean.strip_edges()

	if json.parse(clean) != OK:
		return []

	var data: Dictionary = json.data if json.data is Dictionary else {}
	var raw_rules: Array = data.get("rules", [])
	var result: Array[Dictionary] = []

	for i in raw_rules.size():
		var raw: Dictionary = raw_rules[i] if raw_rules[i] is Dictionary else {}
		if raw.is_empty():
			continue
		var rule_id := "%s_%s_rule_%d" % [deck_id, opponent_id, i]
		result.append({
			"id": rule_id,
			"text": str(raw.get("text", "")),
			"category": str(raw.get("category", "general")),
			"confidence": float(raw.get("confidence", 0.5)),
			"reasoning": str(raw.get("reasoning", "")),
			"source_deck": deck_id,
			"source_opponent": opponent_id,
		})

	return result


func _deduplicate_rules(rules: Array[Dictionary]) -> Array[Dictionary]:
	## 跨局去重：相似规则合并，保留更高的置信度和更多的 source_matches
	var by_category: Dictionary = {}
	for rule: Dictionary in rules:
		var cat: String = str(rule.get("category", "general"))
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(rule)

	var result: Array[Dictionary] = []
	for cat_key in by_category:
		var cat_rules: Array = by_category[cat_key]
		# 简单去重：同类别下保留置信度最高的几条
		cat_rules.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.get("confidence", 0)) > float(b.get("confidence", 0))
		)
		# 每个类别最多保留 5 条规则
		var limit := mini(cat_rules.size(), 5)
		for i in limit:
			result.append(cat_rules[i])
	return result

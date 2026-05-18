## 自博弈复盘循环入口（headless）。
## 用法：
## godot --headless --path . res://scenes/tuner/SelfPlayEvolvementRunner.tscn -- \
##   --games=10 --deck-a=578647 --deck-b=578647 --loop=true --max-iterations=50
##
## 单次模式（默认）：跑 N 局自博弈 → 复盘 → 提取规则 → 结束
## 循环模式：自博弈 → 复盘 → 提取规则 → 重复，直到达到迭代上限
extends Control

const SelfPlayRunnerScript = preload("res://scripts/ai/SelfPlayRunner.gd")
const SelfPlayReviewPipelineScript = preload("res://scripts/ai/SelfPlayReviewPipeline.gd")
const ReviewLLMConfigScript = preload("res://scripts/ai/ReviewLLMConfig.gd")
const DeckStrategyGardevoirScript = preload("res://scripts/ai/DeckStrategyGardevoir.gd")
const DeckStrategyMiraidonScript = preload("res://scripts/ai/DeckStrategyMiraidon.gd")
const DeckStrategyArceusGiratinaScript = preload("res://scripts/ai/DeckStrategyArceusGiratina.gd")
const DeckStrategyDragapultDusknoirScript = preload("res://scripts/ai/DeckStrategyDragapultDusknoir.gd")
const DeckStrategyDragapultCharizardScript = preload("res://scripts/ai/DeckStrategyDragapultCharizard.gd")


func _ready() -> void:
	var options := _parse_args(OS.get_cmdline_user_args())
	var loop_mode: bool = options.get("loop", false)
	var max_iterations: int = int(options.get("max_iterations", 10))

	# 加载复盘 LLM 配置
	var review_config := ReviewLLMConfigScript.new()
	if not review_config.load_from_disk():
		print("[SelfPlayEvolvement] 错误：未找到复盘 LLM 配置文件 (user://review_llm_config.json)")
		print("[SelfPlayEvolvement] 请先创建配置文件，格式：{\"endpoint\":\"...\",\"api_key\":\"...\",\"model\":\"...\"}")
		if DisplayServer.get_name() == "headless":
			call_deferred("_quit_after_run")
		return

	if not review_config.is_configured():
		print("[SelfPlayEvolvement] 错误：复盘 LLM 配置不完整")
		if DisplayServer.get_name() == "headless":
			call_deferred("_quit_after_run")
		return

	print("===== SelfPlay Evolvement Runner =====")
	print("[SelfPlayEvolvement] mode=%s" % ("loop" if loop_mode else "single"))
	print("[SelfPlayEvolvement] review_model=%s" % review_config.model)

	if loop_mode:
		_run_loop(options, max_iterations, review_config)
	else:
		_run_single(options, review_config)


func _run_single(options: Dictionary, review_config: RefCounted) -> void:
	var games: int = int(options.get("games", 10))
	var deck_a: int = int(options.get("deck_a", 578647))
	var deck_b: int = int(options.get("deck_b", 578647))
	var max_steps: int = int(options.get("max_steps", 200))
	var encoder: String = str(options.get("encoder", "gardevoir"))

	print("[SelfPlayEvolvement] games=%d deck_a=%d deck_b=%d" % [games, deck_a, deck_b])

	# 1. 跑自博弈（带录制）
	var strategy := _create_strategy(encoder)
	var agent_config := {
		"heuristic_weights": {},
		"mcts_config": strategy.get_mcts_config(),
	}

	var deck_pairings: Array = [[deck_a, deck_b]]
	var seeds: Array = []
	for i in games:
		seeds.append(i + 2000)

	var runner := SelfPlayRunnerScript.new()
	print("[SelfPlayEvolvement] 开始自博弈...")
	var result: Dictionary = runner.run_batch(
		agent_config, agent_config,
		deck_pairings, seeds,
		max_steps,
		false, false, false, false, "",
		"", "", "",
		true  # record_matches
	)

	var match_dirs: Array = result.get("match_dirs", [])
	print("[SelfPlayEvolvement] 自博弈完成: %d 局, %d 个录制" % [int(result.get("total_matches", 0)), match_dirs.size()])

	if match_dirs.size() == 0:
		print("[SelfPlayEvolvement] 无对局录制，跳过复盘")
		if DisplayServer.get_name() == "headless":
			call_deferred("_quit_after_run")
		return

	# 2. 复盘并提取规则
	var pipeline := SelfPlayReviewPipelineScript.new()
	pipeline.configure(review_config)

	var deck_id := _encoder_to_deck_id(encoder)
	print("[SelfPlayEvolvement] 开始复盘 %d 局..." % match_dirs.size())

	var match_dirs_str: Array[String] = []
	for md in match_dirs:
		match_dirs_str.append(str(md))

	pipeline.review_batch(match_dirs_str, deck_id, "", self, func(total_rules: int) -> void:
		print("[SelfPlayEvolvement] 复盘完成，共提取 %d 条规则" % total_rules)
		_print_rules_summary(deck_id)
		if DisplayServer.get_name() == "headless":
			call_deferred("_quit_after_run")
	)


func _run_loop(options: Dictionary, max_iterations: int, review_config: RefCounted) -> void:
	var games_per_iter: int = int(options.get("games", 10))
	var deck_a: int = int(options.get("deck_a", 578647))
	var deck_b: int = int(options.get("deck_b", 578647))
	var max_steps: int = int(options.get("max_steps", 200))
	var encoder: String = str(options.get("encoder", "gardevoir"))

	print("[SelfPlayEvolvement] 循环模式: %d 轮, 每轮 %d 局" % [max_iterations, games_per_iter])

	var strategy := _create_strategy(encoder)
	var agent_config := {
		"heuristic_weights": {},
		"mcts_config": strategy.get_mcts_config(),
	}
	var deck_id := _encoder_to_deck_id(encoder)
	var deck_pairings: Array = [[deck_a, deck_b]]

	for iteration in max_iterations:
		print("\n===== 迭代 %d / %d =====" % [iteration + 1, max_iterations])

		# 生成种子
		var seeds: Array = []
		for i in games_per_iter:
			seeds.append(i + 3000 + iteration * 1000)

		# 1. 自博弈
		var runner := SelfPlayRunnerScript.new()
		var result: Dictionary = runner.run_batch(
			agent_config, agent_config,
			deck_pairings, seeds,
			max_steps,
			false, false, false, false, "",
			"", "", "",
			true  # record_matches
		)

		var match_dirs: Array = result.get("match_dirs", [])
		print("[SelfPlayEvolvement] 迭代 %d 自博弈: %d 局, %d 录制" % [iteration + 1, int(result.get("total_matches", 0)), match_dirs.size()])

		if match_dirs.size() == 0:
			print("[SelfPlayEvolvement] 无录制，跳过本轮复盘")
			continue

		# 2. 复盘
		var pipeline := SelfPlayReviewPipelineScript.new()
		pipeline.configure(review_config)

		var match_dirs_str: Array[String] = []
		for md in match_dirs:
			match_dirs_str.append(str(md))

		# 注意：headless 模式下回调是同步执行的
		var done := false
		pipeline.review_batch(match_dirs_str, deck_id, "", self, func(total_rules: int) -> void:
			print("[SelfPlayEvolvement] 迭代 %d 复盘完成，提取 %d 条规则" % [iteration + 1, total_rules])
			done = true
		)

		# 等待复盘完成（headless 模式下回调应该很快）
		while not done:
			await get_tree().process_frame

	_print_rules_summary(deck_id)
	print("\n===== 全部完成 =====")
	if DisplayServer.get_name() == "headless":
		call_deferred("_quit_after_run")


func _print_rules_summary(deck_id: String) -> void:
	var rules_text := StrategyRuleStore.load_rules_text(deck_id)
	if rules_text.strip_edges() == "":
		print("[SelfPlayEvolvement] 当前无学习到的规则")
		return
	print("[SelfPlayEvolvement] 当前学习到的规则:")
	print(rules_text)


func _create_strategy(encoder: String) -> RefCounted:
	match encoder:
		"miraidon":
			return DeckStrategyMiraidonScript.new()
		"arceus_giratina":
			return DeckStrategyArceusGiratinaScript.new()
		"dragapult_dusknoir":
			return DeckStrategyDragapultDusknoirScript.new()
		"dragapult_charizard":
			return DeckStrategyDragapultCharizardScript.new()
	return DeckStrategyGardevoirScript.new()


func _encoder_to_deck_id(encoder: String) -> String:
	match encoder:
		"miraidon":
			return "miraidon"
		"arceus_giratina":
			return "arceus_giratina"
		"dragapult_dusknoir":
			return "dragapult_dusknoir"
		"dragapult_charizard":
			return "dragapult_charizard"
	return "gardevoir"


func _quit_after_run() -> void:
	get_tree().quit(0)


func _parse_args(args: PackedStringArray) -> Dictionary:
	var parsed := {
		"games": 10,
		"deck_a": 578647,
		"deck_b": 578647,
		"max_steps": 200,
		"loop": false,
		"max_iterations": 10,
		"encoder": "gardevoir",
	}
	for arg: String in args:
		if arg.begins_with("--games="):
			parsed["games"] = int(arg.split("=")[1])
		elif arg.begins_with("--deck-a="):
			parsed["deck_a"] = int(arg.split("=")[1])
		elif arg.begins_with("--deck-b="):
			parsed["deck_b"] = int(arg.split("=")[1])
		elif arg.begins_with("--max-steps="):
			parsed["max_steps"] = int(arg.split("=")[1])
		elif arg == "--loop=true" or arg == "--loop":
			parsed["loop"] = true
		elif arg.begins_with("--max-iterations="):
			parsed["max_iterations"] = int(arg.split("=")[1])
		elif arg.begins_with("--encoder="):
			parsed["encoder"] = arg.split("=")[1]
	return parsed

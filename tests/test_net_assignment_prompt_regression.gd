class_name TestNetAssignmentPromptRegression
extends TestBase

const GameRoomScript = preload("res://scripts/server/GameRoom.gd")
const NetBattleSceneScript = preload("res://scenes/network/NetBattleScene.gd")
const NetworkClientScript = preload("res://scripts/network/NetworkClient.gd")
const ServerSerializerScript = preload("res://scripts/server/ServerSerializer.gd")
const BattleReplayStateRestorerScript = preload("res://scripts/engine/BattleReplayStateRestorer.gd")
const EffectTMTurboEnergizeScript = preload("res://scripts/effects/trainer_effects/EffectTMTurboEnergize.gd")
const EffectLookTopCardsScript = preload("res://scripts/effects/trainer_effects/EffectLookTopCards.gd")
const AttackDistributedBenchCountersScript = preload("res://scripts/effects/pokemon_effects/AttackDistributedBenchCounters.gd")


class SpyGrantedAttackGameStateMachine extends GameStateMachine:
	var use_granted_attack_calls: int = 0
	var last_targets: Array = []

	func use_granted_attack(
		_player_index: int,
		_attacker: PokemonSlot,
		_granted_attack: Dictionary,
		targets: Array = []
	) -> bool:
		use_granted_attack_calls += 1
		last_targets = targets.duplicate(true)
		return true


class SpyPromptBattleScene extends Control:
	var _pending_choice: String = ""
	var _gsm: GameStateMachine = null
	var shown_dialog_title: String = ""
	var shown_dialog_items: Array = []
	var shown_dialog_data: Dictionary = {}
	var shown_counter_distribution_step: Dictionary = {}
	var logged_messages: Array[String] = []

	func _show_dialog(title: String, items: Array, extra_data: Dictionary = {}) -> void:
		shown_dialog_title = title
		shown_dialog_items = items.duplicate(true)
		shown_dialog_data = extra_data.duplicate(true)

	func _show_field_counter_distribution(step: Dictionary) -> void:
		shown_counter_distribution_step = step.duplicate(true)

	func _log(message: String) -> void:
		logged_messages.append(message)


class SpyNetClient extends NetworkClientScript:
	var sent_choice_type: String = ""
	var sent_data: Dictionary = {}

	func send_choice_response(choice_type: String, data: Dictionary = {}) -> void:
		sent_choice_type = choice_type
		sent_data = data.duplicate(true)


func test_game_room_serializes_full_library_assignment_source_metadata() -> String:
	var fixture := _make_tm_turbo_fixture()
	fixture.energy_a.card_data.description = "A".repeat(4000)
	fixture.energy_a.card_data.image_local_path = "user://cards/images/LONG/PAYLOAD_A.png"
	fixture.energy_b.card_data.description = "B".repeat(4000)
	fixture.energy_b.card_data.image_local_path = "user://cards/images/LONG/PAYLOAD_B.png"
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	var serialized_steps: Array = room._serialize_interaction_steps(fixture.steps)
	var step: Dictionary = serialized_steps[0] if not serialized_steps.is_empty() else {}
	var source_items: Array = step.get("source_items", [])
	var first_serialized_source: Dictionary = source_items[0] if not source_items.is_empty() and source_items[0] is Dictionary else {}

	return run_checks([
		assert_true(step.has("source_items"), "网络交互步骤应保留 assignment 的 source_items"),
		assert_true(step.has("source_card_items"), "网络交互步骤应保留 full-library source_card_items"),
		assert_true(step.has("source_choice_labels"), "网络交互步骤应保留 full-library source_choice_labels"),
		assert_eq(int((step.get("source_items", []) as Array).size()), 2, "可选 source_items 应只包含 2 张基本能量"),
		assert_eq(int((step.get("source_card_items", []) as Array).size()), 3, "可见 source_card_items 应保留整个牌库视图"),
		assert_eq(int((step.get("target_items", []) as Array).size()), 2, "目标列表应保留全部备战宝可梦"),
		assert_false(first_serialized_source.has("description"), "网络卡牌快照不应携带长 description 字段"),
		assert_false(first_serialized_source.has("image_local_path"), "网络卡牌快照不应携带 image_local_path 字段"),
	])


func test_game_room_resolves_assignment_indices_against_source_items() -> String:
	var fixture := _make_tm_turbo_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	room._pending_granted_attack[0] = {
		"slot": fixture.player.active_pokemon,
		"granted_attack": {"name": "能量涡轮"},
		"steps": fixture.steps,
		"step_index": 0,
		"context": {},
	}

	room._resolve_granted_attack_interaction(0, {"selected_indices": [0, 1]})

	var context: Dictionary = fixture.gsm.last_targets[0] if not fixture.gsm.last_targets.is_empty() and fixture.gsm.last_targets[0] is Dictionary else {}
	var assignments: Array = context.get("tm_turbo_energize", [])
	var first_assignment: Dictionary = assignments[0] if not assignments.is_empty() else {}

	return run_checks([
		assert_eq(fixture.gsm.use_granted_attack_calls, 1, "完成 assignment 后服务器应执行一次 use_granted_attack"),
		assert_eq(assignments.size(), 1, "selected_indices 应解析为一条 assignment 记录"),
		assert_true(first_assignment.get("source") == fixture.energy_a, "assignment source 应映射回原始 source_items 中的能量卡"),
		assert_true(first_assignment.get("target") == fixture.player.bench[1], "assignment target 应映射回原始 target_items 中的备战宝可梦"),
	])


func test_net_battle_scene_restores_full_library_assignment_prompt() -> String:
	var fixture := _make_tm_turbo_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	var serialized_steps: Array = room._serialize_interaction_steps(fixture.steps)
	var battle_scene := SpyPromptBattleScene.new()
	battle_scene._gsm = fixture.gsm
	var scene: Node = NetBattleSceneScript.new()
	scene._battle_scene = battle_scene
	scene._net_my_player_index = 0

	scene._handle_trainer_interaction_prompt({
		"steps": serialized_steps,
		"step_index": 0,
		"card_name": "能量涡轮",
	})

	var dialog_data: Dictionary = battle_scene.shown_dialog_data
	var source_items: Array = dialog_data.get("source_items", [])
	var source_card_items: Array = dialog_data.get("source_card_items", [])
	var target_items: Array = dialog_data.get("target_items", [])
	var first_source_name := ""
	if not source_items.is_empty() and source_items[0] is CardInstance:
		first_source_name = (source_items[0] as CardInstance).card_data.name
	var first_visible_name := ""
	if not source_card_items.is_empty() and source_card_items[0] is CardInstance:
		first_visible_name = (source_card_items[0] as CardInstance).card_data.name

	return run_checks([
		assert_eq(str(battle_scene._pending_choice), "network_trainer_interaction", "网络赋值 prompt 应进入 network_trainer_interaction 状态"),
		assert_eq(str(dialog_data.get("ui_mode", "")), "card_assignment", "网络赋值 prompt 应恢复为 card_assignment UI"),
		assert_eq(source_items.size(), 2, "客户端应恢复 2 个可选 source_items"),
		assert_eq(source_card_items.size(), 3, "客户端应恢复整个牌库的 source_card_items"),
		assert_eq(target_items.size(), 2, "客户端应恢复全部备战目标"),
		assert_eq(first_source_name, "闪电能量A", "客户端恢复后的 source_items 应保留原卡名"),
		assert_eq(first_visible_name, "闪电能量A", "客户端恢复后的 visible source cards 应保留原卡名"),
	])


func test_net_battle_scene_restores_counter_distribution_prompt() -> String:
	var fixture := _make_counter_distribution_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	var serialized_steps: Array = room._serialize_interaction_steps(fixture.steps)
	var battle_scene := SpyPromptBattleScene.new()
	battle_scene._gsm = fixture.gsm
	var scene: Node = NetBattleSceneScript.new()
	scene._battle_scene = battle_scene
	scene._net_my_player_index = 0

	scene._handle_trainer_interaction_prompt({
		"steps": serialized_steps,
		"step_index": 0,
		"card_name": "幻影潜袭",
	})

	var step: Dictionary = battle_scene.shown_counter_distribution_step
	var target_items: Array = step.get("target_items", [])

	return run_checks([
		assert_eq(str(battle_scene._pending_choice), "network_trainer_interaction", "网络伤害指示物 prompt 应保持在 network_trainer_interaction 状态"),
		assert_eq(str(step.get("ui_mode", "")), "counter_distribution", "联机 Dragapult 类步骤应恢复为 counter_distribution UI"),
		assert_eq(int(step.get("total_counters", -1)), 8, "联机伤害指示物 prompt 应保留总分配数量，不能在客户端退化为 0"),
		assert_eq(target_items.size(), 2, "客户端应恢复全部可分配的目标宝可梦"),
		assert_true(target_items[0] == fixture.opponent.bench[0], "恢复后的 target_items 应映射回原始 PokemonSlot"),
	])


func test_game_room_rejects_end_turn_while_trainer_interaction_is_pending() -> String:
	var room := GameRoomScript.new()
	var gsm := GameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.phase = GameState.GamePhase.MAIN
	gsm.game_state.current_player_index = 0
	gsm.game_state.turn_number = 3
	for pi: int in 2:
		var player := PlayerState.new()
		player.player_index = pi
		var active_slot := PokemonSlot.new()
		active_slot.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("测试战斗宝可梦%d" % (pi + 1), "P", "SET", "30%d" % pi), pi))
		player.active_pokemon = active_slot
		gsm.game_state.players.append(player)
	var arven_cd := CardData.new()
	arven_cd.name = "派帕"
	arven_cd.card_type = "Supporter"
	arven_cd.effect_id = "5bdbc985f9aa2e6f248b53f6f35d1d37"
	var arven := CardInstance.create(arven_cd, 0)
	var item_card := CardInstance.create(_make_trainer_data("高级球", "SET", "400"), 0)
	item_card.card_data.card_type = "Item"
	var tool_card := CardInstance.create(_make_tool_data("勇气护符", "SET", "401"), 0)
	gsm.game_state.players[0].hand = [arven]
	gsm.game_state.players[0].deck = [item_card, tool_card]
	room._gsm = gsm
	room._state = NetProtocol.ROOM_STATE_PLAYING
	var sent_messages: Array[Dictionary] = []
	room.send_to_player.connect(func(player_index: int, message: Dictionary) -> void:
		sent_messages.append({
			"player_index": player_index,
			"message": message,
		})
	)

	room.handle_action(0, NetProtocol.ACTION_PLAY_TRAINER, {"instance_id": arven.instance_id})
	var current_player_before_end_turn := int(gsm.game_state.current_player_index)
	var hand_size_before_end_turn := gsm.game_state.players[0].hand.size()
	room.handle_action(0, NetProtocol.ACTION_END_TURN, {})
	var last_message: Dictionary = sent_messages[-1] if not sent_messages.is_empty() else {}
	var last_payload: Dictionary = last_message.get("message", {}).get("payload", {}) if last_message.get("message", {}) is Dictionary else {}

	return run_checks([
		assert_true(room._pending_trainer.has(0), "派帕首步 prompt 发出后服务器应保留 pending_trainer"),
		assert_eq(current_player_before_end_turn, 0, "开始交互时当前回合仍应属于玩家1"),
		assert_eq(int(gsm.game_state.current_player_index), 0, "训练家交互未完成前，结束回合不应推进到对手"),
		assert_eq(gsm.game_state.players[0].hand.size(), hand_size_before_end_turn, "训练家交互未完成前，错误的结束回合不应改变手牌区"),
		assert_eq(int(last_message.get("player_index", -1)), 0, "阻断中的错误应返回给发起结束回合的玩家"),
		assert_eq(str(last_payload.get("code", "")), "interaction_pending", "训练家交互未完成时应返回明确的 interaction_pending 错误"),
	])


func test_net_battle_scene_restores_visible_opponent_bench_slot_when_server_view_is_compressed() -> String:
	var fixture := _make_counter_distribution_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	var serialized_steps: Array = room._serialize_interaction_steps(fixture.steps)
	var compressed_state := BattleReplayStateRestorerScript.new().restore({
		"players": [
			{
				"player_index": 0,
				"hand": [],
				"deck": [],
				"prizes": [],
				"discard_pile": [],
				"lost_zone": [],
				"active": {},
				"bench": [],
			},
			{
				"player_index": 1,
				"hand": [],
				"deck": [],
				"prizes": [],
				"discard_pile": [],
				"lost_zone": [],
				"active": {},
				"bench": [
					{
						"pokemon_stack": [
							{
								"name": fixture.opponent.bench[1].get_pokemon_name(),
								"card_name": fixture.opponent.bench[1].get_pokemon_name(),
								"card_type": "Pokemon",
								"stage": "Basic",
								"instance_id": fixture.opponent.bench[1].get_top_card().instance_id,
								"owner_index": 1,
								"face_up": true,
							}
						],
						"attached_energy": [],
						"effects": [],
					}
				],
			},
		],
	})
	var battle_scene := SpyPromptBattleScene.new()
	var gsm := GameStateMachine.new()
	gsm.game_state = compressed_state
	battle_scene._gsm = gsm
	var scene: Node = NetBattleSceneScript.new()
	scene._battle_scene = battle_scene
	scene._net_my_player_index = 0

	scene._handle_trainer_interaction_prompt({
		"steps": serialized_steps,
		"step_index": 0,
		"card_name": "幻影潜袭",
	})

	var step: Dictionary = battle_scene.shown_counter_distribution_step
	var target_items: Array = step.get("target_items", [])
	var restored_slot: PokemonSlot = target_items[1] if target_items.size() > 1 and target_items[1] is PokemonSlot else null

	return run_checks([
		assert_eq(target_items.size(), 2, "压缩后的对手 bench 视图也应恢复出完整的可分配目标数"),
		assert_not_null(restored_slot, "原始 bench 索引失效时应按顶牌 instance_id 回捞目标槽位"),
		assert_eq(restored_slot.get_pokemon_name(), fixture.opponent.bench[1].get_pokemon_name(), "客户端应恢复到当前可见的铁荆棘ex槽位而不是丢失该目标"),
	])


func test_net_battle_scene_logs_and_skips_counter_distribution_when_targets_cannot_restore() -> String:
	var fixture := _make_counter_distribution_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	var serialized_steps: Array = room._serialize_interaction_steps(fixture.steps)
	var hidden_state := BattleReplayStateRestorerScript.new().restore({
		"players": [
			{
				"player_index": 0,
				"hand": [],
				"deck": [],
				"prizes": [],
				"discard_pile": [],
				"lost_zone": [],
				"active": {},
				"bench": [],
			},
			{
				"player_index": 1,
				"hand": [],
				"deck": [],
				"prizes": [],
				"discard_pile": [],
				"lost_zone": [],
				"active": {},
				"bench": [],
			},
		],
	})
	var battle_scene := SpyPromptBattleScene.new()
	var gsm := GameStateMachine.new()
	gsm.game_state = hidden_state
	battle_scene._gsm = gsm
	var scene: Node = NetBattleSceneScript.new()
	var net_client := SpyNetClient.new()
	scene._battle_scene = battle_scene
	scene._net_client = net_client
	scene._net_my_player_index = 0

	scene._handle_trainer_interaction_prompt({
		"steps": serialized_steps,
		"step_index": 0,
		"card_name": "幻影潜袭",
	})

	return run_checks([
		assert_eq(str(battle_scene._pending_choice), "", "恢复不出任何 counter_distribution 目标时不应进入 network_trainer_interaction"),
		assert_true(battle_scene.shown_counter_distribution_step.is_empty(), "恢复失败时不应继续显示空的 counter_distribution UI"),
		assert_false(battle_scene.logged_messages.is_empty(), "恢复失败时应写出明确日志"),
		assert_true(battle_scene.logged_messages.any(func(message: String) -> bool: return message.contains("联机交互恢复失败")), "恢复失败日志应标记为联机交互恢复失败"),
		assert_eq(net_client.sent_choice_type, NetProtocol.CHOICE_TRAINER_INTERACTION, "恢复失败时客户端应回服务器取消当前 trainer_interaction pending"),
		assert_true(bool(net_client.sent_data.get("cancelled", false)), "恢复失败时客户端应发送 cancelled=true 解开服务器 pending"),
	])


func test_server_state_preserves_tera_metadata_for_sparkling_crystal() -> String:
	var state := GameState.new()
	state.players = [PlayerState.new(), PlayerState.new()]
	state.players[0].player_index = 0
	state.players[1].player_index = 1
	var active_slot := PokemonSlot.new()
	var dragapult := CardInstance.create(_make_basic_pokemon_data("多龙巴鲁托ex", "N", "CSV8C", "159"), 0)
	dragapult.card_data.stage = "Stage 2"
	dragapult.card_data.mechanic = "ex"
	dragapult.card_data.label = "太晶"
	dragapult.card_data.ancient_trait = "Tera"
	dragapult.card_data.name_en = "Dragapult ex"
	dragapult.card_data.yoren_code = "Y1459"
	dragapult.card_data.regulation_mark = "H"
	dragapult.face_up = true
	active_slot.pokemon_stack.append(dragapult)
	var crystal := CardInstance.create(_make_tool_data("璀璨结晶", "CSV8C", "186"), 0)
	crystal.face_up = true
	active_slot.attached_tool = crystal
	state.players[0].active_pokemon = active_slot

	var serializer := ServerSerializerScript.new()
	var snapshot: Dictionary = serializer.build_view_for_player(state, 0)
	var restorer := BattleReplayStateRestorerScript.new()
	var restored: GameState = restorer.restore(snapshot)
	var restored_slot: PokemonSlot = restored.players[0].active_pokemon if restored != null and restored.players.size() > 0 else null
	var restored_top: CardInstance = restored_slot.get_top_card() if restored_slot != null else null
	var restored_tool: CardInstance = restored_slot.attached_tool if restored_slot != null else null

	return run_checks([
		assert_not_null(restored_top, "联机状态恢复后应保留战斗宝可梦"),
		assert_eq(str(restored_top.card_data.ancient_trait) if restored_top != null and restored_top.card_data != null else "", "Tera", "联机状态恢复后应保留 Tera 标记，供璀璨结晶判定减费"),
		assert_eq(str(restored_top.card_data.label) if restored_top != null and restored_top.card_data != null else "", "太晶", "联机状态恢复后应保留 label 等补充卡牌信息"),
		assert_eq(str(restored_top.card_data.name_en) if restored_top != null and restored_top.card_data != null else "", "Dragapult ex", "联机状态恢复后应保留英文名等扩展元数据"),
		assert_eq(str(restored_top.card_data.regulation_mark) if restored_top != null and restored_top.card_data != null else "", "H", "联机状态恢复后应保留赛制标记"),
		assert_eq(str(restored_top.card_data.yoren_code) if restored_top != null and restored_top.card_data != null else "", "Y1459", "联机状态恢复后应保留 yoren_code 等编号信息"),
		assert_eq(str(restored_tool.card_data.name) if restored_tool != null and restored_tool.card_data != null else "", "璀璨结晶", "联机状态恢复后应保留附加工具"),
	])


func test_net_battle_scene_restores_compact_card_prompt_metadata() -> String:
	var fixture := _make_tm_turbo_fixture()
	fixture.energy_a.card_data.label = "特殊提示"
	fixture.energy_a.card_data.name_en = "Lightning Energy A"
	fixture.energy_a.card_data.regulation_mark = "G"
	fixture.energy_a.card_data.yoren_code = "E001"
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	var serialized_steps: Array = room._serialize_interaction_steps(fixture.steps)
	var battle_scene := SpyPromptBattleScene.new()
	battle_scene._gsm = fixture.gsm
	var scene: Node = NetBattleSceneScript.new()
	scene._battle_scene = battle_scene
	scene._net_my_player_index = 0

	scene._handle_trainer_interaction_prompt({
		"steps": serialized_steps,
		"step_index": 0,
		"card_name": "能量涡轮",
	})

	var dialog_data: Dictionary = battle_scene.shown_dialog_data
	var source_items: Array = dialog_data.get("source_items", [])
	var first_source: CardInstance = source_items[0] if not source_items.is_empty() and source_items[0] is CardInstance else null

	return run_checks([
		assert_not_null(first_source, "联机交互卡牌恢复后应仍然是 CardInstance"),
		assert_eq(str(first_source.card_data.name) if first_source != null and first_source.card_data != null else "", "闪电能量A", "联机交互卡牌应恢复核心卡名信息"),
		assert_eq(str(first_source.card_data.card_type) if first_source != null and first_source.card_data != null else "", "Basic Energy", "联机交互卡牌应恢复核心卡牌类型信息"),
		assert_eq(str(first_source.card_data.label) if first_source != null and first_source.card_data != null else "", "特殊提示", "联机交互卡牌应恢复 label 等展示信息"),
		assert_eq(str(first_source.card_data.name_en) if first_source != null and first_source.card_data != null else "", "", "压缩后的联机 prompt 不应再依赖英文名等扩展元数据"),
		assert_eq(str(first_source.card_data.regulation_mark) if first_source != null and first_source.card_data != null else "", "", "压缩后的联机 prompt 不应再携带赛制标记"),
		assert_eq(str(first_source.card_data.yoren_code) if first_source != null and first_source.card_data != null else "", "", "压缩后的联机 prompt 不应再携带额外编号信息"),
	])


func test_server_view_keeps_face_up_opponent_bench_visible() -> String:
	var gsm := GameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.phase = GameState.GamePhase.MAIN
	gsm.game_state.turn_number = 2
	gsm.game_state.current_player_index = 1
	gsm.game_state.players = [PlayerState.new(), PlayerState.new()]
	gsm.game_state.players[0].player_index = 0
	gsm.game_state.players[1].player_index = 1
	var my_active := PokemonSlot.new()
	my_active.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("我方战斗宝可梦", "P", "TEST", "501"), 0))
	my_active.get_top_card().face_up = true
	gsm.game_state.players[0].active_pokemon = my_active
	var opp_active := PokemonSlot.new()
	opp_active.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("对方战斗宝可梦", "L", "TEST", "601"), 1))
	opp_active.get_top_card().face_up = true
	gsm.game_state.players[1].active_pokemon = opp_active
	var bench_card := CardInstance.create(_make_basic_pokemon_data("铁荆棘ex", "L", "CSV7C", "091"), 1)
	bench_card.card_data.mechanic = "ex"
	bench_card.face_up = true
	gsm.game_state.players[1].hand.append(bench_card)

	var played := gsm.play_basic_to_bench(1, bench_card, false)
	var serializer := ServerSerializerScript.new()
	var snapshot: Dictionary = serializer.build_view_for_player(gsm.game_state, 0)
	var players_data: Array = snapshot.get("players", [])
	var opponent_view: Dictionary = players_data[1] if players_data.size() > 1 and players_data[1] is Dictionary else {}
	var opponent_bench: Array = opponent_view.get("bench", [])

	return run_checks([
		assert_true(played, "对手主阶段打出备战宝可梦应成功"),
		assert_true(bench_card.face_up, "主阶段打出的对手备战宝可梦应保持正面朝上"),
		assert_eq(opponent_bench.size(), 1, "服务器快照应向我方暴露正面朝上的对手备战宝可梦"),
		assert_eq(str(((opponent_bench[0] as Dictionary).get("pokemon_name", "")) if not opponent_bench.is_empty() and opponent_bench[0] is Dictionary else ""), "铁荆棘ex", "对手备战区序列化应保留宝可梦名称和可见槽位"),
	])


func test_server_view_keeps_promoted_opponent_active_visible_after_send_out() -> String:
	var gsm := GameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.phase = GameState.GamePhase.MAIN
	gsm.game_state.turn_number = 3
	gsm.game_state.current_player_index = 1
	gsm.game_state.players = [PlayerState.new(), PlayerState.new()]
	gsm.game_state.players[0].player_index = 0
	gsm.game_state.players[1].player_index = 1
	var my_active := PokemonSlot.new()
	my_active.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("我方战斗宝可梦", "P", "TEST", "701"), 0))
	my_active.get_top_card().face_up = true
	gsm.game_state.players[0].active_pokemon = my_active
	var replacement := PokemonSlot.new()
	replacement.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("对方替补战斗宝可梦", "L", "TEST", "702"), 1))
	gsm.game_state.players[1].bench.append(replacement)

	var sent_out := gsm.send_out_pokemon(1, replacement)
	var serializer := ServerSerializerScript.new()
	var snapshot: Dictionary = serializer.build_view_for_player(gsm.game_state, 0)
	var players_data: Array = snapshot.get("players", [])
	var opponent_view: Dictionary = players_data[1] if players_data.size() > 1 and players_data[1] is Dictionary else {}
	var opponent_active: Dictionary = opponent_view.get("active", {})

	return run_checks([
		assert_true(sent_out, "对手在没有现任 active 时应能派出替补战斗宝可梦"),
		assert_true(replacement.get_top_card().face_up, "派出的替补战斗宝可梦应被翻到正面"),
		assert_eq(str(opponent_active.get("pokemon_name", "")), "对方替补战斗宝可梦", "服务器快照应继续暴露已派出的对手战斗宝可梦"),
	])


func test_server_view_keeps_opponent_initial_in_play_visible_after_setup() -> String:
	var gsm := GameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.phase = GameState.GamePhase.MAIN
	gsm.game_state.turn_number = 1
	gsm.game_state.current_player_index = 0
	gsm.game_state.players = [PlayerState.new(), PlayerState.new()]
	gsm.game_state.players[0].player_index = 0
	gsm.game_state.players[1].player_index = 1
	var my_active := PokemonSlot.new()
	my_active.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("我方战斗宝可梦", "P", "TEST", "801"), 0))
	my_active.get_top_card().face_up = true
	gsm.game_state.players[0].active_pokemon = my_active
	var opp_active := PokemonSlot.new()
	opp_active.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("对方初始战斗宝可梦A", "L", "TEST", "802"), 1))
	opp_active.get_top_card().face_up = false
	gsm.game_state.players[1].active_pokemon = opp_active
	var opp_bench := PokemonSlot.new()
	opp_bench.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("对方初始备战宝可梦B", "L", "TEST", "803"), 1))
	opp_bench.get_top_card().face_up = false
	gsm.game_state.players[1].bench = [opp_bench]

	var serializer := ServerSerializerScript.new()
	var snapshot: Dictionary = serializer.build_view_for_player(gsm.game_state, 0)
	var players_data: Array = snapshot.get("players", [])
	var opponent_view: Dictionary = players_data[1] if players_data.size() > 1 and players_data[1] is Dictionary else {}
	var opponent_active: Dictionary = opponent_view.get("active", {})
	var opponent_bench: Array = opponent_view.get("bench", [])

	return run_checks([
		assert_eq(str(opponent_active.get("pokemon_name", "")), "对方初始战斗宝可梦A", "准备阶段结束后，即便旧 face_up 标记未翻正，对手 active 也应继续可见"),
		assert_eq(opponent_bench.size(), 1, "准备阶段结束后，即便旧 face_up 标记未翻正，对手已公开的 bench 也不应被服务器快照隐藏"),
		assert_eq(str(((opponent_bench[0] as Dictionary).get("pokemon_name", "")) if not opponent_bench.is_empty() and opponent_bench[0] is Dictionary else ""), "对方初始备战宝可梦B", "服务器快照应保留对手初始 bench 名称"),
	])


func test_net_battle_scene_restores_top_card_reveal_prompt() -> String:
	var fixture := _make_look_top_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	var serialized_steps: Array = room._serialize_interaction_steps(fixture.steps)
	var battle_scene := SpyPromptBattleScene.new()
	battle_scene._gsm = fixture.gsm
	var scene: Node = NetBattleSceneScript.new()
	scene._battle_scene = battle_scene
	scene._net_my_player_index = 0

	scene._handle_trainer_interaction_prompt({
		"steps": serialized_steps,
		"step_index": 0,
		"card_name": "能量签",
	})

	var dialog_data: Dictionary = battle_scene.shown_dialog_data
	var card_items: Array = dialog_data.get("card_items", [])
	var card_indices: Array = dialog_data.get("card_indices", [])
	var choice_labels: Array = dialog_data.get("choice_labels", [])
	var first_name := ""
	var second_name := ""
	if not card_items.is_empty() and card_items[0] is CardInstance:
		first_name = (card_items[0] as CardInstance).card_data.name
	if card_items.size() > 1 and card_items[1] is CardInstance:
		second_name = (card_items[1] as CardInstance).card_data.name

	return run_checks([
		assert_eq(str(battle_scene._pending_choice), "network_trainer_interaction", "联机顶牌检索 prompt 应进入 network_trainer_interaction 状态"),
		assert_eq(card_items.size(), 2, "客户端应恢复整个已查看的顶部牌组视图"),
		assert_eq(first_name, "顶部能量", "客户端应显示已查看顶部的可选卡"),
		assert_eq(second_name, "顶部宝可梦", "客户端应显示已查看顶部的不可选卡"),
		assert_eq(card_indices, [0, -1], "联机顶牌检索应保留已查看牌与可选项的映射"),
		assert_eq(choice_labels.size(), 2, "联机顶牌检索应为每张已查看顶牌恢复提示标签"),
		assert_str_contains(str(choice_labels[1]), "不可选", "联机顶牌检索应把不符合条件的已查看卡标成不可选"),
	])


func test_game_room_builds_counter_distribution_results_from_target_amount_pairs() -> String:
	var fixture := _make_counter_distribution_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	var step: Dictionary = fixture.steps[0]
	var result_variant: Variant = room._build_step_selection_result(step, [1, 60, 0, 20])
	var result: Array = result_variant if result_variant is Array else []
	var first_entry: Dictionary = result[0] if not result.is_empty() and result[0] is Dictionary else {}
	var second_entry: Dictionary = result[1] if result.size() > 1 and result[1] is Dictionary else {}

	return run_checks([
		assert_eq(result.size(), 2, "counter_distribution 应按 target-index/amount 成对还原为 2 条分配记录"),
		assert_true(first_entry.get("target") == fixture.opponent.bench[1], "第一条分配应映射回对应的目标槽位"),
		assert_eq(int(first_entry.get("amount", 0)), 60, "第一条分配应保留伤害值"),
		assert_true(second_entry.get("target") == fixture.opponent.bench[0], "第二条分配应映射回另一目标槽位"),
		assert_eq(int(second_entry.get("amount", 0)), 20, "第二条分配应保留伤害值"),
	])


func test_net_scene_synthesizes_hidden_opponent_prizes_from_prize_count() -> String:
	var state := GameState.new()
	state.players = [PlayerState.new(), PlayerState.new()]
	state.players[0].player_index = 0
	state.players[1].player_index = 1
	var scene: Node = NetBattleSceneScript.new()
	scene._net_my_player_index = 0

	scene._synthesize_prize_counts({
		"players": [
			{"player_index": 0, "prize_count": 6},
			{"player_index": 1, "prize_count": 4},
		],
	}, state)

	return run_checks([
		assert_eq(state.players[1].prizes.size(), 4, "联机隐藏对手奖赏卡时应根据 prize_count 合成占位卡"),
		assert_eq(state.players[1].get_prize_layout().size(), 4, "合成的奖赏卡占位应同步更新 prize_layout"),
	])


func test_net_state_restores_prize_layout_holes_without_compacting() -> String:
	var game_state := GameState.new()
	game_state.players = [PlayerState.new(), PlayerState.new()]
	game_state.players[0].player_index = 0
	game_state.players[1].player_index = 1
	var own_a := CardInstance.create(_make_trainer_data("我的奖赏A", "SET", "301"), 0)
	var own_b := CardInstance.create(_make_trainer_data("我的奖赏B", "SET", "302"), 0)
	var own_c := CardInstance.create(_make_trainer_data("我的奖赏C", "SET", "303"), 0)
	var own_d := CardInstance.create(_make_trainer_data("我的奖赏D", "SET", "304"), 0)
	game_state.players[0].prizes = [own_a, own_b, own_c, own_d]
	game_state.players[0].prize_layout = [own_a, null, own_b, null, own_c, own_d]
	var opp_a := CardInstance.create(_make_trainer_data("对手奖赏A", "SET", "311"), 1)
	var opp_b := CardInstance.create(_make_trainer_data("对手奖赏B", "SET", "312"), 1)
	var opp_c := CardInstance.create(_make_trainer_data("对手奖赏C", "SET", "313"), 1)
	game_state.players[1].prizes = [opp_a, opp_b, opp_c]
	game_state.players[1].prize_layout = [null, opp_a, null, opp_b, opp_c, null]

	var serializer := ServerSerializerScript.new()
	var payload: Dictionary = serializer.build_view_for_player(game_state, 0)
	var restorer := BattleReplayStateRestorerScript.new()
	var restored: GameState = restorer.restore(payload)
	var scene: Node = NetBattleSceneScript.new()
	scene._net_my_player_index = 0
	scene._synthesize_prize_counts(payload, restored)
	var own_layout: Array = restored.players[0].get_prize_layout()
	var opp_layout: Array = restored.players[1].get_prize_layout()

	return run_checks([
		assert_eq(own_layout.size(), 6, "己方奖赏布局应保留完整 6 格布局"),
		assert_true(own_layout[0] is CardInstance and own_layout[1] == null and own_layout[2] is CardInstance and own_layout[3] == null, "己方奖赏布局中的空洞不应在联机恢复时被压缩"),
		assert_eq(restored.players[0].prizes.size(), 4, "己方真实奖赏卡数量应保持不变"),
		assert_eq(opp_layout.size(), 6, "对手隐藏奖赏布局也应保留完整 6 格布局"),
		assert_true(opp_layout[0] == null and opp_layout[1] is CardInstance and opp_layout[2] == null and opp_layout[3] is CardInstance and opp_layout[4] is CardInstance and opp_layout[5] == null, "对手已被拿走的奖赏格子位置应继续可见"),
		assert_eq(restored.players[1].prizes.size(), 0, "对手隐藏奖赏仍不应泄露到 prizes 列表"),
	])


func _make_tm_turbo_fixture() -> Dictionary:
	var gsm := SpyGrantedAttackGameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.phase = GameState.GamePhase.MAIN
	gsm.game_state.current_player_index = 0
	var player := PlayerState.new()
	player.player_index = 0
	var opponent := PlayerState.new()
	opponent.player_index = 1

	var attacker_slot := PokemonSlot.new()
	var attacker_card := CardInstance.create(_make_basic_pokemon_data("攻击宝可梦", "C", "SET", "001"), 0)
	attacker_slot.pokemon_stack.append(attacker_card)
	player.active_pokemon = attacker_slot

	for i in range(2):
		var bench_slot := PokemonSlot.new()
		bench_slot.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("备战宝可梦%d" % i, "L", "SET", "00%d" % (i + 2)), 0))
		player.bench.append(bench_slot)

	var opp_slot := PokemonSlot.new()
	opp_slot.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("对手战斗宝可梦", "P", "SET", "010"), 1))
	opponent.active_pokemon = opp_slot

	var energy_a := CardInstance.create(_make_energy_data("闪电能量A", "L", "ENERGY", "001"), 0)
	var energy_b := CardInstance.create(_make_energy_data("闪电能量B", "L", "ENERGY", "002"), 0)
	var trainer_card := CardInstance.create(_make_trainer_data("神奇糖果", "TRAINER", "099"), 0)
	player.deck.append(energy_a)
	player.deck.append(energy_b)
	player.deck.append(trainer_card)

	gsm.game_state.players = [player, opponent]
	var effect := EffectTMTurboEnergizeScript.new()
	var steps := effect.get_granted_attack_interaction_steps(attacker_slot, {"name": "能量涡轮"}, gsm.game_state)

	return {
		"gsm": gsm,
		"player": player,
		"energy_a": energy_a,
		"energy_b": energy_b,
		"steps": steps,
	}


func _make_counter_distribution_fixture() -> Dictionary:
	var gsm := SpyGrantedAttackGameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.phase = GameState.GamePhase.MAIN
	gsm.game_state.current_player_index = 0
	var player := PlayerState.new()
	player.player_index = 0
	var opponent := PlayerState.new()
	opponent.player_index = 1

	var attacker_slot := PokemonSlot.new()
	var attacker_card := CardInstance.create(_make_basic_pokemon_data("多龙巴鲁托ex", "P", "SET", "200"), 0)
	attacker_slot.pokemon_stack.append(attacker_card)
	player.active_pokemon = attacker_slot

	for i in range(2):
		var opp_bench := PokemonSlot.new()
		opp_bench.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("对手备战%d" % (i + 1), "P", "SET", "21%d" % i), 1))
		opponent.bench.append(opp_bench)

	gsm.game_state.players = [player, opponent]
	var effect := AttackDistributedBenchCountersScript.new(80)
	var attack := {"name": "幻影潜袭"}
	var steps := effect.get_attack_interaction_steps(attacker_card, attack, gsm.game_state)

	return {
		"gsm": gsm,
		"opponent": opponent,
		"steps": steps,
	}


func _make_look_top_fixture() -> Dictionary:
	var gsm := SpyGrantedAttackGameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.phase = GameState.GamePhase.MAIN
	gsm.game_state.current_player_index = 0
	var player := PlayerState.new()
	player.player_index = 0
	var opponent := PlayerState.new()
	opponent.player_index = 1
	player.deck.append(CardInstance.create(_make_energy_data("顶部能量", "L", "ENERGY", "101"), 0))
	player.deck.append(CardInstance.create(_make_basic_pokemon_data("顶部宝可梦", "P", "SET", "102"), 0))
	player.deck.append(CardInstance.create(_make_trainer_data("隐藏道具", "SET", "103"), 0))
	gsm.game_state.players = [player, opponent]
	var effect := EffectLookTopCardsScript.new(2, "Energy", 1)
	var card := CardInstance.create(_make_trainer_data("能量签", "SET", "100"), 0)
	var steps := effect.get_interaction_steps(card, gsm.game_state)

	return {
		"gsm": gsm,
		"steps": steps,
	}


func _make_basic_pokemon_data(name: String, energy_type: String, set_code: String, card_index: String) -> CardData:
	var card_data := CardData.new()
	card_data.name = name
	card_data.card_type = "Pokemon"
	card_data.energy_type = energy_type
	card_data.stage = "Basic"
	card_data.hp = 100
	card_data.set_code = set_code
	card_data.card_index = card_index
	card_data.ensure_image_metadata()
	return card_data


func _make_tool_data(name: String, set_code: String, card_index: String) -> CardData:
	var card_data := CardData.new()
	card_data.name = name
	card_data.card_type = "Tool"
	card_data.set_code = set_code
	card_data.card_index = card_index
	card_data.ensure_image_metadata()
	return card_data


func _make_energy_data(name: String, energy_type: String, set_code: String, card_index: String) -> CardData:
	var card_data := CardData.new()
	card_data.name = name
	card_data.card_type = "Basic Energy"
	card_data.energy_type = energy_type
	card_data.energy_provides = energy_type
	card_data.set_code = set_code
	card_data.card_index = card_index
	card_data.ensure_image_metadata()
	return card_data


func _make_trainer_data(name: String, set_code: String, card_index: String) -> CardData:
	var card_data := CardData.new()
	card_data.name = name
	card_data.card_type = "Item"
	card_data.set_code = set_code
	card_data.card_index = card_index
	card_data.ensure_image_metadata()
	return card_data
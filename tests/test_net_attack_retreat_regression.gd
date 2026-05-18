class_name TestNetAttackRetreatRegression
extends TestBase

const GameRoomScript = preload("res://scripts/server/GameRoom.gd")
const NetBattleSceneScript = preload("res://scenes/network/NetBattleScene.gd")
const NetBattleScenePatchScript = preload("res://scenes/network/NetBattleScenePatch.gd")
const BattleReplayStateRestorerScript = preload("res://scripts/engine/BattleReplayStateRestorer.gd")
const AttackDistributedBenchCountersScript = preload("res://scripts/effects/pokemon_effects/AttackDistributedBenchCounters.gd")
const AttackMoveEnergyToBenchScript = preload("res://scripts/effects/pokemon_effects/AttackMoveEnergyToBench.gd")


class SpyAttackGameStateMachine extends GameStateMachine:
	var use_attack_calls: int = 0
	var last_targets: Array = []

	func can_use_attack(_player_index: int, _attack_index: int) -> bool:
		return true

	func get_attack_unusable_reason(_player_index: int, _attack_index: int) -> String:
		return ""

	func get_post_damage_defender_interaction_steps(_attacker: PokemonSlot, _defender: PokemonSlot) -> Array[Dictionary]:
		return []

	func use_attack(_player_index: int, _attack_index: int, targets: Array = []) -> bool:
		use_attack_calls += 1
		last_targets = targets.duplicate(true)
		return true


class SpyNetHandler extends Control:
	var sent_actions: Array = []

	func send_action(action_type: String, params: Dictionary = {}) -> void:
		sent_actions.append({
			"action_type": action_type,
			"params": params.duplicate(true),
		})

	func get_my_player_index() -> int:
		return 0


class SpyRetreatGameStateMachine extends GameStateMachine:
	var retreat_calls: int = 0
	var last_energy_to_discard: Array[CardInstance] = []
	var last_bench_slot: PokemonSlot = null

	func retreat(_player_index: int, energy_to_discard: Array[CardInstance], bench_slot: PokemonSlot) -> bool:
		retreat_calls += 1
		last_energy_to_discard = energy_to_discard.duplicate()
		last_bench_slot = bench_slot
		return true


class SpyPromptBattleScene extends Control:
	var _pending_choice: String = ""
	var _gsm: GameStateMachine = null
	var shown_field_slot_title: String = ""
	var shown_field_slot_items: Array = []
	var shown_field_slot_step: Dictionary = {}
	var dialog_call_count: int = 0
	var logged_messages: Array[String] = []

	func _show_field_slot_choice(title: String, items: Array, step: Dictionary = {}) -> void:
		shown_field_slot_title = title
		shown_field_slot_items = items.duplicate(true)
		shown_field_slot_step = step.duplicate(true)

	func _show_dialog(_title: String, _items: Array, _extra_data: Dictionary = {}) -> void:
		dialog_call_count += 1

	func _log(message: String) -> void:
		logged_messages.append(message)


func test_game_room_routes_standard_attack_interactions_over_network() -> String:
	var fixture := _make_attack_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	room._state = NetProtocol.ROOM_STATE_PLAYING
	var sent_messages: Array = []
	room.send_to_player.connect(func(player_index: int, message: Dictionary):
		sent_messages.append({"player_index": player_index, "message": message})
	)

	room.handle_action(0, NetProtocol.ACTION_USE_ATTACK, {"attack_index": 0})
	var first_prompt: Dictionary = sent_messages[0].get("message", {}) if not sent_messages.is_empty() else {}
	var first_payload: Dictionary = first_prompt.get("payload", {}) if first_prompt.get("payload") is Dictionary else {}
	var first_data: Dictionary = first_payload.get("data", {}) if first_payload.get("data") is Dictionary else {}
	var had_pending_attack := room._pending_attack.has(0)

	room.handle_choice_response(0, NetProtocol.CHOICE_TRAINER_INTERACTION, {"selected_indices": [1]})
	var second_prompt: Dictionary = sent_messages[1].get("message", {}) if sent_messages.size() > 1 else {}
	var second_payload: Dictionary = second_prompt.get("payload", {}) if second_prompt.get("payload") is Dictionary else {}
	var second_data: Dictionary = second_payload.get("data", {}) if second_payload.get("data") is Dictionary else {}

	room.handle_choice_response(0, NetProtocol.CHOICE_TRAINER_INTERACTION, {"selected_indices": [0]})
	var resolved_context: Dictionary = fixture.gsm.last_targets[0] if not fixture.gsm.last_targets.is_empty() and fixture.gsm.last_targets[0] is Dictionary else {}
	var chosen_energy: Array = resolved_context.get("move_energy", [])
	var chosen_target: Array = resolved_context.get("move_target", [])

	return run_checks([
		assert_eq(str(first_prompt.get("type", "")), NetProtocol.MSG_CHOICE_PROMPT, "普通攻击有交互步骤时应先向客户端发送 choice_prompt"),
		assert_eq(str(first_payload.get("choice_type", "")), NetProtocol.CHOICE_TRAINER_INTERACTION, "普通攻击网络交互应复用 trainer_interaction choice type"),
		assert_eq(int(first_data.get("step_index", -1)), 0, "首个攻击交互 prompt 应从第 0 步开始"),
		assert_true(had_pending_attack, "服务器应记录待处理的普通攻击交互"),
		assert_eq(int(second_data.get("step_index", -1)), 1, "完成第 0 步后应继续发送第 1 步 prompt"),
		assert_eq(fixture.gsm.use_attack_calls, 1, "完成全部步骤后服务器应执行一次 use_attack"),
		assert_true(not room._pending_attack.has(0), "攻击交互完成后应清理 pending_attack"),
		assert_eq(chosen_energy.size(), 1, "上下文应保留所选中的能量卡"),
		assert_true(chosen_energy[0] == fixture.energy_b, "所选能量应映射回原始附加能量对象"),
		assert_eq(chosen_target.size(), 1, "上下文应保留所选中的备战目标"),
		assert_true(chosen_target[0] == fixture.player.bench[0], "所选目标应映射回原始备战宝可梦槽位"),
	])


func test_net_patch_retreat_bench_uses_field_selection_payload() -> String:
	var fixture := _make_attack_fixture()
	var net_handler := SpyNetHandler.new()
	var scene := NetBattleScenePatchScript.new()
	scene._net_mode = true
	scene._net_handler = net_handler
	scene._gsm = fixture.gsm
	scene._pending_choice = "retreat_bench"
	scene._dialog_data = {
		"bench": fixture.player.bench,
		"energy_discard": [fixture.energy_a, fixture.energy_b],
	}

	scene._handle_dialog_choice(PackedInt32Array([1]))
	var sent: Dictionary = net_handler.sent_actions[0] if not net_handler.sent_actions.is_empty() else {}
	var params: Dictionary = sent.get("params", {}) if sent.get("params") is Dictionary else {}
	var bench_slot: Dictionary = params.get("bench_slot", {}) if params.get("bench_slot") is Dictionary else {}
	var energy_ids: Array = params.get("energy_instance_ids", [])

	return run_checks([
		assert_eq(str(sent.get("action_type", "")), NetProtocol.ACTION_RETREAT, "免费撤退确认后应向服务器发送 retreat action"),
		assert_eq(int(bench_slot.get("player_index", -1)), 0, "撤退目标应指向己方玩家"),
		assert_eq(str(bench_slot.get("slot_kind", "")), "bench", "撤退目标应序列化为 bench slot ref"),
		assert_eq(int(bench_slot.get("slot_index", -1)), 1, "点击第二个备战位时应发送对应的 bench 索引"),
		assert_eq(energy_ids.size(), 2, "网络撤退应把待弃置能量的 instance_id 一并发给服务器"),
		assert_true(int(energy_ids[0]) == fixture.energy_a.instance_id and int(energy_ids[1]) == fixture.energy_b.instance_id, "energy_instance_ids 应来自 field 交互保存的能量对象"),
	])


func test_net_patch_retreat_bench_uses_cached_slot_refs_after_state_replacement() -> String:
	var fixture := _make_attack_fixture()
	var net_handler := SpyNetHandler.new()
	var scene := NetBattleScenePatchScript.new()
	scene._net_mode = true
	scene._net_handler = net_handler
	scene._gsm = fixture.gsm
	scene._pending_choice = "retreat_bench"
	var stale_bench_a := PokemonSlot.new()
	stale_bench_a.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("旧备战1", "L", "TEST", "701"), 0))
	var stale_bench_b := PokemonSlot.new()
	stale_bench_b.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("旧备战2", "L", "TEST", "702"), 0))
	scene._dialog_data = {
		"bench": [stale_bench_a, stale_bench_b],
		"bench_slot_refs": [
			NetProtocol.make_slot_ref(0, "bench", 0),
			NetProtocol.make_slot_ref(0, "bench", 1),
		],
		"energy_instance_ids": [fixture.energy_a.instance_id],
	}

	scene._handle_dialog_choice(PackedInt32Array([1]))
	var sent: Dictionary = net_handler.sent_actions[0] if not net_handler.sent_actions.is_empty() else {}
	var params: Dictionary = sent.get("params", {}) if sent.get("params") is Dictionary else {}
	var bench_slot: Dictionary = params.get("bench_slot", {}) if params.get("bench_slot") is Dictionary else {}

	return run_checks([
		assert_eq(str(sent.get("action_type", "")), NetProtocol.ACTION_RETREAT, "缓存 slot ref 的撤退确认后仍应向服务器发送 retreat action"),
		assert_eq(int(bench_slot.get("player_index", -1)), 0, "缓存的撤退目标应指向己方玩家"),
		assert_eq(str(bench_slot.get("slot_kind", "")), "bench", "缓存的撤退目标应保持 bench slot ref"),
		assert_eq(int(bench_slot.get("slot_index", -1)), 1, "即使旧 slot 对象失效也应保留被点击的 bench 索引"),
	])


func test_game_room_retreat_resolves_typed_energy_array() -> String:
	var fixture := _make_retreat_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	room._state = NetProtocol.ROOM_STATE_PLAYING

	room.handle_action(0, NetProtocol.ACTION_RETREAT, {
		"energy_instance_ids": [fixture.energy_a.instance_id, fixture.energy_b.instance_id],
		"bench_slot": NetProtocol.make_slot_ref(0, "bench", 1),
	})

	return run_checks([
		assert_eq(fixture.gsm.retreat_calls, 1, "服务器处理撤退 action 时应调用一次 retreat"),
		assert_eq(fixture.gsm.last_energy_to_discard.size(), 2, "服务器应把待弃置能量恢复为 typed Array[CardInstance]"),
		assert_true(fixture.gsm.last_energy_to_discard[0] == fixture.energy_a, "第一张待弃置能量应映射回原始附着能量对象"),
		assert_true(fixture.gsm.last_energy_to_discard[1] == fixture.energy_b, "第二张待弃置能量应映射回原始附着能量对象"),
		assert_true(fixture.gsm.last_bench_slot == fixture.player.bench[1], "撤退目标应映射回原始备战槽位"),
	])


func test_net_battle_scene_restores_pokemon_slot_prompt_as_field_selection() -> String:
	var fixture := _make_attack_fixture()
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
		"step_index": 1,
		"card_name": "伏特旋风",
	})

	return run_checks([
		assert_eq(str(battle_scene._pending_choice), "network_trainer_interaction", "联机 PokemonSlot 目标步骤应保持在 network_trainer_interaction 状态"),
		assert_eq(battle_scene.shown_field_slot_title, "选择要接收能量的备战宝可梦", "联机 PokemonSlot 目标步骤应恢复原始标题"),
		assert_eq(battle_scene.shown_field_slot_items.size(), 2, "联机 PokemonSlot 目标步骤应恢复全部备战目标"),
		assert_true(battle_scene.shown_field_slot_items[0] == fixture.player.bench[0], "第一个联机恢复目标应映射回原始备战槽位"),
		assert_true(battle_scene.shown_field_slot_items[1] == fixture.player.bench[1], "第二个联机恢复目标应映射回原始备战槽位"),
		assert_eq(battle_scene.dialog_call_count, 0, "联机 PokemonSlot 目标步骤不应退化为普通 dialog"),
		assert_true((battle_scene.shown_field_slot_step.get("items", []) as Array).size() == 2, "field slot UI 应拿到已恢复的 PokemonSlot items"),
	])


func test_net_battle_scene_logs_and_skips_field_slot_prompt_when_targets_cannot_restore() -> String:
	var fixture := _make_attack_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	var serialized_steps: Array = room._serialize_interaction_steps(fixture.steps)
	var hidden_state: GameState = BattleReplayStateRestorerScript.new().restore({
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
	scene._battle_scene = battle_scene
	scene._net_my_player_index = 0

	scene._handle_trainer_interaction_prompt({
		"steps": serialized_steps,
		"step_index": 1,
		"card_name": "伏特旋风",
	})

	return run_checks([
		assert_eq(str(battle_scene._pending_choice), "", "恢复不出任何 PokemonSlot 目标时不应进入 network_trainer_interaction"),
		assert_true(battle_scene.shown_field_slot_items.is_empty(), "恢复失败时不应继续显示空的 field slot UI"),
		assert_eq(battle_scene.dialog_call_count, 0, "恢复失败时不应退化为普通 dialog"),
		assert_false(battle_scene.logged_messages.is_empty(), "恢复失败时应写出明确日志"),
		assert_true(battle_scene.logged_messages.any(func(message: String) -> bool: return message.contains("联机交互恢复失败")), "恢复失败日志应标记为联机交互恢复失败"),
	])


func test_game_room_clears_phantom_dive_pending_attack_before_next_attack() -> String:
	var fixture := _make_dragapult_attack_fixture()
	var room := GameRoomScript.new()
	room._gsm = fixture.gsm
	room._state = NetProtocol.ROOM_STATE_PLAYING
	var sent_messages: Array = []
	room.send_to_player.connect(func(player_index: int, message: Dictionary):
		sent_messages.append({"player_index": player_index, "message": message})
	)

	room.handle_action(0, NetProtocol.ACTION_USE_ATTACK, {"attack_index": 1})
	var had_pending_before_resolution := room._pending_attack.has(0)
	room.handle_choice_response(0, NetProtocol.CHOICE_TRAINER_INTERACTION, {"selected_indices": [0, 60]})
	var sent_count_after_interaction: int = sent_messages.size()
	room.handle_action(0, NetProtocol.ACTION_USE_ATTACK, {"attack_index": 0})

	return run_checks([
		assert_true(had_pending_before_resolution, "幻影潜袭开始交互后服务器应记录 pending_attack"),
		assert_eq(fixture.gsm.use_attack_calls, 2, "完成幻影潜袭交互后，下次使用其他招式应还能再次调用 use_attack"),
		assert_true(not room._pending_attack.has(0), "幻影潜袭交互完成后应清理 pending_attack"),
		assert_eq(sent_messages.size(), sent_count_after_interaction, "改用无交互招式时不应再收到旧的交互 prompt"),
		assert_true(fixture.gsm.last_targets.is_empty(), "后续无交互招式不应携带残留的 Phantom Dive targets"),
	])


func _make_attack_fixture() -> Dictionary:
	var gsm := SpyAttackGameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.phase = GameState.GamePhase.MAIN
	gsm.game_state.current_player_index = 0

	var player := PlayerState.new()
	player.player_index = 0
	var opponent := PlayerState.new()
	opponent.player_index = 1

	var attacker_slot := PokemonSlot.new()
	var attacker_data := _make_basic_pokemon_data("铁荆棘ex", "L", "TEST", "001")
	attacker_data.effect_id = "iron_thorns_move_energy_test"
	attacker_data.attacks = [{"name": "伏特旋风", "cost": "0", "damage": "0", "text": "", "is_vstar_power": false}]
	var attacker_card := CardInstance.create(attacker_data, 0)
	attacker_slot.pokemon_stack.append(attacker_card)
	var energy_a := CardInstance.create(_make_energy_data("闪电能量A", "L", "ENERGY", "001"), 0)
	var energy_b := CardInstance.create(_make_energy_data("闪电能量B", "L", "ENERGY", "002"), 0)
	attacker_slot.attached_energy.append(energy_a)
	attacker_slot.attached_energy.append(energy_b)
	player.active_pokemon = attacker_slot

	for i in range(2):
		var bench_slot := PokemonSlot.new()
		bench_slot.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("备战宝可梦%d" % (i + 1), "L", "TEST", "10%d" % i), 0))
		player.bench.append(bench_slot)

	var defender_slot := PokemonSlot.new()
	defender_slot.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("对手战斗宝可梦", "P", "TEST", "900"), 1))
	opponent.active_pokemon = defender_slot

	gsm.game_state.players = [player, opponent]
	gsm.effect_processor.register_attack_effect("iron_thorns_move_energy_test", AttackMoveEnergyToBenchScript.new())
	var steps := AttackMoveEnergyToBenchScript.new().get_attack_interaction_steps(attacker_card, attacker_data.attacks[0], gsm.game_state)

	return {
		"gsm": gsm,
		"player": player,
		"energy_a": energy_a,
		"energy_b": energy_b,
		"steps": steps,
	}


func _make_retreat_fixture() -> Dictionary:
	var gsm := SpyRetreatGameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.phase = GameState.GamePhase.MAIN
	gsm.game_state.current_player_index = 0

	var player := PlayerState.new()
	player.player_index = 0
	var opponent := PlayerState.new()
	opponent.player_index = 1

	var attacker_slot := PokemonSlot.new()
	attacker_slot.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("撤退测试宝可梦", "L", "TEST", "301"), 0))
	var energy_a := CardInstance.create(_make_energy_data("撤退能量A", "L", "ENERGY", "301"), 0)
	var energy_b := CardInstance.create(_make_energy_data("撤退能量B", "L", "ENERGY", "302"), 0)
	attacker_slot.attached_energy.append(energy_a)
	attacker_slot.attached_energy.append(energy_b)
	player.active_pokemon = attacker_slot

	for i in range(2):
		var bench_slot := PokemonSlot.new()
		bench_slot.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("撤退备战%d" % (i + 1), "L", "TEST", "31%d" % i), 0))
		player.bench.append(bench_slot)

	var opponent_slot := PokemonSlot.new()
	opponent_slot.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("对手测试宝可梦", "P", "TEST", "399"), 1))
	opponent.active_pokemon = opponent_slot

	gsm.game_state.players = [player, opponent]

	return {
		"gsm": gsm,
		"player": player,
		"energy_a": energy_a,
		"energy_b": energy_b,
	}


func _make_dragapult_attack_fixture() -> Dictionary:
	var gsm := SpyAttackGameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.phase = GameState.GamePhase.MAIN
	gsm.game_state.current_player_index = 0

	var player := PlayerState.new()
	player.player_index = 0
	var opponent := PlayerState.new()
	opponent.player_index = 1

	var attacker_slot := PokemonSlot.new()
	var attacker_data := _make_basic_pokemon_data("多龙巴鲁托ex", "N", "CSV8C", "159")
	attacker_data.effect_id = "dragapult_network_cleanup_test"
	attacker_data.stage = "Stage 2"
	attacker_data.mechanic = "ex"
	attacker_data.attacks = [
		{"name": "喷射头击", "cost": "C", "damage": "70", "text": "", "is_vstar_power": false},
		{"name": "幻影潜袭", "cost": "RP", "damage": "200", "text": "", "is_vstar_power": false},
	]
	var attacker_card := CardInstance.create(attacker_data, 0)
	attacker_slot.pokemon_stack.append(attacker_card)
	player.active_pokemon = attacker_slot

	var defender_slot := PokemonSlot.new()
	defender_slot.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("对手战斗宝可梦", "P", "TEST", "901"), 1))
	opponent.active_pokemon = defender_slot
	for i in range(2):
		var bench_slot := PokemonSlot.new()
		bench_slot.pokemon_stack.append(CardInstance.create(_make_basic_pokemon_data("对手备战%d" % (i + 1), "P", "TEST", "91%d" % i), 1))
		opponent.bench.append(bench_slot)

	gsm.game_state.players = [player, opponent]
	gsm.effect_processor.register_attack_effect("dragapult_network_cleanup_test", AttackDistributedBenchCountersScript.new(60, 1))

	return {
		"gsm": gsm,
		"player": player,
		"opponent": opponent,
	}


func _make_basic_pokemon_data(name: String, energy_type: String, set_code: String, card_index: String) -> CardData:
	var card_data := CardData.new()
	card_data.name = name
	card_data.card_type = "Pokemon"
	card_data.energy_type = energy_type
	card_data.stage = "Basic"
	card_data.hp = 220
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
class_name TestNetBattleSetupRegression
extends TestBase

const GameRoomScript = preload("res://scripts/server/GameRoom.gd")
const NetBattleSceneScript = preload("res://scenes/network/NetBattleScene.gd")
const NetBattleScenePatchScript = preload("res://scenes/network/NetBattleScenePatch.gd")


class OverlayStub extends Control:
	pass


class PendingChoiceBattleSceneStub extends Control:
	var _pending_choice: String = ""
	var _pending_prize_player_index: int = -1
	var _pending_prize_remaining: int = 0
	var _net_server_pending_choice_type: String = ""
	var _net_server_pending_choice_target_player: int = -1
	var _dialog_overlay := OverlayStub.new()
	var _field_interaction_overlay := OverlayStub.new()
	var hide_field_interaction_calls: int = 0

	func _hide_field_interaction() -> void:
		hide_field_interaction_calls += 1
		_field_interaction_overlay.visible = false


class StubNetHandler extends Control:
	var player_index: int = 0

	func _init(next_player_index: int = 0) -> void:
		player_index = next_player_index

	func get_my_player_index() -> int:
		return player_index


class SpyRoomGameStateMachine extends GameStateMachine:
	var mulligan_resolve_calls: int = 0
	var resolved_player_index: int = -1
	var resolved_draw_extra: bool = false

	func resolve_mulligan_choice(player_index: int, draw_extra: bool) -> void:
		mulligan_resolve_calls += 1
		resolved_player_index = player_index
		resolved_draw_extra = draw_extra


class InteractiveAbilityEffect extends BaseEffect:
	func get_interaction_steps(_card: CardInstance, _state: GameState) -> Array[Dictionary]:
		return [{
			"id": "probe",
			"title": "选择1项",
			"items": ["占位"],
			"labels": ["占位"],
			"min_select": 1,
			"max_select": 1,
		}]


class AbilityPhaseEffectProcessor extends EffectProcessor:
	var source_card: CardInstance = null

	func get_ability_effect(_slot: PokemonSlot, _ability_index: int = 0, _state: GameState = null) -> BaseEffect:
		return InteractiveAbilityEffect.new()

	func can_use_ability(_slot: PokemonSlot, _state: GameState, _ability_index: int = 0) -> bool:
		return true

	func get_ability_source_card(_slot: PokemonSlot, _ability_index: int = 0, _state: GameState = null) -> CardInstance:
		return source_card

	func get_ability_name(_slot: PokemonSlot, _ability_index: int = 0, _state: GameState = null) -> String:
		return "测试特性"


class AbilityPhaseGameStateMachine extends GameStateMachine:
	func _init() -> void:
		effect_processor = AbilityPhaseEffectProcessor.new()


func test_net_scene_preserves_local_setup_prompt_when_server_pending_choice_clears() -> String:
	var scene := NetBattleSceneScript.new()
	var battle_scene := PendingChoiceBattleSceneStub.new()
	battle_scene._pending_choice = "setup_active_0"
	battle_scene._dialog_overlay.visible = true
	scene._battle_scene = battle_scene
	scene._net_my_player_index = 0

	scene._sync_pending_choice({}, GameState.new())

	return run_checks([
		assert_eq(str(battle_scene._pending_choice), "setup_active_0", "空 pending_choice 不应清掉本地 setup_active 对话状态"),
		assert_eq(str(battle_scene._net_server_pending_choice_type), "", "服务器 pending choice 类型应同步清空"),
		assert_eq(int(battle_scene._net_server_pending_choice_target_player), -1, "服务器 pending choice 目标应重置"),
	])


func test_net_scene_preserves_local_network_trainer_dialog_when_server_pending_choice_clears() -> String:
	var scene := NetBattleSceneScript.new()
	var battle_scene := PendingChoiceBattleSceneStub.new()
	battle_scene._pending_choice = "network_trainer_interaction"
	battle_scene._dialog_overlay.visible = true
	scene._battle_scene = battle_scene
	scene._net_my_player_index = 0

	scene._sync_pending_choice({}, GameState.new())

	return run_checks([
		assert_eq(str(battle_scene._pending_choice), "network_trainer_interaction", "空 pending_choice 不应清掉本地 trainer 对话状态"),
		assert_true(battle_scene._dialog_overlay.visible, "trainer 对话框可见时应继续保留"),
	])


func test_net_scene_preserves_local_network_field_interaction_when_server_pending_choice_clears() -> String:
	var scene := NetBattleSceneScript.new()
	var battle_scene := PendingChoiceBattleSceneStub.new()
	battle_scene._pending_choice = "network_trainer_interaction"
	battle_scene._field_interaction_overlay.visible = true
	scene._battle_scene = battle_scene
	scene._net_my_player_index = 0

	scene._sync_pending_choice({}, GameState.new())

	return run_checks([
		assert_eq(str(battle_scene._pending_choice), "network_trainer_interaction", "空 pending_choice 不应清掉本地场地交互状态"),
		assert_true(battle_scene._field_interaction_overlay.visible, "场地交互可见时应继续保留"),
	])


func test_net_scene_tracks_foreign_mulligan_pending_choice_without_claiming_prompt() -> String:
	var scene := NetBattleSceneScript.new()
	var battle_scene := PendingChoiceBattleSceneStub.new()
	battle_scene._pending_choice = "mulligan_extra_draw"
	battle_scene._dialog_overlay.visible = true
	scene._battle_scene = battle_scene
	scene._net_my_player_index = 0

	scene._sync_pending_choice({
		"type": NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW,
		"data": {
			"beneficiary": 1,
			"mulligan_count": 1,
			"target_player": 1,
		},
	}, GameState.new())

	return run_checks([
		assert_eq(str(battle_scene._pending_choice), "", "非受益者客户端不应把补偿抽牌提示当作自己的 prompt"),
		assert_false(battle_scene._dialog_overlay.visible, "非受益者客户端应关闭残留的补偿抽牌对话框"),
		assert_eq(str(battle_scene._net_server_pending_choice_type), NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW, "客户端应记录服务器当前 pending choice 类型"),
		assert_eq(int(battle_scene._net_server_pending_choice_target_player), 1, "客户端应记录服务器当前 pending choice 目标"),
	])


func test_net_patch_blocks_live_actions_while_waiting_for_other_player_choice() -> String:
	var scene := NetBattleScenePatchScript.new()
	var gsm := GameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.current_player_index = 0
	scene._gsm = gsm
	scene._net_mode = true
	scene._net_handler = StubNetHandler.new(0)
	scene._net_server_pending_choice_type = NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW
	scene._net_server_pending_choice_target_player = 1

	return run_checks([
		assert_false(scene._is_my_turn(), "等待对手处理补偿抽牌时，本地不应继续被视为可操作回合"),
		assert_false(scene._can_accept_live_action(), "等待对手处理补偿抽牌时，应阻断本地 live action"),
	])


func test_game_room_rejects_mulligan_choice_from_wrong_player() -> String:
	var room := GameRoomScript.new()
	var gsm := SpyRoomGameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.current_player_index = 0
	room._gsm = gsm
	room._pending_choice = {
		"type": NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW,
		"data": {
			"beneficiary": 1,
			"mulligan_count": 1,
		},
	}
	var sent_messages: Array[Dictionary] = []
	room.send_to_player.connect(func(player_index: int, message: Dictionary) -> void:
		sent_messages.append({
			"player_index": player_index,
			"message": message,
		})
	)

	room.handle_choice_response(0, NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW, {"draw_extra": true})

	var first_message: Dictionary = sent_messages[0] if not sent_messages.is_empty() else {}
	var first_payload: Dictionary = first_message.get("message", {}).get("payload", {}) if first_message.get("message", {}) is Dictionary else {}
	return run_checks([
		assert_eq(gsm.mulligan_resolve_calls, 0, "非受益者发送补偿抽牌选择时，服务器不应执行 resolve_mulligan_choice"),
		assert_eq(str(room._pending_choice.get("type", "")), NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW, "非法响应不应清除服务器 pending choice"),
		assert_eq(sent_messages.size(), 1, "服务器应向错误发送者返回一条错误消息"),
		assert_eq(int(first_message.get("player_index", -1)), 0, "错误消息应返回给违规玩家"),
		assert_eq(str(first_payload.get("code", "")), "not_your_choice", "服务器应返回明确的 choice 所有权错误"),
	])


func test_game_room_rejects_interactive_ability_outside_main_phase() -> String:
	var room := GameRoomScript.new()
	var gsm := AbilityPhaseGameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.players = [PlayerState.new(), PlayerState.new()]
	gsm.game_state.current_player_index = 0
	gsm.game_state.phase = GameState.GamePhase.DRAW
	var processor := gsm.effect_processor as AbilityPhaseEffectProcessor
	processor.source_card = CardInstance.create(CardData.from_dict({
		"name": "百变怪",
		"card_type": "Pokemon",
		"stage": "Basic",
	}), 0)
	room._gsm = gsm
	var sent_messages: Array[Dictionary] = []
	room.send_to_player.connect(func(player_index: int, message: Dictionary) -> void:
		sent_messages.append({
			"player_index": player_index,
			"message": message,
		})
	)

	room._handle_use_ability(0, PokemonSlot.new(), 0)

	var first_message: Dictionary = sent_messages[0] if not sent_messages.is_empty() else {}
	var first_payload: Dictionary = first_message.get("message", {}).get("payload", {}) if first_message.get("message", {}) is Dictionary else {}
	return run_checks([
		assert_false(room._pending_ability.has(0), "非 MAIN 阶段不应创建待处理的特性交互"),
		assert_eq(sent_messages.size(), 1, "服务器应直接返回特性不可用错误"),
		assert_eq(int(first_message.get("player_index", -1)), 0, "错误消息应返回给请求玩家"),
		assert_eq(str(first_payload.get("code", "")), "ability_unavailable", "非 MAIN 阶段应返回 ability_unavailable"),
	])


func test_game_room_enriches_state_pending_choice_with_target_player() -> String:
	var room := GameRoomScript.new()
	var gsm := GameStateMachine.new()
	gsm.game_state = GameState.new()
	gsm.game_state.current_player_index = 0
	room._gsm = gsm

	var pending_choice := room._build_pending_choice_view({
		"type": NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW,
		"data": {
			"beneficiary": 1,
			"mulligan_count": 1,
		},
	})
	var pending_data: Dictionary = pending_choice.get("data", {}) if pending_choice.get("data") is Dictionary else {}

	return run_checks([
		assert_eq(str(pending_choice.get("type", "")), NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW, "补偿抽牌 pending choice 类型应保持不变"),
		assert_eq(int(pending_data.get("target_player", -1)), 1, "state_update 中的 mulligan pending choice 应带上 target_player"),
	])
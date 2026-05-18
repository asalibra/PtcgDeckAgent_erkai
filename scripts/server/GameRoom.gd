## 游戏房间 - 包装 GameStateMachine，处理 action 路由，广播状态
class_name GameRoom
extends RefCounted

signal state_changed(room_id: String)
signal game_ended(room_id: String, winner: int, reason: String)
signal send_to_player(player_index: int, message: Dictionary)

var room_id: String
var room_name: String
var host_player_index: int = 0

var _gsm: GameStateMachine
var _players: Dictionary = {}  # player_index -> {peer_id, name, deck_id, ready, session_token}
var _state: String = NetProtocol.ROOM_STATE_WAITING
var _pending_choice: Dictionary = {}
var _last_action: Dictionary = {}
var _update_pending: bool = false
var _serializer: ServerSerializer
var _first_player_choice: int = -1
var _card_db: Node  # CardDatabase 实例，由 RoomManager 注入
var _extra_deck_data: Dictionary = {}  # player_index -> deck_dict（客户端发来的牌组数据）
var _setup_complete_flags: Dictionary = {}  # player_index -> bool（服务端跟踪双方准备状态）
var _pending_trainer: Dictionary = {}  # player_index -> {card, steps, step_index, context}
var _pending_ability: Dictionary = {}  # player_index -> {slot, ability_index, steps, step_index, context}
var _pending_stadium: Dictionary = {}  # player_index -> {card, steps, step_index, context}
var _pending_attack: Dictionary = {}  # player_index -> {slot, attack_index, attack_name, steps, step_index, context}
var _pending_granted_attack: Dictionary = {}  # player_index -> {slot, granted_attack, steps, step_index, context}
var _choice_prompt_needs_broadcast: bool = false

const BattleReplayStateRestorerScript := preload("res://scripts/engine/BattleReplayStateRestorer.gd")
const ServerBattleRecorderScript := preload("res://scripts/server/ServerBattleRecorder.gd")
const NET_BATTLE_TRACE_LOG_PATH := "user://logs/net_battle_trace.log"
const _SERIALIZED_INTERACTION_STEP_KEYS := {
	"id": true,
	"title": true,
	"min_select": true,
	"max_select": true,
	"allow_cancel": true,
	"items": true,
	"labels": true,
	"source_items": true,
	"source_labels": true,
	"source_groups": true,
	"source_card_items": true,
	"source_card_indices": true,
	"source_choice_labels": true,
	"card_items": true,
	"card_indices": true,
	"choice_labels": true,
	"presentation": true,
	"ui_mode": true,
	"visible_scope": true,
	"card_disabled_badge": true,
	"card_selectable_hint": true,
	"show_selectable_hints": true,
	"card_click_selectable": true,
	"utility_actions": true,
	"prompt_type": true,
	"single_target_only": true,
	"total_counters": true,
	"allow_partial": true,
	"max_assignments": true,
	"max_assignments_per_target": true,
	"source_exclude_targets": true,
	"source_visible_scope": true,
	"source_card_disabled_badge": true,
	"source_card_selectable_hint": true,
	"source_visible_count": true,
	"source_selectable_count": true,
	"card_groups": true,
	"target_items": true,
	"target_labels": true,
}
const _IGNORED_UNSERIALIZED_INTERACTION_STEP_KEYS := {
	"wait_for_coin_animation": true,
}

var _recorder: ServerBattleRecorder


func _init() -> void:
	_serializer = ServerSerializer.new()


func add_player(peer_id: int, player_index: int, player_name: String, session_token: String) -> bool:
	if _players.has(player_index):
		return false
	_players[player_index] = {
		"peer_id": peer_id,
		"name": player_name,
		"deck_id": -1,
		"ready": false,
		"session_token": session_token,
	}
	return true


func remove_player(player_index: int) -> void:
	_players.erase(player_index)
	_pending_trainer.erase(player_index)
	_pending_attack.erase(player_index)
	_setup_complete_flags.erase(player_index)


func set_player_deck(player_index: int, deck_id: int) -> void:
	if _players.has(player_index):
		_players[player_index]["deck_id"] = deck_id


func set_player_ready(player_index: int, ready: bool) -> void:
	if _players.has(player_index):
		_players[player_index]["ready"] = ready


func get_player_count() -> int:
	return _players.size()


func get_opponent_info(player_index: int) -> Dictionary:
	var opp_index := 1 - player_index
	if _players.has(opp_index):
		return _players[opp_index]
	return {}


func get_room_info() -> Dictionary:
	var player_infos: Array = []
	for pi in _players.keys():
		var p: Dictionary = _players[pi]
		player_infos.append({
			"player_index": pi,
			"name": p["name"],
			"ready": p["ready"],
			"connected": true,
		})
	return {
		"room_id": room_id,
		"room_name": room_name,
		"state": _state,
		"players": player_infos,
	}


func start_game() -> bool:
	if _players.size() < 2:
		return false
	for pi in _players.keys():
		if not _players[pi]["ready"]:
			return false

	var deck_id_0: int = _players[0]["deck_id"]
	var deck_id_1: int = _players[1]["deck_id"]
	var deck_0: DeckData = _card_db.get_deck(deck_id_0)
	var deck_1: DeckData = _card_db.get_deck(deck_id_1)
	# 如果服务器没有该牌组，使用客户端发来的数据
	if deck_0 == null and _extra_deck_data.has(0):
		deck_0 = DeckData.from_dict(_extra_deck_data[0])
	if deck_1 == null and _extra_deck_data.has(1):
		deck_1 = DeckData.from_dict(_extra_deck_data[1])
	if deck_0 == null or deck_1 == null:
		_broadcast_error("deck_not_found", "牌组数据未找到")
		return false

	_gsm = GameStateMachine.new()
	_gsm.state_changed.connect(_on_gsm_state_changed)
	_gsm.action_logged.connect(_on_gsm_action_logged)
	_gsm.player_choice_required.connect(_on_gsm_player_choice_required)
	_gsm.game_over.connect(_on_gsm_game_over)

	_state = NetProtocol.ROOM_STATE_PLAYING
	_setup_complete_flags = {}
	_gsm.start_game(deck_0, deck_1, _first_player_choice)

	# 开始录制对局
	_recorder = ServerBattleRecorderScript.new()
	var player_names: Array = []
	var deck_names: Array = []
	for pi in _players.keys():
		player_names.append(_players[pi]["name"])
		deck_names.append(deck_0.deck_name if pi == 0 else deck_1.deck_name)
	_recorder.start_recording(
		room_id,
		player_names,
		deck_names,
		_gsm.game_state.first_player_index,
		_recorder._build_full_snapshot(_gsm.game_state)
	)
	_recorder.record_state_snapshot(_gsm.game_state, "game_start")

	# 通知双方游戏开始
	for pi in _players.keys():
		send_to_player.emit(pi, NetProtocol.make_game_starting(_gsm.game_state.first_player_index, pi))

	# 立即广播初始状态（GSM 信号可能已设置 _update_pending 和 _pending_choice）
	# 必须在 tick() 之前发送，确保客户端在收到 choice_prompt 前已有 game_state
	if _update_pending:
		_broadcast_state_update()
		_update_pending = false

	return true


func handle_action(player_index: int, action_type: String, params: Dictionary) -> void:
	if _state != NetProtocol.ROOM_STATE_PLAYING:
		_send_error_to(player_index, "not_playing", "游戏未在进行中")
		return
	if _gsm == null:
		return
	if action_type in [NetProtocol.ACTION_PLAY_TRAINER, NetProtocol.ACTION_END_TURN]:
		_trace_net_event("action_request", "player=%d action=%s %s params=%s" % [
			player_index,
			action_type,
			_net_turn_state_summary(),
			JSON.stringify(params),
		])

	# 验证是否轮到该玩家（部分 action 不需要轮次检查）
	var needs_turn_check := not (action_type in [
		NetProtocol.ACTION_RESOLVE_MULLIGAN_CHOICE,
		NetProtocol.ACTION_RESOLVE_TAKE_PRIZE,
		NetProtocol.ACTION_SEND_OUT_POKEMON,
		NetProtocol.ACTION_RESOLVE_HEAVY_BATON,
		NetProtocol.ACTION_RESOLVE_EXP_SHARE,
		NetProtocol.ACTION_SETUP_PLACE_ACTIVE,
		NetProtocol.ACTION_SETUP_PLACE_BENCH,
		NetProtocol.ACTION_SETUP_COMPLETE,
	])

	if needs_turn_check and _gsm.game_state.current_player_index != player_index:
		_send_error_to(player_index, "not_your_turn", "不是你的回合")
		return
	if _has_blocking_pending_interaction(player_index) and not _is_pending_interaction_resolution_action(action_type):
		_trace_net_event("action_blocked_pending", "player=%d action=%s pending=%s %s" % [
			player_index,
			action_type,
			_pending_interaction_summary(player_index),
			_net_turn_state_summary(),
		])
		_send_error_to(player_index, "interaction_pending", "请先完成当前交互")
		return

	var pi: int = player_index
	match action_type:
		NetProtocol.ACTION_SETUP_PLACE_ACTIVE:
			var card = _resolve_card_from_hand(pi, int(params.get("instance_id", -1)))
			if card:
				print("[GameRoom] player %d 放置战斗宝可梦: %s" % [pi, card.card_data.name if card.card_data else "?"])
				_gsm.setup_place_active_pokemon(pi, card)
				# 立即广播状态（确保客户端手牌数据更新后再显示备战区对话框）
				if _update_pending:
					_broadcast_state_update()
					_update_pending = false
				# 通知客户端显示备战区选择对话框
				send_to_player.emit(pi, NetProtocol.make_choice_prompt("setup_bench", {"player_index": pi}))
				print("[GameRoom] 已发送 setup_bench 提示给 player %d" % pi)
			else:
				_send_error_to(pi, "card_not_found", "找不到指定卡牌")

		NetProtocol.ACTION_SETUP_PLACE_BENCH:
			var card = _resolve_card_from_hand(pi, int(params.get("instance_id", -1)))
			if card:
				_gsm.setup_place_bench_pokemon(pi, card)
				# 立即广播状态，然后发送备战区提示（让客户端刷新可用宝可梦列表）
				if _update_pending:
					_broadcast_state_update()
					_update_pending = false
				send_to_player.emit(pi, NetProtocol.make_choice_prompt("setup_bench", {"player_index": pi}))
			else:
				_send_error_to(pi, "card_not_found", "找不到指定卡牌")

		NetProtocol.ACTION_SETUP_COMPLETE:
			_setup_complete_flags[pi] = true
			# 检查双方是否都已完成准备
			if _setup_complete_flags.get(0, false) and _setup_complete_flags.get(1, false):
				_pending_choice = {}
				_gsm.setup_complete(0)
				# setup_complete 会触发 state_changed（turn_number 增加），立即广播
				if _update_pending:
					_broadcast_state_update()
					_update_pending = false
				print("[GameRoom] setup_complete 完成，turn_number=%d, current_player=%d" % [_gsm.game_state.turn_number, _gsm.game_state.current_player_index])
			# 否则等待另一方

		NetProtocol.ACTION_PLAY_BASIC_TO_BENCH:
			var card = _resolve_card_from_hand(pi, int(params.get("instance_id", -1)))
			if card:
				_gsm.play_basic_to_bench(pi, card)
			else:
				_send_error_to(pi, "card_not_found", "找不到指定卡牌")

		NetProtocol.ACTION_EVOLVE:
			var card = _resolve_card_from_hand(pi, int(params.get("instance_id", -1)))
			var slot = _resolve_slot(params.get("target_slot", {}))
			if card and slot:
				_gsm.evolve_pokemon(pi, card, slot)
			else:
				_send_error_to(pi, "invalid_action", "进化参数无效")

		NetProtocol.ACTION_ATTACH_ENERGY:
			var card = _resolve_card_from_hand(pi, int(params.get("instance_id", -1)))
			var slot = _resolve_slot(params.get("target_slot", {}))
			if card and slot:
				_gsm.attach_energy(pi, card, slot)
			else:
				_send_error_to(pi, "invalid_action", "附加能量参数无效")

		NetProtocol.ACTION_ATTACH_TOOL:
			var card = _resolve_card_from_hand(pi, int(params.get("instance_id", -1)))
			var slot = _resolve_slot(params.get("target_slot", {}))
			if card and slot:
				_gsm.attach_tool(pi, card, slot)
			else:
				_send_error_to(pi, "invalid_action", "附加工具参数无效")

		NetProtocol.ACTION_PLAY_TRAINER:
			var card = _resolve_card_from_hand(pi, int(params.get("instance_id", -1)))
			if card:
				_handle_play_trainer(pi, card)
			else:
				print("[GameRoom] player %d 训练家卡未找到 (instance_id=%s)" % [pi, params.get("instance_id", "?")])
				_send_error_to(pi, "card_not_found", "找不到指定卡牌")

		NetProtocol.ACTION_PLAY_STADIUM:
			var card = _resolve_card_from_hand(pi, int(params.get("instance_id", -1)))
			if card:
				_gsm.play_stadium(pi, card)
			else:
				_send_error_to(pi, "card_not_found", "找不到指定卡牌")

		NetProtocol.ACTION_USE_STADIUM_EFFECT:
			_handle_use_stadium_effect(pi)

		NetProtocol.ACTION_RETREAT:
			var energy_ids: Array = params.get("energy_instance_ids", [])
			var energy_cards: Array[CardInstance] = []
			for eid in energy_ids:
				var ec: CardInstance = _resolve_card_from_hand(pi, int(eid))
				if ec == null:
					ec = _resolve_attached_energy(pi, int(eid))
				if ec:
					energy_cards.append(ec)
			var bench_slot = _resolve_slot(params.get("bench_slot", {}))
			if bench_slot:
				_gsm.retreat(pi, energy_cards, bench_slot)
			else:
				_send_error_to(pi, "invalid_action", "撤退参数无效")

		NetProtocol.ACTION_USE_ATTACK:
			var attack_index: int = int(params.get("attack_index", 0))
			var targets: Array = _resolve_slot_array(params.get("targets", []))
			if targets.is_empty():
				_handle_use_attack(pi, attack_index)
			else:
				_gsm.use_attack(pi, attack_index, targets)

		NetProtocol.ACTION_USE_GRANTED_ATTACK:
			var attacker_slot = _resolve_slot(params.get("attacker_slot", {}))
			var attack_name: String = str(params.get("attack_name", ""))
			if attacker_slot and not attack_name.is_empty():
				var granted_attack: Dictionary = {"name": attack_name}
				_handle_use_granted_attack(pi, attacker_slot, granted_attack)
			else:
				_send_error_to(pi, "invalid_action", "使用招式参数无效")

		NetProtocol.ACTION_USE_ABILITY:
			var slot = _resolve_slot(params.get("slot", {}))
			var ability_index: int = int(params.get("ability_index", 0))
			if slot:
				_handle_use_ability(pi, slot, ability_index)
			else:
				_send_error_to(pi, "invalid_action", "使用特性参数无效")

		NetProtocol.ACTION_END_TURN:
			_trace_net_event("action_forward_end_turn", "player=%d pending=%s %s" % [
				pi,
				_pending_interaction_summary(pi),
				_net_turn_state_summary(),
			])
			_gsm.end_turn(pi)

		NetProtocol.ACTION_RESOLVE_MULLIGAN_CHOICE:
			var draw_extra: bool = bool(params.get("draw_extra", false))
			if not _is_player_authorized_for_pending_choice(pi, NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW):
				_send_error_to(pi, "not_your_choice", "当前的重抽补偿选择不属于你")
				return
			_pending_choice = {}
			_gsm.resolve_mulligan_choice(pi, draw_extra)

		NetProtocol.ACTION_RESOLVE_TAKE_PRIZE:
			var slot_index: int = int(params.get("slot_index", 0))
			_pending_choice = {}
			_gsm.resolve_take_prize(pi, slot_index)

		NetProtocol.ACTION_SEND_OUT_POKEMON:
			var slot = _resolve_slot(params.get("slot", {}))
			if slot:
				_pending_choice = {}
				_gsm.send_out_pokemon(pi, slot)

		NetProtocol.ACTION_RESOLVE_HEAVY_BATON:
			var slot = _resolve_slot(params.get("slot", {}))
			if slot:
				_pending_choice = {}
				_gsm.resolve_heavy_baton_choice(pi, slot)

		NetProtocol.ACTION_RESOLVE_EXP_SHARE:
			var slot = _resolve_slot(params.get("slot", {}))
			if slot:
				_pending_choice = {}
				_gsm.resolve_exp_share_choice(pi, slot)

		_:
			_send_error_to(pi, "unknown_action", "未知操作: %s" % action_type)


func handle_choice_response(player_index: int, choice_type: String, data: Dictionary) -> void:
	if _gsm == null:
		return
	match choice_type:
		NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW:
			if not _is_player_authorized_for_pending_choice(player_index, choice_type):
				_send_error_to(player_index, "not_your_choice", "当前的重抽补偿选择不属于你")
				return
			_pending_choice = {}
			_gsm.resolve_mulligan_choice(player_index, bool(data.get("draw_extra", false)))
		NetProtocol.CHOICE_TAKE_PRIZE:
			_pending_choice = {}
			_gsm.resolve_take_prize(player_index, int(data.get("slot_index", 0)))
		NetProtocol.CHOICE_SEND_OUT_POKEMON:
			var slot = _resolve_slot(data.get("slot", {}))
			if slot:
				_pending_choice = {}
				_gsm.send_out_pokemon(player_index, slot)
		NetProtocol.CHOICE_HEAVY_BATON_TARGET:
			var slot = _resolve_slot(data.get("slot", {}))
			if slot:
				_pending_choice = {}
				_gsm.resolve_heavy_baton_choice(player_index, slot)
		NetProtocol.CHOICE_EXP_SHARE_TARGET:
			var slot = _resolve_slot(data.get("slot", {}))
			if slot:
				_pending_choice = {}
				_gsm.resolve_exp_share_choice(player_index, slot)
		NetProtocol.CHOICE_TRAINER_INTERACTION:
			_pending_choice = {}
			if _pending_attack.has(player_index):
				_resolve_attack_interaction(player_index, data)
			elif _pending_ability.has(player_index):
				_resolve_ability_interaction(player_index, data)
			elif _pending_stadium.has(player_index):
				_resolve_stadium_interaction(player_index, data)
			elif _pending_granted_attack.has(player_index):
				_resolve_granted_attack_interaction(player_index, data)
			else:
				_resolve_trainer_interaction(player_index, data)


func tick(_delta: float) -> void:
	if _update_pending:
		_broadcast_state_update()
		_update_pending = false

	# 检查断线超时
	for pi in _players.keys():
		var session = _players[pi].get("_session_obj")
		if session != null and session.is_expired():
			var winner: int = 1 - pi
			_on_gsm_game_over(winner, "对手断线超时")


func get_visible_state(player_index: int) -> Dictionary:
	if _gsm == null or _gsm.game_state == null:
		return {}
	return _serializer.build_view_for_player(_gsm.game_state, player_index, _last_action, _pending_choice)


# ===================== GSM 信号处理 =====================

func _on_gsm_state_changed(new_phase) -> void:
	_update_pending = true
	state_changed.emit(room_id)
	# 在抽牌阶段（回合开始）记录状态快照
	if _recorder != null and _gsm != null and _gsm.game_state != null:
		if new_phase == GameState.GamePhase.DRAW:
			_recorder.record_state_snapshot(_gsm.game_state, "turn_start")


func _on_gsm_action_logged(action) -> void:
	_last_action = _serializer.serialize_action(action)
	# 录制 action
	if _recorder != null and _gsm != null:
		_recorder.record_action(action, _gsm.game_state)
	# 抽牌揭示
	if action != null and str(action.action_type) == "DRAW_CARD":
		var drawing_player: int = action.player_index
		var cards: Array = []
		if action.data is Dictionary:
			cards = action.data.get("cards", [])
		if cards.size() > 0:
			var reveal_data := _serializer.serialize_draw_cards(cards)
			send_to_player.emit(drawing_player, NetProtocol.make_draw_reveal(drawing_player, reveal_data))
	_update_pending = true


func _on_gsm_player_choice_required(choice_type: String, data: Dictionary) -> void:
	_pending_choice = {"type": choice_type, "data": data}
	# 录制 choice prompt
	if _recorder != null and _gsm != null and _gsm.game_state != null:
		_recorder.record_choice_prompt(choice_type, data, _gsm.game_state.current_player_index, _gsm.game_state)
	_update_pending = true
	_choice_prompt_needs_broadcast = true


func _on_gsm_game_over(winner_index: int, reason: String) -> void:
	_state = NetProtocol.ROOM_STATE_FINISHED
	_pending_choice = {}
	# 录制最终状态并结束录制
	if _recorder != null and _gsm != null and _gsm.game_state != null:
		_recorder.record_state_snapshot(_gsm.game_state, "game_end")
		_recorder.finalize_recording(winner_index, reason, _gsm.game_state.turn_number)
		print("[GameRoom] 对局录制完成: %s" % _recorder.get_match_dir())
	# 先发最后一次状态更新
	_broadcast_state_update()
	# 再发 game_over
	_broadcast(NetProtocol.make_game_over(winner_index, reason))
	game_ended.emit(room_id, winner_index, reason)


# ===================== 内部工具 =====================

func _resolve_card_from_hand(player_index: int, instance_id: int):
	if _gsm == null or _gsm.game_state == null:
		return null
	var player: PlayerState = _gsm.game_state.players[player_index]
	for card in player.hand:
		if card != null and card.instance_id == instance_id:
			return card
	return null


func _resolve_attached_energy(player_index: int, instance_id: int):
	if _gsm == null or _gsm.game_state == null:
		return null
	var player: PlayerState = _gsm.game_state.players[player_index]
	var slots: Array = []
	if player.active_pokemon != null:
		slots.append(player.active_pokemon)
	for slot in player.bench:
		if slot != null:
			slots.append(slot)
	for slot in slots:
		for energy in slot.attached_energy:
			if energy != null and energy.instance_id == instance_id:
				return energy
	return null


func _resolve_slot(ref: Dictionary):
	if ref.is_empty() or _gsm == null or _gsm.game_state == null:
		return null
	var pi: int = int(ref.get("player_index", -1))
	var kind: String = str(ref.get("slot_kind", ""))
	var idx: int = int(ref.get("slot_index", 0))
	if pi < 0 or pi >= _gsm.game_state.players.size():
		return null
	var player: PlayerState = _gsm.game_state.players[pi]
	if kind == "active":
		return player.active_pokemon
	elif kind == "bench":
		if idx >= 0 and idx < player.bench.size():
			return player.bench[idx]
	return null


func _resolve_slot_array(refs: Array) -> Array:
	var result: Array = []
	for ref in refs:
		if ref is Dictionary:
			var slot = _resolve_slot(ref)
			if slot != null:
				result.append(slot)
	return result


func _find_bench_index(player_index: int, slot) -> int:
	if _gsm == null or _gsm.game_state == null:
		return -1
	var player: PlayerState = _gsm.game_state.players[player_index]
	return player.bench.find(slot)


func _resolve_choice_target(choice_type: String, data: Dictionary) -> int:
	if _gsm == null:
		return 0
	match choice_type:
		NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW:
			return int(data.get("beneficiary", _gsm.game_state.current_player_index))
		NetProtocol.CHOICE_SEND_OUT_POKEMON, \
		NetProtocol.CHOICE_TAKE_PRIZE, \
		NetProtocol.CHOICE_HEAVY_BATON_TARGET, \
		NetProtocol.CHOICE_EXP_SHARE_TARGET:
			return int(data.get("player", _gsm.game_state.current_player_index))
		_:
			return _gsm.game_state.current_player_index


func _has_blocking_pending_interaction(player_index: int) -> bool:
	return _pending_trainer.has(player_index) \
		or _pending_attack.has(player_index) \
		or _pending_ability.has(player_index) \
		or _pending_stadium.has(player_index) \
		or _pending_granted_attack.has(player_index)


func _is_pending_interaction_resolution_action(action_type: String) -> bool:
	return action_type in [
		NetProtocol.ACTION_RESOLVE_MULLIGAN_CHOICE,
		NetProtocol.ACTION_RESOLVE_TAKE_PRIZE,
		NetProtocol.ACTION_SEND_OUT_POKEMON,
		NetProtocol.ACTION_RESOLVE_HEAVY_BATON,
		NetProtocol.ACTION_RESOLVE_EXP_SHARE,
		NetProtocol.ACTION_SETUP_PLACE_ACTIVE,
		NetProtocol.ACTION_SETUP_PLACE_BENCH,
		NetProtocol.ACTION_SETUP_COMPLETE,
	]


func _is_player_authorized_for_pending_choice(player_index: int, choice_type: String) -> bool:
	if _pending_choice.is_empty():
		return true
	var pending_type: String = str(_pending_choice.get("type", ""))
	if pending_type.is_empty() or pending_type != choice_type:
		return true
	var pending_data: Dictionary = _pending_choice.get("data", {}) if _pending_choice.get("data") is Dictionary else {}
	var target_player := _resolve_choice_target(choice_type, pending_data)
	return target_player < 0 or target_player == player_index


func _build_pending_choice_view(choice: Dictionary) -> Dictionary:
	if choice.is_empty():
		return {}
	var choice_type: String = str(choice.get("type", ""))
	if choice_type.is_empty():
		return {}
	var data: Dictionary = choice.get("data", {}) if choice.get("data") is Dictionary else {}
	if choice_type == "setup_ready":
		return {
			"type": choice_type,
			"data": data.duplicate(true),
		}
	var enriched_data: Dictionary = data.duplicate(true)
	var target_player := _resolve_choice_target(choice_type, data)
	if target_player >= 0:
		enriched_data["target_player"] = target_player
	return {
		"type": choice_type,
		"data": enriched_data,
	}


func _handle_play_trainer(pi: int, card: CardInstance) -> void:
	_trace_net_event("trainer_begin", "player=%d card=%s effect=%s type=%s hand=%d deck=%d pending=%s %s" % [
		pi,
		card.card_data.name if card != null and card.card_data != null else "?",
		card.card_data.effect_id if card != null and card.card_data != null else "",
		card.card_data.card_type if card != null and card.card_data != null else "?",
		_gsm.game_state.players[pi].hand.size(),
		_gsm.game_state.players[pi].deck.size(),
		_pending_interaction_summary(pi),
		_net_turn_state_summary(),
	])
	if _pending_trainer.has(pi):
		_send_error_to(pi, "trainer_interaction_pending", "请先完成当前训练家交互")
		return
	var effect_id: String = card.card_data.effect_id if card.card_data else ""
	var card_type: String = card.card_data.card_type if card.card_data else "?"
	print("[GameRoom] player %d 使用训练家: %s (effect_id=%s, type=%s, hand_size=%d)" % [
		pi, card.card_data.name if card.card_data else "?",
		effect_id, card_type,
		_gsm.game_state.players[pi].hand.size()])
	var effect = _gsm.effect_processor.get_effect(effect_id)
	if effect != null and effect.can_execute(card, _gsm.game_state):
		var steps: Array[Dictionary] = effect.get_interaction_steps(card, _gsm.game_state)
		var coin_result: Variant = _detect_coin_flip_result(steps)
		# get_interaction_steps 可能通过 flip() 设置了 effect 的内部状态
		# 对于硬币反面（steps 为空但 effect 已翻过硬币），需要补充检测
		if steps.is_empty() and coin_result == null and effect.get("_has_pending_flip") != null:
			if effect._has_pending_flip and not effect._pending_heads:
				coin_result = false  # 硬币反面
		if not steps.is_empty():
			# 有交互步骤：存储 pending，发送交互提示（不立即执行）
			_pending_trainer[pi] = {
				"card": card,
				"steps": steps,
				"step_index": 0,
				"context": {},
			}
			var serialized_steps := _serialize_interaction_steps(steps)
			var prompt_data: Dictionary = {
				"steps": serialized_steps,
				"step_index": 0,
				"card_name": card.card_data.name if card.card_data else "?",
				"target_player": pi,
			}
			if coin_result != null:
				prompt_data["coin_flip_result"] = coin_result
			var prompt_message := NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, prompt_data)
			var prompt_bytes := NetProtocol.dict_to_json_string(prompt_message).to_utf8_buffer().size()
			_log_trainer_trace(
				"send_prompt",
				pi,
				card.card_data.name if card.card_data else "?",
				steps[0],
				0,
				steps.size(),
				"coin=%s bytes=%d" % [str(coin_result), prompt_bytes]
			)
			_trace_net_event("trainer_prompt_sent", "player=%d card=%s step_id=%s steps=%d coin=%s bytes=%d %s" % [
				pi,
				card.card_data.name if card.card_data else "?",
				str(steps[0].get("id", "step_0")),
				steps.size(),
				str(coin_result),
				prompt_bytes,
				_net_turn_state_summary(),
			])
			send_to_player.emit(pi, prompt_message)
			print("[GameRoom] player %d 训练家 %s 需要交互（%d步，硬币=%s），已发送步骤提示" % [
				pi, card.card_data.name if card.card_data else "?", steps.size(), str(coin_result)])
			return
		# 无交互步骤：检查硬币结果
		if coin_result != null:
			# 硬币投掷类卡牌，无后续交互
			if coin_result:
				# 正面但无交互步骤（理论上不该发生，防御性处理）
				send_to_player.emit(pi, NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, {
					"steps": [], "step_index": 0,
					"card_name": card.card_data.name if card.card_data else "?",
					"target_player": pi,
					"coin_flip_result": true, "coin_only": true,
				}))
				var result: bool = _gsm.play_trainer(pi, card, [])
				print("[GameRoom] player %d 训练家 %s 硬币正面，直接执行: %s" % [pi, card.card_data.name if card.card_data else "?", result])
			else:
				# 反面：通知客户端，手动弃牌，不执行效果
				send_to_player.emit(pi, NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, {
					"steps": [], "step_index": 0,
					"card_name": card.card_data.name if card.card_data else "?",
					"target_player": pi,
					"coin_flip_result": false, "coin_only": true,
				}))
				_manual_discard_trainer(pi, card)
				print("[GameRoom] player %d 训练家 %s 硬币反面，卡牌已弃置" % [pi, card.card_data.name if card.card_data else "?"])
			return
	# 无硬币投掷，无交互步骤：直接执行
	var exec_result: bool = _gsm.play_trainer(pi, card, [])
	_trace_net_event("trainer_direct_result", "player=%d card=%s result=%s in_hand=%s in_discard=%s %s" % [
		pi,
		card.card_data.name if card != null and card.card_data != null else "?",
		str(exec_result),
		str(card in _gsm.game_state.players[pi].hand),
		str(card in _gsm.game_state.players[pi].discard_pile),
		_net_turn_state_summary(),
	])
	print("[GameRoom] play_trainer 结果: %s, hand_size_after=%d" % [exec_result, _gsm.game_state.players[pi].hand.size()])


## 硬币反面时手动弃置训练家卡（不执行效果）
func _manual_discard_trainer(pi: int, card: CardInstance) -> void:
	var player: PlayerState = _gsm.game_state.players[pi]
	player.hand.erase(card)
	player.discard_pile.append(card)
	_broadcast_state_update()


# ===================== 特性交互处理 =====================

func _handle_use_ability(pi: int, slot: PokemonSlot, ability_index: int) -> void:
	if _pending_ability.has(pi):
		_send_error_to(pi, "ability_interaction_pending", "请先完成当前特性交互")
		return
	if _gsm == null or _gsm.game_state == null:
		_send_error_to(pi, "ability_unavailable", "当前对局状态无法使用特性")
		return
	if _gsm.game_state.current_player_index != pi or _gsm.game_state.phase != GameState.GamePhase.MAIN:
		_send_error_to(pi, "ability_unavailable", "当前阶段无法使用特性")
		return
	var effect = _gsm.effect_processor.get_ability_effect(slot, ability_index, _gsm.game_state)
	if effect == null or not _gsm.effect_processor.can_use_ability(slot, _gsm.game_state, ability_index):
		_send_error_to(pi, "ability_unavailable", "特性不可用")
		return
	var card: CardInstance = _gsm.effect_processor.get_ability_source_card(slot, ability_index, _gsm.game_state)
	if card == null:
		_send_error_to(pi, "ability_unavailable", "特性来源卡牌无效")
		return
	var steps: Array[Dictionary] = effect.get_interaction_steps(card, _gsm.game_state)
	if not steps.is_empty():
		# 有交互步骤：存储 pending，发送交互提示给客户端
		_pending_ability[pi] = {
			"slot": slot,
			"ability_index": ability_index,
			"steps": steps,
			"step_index": 0,
			"context": {},
		}
		var serialized_steps := _serialize_interaction_steps(steps)
		var ability_name: String = _gsm.effect_processor.get_ability_name(slot, ability_index, _gsm.game_state)
		send_to_player.emit(pi, NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, {
			"steps": serialized_steps,
			"step_index": 0,
			"card_name": ability_name,
			"target_player": pi,
		}))
		print("[GameRoom] player %d 特性 %s 需要交互（%d步），已发送步骤提示" % [pi, ability_name, steps.size()])
		return
	# 无交互步骤：直接执行
	var result: bool = _gsm.use_ability(pi, slot, ability_index, [])
	print("[GameRoom] player %d 特性直接执行: %s" % [pi, result])
	if not result:
		var fail_name: String = _gsm.effect_processor.get_ability_name(slot, ability_index, _gsm.game_state)
		_send_error_to(pi, "ability_failed", "特性「%s」执行失败" % fail_name)


func _resolve_ability_interaction(pi: int, params: Dictionary) -> void:
	if not _pending_ability.has(pi):
		_send_error_to(pi, "no_pending_ability", "没有待处理的特性交互")
		return
	var cancelled: bool = bool(params.get("cancelled", false))
	if cancelled:
		_pending_ability.erase(pi)
		_send_error_to(pi, "cancelled", "操作已取消")
		return
	var selected_indices: Array = params.get("selected_indices", [])
	var pending: Dictionary = _pending_ability[pi]
	var steps: Array = pending["steps"]
	var step_index: int = int(pending["step_index"])
	var context: Dictionary = pending["context"]
	if step_index >= steps.size():
		_pending_ability.erase(pi)
		_send_error_to(pi, "invalid_step", "交互步骤索引无效")
		return
	var step: Dictionary = steps[step_index]
	var step_id: String = str(step.get("id", "step_%d" % step_index))
	context[step_id] = _build_step_selection_result(step, selected_indices)
	var next_step_index: int = step_index + 1
	if next_step_index < steps.size():
		pending["step_index"] = next_step_index
		pending["context"] = context
		var serialized_steps := _serialize_interaction_steps(steps)
		var ability_name: String = _gsm.effect_processor.get_ability_name(
			pending["slot"], pending["ability_index"], _gsm.game_state)
		send_to_player.emit(pi, NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, {
			"steps": serialized_steps,
			"step_index": next_step_index,
			"card_name": ability_name,
			"target_player": pi,
		}))
		print("[GameRoom] player %d 特性交互第 %d 步完成，发送第 %d 步" % [pi, step_index, next_step_index])
	else:
		var slot: PokemonSlot = pending["slot"]
		var ability_index: int = int(pending["ability_index"])
		_pending_ability.erase(pi)
		var result: bool = _gsm.use_ability(pi, slot, ability_index, [context])
		print("[GameRoom] player %d 特性交互完成，use_ability 结果: %s" % [pi, result])


# ===================== 竞技场效果交互处理 =====================

func _handle_use_stadium_effect(pi: int) -> void:
	if _pending_stadium.has(pi):
		_send_error_to(pi, "stadium_interaction_pending", "请先完成当前竞技场交互")
		return
	var stadium_card: CardInstance = _gsm.game_state.stadium_card
	if stadium_card == null:
		_send_error_to(pi, "no_stadium", "没有竞技场卡牌")
		return
	var effect = _gsm.effect_processor.get_effect(stadium_card.card_data.effect_id)
	if effect == null:
		_send_error_to(pi, "no_effect", "竞技场效果不存在")
		return
	var steps: Array[Dictionary] = effect.get_interaction_steps(stadium_card, _gsm.game_state)
	if not steps.is_empty():
		_pending_stadium[pi] = {
			"card": stadium_card,
			"steps": steps,
			"step_index": 0,
			"context": {},
		}
		var serialized_steps := _serialize_interaction_steps(steps)
		send_to_player.emit(pi, NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, {
			"steps": serialized_steps,
			"step_index": 0,
			"card_name": stadium_card.card_data.name if stadium_card.card_data else "?",
			"target_player": pi,
		}))
		print("[GameRoom] player %d 竞技场 %s 需要交互（%d步），已发送步骤提示" % [
			pi, stadium_card.card_data.name if stadium_card.card_data else "?", steps.size()])
		return
	var result: bool = _gsm.use_stadium_effect(pi, [])
	print("[GameRoom] player %d 竞技场效果直接执行: %s" % [pi, result])


func _resolve_stadium_interaction(pi: int, params: Dictionary) -> void:
	if not _pending_stadium.has(pi):
		_send_error_to(pi, "no_pending_stadium", "没有待处理的竞技场交互")
		return
	var cancelled: bool = bool(params.get("cancelled", false))
	if cancelled:
		_pending_stadium.erase(pi)
		_send_error_to(pi, "cancelled", "操作已取消")
		return
	var selected_indices: Array = params.get("selected_indices", [])
	var pending: Dictionary = _pending_stadium[pi]
	var steps: Array = pending["steps"]
	var step_index: int = int(pending["step_index"])
	var context: Dictionary = pending["context"]
	if step_index >= steps.size():
		_pending_stadium.erase(pi)
		_send_error_to(pi, "invalid_step", "交互步骤索引无效")
		return
	var step: Dictionary = steps[step_index]
	var step_id: String = str(step.get("id", "step_%d" % step_index))
	context[step_id] = _build_step_selection_result(step, selected_indices)
	var next_step_index: int = step_index + 1
	if next_step_index < steps.size():
		pending["step_index"] = next_step_index
		pending["context"] = context
		var serialized_steps := _serialize_interaction_steps(steps)
		var card_name: String = pending["card"].card_data.name if pending["card"].card_data else "?"
		send_to_player.emit(pi, NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, {
			"steps": serialized_steps,
			"step_index": next_step_index,
			"card_name": card_name,
			"target_player": pi,
		}))
		print("[GameRoom] player %d 竞技场交互第 %d 步完成，发送第 %d 步" % [pi, step_index, next_step_index])
	else:
		_pending_stadium.erase(pi)
		var result: bool = _gsm.use_stadium_effect(pi, [context])
		print("[GameRoom] player %d 竞技场交互完成，use_stadium_effect 结果: %s" % [pi, result])


# ===================== 赋予招式交互处理 =====================

func _handle_use_attack(pi: int, attack_index: int) -> void:
	if _pending_attack.has(pi):
		_send_error_to(pi, "attack_interaction_pending", "请先完成当前招式交互")
		return
	if not _gsm.can_use_attack(pi, attack_index):
		_send_error_to(pi, "attack_unavailable", _gsm.get_attack_unusable_reason(pi, attack_index))
		return
	if _gsm.game_state == null or pi < 0 or pi >= _gsm.game_state.players.size():
		_send_error_to(pi, "invalid_action", "招式参数无效")
		return
	var attacker_slot: PokemonSlot = _gsm.game_state.players[pi].active_pokemon
	if attacker_slot == null:
		_send_error_to(pi, "attack_unavailable", "没有可用的战斗宝可梦")
		return
	var card: CardInstance = attacker_slot.get_top_card()
	if card == null or card.card_data == null:
		_send_error_to(pi, "attack_unavailable", "招式来源卡牌无效")
		return
	var attacks: Array = card.card_data.attacks if card.card_data.attacks is Array else []
	if attack_index < 0 or attack_index >= attacks.size():
		_send_error_to(pi, "invalid_action", "招式索引无效")
		return
	var attack: Dictionary = attacks[attack_index] if attacks[attack_index] is Dictionary else {}
	var steps: Array[Dictionary] = []
	var effects: Array[BaseEffect] = _gsm.effect_processor.get_attack_effects_for_slot(attacker_slot, attack_index)
	for effect: BaseEffect in effects:
		steps.append_array(effect.get_attack_interaction_steps(card, attack, _gsm.game_state))
	var defender: PokemonSlot = null
	if _gsm.game_state.players.size() > 1 - pi and (1 - pi) >= 0:
		defender = _gsm.game_state.players[1 - pi].active_pokemon
	steps.append_array(_gsm.get_post_damage_defender_interaction_steps(attacker_slot, defender))
	if steps.is_empty():
		var result: bool = _gsm.use_attack(pi, attack_index)
		if not result:
			_send_error_to(pi, "attack_failed", _gsm.get_attack_unusable_reason(pi, attack_index))
		return
	_pending_attack[pi] = {
		"slot": attacker_slot,
		"attack_index": attack_index,
		"attack_name": str(attack.get("name", "招式")),
		"steps": steps,
		"step_index": 0,
		"context": {},
	}
	var serialized_steps := _serialize_interaction_steps(steps)
	send_to_player.emit(pi, NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, {
		"steps": serialized_steps,
		"step_index": 0,
		"card_name": str(attack.get("name", "招式")),
		"target_player": pi,
	}))
	print("[GameRoom] player %d 招式 %s 需要交互（%d步），已发送步骤提示" % [pi, str(attack.get("name", "?")), steps.size()])


func _resolve_attack_interaction(pi: int, params: Dictionary) -> void:
	if not _pending_attack.has(pi):
		_send_error_to(pi, "no_pending_attack", "没有待处理的招式交互")
		return
	var cancelled: bool = bool(params.get("cancelled", false))
	if cancelled:
		_pending_attack.erase(pi)
		_send_error_to(pi, "cancelled", "操作已取消")
		return
	var selected_indices: Array = params.get("selected_indices", [])
	var pending: Dictionary = _pending_attack[pi]
	var steps: Array = pending["steps"]
	var step_index: int = int(pending["step_index"])
	var context: Dictionary = pending["context"]
	if step_index >= steps.size():
		_pending_attack.erase(pi)
		_send_error_to(pi, "invalid_step", "交互步骤索引无效")
		return
	var step: Dictionary = steps[step_index]
	var step_id: String = str(step.get("id", "step_%d" % step_index))
	context[step_id] = _build_step_selection_result(step, selected_indices)
	var next_step_index: int = step_index + 1
	if next_step_index < steps.size():
		pending["step_index"] = next_step_index
		pending["context"] = context
		var serialized_steps := _serialize_interaction_steps(steps)
		send_to_player.emit(pi, NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, {
			"steps": serialized_steps,
			"step_index": next_step_index,
			"card_name": str(pending.get("attack_name", "招式")),
			"target_player": pi,
		}))
		print("[GameRoom] player %d 招式交互第 %d 步完成，发送第 %d 步" % [pi, step_index, next_step_index])
	else:
		var slot: PokemonSlot = pending["slot"]
		var attack_index: int = int(pending["attack_index"])
		_pending_attack.erase(pi)
		var result: bool = _gsm.use_attack(pi, attack_index, [context])
		print("[GameRoom] player %d 招式交互完成，use_attack 结果: %s" % [pi, result])
		if not result:
			_send_error_to(pi, "attack_failed", "招式执行失败")

func _handle_use_granted_attack(pi: int, attacker_slot: PokemonSlot, granted_attack: Dictionary) -> void:
	if _pending_granted_attack.has(pi):
		_send_error_to(pi, "granted_attack_interaction_pending", "请先完成当前招式交互")
		return
	var attack_name: String = str(granted_attack.get("name", ""))
	# 通过 EffectProcessor 获取赋予招式的交互步骤（自动查找道具效果）
	var steps: Array[Dictionary] = _gsm.effect_processor.get_granted_attack_interaction_steps(attacker_slot, granted_attack, _gsm.game_state)
	if steps.is_empty():
		# 无交互步骤：直接执行
		var result: bool = _gsm.use_granted_attack(pi, attacker_slot, granted_attack, [])
		print("[GameRoom] player %d 赋予招式 %s 直接执行: %s" % [pi, attack_name, result])
		if not result:
			_send_error_to(pi, "granted_attack_failed", "招式「%s」执行失败" % attack_name)
		return
	# 有交互步骤：存储 pending，发送交互提示给客户端
	_pending_granted_attack[pi] = {
		"slot": attacker_slot,
		"granted_attack": granted_attack,
		"steps": steps,
		"step_index": 0,
		"context": {},
	}
	var serialized_steps := _serialize_interaction_steps(steps)
	send_to_player.emit(pi, NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, {
		"steps": serialized_steps,
		"step_index": 0,
		"card_name": attack_name,
		"target_player": pi,
	}))
	print("[GameRoom] player %d 赋予招式 %s 需要交互（%d步），已发送步骤提示" % [pi, attack_name, steps.size()])


func _resolve_granted_attack_interaction(pi: int, params: Dictionary) -> void:
	if not _pending_granted_attack.has(pi):
		_send_error_to(pi, "no_pending_granted_attack", "没有待处理的招式交互")
		return
	var cancelled: bool = bool(params.get("cancelled", false))
	if cancelled:
		_pending_granted_attack.erase(pi)
		_send_error_to(pi, "cancelled", "操作已取消")
		return
	var selected_indices: Array = params.get("selected_indices", [])
	var pending: Dictionary = _pending_granted_attack[pi]
	var steps: Array = pending["steps"]
	var step_index: int = int(pending["step_index"])
	var context: Dictionary = pending["context"]
	if step_index >= steps.size():
		_pending_granted_attack.erase(pi)
		_send_error_to(pi, "invalid_step", "交互步骤索引无效")
		return
	var step: Dictionary = steps[step_index]
	var step_id: String = str(step.get("id", "step_%d" % step_index))
	context[step_id] = _build_step_selection_result(step, selected_indices)
	var next_step_index: int = step_index + 1
	if next_step_index < steps.size():
		pending["step_index"] = next_step_index
		pending["context"] = context
		var serialized_steps := _serialize_interaction_steps(steps)
		var attack_name: String = str(pending["granted_attack"].get("name", "?"))
		send_to_player.emit(pi, NetProtocol.make_choice_prompt(NetProtocol.CHOICE_TRAINER_INTERACTION, {
			"steps": serialized_steps,
			"step_index": next_step_index,
			"card_name": attack_name,
			"target_player": pi,
		}))
		print("[GameRoom] player %d 赋予招式交互第 %d 步完成，发送第 %d 步" % [pi, step_index, next_step_index])
	else:
		var slot: PokemonSlot = pending["slot"]
		var ga: Dictionary = pending["granted_attack"]
		_pending_granted_attack.erase(pi)
		var result: bool = _gsm.use_granted_attack(pi, slot, ga, [context])
		print("[GameRoom] player %d 赋予招式交互完成，use_granted_attack 结果: %s" % [pi, result])
		if not result:
			_send_error_to(pi, "granted_attack_failed", "招式执行失败")


## 检测交互步骤中是否包含硬币投掷，返回投掷结果（true=正面，false=反面，null=无硬币）
func _detect_coin_flip_result(steps: Array[Dictionary]) -> Variant:
	if steps.is_empty():
		return null
	var first_step: Dictionary = steps[0]
	if not first_step.get("wait_for_coin_animation", false):
		return null
	# 硬币步骤之后有非硬币步骤 → 正面
	for i in range(1, steps.size()):
		var step: Dictionary = steps[i]
		if not step.get("wait_for_coin_animation", false):
			return true
	# 只有硬币步骤：检查该步骤自身是否包含可选目标（正面+选择合一的步骤）
	var items: Array = first_step.get("items", [])
	if not items.is_empty():
		return true
	# 纯预览无目标 → 反面
	return false


func _trainer_trace_step_summary(step: Dictionary, step_index: int, total_steps: int) -> String:
	var step_id := str(step.get("id", "step_%d" % step_index))
	var ui_mode := str(step.get("ui_mode", step.get("presentation", "auto")))
	var items: Array = step.get("items", [])
	var target_items: Array = step.get("target_items", [])
	var card_items: Array = step.get("card_items", [])
	return "step=%d/%d id=%s ui=%s items=%d target_items=%d card_items=%d" % [
		step_index + 1,
		total_steps,
		step_id,
		ui_mode,
		items.size(),
		target_items.size(),
		card_items.size(),
	]


func _log_trainer_trace(event_name: String, pi: int, card_name: String, step: Dictionary, step_index: int, total_steps: int, extra: String = "") -> void:
	var message := "[GameRoom][TrainerTrace] %s player=%d card=%s %s" % [
		event_name,
		pi,
		card_name,
		_trainer_trace_step_summary(step, step_index, total_steps),
	]
	if not extra.is_empty():
		message += " " + extra
	print(message)


func _resolve_trainer_interaction(pi: int, params: Dictionary) -> void:
	if not _pending_trainer.has(pi):
		_send_error_to(pi, "no_pending_trainer", "没有待处理的训练家交互")
		return
	var pending: Dictionary = _pending_trainer[pi]
	var steps: Array = pending["steps"]
	var step_index: int = int(pending["step_index"])
	var card_name: String = pending["card"].card_data.name if pending["card"].card_data else "?"
	var cancelled: bool = bool(params.get("cancelled", false))
	if cancelled:
		if step_index >= 0 and step_index < steps.size():
			_log_trainer_trace("recv_cancel", pi, card_name, steps[step_index], step_index, steps.size())
		# 用户取消：清除 pending
		_pending_trainer.erase(pi)
		_send_error_to(pi, "cancelled", "操作已取消")
		return
	var selected_indices: Array = params.get("selected_indices", [])
	var context: Dictionary = pending["context"]
	if step_index >= steps.size():
		_pending_trainer.erase(pi)
		_send_error_to(pi, "invalid_step", "交互步骤索引无效")
		return
	var step: Dictionary = steps[step_index]
	_log_trainer_trace(
		"recv_response",
		pi,
		card_name,
		step,
		step_index,
		steps.size(),
		"selected=%s" % JSON.stringify(selected_indices)
	)
	var step_id: String = str(step.get("id", "step_%d" % step_index))
	_trace_net_event("trainer_response", "player=%d card=%s step_id=%s selected=%s context_keys=%s %s" % [
		pi,
		card_name,
		step_id,
		JSON.stringify(selected_indices),
		JSON.stringify(context.keys()),
		_net_turn_state_summary(),
	])
	context[step_id] = _build_step_selection_result(step, selected_indices)
	# 检查是否还有下一步
	var next_step_index: int = step_index + 1
	if next_step_index < steps.size():
		pending["step_index"] = next_step_index
		pending["context"] = context
		var serialized_steps := _serialize_interaction_steps(steps)
		var next_step: Dictionary = steps[next_step_index]
		var prompt_message := NetProtocol.make_trainer_interaction_prompt(serialized_steps, next_step_index, card_name, pi)
		var prompt_bytes := NetProtocol.dict_to_json_string(prompt_message).to_utf8_buffer().size()
		_log_trainer_trace(
			"send_prompt",
			pi,
			card_name,
			next_step,
			next_step_index,
			steps.size(),
			"after_selected=%s context_keys=%s bytes=%d" % [JSON.stringify(selected_indices), JSON.stringify(context.keys()), prompt_bytes]
		)
		_trace_net_event("trainer_prompt_sent", "player=%d card=%s step_id=%s steps=%d context_keys=%s bytes=%d %s" % [
			pi,
			card_name,
			str(next_step.get("id", "step_%d" % next_step_index)),
			steps.size(),
			JSON.stringify(context.keys()),
			prompt_bytes,
			_net_turn_state_summary(),
		])
		send_to_player.emit(pi, prompt_message)
		print("[GameRoom] player %d 训练家交互第 %d 步完成，发送第 %d 步" % [pi, step_index, next_step_index])
	else:
		# 全部步骤完成：执行训练家
		var card: CardInstance = pending["card"]
		_pending_trainer.erase(pi)
		var targets: Array = [context]
		_log_trainer_trace(
			"complete",
			pi,
			card_name,
			step,
			step_index,
			steps.size(),
			"selected=%s context_keys=%s" % [JSON.stringify(selected_indices), JSON.stringify(context.keys())]
		)
		var result: bool = _gsm.play_trainer(pi, card, targets)
		var player: PlayerState = _gsm.game_state.players[pi]
		_trace_net_event("trainer_complete", "player=%d card=%s result=%s in_hand=%s in_discard=%s context_keys=%s %s" % [
			pi,
			card.card_data.name if card != null and card.card_data != null else "?",
			str(result),
			str(card in player.hand),
			str(card in player.discard_pile),
			JSON.stringify(context.keys()),
			_net_turn_state_summary(),
		])
		print("[GameRoom] player %d 训练家 %s 交互完成，play_trainer 结果: %s" % [pi, card.card_data.name if card.card_data else "?", result])


func _step_uses_counter_distribution_selection(step: Dictionary) -> bool:
	return str(step.get("ui_mode", "")) == "counter_distribution" and step.has("target_items")


func _step_uses_assignment_selection(step: Dictionary) -> bool:
	if _step_uses_counter_distribution_selection(step):
		return false
	return str(step.get("ui_mode", step.get("presentation", ""))) == "card_assignment" or step.has("target_items")


func _build_step_selection_result(step: Dictionary, selected_indices: Array) -> Variant:
	if _step_uses_counter_distribution_selection(step):
		var target_items_raw: Array = step.get("target_items", [])
		var assignments: Array = []
		for pair_start in range(0, selected_indices.size(), 2):
			if pair_start + 1 >= selected_indices.size():
				continue
			var target_idx: int = int(selected_indices[pair_start])
			var amount: int = int(selected_indices[pair_start + 1])
			var target_item = target_items_raw[target_idx] if target_idx >= 0 and target_idx < target_items_raw.size() else null
			if target_item != null and amount > 0:
				assignments.append({"target": target_item, "amount": amount})
		return assignments
	if _step_uses_assignment_selection(step):
		var source_items_raw: Array = step.get("source_items", step.get("items", []))
		var target_items_raw: Array = step.get("target_items", [])
		var assignments: Array = []
		for pair_start in range(0, selected_indices.size(), 2):
			if pair_start + 1 >= selected_indices.size():
				continue
			var source_idx: int = int(selected_indices[pair_start])
			var target_idx: int = int(selected_indices[pair_start + 1])
			var source_item = source_items_raw[source_idx] if source_idx >= 0 and source_idx < source_items_raw.size() else null
			var target_item = target_items_raw[target_idx] if target_idx >= 0 and target_idx < target_items_raw.size() else null
			if source_item != null and target_item != null:
				assignments.append({"source": source_item, "target": target_item})
		return assignments
	var items_raw: Array = step.get("items", [])
	var selected_items: Array = []
	for sel_idx in selected_indices:
		var idx: int = int(sel_idx)
		if idx >= 0 and idx < items_raw.size():
			selected_items.append(items_raw[idx])
	return selected_items


func _serialize_interaction_item(item: Variant, label: String = "") -> Dictionary:
	if item is CardInstance:
		var card: CardInstance = item as CardInstance
		var card_data: CardData = card.card_data
		return {
			"type": "card",
			"instance_id": card.instance_id,
			"owner_index": card.owner_index,
			"name": card_data.name if card_data else "?",
			"card_name": card_data.name if card_data else "?",
			"label": card_data.label if card_data else "",
			"display_label": label,
			"card_type": card_data.card_type if card_data else "",
			"energy_type": card_data.energy_type if card_data else "",
			"energy_provides": card_data.energy_provides if card_data else "",
			"hp": card_data.hp if card_data else 0,
			"stage": card_data.stage if card_data else "",
			"evolves_from": card_data.evolves_from if card_data else "",
			"set_code": card_data.set_code if card_data else "",
			"card_index": card_data.card_index if card_data else "",
			"mechanic": card_data.mechanic if card_data else "",
			"effect_id": card_data.effect_id if card_data else "",
			"ancient_trait": card_data.ancient_trait if card_data else "",
			"is_tags": Array(card_data.is_tags) if card_data else [],
		}
	if item is PokemonSlot:
		var slot: PokemonSlot = item as PokemonSlot
		var top_card: CardInstance = slot.get_top_card()
		return {
			"type": "slot",
			"slot_ref": _find_slot_ref(slot),
			"top_instance_id": top_card.instance_id if top_card != null else -1,
			"name": slot.get_pokemon_name() if slot != null else "?",
			"display_label": label,
		}
	return {
		"type": "text",
		"label": label if label != "" else str(item),
	}


func _serialize_interaction_items(items: Array, labels: Array = []) -> Array:
	var serialized_items: Array = []
	for i in range(items.size()):
		var item = items[i]
		var label: String = str(labels[i]) if i < labels.size() else ""
		serialized_items.append(_serialize_interaction_item(item, label))
	return serialized_items


func _serialize_interaction_groups(raw_groups: Array) -> Array:
	var serialized_groups: Array = []
	for group_variant in raw_groups:
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = (group_variant as Dictionary).duplicate(true)
		if group.has("slot") and group["slot"] is PokemonSlot:
			group["slot_ref"] = _find_slot_ref(group["slot"])
			group.erase("slot")
		serialized_groups.append(group)
	return serialized_groups


func _serialize_interaction_steps(steps: Array) -> Array:
	var serialized: Array = []
	for step in steps:
		if not step is Dictionary:
			continue
		_trace_unserialized_step_keys(step as Dictionary)
		var s: Dictionary = {}
		s["id"] = step.get("id", "")
		s["title"] = step.get("title", "")
		s["min_select"] = int(step.get("min_select", 1))
		s["max_select"] = int(step.get("max_select", 1))
		s["allow_cancel"] = bool(step.get("allow_cancel", true))
		# 序列化 items
		var items_raw: Array = step.get("items", [])
		var labels: Array = step.get("labels", [])
		s["items"] = _serialize_interaction_items(items_raw, labels)
		s["labels"] = labels
		if step.has("source_items"):
			var source_items_raw: Array = step.get("source_items", [])
			var source_labels: Array = step.get("source_labels", [])
			s["source_items"] = _serialize_interaction_items(source_items_raw, source_labels)
			s["source_labels"] = source_labels
		if step.has("source_groups"):
			s["source_groups"] = _serialize_interaction_groups(step.get("source_groups", []))
		if step.has("source_card_items"):
			s["source_card_items"] = _serialize_interaction_items(step.get("source_card_items", []))
		if step.has("source_card_indices"):
			s["source_card_indices"] = step.get("source_card_indices", [])
		if step.has("source_choice_labels"):
			s["source_choice_labels"] = step.get("source_choice_labels", [])
		# 完整牌库搜索字段（兼容旧版卡牌选择步骤）
		if step.has("card_items"):
			s["card_items"] = _serialize_interaction_items(step.get("card_items", []))
		if step.has("card_indices"):
			s["card_indices"] = step.get("card_indices", [])
		if step.has("choice_labels"):
			s["choice_labels"] = step.get("choice_labels", [])
		for passthrough_key: String in [
			"presentation", "ui_mode", "visible_scope", "card_disabled_badge",
			"card_selectable_hint", "show_selectable_hints",
			"card_click_selectable", "utility_actions", "prompt_type",
			"single_target_only", "total_counters", "allow_partial",
			"max_assignments", "max_assignments_per_target",
			"source_exclude_targets", "source_visible_scope",
			"source_card_disabled_badge", "source_card_selectable_hint",
			"source_visible_count", "source_selectable_count",
		]:
			if step.has(passthrough_key):
				s[passthrough_key] = step.get(passthrough_key)
		# card_groups 包含 PokemonSlot 对象，需要序列化为 slot_ref
		if step.has("card_groups"):
			s["card_groups"] = _serialize_interaction_groups(step.get("card_groups", []))
		# 序列化 target_items（赋予招式等需要选择目标的步骤）
		if step.has("target_items"):
			s["target_items"] = _serialize_interaction_items(step.get("target_items", []), step.get("target_labels", []))
		if step.has("target_labels"):
			s["target_labels"] = step.get("target_labels", [])
		serialized.append(s)
	return serialized


func _trace_net_event(event_name: String, detail: String = "") -> void:
	var logs_dir := ProjectSettings.globalize_path("user://logs")
	DirAccess.make_dir_recursive_absolute(logs_dir)
	var file := FileAccess.open(NET_BATTLE_TRACE_LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		return
	file.seek_end()
	var line := "[%s] %s" % [Time.get_datetime_string_from_system(), event_name]
	if not detail.is_empty():
		line += " | %s" % detail
	file.store_line(line)
	file.close()


func _net_turn_state_summary() -> String:
	if _gsm == null or _gsm.game_state == null:
		return "gsm=null"
	return "turn=%d phase=%d current=%d pending_choice=%s" % [
		_gsm.game_state.turn_number,
		_gsm.game_state.phase,
		_gsm.game_state.current_player_index,
		str(_pending_choice.get("type", "")),
	]


func _pending_interaction_summary(player_index: int) -> String:
	var pending: Array[String] = []
	if _pending_trainer.has(player_index):
		pending.append("trainer")
	if _pending_attack.has(player_index):
		pending.append("attack")
	if _pending_ability.has(player_index):
		pending.append("ability")
	if _pending_stadium.has(player_index):
		pending.append("stadium")
	if _pending_granted_attack.has(player_index):
		pending.append("granted_attack")
	return ",".join(pending) if not pending.is_empty() else "-"


func _trace_unserialized_step_keys(step: Dictionary) -> void:
	var unknown_keys: Array[String] = []
	for key_variant: Variant in step.keys():
		var key := str(key_variant)
		if _SERIALIZED_INTERACTION_STEP_KEYS.has(key) or _IGNORED_UNSERIALIZED_INTERACTION_STEP_KEYS.has(key):
			continue
		unknown_keys.append(key)
	if unknown_keys.is_empty():
		return
	_trace_net_event("interaction_step_unserialized_keys", "step_id=%s ui=%s keys=%s" % [
		str(step.get("id", "")),
		str(step.get("ui_mode", step.get("presentation", "auto"))),
		JSON.stringify(unknown_keys),
	])


func _find_slot_ref(slot) -> Dictionary:
	if slot == null or _gsm == null or _gsm.game_state == null:
		return {}
	for pi in range(_gsm.game_state.players.size()):
		var player: PlayerState = _gsm.game_state.players[pi]
		if player.active_pokemon == slot:
			return NetProtocol.make_slot_ref(pi, "active", 0)
		for idx in range(player.bench.size()):
			if player.bench[idx] == slot:
				return NetProtocol.make_slot_ref(pi, "bench", idx)
	return {}


func _broadcast(message: Dictionary) -> void:
	for pi in _players.keys():
		send_to_player.emit(pi, message)


func _broadcast_state_update() -> void:
	if _gsm == null or _gsm.game_state == null:
		return
	var turn: int = _gsm.game_state.turn_number
	var cp: int = _gsm.game_state.current_player_index
	var phase: int = _gsm.game_state.phase
	print("[GameRoom] 广播状态: turn=%d, cp=%d, phase=%d" % [turn, cp, phase])
	for pi in _players.keys():
		var pending_choice_view := _build_pending_choice_view(_pending_choice)
		var state_view := _serializer.build_view_for_player(_gsm.game_state, pi, _last_action, pending_choice_view)
		send_to_player.emit(pi, NetProtocol.make_state_update(state_view, _last_action, pending_choice_view))
	# choice_prompt 必须在 state_update 之后发送，确保客户端先初始化 GSM 再显示对话框
	if _choice_prompt_needs_broadcast:
		_choice_prompt_needs_broadcast = false
		_broadcast_pending_choice()


func _broadcast_error(code: String, message: String) -> void:
	_broadcast(NetProtocol.make_error(code, message))


func _broadcast_pending_choice() -> void:
	if _pending_choice.is_empty():
		return
	var choice_type: String = str(_pending_choice.get("type", ""))
	var data: Dictionary = _pending_choice.get("data", {}) if _pending_choice.get("data") is Dictionary else {}
	if choice_type.is_empty():
		return
	# setup_ready 广播给双方（不带 target_player，客户端不做过滤）
	# 其他 choice 带 target_player 字段让客户端过滤
	if choice_type == "setup_ready":
		_broadcast(NetProtocol.make_choice_prompt(choice_type, data))
	else:
		var target_player := _resolve_choice_target(choice_type, data)
		var enriched_data: Dictionary = data.duplicate()
		enriched_data["target_player"] = target_player
		_broadcast(NetProtocol.make_choice_prompt(choice_type, enriched_data))


func _send_error_to(player_index: int, code: String, message: String) -> void:
	send_to_player.emit(player_index, NetProtocol.make_error(code, message))

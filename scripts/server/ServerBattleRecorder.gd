## 服务器端对局录制 - 记录完整对局到服务器磁盘
class_name ServerBattleRecorder
extends RefCounted

const BattleRecorderScript = preload("res://scripts/engine/BattleRecorder.gd")
const BattleEventBuilderScript = preload("res://scripts/engine/BattleEventBuilder.gd")

var _recorder: BattleRecorder
var _serializer: ServerSerializer
var _match_id: String = ""
var _match_dir: String = ""
var _meta: Dictionary = {}
var _player_names: Array = []
var _deck_names: Array = []


func _init() -> void:
	_recorder = BattleRecorderScript.new()
	_serializer = ServerSerializer.new()


func set_output_root(root_path: String) -> void:
	if _recorder != null:
		_recorder.set_output_root(root_path)


func start_recording(room_id: String, player_names: Array, deck_names: Array, first_player: int, initial_state: Dictionary = {}) -> void:
	_player_names = player_names.duplicate()
	_deck_names = deck_names.duplicate()
	_match_id = BattleEventBuilderScript.new().make_match_id()

	_meta = {
		"match_id": _match_id,
		"mode": "online",
		"room_id": room_id,
		"player_labels": player_names.duplicate(),
		"player_archetypes": {},
		"first_player_index": first_player,
		"deck_names": deck_names.duplicate(),
	}

	_recorder.start_match(_meta, _sanitize_for_recording(initial_state))


func record_state_snapshot(game_state: GameState, reason: String, turn_number: int = -1) -> void:
	if game_state == null:
		return
	var snapshot := _build_full_snapshot(game_state)
	snapshot["event_type"] = "state_snapshot"
	snapshot["snapshot_reason"] = reason
	if turn_number >= 0:
		snapshot["turn_number"] = turn_number
	else:
		snapshot["turn_number"] = game_state.turn_number
	# 枚举值必须转为 str，否则 BattleEventBuilder._string_field 会崩
	snapshot["phase"] = str(game_state.phase)
	snapshot["player_index"] = game_state.current_player_index
	_recorder.record_event(_sanitize_for_recording(snapshot))


func record_action(action, game_state: GameState = null) -> void:
	if action == null:
		return
	var event := _serializer.serialize_action(action)
	event["event_type"] = "action_resolved"
	# 确保有 turn_number 和 phase（枚举值转 str）
	if game_state != null:
		if not event.has("turn_number") or int(event.get("turn_number", 0)) == 0:
			event["turn_number"] = game_state.turn_number
		if not event.has("phase") or str(event.get("phase", "")).is_empty():
			event["phase"] = str(game_state.phase)
	_recorder.record_event(_sanitize_for_recording(event))


func record_choice_prompt(choice_type: String, data: Dictionary, player_index: int, game_state: GameState = null) -> void:
	var event := {
		"event_type": "choice_context",
		"choice_type": choice_type,
		"player_index": player_index,
		"data": _serializer.sanitize_recording_value(null, data),
	}
	if game_state != null:
		event["turn_number"] = game_state.turn_number
		event["phase"] = str(game_state.phase)
	_recorder.record_event(_sanitize_for_recording(event))


func finalize_recording(winner_index: int, reason: String, turn_count: int) -> void:
	var result := {
		"winner_index": winner_index,
		"reason": reason,
		"turn_count": turn_count,
		"player_names": _player_names.duplicate(),
		"deck_names": _deck_names.duplicate(),
	}
	_recorder.finalize_match(result)
	_match_dir = _recorder.get_match_dir()


func get_match_dir() -> String:
	return _match_dir


func get_match_id() -> String:
	return _match_id


## 构建完整状态快照（无信息隔离，用于服务器存储）
func _build_full_snapshot(game_state: GameState) -> Dictionary:
	var players_data: Array = []
	for i in range(game_state.players.size()):
		var player: PlayerState = game_state.players[i]
		players_data.append({
			"player_index": player.player_index,
			"hand_count": player.hand.size(),
			"hand": _serialize_card_list(player.hand),
			"deck": _serialize_card_list(player.deck),
			"deck_count": player.deck.size(),
			"prize_count": player.prizes.size(),
			"prizes": _serialize_prizes(player.prizes),
			"prize_layout": _serialize_prize_layout(player.get_prize_layout()),
			"discard_count": player.discard_pile.size(),
			"discard_pile": _serialize_card_list(player.discard_pile),
			"lost_zone": _serialize_card_list(player.lost_zone),
			"active": _serializer.serialize_pokemon_slot(player.active_pokemon),
			"bench": _serialize_slot_list(player.bench),
		})

	return {
		"turn_number": game_state.turn_number,
		"phase": game_state.phase,
		"current_player_index": game_state.current_player_index,
		"first_player_index": game_state.first_player_index,
		"winner_index": game_state.winner_index,
		"win_reason": game_state.win_reason,
		"energy_attached_this_turn": game_state.energy_attached_this_turn,
		"supporter_used_this_turn": game_state.supporter_used_this_turn,
		"stadium_played_this_turn": game_state.stadium_played_this_turn,
		"retreat_used_this_turn": game_state.retreat_used_this_turn,
		"stadium_card": _serializer.serialize_card_instance(game_state.stadium_card) if game_state.stadium_card else {},
		"stadium_owner_index": game_state.stadium_owner_index,
		"stadium_effect_used_turn": game_state.stadium_effect_used_turn,
		"stadium_effect_used_player": game_state.stadium_effect_used_player,
		"stadium_effect_used_effect_id": game_state.stadium_effect_used_effect_id,
		"vstar_power_used": game_state.vstar_power_used.duplicate(),
		"last_knockout_turn_against": game_state.last_knockout_turn_against.duplicate(),
		"shared_turn_flags": game_state.shared_turn_flags.duplicate(true),
		"players": players_data,
	}


func _serialize_card_list(cards: Array) -> Array:
	var result: Array = []
	for card in cards:
		if card == null:
			continue
		result.append(_serializer.serialize_card_instance(card))
	return result


func _serialize_prizes(prizes: Array) -> Array:
	var result: Array = []
	for card in prizes:
		if card == null:
			continue
		var card_dict: Dictionary = _serializer.serialize_card_instance(card)
		card_dict["face_up"] = false
		result.append(card_dict)
	return result


func _serialize_prize_layout(prize_layout: Array) -> Array:
	var result: Array = []
	for entry: Variant in prize_layout:
		if entry == null:
			result.append(null)
			continue
		if not (entry is CardInstance):
			result.append(null)
			continue
		var card_dict: Dictionary = _serializer.serialize_card_instance(entry as CardInstance)
		card_dict["face_up"] = false
		result.append(card_dict)
	return result


func _serialize_slot_list(slots: Array) -> Array:
	var result: Array = []
	for slot in slots:
		if slot == null:
			continue
		result.append(_serializer.serialize_pokemon_slot(slot))
	return result


## 递归清理数据，确保所有值都是 JSON 安全的原始类型
func _sanitize_for_recording(value: Variant) -> Variant:
	if value == null:
		return null
	if value is Dictionary:
		var out := {}
		for k in value.keys():
			var v = _sanitize_for_recording(value[k])
			if v != null:
				out[str(k)] = v
		return out
	if value is Array:
		var out: Array = []
		for item in value:
			var v = _sanitize_for_recording(item)
			if v != null:
				out.append(v)
		return out
	if value is bool or value is int or value is float or value is String:
		return value
	# 枚举、StringName、其他类型一律转 str
	return str(value)

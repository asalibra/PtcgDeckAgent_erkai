## 服务器端序列化 - GameState → Dictionary，含信息隔离（隐藏对手手牌/牌库）
class_name ServerSerializer
extends RefCounted


## 构建指定玩家可见的状态快照
func build_view_for_player(game_state: GameState, player_index: int, last_action: Dictionary = {}, pending_choice: Dictionary = {}) -> Dictionary:
	var players_data: Array = []
	for i in range(game_state.players.size()):
		players_data.append(_build_player_view(game_state, game_state.players[i], i, player_index))

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
		"stadium_card": _serialize_card(game_state.stadium_card),
		"stadium_owner_index": game_state.stadium_owner_index,
		"vstar_power_used": game_state.vstar_power_used.duplicate(),
		"players": players_data,
		"last_action": last_action,
		"pending_choice": pending_choice,
	}


func _build_player_view(current_state: GameState, player: PlayerState, view_of: int, requesting_player: int) -> Dictionary:
	var is_self: bool = (view_of == requesting_player)
	var hide_face_down_in_play: bool = _should_hide_face_down_opponent_in_play(current_state)
	# 对手的 active 在 face_up=false 时（setup 阶段）隐藏详情
	var active_slot = player.active_pokemon
	if not is_self and hide_face_down_in_play and active_slot != null:
		var top_card = active_slot.get_top_card() if active_slot.get_top_card() != null else null
		if top_card != null and not top_card.face_up:
			active_slot = null  # 隐藏对手未翻开的战斗宝可梦
	# 对手的 bench 在 face_up=false 时也隐藏
	var bench_slots: Array = player.bench
	if not is_self and hide_face_down_in_play:
		var visible_bench: Array = []
		for slot in bench_slots:
			if slot != null:
				var top = slot.get_top_card()
				if top != null and top.face_up:
					visible_bench.append(slot)
		bench_slots = visible_bench
	return {
		"player_index": player.player_index,
		"hand_count": player.hand.size(),
		"deck_count": player.deck.size(),
		"discard_count": player.discard_pile.size(),
		"prize_count": player.prizes.size(),
		"hand": _serialize_hand(player.hand, is_self),
		"deck": [],
		"prizes": _serialize_prizes(player.prizes, is_self),
		"prize_layout": _serialize_prize_layout(player.get_prize_layout(), is_self, player.player_index),
		"discard_pile": _serialize_card_list(player.discard_pile),
		"lost_zone": _serialize_card_list(player.lost_zone),
		"active": _serialize_slot(active_slot),
		"bench": _serialize_slot_list(bench_slots),
	}


func _should_hide_face_down_opponent_in_play(current_state: GameState) -> bool:
	if current_state == null:
		return true
	return current_state.phase in [
		GameState.GamePhase.SETUP,
		GameState.GamePhase.MULLIGAN,
		GameState.GamePhase.SETUP_PLACE,
	]


func _serialize_hand(hand: Array, is_self: bool) -> Array:
	if is_self:
		return _serialize_card_list(hand)
	return []


func _serialize_prizes(prizes: Array, is_self: bool) -> Array:
	if is_self:
		var result: Array = []
		for card in prizes:
			if card == null:
				continue
			var card_dict: Dictionary = _serialize_card(card)
			card_dict["face_up"] = false
			result.append(card_dict)
		return result
	return []


func _serialize_prize_layout(prize_layout: Array, is_self: bool, owner_index: int) -> Array:
	var result: Array = []
	for entry: Variant in prize_layout:
		if entry == null:
			result.append(null)
			continue
		if not (entry is CardInstance):
			result.append(null)
			continue
		var card: CardInstance = entry as CardInstance
		if is_self:
			var card_dict: Dictionary = _serialize_card(card)
			card_dict["face_up"] = false
			result.append(card_dict)
		else:
			result.append(_serialize_hidden_prize_card(card, owner_index))
	return result


func _serialize_hidden_prize_card(card: CardInstance, owner_index: int) -> Dictionary:
	return {
		"card_name": "Prize",
		"instance_id": card.instance_id if card != null else -1,
		"owner_index": owner_index,
		"face_up": false,
		"card_type": "Prize",
		"mechanic": "",
		"description": "",
		"stage": "",
		"hp": 0,
		"energy_type": "",
		"effect_id": "",
		"energy_provides": "",
		"set_code": "",
		"card_index": "",
		"evolves_from": "",
		"weakness_energy": "",
		"weakness_value": "",
		"resistance_energy": "",
		"resistance_value": "",
		"retreat_cost": 0,
		"attacks": [],
		"abilities": [],
	}


func _serialize_card_list(cards: Array) -> Array:
	var result: Array = []
	for card in cards:
		if card == null:
			continue
		result.append(_serialize_card(card))
	return result


func _serialize_card(card) -> Dictionary:
	if card == null:
		return {}
	return serialize_card_instance(card)


func _serialize_slot(slot) -> Dictionary:
	if slot == null:
		return {}
	return serialize_pokemon_slot(slot)


func _serialize_slot_list(slots: Array) -> Array:
	var result: Array = []
	for slot in slots:
		if slot == null:
			continue
		result.append(_serialize_slot(slot))
	return result


## 序列化 GameAction 用于 last_action
func serialize_action(action) -> Dictionary:
	if action == null:
		return {}
	var result := {
		"action_type": str(action.action_type),
		"player_index": action.player_index,
		"description": action.description,
	}
	if action.data is Dictionary:
		result["data"] = sanitize_recording_value(null, action.data)
	return result


## 序列化抽牌信息（仅发给抽牌者）
func serialize_draw_cards(cards: Array) -> Array:
	var result: Array = []
	for card in cards:
		if card == null:
			continue
		result.append({
			"instance_id": card.instance_id,
			"card_name": card.card_data.card_name if card.card_data else "",
			"set_code": card.card_data.set_code if card.card_data else "",
			"card_index": card.card_data.card_index if card.card_data else "",
		})
	return result


# ===================== 内联序列化方法（原 BattleRecordingController） =====================

func serialize_card_instance(card: CardInstance) -> Dictionary:
	if card == null:
		return {}
	var card_data := card.card_data
	var tags: Array = Array(card_data.is_tags) if card_data != null else []
	return {
		"name": card_data.name if card_data != null else "",
		"card_name": card_data.name if card_data != null else "",
		"instance_id": card.instance_id,
		"owner_index": card.owner_index,
		"face_up": card.face_up,
		"card_type": card_data.card_type if card_data != null else "",
		"mechanic": card_data.mechanic if card_data != null else "",
		"label": card_data.label if card_data != null else "",
		"yoren_code": card_data.yoren_code if card_data != null else "",
		"set_code_en": card_data.set_code_en if card_data != null else "",
		"card_index_en": card_data.card_index_en if card_data != null else "",
		"name_en": card_data.name_en if card_data != null else "",
		"artist": card_data.artist if card_data != null else "",
		"rarity": card_data.rarity if card_data != null else "",
		"release_date": card_data.release_date if card_data != null else "",
		"regulation_mark": card_data.regulation_mark if card_data != null else "",
		"image_url": card_data.image_url if card_data != null else "",
		"image_local_path": card_data.image_local_path if card_data != null else "",
		"ancient_trait": card_data.ancient_trait if card_data != null else "",
		"is_tags": tags.duplicate(),
		"regulation_standard": card_data.regulation_standard if card_data != null else true,
		"regulation_expanded": card_data.regulation_expanded if card_data != null else true,
		"description": card_data.description if card_data != null else "",
		"stage": card_data.stage if card_data != null else "",
		"hp": card_data.hp if card_data != null else 0,
		"energy_type": card_data.energy_type if card_data != null else "",
		"effect_id": card_data.effect_id if card_data != null else "",
		"energy_provides": card_data.energy_provides if card_data != null else "",
		"set_code": card_data.set_code if card_data != null else "",
		"card_index": card_data.card_index if card_data != null else "",
		"evolves_from": card_data.evolves_from if card_data != null else "",
		"weakness_energy": card_data.weakness_energy if card_data != null else "",
		"weakness_value": card_data.weakness_value if card_data != null else "",
		"resistance_energy": card_data.resistance_energy if card_data != null else "",
		"resistance_value": card_data.resistance_value if card_data != null else "",
		"retreat_cost": card_data.retreat_cost if card_data != null else 0,
		"attacks": card_data.attacks.duplicate(true) if card_data != null else [],
		"abilities": card_data.abilities.duplicate(true) if card_data != null else [],
	}


func serialize_pokemon_slot(slot: PokemonSlot) -> Dictionary:
	if slot == null:
		return {}
	return {
		"pokemon_name": slot.get_pokemon_name(),
		"prize_count": slot.get_prize_count(),
		"damage_counters": slot.damage_counters,
		"remaining_hp": slot.get_remaining_hp(),
		"max_hp": slot.get_max_hp(),
		"retreat_cost": slot.get_retreat_cost(),
		"attached_energy": _serialize_card_list(slot.attached_energy),
		"attached_tool": serialize_card_instance(slot.attached_tool),
		"status_conditions": slot.status_conditions.duplicate(true),
		"effects": slot.effects.duplicate(true),
		"turn_played": slot.turn_played,
		"turn_evolved": slot.turn_evolved,
		"pokemon_stack": _serialize_card_list(slot.pokemon_stack),
	}


func sanitize_recording_value(_scene: Object, value: Variant) -> Variant:
	if value is Dictionary:
		var sanitized_dict := {}
		for key: Variant in (value as Dictionary).keys():
			sanitized_dict[str(key)] = sanitize_recording_value(_scene, (value as Dictionary).get(key))
		return sanitized_dict
	if value is Array:
		var sanitized_array: Array = []
		for entry: Variant in value:
			sanitized_array.append(sanitize_recording_value(_scene, entry))
		return sanitized_array
	if value is PokemonSlot:
		return serialize_pokemon_slot(value)
	if value is CardInstance:
		return serialize_card_instance(value)
	if value is CardData:
		var card_data: CardData = value
		return {
			"card_name": card_data.name,
			"card_type": card_data.card_type,
			"mechanic": card_data.mechanic,
			"description": card_data.description,
			"stage": card_data.stage,
			"hp": card_data.hp,
			"energy_type": card_data.energy_type,
			"effect_id": card_data.effect_id,
			"energy_provides": card_data.energy_provides,
			"attacks": card_data.attacks.duplicate(true),
			"abilities": card_data.abilities.duplicate(true),
		}
	return value

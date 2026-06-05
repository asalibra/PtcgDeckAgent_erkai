extends Control

const DEFAULT_CARD_LIST_HINT := "逗号分隔卡名，支持 *数量，例如：基础超能量*3, 博士的研究"
const MAX_FUZZY_SCAN := 240

var _all_cards: Array[CardData] = []
var _uid_index: Dictionary = {}
var _name_index: Dictionary = {}
var _next_instance_id: int = 900000000


func _ready() -> void:
	_build_card_lookup()
	%HintLabel.text = DEFAULT_CARD_LIST_HINT
	%StartBtn.pressed.connect(_on_start_pressed)
	%BackBtn.pressed.connect(_on_back_pressed)
	%StatusLabel.text = "填写后点击“开始验证局”"


func _on_back_pressed() -> void:
	GameManager.goto_main_menu()


func _on_start_pressed() -> void:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var snapshot := _build_snapshot(errors, warnings)
	if not errors.is_empty():
		%StatusLabel.text = "配置有误：\n- %s" % "\n- ".join(errors)
		return
	if snapshot.is_empty():
		%StatusLabel.text = "无法构建验证局状态"
		return

	var launch := {
		"raw_snapshot": snapshot,
		"view_player_index": 0,
		"entry_source": "quick_validation",
	}
	GameManager.current_mode = GameManager.GameMode.TWO_PLAYER
	GameManager.first_player_choice = 0
	GameManager.clear_battle_player_display_names()
	GameManager.set_quick_validation_launch(launch)
	GameManager.goto_battle()

	if warnings.is_empty():
		%StatusLabel.text = "已启动验证局"
	else:
		%StatusLabel.text = "已启动验证局（提示：%s）" % "；".join(warnings)


func _build_snapshot(errors: Array[String], warnings: Array[String]) -> Dictionary:
	_next_instance_id = 900000000
	var my_active: CardData = _resolve_required_pokemon(%MyActiveEdit.text, "我方上场宝可梦", errors)
	var opp_active: CardData = _resolve_required_pokemon(%OppActiveEdit.text, "敌方上场宝可梦", errors)
	if my_active == null or opp_active == null:
		return {}

	var my_hand: Array[Dictionary] = _resolve_cards_from_text(%MyHandEdit.text, 0, true, "我方手牌", errors)
	var my_deck: Array[Dictionary] = _resolve_cards_from_text(%MyDeckEdit.text, 0, false, "我方牌库", errors)
	var my_prizes: Array[Dictionary] = _resolve_cards_from_text(%MyPrizeEdit.text, 0, false, "我方奖赏卡", errors)
	var opp_hand: Array[Dictionary] = _resolve_cards_from_text(%OppHandEdit.text, 1, true, "敌方手牌", errors)
	var opp_deck: Array[Dictionary] = _resolve_cards_from_text(%OppDeckEdit.text, 1, false, "敌方牌库", errors)
	var opp_prizes: Array[Dictionary] = _resolve_cards_from_text(%OppPrizeEdit.text, 1, false, "敌方奖赏卡", errors)

	if my_hand.is_empty():
		warnings.append("我方手牌为空，进入后无法直接打手牌")
	if my_deck.is_empty() or opp_deck.is_empty():
		warnings.append("有玩家牌库为空，继续回合可能触发抽牌失败")

	if not errors.is_empty():
		return {}

	var players: Array = [
		_build_player_snapshot(0, my_active, my_hand, my_deck, my_prizes),
		_build_player_snapshot(1, opp_active, opp_hand, opp_deck, opp_prizes),
	]

	return {
		"format_version": 1,
		"turn_number": 1,
		"current_player_index": 0,
		"first_player_index": 0,
		"phase": "main",
		"winner_index": -1,
		"win_reason": "",
		"energy_attached_this_turn": false,
		"supporter_used_this_turn": false,
		"stadium_played_this_turn": false,
		"retreat_used_this_turn": false,
		"stadium_card": {},
		"stadium_owner_index": -1,
		"stadium_effect_used_turn": -1,
		"stadium_effect_used_player": -1,
		"stadium_effect_used_effect_id": "",
		"vstar_power_used": [false, false],
		"last_knockout_turn_against": [-999, -999],
		"shared_turn_flags": {},
		"players": players,
	}


func _build_player_snapshot(
	player_index: int,
	active_card: CardData,
	hand_cards: Array[Dictionary],
	deck_cards: Array[Dictionary],
	prize_cards: Array[Dictionary]
) -> Dictionary:
	return {
		"player_index": player_index,
		"active": _build_active_slot_snapshot(active_card, player_index),
		"bench": [],
		"hand": hand_cards,
		"deck": deck_cards,
		"discard": [],
		"discard_pile": [],
		"prizes": prize_cards,
		"prize_layout": [],
		"lost_zone": [],
		"shuffle_count": 0,
	}


func _build_active_slot_snapshot(card: CardData, owner_index: int) -> Dictionary:
	var hp := max(10, int(card.hp))
	return {
		"pokemon_name": card.name,
		"prize_count": card.get_prize_count(),
		"damage_counters": 0,
		"remaining_hp": hp,
		"max_hp": hp,
		"retreat_cost": int(card.retreat_cost),
		"attached_energy": [],
		"attached_tool": {},
		"status_conditions": {},
		"effects": [],
		"turn_played": 0,
		"turn_evolved": -1,
		"pokemon_stack": [_snapshot_card(card, owner_index, true)],
	}


func _resolve_required_pokemon(raw_name: String, field_name: String, errors: Array[String]) -> CardData:
	var card := _find_card(raw_name, true)
	if card == null:
		errors.append("%s 未匹配到宝可梦：%s" % [field_name, raw_name.strip_edges()])
	return card


func _resolve_cards_from_text(
	raw_text: String,
	owner_index: int,
	face_up: bool,
	field_name: String,
	errors: Array[String]
) -> Array[Dictionary]:
	var resolved: Array[Dictionary] = []
	var tokens: Array[String] = _tokenize_card_text(raw_text)
	for token: String in tokens:
		var parsed := _parse_count_token(token)
		var card_name := str(parsed.get("name", "")).strip_edges()
		var count := max(1, int(parsed.get("count", 1)))
		var card := _find_card(card_name)
		if card == null:
			errors.append("%s 未匹配到卡牌：%s" % [field_name, card_name])
			continue
		for _i: int in count:
			resolved.append(_snapshot_card(card, owner_index, face_up))
	return resolved


func _tokenize_card_text(raw_text: String) -> Array[String]:
	var normalized := raw_text.replace("\r", "\n")
	normalized = normalized.replace("，", ",")
	normalized = normalized.replace("；", ",")
	normalized = normalized.replace(";", ",")
	normalized = normalized.replace("\n", ",")
	var tokens: Array[String] = []
	for part_variant: Variant in normalized.split(","):
		var part := str(part_variant).strip_edges()
		if not part.is_empty():
			tokens.append(part)
	return tokens


func _parse_count_token(token: String) -> Dictionary:
	var clean := token.strip_edges()
	var split_index := clean.rfind("*")
	if split_index <= 0:
		return {
			"name": clean,
			"count": 1,
		}
	var count_text := clean.substr(split_index + 1).strip_edges()
	if not count_text.is_valid_int():
		return {
			"name": clean,
			"count": 1,
		}
	return {
		"name": clean.substr(0, split_index).strip_edges(),
		"count": max(1, int(count_text)),
	}


func _snapshot_card(card: CardData, owner_index: int, face_up: bool) -> Dictionary:
	var payload := card.to_dict()
	payload["instance_id"] = _next_instance_id
	payload["owner_index"] = owner_index
	payload["face_up"] = face_up
	payload["card_name"] = card.name
	_next_instance_id += 1
	return payload


func _build_card_lookup() -> void:
	_all_cards = CardDatabase.get_all_cards()
	_uid_index.clear()
	_name_index.clear()
	for card: CardData in _all_cards:
		if card == null:
			continue
		_uid_index[str(card.get_uid()).to_lower()] = card
		_index_card_name(card.name, card)
		_index_card_name(card.name_en, card)


func _index_card_name(raw_name: String, card: CardData) -> void:
	var key := _normalize_key(raw_name)
	if key.is_empty():
		return
	if not _name_index.has(key):
		_name_index[key] = []
	(_name_index[key] as Array).append(card)


func _find_card(query: String, require_pokemon: bool = false) -> CardData:
	var trimmed := query.strip_edges()
	if trimmed.is_empty():
		return null

	var uid_key := trimmed.to_lower()
	if _uid_index.has(uid_key):
		var uid_card: CardData = _uid_index[uid_key]
		if not require_pokemon or uid_card.is_pokemon():
			return uid_card

	var key := _normalize_key(trimmed)
	if _name_index.has(key):
		for card_variant: Variant in (_name_index[key] as Array):
			var candidate: CardData = card_variant
			if candidate != null and (not require_pokemon or candidate.is_pokemon()):
				return candidate

	var scanned := 0
	for card: CardData in _all_cards:
		if card == null:
			continue
		if require_pokemon and not card.is_pokemon():
			continue
		var zh_key := _normalize_key(card.name)
		var en_key := _normalize_key(card.name_en)
		if zh_key.contains(key) or en_key.contains(key):
			return card
		scanned += 1
		if scanned >= MAX_FUZZY_SCAN and key.length() <= 2:
			break
	return null


func _normalize_key(raw_text: String) -> String:
	var key := raw_text.strip_edges().to_lower()
	for ch: String in [" ", "\t", "-", "_", "·", ".", "'", "’", "\"", "`", "（", "）", "(", ")", "[", "]", "/"]:
		key = key.replace(ch, "")
	return key

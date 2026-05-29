## 网络对战通信协议 - 客户端/服务端共用常量和消息构建工具
class_name NetProtocol
extends RefCounted

# ===================== 消息类型 =====================

## 客户端→服务器
const MSG_CREATE_ROOM := "create_room"
const MSG_JOIN_ROOM := "join_room"
const MSG_LIST_ROOMS := "list_rooms"
const MSG_SELECT_DECK := "select_deck"
const MSG_SET_READY := "set_ready"
const MSG_START_GAME := "start_game"
const MSG_ACTION := "action"
const MSG_CHOICE_RESPONSE := "choice_response"
const MSG_RECONNECT := "reconnect"
const MSG_LEAVE_ROOM := "leave_room"
const MSG_PONG := "pong"
const MSG_SAVE_DECK := "save_deck"       # 保存/更新牌组到服务器
const MSG_DELETE_DECK := "delete_deck"   # 从服务器删除牌组
const MSG_LIST_DECKS := "list_decks"     # 获取服务器牌组列表
const MSG_LIST_REPLAYS := "list_replays" # 获取对局回放列表
const MSG_GET_REPLAY := "get_replay"     # 获取单个回放详情

## 服务器→客户端
const MSG_ROOM_LIST := "room_list"
const MSG_ROOM_CREATED := "room_created"
const MSG_ROOM_JOINED := "room_joined"
const MSG_ROOM_UPDATE := "room_update"
const MSG_GAME_STARTING := "game_starting"
const MSG_STATE_UPDATE := "state_update"
const MSG_CHOICE_PROMPT := "choice_prompt"
const MSG_DRAW_REVEAL := "draw_reveal"
const MSG_GAME_OVER := "game_over"
const MSG_ERROR := "error"
const MSG_PING := "ping"
const MSG_OPPONENT_DISCONNECTED := "opponent_disconnected"
const MSG_OPPONENT_RECONNECTED := "opponent_reconnected"
const MSG_RECONNECTED := "reconnected"  # 服务器确认重连成功
const MSG_DECK_LIST := "deck_list"       # 服务器牌组列表响应
const MSG_DECK_SAVED := "deck_saved"     # 牌组保存成功
const MSG_REPLAY_LIST := "replay_list"   # 对局回放列表响应
const MSG_REPLAY_DATA := "replay_data"   # 单个回放详情响应
const MSG_REPLAY_DETAIL_CHUNK := "replay_detail_chunk"   # 单个回放 detail.jsonl 分块响应

# ===================== Action 类型 =====================

const ACTION_SETUP_PLACE_ACTIVE := "setup_place_active"
const ACTION_SETUP_PLACE_BENCH := "setup_place_bench"
const ACTION_SETUP_COMPLETE := "setup_complete"
const ACTION_PLAY_BASIC_TO_BENCH := "play_basic_to_bench"
const ACTION_EVOLVE := "evolve"
const ACTION_ATTACH_ENERGY := "attach_energy"
const ACTION_ATTACH_TOOL := "attach_tool"
const ACTION_PLAY_TRAINER := "play_trainer"
const ACTION_PLAY_STADIUM := "play_stadium"
const ACTION_USE_STADIUM_EFFECT := "use_stadium_effect"
const ACTION_RETREAT := "retreat"
const ACTION_USE_ATTACK := "use_attack"
const ACTION_USE_GRANTED_ATTACK := "use_granted_attack"
const ACTION_USE_ABILITY := "use_ability"
const ACTION_END_TURN := "end_turn"
const ACTION_RESOLVE_MULLIGAN_CHOICE := "resolve_mulligan_choice"
const ACTION_RESOLVE_TAKE_PRIZE := "resolve_take_prize"
const ACTION_SEND_OUT_POKEMON := "send_out_pokemon"
const ACTION_RESOLVE_HEAVY_BATON := "resolve_heavy_baton"
const ACTION_RESOLVE_EXP_SHARE := "resolve_exp_share"

# ===================== Choice 类型 =====================

const CHOICE_MULLIGAN_EXTRA_DRAW := "mulligan_extra_draw"
const CHOICE_SETUP_READY := "setup_ready"
const CHOICE_TAKE_PRIZE := "take_prize"
const CHOICE_SEND_OUT_POKEMON := "send_out_pokemon"
const CHOICE_HEAVY_BATON_TARGET := "heavy_baton_target"
const CHOICE_EXP_SHARE_TARGET := "exp_share_target"
const CHOICE_TRAINER_INTERACTION := "trainer_interaction"

# ===================== 房间状态 =====================

const ROOM_STATE_WAITING := "waiting"
const ROOM_STATE_PLAYING := "playing"
const ROOM_STATE_FINISHED := "finished"

# ===================== 协议元数据 =====================

const PROTOCOL_VERSION := 2
const INVALID_STATE_SEQ := -1

const META_REQUEST_ID := "request_id"
const META_STATE_SEQ := "state_seq"
const META_VERSION := "version"
const META_RESYNC_REQUIRED := "resync_required"

# ===================== 消息构建工具 =====================

static func make_message(type: String, payload: Dictionary = {}, meta: Dictionary = {}) -> Dictionary:
	return {
		"type": type,
		"payload": payload,
		META_VERSION: int(meta.get(META_VERSION, PROTOCOL_VERSION)),
		META_REQUEST_ID: str(meta.get(META_REQUEST_ID, "")),
		META_STATE_SEQ: int(meta.get(META_STATE_SEQ, INVALID_STATE_SEQ)),
		META_RESYNC_REQUIRED: bool(meta.get(META_RESYNC_REQUIRED, false)),
	}


static func with_request_id(message: Dictionary, request_id: String) -> Dictionary:
	return with_meta(message, {META_REQUEST_ID: request_id})


static func with_state_seq(message: Dictionary, state_seq: int) -> Dictionary:
	return with_meta(message, {META_STATE_SEQ: state_seq})


static func with_resync_required(message: Dictionary, required: bool = true) -> Dictionary:
	return with_meta(message, {META_RESYNC_REQUIRED: required})


static func with_meta(message: Dictionary, meta: Dictionary) -> Dictionary:
	var result := message.duplicate(true)
	result[META_VERSION] = int(meta.get(META_VERSION, int(result.get(META_VERSION, PROTOCOL_VERSION))))
	result[META_REQUEST_ID] = str(meta.get(META_REQUEST_ID, str(result.get(META_REQUEST_ID, ""))))
	result[META_STATE_SEQ] = int(meta.get(META_STATE_SEQ, int(result.get(META_STATE_SEQ, INVALID_STATE_SEQ))))
	result[META_RESYNC_REQUIRED] = bool(meta.get(META_RESYNC_REQUIRED, bool(result.get(META_RESYNC_REQUIRED, false))))
	return result


static func is_version_compatible(message: Dictionary) -> bool:
	return int(message.get(META_VERSION, PROTOCOL_VERSION)) == PROTOCOL_VERSION


static func get_request_id(message: Dictionary) -> String:
	return str(message.get(META_REQUEST_ID, ""))


static func get_state_seq(message: Dictionary) -> int:
	return int(message.get(META_STATE_SEQ, INVALID_STATE_SEQ))


static func is_resync_required(message: Dictionary) -> bool:
	return bool(message.get(META_RESYNC_REQUIRED, false))

static func make_error(code: String, message: String) -> Dictionary:
	return make_message(MSG_ERROR, {"code": code, "message": message})

static func make_room_created(room_id: String, player_index: int, session_token: String) -> Dictionary:
	return make_message(MSG_ROOM_CREATED, {
		"room_id": room_id,
		"player_index": player_index,
		"session_token": session_token,
	})

static func make_room_joined(room_id: String, player_index: int, session_token: String, opponent_name: String = "") -> Dictionary:
	return make_message(MSG_ROOM_JOINED, {
		"room_id": room_id,
		"player_index": player_index,
		"session_token": session_token,
		"opponent_name": opponent_name,
	})

static func make_room_update(opponent_name: String, opponent_ready: bool) -> Dictionary:
	return make_message(MSG_ROOM_UPDATE, {
		"opponent_name": opponent_name,
		"opponent_ready": opponent_ready,
	})

static func make_reconnected(room_id: String, player_index: int, opponent_name: String, opponent_ready: bool, room_state: String = ROOM_STATE_WAITING) -> Dictionary:
	return make_message(MSG_RECONNECTED, {
		"room_id": room_id,
		"player_index": player_index,
		"opponent_name": opponent_name,
		"opponent_ready": opponent_ready,
		"room_state": room_state,
	})

static func make_game_starting(first_player_index: int, your_player_index: int) -> Dictionary:
	return make_message(MSG_GAME_STARTING, {
		"first_player_index": first_player_index,
		"your_player_index": your_player_index,
	})

static func make_state_update(state: Dictionary, last_action: Dictionary = {}, pending_choice: Dictionary = {}) -> Dictionary:
	return make_message(MSG_STATE_UPDATE, {
		"state": state,
		"last_action": last_action,
		"pending_choice": pending_choice,
	})

static func make_choice_prompt(choice_type: String, data: Dictionary) -> Dictionary:
	return make_message(MSG_CHOICE_PROMPT, {
		"choice_type": choice_type,
		"data": data,
	})

static func make_draw_reveal(player_index: int, cards: Array) -> Dictionary:
	return make_message(MSG_DRAW_REVEAL, {
		"player_index": player_index,
		"cards": cards,
	})

static func make_game_over(winner_index: int, reason: String) -> Dictionary:
	return make_message(MSG_GAME_OVER, {
		"winner_index": winner_index,
		"reason": reason,
	})

static func make_action(action_type: String, params: Dictionary = {}) -> Dictionary:
	return make_message(MSG_ACTION, {
		"action_type": action_type,
		"params": params,
	})

static func make_choice_response(choice_type: String, data: Dictionary = {}) -> Dictionary:
	return make_message(MSG_CHOICE_RESPONSE, {
		"choice_type": choice_type,
		"data": data,
	})

static func make_trainer_interaction_prompt(steps: Array, step_index: int, card_name: String, target_player: int) -> Dictionary:
	return make_choice_prompt(CHOICE_TRAINER_INTERACTION, {
		"steps": steps,
		"step_index": step_index,
		"card_name": card_name,
		"target_player": target_player,
	})

# ===================== 牌组工具 =====================

static func make_deck_list(decks: Array) -> Dictionary:
	return make_message(MSG_DECK_LIST, {"decks": decks})

static func make_deck_saved(deck_id: int) -> Dictionary:
	return make_message(MSG_DECK_SAVED, {"deck_id": deck_id})

# ===================== 回放工具 =====================

static func make_replay_list(replays: Array) -> Dictionary:
	return make_message(MSG_REPLAY_LIST, {"replays": replays})

static func make_replay_data(replay: Dictionary) -> Dictionary:
	return make_message(MSG_REPLAY_DATA, replay)


static func make_replay_detail_chunk(match_id: String, chunk_index: int, total_chunks: int, detail_events: Array) -> Dictionary:
	return make_message(MSG_REPLAY_DETAIL_CHUNK, {
		"match_id": match_id,
		"chunk_index": chunk_index,
		"total_chunks": total_chunks,
		"detail_events": detail_events,
	})

# ===================== SlotRef 工具 =====================

static func make_slot_ref(player_index: int, slot_kind: String, slot_index: int = 0) -> Dictionary:
	return {"player_index": player_index, "slot_kind": slot_kind, "slot_index": slot_index}

static func slot_ref_to_string(ref: Dictionary) -> String:
	return "%d_%s_%d" % [ref.get("player_index", 0), ref.get("slot_kind", ""), ref.get("slot_index", 0)]

# ===================== 序列化工具 =====================

static func dict_to_json_string(data: Dictionary) -> String:
	return JSON.stringify(data)

static func json_string_to_dict(json_str: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(json_str) != OK:
		return {}
	var result = json.data
	if result is Dictionary:
		return result
	return {}

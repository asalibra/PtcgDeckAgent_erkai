## 房间管理器 - 房间 CRUD、消息路由、session 管理
class_name RoomManager
extends RefCounted

var _rooms: Dictionary = {}  # room_id -> GameRoom
var _server_decks: Dictionary = {}  # deck_id -> deck_dict（服务器端牌组存储）
var _server_decks_dir := "user://server_decks/"
var _player_sessions: Dictionary = {}  # peer_id -> PlayerSession
var _session_tokens: Dictionary = {}  # session_token -> PlayerSession
var _peer_to_room: Dictionary = {}  # peer_id -> room_id

var _send_to_peer_callback: Callable
var _card_db: Node  # CardDatabase 实例


func setup(send_callback: Callable, card_db: Node = null) -> void:
	_send_to_peer_callback = send_callback
	_card_db = card_db


func handle_message(peer_id: int, message: Dictionary) -> void:
	var type: String = str(message.get("type", ""))
	var payload: Dictionary = message.get("payload", {}) if message.get("payload") is Dictionary else {}

	match type:
		NetProtocol.MSG_CREATE_ROOM:
			_handle_create_room(peer_id, payload)
		NetProtocol.MSG_JOIN_ROOM:
			_handle_join_room(peer_id, payload)
		NetProtocol.MSG_LIST_ROOMS:
			_handle_list_rooms(peer_id)
		NetProtocol.MSG_SELECT_DECK:
			_handle_select_deck(peer_id, payload)
		NetProtocol.MSG_SET_READY:
			_handle_set_ready(peer_id, payload)
		NetProtocol.MSG_START_GAME:
			_handle_start_game(peer_id)
		NetProtocol.MSG_ACTION:
			_handle_action(peer_id, payload)
		NetProtocol.MSG_CHOICE_RESPONSE:
			_handle_choice_response(peer_id, payload)
		NetProtocol.MSG_RECONNECT:
			_handle_reconnect(peer_id, payload)
		NetProtocol.MSG_LEAVE_ROOM:
			_handle_leave_room(peer_id)
		NetProtocol.MSG_PONG:
			pass  # 心跳响应，忽略
		NetProtocol.MSG_LIST_DECKS:
			_handle_list_decks(peer_id)
		NetProtocol.MSG_SAVE_DECK:
			_handle_save_deck(peer_id, payload)
		NetProtocol.MSG_DELETE_DECK:
			_handle_delete_deck(peer_id, payload)
		NetProtocol.MSG_LIST_REPLAYS:
			_handle_list_replays(peer_id)
		NetProtocol.MSG_GET_REPLAY:
			_handle_get_replay(peer_id, payload)
		_:
			_send_error(peer_id, "unknown_message", "未知消息类型: %s" % type)


func handle_disconnect(peer_id: int) -> void:
	if not _player_sessions.has(peer_id):
		return
	var session: PlayerSession = _player_sessions[peer_id]
	session.mark_disconnected()

	# 通知房间内对手
	if not session.room_id.is_empty() and _rooms.has(session.room_id):
		var room: GameRoom = _rooms[session.room_id]
		var opp_info := room.get_opponent_info(session.player_index)
		if opp_info.has("peer_id"):
			_send_to(opp_info["peer_id"], NetProtocol.make_message(
				NetProtocol.MSG_OPPONENT_DISCONNECTED,
				{"grace_seconds": PlayerSession.GRACE_PERIOD_SECONDS}
			))


func handle_tick(delta: float) -> void:
	# 检查断线超时的会话
	var expired_sessions: Array = []
	for peer_id_variant: Variant in _player_sessions.keys():
		var peer_id := int(peer_id_variant)
		var session: PlayerSession = _player_sessions[peer_id]
		if session.is_expired() and not session.room_id.is_empty() and _rooms.has(session.room_id):
			var room: GameRoom = _rooms[session.room_id]
			if room._state == NetProtocol.ROOM_STATE_PLAYING:
				var winner: int = 1 - session.player_index
				room._on_gsm_game_over(winner, "对手断线超时")
			expired_sessions.append(peer_id)
	for peer_id: int in expired_sessions:
		var session: PlayerSession = _player_sessions[peer_id]
		session.room_id = ""
		_peer_to_room.erase(peer_id)

	# 清理过期房间
	var expired_rooms: Array = []
	for room_id in _rooms.keys():
		var room: GameRoom = _rooms[room_id]
		room.tick(delta)
		if room.get_room_info()["state"] == NetProtocol.ROOM_STATE_FINISHED:
			# 检查是否两个玩家都已离开
			if room.get_player_count() == 0:
				expired_rooms.append(room_id)
	for room_id in expired_rooms:
		_rooms.erase(room_id)


func get_room_list() -> Array:
	var result: Array = []
	for room_id in _rooms.keys():
		var room: GameRoom = _rooms[room_id]
		var info := room.get_room_info()
		if info["state"] == NetProtocol.ROOM_STATE_WAITING:
			result.append({
				"room_id": room_id,
				"room_name": room.room_name,
				"player_count": room.get_player_count(),
			})
	return result


func _send_to(peer_id: int, message: Dictionary) -> void:
	if _send_to_peer_callback.is_valid():
		_send_to_peer_callback.call(peer_id, message)


func _send_error(peer_id: int, code: String, message: String) -> void:
	_send_to(peer_id, NetProtocol.make_error(code, message))


func _handle_create_room(peer_id: int, payload: Dictionary) -> void:
	var room_name: String = str(payload.get("room_name", "房间"))
	var player_name: String = str(payload.get("player_name", "玩家"))

	# 如果已在房间中，先离开
	_leave_current_room(peer_id)

	var room_id := _generate_room_id()
	var room := GameRoom.new()
	room.room_id = room_id
	room.room_name = room_name
	room._card_db = _card_db
	room.send_to_player.connect(func(pi: int, msg: Dictionary) -> void:
		if room._players.has(pi):
			_send_to(room._players[pi]["peer_id"], msg)
	)

	var session := PlayerSession.new()
	session.peer_id = peer_id
	session.player_name = player_name
	session.room_id = room_id
	session.player_index = 0
	session.generate_token()

	room.add_player(peer_id, 0, player_name, session.session_token)

	_rooms[room_id] = room
	_player_sessions[peer_id] = session
	_session_tokens[session.session_token] = session
	_peer_to_room[peer_id] = room_id

	_send_to(peer_id, NetProtocol.make_room_created(room_id, 0, session.session_token))
	print("[RoomManager] 房间创建: %s (%s) by %s" % [room_id, room_name, player_name])


func _handle_join_room(peer_id: int, payload: Dictionary) -> void:
	var room_id: String = str(payload.get("room_id", ""))
	var player_name: String = str(payload.get("player_name", "玩家"))

	if not _rooms.has(room_id):
		_send_error(peer_id, "room_not_found", "房间不存在")
		return

	var room: GameRoom = _rooms[room_id]
	if room.get_player_count() >= 2:
		_send_error(peer_id, "room_full", "房间已满")
		return

	# 如果已在房间中，先离开
	_leave_current_room(peer_id)

	var session := PlayerSession.new()
	session.peer_id = peer_id
	session.player_name = player_name
	session.room_id = room_id
	session.player_index = 1
	session.generate_token()

	room.add_player(peer_id, 1, player_name, session.session_token)

	_player_sessions[peer_id] = session
	_session_tokens[session.session_token] = session
	_peer_to_room[peer_id] = room_id

	# 通知加入者
	var opp_info := room.get_opponent_info(1)
	_send_to(peer_id, NetProtocol.make_room_joined(room_id, 1, session.session_token, opp_info.get("name", "")))

	# 通知房主有新人加入
	_send_to(room._players[0]["peer_id"], NetProtocol.make_room_update(player_name, false))

	print("[RoomManager] 玩家 %s 加入房间 %s" % [player_name, room_id])


func _handle_list_rooms(peer_id: int) -> void:
	var rooms := get_room_list()
	_send_to(peer_id, NetProtocol.make_message(NetProtocol.MSG_ROOM_LIST, {"rooms": rooms}))


func _handle_select_deck(peer_id: int, payload: Dictionary) -> void:
	if not _player_sessions.has(peer_id):
		return
	var session: PlayerSession = _player_sessions[peer_id]
	if not _rooms.has(session.room_id):
		return
	var room: GameRoom = _rooms[session.room_id]
	var deck_id: int = int(payload.get("deck_id", -1))
	if deck_id < 0:
		_send_error(peer_id, "invalid_deck", "无效的牌组ID")
		return
	# 优先从服务器缓存获取牌组
	var deck: DeckData = _card_db.get_deck(deck_id)
	# CardDatabase 没有，检查服务器端牌组存储
	if deck == null and _server_decks.has(deck_id):
		deck = DeckData.from_dict(_server_decks[deck_id])
	# 还没有则使用客户端发来的数据
	if deck == null and payload.has("deck_data") and payload["deck_data"] is Dictionary and not payload["deck_data"].is_empty():
		deck = DeckData.from_dict(payload["deck_data"])
		room._extra_deck_data[session.player_index] = payload["deck_data"]
	if deck == null:
		_send_error(peer_id, "deck_not_found", "牌组未找到")
		return
	room.set_player_deck(session.player_index, deck_id)


func _handle_set_ready(peer_id: int, payload: Dictionary) -> void:
	if not _player_sessions.has(peer_id):
		return
	var session: PlayerSession = _player_sessions[peer_id]
	if not _rooms.has(session.room_id):
		return
	var room: GameRoom = _rooms[session.room_id]
	var ready: bool = bool(payload.get("ready", false))
	room.set_player_ready(session.player_index, ready)

	# 通知对手
	var opp_info := room.get_opponent_info(session.player_index)
	if opp_info.has("peer_id"):
		_send_to(opp_info["peer_id"], NetProtocol.make_room_update(
			session.player_name, ready
		))


func _handle_start_game(peer_id: int) -> void:
	if not _player_sessions.has(peer_id):
		return
	var session: PlayerSession = _player_sessions[peer_id]
	if not _rooms.has(session.room_id):
		return
	var room: GameRoom = _rooms[session.room_id]

	if session.player_index != room.host_player_index:
		_send_error(peer_id, "not_host", "只有房主可以开始游戏")
		return

	if room.start_game():
		# game_starting 信号由 GSM 的 state_changed 触发
		print("[RoomManager] 游戏开始: %s" % session.room_id)


func _handle_action(peer_id: int, payload: Dictionary) -> void:
	if not _player_sessions.has(peer_id):
		return
	var session: PlayerSession = _player_sessions[peer_id]
	if not _rooms.has(session.room_id):
		return
	var room: GameRoom = _rooms[session.room_id]
	var action_type: String = str(payload.get("action_type", ""))
	var params: Dictionary = payload.get("params", {}) if payload.get("params") is Dictionary else {}
	room.handle_action(session.player_index, action_type, params)


func _handle_choice_response(peer_id: int, payload: Dictionary) -> void:
	if not _player_sessions.has(peer_id):
		return
	var session: PlayerSession = _player_sessions[peer_id]
	if not _rooms.has(session.room_id):
		return
	var room: GameRoom = _rooms[session.room_id]
	var choice_type: String = str(payload.get("choice_type", ""))
	var data: Dictionary = payload.get("data", {}) if payload.get("data") is Dictionary else {}
	room.handle_choice_response(session.player_index, choice_type, data)


func _handle_reconnect(peer_id: int, payload: Dictionary) -> void:
	var token: String = str(payload.get("session_token", ""))
	if not _session_tokens.has(token):
		_send_error(peer_id, "invalid_token", "无效的重连令牌")
		return

	var session: PlayerSession = _session_tokens[token]
	# 如果旧会话仍在线，先断开（场景切换时可能旧连接还没被服务器检测到断开）
	if session.connected:
		var old_peer_id := session.peer_id
		_player_sessions.erase(old_peer_id)
		_peer_to_room.erase(old_peer_id)
		session.mark_disconnected()

	var old_peer_id := session.peer_id
	# 清理旧映射
	_player_sessions.erase(old_peer_id)
	_peer_to_room.erase(old_peer_id)

	# 更新 session
	session.mark_reconnected(peer_id)
	_player_sessions[peer_id] = session
	_peer_to_room[peer_id] = session.room_id

	# 同步更新 GameRoom 中的 peer_id
	if _rooms.has(session.room_id):
		var room: GameRoom = _rooms[session.room_id]
		if room._players.has(session.player_index):
			room._players[session.player_index]["peer_id"] = peer_id

	# 通知对手（携带重连者的名字和准备状态）
	var opp_name := ""
	if _rooms.has(session.room_id):
		var room: GameRoom = _rooms[session.room_id]
		var opp_info := room.get_opponent_info(session.player_index)
		if opp_info.has("peer_id"):
			_send_to(opp_info["peer_id"], NetProtocol.make_message(NetProtocol.MSG_OPPONENT_RECONNECTED, {
				"opponent_name": session.player_name,
				"opponent_ready": room._players.get(session.player_index, {}).get("ready", false),
			}))
		# 发送重连确认（包含房间信息和对手状态）
		opp_name = str(opp_info.get("name", ""))
		var opp_ready: bool = opp_info.get("ready", false)
		_send_to(peer_id, NetProtocol.make_reconnected(session.room_id, session.player_index, opp_name, opp_ready, room._state))
		# 如果游戏已开始，发送当前状态
		if room._state != NetProtocol.ROOM_STATE_WAITING:
			var state_view := room.get_visible_state(session.player_index)
			_send_to(peer_id, NetProtocol.make_state_update(state_view))
			# 重新发送待处理的选择提示（setup_ready 等）
			if not room._pending_choice.is_empty():
				_send_to(peer_id, NetProtocol.make_choice_prompt(
					str(room._pending_choice.get("type", "")),
					room._pending_choice.get("data", {})
				))

	print("[RoomManager] 玩家重连: %s (peer %d -> %d), 对手: %s" % [session.player_name, old_peer_id, peer_id, opp_name if not opp_name.is_empty() else "无"])


func _handle_leave_room(peer_id: int) -> void:
	_leave_current_room(peer_id)


func _leave_current_room(peer_id: int) -> void:
	if not _player_sessions.has(peer_id):
		return
	var session: PlayerSession = _player_sessions[peer_id]
	if session.room_id.is_empty():
		return

	if _rooms.has(session.room_id):
		var room: GameRoom = _rooms[session.room_id]
		room.remove_player(session.player_index)
		# 通知对手
		var opp_info := room.get_opponent_info(session.player_index)
		if opp_info.has("peer_id"):
			_send_to(opp_info["peer_id"], NetProtocol.make_error("opponent_left", "对手已离开"))

	session.room_id = ""
	session.player_index = -1
	_peer_to_room.erase(peer_id)


func _generate_room_id() -> String:
	var chars := "abcdefghijklmnopqrstuvwxyz0123456789"
	var result := ""
	for i in 6:
		result += chars[randi() % chars.length()]
	# 确保唯一
	if _rooms.has(result):
		return _generate_room_id()
	return result


# ===================== 服务器端牌组管理 =====================

func init_server_decks() -> void:
	_load_server_decks_from_disk()
	print("[RoomManager] 服务器牌组数: %d" % _server_decks.size())


func _load_server_decks_from_disk() -> void:
	if not DirAccess.dir_exists_absolute(_server_decks_dir):
		DirAccess.make_dir_recursive_absolute(_server_decks_dir)
	var dir := DirAccess.open(_server_decks_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var path := _server_decks_dir.path_join(file_name)
			var file := FileAccess.open(path, FileAccess.READ)
			if file:
				var json := JSON.new()
				if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
					var deck_dict: Dictionary = json.data
					var deck_id: int = int(deck_dict.get("id", 0))
					if deck_id > 0:
						_server_decks[deck_id] = deck_dict
				file.close()
		file_name = dir.get_next()
	dir.list_dir_end()


func _save_deck_to_disk(deck_id: int, deck_dict: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(_server_decks_dir):
		DirAccess.make_dir_recursive_absolute(_server_decks_dir)
	var path := _server_decks_dir.path_join("%d.json" % deck_id)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(deck_dict, "\t"))
		file.close()


func _delete_deck_from_disk(deck_id: int) -> void:
	var path := _server_decks_dir.path_join("%d.json" % deck_id)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _handle_list_decks(peer_id: int) -> void:
	var decks_info: Array = []
	for deck_id: int in _server_decks:
		var d: Dictionary = _server_decks[deck_id]
		decks_info.append({
			"id": deck_id,
			"deck_name": d.get("deck_name", ""),
			"total_cards": d.get("total_cards", 0),
		})
	_send_to(peer_id, NetProtocol.make_deck_list(decks_info))


func _handle_save_deck(peer_id: int, payload: Dictionary) -> void:
	if not payload.has("deck_data") or not payload["deck_data"] is Dictionary:
		_send_error(peer_id, "invalid_deck", "无效的牌组数据")
		return
	var deck_dict: Dictionary = payload["deck_data"]
	var deck_id: int = int(deck_dict.get("id", 0))
	if deck_id <= 0:
		# 生成新 ID
		deck_id = int(Time.get_ticks_msec()) + randi() % 1000
		deck_dict["id"] = deck_id
	_server_decks[deck_id] = deck_dict
	_save_deck_to_disk(deck_id, deck_dict)
	_send_to(peer_id, NetProtocol.make_deck_saved(deck_id))
	print("[RoomManager] 牌组保存: %s (id=%d)" % [deck_dict.get("deck_name", "?"), deck_id])


func _handle_delete_deck(peer_id: int, payload: Dictionary) -> void:
	var deck_id: int = int(payload.get("deck_id", -1))
	if deck_id < 0 or not _server_decks.has(deck_id):
		_send_error(peer_id, "deck_not_found", "牌组未找到")
		return
	_server_decks.erase(deck_id)
	_delete_deck_from_disk(deck_id)
	# 返回更新后的列表
	_handle_list_decks(peer_id)
	print("[RoomManager] 牌组删除: id=%d" % deck_id)


# ===================== 对局回放管理 =====================

const _replays_dir := "user://match_records"
const REPLAY_DETAIL_CHUNK_MAX_BYTES := 24 * 1024


func _handle_list_replays(peer_id: int) -> void:
	var replays: Array = []
	if not DirAccess.dir_exists_absolute(_replays_dir):
		_send_to(peer_id, NetProtocol.make_replay_list(replays))
		return
	var dir := DirAccess.open(_replays_dir)
	if dir == null:
		_send_to(peer_id, NetProtocol.make_replay_list(replays))
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and entry.begins_with("match_"):
			var match_dir := _replays_dir.path_join(entry)
			var match_json_path := match_dir.path_join("match.json")
			if FileAccess.file_exists(match_json_path):
				var info := _read_replay_summary(entry, match_json_path)
				if not info.is_empty():
					replays.append(info)
		entry = dir.get_next()
	dir.list_dir_end()
	# 按 match_id 降序排列（最新的在前）
	replays.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("match_id", "")) > str(b.get("match_id", ""))
	)
	_send_to(peer_id, NetProtocol.make_replay_list(replays))


func _handle_get_replay(peer_id: int, payload: Dictionary) -> void:
	var match_id: String = str(payload.get("match_id", ""))
	if match_id.is_empty():
		_send_error(peer_id, "invalid_replay", "无效的回放ID")
		return
	var match_dir := _replays_dir.path_join(match_id)
	var match_json_path := match_dir.path_join("match.json")
	if not FileAccess.file_exists(match_json_path):
		_send_error(peer_id, "replay_not_found", "回放未找到")
		return
	var file := FileAccess.open(match_json_path, FileAccess.READ)
	if file == null:
		_send_error(peer_id, "replay_read_error", "读取回放失败")
		return
	var json := JSON.new()
	var parse_result := json.parse(file.get_as_text())
	file.close()
	if parse_result != OK or not (json.data is Dictionary):
		_send_error(peer_id, "replay_parse_error", "回放数据格式错误")
		return
	var replay_data: Dictionary = json.data
	replay_data["match_id"] = match_id
	# 尝试加载 turns.json
	var turns_path := match_dir.path_join("turns.json")
	if FileAccess.file_exists(turns_path):
		var turns_file := FileAccess.open(turns_path, FileAccess.READ)
		if turns_file:
			var turns_json := JSON.new()
			if turns_json.parse(turns_file.get_as_text()) == OK and turns_json.data is Dictionary:
				replay_data["turns"] = turns_json.data
			turns_file.close()
	var detail_path := match_dir.path_join("detail.jsonl")
	var detail_chunks: Array = []
	if FileAccess.file_exists(detail_path):
		detail_chunks = _chunk_replay_detail_events(_read_json_lines(detail_path))
		replay_data["detail_chunk_count"] = detail_chunks.size()
		if detail_chunks.size() <= 1:
			replay_data["detail_events"] = detail_chunks[0] if not detail_chunks.is_empty() else []
	_send_to(peer_id, NetProtocol.make_replay_data(replay_data))
	for chunk_index: int in detail_chunks.size():
		if detail_chunks.size() <= 1:
			break
		_send_to(peer_id, NetProtocol.make_replay_detail_chunk(
			match_id,
			chunk_index,
			detail_chunks.size(),
			detail_chunks[chunk_index] if detail_chunks[chunk_index] is Array else []
		))
	print("[RoomManager] 回放请求: %s by peer %d" % [match_id, peer_id])


func _read_replay_summary(match_id: String, match_json_path: String) -> Dictionary:
	var file := FileAccess.open(match_json_path, FileAccess.READ)
	if file == null:
		return {}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not (json.data is Dictionary):
		file.close()
		return {}
	file.close()
	var data: Dictionary = json.data
	var meta: Dictionary = data.get("meta", {})
	var result: Dictionary = data.get("result", {})
	return {
		"match_id": match_id,
		"mode": str(meta.get("mode", "")),
		"room_id": str(meta.get("room_id", "")),
		"player_names": meta.get("player_labels", []),
		"deck_names": meta.get("deck_names", []),
		"winner_index": int(result.get("winner_index", -1)),
		"reason": str(result.get("reason", "")),
		"turn_count": int(result.get("turn_count", 0)),
		"event_count": int(data.get("event_count", 0)),
	}


func _read_json_lines(path: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return rows
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line == "":
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			rows.append((parsed as Dictionary).duplicate(true))
	file.close()
	return rows


func _chunk_replay_detail_events(detail_events: Array[Dictionary]) -> Array:
	if detail_events.is_empty():
		return []
	var chunks: Array = []
	var current_chunk: Array = []
	var current_bytes: int = 2
	for event: Dictionary in detail_events:
		var serialized: String = JSON.stringify(event)
		var event_bytes: int = maxi(1, serialized.length()) + 1
		if not current_chunk.is_empty() and current_bytes + event_bytes > REPLAY_DETAIL_CHUNK_MAX_BYTES:
			chunks.append(current_chunk)
			current_chunk = []
			current_bytes = 2
		current_chunk.append(event.duplicate(true))
		current_bytes += event_bytes
	if not current_chunk.is_empty():
		chunks.append(current_chunk)
	return chunks

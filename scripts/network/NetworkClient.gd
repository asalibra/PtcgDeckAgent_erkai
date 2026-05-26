## 网络对战客户端 - WebSocket 连接管理，消息收发
class_name NetworkClient
extends Node

signal connected()
signal disconnected(reason: String)
signal message_received(message: Dictionary)
signal connection_error(error: String)

const CONNECT_TIMEOUT_SEC := 10.0

var server_url: String = "ws://localhost:9000"
var _ws: WebSocketPeer
var _connected: bool = false
var _session_token: String = ""
var _player_index: int = -1
var _room_id: String = ""
var _connecting: bool = false
var _connect_start_msec: int = 0


func connect_to_server(url: String = "") -> void:
	if not url.is_empty():
		server_url = url
	_disconnect_internal()
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(server_url)
	if err != OK:
		connection_error.emit("连接失败: %s" % error_string(err))
		return
	_connecting = true
	_connect_start_msec = Time.get_ticks_msec()
	print("[NetworkClient] 正在连接 %s..." % server_url)


func disconnect_from_server() -> void:
	_disconnect_internal()


func send_message(message: Dictionary) -> void:
	if _ws == null or not _connected:
		push_warning("[NetworkClient] 未连接，无法发送消息")
		return
	var json_str := NetProtocol.dict_to_json_string(message)
	_ws.send_text(json_str)


func is_connected_to_server() -> bool:
	return _connected


func get_session_token() -> String:
	return _session_token


func get_player_index() -> int:
	return _player_index


func get_room_id() -> String:
	return _room_id


func set_session_info(token: String, player_index: int, room_id: String) -> void:
	_session_token = token
	_player_index = player_index
	_room_id = room_id


# ===================== 便捷消息方法 =====================

func create_room(room_name: String, player_name: String) -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_CREATE_ROOM, {
		"room_name": room_name,
		"player_name": player_name,
	}))


func join_room(room_id: String, player_name: String) -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_JOIN_ROOM, {
		"room_id": room_id,
		"player_name": player_name,
	}))


func list_rooms() -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_LIST_ROOMS))


func select_deck(deck_id: int, deck_data: Dictionary = {}) -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_SELECT_DECK, {
		"deck_id": deck_id,
		"deck_data": deck_data,
	}))


func set_ready(ready: bool) -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_SET_READY, {
		"ready": ready,
	}))


func start_game() -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_START_GAME))


func send_action(action_type: String, params: Dictionary = {}) -> void:
	send_message(NetProtocol.make_action(action_type, params))


func send_choice_response(choice_type: String, data: Dictionary = {}) -> void:
	send_message(NetProtocol.make_choice_response(choice_type, data))


func reconnect(token: String) -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_RECONNECT, {
		"session_token": token,
	}))


func leave_room() -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_LEAVE_ROOM))
	_room_id = ""
	_player_index = -1


func list_server_decks() -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_LIST_DECKS))


func save_deck_to_server(deck_data: Dictionary) -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_SAVE_DECK, {
		"deck_data": deck_data,
	}))


func delete_deck_from_server(deck_id: int) -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_DELETE_DECK, {
		"deck_id": deck_id,
	}))


func list_replays() -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_LIST_REPLAYS))


func get_replay(match_id: String) -> void:
	send_message(NetProtocol.make_message(NetProtocol.MSG_GET_REPLAY, {
		"match_id": match_id,
	}))


# ===================== 内部 =====================

func _process(_delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()

	# 连接超时检测
	if _connecting and state != WebSocketPeer.STATE_OPEN:
		var elapsed_sec := (Time.get_ticks_msec() - _connect_start_msec) / 1000.0
		if elapsed_sec >= CONNECT_TIMEOUT_SEC:
			_connecting = false
			_disconnect_internal()
			connection_error.emit("连接超时（%.0f秒）" % CONNECT_TIMEOUT_SEC)
			return

	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			_connecting = false
			print("[NetworkClient] 已连接")
			connected.emit()
		while _ws.get_available_packet_count() > 0:
			var packet := _ws.get_packet()
			var json_str := packet.get_string_from_utf8()
			var message := NetProtocol.json_string_to_dict(json_str)
			if message.is_empty():
				continue
			_handle_message(message)

	elif state == WebSocketPeer.STATE_CLOSING:
		pass

	elif state == WebSocketPeer.STATE_CLOSED:
		if _connected:
			_connected = false
			var reason := _ws.get_close_reason()
			print("[NetworkClient] 连接断开: %s" % reason)
			disconnected.emit(reason)


func _handle_message(message: Dictionary) -> void:
	var type: String = str(message.get("type", ""))
	var payload: Dictionary = message.get("payload", {}) if message.get("payload") is Dictionary else {}
	_log_message_trace("recv", type, payload)

	# 处理 session 信息
	match type:
		NetProtocol.MSG_ROOM_CREATED:
			_session_token = str(payload.get("session_token", ""))
			_player_index = int(payload.get("player_index", 0))
			_room_id = str(payload.get("room_id", ""))
		NetProtocol.MSG_ROOM_JOINED:
			_session_token = str(payload.get("session_token", ""))
			_player_index = int(payload.get("player_index", 1))
			_room_id = str(payload.get("room_id", ""))
		NetProtocol.MSG_PING:
			send_message(NetProtocol.make_message(NetProtocol.MSG_PONG))
			return

	message_received.emit(message)


func _log_message_trace(direction: String, message_type: String, payload: Dictionary) -> void:
	if message_type != NetProtocol.MSG_CHOICE_PROMPT and message_type != NetProtocol.MSG_CHOICE_RESPONSE:
		return
	var choice_type := str(payload.get("choice_type", ""))
	var data: Dictionary = payload.get("data", {}) if payload.get("data") is Dictionary else {}
	if choice_type != NetProtocol.CHOICE_TRAINER_INTERACTION:
		return
	var step_index := int(data.get("step_index", -1))
	var steps: Array = data.get("steps", []) if data.get("steps") is Array else []
	var card_name := str(data.get("card_name", ""))
	var target_player := int(data.get("target_player", -1))
	print("[NetworkClient][TrainerTrace] %s type=%s choice=%s target=%d me=%d step_index=%d steps=%d card=%s" % [
		direction,
		message_type,
		choice_type,
		target_player,
		_player_index,
		step_index,
		steps.size(),
		card_name,
	])


func _disconnect_internal() -> void:
	if _ws != null:
		_ws.close()
		_ws = null
	_connected = false
	_connecting = false

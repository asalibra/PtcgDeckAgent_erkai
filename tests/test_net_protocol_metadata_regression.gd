class_name TestNetProtocolMetadataRegression
extends TestBase

const RoomManagerScript = preload("res://scripts/server/RoomManager.gd")
const PlayerSessionScript = preload("res://scripts/server/PlayerSession.gd")
const NetworkClientScript = preload("res://scripts/network/NetworkClient.gd")
const NetLobbyScene = preload("res://scenes/network/NetLobby.tscn")


class SpyReconnectClient extends NetworkClientScript:
	var reconnect_calls: int = 0

	func connect_to_server(_url: String = "") -> void:
		pass

	func is_connected_to_server() -> bool:
		return true

	func reconnect(_token: String) -> void:
		reconnect_calls += 1

	func list_rooms() -> void:
		pass

	func disconnect_from_server() -> void:
		pass


func test_make_message_includes_protocol_metadata_defaults() -> String:
	var message := NetProtocol.make_message(NetProtocol.MSG_LIST_ROOMS)
	return run_checks([
		assert_eq(int(message.get(NetProtocol.META_VERSION, -1)), NetProtocol.PROTOCOL_VERSION, "协议消息应带默认 version"),
		assert_eq(str(message.get(NetProtocol.META_REQUEST_ID, "missing")), "", "未指定 request_id 时应为空字符串"),
		assert_eq(int(message.get(NetProtocol.META_STATE_SEQ, 999)), NetProtocol.INVALID_STATE_SEQ, "默认 state_seq 应为 INVALID_STATE_SEQ"),
		assert_false(bool(message.get(NetProtocol.META_RESYNC_REQUIRED, true)), "默认消息不应要求 resync"),
	])


func test_network_client_decorates_outbound_message_with_request_id_and_state_seq() -> String:
	var client := NetworkClientScript.new()
	client._last_received_state_seq = 7
	var outbound := client._decorate_outbound_message(NetProtocol.make_action(NetProtocol.ACTION_END_TURN))
	return run_checks([
		assert_eq(int(outbound.get(NetProtocol.META_VERSION, -1)), NetProtocol.PROTOCOL_VERSION, "客户端外发消息应带当前协议版本"),
		assert_eq(int(outbound.get(NetProtocol.META_STATE_SEQ, -1)), 7, "客户端外发消息应携带最近一次 state_seq"),
		assert_true(not str(outbound.get(NetProtocol.META_REQUEST_ID, "")).is_empty(), "客户端外发消息应自动生成 request_id"),
	])


func test_room_manager_rejects_stale_action_with_resync_required() -> String:
	var sent_messages: Array = []
	var manager := RoomManagerScript.new()
	manager.setup(func(peer_id: int, message: Dictionary) -> void:
		sent_messages.append({"peer_id": peer_id, "message": message})
	)
	manager.handle_message(1, NetProtocol.make_message(NetProtocol.MSG_CREATE_ROOM, {
		"room_name": "room-1",
		"player_name": "player-1",
	}))
	var session: PlayerSession = manager._player_sessions[1]
	var room = manager._rooms[session.room_id]
	room._state = NetProtocol.ROOM_STATE_PLAYING
	room._state_seq = 5
	sent_messages.clear()

	var stale_action := NetProtocol.with_meta(
		NetProtocol.make_action(NetProtocol.ACTION_END_TURN),
		{
			NetProtocol.META_REQUEST_ID: "req-1",
			NetProtocol.META_STATE_SEQ: 4,
		}
	)
	manager.handle_message(1, stale_action)

	var first_sent: Dictionary = sent_messages[0] if not sent_messages.is_empty() and sent_messages[0] is Dictionary else {}
	var sent_message: Dictionary = first_sent.get("message", {}) if first_sent.get("message") is Dictionary else {}
	var payload: Dictionary = sent_message.get("payload", {}) if sent_message.get("payload") is Dictionary else {}
	return run_checks([
		assert_eq(str(sent_message.get("type", "")), NetProtocol.MSG_ERROR, "服务端应返回 error 触发重同步"),
		assert_true(NetProtocol.is_resync_required(sent_message), "服务端应显式标记 resync_required"),
		assert_eq(str(sent_message.get(NetProtocol.META_REQUEST_ID, "")), "req-1", "resync 错误应回显原始 request_id"),
		assert_eq(int(sent_message.get(NetProtocol.META_STATE_SEQ, -1)), 5, "resync 错误应携带服务器最新 state_seq"),
		assert_eq(int(payload.get("expected_state_seq", -1)), 5, "resync 错误应包含期望的 state_seq"),
		assert_eq(int(payload.get("received_state_seq", -1)), 4, "resync 错误应包含客户端提交的过期 state_seq"),
	])


func test_net_lobby_resync_required_reconnects_saved_session() -> String:
	var backup_token := GameManager.net_session_token
	var lobby: Control = NetLobbyScene.instantiate()
	var client := SpyReconnectClient.new()
	client.name = "NetworkClient"
	lobby._network_client = client
	lobby.add_child(client)
	lobby.call("_ready")
	# Set token AFTER _ready, because _load_prefs() inside _ready overwrites it
	GameManager.net_session_token = "session-token"

	var message := NetProtocol.with_meta(
		NetProtocol.make_error("resync_required", "客户端状态已过期，请重新同步"),
		{NetProtocol.META_RESYNC_REQUIRED: true}
	)
	lobby.call("_on_message_received", message)
	var status_label := lobby.get_node("%StatusLabel") as Label

	var result := run_checks([
		assert_eq(client.reconnect_calls, 1, "大厅收到 resync_required 后应尝试使用已保存 session 重连"),
		assert_str_contains(status_label.text, "重新同步", "大厅应提示正在重新同步"),
	])

	lobby.queue_free()
	GameManager.net_session_token = backup_token
	return result

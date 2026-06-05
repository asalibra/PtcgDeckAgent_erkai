class_name TestNetReconnectResumeRegression
extends TestBase

const NetLobbyScene = preload("res://scenes/network/NetLobby.tscn")
const NetWaitingRoomScene = preload("res://scenes/network/NetWaitingRoom.tscn")


class SpyReconnectClient extends NetworkClient:
	var disconnect_calls: int = 0
	var reconnect_calls: int = 0
	var list_server_decks_calls: int = 0
	var select_deck_calls: int = 0
	var last_reconnect_token: String = ""

	func connect_to_server(_url: String = "") -> void:
		pass

	func disconnect_from_server() -> void:
		disconnect_calls += 1

	func is_connected_to_server() -> bool:
		return true

	func list_rooms() -> void:
		pass

	func list_server_decks() -> void:
		list_server_decks_calls += 1

	func save_deck_to_server(_deck_data: Dictionary) -> void:
		pass

	func select_deck(_deck_id: int, _deck_data: Dictionary = {}, _deck_source: String = "") -> void:
		select_deck_calls += 1

	func reconnect(_token: String) -> void:
		reconnect_calls += 1
		last_reconnect_token = _token


func test_net_lobby_waits_for_state_update_before_entering_battle_on_reconnect() -> String:
	var backup_nav := GameManager.suppress_scene_navigation_for_tests
	GameManager.set_scene_navigation_suppressed_for_tests(true)
	GameManager.consume_last_requested_scene_path()
	var lobby: Control = NetLobbyScene.instantiate()
	var client := SpyReconnectClient.new()
	client.name = "NetworkClient"
	lobby._network_client = client
	lobby.add_child(client)
	lobby.call("_ready")

	lobby.call("_on_message_received", NetProtocol.make_reconnected("room-1", 0, "对手", true, NetProtocol.ROOM_STATE_PLAYING))
	var path_after_reconnected := GameManager.consume_last_requested_scene_path()
	var disconnects_after_reconnected := client.disconnect_calls
	lobby.call("_on_message_received", NetProtocol.make_state_update({"players": []}))
	var final_path := GameManager.consume_last_requested_scene_path()

	var result := run_checks([
		assert_eq(path_after_reconnected, "", "大厅收到 playing 状态的 reconnected 后不应提前跳到等待房间"),
		assert_eq(disconnects_after_reconnected, 0, "大厅收到 playing 状态的 reconnected 后不应提前断开连接"),
		assert_eq(final_path, GameManager.SCENE_NET_BATTLE, "大厅应在收到 state_update 后再进入网络对战场景"),
		assert_eq(client.disconnect_calls, 1, "大厅进入网络对战前应只断开一次旧连接"),
	])

	lobby.queue_free()
	GameManager.set_scene_navigation_suppressed_for_tests(backup_nav)
	return result


func test_net_waiting_room_waits_for_state_update_before_entering_battle_on_reconnect() -> String:
	var backup_nav := GameManager.suppress_scene_navigation_for_tests
	GameManager.set_scene_navigation_suppressed_for_tests(true)
	GameManager.consume_last_requested_scene_path()
	var waiting_room: Control = NetWaitingRoomScene.instantiate()
	var client := SpyReconnectClient.new()
	client.name = "NetworkClient"
	waiting_room._network_client = client
	waiting_room.add_child(client)
	waiting_room.call("_ready")

	waiting_room.call("_on_message_received", NetProtocol.make_reconnected("room-1", 0, "对手", true, NetProtocol.ROOM_STATE_PLAYING))
	var path_after_reconnected := GameManager.consume_last_requested_scene_path()
	var disconnects_after_reconnected := client.disconnect_calls
	waiting_room.call("_on_message_received", NetProtocol.make_state_update({"players": []}))
	var final_path := GameManager.consume_last_requested_scene_path()

	var result := run_checks([
		assert_eq(path_after_reconnected, "", "等待房间收到 playing 状态的 reconnected 后不应停留在错误跳转上"),
		assert_eq(disconnects_after_reconnected, 0, "等待房间收到 playing 状态的 reconnected 后不应提前断开连接"),
		assert_eq(final_path, GameManager.SCENE_NET_BATTLE, "等待房间应在收到 state_update 后再进入网络对战场景"),
		assert_eq(client.disconnect_calls, 1, "等待房间进入网络对战前应只断开一次旧连接"),
	])

	waiting_room.queue_free()
	GameManager.set_scene_navigation_suppressed_for_tests(backup_nav)
	return result


func test_net_waiting_room_reconnects_saved_room_session_after_room_creation() -> String:
	var waiting_room: Control = NetWaitingRoomScene.instantiate()
	var client := SpyReconnectClient.new()
	client.name = "NetworkClient"
	waiting_room._network_client = client
	waiting_room.add_child(client)
	GameManager.net_room_id = "room-created"
	GameManager.net_player_index = 0
	GameManager.net_session_token = "session-token"
	waiting_room.call("_ready")
	waiting_room.call("_on_connected")
	var list_calls_before_reconnected := client.list_server_decks_calls
	waiting_room.call("_on_message_received", NetProtocol.make_reconnected("room-created", 0, "对手", false, NetProtocol.ROOM_STATE_WAITING))

	var result := run_checks([
		assert_eq(client.reconnect_calls, 1, "等待房间在创建房间后应使用已保存 session 重新附着房间"),
		assert_eq(client.last_reconnect_token, "session-token", "等待房间应使用当前 session_token 重连"),
		assert_eq(list_calls_before_reconnected, 0, "等待房间在重连确认前不应提前请求牌组列表"),
		assert_true(client.list_server_decks_calls >= 1, "等待房间在收到 reconnected 后应再请求牌组列表"),
		assert_true(client.select_deck_calls >= 1, "等待房间在重新附着后应同步当前牌组选择"),
	])

	waiting_room.queue_free()
	GameManager.clear_net_connection_session()
	return result


func test_net_lobby_recovery_timeout_clears_stale_session() -> String:
	var backup_room_id := GameManager.net_room_id
	var backup_player_index := GameManager.net_player_index
	var backup_session_token := GameManager.net_session_token
	var lobby: Control = NetLobbyScene.instantiate()
	var client := SpyReconnectClient.new()
	client.name = "NetworkClient"
	lobby._network_client = client
	lobby.add_child(client)
	GameManager.net_room_id = "room-stale"
	GameManager.net_player_index = 0
	GameManager.net_session_token = "stale-token"
	lobby.call("_ready")
	lobby.call("_start_recovery", "test_timeout")
	lobby.call("_tick_recovery", Time.get_ticks_msec() + int((lobby.RECOVERY_TIMEOUT_SEC + 1.0) * 1000.0))
	var status_label: Label = lobby.get_node("CenterContainer/MainPanel/VBox/StatusLabel")

	var result := run_checks([
		assert_eq(GameManager.net_session_token, "", "大厅恢复超时后应清理旧 session_token"),
		assert_eq(GameManager.net_room_id, "", "大厅恢复超时后应清理旧 room_id"),
		assert_eq(client.disconnect_calls, 1, "大厅恢复超时后应断开旧连接"),
		assert_true(status_label.text.contains("恢复房间超时"), "大厅恢复超时后应提示用户重新进入房间"),
	])

	lobby.queue_free()
	GameManager.net_room_id = backup_room_id
	GameManager.net_player_index = backup_player_index
	GameManager.net_session_token = backup_session_token
	return result
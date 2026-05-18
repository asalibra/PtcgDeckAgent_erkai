class_name TestNetReconnectResumeRegression
extends TestBase

const NetLobbyScene = preload("res://scenes/network/NetLobby.tscn")
const NetWaitingRoomScene = preload("res://scenes/network/NetWaitingRoom.tscn")


class SpyReconnectClient extends NetworkClient:
	var disconnect_calls: int = 0

	func connect_to_server(_url: String = "") -> void:
		pass

	func disconnect_from_server() -> void:
		disconnect_calls += 1

	func is_connected_to_server() -> bool:
		return true

	func list_rooms() -> void:
		pass

	func list_server_decks() -> void:
		pass

	func save_deck_to_server(_deck_data: Dictionary) -> void:
		pass

	func reconnect(_token: String) -> void:
		pass


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
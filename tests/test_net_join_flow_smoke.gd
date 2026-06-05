class_name TestNetJoinFlowSmoke
extends TestBase

const NetLobbyScene := preload("res://scenes/network/NetLobby.tscn")
const NetWaitingRoomScene := preload("res://scenes/network/NetWaitingRoom.tscn")


class SpyLobbyClient extends NetworkClient:
	var create_room_calls: int = 0
	var join_room_calls: int = 0
	var disconnect_calls: int = 0
	var created_room_name: String = ""
	var created_player_name: String = ""
	var joined_room_id: String = ""
	var joined_player_name: String = ""

	func connect_to_server(_url: String = "") -> void:
		pass

	func is_connected_to_server() -> bool:
		return true

	func list_rooms() -> void:
		pass

	func create_room(room_name: String, player_name: String) -> void:
		create_room_calls += 1
		created_room_name = room_name
		created_player_name = player_name

	func join_room(room_id: String, player_name: String) -> void:
		join_room_calls += 1
		joined_room_id = room_id
		joined_player_name = player_name

	func disconnect_from_server() -> void:
		disconnect_calls += 1


class SpyWaitingClient extends NetworkClient:
	var list_server_decks_calls: int = 0
	var save_deck_calls: int = 0
	var select_deck_calls: int = 0
	var disconnect_calls: int = 0
	var last_saved_deck_data: Dictionary = {}
	var last_selected_deck_id: int = -1
	var last_selected_deck_data: Dictionary = {}
	var last_selected_deck_source: String = ""
	var connected_state: bool = true

	func connect_to_server(_url: String = "") -> void:
		pass

	func is_connected_to_server() -> bool:
		return connected_state

	func list_server_decks() -> void:
		list_server_decks_calls += 1

	func save_deck_to_server(_deck_data: Dictionary) -> void:
		save_deck_calls += 1
		last_saved_deck_data = _deck_data.duplicate(true)

	func select_deck(_deck_id: int, _deck_data: Dictionary = {}, _deck_source: String = "") -> void:
		select_deck_calls += 1
		last_selected_deck_id = _deck_id
		last_selected_deck_data = _deck_data.duplicate(true)
		last_selected_deck_source = _deck_source

	func disconnect_from_server() -> void:
		disconnect_calls += 1


func _backup_net_state() -> Dictionary:
	return {
		"room_id": GameManager.net_room_id,
		"player_index": GameManager.net_player_index,
		"session_token": GameManager.net_session_token,
		"server_url": GameManager.net_server_url,
		"suppress_nav": GameManager.suppress_scene_navigation_for_tests,
	}


func _restore_net_state(backup: Dictionary) -> void:
	GameManager.net_room_id = str(backup.get("room_id", ""))
	GameManager.net_player_index = int(backup.get("player_index", -1))
	GameManager.net_session_token = str(backup.get("session_token", ""))
	GameManager.net_server_url = str(backup.get("server_url", "ws://localhost:9000"))
	GameManager.set_scene_navigation_suppressed_for_tests(bool(backup.get("suppress_nav", false)))


func _reset_net_state_for_waiting_room() -> void:
	GameManager.net_room_id = ""
	GameManager.net_player_index = -1
	GameManager.net_session_token = ""
	GameManager.net_server_url = "ws://localhost:9000"


func _dispose_node(node: Node) -> void:
	if node == null:
		return
	if node.is_inside_tree():
		var tree := node.get_tree()
		node.queue_free()
		if tree != null:
			await tree.process_frame
		return
	node.free()


func test_join_room_pipeline_smoke_without_manual_ui() -> String:
	var backup_state := _backup_net_state()

	GameManager.set_scene_navigation_suppressed_for_tests(true)
	GameManager.consume_last_requested_scene_path()
	_reset_net_state_for_waiting_room()

	var lobby: Control = NetLobbyScene.instantiate()
	var lobby_client := SpyLobbyClient.new()
	lobby_client.name = "NetworkClient"
	lobby._network_client = lobby_client
	lobby.add_child(lobby_client)
	lobby.call("_ready")

	lobby.call("_on_join_room", "abc123")
	lobby.call("_on_message_received", NetProtocol.make_room_joined("abc123", 1, "sess-abc", "房主"))
	var waiting_scene_path := GameManager.consume_last_requested_scene_path()

	await _dispose_node(lobby)

	var waiting_room: Control = NetWaitingRoomScene.instantiate()
	var waiting_client := SpyWaitingClient.new()
	waiting_client.name = "NetworkClient"
	waiting_client.connected_state = false
	waiting_room._network_client = waiting_client
	waiting_room.add_child(waiting_client)
	waiting_room.call("_ready")
	waiting_client.connected_state = true
	waiting_room.call("_on_connected")
	waiting_room.call("_on_message_received", NetProtocol.make_reconnected("abc123", 1, "房主", false, NetProtocol.ROOM_STATE_WAITING))

	waiting_room.call("_on_message_received", NetProtocol.make_deck_list([
		{"id": 101, "deck_name": "Smoke Deck", "total_cards": 60}
	]))
	waiting_room.call("_on_message_received", NetProtocol.make_room_update("房主", true))
	waiting_room.call("_on_message_received", NetProtocol.make_game_starting(0, 1))
	var battle_scene_path := GameManager.consume_last_requested_scene_path()

	var status_label: Label = waiting_room.get_node("CenterContainer/MainPanel/VBox/StatusLabel")
	var join_room_calls := lobby_client.join_room_calls
	var joined_room_id := lobby_client.joined_room_id
	var list_server_decks_calls := waiting_client.list_server_decks_calls
	var select_deck_calls := waiting_client.select_deck_calls
	var status_text := status_label.text
	await _dispose_node(waiting_room)
	await _dispose_node(lobby)

	var result := run_checks([
		assert_eq(join_room_calls, 1, "大厅应发送一次 join_room 请求"),
		assert_eq(joined_room_id, "abc123", "join_room 应使用房间列表里的 room_id"),
		assert_eq(GameManager.net_room_id, "abc123", "收到 room_joined 后应写入房间ID"),
		assert_eq(GameManager.net_session_token, "sess-abc", "收到 room_joined 后应写入会话令牌"),
		assert_eq(waiting_scene_path, GameManager.SCENE_NET_WAITING, "加入成功后应跳转到等待房间"),
		assert_true(list_server_decks_calls >= 1, "等待房间连接后应请求服务器牌组列表"),
		assert_true(select_deck_calls >= 1, "收到牌组列表后应自动选择一个可用牌组"),
		assert_true(status_text.contains("已加载"), "等待房间应显示服务器牌组已加载状态"),
		assert_eq(battle_scene_path, GameManager.SCENE_NET_BATTLE, "收到 game_starting 后应跳转到网络对战场景"),
	])

	_restore_net_state(backup_state)

	return result


func test_create_room_pipeline_smoke_without_manual_ui() -> String:
	var backup_state := _backup_net_state()

	GameManager.set_scene_navigation_suppressed_for_tests(true)
	GameManager.consume_last_requested_scene_path()
	_reset_net_state_for_waiting_room()

	var lobby: Control = NetLobbyScene.instantiate()
	var lobby_client := SpyLobbyClient.new()
	lobby_client.name = "NetworkClient"
	lobby._network_client = lobby_client
	lobby.add_child(lobby_client)
	lobby.call("_ready")
	var room_name_edit: LineEdit = lobby.get_node("CenterContainer/MainPanel/VBox/CreateRoomPanel/CreateVBox/RoomNameEdit")
	room_name_edit.text = "Smoke Create Room"
	lobby.call("_on_confirm_create_pressed")
	lobby.call("_on_message_received", NetProtocol.make_room_created("create-123", 0, "sess-create"))
	var waiting_scene_path := GameManager.consume_last_requested_scene_path()

	var create_room_calls := lobby_client.create_room_calls
	var created_room_name := lobby_client.created_room_name
	await _dispose_node(lobby)

	var result := run_checks([
		assert_eq(create_room_calls, 1, "大厅应发送一次 create_room 请求"),
		assert_eq(created_room_name, "Smoke Create Room", "create_room 应使用创建面板里的房间名"),
		assert_eq(GameManager.net_room_id, "create-123", "收到 room_created 后应写入房间ID"),
		assert_eq(GameManager.net_player_index, 0, "收到 room_created 后应写入玩家索引"),
		assert_eq(GameManager.net_session_token, "sess-create", "收到 room_created 后应写入会话令牌"),
		assert_eq(waiting_scene_path, GameManager.SCENE_NET_WAITING, "创建成功后应跳转到等待房间"),
	])

	_restore_net_state(backup_state)

	return result


func test_create_room_panel_prefills_player_based_room_name() -> String:
	var backup_state := _backup_net_state()
	var lobby: Control = NetLobbyScene.instantiate()
	var lobby_client := SpyLobbyClient.new()
	lobby_client.name = "NetworkClient"
	lobby._network_client = lobby_client
	lobby.add_child(lobby_client)
	lobby.call("_ready")

	var player_name_edit: LineEdit = lobby.get_node("CenterContainer/MainPanel/VBox/NameRow/PlayerNameEdit")
	var room_name_edit: LineEdit = lobby.get_node("CenterContainer/MainPanel/VBox/CreateRoomPanel/CreateVBox/RoomNameEdit")
	player_name_edit.text = "小明"
	lobby.call("_on_create_room_pressed")
	var prefixed_default_name := room_name_edit.text
	player_name_edit.text = "玩家阿金"
	lobby.call("_on_create_room_pressed")
	var preserved_default_name := room_name_edit.text

	await _dispose_node(lobby)
	_restore_net_state(backup_state)

	return run_checks([
		assert_eq(prefixed_default_name, "玩家小明的房间", "创建房间面板应基于玩家昵称预填默认房名"),
		assert_eq(preserved_default_name, "玩家阿金的房间", "已带“玩家”前缀的昵称不应重复追加前缀"),
	])


func test_create_room_pipeline_loads_waiting_room_in_tree() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return "测试运行器未提供可用的 SceneTree"
	var backup_state := _backup_net_state()

	GameManager.set_scene_navigation_suppressed_for_tests(false)
	_reset_net_state_for_waiting_room()

	var lobby: Control = NetLobbyScene.instantiate()
	var lobby_client := SpyLobbyClient.new()
	lobby_client.name = "NetworkClient"
	lobby._network_client = lobby_client
	lobby.add_child(lobby_client)
	tree.root.add_child(lobby)
	tree.current_scene = lobby
	await tree.process_frame

	lobby.call("_on_message_received", NetProtocol.make_room_created("scene-123", 0, "sess-scene"))
	var lobby_disconnects := lobby_client.disconnect_calls
	await tree.scene_changed

	var current_scene := tree.current_scene
	var waiting_scene_path := current_scene.get_scene_file_path() if current_scene != null else ""
	var has_waiting_room_id := current_scene != null and current_scene.has_node("%RoomIdLabel")

	if current_scene != null:
		current_scene.queue_free()
	await tree.process_frame

	_restore_net_state(backup_state)

	return run_checks([
		assert_eq(waiting_scene_path, GameManager.SCENE_NET_WAITING, "创建房间成功后应能在真实场景树里加载等待房间"),
		assert_true(has_waiting_room_id, "等待房间场景应成功实例化 UI 节点"),
		assert_eq(lobby_disconnects, 1, "创建房间成功后应断开大厅旧连接"),
	])


func test_waiting_room_upload_falls_back_to_server_deck_when_local_deck_missing() -> String:
	var backup_state := _backup_net_state()
	_reset_net_state_for_waiting_room()
	var waiting_room: Control = NetWaitingRoomScene.instantiate()
	var waiting_client := SpyWaitingClient.new()
	waiting_client.name = "NetworkClient"
	waiting_room._network_client = waiting_client
	waiting_room.add_child(waiting_client)
	waiting_room.call("_ready")
	waiting_room._local_decks = {
		101: {
			"id": 101,
			"deck_name": "Local Draft Deck",
			"total_cards": 60,
			"cards": [],
		}
	}
	waiting_room._server_decks = {}
	waiting_room.call("_refresh_deck_picker")
	waiting_client.save_deck_calls = 0
	waiting_room.call("_on_upload_pressed")

	var status_label: Label = waiting_room.get_node("CenterContainer/MainPanel/VBox/StatusLabel")
	var upload_btn: Button = waiting_room.get_node("CenterContainer/MainPanel/VBox/DeckRow/UploadBtn")
	var save_deck_calls := waiting_client.save_deck_calls
	var last_saved_deck_name := str(waiting_client.last_saved_deck_data.get("deck_name", ""))
	var status_text := status_label.text
	var upload_btn_text := upload_btn.text
	await _dispose_node(waiting_room)
	_restore_net_state(backup_state)

	return run_checks([
		assert_eq(save_deck_calls, 1, "选择本地草稿时应仅发布当前牌组到云端"),
		assert_eq(last_saved_deck_name, "Local Draft Deck", "发布到云端应使用当前本地草稿内容"),
		assert_true(status_text.contains("发布"), "发布到云端后应显示发布状态"),
		assert_eq(upload_btn_text, "发布到云端", "选择本地草稿时按钮应显示发布到云端"),
	])


func test_waiting_room_does_not_auto_upload_all_local_decks_on_connect() -> String:
	var backup_state := _backup_net_state()
	_reset_net_state_for_waiting_room()
	var waiting_room: Control = NetWaitingRoomScene.instantiate()
	var waiting_client := SpyWaitingClient.new()
	waiting_client.name = "NetworkClient"
	waiting_client.connected_state = false
	waiting_room._network_client = waiting_client
	waiting_room.add_child(waiting_client)
	waiting_room.call("_ready")
	waiting_room._local_decks = {
		301: {
			"id": 301,
			"deck_name": "Auto Publish Deck",
			"total_cards": 60,
			"cards": [],
		}
	}
	waiting_room._server_decks = {}
	waiting_room.call("_refresh_deck_picker")
	waiting_client.save_deck_calls = 0
	waiting_client.list_server_decks_calls = 0
	waiting_client.connected_state = true
	waiting_room.call("_on_connected")
	var save_deck_calls := waiting_client.save_deck_calls
	var list_server_decks_calls := waiting_client.list_server_decks_calls
	await _dispose_node(waiting_room)
	_restore_net_state(backup_state)

	return run_checks([
		assert_eq(save_deck_calls, 1, "等待房间连接后应默认自动上传当前选中的本地牌组"),
		assert_eq(list_server_decks_calls, 1, "等待房间连接后应仅拉取云端牌组列表"),
	])


func test_waiting_room_local_draft_selection_sends_payload_with_local_source() -> String:
	var backup_state := _backup_net_state()
	_reset_net_state_for_waiting_room()
	var waiting_room: Control = NetWaitingRoomScene.instantiate()
	var waiting_client := SpyWaitingClient.new()
	waiting_client.name = "NetworkClient"
	waiting_client.connected_state = false
	waiting_room._network_client = waiting_client
	waiting_room.add_child(waiting_client)
	waiting_room.call("_ready")
	waiting_room._local_decks = {
		202: {
			"id": 202,
			"deck_name": "Selectable Local Deck",
			"total_cards": 60,
			"cards": [],
		}
	}
	waiting_room._server_decks = {}
	waiting_client.select_deck_calls = 0
	waiting_client.save_deck_calls = 0
	waiting_room.call("_refresh_deck_picker")
	waiting_client.connected_state = true
	waiting_room.call("_on_connected")
	var upload_btn: Button = waiting_room.get_node("CenterContainer/MainPanel/VBox/DeckRow/UploadBtn")
	var select_deck_calls := waiting_client.select_deck_calls
	var save_deck_calls := waiting_client.save_deck_calls
	var last_selected_deck_id := waiting_client.last_selected_deck_id
	var last_selected_deck_source := waiting_client.last_selected_deck_source
	var last_selected_deck_name := str(waiting_client.last_selected_deck_data.get("deck_name", ""))
	var upload_btn_text := upload_btn.text
	await _dispose_node(waiting_room)
	_restore_net_state(backup_state)

	return run_checks([
		assert_gte(select_deck_calls, 1, "本地草稿应在等待房附着后自动发送当前选择"),
		assert_gte(save_deck_calls, 1, "本地草稿应默认自动发布到云端"),
		assert_eq(last_selected_deck_id, 202, "本地草稿选择应发送正确的 deck_id"),
		assert_eq(last_selected_deck_source, NetProtocol.DECK_SOURCE_LOCAL_DRAFT, "本地草稿选择应带 local_draft 来源标记"),
		assert_eq(last_selected_deck_name, "Selectable Local Deck", "本地草稿选择应携带完整 deck_data"),
		assert_eq(upload_btn_text, "发布到云端", "本地草稿选择应允许发布到云端"),
	])

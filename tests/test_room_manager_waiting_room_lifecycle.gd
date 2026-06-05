class_name TestRoomManagerWaitingRoomLifecycle
extends TestBase


func test_room_list_hides_waiting_room_when_host_disconnects() -> String:
	var manager := RoomManager.new()
	manager.setup(func(_peer_id: int, _message: Dictionary) -> void:
		pass
	)

	var room := GameRoom.new()
	room.room_id = "room-hide"
	room.room_name = "玩家A的房间"
	room.add_player(11, 0, "玩家A", "token-a")
	manager._rooms[room.room_id] = room

	var session := PlayerSession.new()
	session.peer_id = 11
	session.player_name = "玩家A"
	session.room_id = room.room_id
	session.player_index = 0
	session.session_token = "token-a"
	manager._player_sessions[11] = session
	manager._session_tokens[session.session_token] = session

	manager.handle_disconnect(11)
	var rooms: Array = manager.get_room_list()

	return run_checks([
		assert_eq(rooms.size(), 0, "房主断线后，等待房不应继续出现在大厅列表里"),
		assert_false(room.is_player_connected(0), "房主断线后房间内连接状态应标记为 false"),
	])


func test_expired_waiting_room_session_removes_empty_room() -> String:
	var manager := RoomManager.new()
	manager.setup(func(_peer_id: int, _message: Dictionary) -> void:
		pass
	)

	var room := GameRoom.new()
	room.room_id = "room-expire"
	room.room_name = "玩家B的房间"
	room.add_player(21, 0, "玩家B", "token-b")
	manager._rooms[room.room_id] = room

	var session := PlayerSession.new()
	session.peer_id = 21
	session.player_name = "玩家B"
	session.room_id = room.room_id
	session.player_index = 0
	session.session_token = "token-b"
	manager._player_sessions[21] = session
	manager._session_tokens[session.session_token] = session

	manager.handle_disconnect(21)
	session.disconnect_time = (Time.get_ticks_msec() / 1000.0) - PlayerSession.GRACE_PERIOD_SECONDS - 1.0
	manager.handle_tick(0.1)

	return run_checks([
		assert_false(manager._rooms.has(room.room_id), "等待房玩家断线超时后应回收空房间"),
		assert_false(manager._player_sessions.has(21), "断线超时会话应从会话表中移除"),
		assert_false(manager._session_tokens.has("token-b"), "断线超时会话应移除 session_token 映射"),
	])


func test_waiting_guest_disconnect_uses_grace_then_releases_slot() -> String:
	var sent_messages: Array = []
	var manager := RoomManager.new()
	manager.setup(func(peer_id: int, message: Dictionary) -> void:
		sent_messages.append({
			"peer_id": peer_id,
			"message": message,
		})
	)

	var room := GameRoom.new()
	room.room_id = "room-grace"
	room.room_name = "玩家A的房间"
	room.add_player(31, 0, "玩家A", "token-a")
	room.add_player(32, 1, "玩家B", "token-b")
	manager._rooms[room.room_id] = room

	var host_session := PlayerSession.new()
	host_session.peer_id = 31
	host_session.player_name = "玩家A"
	host_session.room_id = room.room_id
	host_session.player_index = 0
	host_session.session_token = "token-a"
	manager._player_sessions[31] = host_session
	manager._session_tokens[host_session.session_token] = host_session

	var guest_session := PlayerSession.new()
	guest_session.peer_id = 32
	guest_session.player_name = "玩家B"
	guest_session.room_id = room.room_id
	guest_session.player_index = 1
	guest_session.session_token = "token-b"
	manager._player_sessions[32] = guest_session
	manager._session_tokens[guest_session.session_token] = guest_session

	manager.handle_disconnect(32)
	var sent_after_disconnect := sent_messages.size()
	guest_session.disconnect_time = (Time.get_ticks_msec() / 1000.0) - RoomManager.WAITING_RECONNECT_GRACE_SECONDS - 0.1
	manager.handle_tick(0.1)
	var rooms: Array = manager.get_room_list()

	var room_update_sent := false
	for msg_variant: Variant in sent_messages:
		if not (msg_variant is Dictionary):
			continue
		var msg_dict: Dictionary = msg_variant
		var peer_id := int(msg_dict.get("peer_id", -1))
		var message: Dictionary = msg_dict.get("message", {}) if msg_dict.get("message") is Dictionary else {}
		if peer_id == 31 and str(message.get("type", "")) == NetProtocol.MSG_ROOM_UPDATE:
			var payload: Dictionary = message.get("payload", {}) if message.get("payload") is Dictionary else {}
			if str(payload.get("opponent_name", "__non_empty__")).is_empty():
				room_update_sent = true

	return run_checks([
		assert_eq(sent_after_disconnect, 0, "等待房客方断线在宽限期内不应立刻误报对手断线"),
		assert_eq(room.get_player_count(), 1, "等待房客方超过宽限未重连后应释放席位"),
		assert_false(manager._player_sessions.has(32), "等待房客方超过宽限后应移除会话映射"),
		assert_true(room.is_joinable(), "等待房客方席位释放后房间应可再次加入"),
		assert_eq(rooms.size(), 1, "大厅列表应重新展示可加入的等待房"),
		assert_eq(int(rooms[0].get("player_count", -1)), 1, "大厅列表中的等待房人数应回落到 1"),
		assert_true(room_update_sent, "客方席位释放后应向房主推送空对手 room_update"),
	])
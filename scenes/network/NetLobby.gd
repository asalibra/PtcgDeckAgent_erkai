## 网络对战大厅 - 房间列表、创建、加入
extends Control

const BattleReplayLocatorScript = preload("res://scripts/engine/BattleReplayLocator.gd")
const REPLAY_DETAIL_STALL_BASE_TIMEOUT_MSEC := 1500
const REPLAY_DETAIL_STALL_PER_CHUNK_MSEC := 250
const REPLAY_DETAIL_STALL_MAX_TIMEOUT_MSEC := 12000
const REPLAY_DETAIL_MAX_RETRIES := 2
const REQUEST_TIMEOUT_SEC := 8.0

var _network_client: NetworkClient
var _player_name: String = "玩家"
var _server_url: String = "ws://154.83.12.152:9000"
var _replay_locator: RefCounted = BattleReplayLocatorScript.new()
var _pending_replay_details: Dictionary = {}
var _pending_request: String = ""  # "create_room" / "join_room" / ""
var _request_start_msec: int = 0


func _ready() -> void:
	_load_prefs()
	_ensure_network_client()
	_setup_ui()
	_connect_signals()
	_update_status("请输入服务器地址并连接")


func _process(_delta: float) -> void:
	_tick_pending_replay_details(Time.get_ticks_msec())
	_tick_pending_request(Time.get_ticks_msec())


func _ensure_network_client() -> void:
	# NetworkClient 作为子节点动态创建
	if _network_client != null:
		return
	_network_client = NetworkClient.new()
	_network_client.name = "NetworkClient"
	add_child(_network_client)


func _setup_ui() -> void:
	%ServerUrlEdit.text = _server_url
	%PlayerNameEdit.text = _player_name
	%RoomListContainer.visible = false
	%CreateRoomPanel.visible = false
	%ReplayPanel.visible = false
	%ConnectBtn.pressed.connect(_on_connect_pressed)
	%RefreshBtn.pressed.connect(_on_refresh_pressed)
	%CreateRoomBtn.pressed.connect(_on_create_room_pressed)
	%ConfirmCreateBtn.pressed.connect(_on_confirm_create_pressed)
	%CancelCreateBtn.pressed.connect(_on_cancel_create_pressed)
	%BackBtn.pressed.connect(_on_back_pressed)
	%ReplaysBtn.pressed.connect(_on_replays_pressed)
	%CloseReplayBtn.pressed.connect(_on_close_replay_pressed)


func _connect_signals() -> void:
	_network_client.connected.connect(_on_connected)
	_network_client.disconnected.connect(_on_disconnected)
	_network_client.message_received.connect(_on_message_received)
	_network_client.connection_error.connect(_on_connection_error)


func _update_status(text: String) -> void:
	%StatusLabel.text = text


func _show_room_list_panel() -> void:
	%ReplayPanel.visible = false
	%CreateRoomPanel.visible = false
	%RoomListContainer.visible = _network_client != null and _network_client.is_connected_to_server()


func _show_replay_panel() -> void:
	%RoomListContainer.visible = false
	%CreateRoomPanel.visible = false
	%ReplayPanel.visible = true


# ===================== 按钮事件 =====================

func _on_connect_pressed() -> void:
	_server_url = %ServerUrlEdit.text.strip_edges()
	_player_name = %PlayerNameEdit.text.strip_edges()
	if _player_name.is_empty():
		_player_name = "玩家"
	_save_prefs()
	_update_status("正在连接...")
	%ConnectBtn.disabled = true
	_network_client.connect_to_server(_server_url)


func _on_refresh_pressed() -> void:
	_network_client.list_rooms()


func _on_create_room_pressed() -> void:
	%ReplayPanel.visible = false
	%CreateRoomPanel.visible = true
	%RoomNameEdit.text = "%s的房间" % _player_name


func _on_confirm_create_pressed() -> void:
	var room_name: String = %RoomNameEdit.text.strip_edges()
	if room_name.is_empty():
		room_name = "房间"
	_network_client.create_room(room_name, _player_name)
	_pending_request = "create_room"
	_request_start_msec = Time.get_ticks_msec()
	_update_status("正在创建房间...")


func _on_cancel_create_pressed() -> void:
	%CreateRoomPanel.visible = false


func _on_back_pressed() -> void:
	_network_client.disconnect_from_server()
	GameManager.goto_main_menu()


func _on_replays_pressed() -> void:
	if not _network_client.is_connected_to_server():
		_update_status("请先连接服务器")
		return
	_show_replay_panel()
	_network_client.list_replays()
	_update_status("正在获取回放列表...")


func _on_close_replay_pressed() -> void:
	_pending_replay_details.clear()
	_show_room_list_panel()


func _on_join_room(room_id: String) -> void:
	_network_client.join_room(room_id, _player_name)
	_pending_request = "join_room"
	_request_start_msec = Time.get_ticks_msec()
	_update_status("正在加入房间...")


# ===================== 网络事件 =====================

func _on_connected() -> void:
	%ConnectBtn.disabled = false
	# 如果有保存的会话信息，尝试重连
	if not GameManager.net_session_token.is_empty() and not GameManager.net_room_id.is_empty():
		_update_status("已连接，正在尝试恢复房间...")
		_network_client.reconnect(GameManager.net_session_token)
		return
	_update_status("已连接，正在获取房间列表...")
	_show_room_list_panel()
	_network_client.list_rooms()


func _on_disconnected(reason: String) -> void:
	%ConnectBtn.disabled = false
	_pending_request = ""
	_pending_replay_details.clear()
	%RoomListContainer.visible = false
	%ReplayPanel.visible = false
	%CreateRoomPanel.visible = false
	_update_status("连接断开: %s" % reason)


func _on_connection_error(error: String) -> void:
	%ConnectBtn.disabled = false
	_pending_request = ""
	_update_status("连接失败: %s" % error)


func _on_message_received(message: Dictionary) -> void:
	var type: String = str(message.get("type", ""))
	var payload: Dictionary = message.get("payload", {}) if message.get("payload") is Dictionary else {}
	if NetProtocol.is_resync_required(message):
		_handle_resync_required(payload)
		return

	match type:
		NetProtocol.MSG_ROOM_LIST:
			_display_room_list(payload.get("rooms", []))

		NetProtocol.MSG_ROOM_CREATED:
			_pending_request = ""
			GameManager.net_room_id = str(payload.get("room_id", ""))
			GameManager.net_player_index = int(payload.get("player_index", 0))
			GameManager.net_session_token = str(payload.get("session_token", ""))
			GameManager.net_server_url = _server_url
			_save_prefs()
			_network_client.disconnect_from_server()
			GameManager.goto_scene(GameManager.SCENE_NET_WAITING)

		NetProtocol.MSG_ROOM_JOINED:
			_pending_request = ""
			GameManager.net_room_id = str(payload.get("room_id", ""))
			GameManager.net_player_index = int(payload.get("player_index", 1))
			GameManager.net_session_token = str(payload.get("session_token", ""))
			GameManager.net_server_url = _server_url
			_save_prefs()
			_network_client.disconnect_from_server()
			GameManager.goto_scene(GameManager.SCENE_NET_WAITING)

		NetProtocol.MSG_RECONNECTED:
			# 重连成功，恢复房间状态并跳转
			GameManager.net_room_id = str(payload.get("room_id", ""))
			GameManager.net_player_index = int(payload.get("player_index", 0))
			_save_prefs()
			var room_state: String = str(payload.get("room_state", NetProtocol.ROOM_STATE_WAITING))
			if room_state == NetProtocol.ROOM_STATE_WAITING:
				_network_client.disconnect_from_server()
				GameManager.goto_scene(GameManager.SCENE_NET_WAITING)
			else:
				_update_status("已恢复连接，正在同步对局状态...")

		NetProtocol.MSG_STATE_UPDATE:
			# 游戏已开始，直接进入对战
			_network_client.disconnect_from_server()
			GameManager.goto_net_battle()

		NetProtocol.MSG_REPLAY_LIST:
			_display_replay_list(payload.get("replays", []))

		NetProtocol.MSG_REPLAY_DATA:
			_handle_replay_data(payload)

		NetProtocol.MSG_REPLAY_DETAIL_CHUNK:
			_handle_replay_detail_chunk(payload)

		NetProtocol.MSG_ERROR:
			_pending_request = ""
			var err_msg: String = str(payload.get("message", "未知错误"))
			# 仅在重连失败时清除会话
			if not GameManager.net_session_token.is_empty():
				GameManager.clear_saved_net_session()
				_save_prefs()
			_update_status("错误: %s" % err_msg)
			%CreateRoomPanel.visible = false
			_show_room_list_panel()
			if _network_client.is_connected_to_server():
				_network_client.list_rooms()


func _handle_resync_required(payload: Dictionary) -> void:
	_pending_request = ""
	var message := str(payload.get("message", "客户端状态已过期，正在重新同步..."))
	_update_status(message)
	if not GameManager.net_session_token.is_empty() and _network_client.is_connected_to_server():
		_network_client.reconnect(GameManager.net_session_token)
		return
	_update_status("%s 无法自动恢复，请重新进入房间。" % message)


func _display_replay_list(replays: Array) -> void:
	for child in %ReplayListVBox.get_children():
		child.queue_free()

	if replays.is_empty():
		var label := Label.new()
		label.text = "暂无对局记录"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		%ReplayListVBox.add_child(label)
		_update_status("暂无对局记录")
		return

	for replay_data in replays:
		if not replay_data is Dictionary:
			continue
		var match_id: String = str(replay_data.get("match_id", ""))
		var player_names: Array = replay_data.get("player_names", [])
		var deck_names: Array = replay_data.get("deck_names", [])
		var winner_index: int = int(replay_data.get("winner_index", -1))
		var turn_count: int = int(replay_data.get("turn_count", 0))
		var reason: String = str(replay_data.get("reason", ""))

		var row := HBoxContainer.new()
		var label := Label.new()
		var p0: String = str(player_names[0]) if player_names.size() > 0 else "?"
		var p1: String = str(player_names[1]) if player_names.size() > 1 else "?"
		var winner_mark := ""
		if winner_index == 0:
			winner_mark = " [胜]"
		elif winner_index == 1:
			winner_mark = ""
		var winner_mark2 := ""
		if winner_index == 1:
			winner_mark2 = " [胜]"
		elif winner_index == 0:
			winner_mark2 = ""
		label.text = "%s%s vs %s%s | %d回合 | %s" % [p0, winner_mark, p1, winner_mark2, turn_count, reason]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		row.add_child(label)

		var view_btn := Button.new()
		view_btn.text = "查看"
		var mid := match_id
		view_btn.pressed.connect(func(): _open_replay_entry(mid))
		row.add_child(view_btn)

		%ReplayListVBox.add_child(row)

	_update_status("共 %d 场对局记录" % replays.size())


func _open_replay_entry(match_id: String) -> void:
	if _try_launch_local_replay(match_id):
		return
	_update_status("正在获取回放详情...")
	_network_client.get_replay(match_id)


func _try_launch_local_replay(match_id: String) -> bool:
	if match_id.strip_edges() == "":
		return false
	var match_dir := "user://match_records/%s" % match_id
	var global_dir := ProjectSettings.globalize_path(match_dir)
	if not DirAccess.dir_exists_absolute(global_dir):
		return false
	if _replay_locator == null or not _replay_locator.has_method("locate"):
		return false
	var located_variant: Variant = _replay_locator.call("locate", match_dir)
	if not (located_variant is Dictionary):
		return false
	var located: Dictionary = located_variant
	if located.is_empty():
		return false
	GameManager.set_battle_replay_launch({
		"match_dir": match_dir,
		"entry_turn_number": int(located.get("entry_turn_number", 0)),
		"entry_source": str(located.get("entry_source", "unknown")),
		"turn_numbers": (located.get("turn_numbers", []) as Array).duplicate(true),
	})
	_network_client.disconnect_from_server()
	GameManager.goto_battle()
	return true


func _display_replay_detail(replay: Dictionary) -> void:
	var match_id: String = str(replay.get("match_id", ""))
	if _try_launch_local_replay(match_id):
		return
	if _stage_remote_replay(match_id, replay) and _try_launch_local_replay(match_id):
		return
	var meta: Dictionary = replay.get("meta", {})
	var result: Dictionary = replay.get("result", {})
	var turns_data: Dictionary = replay.get("turns", {})
	var turns: Array = turns_data.get("turns", [])
	var player_names: Array = meta.get("player_labels", [])
	var winner_index: int = int(result.get("winner_index", -1))
	var reason: String = str(result.get("reason", ""))

	var detail_text := "--- 对局回放: %s ---\n" % match_id
	detail_text += "玩家: %s vs %s\n" % [
		str(player_names[0]) if player_names.size() > 0 else "?",
		str(player_names[1]) if player_names.size() > 1 else "?"
	]
	detail_text += "结果: %s 获胜 (%s)\n" % [
		str(player_names[winner_index]) if winner_index >= 0 and winner_index < player_names.size() else "?",
		reason
	]
	detail_text += "回合数: %d\n\n" % turns.size()

	for turn_variant in turns:
		if not turn_variant is Dictionary:
			continue
		var turn: Dictionary = turn_variant
		var turn_num: int = int(turn.get("turn_number", 0))
		var key_actions: Array = turn.get("key_actions", [])
		if key_actions.is_empty():
			continue
		detail_text += "第%d回合:\n" % turn_num
		for action_variant in key_actions:
			if not action_variant is Dictionary:
				continue
			var action: Dictionary = action_variant
			var desc: String = str(action.get("description", ""))
			if not desc.is_empty():
				detail_text += "  - %s\n" % desc
		detail_text += "\n"

	# 用弹窗显示（简单实现）
	var dialog := AcceptDialog.new()
	dialog.title = "对局回放"
	dialog.dialog_text = detail_text
	dialog.initial_size = Vector2i(500, 400)
	add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(func(): dialog.queue_free())


func _handle_replay_data(replay: Dictionary) -> void:
	var match_id: String = str(replay.get("match_id", ""))
	var chunk_count: int = int(replay.get("detail_chunk_count", 0))
	if chunk_count <= 1:
		_display_replay_detail(replay)
		return
	var now_msec: int = Time.get_ticks_msec()
	var existing_pending: Dictionary = _pending_replay_details.get(match_id, {}) if _pending_replay_details.has(match_id) else {}
	var chunks: Array = []
	if not existing_pending.is_empty() and int(existing_pending.get("total_chunks", 0)) == chunk_count:
		var existing_chunks: Variant = existing_pending.get("chunks", [])
		if existing_chunks is Array:
			chunks = (existing_chunks as Array).duplicate(true)
	if chunks.is_empty():
		chunks.resize(chunk_count)
	var pending := {
		"replay": replay.duplicate(true),
		"total_chunks": chunk_count,
		"chunks": chunks,
		"retry_count": int(existing_pending.get("retry_count", 0)),
		"last_progress_msec": now_msec,
	}
	_pending_replay_details[match_id] = pending
	_update_status("正在接收回放详情... (%d/%d)" % [_count_received_replay_detail_chunks(chunks), chunk_count])


func _handle_replay_detail_chunk(payload: Dictionary) -> void:
	var match_id: String = str(payload.get("match_id", ""))
	if match_id.is_empty() or not _pending_replay_details.has(match_id):
		return
	var pending: Dictionary = _pending_replay_details[match_id]
	var total_chunks: int = int(pending.get("total_chunks", 0))
	var chunk_index: int = int(payload.get("chunk_index", -1))
	if chunk_index < 0 or chunk_index >= total_chunks:
		return
	var chunks: Array = pending.get("chunks", [])
	if chunk_index >= chunks.size():
		return
	chunks[chunk_index] = (payload.get("detail_events", []) as Array).duplicate(true)
	pending["chunks"] = chunks
	pending["last_progress_msec"] = Time.get_ticks_msec()
	_pending_replay_details[match_id] = pending
	var received_count: int = _count_received_replay_detail_chunks(chunks)
	_update_status("正在接收回放详情... (%d/%d)" % [received_count, total_chunks])
	if received_count < total_chunks:
		return
	var replay: Dictionary = pending.get("replay", {}) if pending.get("replay", {}) is Dictionary else {}
	var detail_events: Array = []
	for chunk_variant: Variant in chunks:
		if chunk_variant is Array:
			for event_variant: Variant in chunk_variant:
				if event_variant is Dictionary:
					detail_events.append((event_variant as Dictionary).duplicate(true))
	replay["detail_events"] = detail_events
	_pending_replay_details.erase(match_id)
	_display_replay_detail(replay)


func _tick_pending_request(now_msec: int) -> void:
	if _pending_request.is_empty():
		return
	var elapsed_sec := (now_msec - _request_start_msec) / 1000.0
	if elapsed_sec < REQUEST_TIMEOUT_SEC:
		return
	var req_name := "请求"
	match _pending_request:
		"create_room":
			req_name = "创建房间"
		"join_room":
			req_name = "加入房间"
	_pending_request = ""
	_update_status("%s超时，请检查服务器地址后重试" % req_name)
	%ConnectBtn.disabled = false
	%CreateRoomPanel.visible = false


func _tick_pending_replay_details(now_msec: int) -> void:
	if _pending_replay_details.is_empty():
		return
	var failed_match_ids: Array[String] = []
	for match_id_variant: Variant in _pending_replay_details.keys():
		var match_id := str(match_id_variant)
		var pending: Dictionary = _pending_replay_details.get(match_id, {}) if _pending_replay_details.has(match_id) else {}
		if pending.is_empty():
			continue
		var total_chunks: int = int(pending.get("total_chunks", 0))
		if total_chunks <= 0:
			failed_match_ids.append(match_id)
			continue
		var last_progress_msec: int = int(pending.get("last_progress_msec", 0))
		if now_msec - last_progress_msec < _replay_detail_stall_timeout_msec(total_chunks):
			continue
		var retry_count: int = int(pending.get("retry_count", 0))
		var pending_chunks: Array = pending.get("chunks", []) as Array
		var received_count: int = _count_received_replay_detail_chunks(pending_chunks)
		if _network_client != null and _network_client.is_connected_to_server() and retry_count < REPLAY_DETAIL_MAX_RETRIES:
			pending["retry_count"] = retry_count + 1
			pending["last_progress_msec"] = now_msec
			_pending_replay_details[match_id] = pending
			_update_status("回放详情接收超时，正在重试... (%d/%d，已收 %d/%d)" % [retry_count + 1, REPLAY_DETAIL_MAX_RETRIES, received_count, total_chunks])
			_network_client.get_replay(match_id)
			continue
		failed_match_ids.append(match_id)
	for match_id: String in failed_match_ids:
		_pending_replay_details.erase(match_id)
	if not failed_match_ids.is_empty():
		_update_status("回放详情接收失败，请重试")


func _replay_detail_stall_timeout_msec(total_chunks: int) -> int:
	var safe_chunk_count: int = maxi(1, total_chunks)
	return mini(
		REPLAY_DETAIL_STALL_MAX_TIMEOUT_MSEC,
		REPLAY_DETAIL_STALL_BASE_TIMEOUT_MSEC + safe_chunk_count * REPLAY_DETAIL_STALL_PER_CHUNK_MSEC
	)


func _count_received_replay_detail_chunks(chunks: Array) -> int:
	var received_count := 0
	for chunk_variant: Variant in chunks:
		if chunk_variant is Array:
			received_count += 1
	return received_count


func _stage_remote_replay(match_id: String, replay: Dictionary) -> bool:
	if match_id.strip_edges() == "":
		return false
	var turns_variant: Variant = replay.get("turns", {})
	var detail_variant: Variant = replay.get("detail_events", [])
	if not (turns_variant is Dictionary) or not (detail_variant is Array):
		return false
	var match_dir := "user://match_records/%s" % match_id
	var global_dir := ProjectSettings.globalize_path(match_dir)
	var ensure_error := DirAccess.make_dir_recursive_absolute(global_dir)
	if ensure_error != OK and not DirAccess.dir_exists_absolute(global_dir):
		return false
	var match_payload := replay.duplicate(true)
	match_payload.erase("turns")
	match_payload.erase("detail_events")
	if not _write_json_file(match_dir.path_join("match.json"), match_payload):
		return false
	if not _write_json_file(match_dir.path_join("turns.json"), turns_variant as Dictionary):
		return false
	if not _write_json_lines_file(match_dir.path_join("detail.jsonl"), detail_variant as Array):
		return false
	return true


func _write_json_file(path: String, payload: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return true


func _write_json_lines_file(path: String, rows: Array) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	for row_variant: Variant in rows:
		if row_variant is Dictionary:
			file.store_line(JSON.stringify(row_variant))
	file.close()
	return true


func _display_room_list(rooms: Array) -> void:
	# 清空现有列表
	for child in %RoomListVBox.get_children():
		child.queue_free()

	if rooms.is_empty():
		var label := Label.new()
		label.text = "暂无可用房间"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		%RoomListVBox.add_child(label)
		return

	for room_data in rooms:
		if not room_data is Dictionary:
			continue
		var room_id: String = str(room_data.get("room_id", ""))
		var room_name: String = str(room_data.get("room_name", "房间"))
		var player_count: int = int(room_data.get("player_count", 0))

		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = "%s (%d/2人)" % [room_name, player_count]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var join_btn := Button.new()
		join_btn.text = "加入"
		join_btn.disabled = player_count >= 2
		var rid := room_id  # 捕获变量
		join_btn.pressed.connect(func(): _on_join_room(rid))
		row.add_child(join_btn)

		%RoomListVBox.add_child(row)

	_update_status("共 %d 个房间" % rooms.size())


# ===================== 偏好设置 =====================

func _load_prefs() -> void:
	var data := GameManager.load_net_prefs()
	if data is Dictionary:
		_player_name = str(data.get("player_name", "玩家"))
		_server_url = str(data.get("server_url", "ws://154.83.12.152:9000"))
		# 恢复会话信息（用于断线重连）
		GameManager.net_session_token = str(data.get("session_token", ""))
		GameManager.net_room_id = str(data.get("room_id", ""))
		GameManager.net_player_index = int(data.get("player_index", -1))


func _save_prefs() -> void:
	GameManager.save_net_prefs(_player_name, _server_url)

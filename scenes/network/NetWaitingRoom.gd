## 网络对战等待房间 - 选牌组、准备、开始游戏
extends Control

const NetClientLogScript := preload("res://scripts/network/NetClientLog.gd")
const RECOVERY_TIMEOUT_SEC := 10.0
const DECK_SOURCE_LOCAL_DRAFT := NetProtocol.DECK_SOURCE_LOCAL_DRAFT
const DECK_SOURCE_PUBLISHED := NetProtocol.DECK_SOURCE_PUBLISHED

var _network_client: NetworkClient
var _my_ready: bool = false
var _opponent_name: String = ""
var _opponent_ready: bool = false
var _selected_deck_id: int = -1
var _selected_deck_source: String = ""
var _local_decks: Dictionary = {}  # deck_id -> deck_dict（本地草稿）
var _server_decks: Dictionary = {}  # deck_id -> deck_dict（从服务器获取）
var _recovery_in_progress: bool = false
var _recovery_start_msec: int = 0
var _ui_ok: bool = false
var _last_auto_published_signature: String = ""
var _room_session_attached: bool = false


func _ready() -> void:
	NetClientLogScript.begin_session("net_waiting_room", {
		"room_id": GameManager.net_room_id,
		"server_url": GameManager.net_server_url,
	})
	_ui_ok = _validate_ui_nodes()
	if not _ui_ok:
		NetClientLogScript.log_error("waiting_ui_missing", "required_nodes_missing", {
			"scene": get_scene_file_path(),
			"room_id": GameManager.net_room_id,
		})
		call_deferred("_return_to_lobby")
		return
	_load_local_decks()
	_ensure_network_client()
	_setup_ui()
	_refresh_deck_picker()
	_update_status("等待对手加入...")


func _process(_delta: float) -> void:
	_tick_recovery(Time.get_ticks_msec())


func _ensure_network_client() -> void:
	if _network_client != null:
		return
	_network_client = NetworkClient.new()
	_network_client.name = "NetworkClient"
	add_child(_network_client)
	# 先连接信号，再连接服务器
	_network_client.connected.connect(_on_connected)
	_network_client.message_received.connect(_on_message_received)
	_network_client.disconnected.connect(_on_disconnected)
	_network_client.connection_error.connect(_on_connection_error)
	_network_client.connect_to_server(GameManager.net_server_url)


func _on_connected() -> void:
	if not _ui_ok:
		return
	if not GameManager.net_session_token.is_empty() and not GameManager.net_room_id.is_empty():
		_room_session_attached = false
		_start_recovery("waiting_room_attach")
		_update_status("已连接，正在恢复房间...")
		_network_client.reconnect(GameManager.net_session_token)
		return
	_room_session_attached = true
	_clear_recovery_state()
	_request_decks_and_sync_selection()


func _request_decks_and_sync_selection() -> void:
	# 房间附着成功后仅拉取云端已发布牌组，并同步当前选中的牌组。
	_network_client.list_server_decks()
	_send_selected_deck_if_connected()


func _setup_ui() -> void:
	%RoomIdLabel.text = "房间ID: %s" % GameManager.net_room_id
	%ShareLinkLabel.text = "分享链接: %s/play/%s" % [GameManager.net_server_url.replace("ws://", "http://").replace("wss://", "https://"), GameManager.net_room_id]
	%OpponentLabel.text = "等待对手..."
	%ReadyBtn.pressed.connect(_on_ready_pressed)
	%StartBtn.pressed.connect(_on_start_pressed)
	%LeaveBtn.pressed.connect(_on_leave_pressed)
	%UploadBtn.pressed.connect(_on_upload_pressed)
	%UploadBtn.text = "发布到云端"
	%StartBtn.visible = GameManager.net_player_index == 0
	%StartBtn.disabled = true
	_refresh_upload_button()


func _load_local_decks() -> void:
	_local_decks.clear()
	var local_decks: Array = CardDatabase.get_all_decks()
	for deck_variant: Variant in local_decks:
		if deck_variant is DeckData:
			var local_deck: DeckData = deck_variant
			if local_deck.id > 0:
				_local_decks[local_deck.id] = local_deck.to_dict()
		elif deck_variant is Dictionary:
			var fallback_deck := deck_variant as Dictionary
			var deck_id := int(fallback_deck.get("id", 0))
			if deck_id > 0 and not fallback_deck.is_empty():
				_local_decks[deck_id] = fallback_deck.duplicate(true)


func _refresh_deck_picker() -> void:
	%DeckOption.clear()
	var previous_deck_id := _selected_deck_id
	var previous_deck_source := _selected_deck_source
	var idx := 0
	var selected_index := -1

	for deck_id: int in _sorted_deck_ids(_local_decks):
		var local_deck: Dictionary = _local_decks.get(deck_id, {}) if _local_decks.get(deck_id, {}) is Dictionary else {}
		if local_deck.is_empty():
			continue
		%DeckOption.add_item(_deck_option_label(local_deck, DECK_SOURCE_LOCAL_DRAFT), deck_id)
		%DeckOption.set_item_metadata(idx, {
			"deck_id": deck_id,
			"deck_source": DECK_SOURCE_LOCAL_DRAFT,
		})
		if deck_id == previous_deck_id and previous_deck_source == DECK_SOURCE_LOCAL_DRAFT:
			selected_index = idx
		idx += 1

	for deck_id_variant: Variant in _server_decks.keys():
		var deck_id := int(deck_id_variant)
		var d: Dictionary = _server_decks.get(deck_id, {}) if _server_decks.get(deck_id, {}) is Dictionary else {}
		if d.is_empty() and _server_decks.get(deck_id_variant, {}) is Dictionary:
			d = _server_decks.get(deck_id_variant, {})
		if d.is_empty():
			continue
		%DeckOption.add_item(_deck_option_label(d, DECK_SOURCE_PUBLISHED), deck_id)
		%DeckOption.set_item_metadata(idx, {
			"deck_id": deck_id,
			"deck_source": DECK_SOURCE_PUBLISHED,
		})
		if deck_id == previous_deck_id and previous_deck_source == DECK_SOURCE_PUBLISHED:
			selected_index = idx
		idx += 1

	if idx == 0:
		_selected_deck_id = -1
		_selected_deck_source = ""
		_refresh_upload_button()
		return

	if selected_index < 0:
		selected_index = 0
	%DeckOption.select(selected_index)
	_apply_selected_deck_metadata(%DeckOption.get_item_metadata(selected_index))
	_refresh_upload_button()
	_send_selected_deck_if_connected()
	if not %DeckOption.item_selected.is_connected(_on_deck_selected):
		%DeckOption.item_selected.connect(_on_deck_selected)


func _on_deck_selected(index: int) -> void:
	_apply_selected_deck_metadata(%DeckOption.get_item_metadata(index))
	_refresh_upload_button()
	_send_selected_deck_if_connected()


func _apply_selected_deck_metadata(metadata: Variant) -> void:
	if metadata is Dictionary:
		_selected_deck_id = int(metadata.get("deck_id", -1))
		_selected_deck_source = str(metadata.get("deck_source", ""))
		return
	_selected_deck_id = -1
	_selected_deck_source = ""


func _send_selected_deck_if_connected() -> void:
	if _network_client == null or not _network_client.is_connected_to_server() or not _room_session_attached:
		return
	_auto_publish_selected_local_deck_if_needed()
	_send_deck_selection()


func _auto_publish_selected_local_deck_if_needed() -> void:
	if _selected_deck_source != DECK_SOURCE_LOCAL_DRAFT:
		return
	if not _local_decks.has(_selected_deck_id):
		return
	var deck_dict: Dictionary = _local_decks[_selected_deck_id]
	if deck_dict.is_empty():
		return
	var publish_signature := "%d:%s" % [_selected_deck_id, JSON.stringify(deck_dict)]
	if publish_signature == _last_auto_published_signature:
		return
	_last_auto_published_signature = publish_signature
	_network_client.save_deck_to_server(deck_dict)
	NetClientLogScript.log_event("waiting_auto_publish_selected_deck", {
		"room_id": GameManager.net_room_id,
		"deck_id": _selected_deck_id,
		"deck_name": str(deck_dict.get("deck_name", "")),
	})


func _send_deck_selection() -> void:
	if _selected_deck_id <= 0:
		return
	if _selected_deck_source == DECK_SOURCE_LOCAL_DRAFT and _local_decks.has(_selected_deck_id):
		_network_client.select_deck(_selected_deck_id, _local_decks[_selected_deck_id], DECK_SOURCE_LOCAL_DRAFT)
		return
	if _selected_deck_source == DECK_SOURCE_PUBLISHED:
		_network_client.select_deck(_selected_deck_id, {}, DECK_SOURCE_PUBLISHED)
		return
	_network_client.select_deck(_selected_deck_id)


func _on_ready_pressed() -> void:
	if not _room_session_attached:
		_update_status("正在恢复房间，请稍候...")
		return
	_my_ready = not _my_ready
	_network_client.set_ready(_my_ready)
	%ReadyBtn.text = "取消准备" if _my_ready else "准备"
	_update_start_button()


func _on_start_pressed() -> void:
	if not _room_session_attached:
		_update_status("正在恢复房间，请稍候...")
		return
	_network_client.start_game()


func _on_leave_pressed() -> void:
	_network_client.leave_room()
	_network_client.disconnect_from_server()
	GameManager.clear_saved_net_session()
	GameManager.goto_net_lobby()


func _on_upload_pressed() -> void:
	if _selected_deck_source != DECK_SOURCE_LOCAL_DRAFT:
		_update_status("当前选择的是云端已发布牌组")
		return
	if _local_decks.has(_selected_deck_id):
		_network_client.save_deck_to_server(_local_decks[_selected_deck_id])
		_update_status("正在发布牌组到云端...")
		return
	var deck: DeckData = CardDatabase.get_deck(_selected_deck_id)
	if deck != null:
		_network_client.save_deck_to_server(deck.to_dict())
		_update_status("正在发布牌组到云端...")
		return
	_update_status("当前选择的本地牌组不可用，无法发布")


func _refresh_upload_button() -> void:
	if not _ui_ok:
		return
	if _selected_deck_source == DECK_SOURCE_LOCAL_DRAFT and _selected_deck_id > 0:
		%UploadBtn.disabled = false
		%UploadBtn.text = "发布到云端"
		return
	if _selected_deck_source == DECK_SOURCE_PUBLISHED and _selected_deck_id > 0:
		%UploadBtn.disabled = true
		%UploadBtn.text = "已在云端"
		return
	%UploadBtn.disabled = true
	%UploadBtn.text = "发布到云端"


func _sorted_deck_ids(deck_map: Dictionary) -> Array[int]:
	var deck_ids: Array[int] = []
	for deck_id_variant: Variant in deck_map.keys():
		deck_ids.append(int(deck_id_variant))
	deck_ids.sort()
	return deck_ids


func _deck_option_label(deck_data: Dictionary, deck_source: String) -> String:
	var source_label := "[本地]"
	if deck_source == DECK_SOURCE_PUBLISHED:
		source_label = "[云端]"
	return "%s %s (%d张)" % [source_label, str(deck_data.get("deck_name", "?")), int(deck_data.get("total_cards", 0))]


func _validate_ui_nodes() -> bool:
	var required_paths: Array[String] = [
		"CenterContainer/MainPanel/VBox/RoomIdLabel",
		"CenterContainer/MainPanel/VBox/ShareLinkLabel",
		"CenterContainer/MainPanel/VBox/OpponentLabel",
		"CenterContainer/MainPanel/VBox/DeckRow/DeckOption",
		"CenterContainer/MainPanel/VBox/BtnRow/ReadyBtn",
		"CenterContainer/MainPanel/VBox/BtnRow/StartBtn",
		"CenterContainer/MainPanel/VBox/BtnRow/LeaveBtn",
		"CenterContainer/MainPanel/VBox/DeckRow/UploadBtn",
		"CenterContainer/MainPanel/VBox/StatusLabel",
	]
	for path: String in required_paths:
		if get_node_or_null(path) == null:
			push_warning("[NetWaitingRoom] 缺少节点: %s" % path)
			return false
	return true


func _update_start_button() -> void:
	if GameManager.net_player_index == 0:
		%StartBtn.disabled = (not _room_session_attached) or not (_my_ready and _opponent_ready)


func _update_status(text: String) -> void:
	%StatusLabel.text = text
	NetClientLogScript.log_event("waiting_status", {
		"text": text,
		"room_id": GameManager.net_room_id,
	})


func _update_opponent_label() -> void:
	if _opponent_name.is_empty():
		%OpponentLabel.text = "等待对手加入..."
		return
	%OpponentLabel.text = "对手: %s%s" % [_opponent_name, " (已准备)" if _opponent_ready else ""]


# ===================== 网络事件 =====================

func _on_disconnected(reason: String) -> void:
	_clear_recovery_state()
	_update_status("连接断开: %s" % reason)


func _on_connection_error(error: String) -> void:
	_clear_recovery_state()
	_update_status("连接失败: %s" % error)
	# 连接失败，延迟返回大厅
	await get_tree().create_timer(2.0).timeout
	_return_to_lobby()


func _return_to_lobby() -> void:
	if _network_client != null:
		_network_client.disconnect_from_server()
	GameManager.clear_saved_net_session()
	GameManager.goto_net_lobby()


func _on_message_received(message: Dictionary) -> void:
	var type: String = str(message.get("type", ""))
	var payload: Dictionary = message.get("payload", {}) if message.get("payload") is Dictionary else {}
	print("[NetWaitingRoom] 收到消息: %s" % type)
	if NetProtocol.is_resync_required(message):
		_handle_resync_required(payload)
		return

	match type:
		NetProtocol.MSG_RECONNECTED:
			_clear_recovery_state()
			_room_session_attached = true
			GameManager.net_room_id = str(payload.get("room_id", GameManager.net_room_id))
			GameManager.net_player_index = int(payload.get("player_index", GameManager.net_player_index))
			%StartBtn.visible = GameManager.net_player_index == 0
			_opponent_name = str(payload.get("opponent_name", ""))
			_opponent_ready = bool(payload.get("opponent_ready", false))
			var room_state: String = str(payload.get("room_state", NetProtocol.ROOM_STATE_WAITING))
			_update_opponent_label()
			if room_state == NetProtocol.ROOM_STATE_WAITING:
				_request_decks_and_sync_selection()
			_update_start_button()
			if room_state != NetProtocol.ROOM_STATE_WAITING:
				_update_status("已恢复连接，正在同步对局状态...")

		NetProtocol.MSG_ROOM_UPDATE:
			_opponent_name = str(payload.get("opponent_name", ""))
			_opponent_ready = bool(payload.get("opponent_ready", false))
			_update_opponent_label()
			_update_start_button()

		NetProtocol.MSG_GAME_STARTING:
			var first_player := int(payload.get("first_player_index", -1))
			GameManager.first_player_choice = first_player
			GameManager.goto_net_battle()

		NetProtocol.MSG_STATE_UPDATE:
			_clear_recovery_state()
			_network_client.disconnect_from_server()
			GameManager.goto_net_battle()

		NetProtocol.MSG_DECK_LIST:
			# 服务器牌组列表
			_server_decks.clear()
			var decks_raw: Array = payload.get("decks", [])
			for d: Variant in decks_raw:
				if d is Dictionary:
					var did: int = int(d.get("id", 0))
					if did > 0:
						_server_decks[did] = d
			_refresh_deck_picker()
			_update_status("已加载 %d 个本地牌组，%d 个云端牌组" % [_local_decks.size(), _server_decks.size()])

		NetProtocol.MSG_DECK_SAVED:
			if _selected_deck_source == DECK_SOURCE_LOCAL_DRAFT and _local_decks.has(_selected_deck_id):
				CardDatabase.mark_deck_published_dict(_local_decks[_selected_deck_id])
			_update_status("牌组已发布到云端!")
			_network_client.list_server_decks()

		NetProtocol.MSG_ERROR:
			_clear_recovery_state()
			var err_msg: String = str(payload.get("message", "未知错误"))
			_update_status("错误: %s" % err_msg)
			# 重连失败，返回大厅
			await get_tree().create_timer(2.0).timeout
			_return_to_lobby()

		NetProtocol.MSG_OPPONENT_DISCONNECTED:
			%OpponentLabel.text = "对手已断线，等待重连..."
			_opponent_ready = false
			_update_start_button()

		NetProtocol.MSG_OPPONENT_RECONNECTED:
			var r_name: String = str(payload.get("opponent_name", ""))
			var r_ready: bool = bool(payload.get("opponent_ready", false))
			if not r_name.is_empty():
				_opponent_name = r_name
			_opponent_ready = r_ready
			_update_opponent_label()
			_update_start_button()


func _handle_resync_required(payload: Dictionary) -> void:
	var message := str(payload.get("message", "客户端状态已过期，正在重新同步..."))
	_update_status(message)
	if not GameManager.net_session_token.is_empty() and _network_client.is_connected_to_server():
		_start_recovery("resync_required")
		_network_client.reconnect(GameManager.net_session_token)
		return
	_update_status("%s 无法自动恢复，请重新进入房间。" % message)


func _start_recovery(reason: String) -> void:
	_recovery_in_progress = true
	_recovery_start_msec = Time.get_ticks_msec()
	NetClientLogScript.log_event("waiting_recovery_start", {
		"reason": reason,
		"room_id": GameManager.net_room_id,
	})


func _clear_recovery_state() -> void:
	_recovery_in_progress = false
	_recovery_start_msec = 0


func _tick_recovery(now_msec: int) -> void:
	if not _recovery_in_progress:
		return
	var elapsed_sec := (now_msec - _recovery_start_msec) / 1000.0
	if elapsed_sec < RECOVERY_TIMEOUT_SEC:
		return
	_clear_recovery_state()
	NetClientLogScript.log_error("waiting_recovery_timeout", "reconnect_timeout", {
		"room_id": GameManager.net_room_id,
		"elapsed_sec": elapsed_sec,
	})
	_update_status("恢复房间超时，请重新进入房间")
	_return_to_lobby()

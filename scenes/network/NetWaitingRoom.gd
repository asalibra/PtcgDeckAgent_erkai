## 网络对战等待房间 - 选牌组、准备、开始游戏
extends Control

var _network_client: NetworkClient
var _my_ready: bool = false
var _opponent_name: String = ""
var _opponent_ready: bool = false
var _selected_deck_id: int = -1
var _server_decks: Dictionary = {}  # deck_id -> deck_dict（从服务器获取）


func _ready() -> void:
	_ensure_network_client()
	_setup_ui()
	_refresh_deck_picker()
	_update_status("等待对手加入...")


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
	_network_client.connect_to_server(GameManager.net_server_url)


func _on_connected() -> void:
	# 重连或请求服务器牌组
	if not GameManager.net_session_token.is_empty():
		_network_client.reconnect(GameManager.net_session_token)
	# 自动同步本地牌组到服务器
	_sync_local_decks_to_server()
	_network_client.list_server_decks()


func _setup_ui() -> void:
	%RoomIdLabel.text = "房间ID: %s" % GameManager.net_room_id
	%ShareLinkLabel.text = "分享链接: %s/play/%s" % [GameManager.net_server_url.replace("ws://", "http://").replace("wss://", "https://"), GameManager.net_room_id]
	%OpponentLabel.text = "等待对手..."
	%ReadyBtn.pressed.connect(_on_ready_pressed)
	%StartBtn.pressed.connect(_on_start_pressed)
	%LeaveBtn.pressed.connect(_on_leave_pressed)
	%UploadBtn.pressed.connect(_on_upload_pressed)
	%StartBtn.visible = GameManager.net_player_index == 0
	%StartBtn.disabled = true


func _sync_local_decks_to_server() -> void:
	var local_decks: Array = CardDatabase.get_all_decks()
	for deck: DeckData in local_decks:
		_network_client.save_deck_to_server(deck.to_dict())


func _refresh_deck_picker() -> void:
	%DeckOption.clear()
	var idx := 0

	# 只显示服务器牌组
	for deck_id: int in _server_decks:
		var d: Dictionary = _server_decks[deck_id]
		%DeckOption.add_item("%s (%d张)" % [d.get("deck_name", "?"), d.get("total_cards", 0)], deck_id)
		%DeckOption.set_item_metadata(idx, deck_id)
		idx += 1

	if idx > 0:
		_selected_deck_id = %DeckOption.get_item_metadata(0)
		_send_deck_selection()
	if not %DeckOption.item_selected.is_connected(_on_deck_selected):
		%DeckOption.item_selected.connect(_on_deck_selected)


func _on_deck_selected(index: int) -> void:
	_selected_deck_id = %DeckOption.get_item_metadata(index)
	_send_deck_selection()


func _send_deck_selection() -> void:
	if _server_decks.has(_selected_deck_id):
		_network_client.select_deck(_selected_deck_id, _server_decks[_selected_deck_id])
	else:
		_network_client.select_deck(_selected_deck_id)


func _on_ready_pressed() -> void:
	_my_ready = not _my_ready
	_network_client.set_ready(_my_ready)
	%ReadyBtn.text = "取消准备" if _my_ready else "准备"
	_update_start_button()


func _on_start_pressed() -> void:
	_network_client.start_game()


func _on_leave_pressed() -> void:
	_network_client.leave_room()
	_network_client.disconnect_from_server()
	GameManager.clear_saved_net_session()
	GameManager.goto_net_lobby()


func _on_upload_pressed() -> void:
	var deck: DeckData = CardDatabase.get_deck(_selected_deck_id)
	if deck == null:
		_update_status("当前选择的牌组不在本地，无法上传")
		return
	_network_client.save_deck_to_server(deck.to_dict())
	_update_status("正在上传牌组到服务器...")


func _update_start_button() -> void:
	if GameManager.net_player_index == 0:
		%StartBtn.disabled = not (_my_ready and _opponent_ready)


func _update_status(text: String) -> void:
	%StatusLabel.text = text


# ===================== 网络事件 =====================

func _on_disconnected(reason: String) -> void:
	_update_status("连接断开: %s" % reason)


func _on_message_received(message: Dictionary) -> void:
	var type: String = str(message.get("type", ""))
	var payload: Dictionary = message.get("payload", {}) if message.get("payload") is Dictionary else {}
	print("[NetWaitingRoom] 收到消息: %s" % type)

	match type:
		NetProtocol.MSG_RECONNECTED:
			_opponent_name = str(payload.get("opponent_name", ""))
			_opponent_ready = bool(payload.get("opponent_ready", false))
			var room_state: String = str(payload.get("room_state", NetProtocol.ROOM_STATE_WAITING))
			if not _opponent_name.is_empty():
				%OpponentLabel.text = "对手: %s%s" % [_opponent_name, " (已准备)" if _opponent_ready else ""]
			_update_start_button()
			if room_state != NetProtocol.ROOM_STATE_WAITING:
				_update_status("已恢复连接，正在同步对局状态...")

		NetProtocol.MSG_ROOM_UPDATE:
			_opponent_name = str(payload.get("opponent_name", ""))
			_opponent_ready = bool(payload.get("opponent_ready", false))
			%OpponentLabel.text = "对手: %s%s" % [_opponent_name, " (已准备)" if _opponent_ready else ""]
			_update_start_button()

		NetProtocol.MSG_GAME_STARTING:
			var first_player := int(payload.get("first_player_index", -1))
			GameManager.first_player_choice = first_player
			GameManager.goto_net_battle()

		NetProtocol.MSG_STATE_UPDATE:
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
			_update_status("已加载 %d 个服务器牌组" % _server_decks.size())

		NetProtocol.MSG_DECK_SAVED:
			_update_status("牌组已上传到服务器!")
			_network_client.list_server_decks()

		NetProtocol.MSG_ERROR:
			_update_status("错误: %s" % str(payload.get("message", "未知错误")))

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
			%OpponentLabel.text = "对手: %s%s" % [_opponent_name, " (已准备)" if _opponent_ready else ""]
			_update_start_button()

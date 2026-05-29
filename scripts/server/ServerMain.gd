## 服务器主入口 - headless 模式运行
extends SceneTree

var _network: ServerNetwork
var _room_manager: RoomManager
var _port: int = 9000
var _ping_timer: float = 0.0

const PING_INTERVAL := 15.0


func _initialize() -> void:
	_parse_args()

	print("========================================")
	print("  PTCG Deck Agent - 对战服务器")
	print("  端口: %d" % _port)
	print("========================================")

	# 手动加载 autoload（headless -s 模式不会自动加载）
	_init_autoloads()

	# 初始化房间管理器
	_room_manager = RoomManager.new()
	_room_manager.setup(_send_to_peer, Engine.get_singleton("CardDatabase"))
	_room_manager.init_server_decks()

	# 初始化网络层
	_network = ServerNetwork.new()
	_network.client_connected.connect(_on_client_connected)
	_network.client_disconnected.connect(_on_client_disconnected)
	_network.client_message_received.connect(_on_client_message)
	if not _network.start(_port):
		push_error("[ServerMain] 无法绑定端口 %d，服务器退出" % _port)
		quit(1)
		return

	print("[ServerMain] 服务器就绪，等待连接...")


func _process(delta: float) -> bool:
	if _network == null:
		return false

	_network.poll()
	_room_manager.handle_tick(delta)

	# 心跳
	_ping_timer += delta
	if _ping_timer >= PING_INTERVAL:
		_ping_timer = 0.0
		_send_ping()

	return false  # 返回 false 继续运行


func _finalize() -> void:
	if _network:
		_network.stop()
	print("[ServerMain] 服务器已关闭")


func _init_autoloads() -> void:
	# CardDatabase - headless -s 模式不加载 autoload，需手动初始化
	var cd_script = load("res://scripts/autoload/CardDatabase.gd")
	var cd_instance = cd_script.new()
	cd_instance.name = "CardDatabase"
	root.add_child(cd_instance)
	Engine.register_singleton("CardDatabase", cd_instance)
	cd_instance._ensure_directories()
	cd_instance._seed_bundled_user_data()
	cd_instance._load_all_decks()
	cd_instance._load_all_ai_decks()
	# 如果 user:// 没有牌组，直接从 bundled 目录加载
	if cd_instance._deck_cache.is_empty():
		print("[ServerMain] user://decks 为空，从 bundled 目录加载牌组...")
		cd_instance._deck_cache = _load_decks_from_manifest(cd_instance)
	print("[ServerMain] CardDatabase 已初始化，牌组数: %d" % cd_instance._deck_cache.size())


func _load_decks_from_manifest(cd_instance) -> Dictionary:
	var cache := {}
	var manifest_path := "res://data/bundled_user/_manifest.txt"
	print("[ServerMain] 检查 manifest: %s (exists=%s)" % [manifest_path, FileAccess.file_exists(manifest_path)])
	if not FileAccess.file_exists(manifest_path):
		# 回退：直接扫描 bundled 目录
		print("[ServerMain] manifest 不存在，尝试直接扫描 decks 目录...")
		return _load_decks_from_dir(cd_instance, "res://data/bundled_user/decks/")
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null:
		print("[ServerMain] 无法打开 manifest 文件")
		return _load_decks_from_dir(cd_instance, "res://data/bundled_user/decks/")
	var content := file.get_as_text()
	file.close()
	var lines := content.split("\n")
	var deck_count := 0
	for line: String in lines:
		line = line.strip_edges()
		if line.is_empty() or not line.begins_with("res://data/bundled_user/decks/"):
			continue
		deck_count += 1
		var deck = cd_instance._load_deck_from_file(line)
		if deck != null:
			cache[deck.id] = deck
		else:
			push_warning("[ServerMain] 牌组加载失败: %s" % line)
	print("[ServerMain] manifest 中 %d 条牌组路径，成功加载 %d 个" % [deck_count, cache.size()])
	if cache.is_empty() and deck_count > 0:
		# res:// 路径加载全部失败，尝试用全局路径
		print("[ServerMain] res:// 路径加载失败，尝试全局路径...")
		return _load_decks_from_dir(cd_instance, "res://data/bundled_user/decks/")
	return cache


func _load_decks_from_dir(cd_instance, dir_path: String) -> Dictionary:
	var cache := {}
	var global_path := ProjectSettings.globalize_path(dir_path)
	print("[ServerMain] 扫描目录: %s (global: %s)" % [dir_path, global_path])
	if not DirAccess.dir_exists_absolute(global_path):
		print("[ServerMain] 目录不存在: %s" % global_path)
		return cache
	var dir := DirAccess.open(global_path)
	if dir == null:
		print("[ServerMain] 无法打开目录: %s" % global_path)
		return cache
	dir.list_dir_begin()
	var file_name := dir.get_next()
	var count := 0
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var file_path := global_path.path_join(file_name)
			var deck = cd_instance._load_deck_from_file(file_path)
			if deck != null:
				cache[deck.id] = deck
				count += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	print("[ServerMain] 从目录加载 %d 个牌组" % count)
	return cache


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--port="):
			_port = int(arg.substr(7))
		elif arg.begins_with("--max-rooms="):
			pass # 未来扩展


func _on_client_connected(peer_id: int) -> void:
	print("[ServerMain] 客户端连接: %d" % peer_id)


func _on_client_disconnected(peer_id: int) -> void:
	_room_manager.handle_disconnect(peer_id)
	print("[ServerMain] 客户端断开: %d" % peer_id)


func _on_client_message(peer_id: int, message: Dictionary) -> void:
	_room_manager.handle_message(peer_id, message)


func _send_to_peer(peer_id: int, message: Dictionary) -> void:
	if _network:
		_network.send_message(peer_id, message)


func _send_ping() -> void:
	var ping_msg := NetProtocol.make_message(NetProtocol.MSG_PING)
	# 向所有连接的客户端发送心跳
	for room_id in _room_manager._rooms:
		var room: GameRoom = _room_manager._rooms[room_id]
		for pi in room._players.keys():
			var peer_id: int = room._players[pi]["peer_id"]
			_send_to_peer(peer_id, ping_msg)

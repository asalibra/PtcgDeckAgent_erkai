## 服务器网络层 - TCPServer + WebSocketPeer 管理连接
class_name ServerNetwork
extends RefCounted

signal client_connected(peer_id: int)
signal client_disconnected(peer_id: int)
signal client_message_received(peer_id: int, message: Dictionary)

var port: int = 9000
var max_clients: int = 100

var _tcp_server: TCPServer
var _clients: Dictionary = {}  # peer_id -> WebSocketPeer
var _outbound_queues: Dictionary = {}  # peer_id -> Array[String]
var _next_peer_id: int = 1
var _pending_connections: Array = []  # 等待 WebSocket 握手的 TCP 连接

const HANDSHAKE_TIMEOUT := 10.0
const PING_INTERVAL := 15.0
const MAX_SENDS_PER_POLL := 1
const WEBSOCKET_OUTBOUND_BUFFER_SIZE := 1024 * 1024
const WEBSOCKET_MAX_QUEUED_PACKETS := 8192


func start(listen_port: int) -> void:
	port = listen_port
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(port)
	if err != OK:
		push_error("[ServerNetwork] 监听端口 %d 失败: %s" % [port, error_string(err)])
		return
	print("[ServerNetwork] 服务器启动，监听端口 %d" % port)


func stop() -> void:
	for peer_id in _clients.keys():
		var ws: WebSocketPeer = _clients[peer_id]
		ws.close()
	_clients.clear()
	_outbound_queues.clear()
	if _tcp_server:
		_tcp_server.stop()
	print("[ServerNetwork] 服务器已停止")


func send_message(peer_id: int, message: Dictionary) -> void:
	if not _clients.has(peer_id):
		return
	var json_str := NetProtocol.dict_to_json_string(message)
	var queue: Array = _outbound_queues.get(peer_id, [])
	queue.append(json_str)
	_outbound_queues[peer_id] = queue


func disconnect_client(peer_id: int, reason: String = "") -> void:
	if not _clients.has(peer_id):
		return
	var ws: WebSocketPeer = _clients[peer_id]
	ws.close(1000, reason)
	_clients.erase(peer_id)
	client_disconnected.emit(peer_id)


func get_client_count() -> int:
	return _clients.size()


func poll() -> void:
	_accept_new_connections()
	_poll_existing_connections()


func _accept_new_connections() -> void:
	if _tcp_server == null:
		return
	while _tcp_server.is_connection_available():
		var tcp_peer: StreamPeerTCP = _tcp_server.take_connection()
		if tcp_peer == null:
			break
		var ws := WebSocketPeer.new()
		var err := ws.accept_stream(tcp_peer)
		if err != OK:
			push_error("[ServerNetwork] WebSocket 握手失败: %s" % error_string(err))
			continue
		ws.set_outbound_buffer_size(WEBSOCKET_OUTBOUND_BUFFER_SIZE)
		ws.set_max_queued_packets(WEBSOCKET_MAX_QUEUED_PACKETS)
		var peer_id := _next_peer_id
		_next_peer_id += 1
		_clients[peer_id] = ws
		_outbound_queues[peer_id] = []
		print("[ServerNetwork] 新连接: peer_id=%d" % peer_id)
		client_connected.emit(peer_id)


func _poll_existing_connections() -> void:
	var to_remove: Array = []
	for peer_id in _clients.keys():
		var ws: WebSocketPeer = _clients[peer_id]
		ws.poll()
		_flush_outbound_queue(peer_id, ws)
		var state := ws.get_ready_state()

		if state == WebSocketPeer.STATE_CLOSING:
			continue

		if state == WebSocketPeer.STATE_CLOSED:
			to_remove.append(peer_id)
			continue

		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet()
				var json_str := packet.get_string_from_utf8()
				var message := NetProtocol.json_string_to_dict(json_str)
				if message.is_empty():
					continue
				client_message_received.emit(peer_id, message)

	for peer_id in to_remove:
		_clients.erase(peer_id)
		_outbound_queues.erase(peer_id)
		print("[ServerNetwork] 连接断开: peer_id=%d" % peer_id)
		client_disconnected.emit(peer_id)


func _flush_outbound_queue(peer_id: int, ws) -> void:
	if ws == null or ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var queue: Array = _outbound_queues.get(peer_id, [])
	if queue.is_empty():
		return
	var sent_count: int = 0
	while not queue.is_empty() and sent_count < MAX_SENDS_PER_POLL:
		var payload: String = str(queue[0])
		var payload_bytes: int = payload.to_utf8_buffer().size()
		var outbound_buffer_size: int = int(ws.get_outbound_buffer_size()) if ws.has_method("get_outbound_buffer_size") else 0
		var current_buffered_amount: int = int(ws.get_current_outbound_buffered_amount()) if ws.has_method("get_current_outbound_buffered_amount") else 0
		if outbound_buffer_size > 0:
			if payload_bytes > outbound_buffer_size:
				push_warning("[ServerNetwork] 丢弃 peer %d 过大的单条消息: %d bytes > outbound buffer %d" % [peer_id, payload_bytes, outbound_buffer_size])
				queue.remove_at(0)
				continue
			if current_buffered_amount + payload_bytes > outbound_buffer_size:
				break
		var err: int = int(ws.send_text(payload))
		if err == OK:
			queue.remove_at(0)
			sent_count += 1
			continue
		if err == ERR_OUT_OF_MEMORY:
			break
		push_warning("[ServerNetwork] 发送 peer %d 消息失败: %s" % [peer_id, error_string(err)])
		queue.remove_at(0)
		break
	_outbound_queues[peer_id] = queue

class_name TestNetworkClientDisconnectRegression
extends TestBase


class FakeWebSocketPeer extends RefCounted:
	var packets: Array[String] = []
	var close_calls: int = 0

	func poll() -> void:
		pass

	func get_ready_state() -> int:
		return WebSocketPeer.STATE_OPEN

	func get_available_packet_count() -> int:
		return packets.size()

	func get_packet() -> PackedByteArray:
		if packets.is_empty():
			return PackedByteArray()
		return packets.pop_front().to_utf8_buffer()

	func send_text(_text: String) -> int:
		return OK

	func close() -> void:
		close_calls += 1

	func get_close_reason() -> String:
		return ""

	func get_close_code() -> int:
		return 1000


func test_network_client_stops_draining_when_callback_disconnects_socket() -> String:
	var client := NetworkClient.new()
	var fake_ws := FakeWebSocketPeer.new()
	fake_ws.packets = [
		NetProtocol.dict_to_json_string(NetProtocol.make_room_created("room-42", 0, "session-42")),
	]
	client._ws = fake_ws
	client._connected = true
	var received_types: Array[String] = []
	client.message_received.connect(func(message: Dictionary):
		received_types.append(str(message.get("type", "")))
		client.disconnect_from_server()
	)

	client._process(0.0)

	return run_checks([
		assert_eq(received_types.size(), 1, "NetworkClient 应只分发一次消息"),
		assert_eq(received_types[0] if received_types.size() > 0 else "", NetProtocol.MSG_ROOM_CREATED, "应先分发 room_created 消息"),
		assert_eq(fake_ws.close_calls, 1, "回调内断开连接时应只关闭一次 socket"),
		assert_null(client._ws, "回调内断开连接后应清空当前 socket 引用"),
		assert_false(client.is_connected_to_server(), "回调内断开连接后不应继续保留连接态"),
	])
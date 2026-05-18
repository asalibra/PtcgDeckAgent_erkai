class_name TestServerNetworkSendQueue
extends TestBase

const ServerNetworkScript = preload("res://scripts/server/ServerNetwork.gd")


class FakeWebSocketPeer extends RefCounted:
	var sent_payloads: Array[String] = []
	var next_send_results: Array[int] = []
	var outbound_buffer_size: int = 65535
	var current_outbound_buffered_amount: int = 0
	var max_queued_packets: int = 4096

	func get_ready_state() -> int:
		return WebSocketPeer.STATE_OPEN

	func set_outbound_buffer_size(value: int) -> void:
		outbound_buffer_size = value

	func get_outbound_buffer_size() -> int:
		return outbound_buffer_size

	func set_max_queued_packets(value: int) -> void:
		max_queued_packets = value

	func get_current_outbound_buffered_amount() -> int:
		return current_outbound_buffered_amount

	func send_text(payload: String) -> int:
		sent_payloads.append(payload)
		if not next_send_results.is_empty():
			return int(next_send_results.pop_front())
		return OK


func test_send_message_queues_and_flushes_one_payload_per_poll() -> String:
	var network := ServerNetworkScript.new()
	var ws := FakeWebSocketPeer.new()
	network._clients[1] = ws
	network._outbound_queues[1] = []

	network.send_message(1, {"type": "first"})
	network.send_message(1, {"type": "second"})
	var queue_before: Array = (network._outbound_queues.get(1, []) as Array).duplicate()
	network._flush_outbound_queue(1, ws)
	var queue_after_first_flush: Array = (network._outbound_queues.get(1, []) as Array).duplicate()
	network._flush_outbound_queue(1, ws)
	var queue_after_second_flush: Array = (network._outbound_queues.get(1, []) as Array).duplicate()

	return run_checks([
		assert_eq(queue_before.size(), 2, "send_message 应先把消息放入出站队列"),
		assert_eq(ws.sent_payloads.size(), 2, "连续两次 flush 应分别发送两条排队消息"),
		assert_eq(queue_after_first_flush.size(), 1, "单次 poll 只应发送一条消息，避免瞬时塞满 websocket 缓冲"),
		assert_eq(queue_after_second_flush.size(), 0, "第二次 flush 后应清空剩余消息"),
	])


func test_flush_keeps_payload_queued_when_websocket_is_backpressured() -> String:
	var network := ServerNetworkScript.new()
	var ws := FakeWebSocketPeer.new()
	ws.next_send_results = [ERR_OUT_OF_MEMORY, OK]
	network._clients[1] = ws
	network._outbound_queues[1] = []
	network.send_message(1, {"type": "delayed"})

	network._flush_outbound_queue(1, ws)
	var queue_after_backpressure: Array = (network._outbound_queues.get(1, []) as Array).duplicate()
	network._flush_outbound_queue(1, ws)
	var queue_after_retry: Array = (network._outbound_queues.get(1, []) as Array).duplicate()

	return run_checks([
		assert_eq(queue_after_backpressure.size(), 1, "send_text 返回 ERR_OUT_OF_MEMORY 时消息应保留在队列里等待下次发送"),
		assert_eq(queue_after_retry.size(), 0, "下次 flush 成功后应从队列移除该消息"),
		assert_eq(ws.sent_payloads.size(), 2, "被回压的消息应在后续 poll 中重试发送"),
	])


func test_flush_defers_send_before_triggering_websocket_out_of_memory() -> String:
	var network := ServerNetworkScript.new()
	var ws := FakeWebSocketPeer.new()
	ws.outbound_buffer_size = 64
	ws.current_outbound_buffered_amount = 56
	network._clients[1] = ws
	network._outbound_queues[1] = ["1234567890"]

	network._flush_outbound_queue(1, ws)
	var queue_after_flush: Array = (network._outbound_queues.get(1, []) as Array).duplicate()

	return run_checks([
		assert_eq(ws.sent_payloads.size(), 0, "当 websocket 当前缓冲已接近上限时，flush 应先等待而不是继续调用 send_text"),
		assert_eq(queue_after_flush.size(), 1, "预检命中缓冲上限时消息应继续保留在队列中"),
	])


func test_flush_drops_payload_that_can_never_fit_in_outbound_buffer() -> String:
	var network := ServerNetworkScript.new()
	var ws := FakeWebSocketPeer.new()
	ws.outbound_buffer_size = 8
	network._clients[1] = ws
	network._outbound_queues[1] = ["123456789"]

	network._flush_outbound_queue(1, ws)
	var queue_after_flush: Array = (network._outbound_queues.get(1, []) as Array).duplicate()

	return run_checks([
		assert_eq(ws.sent_payloads.size(), 0, "单条消息本身超过 websocket buffer 时不应反复调用 send_text 触发引擎报错"),
		assert_eq(queue_after_flush.size(), 0, "无法放入 websocket buffer 的消息应被移出队列，避免永久阻塞后续发送"),
	])
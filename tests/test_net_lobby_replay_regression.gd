class_name TestNetLobbyReplayRegression
extends TestBase

const NetLobbyScene = preload("res://scenes/network/NetLobby.tscn")
const RoomManagerScript = preload("res://scripts/server/RoomManager.gd")


class SpyLobbyClient extends NetworkClient:
	var connected_state: bool = true
	var list_replays_calls: int = 0
	var get_replay_calls: int = 0

	func is_connected_to_server() -> bool:
		return connected_state

	func list_replays() -> void:
		list_replays_calls += 1

	func list_rooms() -> void:
		pass

	func connect_to_server(_url: String = "") -> void:
		pass

	func disconnect_from_server() -> void:
		pass

	func create_room(_room_name: String, _player_name: String) -> void:
		pass

	func join_room(_room_id: String, _player_name: String) -> void:
		pass

	func reconnect(_session_token: String) -> void:
		pass

	func get_replay(_match_id: String) -> void:
		get_replay_calls += 1


class FakeReplayLocator extends RefCounted:
	func locate(_match_dir: String) -> Dictionary:
		return {
			"entry_turn_number": 6,
			"entry_source": "loser_key_turn",
			"turn_numbers": [4, 6],
		}


func test_replays_button_switches_lobby_to_visible_replay_panel() -> String:
	var lobby: Control = NetLobbyScene.instantiate()
	var client := SpyLobbyClient.new()
	client.name = "NetworkClient"
	lobby._network_client = client
	lobby.add_child(client)
	lobby.call("_ready")
	lobby.get_node("%RoomListContainer").visible = true

	lobby.call("_on_replays_pressed")
	var replay_panel := lobby.get_node("%ReplayPanel") as Control
	var room_list := lobby.get_node("%RoomListContainer") as Control

	var open_result := run_checks([
		assert_true(replay_panel != null and replay_panel.visible, "点击对局回放后应显示 ReplayPanel"),
		assert_true(room_list != null and not room_list.visible, "打开回放时应隐藏房间列表，避免回放面板被挤出可视区域"),
		assert_eq(client.list_replays_calls, 1, "点击对局回放后应请求一次回放列表"),
	])
	if open_result != "":
		lobby.queue_free()
		return open_result

	lobby.call("_on_close_replay_pressed")
	var close_result := run_checks([
		assert_true(replay_panel != null and not replay_panel.visible, "关闭回放时应隐藏 ReplayPanel"),
		assert_true(room_list != null and room_list.visible, "关闭回放时应恢复房间列表"),
	])

	lobby.queue_free()
	return close_result


func test_replay_row_prefers_local_battle_replay_launch() -> String:
	var backup_navigation := GameManager.suppress_scene_navigation_for_tests
	GameManager.set_scene_navigation_suppressed_for_tests(true)
	GameManager.consume_battle_replay_launch()
	var match_dir := "user://match_records/match_local_launch"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(match_dir))

	var lobby: Control = NetLobbyScene.instantiate()
	var client := SpyLobbyClient.new()
	client.name = "NetworkClient"
	lobby._network_client = client
	lobby._replay_locator = FakeReplayLocator.new()
	lobby.add_child(client)
	lobby.call("_ready")

	lobby.call("_open_replay_entry", "match_local_launch")
	var launch := GameManager.consume_battle_replay_launch()
	var requested_path := GameManager.consume_last_requested_scene_path()

	var result := run_checks([
		assert_eq(str(launch.get("match_dir", "")), match_dir, "网络大厅查看回放时应转成正式 Battle replay launch 请求"),
		assert_eq(int(launch.get("entry_turn_number", 0)), 6, "网络大厅应保留 locator 给出的 entry turn"),
		assert_eq(requested_path, GameManager.SCENE_BATTLE, "网络大厅本地命中回放目录时应直接进入 BattleScene 复盘"),
		assert_eq(client.get_replay_calls, 0, "本地回放目录可用时不应再走旧的远端详情请求"),
	])

	lobby.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir))
	GameManager.set_scene_navigation_suppressed_for_tests(backup_navigation)
	return result


func test_remote_replay_detail_is_staged_and_launched_in_battle_scene() -> String:
	var backup_navigation := GameManager.suppress_scene_navigation_for_tests
	GameManager.set_scene_navigation_suppressed_for_tests(true)
	GameManager.consume_battle_replay_launch()
	var match_id := "match_remote_launch"
	var match_dir := "user://match_records/%s" % match_id
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("detail.jsonl")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("turns.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("match.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir))

	var lobby: Control = NetLobbyScene.instantiate()
	var client := SpyLobbyClient.new()
	client.name = "NetworkClient"
	lobby._network_client = client
	lobby._replay_locator = FakeReplayLocator.new()
	lobby.add_child(client)
	lobby.call("_ready")

	lobby.call("_display_replay_detail", {
		"match_id": match_id,
		"meta": {"player_labels": ["A", "B"]},
		"result": {"winner_index": 0, "reason": "prize"},
		"turns": {
			"turns": [{
				"turn_number": 4,
				"has_turn_start_snapshot": true,
				"snapshot_reasons": ["turn_start"],
			}],
		},
		"detail_events": [{
			"event_type": "state_snapshot",
			"turn_number": 4,
			"snapshot_reason": "turn_start",
			"state": {"current_player_index": 1, "players": []},
		}],
	})

	var launch := GameManager.consume_battle_replay_launch()
	var requested_path := GameManager.consume_last_requested_scene_path()
	var staged_match := FileAccess.file_exists(match_dir.path_join("match.json"))
	var staged_turns := FileAccess.file_exists(match_dir.path_join("turns.json"))
	var staged_detail := FileAccess.file_exists(match_dir.path_join("detail.jsonl"))

	var result := run_checks([
		assert_eq(str(launch.get("match_dir", "")), match_dir, "远端 replay_data 应先落地到本地回放目录后再进入 BattleScene"),
		assert_eq(requested_path, GameManager.SCENE_BATTLE, "远端 replay_data 应直接触发 BattleScene 回放入口"),
		assert_true(staged_match and staged_turns and staged_detail, "远端回放详情应完整写入 match/turns/detail 三类文件"),
	])

	lobby.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("detail.jsonl")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("turns.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("match.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir))
	GameManager.set_scene_navigation_suppressed_for_tests(backup_navigation)
	return result


func test_room_manager_splits_large_replay_detail_into_chunks() -> String:
	var match_id := "match_chunked_room_manager"
	var match_dir := "user://match_records/%s" % match_id
	var global_dir := ProjectSettings.globalize_path(match_dir)
	DirAccess.make_dir_recursive_absolute(global_dir)
	_write_json_file(match_dir.path_join("match.json"), {
		"meta": {"player_labels": ["A", "B"]},
		"result": {"winner_index": 0, "reason": "prize"},
	})
	_write_json_file(match_dir.path_join("turns.json"), {"turns": []})
	var large_events: Array = []
	for i: int in 8:
		large_events.append({
			"event_index": i,
			"event_type": "state_snapshot",
			"state": {"blob": "x".repeat(24000)},
		})
	_write_jsonl_file(match_dir.path_join("detail.jsonl"), large_events)

	var sent_messages: Array = []
	var room_manager := RoomManagerScript.new()
	room_manager.setup(func(peer_id: int, message: Dictionary) -> void:
		sent_messages.append({"peer_id": peer_id, "message": message})
	)
	room_manager._handle_get_replay(7, {"match_id": match_id})

	var replay_message: Dictionary = sent_messages[0].get("message", {}) if not sent_messages.is_empty() else {}
	var replay_payload: Dictionary = replay_message.get("payload", {}) if replay_message.get("payload") is Dictionary else {}
	var chunk_messages: Array = []
	for message_variant: Variant in sent_messages:
		if not (message_variant is Dictionary):
			continue
		var wrapped: Dictionary = message_variant
		var message: Dictionary = wrapped.get("message", {}) if wrapped.get("message") is Dictionary else {}
		if str(message.get("type", "")) == NetProtocol.MSG_REPLAY_DETAIL_CHUNK:
			chunk_messages.append(message)

	var chunk_count: int = int(replay_payload.get("detail_chunk_count", 0))
	var total_events: int = 0
	for chunk_variant: Variant in chunk_messages:
		var chunk_payload: Dictionary = chunk_variant.get("payload", {}) if chunk_variant.get("payload") is Dictionary else {}
		total_events += int((chunk_payload.get("detail_events", []) as Array).size())

	var result := run_checks([
		assert_eq(str(replay_message.get("type", "")), NetProtocol.MSG_REPLAY_DATA, "首条回放响应应仍然使用 replay_data"),
		assert_true(not replay_payload.has("detail_events"), "分块回放元数据不应再内联 detail_events"),
		assert_true(chunk_count > 1, "大回放 detail.jsonl 应被拆成多个分块"),
		assert_eq(chunk_messages.size(), chunk_count, "服务器应发送完整数量的 detail chunk 消息"),
		assert_eq(total_events, large_events.size(), "所有分块合并后应覆盖完整 detail 事件数"),
	])

	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("detail.jsonl")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("turns.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("match.json")))
	DirAccess.remove_absolute(global_dir)
	return result


func test_net_lobby_assembles_chunked_replay_detail_and_launches() -> String:
	var backup_navigation := GameManager.suppress_scene_navigation_for_tests
	GameManager.set_scene_navigation_suppressed_for_tests(true)
	GameManager.consume_battle_replay_launch()
	var match_id := "match_chunked_lobby"
	var match_dir := "user://match_records/%s" % match_id
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("detail.jsonl")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("turns.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("match.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir))

	var lobby: Control = NetLobbyScene.instantiate()
	var client := SpyLobbyClient.new()
	client.name = "NetworkClient"
	lobby._network_client = client
	lobby._replay_locator = FakeReplayLocator.new()
	lobby.add_child(client)
	lobby.call("_ready")

	lobby.call("_handle_replay_data", {
		"match_id": match_id,
		"meta": {"player_labels": ["A", "B"]},
		"result": {"winner_index": 0, "reason": "prize"},
		"turns": {"turns": []},
		"detail_chunk_count": 2,
	})
	lobby.call("_handle_replay_detail_chunk", {
		"match_id": match_id,
		"chunk_index": 1,
		"total_chunks": 2,
		"detail_events": [{"event_index": 1, "event_type": "state_snapshot", "state": {"players": []}}],
	})
	var launch_before_final := GameManager.consume_battle_replay_launch()
	lobby.call("_handle_replay_detail_chunk", {
		"match_id": match_id,
		"chunk_index": 0,
		"total_chunks": 2,
		"detail_events": [{"event_index": 0, "event_type": "turn_start", "state": {"players": []}}],
	})

	var launch := GameManager.consume_battle_replay_launch()
	var requested_path := GameManager.consume_last_requested_scene_path()
	var staged_detail_lines := _read_jsonl_file(match_dir.path_join("detail.jsonl"))

	var result := run_checks([
		assert_true(launch_before_final.is_empty(), "在 detail chunk 未收齐前不应提前进入 BattleScene 回放"),
		assert_eq(str(launch.get("match_dir", "")), match_dir, "chunked replay detail 收齐后应进入 BattleScene 回放"),
		assert_eq(requested_path, GameManager.SCENE_BATTLE, "chunked replay detail 收齐后应请求 BattleScene"),
		assert_eq(staged_detail_lines.size(), 2, "分块 detail 应按合并后的完整内容写入 detail.jsonl"),
		assert_eq(int((staged_detail_lines[0] as Dictionary).get("event_index", -1)), 0, "分块 detail 应按 chunk_index 顺序重组后写入"),
		assert_eq(int((staged_detail_lines[1] as Dictionary).get("event_index", -1)), 1, "分块 detail 的后续事件也应保留"),
	])

	lobby.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("detail.jsonl")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("turns.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("match.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir))
	GameManager.set_scene_navigation_suppressed_for_tests(backup_navigation)
	return result


func test_net_lobby_retries_stalled_chunked_replay_without_losing_progress() -> String:
	var backup_navigation := GameManager.suppress_scene_navigation_for_tests
	GameManager.set_scene_navigation_suppressed_for_tests(true)
	GameManager.consume_battle_replay_launch()
	var match_id := "match_chunked_retry"
	var match_dir := "user://match_records/%s" % match_id
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("detail.jsonl")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("turns.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("match.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir))

	var lobby: Control = NetLobbyScene.instantiate()
	var client := SpyLobbyClient.new()
	client.name = "NetworkClient"
	lobby._network_client = client
	lobby._replay_locator = FakeReplayLocator.new()
	lobby.add_child(client)
	lobby.call("_ready")

	lobby.call("_open_replay_entry", match_id)
	lobby.call("_handle_replay_data", {
		"match_id": match_id,
		"meta": {"player_labels": ["A", "B"]},
		"result": {"winner_index": 0, "reason": "prize"},
		"turns": {"turns": []},
		"detail_chunk_count": 3,
	})
	lobby.call("_handle_replay_detail_chunk", {
		"match_id": match_id,
		"chunk_index": 0,
		"total_chunks": 3,
		"detail_events": [{"event_index": 0, "event_type": "turn_start", "state": {"players": []}}],
	})
	var pending: Dictionary = lobby._pending_replay_details.get(match_id, {})
	pending["last_progress_msec"] = 0
	lobby._pending_replay_details[match_id] = pending
	lobby.call("_tick_pending_replay_details", 5000)
	var status_after_retry := str((lobby.get_node("%StatusLabel") as Label).text)
	lobby.call("_handle_replay_data", {
		"match_id": match_id,
		"meta": {"player_labels": ["A", "B"]},
		"result": {"winner_index": 0, "reason": "prize"},
		"turns": {"turns": []},
		"detail_chunk_count": 3,
	})
	lobby.call("_handle_replay_detail_chunk", {
		"match_id": match_id,
		"chunk_index": 1,
		"total_chunks": 3,
		"detail_events": [{"event_index": 1, "event_type": "state_snapshot", "state": {"players": []}}],
	})
	var launch_before_final := GameManager.consume_battle_replay_launch()
	lobby.call("_handle_replay_detail_chunk", {
		"match_id": match_id,
		"chunk_index": 2,
		"total_chunks": 3,
		"detail_events": [{"event_index": 2, "event_type": "action", "description": "done"}],
	})

	var launch := GameManager.consume_battle_replay_launch()
	var requested_path := GameManager.consume_last_requested_scene_path()
	var staged_detail_lines := _read_jsonl_file(match_dir.path_join("detail.jsonl"))

	var result := run_checks([
		assert_eq(client.get_replay_calls, 2, "chunked replay 在接收停滞后应自动重试一次 get_replay"),
		assert_true(status_after_retry.contains("正在重试"), "chunked replay 超时重试时应更新状态提示"),
		assert_true(launch_before_final.is_empty(), "重试后在 detail chunk 未收齐前不应提前进入 BattleScene 回放"),
		assert_eq(str(launch.get("match_dir", "")), match_dir, "重试补齐剩余分块后应进入 BattleScene 回放"),
		assert_eq(requested_path, GameManager.SCENE_BATTLE, "重试补齐剩余分块后应请求 BattleScene"),
		assert_eq(staged_detail_lines.size(), 3, "重试后应保留首轮已接收 chunk，并与后续 chunk 合并写入 detail.jsonl"),
		assert_eq(int((staged_detail_lines[0] as Dictionary).get("event_index", -1)), 0, "重试前已接收的 chunk 不应被清空"),
		assert_eq(int((staged_detail_lines[2] as Dictionary).get("event_index", -1)), 2, "重试后的后续 chunk 也应正常写入"),
	])

	lobby.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("detail.jsonl")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("turns.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir.path_join("match.json")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(match_dir))
	GameManager.set_scene_navigation_suppressed_for_tests(backup_navigation)
	return result


func test_net_lobby_scales_replay_chunk_timeout_for_large_replays() -> String:
	var lobby: Control = NetLobbyScene.instantiate()
	var client := SpyLobbyClient.new()
	client.name = "NetworkClient"
	lobby._network_client = client
	lobby.add_child(client)
	lobby.call("_ready")

	var match_id := "match_large_timeout"
	lobby.call("_handle_replay_data", {
		"match_id": match_id,
		"meta": {"player_labels": ["A", "B"]},
		"result": {"winner_index": 0, "reason": "prize"},
		"turns": {"turns": []},
		"detail_chunk_count": 20,
	})
	lobby.call("_handle_replay_detail_chunk", {
		"match_id": match_id,
		"chunk_index": 0,
		"total_chunks": 20,
		"detail_events": [{"event_index": 0, "event_type": "turn_start", "state": {"players": []}}],
	})
	var pending: Dictionary = lobby._pending_replay_details.get(match_id, {})
	pending["last_progress_msec"] = 0
	lobby._pending_replay_details[match_id] = pending

	lobby.call("_tick_pending_replay_details", 5000)
	var status_before_retry := str((lobby.get_node("%StatusLabel") as Label).text)
	var retries_before_timeout := client.get_replay_calls
	var still_pending_before_timeout: bool = lobby._pending_replay_details.has(match_id)

	lobby.call("_tick_pending_replay_details", 7000)
	var status_after_retry := str((lobby.get_node("%StatusLabel") as Label).text)
	var retries_after_timeout := client.get_replay_calls
	var still_pending_after_timeout: bool = lobby._pending_replay_details.has(match_id)

	var result := run_checks([
		assert_eq(retries_before_timeout, 0, "20 个分块的大回放在 5 秒内不应被误判为超时重试"),
		assert_true(still_pending_before_timeout, "大回放在伸缩超时窗口内应继续保留已收进度"),
		assert_true(not status_before_retry.contains("正在重试"), "未到伸缩超时阈值前不应显示重试提示"),
		assert_eq(retries_after_timeout, 1, "超过大回放的伸缩超时阈值后应触发一次重试"),
		assert_true(still_pending_after_timeout, "触发重试后仍应保留已接收的 detail chunk 进度"),
		assert_true(status_after_retry.contains("正在重试"), "超过伸缩超时阈值后应更新重试状态提示"),
	])

	lobby.queue_free()
	return result


func _write_json_file(path: String, payload: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()


func _write_jsonl_file(path: String, rows: Array) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	for row_variant: Variant in rows:
		if row_variant is Dictionary:
			file.store_line(JSON.stringify(row_variant))
	file.close()


func _read_jsonl_file(path: String) -> Array:
	var rows: Array = []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return rows
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line == "":
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			rows.append((parsed as Dictionary).duplicate(true))
	file.close()
	return rows
class_name TestNetSessionCleanupAndMenuGates
extends TestBase

const MainMenuScene = preload("res://scenes/main_menu/MainMenu.tscn")
const NetResultScene = preload("res://scenes/network/NetResult.tscn")


func test_net_result_back_to_lobby_clears_saved_reconnect_state() -> String:
	var backup := _backup_net_prefs()
	var previous_winner := GameManager.net_game_winner
	var previous_reason := GameManager.net_game_reason
	var previous_room := GameManager.net_room_id
	var previous_player_index := GameManager.net_player_index
	var previous_session := GameManager.net_session_token
	GameManager.set_scene_navigation_suppressed_for_tests(true)
	GameManager.net_game_winner = 1
	GameManager.net_game_reason = "测试结算"
	GameManager.net_room_id = "room-123"
	GameManager.net_player_index = 0
	GameManager.net_session_token = "token-abc"
	GameManager.save_net_prefs("测试玩家", "ws://example.test:9000")

	var scene := NetResultScene.instantiate()
	scene.call("_on_back_to_lobby")

	var saved := GameManager.load_net_prefs()
	var requested_path := GameManager.consume_last_requested_scene_path()
	var result := run_checks([
		assert_eq(requested_path, GameManager.SCENE_NET_LOBBY, "结果页返回大厅应跳转到网络大厅"),
		assert_eq(GameManager.net_room_id, "", "结果页返回大厅时应清空内存中的房间 ID"),
		assert_eq(GameManager.net_session_token, "", "结果页返回大厅时应清空内存中的 session token"),
		assert_eq(GameManager.net_player_index, -1, "结果页返回大厅时应清空内存中的 player_index"),
		assert_eq(GameManager.net_game_winner, -1, "结果页返回大厅后应清空结算 winner"),
		assert_eq(GameManager.net_game_reason, "", "结果页返回大厅后应清空结算原因"),
		assert_eq(str(saved.get("room_id", "missing")), "", "结果页返回大厅时应清空持久化房间 ID"),
		assert_eq(str(saved.get("session_token", "missing")), "", "结果页返回大厅时应清空持久化 session token"),
		assert_eq(int(saved.get("player_index", 99)), -1, "结果页返回大厅时应清空持久化 player_index"),
		assert_eq(str(saved.get("player_name", "")), "测试玩家", "清理重连状态时应保留玩家昵称偏好"),
		assert_eq(str(saved.get("server_url", "")), "ws://example.test:9000", "清理重连状态时应保留服务器地址偏好"),
	])

	scene.queue_free()
	_restore_net_prefs(backup)
	GameManager.net_game_winner = previous_winner
	GameManager.net_game_reason = previous_reason
	GameManager.net_room_id = previous_room
	GameManager.net_player_index = previous_player_index
	GameManager.net_session_token = previous_session
	GameManager.set_scene_navigation_suppressed_for_tests(false)
	return result


func test_main_menu_blocks_local_battle_tournament_and_settings_entries() -> String:
	var scene: Control = MainMenuScene.instantiate()
	scene.call("_ready")
	var start_button := scene.get_node_or_null("%BtnStartBattle") as Button
	var tournament_button := scene.get_node_or_null("%BtnTournament") as Button
	var settings_button := scene.get_node_or_null("%BtnSettings") as Button

	var result := run_checks([
		assert_true(start_button != null and start_button.disabled, "主菜单应屏蔽开始对战入口"),
		assert_true(tournament_button != null and tournament_button.disabled, "主菜单应屏蔽比赛模式入口"),
		assert_true(settings_button != null and settings_button.disabled, "主菜单应屏蔽 AI 设置入口"),
	])

	scene.queue_free()
	return result


func _backup_net_prefs() -> Dictionary:
	if not FileAccess.file_exists(GameManager.NET_PREFS_PATH):
		return {"exists": false, "text": ""}
	var text := FileAccess.get_file_as_string(GameManager.NET_PREFS_PATH)
	return {"exists": true, "text": text}


func _restore_net_prefs(backup: Dictionary) -> void:
	if bool(backup.get("exists", false)):
		var file := FileAccess.open(GameManager.NET_PREFS_PATH, FileAccess.WRITE)
		if file != null:
			file.store_string(str(backup.get("text", "")))
		return
	if FileAccess.file_exists(GameManager.NET_PREFS_PATH):
		DirAccess.remove_absolute(GameManager.NET_PREFS_PATH)
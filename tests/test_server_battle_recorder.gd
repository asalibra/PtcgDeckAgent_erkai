class_name TestServerBattleRecorder
extends TestBase

const ServerBattleRecorderScript = preload("res://scripts/server/ServerBattleRecorder.gd")
const BattleReplayStateRestorerScript = preload("res://scripts/engine/BattleReplayStateRestorer.gd")
const TEST_ROOT := "user://test_server_battle_recorder"


func _make_card_data(card_name: String, card_type: String, set_code: String, card_index: String) -> CardData:
	var card_data := CardData.new()
	card_data.name = card_name
	card_data.card_type = card_type
	card_data.set_code = set_code
	card_data.card_index = card_index
	card_data.effect_id = ""
	if card_type == "Pokemon":
		card_data.stage = "Basic"
		card_data.hp = 70
		card_data.energy_type = "C"
	elif card_type == "Basic Energy":
		card_data.energy_provides = "C"
	return card_data


func _make_card(card_name: String, owner_index: int, card_type: String, card_index: String) -> CardInstance:
	return CardInstance.create(_make_card_data(card_name, card_type, "TST", card_index), owner_index)


func _make_slot(card_name: String, owner_index: int, card_index: String) -> PokemonSlot:
	var slot := PokemonSlot.new()
	slot.pokemon_stack.append(_make_card(card_name, owner_index, "Pokemon", card_index))
	return slot


func _make_game_state() -> GameState:
	var state := GameState.new()
	state.turn_number = 4
	state.current_player_index = 1
	state.first_player_index = 0
	state.phase = GameState.GamePhase.MAIN
	state.stadium_card = _make_card("Test Stadium", 0, "Stadium", "900")
	state.stadium_owner_index = 0
	state.stadium_effect_used_turn = 3
	state.stadium_effect_used_player = 0
	state.stadium_effect_used_effect_id = "stadium_test"
	state.vstar_power_used = [true, false]
	state.last_knockout_turn_against = [2, 3]
	state.shared_turn_flags = {"trace": "ok"}

	for player_index: int in 2:
		var player := PlayerState.new()
		player.player_index = player_index
		player.hand = [_make_card("Hand %d" % player_index, player_index, "Trainer", "10%d" % player_index)]
		player.deck = [
			_make_card("Deck Top %d" % player_index, player_index, "Trainer", "20%d" % player_index),
			_make_card("Deck Next %d" % player_index, player_index, "Trainer", "21%d" % player_index),
		]
		player.set_prizes([
			_make_card("Prize A %d" % player_index, player_index, "Trainer", "30%d" % player_index),
			_make_card("Prize B %d" % player_index, player_index, "Trainer", "31%d" % player_index),
		])
		player.discard_pile = [_make_card("Discard %d" % player_index, player_index, "Trainer", "40%d" % player_index)]
		player.lost_zone = [_make_card("Lost %d" % player_index, player_index, "Trainer", "50%d" % player_index)]
		player.active_pokemon = _make_slot("Active %d" % player_index, player_index, "60%d" % player_index)
		player.bench = [_make_slot("Bench %d" % player_index, player_index, "70%d" % player_index)]
		state.players.append(player)
	return state


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed as Dictionary if parsed is Dictionary else {}


func _clear_dir(path: String) -> void:
	var global_path := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(global_path.path_join("match_records")):
		DirAccess.remove_absolute(global_path.path_join("match_records"))
	if DirAccess.dir_exists_absolute(global_path):
		var dir := DirAccess.open(global_path)
		if dir != null:
			dir.list_dir_begin()
			var name := dir.get_next()
			while name != "":
				if name != "." and name != "..":
					var child := global_path.path_join(name)
					if DirAccess.dir_exists_absolute(child):
						for nested_name: String in ["detail.jsonl", "summary.log", "turns.json", "llm_digest.json", "match.json"]:
							var nested_path := child.path_join(nested_name)
							if FileAccess.file_exists(nested_path):
								DirAccess.remove_absolute(nested_path)
						DirAccess.remove_absolute(child)
					elif FileAccess.file_exists(child):
						DirAccess.remove_absolute(child)
				name = dir.get_next()
			dir.list_dir_end()
		DirAccess.remove_absolute(global_path)


func test_server_snapshot_restores_deck_for_replay_draw() -> String:
	var state := _make_game_state()
	var recorder = ServerBattleRecorderScript.new()
	var snapshot: Dictionary = recorder._build_full_snapshot(state)
	var restored: GameState = BattleReplayStateRestorerScript.new().restore(snapshot)
	var draw_before := restored.players[1].deck.size()
	var drawn: CardInstance = restored.players[1].draw_card()

	return run_checks([
		assert_eq(int(((snapshot.get("players", []) as Array)[1] as Dictionary).get("deck_count", -1)), 2, "在线服务器快照应记录 deck_count"),
		assert_eq((((snapshot.get("players", []) as Array)[1] as Dictionary).get("deck", []) as Array).size(), 2, "在线服务器快照应记录完整 deck 列表，而不是只记数量"),
		assert_eq((((snapshot.get("players", []) as Array)[1] as Dictionary).get("prize_layout", []) as Array).size(), 2, "在线服务器快照应保留 prize_layout 供回放恢复固定奖赏槽位"),
		assert_eq(draw_before, 2, "恢复后的回放状态应允许继续从牌库抽牌"),
		assert_eq(restored.players[1].deck.size(), 1, "回放推进一次抽牌后，牌库应正常减少 1 张而不是直接为空"),
		assert_not_null(drawn, "恢复后的回放推进到抽牌阶段时不应因为空牌库直接失败"),
		assert_eq(drawn.card_data.name, "Deck Top 1", "回放抽牌应保持原始牌库顺序"),
	])


func test_server_recording_persists_initial_state_deck_in_match_json() -> String:
	_clear_dir(TEST_ROOT)
	var state := _make_game_state()
	var recorder = ServerBattleRecorderScript.new()
	recorder.set_output_root(TEST_ROOT)
	var initial_state: Dictionary = recorder._build_full_snapshot(state)
	recorder.start_recording("room_test", ["Alice", "Bob"], ["Deck A", "Deck B"], state.first_player_index, initial_state)
	recorder.finalize_recording(1, "test", state.turn_number)
	var match_dir := recorder.get_match_dir()
	var match_json := _read_json(match_dir.path_join("match.json"))
	var stored_initial_state: Dictionary = match_json.get("initial_state", {}) if match_json.get("initial_state") is Dictionary else {}
	var stored_players: Array = stored_initial_state.get("players", []) if stored_initial_state.get("players") is Array else []
	var stored_player0: Dictionary = stored_players[0] if not stored_players.is_empty() and stored_players[0] is Dictionary else {}
	var result := run_checks([
		assert_true(FileAccess.file_exists(match_dir.path_join("match.json")), "服务器回放导出后应写出 match.json"),
		assert_eq((stored_player0.get("deck", []) as Array).size(), 2, "match.json initial_state 应保留开局牌库内容，供后续回放或诊断使用"),
		assert_eq(str(((stored_player0.get("deck", []) as Array)[0] as Dictionary).get("card_name", "")), "Deck Top 0", "match.json initial_state 应保存正确的牌库顺序"),
	])
	_clear_dir(TEST_ROOT)
	return result

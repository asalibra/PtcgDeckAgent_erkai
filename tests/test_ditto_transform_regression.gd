class_name TestDittoTransformRegression
extends TestBase

const BattleSceneScript = preload("res://scenes/battle/BattleScene.gd")
const NetBattleScenePatchScript = preload("res://scenes/network/NetBattleScenePatch.gd")
const NetBattleSceneScript = preload("res://scenes/network/NetBattleScene.gd")
const BattleReplayStateRestorerScript = preload("res://scripts/engine/BattleReplayStateRestorer.gd")
const ServerSerializerScript = preload("res://scripts/server/ServerSerializer.gd")


func _make_battle_scene_stub(scene_script: GDScript = BattleSceneScript) -> Control:
	var battle_scene = scene_script.new()
	battle_scene.set("_dialog_title", Label.new())
	battle_scene.set("_dialog_list", ItemList.new())
	battle_scene.set("_dialog_card_scroll", ScrollContainer.new())
	battle_scene.set("_dialog_card_row", HBoxContainer.new())
	battle_scene.set("_dialog_assignment_panel", VBoxContainer.new())
	battle_scene.set("_dialog_assignment_source_scroll", ScrollContainer.new())
	battle_scene.set("_dialog_assignment_source_row", HBoxContainer.new())
	battle_scene.set("_dialog_assignment_target_scroll", ScrollContainer.new())
	battle_scene.set("_dialog_assignment_target_row", HBoxContainer.new())
	battle_scene.set("_dialog_assignment_summary_lbl", Label.new())
	battle_scene.set("_dialog_utility_row", HBoxContainer.new())
	battle_scene.set("_dialog_confirm", Button.new())
	battle_scene.set("_dialog_cancel", Button.new())
	battle_scene.set("_dialog_status_lbl", Label.new())
	battle_scene.set("_dialog_overlay", Panel.new())
	battle_scene.set("_handover_panel", Panel.new())
	battle_scene.set("_handover_lbl", Label.new())
	battle_scene.set("_handover_btn", Button.new())
	battle_scene.set("_detail_overlay", Panel.new())
	battle_scene.set("_discard_overlay", Panel.new())
	battle_scene.set("_log_list", RichTextLabel.new())
	battle_scene.set("_lbl_phase", Label.new())
	battle_scene.set("_lbl_turn", Label.new())
	battle_scene.set("_opp_prizes", Label.new())
	battle_scene.set("_opp_deck", Label.new())
	battle_scene.set("_opp_discard", Label.new())
	battle_scene.set("_opp_hand_lbl", Label.new())
	battle_scene.set("_opp_hand_bar", PanelContainer.new())
	battle_scene.set("_opp_prize_hud_count", Label.new())
	battle_scene.set("_opp_deck_hud_value", Label.new())
	battle_scene.set("_opp_discard_hud_value", Label.new())
	battle_scene.set("_my_prizes", Label.new())
	battle_scene.set("_my_deck", Label.new())
	battle_scene.set("_my_discard", Label.new())
	battle_scene.set("_my_prize_hud_count", Label.new())
	battle_scene.set("_my_deck_hud_value", Label.new())
	battle_scene.set("_my_discard_hud_value", Label.new())
	battle_scene.set("_btn_end_turn", Button.new())
	battle_scene.set("_btn_back", Button.new())
	battle_scene.set("_btn_attack_vfx_preview", Button.new())
	battle_scene.set("_btn_ai_advice", Button.new())
	battle_scene.set("_btn_battle_discuss_ai", Button.new())
	battle_scene.set("_btn_zeus_help", Button.new())
	battle_scene.set("_btn_opponent_hand", Button.new())
	battle_scene.set("_btn_replay_prev_turn", Button.new())
	battle_scene.set("_btn_replay_next_turn", Button.new())
	battle_scene.set("_btn_replay_continue", Button.new())
	battle_scene.set("_btn_replay_back_to_list", Button.new())
	battle_scene.set("_hud_end_turn_btn", Button.new())
	battle_scene.set("_stadium_lbl", Label.new())
	battle_scene.set("_btn_stadium_action", Button.new())
	battle_scene.set("_enemy_vstar_value", Label.new())
	battle_scene.set("_my_vstar_value", Label.new())
	battle_scene.set("_enemy_lost_value", Label.new())
	battle_scene.set("_my_lost_value", Label.new())
	battle_scene.set("_hand_container", HBoxContainer.new())
	return battle_scene


func _make_real_ditto_state(turn_number: int = 1, first_player_index: int = 0, current_player_index: int = 0) -> GameState:
	var ditto_cd: CardData = CardDatabase.get_card("151C", "132")
	var bench_cd: CardData = CardDatabase.get_card("CSV8C", "157")
	var target_cd: CardData = CardDatabase.get_card("CSV6C", "051")

	var state := GameState.new()
	state.turn_number = turn_number
	state.first_player_index = first_player_index
	state.current_player_index = current_player_index
	state.phase = GameState.GamePhase.MAIN
	for pi: int in 2:
		var player := PlayerState.new()
		player.player_index = pi
		state.players.append(player)

	var active := PokemonSlot.new()
	active.pokemon_stack.append(CardInstance.create(ditto_cd, 0))
	state.players[0].active_pokemon = active
	state.players[0].deck.append(CardInstance.create(target_cd, 0))
	var my_bench := PokemonSlot.new()
	my_bench.pokemon_stack.append(CardInstance.create(bench_cd, 0))
	state.players[0].bench.append(my_bench)
	var opp_active := PokemonSlot.new()
	opp_active.pokemon_stack.append(CardInstance.create(bench_cd, 1))
	state.players[1].active_pokemon = opp_active
	return state


func _make_real_miraidon_state(turn_number: int = 1, first_player_index: int = 0, current_player_index: int = 0) -> GameState:
	var miraidon_cd: CardData = CardDatabase.get_card("CSV1C", "050")
	var target_cd: CardData = CardDatabase.get_card("CSV6C", "051")
	var bench_cd: CardData = CardDatabase.get_card("CSV8C", "157")

	var state := GameState.new()
	state.turn_number = turn_number
	state.first_player_index = first_player_index
	state.current_player_index = current_player_index
	state.phase = GameState.GamePhase.MAIN
	for pi: int in 2:
		var player := PlayerState.new()
		player.player_index = pi
		state.players.append(player)

	var active := PokemonSlot.new()
	active.pokemon_stack.append(CardInstance.create(miraidon_cd, 0))
	state.players[0].active_pokemon = active
	state.players[0].deck.append(CardInstance.create(target_cd, 0))
	var opp_active := PokemonSlot.new()
	opp_active.pokemon_stack.append(CardInstance.create(bench_cd, 1))
	state.players[1].active_pokemon = opp_active
	return state


func test_real_ditto_can_use_transform_on_first_player_opening_turn() -> String:
	var state := _make_real_ditto_state()
	var gsm := GameStateMachine.new()
	gsm.game_state = state
	gsm.effect_processor.register_pokemon_card(state.players[0].active_pokemon.get_card_data())

	return run_checks([
		assert_not_null(state.players[0].active_pokemon.get_card_data(), "Ditto card data should exist"),
		assert_true(gsm.effect_processor.can_use_ability(state.players[0].active_pokemon, state, 0), "Real Ditto should be able to use Transform on the first player's opening turn"),
	])


func test_real_ditto_action_dialog_stays_enabled_after_network_style_restore() -> String:
	var original_ids: Array = GameManager.selected_deck_ids.duplicate()
	var temp_deck := DeckData.new()
	temp_deck.id = 991132
	temp_deck.deck_name = "Ditto Net Probe"
	temp_deck.total_cards = 3
	temp_deck.cards = [
		{"set_code": "151C", "card_index": "132", "count": 1, "card_type": "Pokemon", "name": "百变怪"},
		{"set_code": "CSV8C", "card_index": "157", "count": 1, "card_type": "Pokemon", "name": "多龙梅西亚"},
		{"set_code": "CSV6C", "card_index": "051", "count": 1, "card_type": "Pokemon", "name": "铁臂膀ex"},
	]
	CardDatabase.save_deck(temp_deck)
	GameManager.selected_deck_ids = [temp_deck.id, 0]
	var source_state := _make_real_ditto_state()
	var serializer := ServerSerializerScript.new()
	var state_view: Dictionary = serializer.build_view_for_player(source_state, 0)
	var restored_state := BattleReplayStateRestorerScript.new().restore(state_view)
	var net_scene := NetBattleSceneScript.new()
	net_scene._net_my_player_index = 0
	net_scene._synthesize_deck_counts(state_view, restored_state)
	var scene := _make_battle_scene_stub()
	var gsm := GameStateMachine.new()
	gsm.game_state = restored_state
	scene._gsm = gsm
	scene._view_player = 0
	scene.call("_register_effects_from_game_state", restored_state)

	var ditto_slot: PokemonSlot = restored_state.players[0].active_pokemon
	scene.call("_show_pokemon_action_dialog", 0, ditto_slot, false)
	var dialog_data: Dictionary = scene.get("_dialog_data")
	var actions: Array = dialog_data.get("actions", [])
	var first_action: Dictionary = actions[0] if not actions.is_empty() and actions[0] is Dictionary else {}
	var rebuilt_deck: Array = restored_state.players[0].deck
	var rebuilt_top_name := ""
	if not rebuilt_deck.is_empty() and rebuilt_deck[0] is CardInstance:
		rebuilt_top_name = str((rebuilt_deck[0] as CardInstance).card_data.name)

	GameManager.selected_deck_ids = original_ids
	CardDatabase.delete_deck(temp_deck.id)

	return run_checks([
		assert_eq(str(scene.get("_pending_choice")), "pokemon_action", "Opening Ditto should still open the Pokemon action dialog after network-style restore"),
		assert_eq(rebuilt_top_name, "铁臂膀ex", "Network deck synthesis should rebuild the local remaining deck from the saved decklist instead of Unknown placeholders"),
		assert_false(actions.is_empty(), "Opening Ditto should expose at least one action"),
		assert_eq(str(first_action.get("type", "")), "ability", "Opening Ditto should expose Transform as an ability action"),
		assert_true(bool(first_action.get("enabled", false)), "Opening Ditto Transform should remain enabled after network-style restore"),
	])


func test_real_miraidon_action_dialog_stays_enabled_in_net_mode_with_hidden_deck() -> String:
	var source_state := _make_real_miraidon_state()
	var serializer := ServerSerializerScript.new()
	var state_view: Dictionary = serializer.build_view_for_player(source_state, 0)
	var restored_state := BattleReplayStateRestorerScript.new().restore(state_view)
	var scene := _make_battle_scene_stub(NetBattleScenePatchScript)
	var gsm := GameStateMachine.new()
	gsm.game_state = restored_state
	scene._gsm = gsm
	scene._view_player = 0
	scene._net_mode = true
	scene._net_handler = Control.new()
	scene.call("_register_effects_from_game_state", restored_state)

	var miraidon_slot: PokemonSlot = restored_state.players[0].active_pokemon
	scene.call("_show_pokemon_action_dialog", 0, miraidon_slot, false)
	var dialog_data: Dictionary = scene.get("_dialog_data")
	var actions: Array = dialog_data.get("actions", [])
	var first_action: Dictionary = actions[0] if not actions.is_empty() and actions[0] is Dictionary else {}

	return run_checks([
		assert_true(restored_state.players[0].deck.is_empty(), "Network restore without deck synthesis should leave the local deck hidden for this probe"),
		assert_eq(str(scene.get("_pending_choice")), "pokemon_action", "Opening Miraidon should still open the Pokemon action dialog in net mode"),
		assert_false(actions.is_empty(), "Opening Miraidon should expose at least one action"),
		assert_eq(str(first_action.get("type", "")), "ability", "Opening Miraidon should expose Tandem Unit as an ability action"),
		assert_true(bool(first_action.get("enabled", false)), "Net-mode Miraidon should stay enabled even when the local deck contents are hidden"),
	])
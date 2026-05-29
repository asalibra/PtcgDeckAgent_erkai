## 网络对战场景 - 包装 BattleScene，注入网络逻辑
extends Control

var _battle_scene: Control
var _net_client: NetworkClient
var _net_my_player_index: int = -1
var _net_state_restorer: RefCounted
var _net_connected: bool = false

const BattleSceneScript := preload("res://scenes/battle/BattleScene.gd")
const NetBattleSceneScript := preload("res://scenes/network/NetBattleScenePatch.gd")
const BattleReplayStateRestorerScript := preload("res://scripts/engine/BattleReplayStateRestorer.gd")


func _ready() -> void:
	_net_my_player_index = GameManager.net_player_index
	_net_state_restorer = BattleReplayStateRestorerScript.new()

	# 加载 BattleScene.tscn 并替换脚本
	var scene: PackedScene = load("res://scenes/battle/BattleScene.tscn")
	_battle_scene = scene.instantiate()
	_battle_scene.set_script(NetBattleSceneScript)
	_battle_scene.set("_net_mode", true)
	_battle_scene.set("_net_handler", self)
	add_child(_battle_scene)

	_setup_network_client()


func _setup_network_client() -> void:
	_net_client = NetworkClient.new()
	_net_client.name = "NetBattleClient"
	add_child(_net_client)
	_net_client.connected.connect(_on_net_connected)
	_net_client.disconnected.connect(_on_net_disconnected)
	_net_client.message_received.connect(_on_net_message)
	_net_client.connect_to_server(GameManager.net_server_url)


func _on_net_connected() -> void:
	_net_connected = true
	if not GameManager.net_session_token.is_empty():
		_net_client.reconnect(GameManager.net_session_token)


func _on_net_disconnected(reason: String) -> void:
	_net_connected = false
	_battle_scene.call("_log", "[网络] 连接断开: %s" % reason)


func _on_net_message(message: Dictionary) -> void:
	var type: String = str(message.get("type", ""))
	var payload: Dictionary = message.get("payload", {}) if message.get("payload") is Dictionary else {}
	if NetProtocol.is_resync_required(message):
		_handle_resync_required(payload)
		return

	match type:
		NetProtocol.MSG_STATE_UPDATE:
			_apply_server_state(payload)

		NetProtocol.MSG_CHOICE_PROMPT:
			var choice_type: String = str(payload.get("choice_type", ""))
			var choice_data: Dictionary = payload.get("data", {}) if payload.get("data") is Dictionary else {}
			_log_client_choice_prompt(choice_type, choice_data, "recv_raw")
			# 只在 target_player 字段明确存在且不匹配时才过滤
			# setup_ready 不带 target_player（广播给所有人），mulligan_extra_draw 带 target_player
			if choice_data.has("target_player"):
				var target_player: int = int(choice_data.get("target_player", -1))
				if target_player >= 0 and target_player != _net_my_player_index:
					_log_client_choice_prompt(choice_type, choice_data, "filtered_foreign")
					_clear_foreign_choice_ui()
					print("[NetBattleScene] 忽略非本人的 choice: %s (target=%d, me=%d)" % [choice_type, target_player, _net_my_player_index])
					return
			# setup_bench 是网络模式专用提示，直接调用备战区对话框
			if choice_type == "setup_bench":
				var bench_pi: int = int(choice_data.get("player_index", _net_my_player_index))
				_battle_scene.call("_show_setup_bench_dialog", bench_pi)
				return
			# 训练家交互：显示选择对话框
			if choice_type == NetProtocol.CHOICE_TRAINER_INTERACTION:
				_log_client_choice_prompt(choice_type, choice_data, "dispatch_trainer_prompt")
				_handle_trainer_interaction_prompt(choice_data)
				return
			_battle_scene.call("_on_player_choice_required", choice_type, choice_data)

		NetProtocol.MSG_DRAW_REVEAL:
			var cards: Array = payload.get("cards", [])
			for card_data in cards:
				if card_data is Dictionary:
					_battle_scene.call("_log", "抽到: %s" % str(card_data.get("card_name", "未知")))

		NetProtocol.MSG_GAME_OVER:
			var winner_index: int = int(payload.get("winner_index", -1))
			var reason: String = str(payload.get("reason", ""))
			_battle_scene.call("_log", "游戏结束: %s" % reason)
			GameManager.net_game_winner = winner_index
			GameManager.net_game_reason = reason
			GameManager.clear_saved_net_session()
			GameManager.goto_scene(GameManager.SCENE_NET_RESULT)

		NetProtocol.MSG_OPPONENT_DISCONNECTED:
			_battle_scene.call("_log", "[网络] 对手已断线，等待重连...")

		NetProtocol.MSG_OPPONENT_RECONNECTED:
			_battle_scene.call("_log", "[网络] 对手已重连")

		NetProtocol.MSG_ERROR:
			_battle_scene.call("_log", "[网络] 错误: %s" % str(payload.get("message", "未知")))


func _handle_resync_required(payload: Dictionary) -> void:
	var message := str(payload.get("message", "客户端状态已过期，正在重新同步..."))
	_battle_scene.call("_log", "[网络] %s" % message)
	if not GameManager.net_session_token.is_empty() and _net_client != null and _net_client.is_connected_to_server():
		_net_client.reconnect(GameManager.net_session_token)
		return
	_battle_scene.call("_log", "[网络] 无法自动恢复，请重新进入房间")


func _log_client_choice_prompt(choice_type: String, choice_data: Dictionary, event_name: String) -> void:
	if choice_type != NetProtocol.CHOICE_TRAINER_INTERACTION:
		return
	var steps: Array = choice_data.get("steps", []) if choice_data.get("steps") is Array else []
	var step_index := int(choice_data.get("step_index", -1))
	var card_name := str(choice_data.get("card_name", ""))
	var target_player := int(choice_data.get("target_player", -1))
	print("[NetBattleScene][PromptTrace] %s choice=%s target=%d me=%d step_index=%d steps=%d card=%s pending=%s" % [
		event_name,
		choice_type,
		target_player,
		_net_my_player_index,
		step_index,
		steps.size(),
		card_name,
		str(_battle_scene.get("_pending_choice")) if _battle_scene != null else "",
	])


func _apply_server_state(payload: Dictionary) -> void:
	var state_data: Dictionary = payload.get("state", {})
	if state_data.is_empty():
		print("[NetBattleScene] state_update 无 state 数据")
		return

	var new_game_state: GameState = _net_state_restorer.restore(state_data)
	if new_game_state == null:
		print("[NetBattleScene] state restore 失败")
		return

	var overlay_visible = _battle_scene.get("_dialog_overlay").visible if _battle_scene.get("_dialog_overlay") != null else "null"
	print("[NetBattleScene] 应用状态: turn=%d, cp=%d, phase=%s, pending_choice=%s, overlay=%s" % [
		new_game_state.turn_number, new_game_state.current_player_index, new_game_state.phase,
		_battle_scene.get("_pending_choice"), overlay_visible
	])

	# 获取或创建 GSM
	var gsm = _battle_scene.get("_gsm")
	if gsm == null:
		gsm = _battle_scene.call("_build_game_state_machine")
		_battle_scene.set("_gsm", gsm)

	gsm.game_state = new_game_state
	_battle_scene.set("_view_player", _net_my_player_index)

	# 注册宝可梦特性效果（网络模式不走 _build_deck，需要手动注册）
	_battle_scene.call("_register_effects_from_game_state", new_game_state)

	# 补充占位卡（服务器不发对手手牌/双方牌库内容，只发 count）
	_synthesize_opponent_hand(state_data, new_game_state)
	_synthesize_deck_counts(state_data, new_game_state)
	_synthesize_prize_counts(state_data, new_game_state)
	# 调试：打印数量
	var players_data: Array = state_data.get("players", [])
	for _pi in range(min(players_data.size(), new_game_state.players.size())):
		var pd: Dictionary = players_data[_pi]
		var ps: PlayerState = new_game_state.players[_pi]
		print("[NetBattleScene] player[%d] hand_count=%s deck_count=%s → hand.size=%d deck.size=%d" % [_pi, pd.get("hand_count", "?"), pd.get("deck_count", "?"), ps.hand.size(), ps.deck.size()])

	# 同步服务器的 pending_choice 状态（覆盖客户端本地状态）
	# 仅在服务器明确发送了 pending_choice 字段时才同步，兼容旧版服务器
	if payload.has("pending_choice"):
		var server_pending: Dictionary = payload.get("pending_choice", {})
		_sync_pending_choice(server_pending, new_game_state)

	# 刷新 UI
	_battle_scene.call("_refresh_ui")

	# 昏厥换位：state_update 创建了新的 PokemonSlot 对象，
	# 需要用新引用重新显示对话框（否则对话框中的 slot 引用已失效）
	if new_game_state.phase == GameState.GamePhase.KNOCKOUT_REPLACE:
		var cur_choice: String = str(_battle_scene.get("_pending_choice"))
		if cur_choice == "send_out":
			var ko_player: int = -1
			for pi_check in range(new_game_state.players.size()):
				if new_game_state.players[pi_check].active_pokemon == null:
					ko_player = pi_check
					break
			if ko_player >= 0:
				_battle_scene.call("_prompt_send_out_dialog", ko_player)

	# 处理 last_action
	var last_action_data: Dictionary = payload.get("last_action", {})
	if not last_action_data.is_empty():
		var desc: String = str(last_action_data.get("description", ""))
		if not desc.is_empty():
			_battle_scene.call("_log", desc)


# ===================== 训练家交互处理 =====================

## 根据服务器的 pending_choice 同步客户端 _pending_choice 状态
## 仅设置状态标志，不显示对话框（对话框由 MSG_CHOICE_PROMPT 负责）
func _sync_pending_choice(server_pending: Dictionary, _game_state: GameState) -> void:
	var choice_type: String = str(server_pending.get("type", ""))
	var choice_data: Dictionary = server_pending.get("data", {}) if server_pending.get("data") is Dictionary else {}
	var target_player: int = int(choice_data.get("target_player", -1))
	_battle_scene.set("_net_server_pending_choice_type", choice_type)
	_battle_scene.set("_net_server_pending_choice_target_player", target_player)

	if choice_type.is_empty():
		# 服务器没有 pending choice。
		# trainer/effect 交互不会持久化在 state_update 里，若本地弹窗仍可见则必须保留提交路由。
		var old_choice: String = str(_battle_scene.get("_pending_choice"))
		if not old_choice.is_empty():
			print("[NetBattleScene] 服务器无 pending_choice，清除客户端状态: %s" % old_choice)
		var dialog_overlay: Variant = _battle_scene.get("_dialog_overlay")
		var overlay_visible: bool = dialog_overlay is CanvasItem and dialog_overlay.visible
		var field_overlay: Variant = _battle_scene.get("_field_interaction_overlay")
		var field_overlay_visible: bool = field_overlay is CanvasItem and field_overlay.visible
		if overlay_visible and (old_choice.begins_with("setup_active_") or old_choice.begins_with("setup_bench_")):
			print("[NetBattleScene] 保留本地 setup 对话状态: %s" % old_choice)
			return
		if (overlay_visible or field_overlay_visible) and old_choice in ["network_trainer_interaction", "effect_interaction"]:
			print("[NetBattleScene] 保留本地交互状态: %s" % old_choice)
			return
		_battle_scene.set("_pending_choice", "")
		return

	# 检查此 choice 是否针对当前玩家（target_player 字段）
	if target_player >= 0 and target_player != _net_my_player_index:
		# 不是给我的 choice，不设置 _pending_choice
		_clear_foreign_choice_ui()
		return

	# 服务器有 pending choice 且针对当前玩家 → 映射到客户端 _pending_choice 字符串
	# 注意：setup_ready 和 mulligan_extra_draw 由 MSG_CHOICE_PROMPT → _on_player_choice_required 驱动，
	# 不在此处映射，避免其他客户端的状态更新广播覆盖本客户端的对话框状态。
	var client_choice: String = ""
	match choice_type:
		"take_prize":
			client_choice = "take_prize"
			_battle_scene.set("_pending_prize_player_index", int(choice_data.get("player", _net_my_player_index)))
			_battle_scene.set("_pending_prize_remaining", int(choice_data.get("count", 1)))
		"send_out_pokemon":
			client_choice = "send_out"
		"heavy_baton_target":
			client_choice = "heavy_baton_target"
		"exp_share_target":
			client_choice = "exp_share_target"
		_:
			# setup_ready、mulligan_extra_draw、trainer_interaction 等 → 不修改 _pending_choice
			return

	if not client_choice.is_empty():
		_battle_scene.set("_pending_choice", client_choice)


func _clear_foreign_choice_ui() -> void:
	if _battle_scene == null:
		return
	var current_choice: String = str(_battle_scene.get("_pending_choice"))
	if current_choice.is_empty():
		return
	if current_choice.begins_with("setup_active_") or current_choice.begins_with("setup_bench_"):
		return
	var dialog_overlay: Variant = _battle_scene.get("_dialog_overlay")
	if dialog_overlay is CanvasItem:
		dialog_overlay.visible = false
	var field_overlay: Variant = _battle_scene.get("_field_interaction_overlay")
	if field_overlay is CanvasItem and field_overlay.visible and _battle_scene.has_method("_hide_field_interaction"):
		_battle_scene.call("_hide_field_interaction")
	_battle_scene.set("_pending_choice", "")


func _synthesize_opponent_hand(state_data: Dictionary, game_state: GameState) -> void:
	var players_data: Array = state_data.get("players", [])
	var opp_index: int = 1 - _net_my_player_index
	if opp_index < 0 or opp_index >= players_data.size() or opp_index >= game_state.players.size():
		return
	var opp_data: Dictionary = players_data[opp_index]
	var hand_count: int = int(opp_data.get("hand_count", 0))
	var player: PlayerState = game_state.players[opp_index]
	if player.hand.is_empty() and hand_count > 0:
		var placeholder_cd := CardData.new()
		placeholder_cd.name = "???"
		placeholder_cd.card_type = "Unknown"
		var placeholders: Array[CardInstance] = []
		for i in range(hand_count):
			var ci := CardInstance.create(placeholder_cd, opp_index)
			if ci != null:
				placeholders.append(ci)
		player.hand = placeholders


## 补充双方牌库占位卡（服务器不发牌库内容，只发 deck_count）
func _synthesize_deck_counts(state_data: Dictionary, game_state: GameState) -> void:
	var players_data: Array = state_data.get("players", [])
	for pi in range(min(players_data.size(), game_state.players.size())):
		var p_data: Dictionary = players_data[pi]
		var deck_count: int = int(p_data.get("deck_count", 0))
		var player: PlayerState = game_state.players[pi]
		if player.deck.is_empty() and deck_count > 0:
			var rebuilt_deck: Array[CardInstance] = []
			if pi == _net_my_player_index:
				rebuilt_deck = _rebuild_local_remaining_deck(game_state, pi, deck_count)
			if rebuilt_deck.is_empty():
				player.deck = _build_unknown_cards(deck_count, pi)
			else:
				player.deck = rebuilt_deck


func _build_unknown_cards(card_count: int, owner_index: int) -> Array[CardInstance]:
	var placeholder_cd := CardData.new()
	placeholder_cd.name = "???"
	placeholder_cd.card_type = "Unknown"
	var placeholders: Array[CardInstance] = []
	for i in range(card_count):
		var ci := CardInstance.create(placeholder_cd, owner_index)
		if ci != null:
			placeholders.append(ci)
	return placeholders


func _rebuild_local_remaining_deck(game_state: GameState, player_index: int, deck_count: int) -> Array[CardInstance]:
	if player_index < 0 or player_index >= GameManager.selected_deck_ids.size():
		return []
	var deck_id: int = int(GameManager.selected_deck_ids[player_index])
	if deck_id <= 0:
		return []
	var deck_data: DeckData = CardDatabase.get_deck(deck_id)
	if deck_data == null:
		return []
	var remaining_by_key: Dictionary = {}
	for entry_variant: Variant in deck_data.cards:
		if not (entry_variant is Dictionary):
			continue
		var entry: Dictionary = entry_variant as Dictionary
		var key := _deck_card_key(str(entry.get("set_code", "")), str(entry.get("card_index", "")), str(entry.get("name", "")))
		remaining_by_key[key] = int(remaining_by_key.get(key, 0)) + int(entry.get("count", 0))
	_subtract_known_player_cards(remaining_by_key, game_state.players[player_index])
	if game_state.stadium_card != null and game_state.stadium_owner_index == player_index:
		_subtract_known_card(remaining_by_key, game_state.stadium_card)
	var rebuilt: Array[CardInstance] = []
	for entry_variant: Variant in deck_data.cards:
		if not (entry_variant is Dictionary):
			continue
		var entry: Dictionary = entry_variant as Dictionary
		var set_code := str(entry.get("set_code", ""))
		var card_index := str(entry.get("card_index", ""))
		var key := _deck_card_key(set_code, card_index, str(entry.get("name", "")))
		var remaining: int = int(remaining_by_key.get(key, 0))
		if remaining <= 0:
			continue
		var card_data: CardData = CardDatabase.get_card(set_code, card_index)
		if card_data == null:
			continue
		for i in range(remaining):
			var ci := CardInstance.create(card_data, player_index)
			if ci != null:
				rebuilt.append(ci)
	if rebuilt.size() < deck_count:
		rebuilt.append_array(_build_unknown_cards(deck_count - rebuilt.size(), player_index))
	elif rebuilt.size() > deck_count:
		rebuilt.resize(deck_count)
	return rebuilt


func _subtract_known_player_cards(remaining_by_key: Dictionary, player: PlayerState) -> void:
	if player == null:
		return
	_subtract_known_card_list(remaining_by_key, player.hand)
	_subtract_known_card_list(remaining_by_key, player.prizes)
	_subtract_known_card_list(remaining_by_key, player.discard_pile)
	_subtract_known_card_list(remaining_by_key, player.lost_zone)
	_subtract_known_slot_cards(remaining_by_key, player.active_pokemon)
	for bench_slot: PokemonSlot in player.bench:
		_subtract_known_slot_cards(remaining_by_key, bench_slot)


func _subtract_known_slot_cards(remaining_by_key: Dictionary, slot: PokemonSlot) -> void:
	if slot == null:
		return
	_subtract_known_card_list(remaining_by_key, slot.pokemon_stack)
	_subtract_known_card_list(remaining_by_key, slot.attached_energy)
	if slot.attached_tool != null:
		_subtract_known_card(remaining_by_key, slot.attached_tool)


func _subtract_known_card_list(remaining_by_key: Dictionary, cards: Array) -> void:
	for card_variant: Variant in cards:
		if card_variant is CardInstance:
			_subtract_known_card(remaining_by_key, card_variant as CardInstance)


func _subtract_known_card(remaining_by_key: Dictionary, card: CardInstance) -> void:
	if card == null or card.card_data == null:
		return
	var key := _deck_card_key(card.card_data.set_code, card.card_data.card_index, card.card_data.name)
	if not remaining_by_key.has(key):
		return
	remaining_by_key[key] = maxi(0, int(remaining_by_key.get(key, 0)) - 1)


func _deck_card_key(set_code: String, card_index: String, fallback_name: String = "") -> String:
	var normalized_set := set_code.strip_edges()
	var normalized_index := card_index.strip_edges()
	if normalized_set != "" or normalized_index != "":
		return "%s::%s" % [normalized_set, normalized_index]
	return "name::%s" % fallback_name.strip_edges()



func _synthesize_prize_counts(state_data: Dictionary, game_state: GameState) -> void:
	var players_data: Array = state_data.get("players", [])
	for pi in range(min(players_data.size(), game_state.players.size())):
		var p_data: Dictionary = players_data[pi]
		var prize_count: int = int(p_data.get("prize_count", 0))
		var player: PlayerState = game_state.players[pi]
		if not player.prizes.is_empty() or not player.get_prize_layout().is_empty() or prize_count <= 0:
			continue
		var placeholder_cd := CardData.new()
		placeholder_cd.name = "Prize"
		placeholder_cd.card_type = "Prize"
		var placeholders: Array[CardInstance] = []
		for i in range(prize_count):
			var ci := CardInstance.create(placeholder_cd, pi)
			if ci != null:
				ci.face_up = false
				placeholders.append(ci)
		player.set_prizes(placeholders)


func _handle_trainer_interaction_prompt(data: Dictionary) -> void:
	var steps: Array = data.get("steps", [])
	var step_index: int = int(data.get("step_index", 0))
	var card_name: String = str(data.get("card_name", "?"))
	var coin_flip_result: Variant = data.get("coin_flip_result", null)
	var coin_only: bool = bool(data.get("coin_only", false))

	# 显示硬币投掷结果
	if coin_flip_result != null:
		var coin_msg: String = "%s：投掷硬币 → 正面！" % card_name if coin_flip_result else "%s：投掷硬币 → 反面！" % card_name
		_battle_scene.call("_log", coin_msg)

	# 仅硬币投掷无后续步骤：不显示对话框
	if coin_only or steps.is_empty():
		return

	if step_index >= steps.size():
		print("[NetBattleScene] 训练家交互步骤索引超出范围")
		return
	var step: Dictionary = steps[step_index]
	var raw_card_items: Array = step.get("card_items", []) if step.has("card_items") else []
	var title: String = str(step.get("title", "%s - 选择" % card_name))
	var raw_items: Array = step.get("items", [])
	var raw_target_items: Array = step.get("target_items", []) if step.has("target_items") else []
	var labels: Array = step.get("labels", [])
	var min_select: int = int(step.get("min_select", 1))
	var max_select: int = int(step.get("max_select", 1))
	var allow_cancel: bool = bool(step.get("allow_cancel", true))
	var presentation: String = str(step.get("presentation", "auto"))
	var gs: GameState = _battle_scene.get("_gsm").game_state if _battle_scene.get("_gsm") != null else null
	_log_trainer_prompt_trace(
		"recv_prompt",
		card_name,
		step,
		step_index,
		steps.size(),
		"pending=%s raw_items=%d raw_target_items=%d raw_card_items=%d overlay_visible=%s" % [
			str(_battle_scene.get("_pending_choice")),
			raw_items.size(),
			raw_target_items.size(),
			raw_card_items.size(),
			str(_dialog_overlay_visible()),
		]
	)
	var restored_items: Array = _restore_serialized_interaction_items(raw_items, gs)
	var restored_target_items: Array = []
	if step.has("target_items"):
		restored_target_items = _restore_serialized_interaction_items(raw_target_items, gs)

	_report_interaction_restore_mismatch(title, "items", raw_items, restored_items)
	_report_interaction_restore_mismatch(title, "target_items", raw_target_items, restored_target_items)

	# 存储步骤信息供确认时使用
	_trainer_interaction_step = step

	if str(step.get("ui_mode", "")) == "counter_distribution":
		if not _serialized_slot_restore_complete(raw_target_items, restored_target_items):
			_abort_interaction_prompt_restore(title, "target_items", raw_target_items, restored_target_items)
			return
		var counter_step: Dictionary = step.duplicate(true)
		counter_step["target_items"] = restored_target_items
		_battle_scene.set("_pending_choice", "network_trainer_interaction")
		_log_trainer_prompt_trace(
			"show_counter_distribution",
			card_name,
			step,
			step_index,
			steps.size(),
			"restored_target_items=%d pending=%s" % [restored_target_items.size(), str(_battle_scene.get("_pending_choice"))]
		)
		_battle_scene.call("_show_field_counter_distribution", counter_step)
		return

	var uses_field_slot_ui := not restored_items.is_empty()
	if uses_field_slot_ui:
		for item: Variant in restored_items:
			if not (item is PokemonSlot):
				uses_field_slot_ui = false
				break
	if _serialized_slot_restore_complete(raw_items, restored_items) == false and _serialized_items_expect_slot_ui(raw_items) and str(step.get("ui_mode", "")) != "card_assignment":
		_abort_interaction_prompt_restore(title, "items", raw_items, restored_items)
		return
	if uses_field_slot_ui and str(step.get("ui_mode", "")) != "card_assignment":
		var field_step: Dictionary = step.duplicate(true)
		field_step["items"] = restored_items
		field_step["labels"] = labels.duplicate(true)
		_battle_scene.set("_pending_choice", "network_trainer_interaction")
		_log_trainer_prompt_trace(
			"show_field_slot_choice",
			card_name,
			step,
			step_index,
			steps.size(),
			"restored_items=%d pending=%s" % [restored_items.size(), str(_battle_scene.get("_pending_choice"))]
		)
		_battle_scene.call("_show_field_slot_choice", title, restored_items, field_step)
		return

	# 构建对话框数据
	var dialog_data: Dictionary = {
		"min_select": min_select,
		"max_select": max_select,
		"allow_cancel": allow_cancel,
		"presentation": presentation,
	}
	if not labels.is_empty():
		dialog_data["choice_labels"] = labels.duplicate(true)
	# 赋值类步骤（如能量涡轮）需要 source_items / target_items
	if presentation == "card_assignment" or step.has("target_items"):
		if not _serialized_slot_restore_complete(raw_target_items, restored_target_items):
			_abort_interaction_prompt_restore(title, "target_items", raw_target_items, restored_target_items)
			return
		dialog_data["ui_mode"] = "card_assignment"
		if step.has("source_items"):
			dialog_data["source_items"] = _restore_serialized_interaction_items(step.get("source_items", []), gs)
			dialog_data["source_labels"] = step.get("source_labels", [])
		else:
			dialog_data["source_items"] = _restore_serialized_interaction_items(step.get("items", []), gs)
			dialog_data["source_labels"] = step.get("labels", [])
		if step.has("source_card_items"):
			dialog_data["source_card_items"] = _restore_serialized_interaction_items(step.get("source_card_items", []), gs)
			dialog_data["source_card_indices"] = step.get("source_card_indices", [])
			dialog_data["source_choice_labels"] = step.get("source_choice_labels", [])
		elif step.has("card_items"):
			dialog_data["source_card_items"] = _restore_serialized_interaction_items(step.get("card_items", []), gs)
			dialog_data["source_card_indices"] = step.get("card_indices", [])
			dialog_data["source_choice_labels"] = step.get("choice_labels", [])
		if step.has("source_groups"):
			dialog_data["source_groups"] = _restore_serialized_interaction_groups(step.get("source_groups", []), gs)
		for assignment_key: String in [
			"single_target_only", "max_assignments_per_target", "source_exclude_targets",
			"source_visible_scope", "source_card_disabled_badge", "source_card_selectable_hint",
			"source_visible_count", "source_selectable_count",
		]:
			if step.has(assignment_key):
				dialog_data[assignment_key] = step.get(assignment_key)
	# 完整牌库搜索字段（普通搜索步骤）
	if step.has("card_items") and not dialog_data.has("source_card_items"):
		dialog_data["card_items"] = _restore_serialized_interaction_items(step.get("card_items", []), gs)
	if step.has("card_indices"):
		dialog_data["card_indices"] = step.get("card_indices", [])
	if step.has("choice_labels"):
		dialog_data["choice_labels"] = step.get("choice_labels", [])
	if step.has("card_disabled_badge"):
		dialog_data["card_disabled_badge"] = step.get("card_disabled_badge")
	if step.has("card_selectable_hint"):
		dialog_data["card_selectable_hint"] = step.get("card_selectable_hint")
	if step.has("visible_scope"):
		dialog_data["visible_scope"] = step.get("visible_scope")
	if step.has("show_selectable_hints"):
		dialog_data["show_selectable_hints"] = step.get("show_selectable_hints")
	if step.has("card_click_selectable"):
		dialog_data["card_click_selectable"] = step.get("card_click_selectable")
	if step.has("utility_actions"):
		dialog_data["utility_actions"] = step.get("utility_actions")
	if step.has("prompt_type"):
		dialog_data["prompt_type"] = step.get("prompt_type")
	if step.has("card_groups"):
		dialog_data["card_groups"] = _restore_serialized_interaction_groups(step.get("card_groups", []), gs)
	# target_items：赋予招式等需要选择目标的步骤
	if not restored_target_items.is_empty():
		dialog_data["target_items"] = restored_target_items
	if step.has("target_labels"):
		dialog_data["target_labels"] = step.get("target_labels", [])

	_battle_scene.set("_pending_choice", "network_trainer_interaction")
	_battle_scene.call("_show_dialog", title, restored_items, dialog_data)
	var dialog_card_items: Array = dialog_data.get("card_items", [])
	var dialog_card_indices: Array = dialog_data.get("card_indices", [])
	var dialog_target_items: Array = dialog_data.get("target_items", [])
	_log_trainer_prompt_trace(
		"show_dialog",
		card_name,
		step,
		step_index,
		steps.size(),
		"restored_items=%d dialog_card_items=%d dialog_card_indices=%d dialog_target_items=%d pending=%s overlay_visible=%s" % [
			restored_items.size(),
			dialog_card_items.size(),
			dialog_card_indices.size(),
			dialog_target_items.size(),
			str(_battle_scene.get("_pending_choice")),
			str(_dialog_overlay_visible()),
		]
	)


func _trainer_prompt_trace_summary(step: Dictionary, step_index: int, total_steps: int) -> String:
	var step_id := str(step.get("id", "step_%d" % step_index))
	var ui_mode := str(step.get("ui_mode", step.get("presentation", "auto")))
	var items: Array = step.get("items", [])
	var target_items: Array = step.get("target_items", [])
	var card_items: Array = step.get("card_items", [])
	return "step=%d/%d id=%s ui=%s items=%d target_items=%d card_items=%d" % [
		step_index + 1,
		total_steps,
		step_id,
		ui_mode,
		items.size(),
		target_items.size(),
		card_items.size(),
	]


func _log_trainer_prompt_trace(event_name: String, card_name: String, step: Dictionary, step_index: int, total_steps: int, extra: String = "") -> void:
	var message := "[NetBattleScene][TrainerTrace] %s card=%s %s" % [
		event_name,
		card_name,
		_trainer_prompt_trace_summary(step, step_index, total_steps),
	]
	if not extra.is_empty():
		message += " " + extra
	print(message)
	if _battle_scene != null and _battle_scene.has_method("_runtime_log"):
		_battle_scene.call("_runtime_log", "network_trainer_trace", message)


func _dialog_overlay_visible() -> bool:
	if _battle_scene == null:
		return false
	var dialog_overlay: Variant = _battle_scene.get("_dialog_overlay")
	return dialog_overlay is CanvasItem and dialog_overlay.visible


func _is_serialized_slot_item(item_variant: Variant) -> bool:
	if not (item_variant is Dictionary):
		return false
	var item_data: Dictionary = item_variant as Dictionary
	return str(item_data.get("type", "")) == "slot" and item_data.has("slot_ref")


func _serialized_items_expect_slot_ui(raw_items: Array) -> bool:
	if raw_items.is_empty():
		return false
	for item_variant: Variant in raw_items:
		if not _is_serialized_slot_item(item_variant):
			return false
	return true


func _serialized_slot_restore_complete(raw_items: Array, restored_items: Array) -> bool:
	if not _serialized_items_expect_slot_ui(raw_items):
		return true
	return raw_items.size() == restored_items.size()


func _report_interaction_restore_mismatch(title: String, field_name: String, raw_items: Array, restored_items: Array) -> void:
	if raw_items.is_empty() or raw_items.size() == restored_items.size():
		return
	_log_interaction_restore_issue(
		"[NetBattleScene] 联机交互恢复不一致: %s field=%s raw=%d restored=%d" % [
			title,
			field_name,
			raw_items.size(),
			restored_items.size(),
		]
	)


func _abort_interaction_prompt_restore(title: String, field_name: String, raw_items: Array, restored_items: Array) -> void:
	_log_interaction_restore_issue(
		"[NetBattleScene] 联机交互恢复失败: %s field=%s raw=%d restored=%d" % [
			title,
			field_name,
			raw_items.size(),
			restored_items.size(),
		]
	)
	_cancel_unrestorable_trainer_interaction()


func _log_interaction_restore_issue(message: String) -> void:
	print(message)
	if _battle_scene != null and _battle_scene.has_method("_log"):
		_battle_scene.call("_log", message)


func _cancel_unrestorable_trainer_interaction() -> void:
	if _battle_scene != null:
		_battle_scene.set("_pending_choice", "")
	send_choice_response(NetProtocol.CHOICE_TRAINER_INTERACTION, {
		"selected_indices": [],
		"cancelled": true,
	})


func _restore_serialized_card_instance(item_data: Dictionary) -> CardInstance:
	var card_data: CardData = null
	var set_code := str(item_data.get("set_code", "")).strip_edges()
	var card_index := str(item_data.get("card_index", "")).strip_edges()
	if set_code != "" or card_index != "":
		card_data = CardDatabase.get_card(set_code, card_index)
	if card_data == null:
		var card_snapshot: Dictionary = item_data.duplicate(true)
		if not card_snapshot.has("name") and card_snapshot.has("card_name"):
			card_snapshot["name"] = card_snapshot.get("card_name", "")
		card_data = CardData.from_dict(card_snapshot)
	var card_instance := CardInstance.create(card_data, _net_my_player_index)
	if card_instance != null:
		card_instance.instance_id = int(item_data.get("instance_id", 0))
	return card_instance


func _restore_slot_from_ref(slot_ref: Dictionary, game_state: GameState, top_instance_id: int = -1) -> PokemonSlot:
	if game_state == null:
		return null
	var slot_pi: int = int(slot_ref.get("player_index", -1))
	var slot_kind: String = str(slot_ref.get("slot_kind", ""))
	var slot_idx: int = int(slot_ref.get("slot_index", 0))
	if slot_pi < 0 or slot_pi >= game_state.players.size():
		return null
	if slot_kind == "active":
		var active_slot: PokemonSlot = game_state.players[slot_pi].active_pokemon
		if active_slot != null:
			return active_slot
		return _find_slot_by_top_instance_id(game_state, slot_pi, top_instance_id)
	if slot_kind == "bench" and slot_idx >= 0 and slot_idx < game_state.players[slot_pi].bench.size():
		return game_state.players[slot_pi].bench[slot_idx]
	return _find_slot_by_top_instance_id(game_state, slot_pi, top_instance_id)


func _find_slot_by_top_instance_id(game_state: GameState, player_index: int, top_instance_id: int) -> PokemonSlot:
	if game_state == null or top_instance_id < 0:
		return null
	if player_index < 0 or player_index >= game_state.players.size():
		return null
	var player: PlayerState = game_state.players[player_index]
	if player.active_pokemon != null:
		var active_top: CardInstance = player.active_pokemon.get_top_card()
		if active_top != null and active_top.instance_id == top_instance_id:
			return player.active_pokemon
	for slot: PokemonSlot in player.bench:
		if slot == null:
			continue
		var top_card: CardInstance = slot.get_top_card()
		if top_card != null and top_card.instance_id == top_instance_id:
			return slot
	return null


func _restore_serialized_interaction_items(raw_items: Array, game_state: GameState) -> Array:
	var restored_items: Array = []
	for item_variant in raw_items:
		if not (item_variant is Dictionary):
			restored_items.append(item_variant)
			continue
		var item_data: Dictionary = item_variant as Dictionary
		var item_type: String = str(item_data.get("type", ""))
		if item_type == "card" or item_data.has("card_name"):
			var restored_card := _restore_serialized_card_instance(item_data)
			if restored_card != null:
				restored_items.append(restored_card)
		elif item_type == "slot" and item_data.has("slot_ref"):
			var restored_slot := _restore_slot_from_ref(
				item_data.get("slot_ref", {}),
				game_state,
				int(item_data.get("top_instance_id", -1))
			)
			if restored_slot != null:
				restored_items.append(restored_slot)
		elif item_type == "text":
			restored_items.append(str(item_data.get("label", "")))
	return restored_items


func _restore_serialized_interaction_groups(raw_groups: Array, game_state: GameState) -> Array:
	var restored_groups: Array = []
	for group_variant in raw_groups:
		if not (group_variant is Dictionary):
			continue
		var restored_group: Dictionary = (group_variant as Dictionary).duplicate(true)
		if restored_group.has("slot_ref"):
			var restored_slot := _restore_slot_from_ref(
				restored_group.get("slot_ref", {}),
				game_state,
				int(restored_group.get("top_instance_id", -1))
			)
			if restored_slot != null:
				restored_group["slot"] = restored_slot
			restored_group.erase("slot_ref")
		restored_groups.append(restored_group)
	return restored_groups

var _trainer_interaction_step: Dictionary = {}


# ===================== 网络动作发送 =====================

func send_action(action_type: String, params: Dictionary = {}) -> void:
	if _net_client:
		_net_client.send_action(action_type, params)


func send_choice_response(choice_type: String, data: Dictionary = {}) -> void:
	if _net_client:
		_net_client.send_choice_response(choice_type, data)


func get_my_player_index() -> int:
	return _net_my_player_index


func get_network_client() -> NetworkClient:
	return _net_client

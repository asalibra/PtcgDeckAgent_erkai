## 网络对战补丁脚本 - 替换 BattleScene 的 GSM 调用为网络发送
## 运行在 BattleScene 实例上，拥有完整的节点树访问权限
extends "res://scenes/battle/BattleScene.gd"

## 由 NetBattleScene 包装器设置
var _net_mode: bool = false
var _net_handler: Control = null  # NetBattleScene 引用
var _net_server_pending_choice_type: String = ""
var _net_server_pending_choice_target_player: int = -1


func _start_battle() -> void:
	if _net_mode:
		# 网络模式：不创建本地 GSM，等待服务器状态
		_gsm = null
		_view_player = _net_handler.get_my_player_index() if _net_handler else 0
		_log("[你是玩家%d] 等待服务器同步游戏状态..." % (_view_player + 1))
		# 设置标题栏显示玩家标识
		var window := get_window()
		if window != null:
			window.title = "PTCG 对战 - 你是玩家%d" % (_view_player + 1)
		return
	super._start_battle()


## 网络模式下覆盖 setup 流程：只处理自己的玩家
func _begin_setup_flow() -> void:
	if _is_net():
		var my_pi: int = _net_handler.get_my_player_index() if _net_handler else 0
		_setup_done = [false, false]
		_view_player = my_pi
		_refresh_ui()
		var gsm = get("_gsm")
		var hand_count: int = gsm.game_state.players[my_pi].hand.size() if gsm and gsm.game_state else -1
		print("[NetPatch] _begin_setup_flow: pi=%d, gsm=%s, hand=%d, overlay_visible=%s" % [my_pi, gsm != null, hand_count, get("_dialog_overlay").visible])
		_show_setup_active_dialog(my_pi)
		print("[NetPatch] _begin_setup_flow: dialog shown, overlay_visible=%s" % get("_dialog_overlay").visible)
		return
	super._begin_setup_flow()


## 检查是否为网络模式
func _is_net() -> bool:
	return _net_mode and _net_handler != null


## 设置玩家标识到 UI
func _set_player_indicator() -> void:
	var my_pi: int = _net_handler.get_my_player_index() if _net_handler else 0
	var phase_label: Label = get("_lbl_phase")
	if phase_label != null:
		phase_label.text = "[你是玩家%d] %s" % [my_pi + 1, phase_label.text]


## 覆盖 UI 刷新，追加玩家标识
func _refresh_ui() -> void:
	super._refresh_ui()
	if _is_net():
		_set_player_indicator()


## 检查是否轮到自己操作（网络模式下阻止非回合操作）
func _is_my_turn() -> bool:
	if _gsm == null or _gsm.game_state == null:
		return false
	if _is_net() and _is_waiting_for_other_player_choice():
		return false
	return _gsm.game_state.current_player_index == _net_handler.get_my_player_index()


func _is_waiting_for_other_player_choice() -> bool:
	if not _is_net():
		return false
	if _net_server_pending_choice_type.is_empty() or _net_server_pending_choice_target_player < 0:
		return false
	return _net_server_pending_choice_target_player != _net_handler.get_my_player_index()


func _can_accept_live_action() -> bool:
	if _is_net() and _is_waiting_for_other_player_choice():
		return false
	return super._can_accept_live_action()


# ===================== 覆盖回合结束 =====================

func _on_end_turn(action_player_index: int = -1) -> void:
	if _is_net():
		if not _is_my_turn():
			return
		_net_handler.send_action(NetProtocol.ACTION_END_TURN)
		return
	super._on_end_turn(action_player_index)


# ===================== 覆盖准备阶段完成 =====================

func _after_setup_bench(pi: int) -> void:
	if _is_net():
		_net_handler.send_action(NetProtocol.ACTION_SETUP_COMPLETE)
		return
	super._after_setup_bench(pi)


# ===================== 覆盖对话框取消 =====================

func _on_dialog_cancel() -> void:
	if _is_net() and _pending_choice == "network_trainer_interaction":
		_pending_choice = ""
		get("_dialog_overlay").visible = false
		_net_handler.send_choice_response(NetProtocol.CHOICE_TRAINER_INTERACTION, {
			"selected_indices": [],
			"cancelled": true,
		})
		return
	super._on_dialog_cancel()


## 网络模式：赋值类对话框确认后发送给服务器
func _commit_network_assignment_selection(stored_assignments: Array[Dictionary]) -> void:
	_pending_choice = ""
	# stored_assignments 每个 entry: {"source_index": int, "source": CardInstance, "target_index": int, "target": PokemonSlot}
	# 转换为 [source_idx, target_idx, source_idx, target_idx, ...] 格式
	var indices: Array = []
	for assignment: Dictionary in stored_assignments:
		var source_idx: int = int(assignment.get("source_index", -1))
		var target_idx: int = int(assignment.get("target_index", -1))
		if source_idx >= 0:
			indices.append(source_idx)
		if target_idx >= 0:
			indices.append(target_idx)
	_net_handler.send_choice_response(NetProtocol.CHOICE_TRAINER_INTERACTION, {
		"selected_indices": indices,
	})


func _commit_network_counter_distribution_selection(stored_assignments: Array[Dictionary]) -> void:
	_pending_choice = ""
	var indices: Array = []
	for assignment: Dictionary in stored_assignments:
		var target_idx: int = int(assignment.get("target_index", -1))
		var amount: int = int(assignment.get("amount", 0))
		if target_idx < 0 or amount <= 0:
			continue
		indices.append(target_idx)
		indices.append(amount)
	_net_handler.send_choice_response(NetProtocol.CHOICE_TRAINER_INTERACTION, {
		"selected_indices": indices,
	})


func _show_retreat_bench_choice(cp: int, energy_discard: Array[CardInstance]) -> void:
	super._show_retreat_bench_choice(cp, energy_discard)
	if not _is_net() or _dialog_data.is_empty():
		return
	var bench_slot_refs: Array = []
	if _gsm != null and _gsm.game_state != null and cp >= 0 and cp < _gsm.game_state.players.size():
		for bench_index: int in _gsm.game_state.players[cp].bench.size():
			bench_slot_refs.append(NetProtocol.make_slot_ref(cp, "bench", bench_index))
	var energy_ids: Array = []
	for energy_card: CardInstance in energy_discard:
		energy_ids.append(energy_card.instance_id)
	_dialog_data["bench_slot_refs"] = bench_slot_refs
	_dialog_data["energy_instance_ids"] = energy_ids


# ===================== 覆盖对话框选择 =====================

func _handle_dialog_choice(selected_indices: PackedInt32Array) -> void:
	if _is_net():
		var idx: int = selected_indices[0] if not selected_indices.is_empty() else -1
		var handled_choice := _pending_choice
		if handled_choice == "network_trainer_interaction":
			_runtime_log(
				"network_trainer_dispatch",
				"event=handle_dialog_choice handled_choice=%s selected=%s %s" % [
					handled_choice,
					JSON.stringify(selected_indices),
					_dialog_state_snapshot(),
				]
			)
		_pending_choice = ""
		_net_handle_dialog_choice(handled_choice, idx, selected_indices)
		return
	super._handle_dialog_choice(selected_indices)


func _net_handle_dialog_choice(handled_choice: String, idx: int, all_indices: PackedInt32Array = []) -> void:
	match handled_choice:
		"mulligan_extra_draw":
			_net_handler.send_choice_response(NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW, {
				"draw_extra": idx == 0,
			})

		"attack":
			_net_handler.send_action(NetProtocol.ACTION_USE_ATTACK, {
				"attack_index": idx,
			})

		"send_out":
			var bench_raw: Array = _dialog_data.get("bench", [])
			var bench_slots: Array[PokemonSlot] = []
			for s: Variant in bench_raw:
				if s is PokemonSlot:
					bench_slots.append(s)
			if idx >= 0 and idx < bench_slots.size():
				_net_handler.send_choice_response(NetProtocol.CHOICE_SEND_OUT_POKEMON, {
					"slot": _slot_to_ref(bench_slots[idx]),
				})

		"heavy_baton_target":
			var bench_raw: Array = _dialog_data.get("bench", [])
			var bench_slots: Array[PokemonSlot] = []
			for s: Variant in bench_raw:
				if s is PokemonSlot:
					bench_slots.append(s)
			if idx >= 0 and idx < bench_slots.size():
				_net_handler.send_choice_response(NetProtocol.CHOICE_HEAVY_BATON_TARGET, {
					"slot": _slot_to_ref(bench_slots[idx]),
				})

		"retreat_bench":
			var bench_slot_refs: Array = _dialog_data.get("bench_slot_refs", [])
			var bench_slots_raw: Array = _dialog_data.get("bench_slots", _dialog_data.get("bench", []))
			var energy_ids: Array = _dialog_data.get("energy_instance_ids", [])
			if energy_ids.is_empty():
				var energy_cards_raw: Array = _dialog_data.get("energy_discard", [])
				for energy_card: Variant in energy_cards_raw:
					if energy_card is CardInstance:
						energy_ids.append((energy_card as CardInstance).instance_id)
			if idx >= 0 and idx < bench_slots_raw.size():
				var bench_ref: Dictionary = {}
				if idx < bench_slot_refs.size() and bench_slot_refs[idx] is Dictionary:
					bench_ref = (bench_slot_refs[idx] as Dictionary).duplicate(true)
				elif idx >= 0:
					var player_index: int = _net_handler.get_my_player_index() if _net_handler != null else 0
					bench_ref = NetProtocol.make_slot_ref(player_index, "bench", idx)
				if bench_ref.is_empty() and idx < bench_slots_raw.size():
					bench_ref = _slot_to_ref(bench_slots_raw[idx])
				_net_handler.send_action(NetProtocol.ACTION_RETREAT, {
					"bench_slot": bench_ref,
					"energy_instance_ids": energy_ids,
				})

		"network_trainer_interaction":
			var indices: Array = []
			for i in all_indices:
				indices.append(int(i))
			_runtime_log(
				"network_trainer_dispatch",
				"event=send_choice_response handled_choice=%s selected=%s dialog=%s" % [
					handled_choice,
					JSON.stringify(indices),
					_dialog_state_snapshot(),
				]
			)
			_net_handler.send_choice_response(NetProtocol.CHOICE_TRAINER_INTERACTION, {
				"selected_indices": indices,
			})

		"pokemon_action":
			var actions: Array = _dialog_data.get("actions", [])
			if idx >= 0 and idx < actions.size():
				var action: Variant = actions[idx]
				if action is Dictionary:
					var action_data: Dictionary = action
					var action_slot: Variant = action_data.get("slot", null)
					var action_type: String = str(action_data.get("type", ""))
					if not bool(action_data.get("enabled", true)):
						_log(str(action_data.get("reason", "当前无法执行该操作")))
						return
					var cp_action: int = _dialog_data.get("player", 0)
					if action_slot is PokemonSlot and action_type == "ability":
						_try_use_ability_with_interaction(
							cp_action, action_slot, int(action_data.get("ability_index", 0)))
					elif action_slot is PokemonSlot and action_type == "attack":
						_try_use_attack_with_interaction(
							cp_action, action_slot, int(action_data.get("attack_index", 0)))
					elif action_slot is PokemonSlot and action_type == "granted_attack":
						_try_use_granted_attack_with_interaction(
							cp_action, action_slot, action_data.get("granted_attack", {}))
					elif action_type == "retreat":
						if _gsm != null and _gsm.rule_validator.can_retreat(_gsm.game_state, cp_action):
							_show_retreat_dialog(cp_action)
						else:
							_log("当前无法撤退")

		_:
			if handled_choice.begins_with("setup_active_"):
				var basics_raw: Array = _dialog_data.get("basics", [])
				var basics: Array[CardInstance] = []
				for c: Variant in basics_raw:
					if c is CardInstance:
						basics.append(c)
				if idx >= 0 and idx < basics.size():
					_net_handler.send_action(NetProtocol.ACTION_SETUP_PLACE_ACTIVE, {
						"instance_id": basics[idx].instance_id,
					})
			elif handled_choice.begins_with("setup_bench_"):
				if idx == 0:
					_net_handler.send_action(NetProtocol.ACTION_SETUP_COMPLETE)
				else:
					var cards_raw: Array = _dialog_data.get("cards", [])
					var cards: Array[CardInstance] = []
					for c: Variant in cards_raw:
						if c is CardInstance:
							cards.append(c)
					var card_idx: int = idx - 1
					if card_idx >= 0 and card_idx < cards.size():
						_net_handler.send_action(NetProtocol.ACTION_SETUP_PLACE_BENCH, {
							"instance_id": cards[card_idx].instance_id,
						})


# ===================== 覆盖场地点击操作 =====================

func _handle_slot_left_click(slot_id: String) -> void:
	if _is_net():
		_net_handle_slot_left_click(slot_id)
		return
	super._handle_slot_left_click(slot_id)


func _net_handle_slot_left_click(slot_id: String) -> void:
	# 场地交互（如昏厥换位）优先于回合检查，因为需要在对手回合也能操作
	if _is_field_interaction_active():
		var gs: GameState = _gsm.game_state if _gsm != null else null
		if gs != null:
			var target_slot: PokemonSlot = _slot_from_id(slot_id, gs)
			_try_handle_field_interaction_slot_click(slot_id, target_slot)
		return
	if not _is_my_turn():
		return
	if _selected_hand_card == null:
		# 无手牌选中：点击己方宝可梦弹出操作菜单
		if slot_id.begins_with("my_") and _gsm != null and _gsm.game_state != null:
			var cp: int = _net_handler.get_my_player_index() if _net_handler else 0
			var gs: GameState = _gsm.game_state
			var target_slot: PokemonSlot = _slot_from_id(slot_id, gs)
			if target_slot != null:
				_show_pokemon_action_dialog(cp, target_slot, slot_id == "my_active")
		return
	# 手牌选中：只能操作自己的宝可梦
	if slot_id.begins_with("opp_"):
		_log("不能对对方的宝可梦使用手牌")
		return
	var card = _selected_hand_card
	var my_pi: int = _net_handler.get_my_player_index() if _net_handler else 0
	var gs: GameState = _gsm.game_state if _gsm != null else null
	var target_slot: PokemonSlot = _slot_from_id(slot_id, gs) if gs != null else null

	# 空位 + 基础宝可梦 → 放到备战区
	if target_slot == null and slot_id.begins_with("my_") and card.card_data.is_basic_pokemon():
		_try_play_to_bench(my_pi, card, slot_id)
		_selected_hand_card = null
		return

	# 有宝可梦的槽位 → 进化/能量/工具
	if target_slot == null:
		return
	var slot_ref := _slot_id_to_ref(slot_id, my_pi)
	var cd: CardData = card.card_data
	if cd.is_pokemon() and cd.stage != "Basic":
		_net_handler.send_action(NetProtocol.ACTION_EVOLVE, {
			"instance_id": card.instance_id,
			"target_slot": slot_ref,
		})
	elif cd.card_type == "Basic Energy" or cd.card_type == "Special Energy":
		_net_handler.send_action(NetProtocol.ACTION_ATTACH_ENERGY, {
			"instance_id": card.instance_id,
			"target_slot": slot_ref,
		})
	elif cd.card_type == "Tool":
		_net_handler.send_action(NetProtocol.ACTION_ATTACH_TOOL, {
			"instance_id": card.instance_id,
			"target_slot": slot_ref,
		})
	_selected_hand_card = null


# ===================== 覆盖放宝可梦到备战区 =====================

func _try_play_to_bench(player_index: int, card: CardInstance, _slot_id: String) -> void:
	if _is_net():
		if not _is_my_turn():
			return
		_net_handler.send_action(NetProtocol.ACTION_PLAY_BASIC_TO_BENCH, {
			"instance_id": card.instance_id if card != null else -1,
		})
		return
	super._try_play_to_bench(player_index, card, _slot_id)


# ===================== 覆盖领取奖赏卡 =====================

func _try_take_prize_from_slot(player_index: int, slot_index: int) -> void:
	if _is_net():
		_net_handler.send_choice_response(NetProtocol.CHOICE_TAKE_PRIZE, {
			"slot_index": slot_index,
		})
		return
	super._try_take_prize_from_slot(player_index, slot_index)


# ===================== 覆盖 Heavy Baton / Exp Share =====================

func _commit_heavy_baton_assignment(stored_assignments: Array[Dictionary]) -> void:
	if _is_net():
		var target_slot: PokemonSlot = null
		for assignment: Dictionary in stored_assignments:
			var target: Variant = assignment.get("target")
			if target is PokemonSlot:
				target_slot = target
				break
		if target_slot != null:
			_net_handler.send_choice_response(NetProtocol.CHOICE_HEAVY_BATON_TARGET, {
				"slot": _slot_to_ref(target_slot),
			})
		return
	super._commit_heavy_baton_assignment(stored_assignments)


func _commit_exp_share_assignment(stored_assignments: Array[Dictionary]) -> void:
	if _is_net():
		var target_slot: PokemonSlot = null
		for assignment: Dictionary in stored_assignments:
			var target: Variant = assignment.get("target")
			if target is PokemonSlot:
				target_slot = target
				break
		if target_slot != null:
			_net_handler.send_choice_response(NetProtocol.CHOICE_EXP_SHARE_TARGET, {
				"slot": _slot_to_ref(target_slot),
			})
		return
	super._commit_exp_share_assignment(stored_assignments)


# ===================== 覆盖攻击 =====================

func _try_use_attack_with_interaction(
	player_index: int,
	slot: PokemonSlot,
	attack_index: int,
	preselected_targets: Array = []
) -> void:
	if _is_net():
		if not _is_my_turn():
			return
		_net_handler.send_action(NetProtocol.ACTION_USE_ATTACK, {
			"attack_index": attack_index,
		})
		return
	super._try_use_attack_with_interaction(player_index, slot, attack_index, preselected_targets)


func _try_use_granted_attack_with_interaction(player_index: int, slot: PokemonSlot, granted_attack: Dictionary) -> void:
	if _is_net():
		if not _is_my_turn():
			return
		_net_handler.send_action(NetProtocol.ACTION_USE_GRANTED_ATTACK, {
			"attacker_slot": _slot_to_ref(slot),
			"attack_name": str(granted_attack.get("name", "")),
		})
		return
	super._try_use_granted_attack_with_interaction(player_index, slot, granted_attack)


# ===================== 覆盖手牌点击（训练家/竞技场路由） =====================

func _on_hand_card_clicked(inst: CardInstance, _panel: PanelContainer) -> void:
	if _is_net():
		if not _can_accept_live_action() or not _is_my_turn():
			return
		if _is_field_interaction_active():
			return
		if _selected_hand_card == inst:
			_selected_hand_card = null
			_refresh_hand()
			return
		var card_data: CardData = inst.card_data
		if card_data.card_type == "Supporter" or card_data.card_type == "Item":
			_net_handler.send_action(NetProtocol.ACTION_PLAY_TRAINER, {
				"instance_id": inst.instance_id,
			})
			return
		if card_data.card_type == "Stadium":
			_net_handler.send_action(NetProtocol.ACTION_PLAY_STADIUM, {
				"instance_id": inst.instance_id,
			})
			return
		# Basic/Stage/Energy/Tool → 选中等待场地点击
		_selected_hand_card = inst
		_refresh_hand()
		return
	super._on_hand_card_clicked(inst, _panel)


# ===================== 覆盖训练家/竞技场/特性使用 =====================

func _try_play_trainer_with_interaction(player_index: int, card: CardInstance) -> void:
	if _is_net():
		if not _is_my_turn():
			return
		_net_handler.send_action(NetProtocol.ACTION_PLAY_TRAINER, {
			"instance_id": card.instance_id,
		})
		return
	super._try_play_trainer_with_interaction(player_index, card)


func _try_play_stadium_with_interaction(player_index: int, card: CardInstance) -> void:
	if _is_net():
		if not _is_my_turn():
			return
		_net_handler.send_action(NetProtocol.ACTION_PLAY_STADIUM, {
			"instance_id": card.instance_id,
		})
		return
	super._try_play_stadium_with_interaction(player_index, card)


func _try_use_ability_with_interaction(player_index: int, slot: PokemonSlot, ability_index: int) -> void:
	if _is_net():
		if not _is_my_turn():
			return
		_net_handler.send_action(NetProtocol.ACTION_USE_ABILITY, {
			"slot": _slot_to_ref(slot),
			"ability_index": ability_index,
		})
		return
	super._try_use_ability_with_interaction(player_index, slot, ability_index)


func _try_use_stadium_with_interaction(player_index: int) -> void:
	if _is_net():
		if not _is_my_turn():
			return
		_net_handler.send_action(NetProtocol.ACTION_USE_STADIUM_EFFECT)
		return
	super._try_use_stadium_with_interaction(player_index)


# ===================== 工具方法 =====================

func _slot_to_ref(slot) -> Dictionary:
	if slot == null or _gsm == null or _gsm.game_state == null:
		return {}
	for pi in range(_gsm.game_state.players.size()):
		var player: PlayerState = _gsm.game_state.players[pi]
		if player.active_pokemon == slot:
			return NetProtocol.make_slot_ref(pi, "active", 0)
		var bench_idx := player.bench.find(slot)
		if bench_idx >= 0:
			return NetProtocol.make_slot_ref(pi, "bench", bench_idx)
	return {}


func _slot_id_to_ref(slot_id: String, my_player_index: int) -> Dictionary:
	if slot_id.begins_with("my_"):
		if slot_id == "my_active":
			return NetProtocol.make_slot_ref(my_player_index, "active", 0)
		elif slot_id.begins_with("my_bench_"):
			return NetProtocol.make_slot_ref(my_player_index, "bench", int(slot_id.substr(9)))
	elif slot_id.begins_with("opp_"):
		var opp := 1 - my_player_index
		if slot_id == "opp_active":
			return NetProtocol.make_slot_ref(opp, "active", 0)
		elif slot_id.begins_with("opp_bench_"):
			return NetProtocol.make_slot_ref(opp, "bench", int(slot_id.substr(10)))
	return {}

## 弃掉手牌中的能量卡，每张追加伤害
## Make It Rain - Gholdengo ex: discard energy from hand ×50 damage
class_name AttackDiscardHandEnergyDamage
extends BaseEffect

var damage_per_energy: int = 50
var attack_index_to_match: int = -1


func _init(per_energy: int = 50, match_index: int = -1) -> void:
	damage_per_energy = per_energy
	attack_index_to_match = match_index


func applies_to_attack_index(index: int) -> bool:
	return attack_index_to_match < 0 or attack_index_to_match == index


func get_damage_bonus(attacker: PokemonSlot, state: GameState) -> int:
	if attacker == null or state == null:
		return 0
	var top_card: CardInstance = attacker.get_top_card()
	if top_card == null:
		return 0
	var owner_index: int = top_card.owner_index
	var player: PlayerState = state.players[owner_index]

	var energy_count: int = 0
	for card: CardInstance in player.hand:
		if card.card_data != null and "Energy" in card.card_data.card_type:
			energy_count += 1
	return energy_count * damage_per_energy


func execute_attack(
	attacker: PokemonSlot,
	_defender: PokemonSlot,
	_attack_index: int,
	state: GameState
) -> void:
	if attacker == null or state == null:
		return
	var top_card: CardInstance = attacker.get_top_card()
	if top_card == null:
		return
	var owner_index: int = top_card.owner_index
	var player: PlayerState = state.players[owner_index]

	# Discard all energy cards from hand
	var discarded: Array[CardInstance] = []
	for card: CardInstance in player.hand:
		if card.card_data != null and "Energy" in card.card_data.card_type:
			discarded.append(card)

	for card: CardInstance in discarded:
		player.hand.erase(card)
		player.discard_pile.append(card)

	if not discarded.is_empty() and state.battle_log != null:
		state.battle_log.log_action("effect", "弃掉%d张能量卡" % discarded.size())


func get_description() -> String:
	return "将任意数量的基本能量卡从手牌弃掉。每弃掉1张，追加%d伤害。" % damage_per_energy

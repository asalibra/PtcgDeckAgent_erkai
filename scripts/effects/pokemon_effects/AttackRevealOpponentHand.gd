## 对手展示手牌
## See Through - Espurr
class_name AttackRevealOpponentHand
extends BaseEffect

var attack_index_to_match: int = -1


func _init(match_index: int = -1) -> void:
	attack_index_to_match = match_index


func applies_to_attack_index(index: int) -> bool:
	return attack_index_to_match < 0 or attack_index_to_match == index


func execute_attack(
	attacker: PokemonSlot,
	defender: PokemonSlot,
	_attack_index: int,
	state: GameState
) -> void:
	if attacker == null or defender == null or state == null:
		return
	var top_card: CardInstance = attacker.get_top_card()
	if top_card == null:
		return
	var opponent_index: int = 1 - top_card.owner_index
	var opponent: PlayerState = state.players[opponent_index]

	# Log the hand contents
	if state.battle_log != null:
		var card_names: Array[String] = []
		for card: CardInstance in opponent.hand:
			if card.card_data != null:
				card_names.append(card.card_data.name)
		state.battle_log.log_action("effect", "对手展示手牌: %s" % ", ".join(card_names))


func get_description() -> String:
	return "对手展示手牌。"

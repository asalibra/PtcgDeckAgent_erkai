## 从弃牌堆拿回训练家卡
## Electromagnetic Sonar - Dedenne: put a Trainer card from discard into hand
class_name AttackRetrieveTrainerFromDiscard
extends BaseEffect

var attack_index_to_match: int = -1


func _init(match_index: int = -1) -> void:
	attack_index_to_match = match_index


func applies_to_attack_index(index: int) -> bool:
	return attack_index_to_match < 0 or attack_index_to_match == index


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

	# Find trainer cards in discard
	var trainer_cards: Array[CardInstance] = []
	for card: CardInstance in player.discard_pile:
		if card.card_data != null:
			var ct: String = card.card_data.card_type
			if ct in ["Item", "Supporter", "Tool", "Stadium"]:
				trainer_cards.append(card)

	if trainer_cards.is_empty():
		return

	# Move the first trainer card to hand
	var chosen: CardInstance = trainer_cards[0]
	player.discard_pile.erase(chosen)
	player.hand.append(chosen)

	if state.battle_log != null:
		state.battle_log.log_action("effect", "从弃牌堆拿回训练家卡: %s" % chosen.card_data.name)


func get_description() -> String:
	return "从自己的弃牌堆选择1张训练家卡，加入手牌。"

## 对手展示手牌，弃掉其中的物品卡和宝可梦道具
## Crushing Pulse - Rotom
class_name AttackRevealHandDiscardItems
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

	# Reveal hand (log it)
	var hand_cards: Array[CardInstance] = []
	for card: CardInstance in opponent.hand:
		hand_cards.append(card)

	# Discard all Item and Tool cards
	var discarded: Array[CardInstance] = []
	for card: CardInstance in hand_cards:
		if card.card_data != null:
			var ct: String = card.card_data.card_type
			if ct == "Item" or ct == "Tool":
				discarded.append(card)

	for card: CardInstance in discarded:
		opponent.hand.erase(card)
		opponent.discard_pile.append(card)

	if not discarded.is_empty() and state.battle_log != null:
		state.battle_log.log_action("effect", "展示手牌并弃掉%d张物品/道具卡" % discarded.size())


func get_description() -> String:
	return "对手展示手牌。弃掉对手手中的所有物品卡和宝可梦道具。"

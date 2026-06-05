## 从牌库搜索基本能量卡到手牌
## Minor Errand-Running - Gimmighoul: search 2 basic energy to hand
class_name AttackSearchBasicEnergyToHand
extends BaseEffect

var search_count: int = 2
var attack_index_to_match: int = -1


func _init(count: int = 2, match_index: int = -1) -> void:
	search_count = count
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

	# Search for basic energy cards
	var found: Array[CardInstance] = []
	for card: CardInstance in player.deck:
		if card.card_data != null and card.card_data.card_type == "Basic Energy":
			found.append(card)
			if found.size() >= search_count:
				break

	# Move found cards to hand
	for card: CardInstance in found:
		player.deck.erase(card)
		player.hand.append(card)

	# Shuffle deck
	player.deck.shuffle()

	if state.battle_log != null:
		state.battle_log.log_action("effect", "从牌库搜索%d张基本能量卡到手牌" % found.size())


func get_description() -> String:
	return "从自己的牌库中选择最多%d张基本能量卡，加入手牌。然后重洗牌库。" % search_count

## 对手选择手牌中的卡洗回牌库
## Cursed Words - Banette: opponent chooses 3 cards from hand, shuffles into deck
class_name AttackOpponentShuffleHandCards
extends BaseEffect

var cards_to_shuffle: int = 3
var attack_index_to_match: int = -1


func _init(count: int = 3, match_index: int = -1) -> void:
	cards_to_shuffle = count
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

	# Opponent chooses N cards from hand to shuffle into deck
	# In AI/headless mode, choose the last N cards
	var hand_size: int = opponent.hand.size()
	if hand_size == 0:
		return

	var count: int = mini(cards_to_shuffle, hand_size)
	var shuffled_cards: Array[CardInstance] = []

	# Take the last N cards (AI mode - in human mode this would be a choice prompt)
	for i in range(count):
		var idx: int = hand_size - 1 - i
		if idx >= 0 and idx < opponent.hand.size():
			shuffled_cards.append(opponent.hand[idx])

	for card: CardInstance in shuffled_cards:
		opponent.hand.erase(card)
		opponent.deck.append(card)

	opponent.deck.shuffle()

	if state.battle_log != null:
		state.battle_log.log_action("effect", "对手将%d张手牌洗回牌库" % shuffled_cards.size())


func get_description() -> String:
	return "对手从手牌中选择%d张卡，将其放回牌库并重洗。" % cards_to_shuffle

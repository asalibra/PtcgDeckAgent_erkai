## 本回合进化自特定宝可梦时追加伤害
## Strike It Rich - Gholdengo: evolved from Gimmighoul this turn +90
class_name AttackBonusIfEvolvedThisTurn
extends BaseEffect

var damage_bonus: int = 90
var required_pre_evolution: String = ""
var attack_index_to_match: int = -1


func _init(bonus: int = 90, pre_evolution: String = "", match_index: int = -1) -> void:
	damage_bonus = bonus
	required_pre_evolution = pre_evolution
	attack_index_to_match = match_index


func applies_to_attack_index(index: int) -> bool:
	return attack_index_to_match < 0 or attack_index_to_match == index


func get_damage_bonus(attacker: PokemonSlot, state: GameState) -> int:
	if attacker == null or state == null:
		return 0
	var top_card: CardInstance = attacker.get_top_card()
	if top_card == null:
		return 0
	# Check if the card was evolved this turn
	if not top_card.metadata.get("evolved_this_turn", false):
		return 0
	# If a specific pre-evolution is required, check it
	if not required_pre_evolution.is_empty():
		var prev_card: CardInstance = attacker.get_card_below_top()
		if prev_card == null or prev_card.card_data.name != required_pre_evolution:
			return 0
	return damage_bonus


func get_description() -> String:
	return "如果本回合从%s进化，则追加%d伤害。" % [required_pre_evolution if not required_pre_evolution.is_empty() else "基础", damage_bonus]

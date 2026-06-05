## 下回合对手能量不足的宝可梦不能攻击
## Frigid Fangs - Walrein: opponent's Pokemon with ≤2 energy can't attack
class_name AttackOpponentEnergyLockNextTurn
extends BaseEffect

var max_energy: int = 2
var attack_index_to_match: int = -1


func _init(max_energy_count: int = 2, match_index: int = -1) -> void:
	max_energy = max_energy_count
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
	var owner_index: int = top_card.owner_index
	var effect_key := "opponent_energy_lock_%d_%d" % [owner_index, state.turn_number]
	state.set_temporary_effect(effect_key, {
		"type": "attack_lock_by_energy",
		"max_energy": max_energy,
		"source_player": owner_index,
		"turn": state.turn_number,
	})


func get_description() -> String:
	return "在对手的下个回合，身上附着%d张或更少能量的宝可梦无法使用招式。" % max_energy

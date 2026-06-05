## 场上没有竞技场时此招式无效
## Assault Landing - Fan Rotom
class_name AttackFailIfNoStadium
extends BaseEffect

var attack_index_to_match: int = -1


func _init(match_index: int = -1) -> void:
	attack_index_to_match = match_index


func applies_to_attack_index(index: int) -> bool:
	return attack_index_to_match < 0 or attack_index_to_match == index


func can_execute_attack(
	attacker: PokemonSlot,
	_defender: PokemonSlot,
	_attack_index: int,
	state: GameState
) -> bool:
	return state != null and state.stadium_card != null


func get_description() -> String:
	return "如果场上没有竞技场卡，则此招式的伤害为0。"

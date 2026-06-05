## 下回合防止对己方太晶宝可梦的伤害
## C.O.D.E.: Protect - Miraidon
class_name AttackPreventDamageToTera
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
	var effect_key := "tera_protect_%d_%d" % [owner_index, state.turn_number]
	state.set_temporary_effect(effect_key, {
		"type": "tera_damage_prevention",
		"source_player": owner_index,
		"turn": state.turn_number,
	})


func get_description() -> String:
	return "在对手的下个回合，防止对己方所有太晶宝可梦的伤害。"

## 下回合不能使用此特定招式（不是完全不能攻击）
## Zap Cannon, Brave Slash, Boss Headbutt, Ogre's Hammer, Impact Blow
class_name AttackSelfAttackLock
extends BaseEffect

var attack_index_to_match: int = -1


func _init(match_index: int = -1) -> void:
	attack_index_to_match = match_index


func applies_to_attack_index(index: int) -> bool:
	return attack_index_to_match < 0 or attack_index_to_match == index


func execute_attack(
	attacker: PokemonSlot,
	_defender: PokemonSlot,
	attack_index: int,
	state: GameState
) -> void:
	if attacker == null or state == null:
		return
	var top_card: CardInstance = attacker.get_top_card()
	if top_card == null:
		return
	var owner_index: int = top_card.owner_index
	var effect_key := "self_attack_lock_%d_%d_%d" % [owner_index, attack_index, state.turn_number]
	state.set_temporary_effect(effect_key, {
		"type": "self_attack_lock",
		"source_player": owner_index,
		"attack_index": attack_index,
		"turn": state.turn_number,
	})


func get_description() -> String:
	return "在下个自己的回合，此宝可梦不能使用此招式。"

## 后备有太晶宝可梦时追加伤害
## Shining Blaze - Ho-Oh: Tera on bench +100
class_name AttackBonusIfTeraOnBench
extends BaseEffect

var damage_bonus: int = 100
var attack_index_to_match: int = -1


func _init(bonus: int = 100, match_index: int = -1) -> void:
	damage_bonus = bonus
	attack_index_to_match = match_index


func applies_to_attack_index(index: int) -> bool:
	return attack_index_to_match < 0 or attack_index_to_match == index


func get_damage_bonus(attacker: PokemonSlot, state: GameState) -> int:
	if attacker == null or state == null:
		return 0
	var owner_index: int = attacker.get_top_card().owner_index if attacker.get_top_card() != null else -1
	if owner_index < 0:
		return 0
	var player: PlayerState = state.players[owner_index]
	for bench_slot: PokemonSlot in player.bench:
		var bench_card: CardInstance = bench_slot.get_top_card() if bench_slot != null else null
		if bench_card != null and bench_card.card_data != null:
			if bench_card.card_data.has_tag(CardData.TERA_TAG):
				return damage_bonus
	return 0


func get_description() -> String:
	return "如果己方后备区有太晶宝可梦，则追加%d伤害。" % damage_bonus

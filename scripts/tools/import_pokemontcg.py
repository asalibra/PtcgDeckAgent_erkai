#!/usr/bin/env python3
"""
Import card data from PokemonTCG GitHub into CardData-compatible JSON.
Usage:
  python3 import_pokemontcg.py sv8pt5
  python3 import_pokemontcg.py sv8 sv8pt5 sv9
  python3 import_pokemontcg.py --all-sv
"""

import json
import os
import sys
import time
import urllib.request
import argparse
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
PROJECT_DIR = SCRIPT_DIR.parent.parent
CARDS_DIR = PROJECT_DIR / "data" / "bundled_user" / "cards"
IMAGES_DIR = PROJECT_DIR / "data" / "bundled_user" / "cards" / "images"
SET_MAP_PATH = SCRIPT_DIR / "pokemontcg_set_map.json"
NAME_MAP_PATH = SCRIPT_DIR / "pokemon_name_map.json"

GITHUB_RAW = "https://raw.githubusercontent.com/PokemonTCG/pokemon-tcg-data/master/cards/en/{}.json"
SETS_API = "https://api.pokemontcg.io/v2/sets?select=id,ptcgoCode,name"

ENERGY_MAP = {
    "Fire": "R", "Water": "W", "Grass": "G", "Lightning": "L",
    "Psychic": "P", "Fighting": "F", "Darkness": "D", "Metal": "M",
    "Dragon": "N", "Colorless": "C",
}

MECHANICS = {"ex", "V", "VSTAR", "VMAX", "Radiant", "V-UNION", "LEGEND"}
STAGES = {"Basic", "Stage 1", "Stage 2"}
TAGS_TO_KEEP = {"ex", "V", "VSTAR", "VMAX", "Radiant", "Tera", "ACE SPEC",
                "Ancient", "Future", "V-UNION", "LEGEND"}

RARITY_MAP = {
    "Common": "C", "Uncommon": "U", "Rare": "R",
    "Double Rare": "RR", "Ultra Rare": "UR", "Illustration Rare": "SAR",
    "Special Art Rare": "SAR", "Hyper Rare": "HR", "ACE SPEC Rare": "ACE",
    "Shiny Rare": "SR", "Shiny Ultra Rare": "SAR",
    "Amazing Rare": "AR", "Radiant Rare": "AR",
}


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent="\t")


def energy_word_to_code(word):
    return ENERGY_MAP.get(word, "C")


def cost_array_to_string(cost_arr):
    if not cost_arr:
        return ""
    return "".join(energy_word_to_code(c) for c in cost_arr)


def derive_card_type(supertype, subtypes):
    # PokemonTCG uses "Pokémon" (with accent), normalize for comparison
    st = supertype.replace("é", "e").replace("É", "E")
    if st == "Pokemon":
        return "Pokemon"
    if st == "Energy":
        if "Special" in subtypes:
            return "Special Energy"
        return "Basic Energy"
    # Trainer
    if "Pokemon Tool" in subtypes:
        return "Tool"
    if "Stadium" in subtypes:
        return "Stadium"
    if "Supporter" in subtypes:
        return "Supporter"
    return "Item"


def derive_mechanic(subtypes):
    for s in subtypes:
        if s in MECHANICS:
            return s
    return ""


def derive_stage(subtypes):
    for s in subtypes:
        if s in STAGES:
            return s
    if "VSTAR" in subtypes:
        return "VSTAR"
    if "VMAX" in subtypes:
        return "VMAX"
    return ""


def derive_tags(subtypes):
    return [s for s in subtypes if s in TAGS_TO_KEEP]


def derive_label(subtypes):
    labels = []
    for tag in ["Tera", "ACE SPEC", "Ancient", "Future"]:
        if tag in subtypes:
            labels.append(tag)
    return ", ".join(labels) if labels else ""


def derive_ancient_trait(subtypes):
    return "Tera" if "Tera" in subtypes else ""


def convert_card(card_json, set_code, set_code_en, name_map):
    """Convert a PokemonTCG card JSON to CardData-compatible dict."""
    name_en = card_json.get("name", "")
    cn_name = name_map.get(name_en, "")

    supertype = card_json.get("supertype", "Pokemon")
    subtypes = card_json.get("subtypes", [])
    card_type = derive_card_type(supertype, subtypes)

    number = card_json.get("number", "")

    # Build description from rules
    rules = card_json.get("rules", [])
    description = "\n".join(rules) if rules else ""

    # For Pokemon, build description from attacks
    attacks_raw = card_json.get("attacks", [])
    if card_type == "Pokemon" and attacks_raw:
        parts = []
        for atk in attacks_raw:
            cost_str = cost_array_to_string(atk.get("cost", []))
            dmg = atk.get("damage", "")
            txt = atk.get("text", "")
            # Use ASCII-safe brackets for portability
            line = "[%s] %s %s" % (cost_str, atk.get("name", ""), dmg)
            if txt:
                line += "\n%s" % txt
            parts.append(line.strip())
        if parts:
            description = "\n".join(parts)

    # Attacks
    attacks = []
    for atk in attacks_raw:
        attacks.append({
            "name": atk.get("name", ""),
            "text": atk.get("text", ""),
            "cost": cost_array_to_string(atk.get("cost", [])),
            "damage": atk.get("damage", ""),
            "is_vstar_power": False,
        })

    # Abilities
    abilities = []
    for ab in card_json.get("abilities", []):
        abilities.append({"name": ab.get("name", ""), "text": ab.get("text", "")})

    # Weakness / Resistance
    weaks = card_json.get("weaknesses", [])
    weakness_energy = energy_word_to_code(weaks[0]["type"]) if weaks else ""
    weakness_value = weaks[0].get("value", "x2") if weaks else ""
    weakness_value = weakness_value.replace("×", "x")  # normalize unicode multiplication sign

    resists = card_json.get("resistances", [])
    resistance_energy = energy_word_to_code(resists[0]["type"]) if resists else ""
    resistance_value = resists[0].get("value", "-30") if resists else ""

    # Retreat cost
    retreat_cost = len(card_json.get("retreatCost", []))

    # Energy type
    types_arr = card_json.get("types", [])
    energy_type = energy_word_to_code(types_arr[0]) if types_arr else ""

    # HP
    try:
        hp = int(card_json.get("hp", "0"))
    except (ValueError, TypeError):
        hp = 0

    # Image
    images = card_json.get("images", {})
    image_url = images.get("large", images.get("small", ""))

    # Legality
    legalities = card_json.get("legalities", {})
    reg_standard = legalities.get("standard", "") == "Legal"
    reg_expanded = legalities.get("expanded", "") == "Legal"

    # Rarity
    rarity_raw = card_json.get("rarity", "")
    rarity = RARITY_MAP.get(rarity_raw, rarity_raw)

    # Energy provides (for basic energy)
    energy_provides = ""
    if card_type == "Basic Energy":
        for word, code in ENERGY_MAP.items():
            if word.lower() in name_en.lower():
                energy_provides = code
                break

    return {
        "name": cn_name,
        "name_en": name_en,
        "card_type": card_type,
        "mechanic": derive_mechanic(subtypes),
        "label": derive_label(subtypes),
        "description": description,
        "yoren_code": "",
        "set_code": set_code,
        "card_index": number,
        "set_code_en": set_code_en,
        "card_index_en": number,
        "effect_id": "",
        "image_url": image_url,
        "image_local_path": f"user://cards/images/{set_code}/{number}.png",
        "artist": card_json.get("artist", ""),
        "rarity": rarity,
        "release_date": "",
        "regulation_mark": card_json.get("regulationMark", ""),
        "is_tags": derive_tags(subtypes),
        "regulation_standard": reg_standard,
        "regulation_expanded": reg_expanded,
        "energy_type": energy_type,
        "stage": derive_stage(subtypes),
        "hp": hp,
        "weakness_energy": weakness_energy,
        "weakness_value": weakness_value,
        "resistance_energy": resistance_energy,
        "resistance_value": resistance_value,
        "retreat_cost": retreat_cost,
        "evolves_from": card_json.get("evolvesFrom", ""),
        "ancient_trait": derive_ancient_trait(subtypes),
        "attacks": attacks,
        "abilities": abilities,
        "energy_provides": energy_provides,
    }


def _curl_json(url, tmp_name):
    """Fetch JSON via curl (more reliable on Windows with proxy)."""
    import subprocess, tempfile
    tmp_path = os.path.join(tempfile.gettempdir(), tmp_name)
    try:
        result = subprocess.run(
            ["curl", "-sL", "--max-time", "30", "-o", tmp_path, url],
            capture_output=True, text=True, timeout=35
        )
        if result.returncode == 0 and os.path.exists(tmp_path):
            with open(tmp_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            os.remove(tmp_path)
            return data
    except Exception:
        pass
    # Fallback to urllib
    req = urllib.request.Request(url, headers={"User-Agent": "PTCGDeckAgent/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_set_data(set_id):
    """Download set card data from PokemonTCG GitHub."""
    url = GITHUB_RAW.format(set_id)
    print(f"  Fetching {url} ...")
    return _curl_json(url, f"pokemontcg_{set_id}.json")


def fetch_set_ptcgo_codes():
    """Fetch set_id -> ptcgoCode mapping from PokemonTCG API."""
    data = _curl_json(SETS_API, "pokemontcg_sets.json")
    result = {}
    for s in data.get("data", []):
        sid = s.get("id", "")
        code = s.get("ptcgoCode", "")
        if sid and code:
            result[sid] = code
    return result


def main():
    parser = argparse.ArgumentParser(description="Import PokemonTCG GitHub card data")
    parser.add_argument("sets", nargs="*", help="Set IDs (e.g. sv8pt5 sv9)")
    parser.add_argument("--all-sv", action="store_true", help="Import all SV-era sets")
    parser.add_argument("--dry-run", action="store_true", help="Print stats without writing")
    args = parser.parse_args()

    # Load mappings
    set_map = load_json(SET_MAP_PATH)
    name_map = {}
    if NAME_MAP_PATH.exists():
        name_map = load_json(NAME_MAP_PATH)

    # Fetch ptcgoCodes from PokemonTCG API
    print("Fetching set metadata from PokemonTCG API...")
    ptcgo_codes = fetch_set_ptcgo_codes()
    print(f"Loaded {len(name_map)} name translations, {len(set_map)} set mappings, {len(ptcgo_codes)} ptcgoCodes")

    # Determine which sets to import
    if args.all_sv:
        set_ids = [k for k in sorted(set_map.keys()) if k.startswith("sv")]
    elif args.sets:
        set_ids = args.sets
    else:
        print("Usage: python3 import_pokemontcg.py <set_id> [set_id ...]")
        print("       python3 import_pokemontcg.py --all-sv")
        sys.exit(1)

    total_cards = 0
    total_translated = 0

    for set_id in set_ids:
        set_code = set_map.get(set_id)
        if not set_code:
            print(f"[SKIP] {set_id}: not in set map, add to pokemontcg_set_map.json first")
            continue

        # Use ptcgoCode from API as set_code_en, fallback to set_id uppercase
        set_code_en = ptcgo_codes.get(set_id, set_id.upper())

        print(f"\n[{set_id}] -> set_code={set_code}")

        try:
            cards_data = fetch_set_data(set_id)
        except Exception as e:
            print(f"  [ERROR] Failed to fetch: {e}")
            continue

        if not isinstance(cards_data, list):
            print(f"  [ERROR] Expected array, got {type(cards_data)}")
            continue

        imported = 0
        translated = 0
        for card_json in cards_data:
            card = convert_card(card_json, set_code, set_code_en, name_map)
            uid = f"{card['set_code']}_{card['card_index']}"

            if card["name"]:
                translated += 1

            if not args.dry_run:
                save_json(CARDS_DIR / f"{uid}.json", card)
            imported += 1

        print(f"  Imported {imported} cards ({translated} with CN name)")
        total_cards += imported
        total_translated += translated

        # Rate limit
        time.sleep(0.5)

    print(f"\n=== Done: {total_cards} cards imported, {total_translated} with Chinese names ===")


if __name__ == "__main__":
    main()

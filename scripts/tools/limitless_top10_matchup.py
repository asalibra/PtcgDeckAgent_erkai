#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Limitless TCG 前10% vs 前10% 精确对战分析
==========================================
只统计双方都在赛事前10%的对局，排除"高手虐菜"带来的胜率膨胀。

用法:
    python3 limitless_top10_matchup.py --decks dragapult-ex,dragapult-dusknoir
    python3 limitless_top10_matchup.py --decks tera-box,gardevoir-ex-sv --top-pct 5
    python3 limitless_top10_matchup.py --decks dragapult-ex --tournaments 0025,0032,0028
"""

import json
import urllib.request
import time
import argparse
import sys
import os
from collections import defaultdict
from datetime import datetime

# 复用中文名映射
from limitless_deck_analysis import DECK_CN, translate_deck_name

# svi-jtg 环境 300+ 人赛事
ALL_TOURNAMENTS = [
    ("0025", "Atlanta", 2684), ("0032", "Portland", 1688),
    ("0028", "Milwaukee", 1657), ("0026", "Monterrey", 1327),
    ("0031", "Santiago", 1249), ("0030", "Utrecht", 1241),
    ("0033", "Bologna", 1239), ("0027", "Sevilla", 817),
    ("0029", "Melbourne", 563),
]


def fetch_json(url, retries=3):
    for _ in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if data.get("ok"):
                    return data["message"]
        except Exception:
            time.sleep(0.5)
    return None


def main():
    parser = argparse.ArgumentParser(description="Limitless Top10% vs Top10% Matchup Analysis")
    parser.add_argument("--decks", required=True, help="Comma-separated deck identifiers")
    parser.add_argument("--top-pct", type=int, default=10, help="Top percentage (default: 10)")
    parser.add_argument("--tournaments", default=None, help="Comma-separated tournament IDs (default: all 300+)")
    parser.add_argument("--output", default=None, help="Output file path")
    args = parser.parse_args()

    deck_ids = [d.strip() for d in args.decks.split(",")]
    top_pct = args.top_pct

    if args.tournaments:
        tid_list = [t.strip() for t in args.tournaments.split(",")]
        tournaments = [(tid, city, pl) for tid, city, pl in ALL_TOURNAMENTS if tid in tid_list]
    else:
        tournaments = ALL_TOURNAMENTS

    # Build deck info
    DECKS = []
    for deck_id in deck_ids:
        cn = DECK_CN.get(deck_id, deck_id)
        # Try to get English name from API
        url = f"https://mew.limitlesstcg.com/labs/data/tcg/decks?tournamentId={tournaments[0][0]}&division=MA"
        decks_data = fetch_json(url)
        en_name = deck_id
        if decks_data:
            for d in decks_data:
                if d["identifier"] == deck_id:
                    en_name = d["name"]
                    break
        DECKS.append((deck_id, en_name, cn))

    print("=" * 60)
    print(f"  Top{top_pct}% vs Top{top_pct}% 精确对战分析")
    print(f"  卡组: {', '.join(d[2] for d in DECKS)}")
    print(f"  赛事: {len(tournaments)} 场")
    print("=" * 60)

    # Phase 1: 获取每个赛事 top N% 玩家 ID 集合
    print(f"\n[1/3] 获取各赛事 Top{top_pct}% 玩家列表...")
    top_by_tid = {}
    for tid, city, t_players in tournaments:
        top_n = max(1, t_players * top_pct // 100)
        standings = fetch_json(f"https://mew.limitlesstcg.com/labs/data/tcg/standings?tournamentId={tid}&division=MA")
        if standings:
            top_ids = {p["tp_id"] for p in standings if p.get("placement") and p["placement"] <= top_n}
            top_by_tid[tid] = top_ids
            print(f"  [{tid}] {city}: {len(top_ids)} Top{top_pct}% players")
        else:
            top_by_tid[tid] = set()
            print(f"  [{tid}] {city}: FAILED")
        time.sleep(0.3)

    # Phase 2: 拉取对战记录，只保留双方都在 top N% 的对局
    print(f"\n[2/3] 拉取对战数据 (只保留双方都在 Top{top_pct}%)...")
    overall = {d[0]: {"W": 0, "L": 0, "T": 0} for d in DECKS}
    matchup = {d[0]: defaultdict(lambda: {"W": 0, "L": 0, "T": 0}) for d in DECKS}
    player_count = {d[0]: 0 for d in DECKS}
    total_requests = 0

    for tid, city, t_players in tournaments:
        top_ids = top_by_tid.get(tid, set())
        for deck_id, _, _ in DECKS:
            url = f"https://mew.limitlesstcg.com/labs/data/tcg/players?tournamentId={tid}&division=MA&deckId={deck_id}"
            players = fetch_json(url)
            if not players:
                continue

            top_players = [p for p in players if p.get("tp_id") in top_ids]
            for p in top_players:
                pid = p["tp_id"]
                player_count[deck_id] += 1

                url2 = f"https://mew.limitlesstcg.com/labs/data/tcg/matches?tournamentId={tid}&playerId={pid}"
                matches = fetch_json(url2)
                total_requests += 1
                if not matches:
                    continue

                for m in matches:
                    is_p1 = (m["p1_id"] == pid and m["p1_deck"] == deck_id)
                    is_p2 = (m["p2_id"] == pid and m["p2_deck"] == deck_id)
                    if not is_p1 and not is_p2:
                        continue

                    opp_id = m["p2_id"] if is_p1 else m["p1_id"]
                    if opp_id not in top_ids:
                        continue

                    opp_deck = str(
                        m.get("p2_deck_name") if is_p1
                        else m.get("p1_deck_name") or "Unknown"
                    )
                    winner = m.get("winner", 0)
                    result = "T" if winner == 0 else ("W" if winner == pid else "L")
                    overall[deck_id][result] += 1
                    matchup[deck_id][opp_deck][result] += 1

                time.sleep(0.12)
        time.sleep(0.2)

    # Phase 3: 输出结果
    print(f"\n[3/3] 生成报告 (共 {total_requests} 次 API 请求)...")

    lines = []
    for deck_id, deck_name, deck_cn in DECKS:
        o = overall[deck_id]
        total = o["W"] + o["L"] + o["T"]
        wr = o["W"] / (o["W"] + o["L"]) * 100 if (o["W"] + o["L"]) > 0 else 0

        lines.append("=" * 75)
        lines.append(f"{deck_cn} ({deck_name}) | Top{top_pct}% vs Top{top_pct}% | "
                     f"{player_count[deck_id]}人 | {o['W']}W-{o['L']}L-{o['T']}T | 胜率: {wr:.1f}%")
        lines.append("=" * 75)
        lines.append(f"{'对手卡组':<30} {'场次':>5} {'胜':>4} {'负':>4} {'平':>4} {'胜率':>8}")
        lines.append("-" * 75)

        sorted_m = sorted(
            matchup[deck_id].items(),
            key=lambda x: sum(v for k, v in x[1].items() if k in ("W", "L", "T")),
            reverse=True,
        )
        for opp, rec in sorted_m:
            w, l, t = rec["W"], rec["L"], rec["T"]
            total_g = w + l + t
            opp_wr = w / (w + l) * 100 if (w + l) > 0 else 0
            opp_cn = translate_deck_name("", opp)
            lines.append(f"{opp_cn:<30} {total_g:>5} {w:>4} {l:>4} {t:>4} {opp_wr:>7.1f}%")

        tw = sum(r["W"] for r in matchup[deck_id].values())
        tl = sum(r["L"] for r in matchup[deck_id].values())
        tt = sum(r["T"] for r in matchup[deck_id].values())
        twr = tw / (tw + tl) * 100 if (tw + tl) > 0 else 0
        lines.append("-" * 75)
        lines.append(f"{'合计':<30} {tw+tl+tt:>5} {tw:>4} {tl:>4} {tt:>4} {twr:>7.1f}%")
        lines.append("")

    output_text = "\n".join(lines)
    print(output_text)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(output_text)
        print(f"\nSaved to: {os.path.abspath(args.output)}")


if __name__ == "__main__":
    main()

# 网络对战 - 准备阶段 Bug 分析

## Bug 1: 玩家2放下战斗宝可梦后，玩家1点击放置无反应

### 完整消息时序

```
start_game()
  → _gsm.start_game()
    → GSM 信号同步触发
    → _on_gsm_player_choice_required("setup_ready", {})
      → _pending_choice = {"type": "setup_ready", "data": {}}
      → _update_pending = true
      → _choice_prompt_needs_broadcast = true
  → 广播 game_starting
  → _broadcast_state_update()
    → 向双方发送 MSG_STATE_UPDATE {pending_choice: {type: "setup_ready"}}
    → _broadcast_pending_choice()
      → 向双方发送 MSG_CHOICE_PROMPT {choice_type: "setup_ready"}
```

双方客户端收到 `MSG_CHOICE_PROMPT("setup_ready")` → `_begin_setup_flow()` → `_show_setup_active_dialog(my_pi)`
→ `_pending_choice = "setup_active_0"` (玩家0) / `"setup_active_1"` (玩家1)
→ 双方都看到选择战斗宝可梦对话框 ✓

### 玩家1放置后发生什么

```
玩家1 确认选择 → _handle_dialog_choice
  → handled_choice = "setup_active_1", _pending_choice = ""
  → send_action(ACTION_SETUP_PLACE_ACTIVE, {instance_id})

服务器 handle_action(1, ACTION_SETUP_PLACE_ACTIVE):
  → _pending_choice = {}                    ← 清除！
  → _gsm.setup_place_active_pokemon(1, card)
    → _log_action() → action_logged 信号
    → _on_gsm_action_logged() → _update_pending = true
  → _broadcast_state_update()               ← 广播给双方！
    → payload.pending_choice = {}           ← 空的！
  → send_to_player(1, setup_bench)          ← 只发给玩家1

玩家0 客户端收到 MSG_STATE_UPDATE:
  → _apply_server_state(payload)
  → payload.has("pending_choice") = true
  → _sync_pending_choice({}, game_state)
    → choice_type = "" (空)
    → _battle_scene.set("_pending_choice", "")  ← 覆盖了 "setup_active_0"！

玩家0 点击对话框中的宝可梦:
  → _handle_dialog_choice
  → handled_choice = _pending_choice = ""   ← 已被清空！
  → _net_handle_dialog_choice("", idx, ...)
    → match "": 落入 _:` 分支
    → handled_choice.begins_with("setup_active_") = false
    → 什么都不做 ← 无反应！
```

### 根因

**`GameRoom.gd:174`** — 服务器在 `ACTION_SETUP_PLACE_ACTIVE` 中先清除 `_pending_choice = {}`，然后 `_gsm.setup_place_active_pokemon` 触发 `_update_pending = true`，导致 `_broadcast_state_update()` 以空 `pending_choice` 广播给双方。

**`NetBattleScene.gd:184-189`** — `_sync_pending_choice` 收到空 `choice_type` 时无条件清除客户端 `_pending_choice`，破坏了玩家0仍在显示的对话框状态。

### 关键代码位置

| 文件 | 行号 | 问题 |
|------|------|------|
| `scripts/server/GameRoom.gd` | 174 | `_pending_choice = {}` 过早清除 |
| `scripts/server/GameRoom.gd` | 177-178 | `_broadcast_state_update()` 广播空 pending_choice 给双方 |
| `scenes/network/NetBattleScene.gd` | 184-189 | `_sync_pending_choice` 无条件清除客户端状态 |

---

## Bug 2: Mulligan 阶段双方都能操作

### 完整消息时序

```
start_game()
  → _gsm.start_game()
    → 玩家0 无基础宝可梦 → _do_mulligan(0)
    → player_choice_required.emit("mulligan_extra_draw", {
        "beneficiary": 1,       ← 受益者是玩家1
        "mulligan_count": 1
      })
  → _broadcast_state_update()
    → payload.pending_choice = {type: "mulligan_extra_draw", data: {beneficiary: 1}}
  → _broadcast_pending_choice()
    → target_player = _resolve_choice_target() = 1
    → 向双方发送 MSG_CHOICE_PROMPT {choice_type: "mulligan_extra_draw", target_player: 1}
```

### MSG_CHOICE_PROMPT 过滤（正常工作）

```
玩家0 (非受益者): target_player=1 != me=0 → 过滤掉 ✓
玩家1 (受益者):   target_player=1 == me=1 → 显示对话框 ✓
```

### 问题所在

**问题A：服务器不验证发送者身份**

```gdscript
# GameRoom.gd:347-348
NetProtocol.CHOICE_MULLIGAN_EXTRA_DRAW:
    _gsm.resolve_mulligan_choice(player_index, ...)  # 不检查 player_index 是否是 beneficiary
```

如果玩家0（非受益者）发送 `CHOICE_MULLIGAN_EXTRA_DRAW`，服务器会直接处理，让玩家0给自己抽额外卡牌。

**问题B：非受益者客户端没有 UI 阻断**

```
玩家0 (非受益者) 在 Mulligan 期间:
  → _pending_choice = ""（无对话框）
  → 对话框 overlay 不可见
  → _can_accept_live_action() = true
  → _is_my_turn() 可能 = true（如果 current_player_index = 0）
  → 可以点击手牌、场地，发送操作到服务器
```

**问题C：`_sync_pending_choice` 不使用 `beneficiary` 过滤**

```
state_update 的 pending_choice:
  {type: "mulligan_extra_draw", data: {beneficiary: 1, mulligan_count: 1}}
  注意：没有 target_player 字段！

_sync_pending_choice 检查:
  target_player = data.get("target_player", -1) = -1  ← 不存在！
  -1 >= 0 = false → 不过滤
  → 落入 _:` 分支 → return（当前无害，但设计脆弱）
```

### 根因

| 问题 | 描述 | 位置 |
|------|------|------|
| 无发送者验证 | 服务器不检查 mulligan 响应是否来自 beneficiary | `GameRoom.gd:347-348` |
| 无 UI 阻断 | 非受益者客户端没有 "等待中" 状态，可以交互 | `NetBattleScenePatch.gd` 的 `_can_accept_live_action` / `_is_my_turn` |
| beneficiary 未传递 | state_update 的 pending_choice 没有 target_player，_sync_pending_choice 无法过滤 | `NetBattleScene.gd:193-195` |

---

## 修复方向（仅供参考，未实现）

### Bug 1 修复方向

**方案A**：`_sync_pending_choice` 收到空 choice_type 时，检查客户端当前 `_pending_choice` 是否是 setup 相关的（`setup_active_*` / `setup_bench_*`），如果是则不清除。

**方案B**：服务器不在 `ACTION_SETUP_PLACE_ACTIVE` 中清除 `_pending_choice`，改为在 `_broadcast_state_update` 中不包含 `_pending_choice`（或只在特定条件下包含）。

**方案C**：`_sync_pending_choice` 收到空 choice_type 时，检查对话框 overlay 是否可见，如果可见则不清除 `_pending_choice`。

### Bug 2 修复方向

**方案A**：服务器在 `handle_choice_response` 和 `handle_action` 中验证 mulligan 响应的发送者是否是 beneficiary。

**方案B**：客户端在 `_sync_pending_choice` 中使用 `beneficiary` 字段（而非 `target_player`）来过滤 mulligan_extra_draw，并为非受益者显示 "等待对手选择..." 提示。

**方案C**：在 `NetBattleScenePatch` 中增加 mulligan-in-progress 状态检查，阻断非受益者的 UI 交互。

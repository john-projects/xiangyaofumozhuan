# 游戏总流程（scenes/main/）

`main.tscn` 是**唯一主场景**（`project.godot` 的 `run/main_scene` 指向它）。

## 流程

```
主菜单 TitleScreen          ← 支持纯键盘：↑↓ / W S 选择，Enter / 空格 / E 确认（Esc 不做事）
   ├── 新的征程   → **直接开局**：队长取 GameRoot.default_leader（留空则用 DEFAULT_LEADER，
   │                 当前指向 resources/units/players/stats_player_well_rounded.tres），
   │                 初始武器取 default_weapon / DEFAULT_START_WEAPON（拳头）
   ├── 继续游戏   → 恒为置灰（没有存档系统），不进键盘焦点环
   ├── 经典模式   → 直接进 arena（老的竞技场玩法，自带选人/波次/商店）
   └── 退出游戏
直接开局 → 世界地图 WorldMap（起点：建邺城，可走动探索）
   ├── 走到 NPC 旁按 E 交谈 → 选目的地 → 传送到另一张图（双向）
   ├── 找「队友」NPC 招募队友（进"团队"名册，默认不限人数；最多 5 人"上阵"）
   │   └── Esc →「队伍管理」里切换上阵/下阵、把人移出团队（敌人数量跟着**上阵人数**变）
   ├── 进入战斗（右下按钮，或 Esc 操作菜单）→ 回合制战斗 Battle（scenes/battle）
   └── 返回主菜单（Esc 操作菜单）
战斗结束 → 结算 → 回到同一张地图的**原位置**（胜利：发金币、记录已通关；失败：可再挑战）
```

> **键盘约定**（主菜单 / 世界地图 / 三个浮层都一样）：`↑↓`+`Enter`/`空格` 走 Godot 内置的
> `ui_*` 与 GUI 焦点系统；`W S` + `E` 由各屏幕的 `_unhandled_input` 调 `Global` 里的
> 焦点工具补上（`can_focus` / `collect_focusable` / `step_focus` / `activate_focused` /
> `is_interact_event`）。屏幕一出现就必须 `grab_focus()` 一个按钮，否则方向键"没人可动"。

> **选人界面（SelectionPanel）已不在主流程里**：`start_new_game()` 末尾调的是
> `start_game_with_defaults()`，直接拿默认队长开局。想恢复"选人 → 选武器"：
> 把那行换回 `show_character_select()` —— 面板场景与脚本都还留着。

地图玩法（走动/相机/NPC/传送）细节见 **[../world/README.md](../world/README.md)**。

## 地图串联

```
建邺城 jianyecheng ⇄ 东海湾 donghaiwan ⇄ 傲来国 aolaiguo ⇄ 花果山 huaguoshan（终点）
```

双向传送由各图 NPC 的 `destinations` 互相指向实现（不是写死在代码里的链条）：

| 地图 | NPC → 目的地 |
|---|---|
| 建邺城 | 船夫 → 东海湾 |
| 东海湾 | 船夫 → 建邺城；向导 → 傲来国 |
| 傲来国 | 向导 → 东海湾；猎人 → 花果山 |
| 花果山 | 看山猴 → 傲来国 |

### 加一张新地图（比如已经躺在 `assets/map/` 里的狮驼岭）

1. 复制 `resources/maps/map_huaguoshan.tres` → 改名 `map_shituoling.tres`；
2. 改 `id` / `display_name` / `texture`，配好 `npcs`（`destinations` 里双向互指）；
3. 把新的 `.tres` 拖进 `main.tscn` 上 `Main` 节点的 **Maps** 数组；
4. （可选）想给这张图摆装饰/加碰撞，就在 `scenes/world/maps/` 下"新建继承场景"（继承 `world_map.tscn`），
   保存成 `world_shituoling.tscn`，再填进这个 `.tres` 的 `scene` 字段。详见 [../world/README.md](../world/README.md)。

## 场景结构

```
Main (Node)  [main.gd = GameRoot]
├── WorldRoot       (Node2D)      —— 世界类屏幕：WorldMap / Battle / Arena
├── UIRoot          (CanvasLayer) —— UI 类屏幕：TitleScreen（SelectionPanel 已不在流程里，但脚本还在）
└── TransitionLayer (CanvasLayer, layer=200)
    └── Fade        (ColorRect)   —— 黑幕淡入淡出（过渡期间挡输入）
```

> 注意：地图现在是 **Node2D 世界**（要相机跟随玩家），所以挂 `WorldRoot` 而不是 `UIRoot`。

## 数值规则（都在 `main.gd` 顶部可调）

| 参数 | 默认 | 说明 |
|---|---|---|
| 起点地图 | `maps[0]`（或 `start_map_id`） | 建邺城 |
| 敌人池 | 地图的 `enemy_pool`，留空则用 `GameRoot.enemy_pool` | 5 个敌人 `.tres` 挂在 `main.tscn` |
| 敌人数量 | **上阵人数 ±1**（随机，钳进 1~5） | 只看 `deployed`（上阵名单），团队里坐板凳的人不算；上限 = `MAX_ENEMY_COUNT` / Battle 的 5 个敌方站位 |
| 敌人强度 | `enemy_scale_per_map = 0.15` | 每图血量/伤害 +15%，用 `duplicate()` 生成副本，不污染 `.tres` |
| 通关奖励 | `coin_reward_per_map(40) × 难度` | 累加进 `Global.coins` |
| 初始金币 | `starting_coins = 500` | 新游戏时重置 |
| 玩家站位记忆 | `_map_positions` | 打完战斗回地图时回到原位置（`WorldMap.spawn_override`） |

## 扩展点

| 要做的功能 | 改哪里 |
|---|---|
| "必须先打赢才能去下一张图" | `travel_to()` 里判断 `cleared_maps.has(current_map_id)`，并让 NPC 面板显示未解锁 |
| 存档 / 读档 | 存 `current_map_id`、`party`、`Global.coins`、`cleared_maps`、`_map_positions` |
| 每张图不同 BGM | `MapData.bgm`（字段已留）在 `show_map()` 里播放 |
| 每张图不同敌人 | 在那张图的 `.tres` 里填 `enemy_pool` |
| 战后商店/升级 | `_on_battle_ended()` 里接 `shop_panel` / `upgrade_panel` |

## 已废弃

`scenes/main/map_screen.tscn` / `map_screen.gd`：**旧版"点击热点传送"的地图界面**，
已被 `scenes/world/world_map.tscn` 取代（玩家走动 + NPC 传送）。`GameRoot` 不再引用它们，可以直接删。

## 验证过的东西

headless 跑过完整的走图流程脚本（跑完已删）：

```
启动      UI=TitleScreen
新游戏 →  直接开局（默认队长）→ 建邺城  世界尺寸=(4096,2304) 缩放=2.0 NPC=2 玩家=(1843.2,1497.6)
靠近NPC   最近NPC=船夫 提示可见=true → 对话框可见=true 按钮数=1
传送到    东海湾 归一化=(0.3,0.59) from=jianyecheng   (落在指向建邺城的 NPC 旁边)
双向回程  建邺城 归一化=(0.62,0.54)                    (落在指向东海湾的 NPC 旁边)
逐图前进  建邺城→东海湾→傲来国→花果山（终点 NPC 仍指向傲来国）
进战斗    我方=1 敌人=2 → 胜利 → 回到花果山原位置 (0.5,0.5)，金币 500→660
```

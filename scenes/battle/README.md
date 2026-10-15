# 回合制战斗 + 技能系统（scenes/battle/）

梦幻西游式战斗：舞台（Node2D）+ UI（CanvasLayer）+ 状态机驱动的回合流程 + 数据驱动的技能。

## 文件

| 文件 | 作用 |
|---|---|
| `battle.tscn` / `battle.gd` | 战斗根：站位 Marker、回合调度、指令分发、技能执行（单体 `_perform_skill` / 群体 `_cast_aoe`）、胜负判定 |
| `battle_unit.tscn` / `battle_unit.gd` | 战斗单位：血量/蓝量、技能冷却、选中高亮、受击与施法表现 |
| `command_menu.tscn` / `command_menu.gd` | 指令菜单（攻击/法术/道具/防御/逃跑）+ **技能二级菜单** |
| `turn_order.tscn` / `turn_order.gd` | 出手顺序条（当前出手的加亮边框） |
| `../effects/projectile/skill_projectile.tscn` / `.gd` | **公共弹道**（所有元素共用）：静态贴图 + 外观包插槽 + 拖尾 + 命中爆炸 + 生命周期 |
| `../effects/fireball/fireball_appearance.tscn` / `.gd` | **火球外观包**：像素序列帧 + 五层飞行粒子（火球专属内容全在这，公共弹道里没有火） |
| `../effects/burst_effect.tscn` / `.gd` | 默认命中爆炸：闪光 / 冲击波 / 火星 / 浓烟（`play(tint, count)`，播完自毁） |
| `../effects/fireball/effect_fireball_1|2|3.tscn` | 飞行体用的像素火焰序列帧（三种配色） |
| `../effects/fireball/effect_fireball_hit.tscn` | **命中**用的像素火焰序列帧（63 帧 / 60fps，无脚本 → 走 `SkillProjectile.play_sequence_once()`） |

> 同目录的 `battle_backup.tscn` 是更早的手搭版本，没有被覆盖，可以随时对照或删掉。

## 操作方式（鼠标 / 键盘双通道，随时混用）

| 操作 | 鼠标 | 键盘 |
|---|---|---|
| 选指令 | 点右侧菜单 | 菜单一打开就**自动聚焦第一个可用指令**（禁用的"道具"会被跳过）；`↑↓←→` 循环选择 · `Enter`/`空格` 确认 |
| 法术二级菜单 | 点"法术" | `Enter` 打开；`ESC`（或点"返回指令"）回主菜单 |
| 选目标 | 点敌人 | `↑↓←→` 切换（首尾循环）· `Enter`/`空格` 确认 · `ESC`/右键 取消 |
| 看轮到谁 | 出手顺序条 | **行动者轮廓**：我方青色 / 敌方橙红（`BattleUnit.OUTLINE_ALLY_COLOR` / `OUTLINE_ENEMY_COLOR`） |
| 看当前目标 | 鼠标悬停会让光标跟过去 | **金色轮廓 + 头顶浮动箭头**（`OUTLINE_TARGET_COLOR`） |

实现要点（想改手感看这三处）：

- **指令菜单**用引擎内建焦点系统：`Button` 的 `focus_mode` 默认 `FOCUS_ALL`，方向键自动移动、
  `ui_accept`（Enter/空格）直接按下当前聚焦的按钮 —— 顺带白送手柄支持。
  `CommandMenu._wire_dpad()` 只补两件事：把"上下左右"都串成环（竖排列表默认按左右没反应），
  以及把 disabled / 不可见的按钮**剔除出导航链**（否则方向键会卡在一个按不下去的项上）。
- **选目标**用 `Battle._target_index` 这个光标 + `Battle._refresh_target_focus()`；
  `BattleUnit.set_focused()` 负责外观：`%Outline`（内嵌描边 shader，`show_behind_parent`）+
  `%TargetArrow`（Polygon2D，`_process` 里做正弦浮动，且只有光标所在的单位开 `_process`）。
- **轮廓只有一个"真相出口"**：`BattleUnit._refresh_outline()` 按优先级挑颜色 ——
  键盘光标（金色）> 行动者（`set_selected()`，我方青 / 敌方橙红）> 不显示。
  行动者由 `Battle._begin_turn()` 点亮、`_finish_turn()` / `_finish_battle()` 熄灭。
  描边 shader 内嵌在 `battle_unit.tscn` 里，材质设了 `resource_local_to_scene = true`（每个单位一份），
  所以"给某个单位改描边颜色"不会串到别人身上。
- **两套操作共享同一个"当前目标"**：鼠标悬停会同步键盘光标（`Battle._on_unit_hovered`），
  所以不会出现"鼠标指着一个、箭头指着另一个"的割裂感。

## 站位（双方上限 5 人 · 前三后二）

| 槽位 | 我方 | 敌方 | 含义 |
|---|---|---|---|
| `Front1` / `Front2` / `Front3` | (420, -220) / (420, 0) / (420, 220) | (-420, -220) / (-420, 0) / (-420, 220) | **前排 3 人**：靠中线、离对面近 |
| `Back1` / `Back2` | (560, -110) / (560, 110) | (-560, -110) / (-560, 110) | **后排 2 人**：错开半格插在前排的空隙上 |

- **双方上限都是 5 人**：`Battle._spawn_team()` 按 `min(队伍人数, Marker2D 个数)` 上场，超出会 `push_warning`（不会崩）；
- **上场顺序 = 队伍数组顺序 = 槽位顺序**（Front1 → Front2 → Front3 → Back1 → Back2），
  所以"队伍里前 3 个人自动站前排"；
- 想改站位/站法：直接在编辑器里挪 `battle.tscn` 的 `Stage/PlayerSlots`、`Stage/EnemySlots` 下的 Marker2D，
  **不用改代码**（`_spawn_team()` 只按子节点顺序取位置）；
- 节点命名用的是 `Front*` / `Back*` 而不是 `Slot1..5`，就是为了在检查器里一眼看出前后排；
- 地图关卡那边的敌人数量是"**上阵人数 ±1**"（随机），再钳进 `[1, 5]`：
  见 `scenes/main/main.gd::_make_enemy_team()`（用的是 `deployed` 上阵名单，团队里没上阵的人不算），
  5 这个上限就是这里的站位数量（`MAX_ENEMY_COUNT`）。

## 技能资源

```
resources/skills/skill_data.gd              SkillData 资源定义
resources/skills/skill_fireball.tres        火球术        单体 · 蓝 6 · CD 2 · 威力 2.2（静态贴图）
resources/skills/skill_fireball_sequence.tres 火球术·像素 单体 · 蓝 6 · CD 2 · 威力 2.2（序列帧 4x）
resources/skills/skill_fireball_aoe.tres    爆裂火球      全体 · 蓝 14 · CD 3 · 威力 1.5（序列帧 5.5x + 序列帧爆炸）
```

| 分组 | 字段 | 说明 |
|---|---|---|
| 基础 | `id` / `display_name` / `icon` / `description` | 菜单里显示的内容 |
| 数值 | `mana_cost` / `cooldown` / `power` / `crit_bonus` | 蓝耗 / 冷却回合 / 伤害倍率（× 施法者 damage）/ 额外暴击率 |
| | `target_mode` | `ENEMY_SINGLE` 选一个敌人 / `ENEMY_ALL` 全体（不用选目标）/ `SELF`·`ALLY_SINGLE` 未实现 |
| 视觉 | `projectile_texture` | **填了**用静态贴图（可 `tint` 染色、可自转） |
| | `appearance_scene` | **元素外观包**（推荐）：火球填 `../effects/fireball/fireball_appearance.tscn`。留空 = 弹体只有静态贴图 |
| | `sequence_frame_scene` | 由外观包读取：指定用哪套帧配色（默认 `effect_fireball_1`）。**别把它和 `appearance_scene` 填混** |
| | `projectile_scale` / `projectile_speed` | 基准缩放 / 速度（像素/秒，时长有 0.18~1.2s 上下限）；飞行时整体还会乘 `FLY_STRETCH` = 1.25 |
| | `frames_only` / `flight_particle_ratio` / `show_smoke_trail` | 由火球外观包读取：压低粒子密度、关掉挡视线的浓烟 |
| | `tint` | 染色 + 技能伤害飘字颜色 |
| | `hit_particles` / `hit_particle_texture` | 命中粒子数量 / 粒子贴图（留空用柔光） |
| | `hit_effect_scene` | **命中爆炸用哪个场景**；留空 = 默认 `burst_effect.tscn`，填了可用像素火焰序列 |
| | `burst_scale` | 命中爆炸的整体缩放（群体技能调大） |
| | `screen_shake` | 命中镜头抖动强度（0 = 不抖） |
| 音效 | `cast_sfx` / `hit_sfx` | 起手 / 命中 |

## 执行流程

```
我方回合 → CommandMenu「法术」→ 技能列表（显示蓝耗 / 冷却 / 蓝不够）
   → skill_selected → Battle._on_skill_selected()
   ├─ ENEMY_SINGLE：进入选目标（ESC/右键取消）→ 点敌人 → _perform_skill()
   └─ ENEMY_ALL   ：不用选目标，直接 → _perform_skill() → _cast_aoe()

_perform_skill()（公共起手）
   扣蓝 → 进冷却 → cast_sfx → 施法起手 play_cast()
   ├─ 单体：for 每个目标 → 生成一颗飞体 → 飞过去 → 命中结算 → burst() → 下一个目标
   └─ 群体：交给 _cast_aoe()

_cast_aoe()（爆裂火球走的路径）
   ① 只生成**一颗**飞体，目标是敌阵几何中心 _group_center()
   ② 抵达 → burst() 中心大爆炸（burst_scale 生效）+ hit_sfx + 镜头抖动（各只做一次）
   ③ 逐个结算全体：格挡判定 → 伤害（暴击 ×1.5）→ 飘字 → 每个敌人身上补一朵
	  0.55 倍小爆炸 → play_hit()（故意不 await，"同时闪红"）
	  目标之间只隔 aoe_step_delay = 0.06s，观感是同时被炸到
```

冷却按**回合**递减（`_next_round()` 对全体单位 `tick_cooldowns()`），所以冷却 3 = 放完隔两个回合能再用。

## 加技能 / 换素材

**加一个新技能**：复制一个 `.tres` → 改 `id` / `display_name` / 数值 / `target_mode` → 拖进 `battle.tscn` 上
`Battle` 节点的 **Default Skills** 数组（我方都默认会）；想只给某个角色就填进该角色的 `UnitStats.skills`。

**换素材（不用改代码）**：

| 想要的效果 | 拖哪里 |
|---|---|
| 火球换个外观（静态图） | `projectile_texture` |
| 火球换个外观（序列帧） | `sequence_frame_scene`（`effect_fireball_1/2/3.tscn`），并留空 `projectile_texture` |
| 火球大小 / 快慢 | `projectile_scale` / `projectile_speed` |
| 命中爆炸换成火焰序列 | `hit_effect_scene` = `effect_fireball_hit.tscn`（或别的序列帧场景） |
| 爆炸范围大小 | `burst_scale` |
| 技能图标 / 音效 | `icon` / `cast_sfx` / `hit_sfx` |

## 扩展点

| 想做的功能 | 改哪里 |
|---|---|
| 治疗 / 增益 | `BattleUnit` 加 `status: Dictionary` + `tick_status()`，在 `_on_skill_selected()` 里补 `SELF`/`ALLY_SINGLE` 分支 |
| 灼烧 / 中毒 DOT | 同上，命中后 `target.add_status(...)`；飘字可复用 `create_floating_text()` |
| 群体技能同时命中 | `_cast_aoe()` 里 ③ 的循环已经很快；要"完全同时"就把 ③ 的 `await aoe_step_delay` 去掉 |
| 敌人也会放技能 | `_enemy_act()` 里判断 `actor.can_use_skill(...)` 优先放技能 |
| 技能动画 | `BattleUnit.play_cast()` 现在是 Tween，换成 `AnimationPlayer.play("cast")` |
| 技能等级 | `SkillData` 加 `level`，或在 `BattleUnit.skill_damage()` 里乘系数 |

## 已验证

headless 实跑（测试脚本已删）：

```
技能表：火球术(单体/蓝6/威力2.2)  火球术·像素(单体/蓝6/威力2.2)  爆裂火球(全体/蓝14/威力1.5/爆缩放1.8/命中特效=effect_fireball_hit.tscn)

【群体】目标数=4 各自HP=[8.0,6.0,8.0,6.0] 单体预计伤害=4.5
		施放中 state=5（直接进 EXECUTE，不需要选目标）待选技能=(空)
		结算后 HP=[3.5,1.5,3.5,1.5] 掉血=["4.5","4.5","4.5","4.5"]
		施法者MP=6.0（20-14） 冷却=3 fx层残留=3（爆炸在播）→ 2 秒后 =0

【单体回归】Bunny 放 火球术·像素 → 掉血=["3.5","0.0","0.0","0.0"]（只有目标掉血）fx层残留=0
```

## 顺手修掉的一个报错

`skill_projectile.gd` 里关浓烟那行原本是 `smoke.amount = 0`，而 `GPUParticles2D.amount` 最小值是 1 →
播放序列帧技能时会一直刷红字（`Amount of particles cannot be smaller than 1.`，不崩但扰人，且 amount 会停在原值上）。
已改成只关 `emitting` + 隐藏节点。

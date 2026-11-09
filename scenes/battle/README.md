# 回合制战斗 + 技能系统（scenes/battle/）

梦幻西游式战斗：舞台（Node2D）+ UI（CanvasLayer）+ 状态机驱动的回合流程 + 数据驱动的技能。

## 文件

| 文件 | 作用 |
|---|---|
| `battle.tscn` / `battle.gd` | 战斗根：站位 Marker、回合调度、指令分发、技能执行（单体 `_perform_skill` / 群体 `_cast_aoe`）、胜负判定、**背景（地图截图 + 蒙层）** |
| `battle_unit.tscn` / `battle_unit.gd` | 战斗单位：血量/蓝量、技能冷却、选中高亮、受击与施法表现 |
| `command_menu.tscn` / `command_menu.gd` | 指令菜单（攻击/法术/道具/防御/逃跑）+ **技能二级菜单** |
| `turn_order.tscn` / `turn_order.gd` | 出手顺序条（当前出手的加亮边框 + 「本轮 / 下一轮」分隔） |
| `battle_stats_panel.tscn` / `.gd` | 右上角**伤害统计面板**（战斗内 + 地图上共用同一个场景；悬停某一行看伤害构成） |
| `../effects/projectile/skill_projectile.tscn` / `.gd` | **公共弹道**（所有元素共用）：静态贴图 + 外观包插槽 + 拖尾 + 命中爆炸 + 生命周期 |
| `../effects/burst_effect.tscn` / `.gd` | 默认命中爆炸：闪光 / 冲击波 / 火星 / 浓烟（`play(tint, count)`，播完自毁） |

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
- **出手顺序条是环形的**：当前出手者排最前，出过手的自动转到队尾等下一轮。为了避免"队尾那几个人
  到底是本轮还是下轮"的歧义，`Battle._turn_display()` 会算出"下一轮第一个出手的人"，
  `TurnOrder.update_turn()` 在那一格前面插一条竖线 + 小字「下轮」。回合刚开始（还没人出手）时
  整条都是本轮，不显示分隔。

## 站位（双方上限 5 人 · 前三后二）

**锚点约定：单位的本地坐标 `(0,0)` = 脚底**。`BattleUnit._refresh_visuals()` 用
`sprite.offset = (0, -贴图高/2)` 把立绘整体上移，所以节点摆在哪、脚就踩在哪；
名字 / 血条 / 蓝条 / 头顶箭头都按"头顶 = `-贴图高 × 缩放`"算，换任何尺寸的立绘都自动对齐。
`battle.tscn` 的 `Stage` 整体下移了 120px，用来抵消"锚点从身体中心变成脚底"带来的视觉位移。

给特效定位时用 `BattleUnit.body_center()`（脚往上抬半个身高），不要直接用 `global_position`：
弹道起点/落点、命中爆炸、飘字都改用它了。

## 背景（地图截图 + 蒙层）

进战斗前 `GameRoot.enter_battle()` 会让当前地图拍一张"只有地图"的截图
（`WorldMap.capture_map_photo()`：临时隐藏 NPC / 玩家 / 整个 UI 层，等 `frame_post_draw` 后抓 viewport，
抓完立刻恢复），再 `Battle.set_backdrop()` 塞进来（必须在 `add_child` 之前）。

`battle.tscn` 里的 `Backdrop`（`CanvasLayer`，**layer = -1**，画在所有单位和 UI 下面）：
`Photo` 是铺满屏幕的 `TextureRect`（`stretch_mode = KEEP_ASPECT_COVERED`），`Dim` 是压暗的 `ColorRect`
（默认 `Color(0.02, 0.02, 0.05, 0.74)`，想更暗/更亮就调它的 alpha）。没有截图（`headless`、直接 F6 跑战斗）时
整层隐藏，露出场景自带的绿底 `Background`。

截图会先缩到 `GameRoot.PHOTO_MAX_WIDTH = 720` 宽再上传（1680×960 → 720×411，约 1.2 MB）：
放大回全屏后天然柔化，背景不抢镜，也省显存。实测一次约 9 ms（抓图 5.4 + 缩放 2.9 + 上传 0.8），
只在进战斗时发生一次，且落在淡出的黑屏期间，战斗过程没有额外开销。
截图里**没有**玩家、队友跟随小人（`_companions`）和 NPC 节点（它们被临时隐藏），但地图原画本身画着的小人属于美术内容，去不掉。

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
```

| 分组 | 字段 | 说明 |
|---|---|---|
| 基础 | `id` / `display_name` / `icon` / `description` | 菜单里显示的内容 |
| 数值 | `mana_cost` / `cooldown` / `power` / `crit_bonus` | 蓝耗 / 冷却回合 / 伤害倍率（× 施法者 damage）/ 额外暴击率 |
| | `target_mode` | `ENEMY_SINGLE` 选一个敌人 / `ENEMY_ALL` 全体（不用选目标）/ `SELF`·`ALLY_SINGLE` 未实现 |
| 视觉 | `projectile_texture` | **填了**用静态贴图（可 `tint` 染色、可自转） |
| | `appearance_scene` | **元素外观包**（推荐）：填自己的外观包场景；留空 = 弹体只有静态贴图 |
| | `sequence_frame_scene` | 由外观包读取：指定用哪套帧配色。**别把它和 `appearance_scene` 填混** |
| | `projectile_scale` / `projectile_speed` | 基准缩放 / 速度（像素/秒，时长有 0.18~1.2s 上下限）；飞行时整体还会乘 `FLY_STRETCH` = 1.25 |
| | `frames_only` / `flight_particle_ratio` / `show_smoke_trail` | 由外观包读取：压低粒子密度、关掉挡视线的浓烟 |
| | `tint` | 染色 + 技能伤害飘字颜色 |
| | `hit_particles` / `hit_particle_texture` | 命中粒子数量 / 粒子贴图（留空用柔光） |
| | `hit_effect_scene` | **命中爆炸用哪个场景**；留空 = 默认 `burst_effect.tscn`，填了可用像素火焰序列 |
| | `hit_effect_on_ground` | true = 命中特效**贴地**播放（放在目标脚下，而不是身体中心）——地面法阵/天降落雷这类素材用 |
| | `instant_hit` | true = **无弹道**：单体技能不飞弹体，施法后招式直接落在目标身上（五雷正法：天降雷柱）；命中特效照常走 `hit_effect_scene`，群体路径不受影响 |
| | `hit_effect_per_target` | true = 群体技能给每个目标再补一朵小爆炸（默认）；放整屏大特效时关掉，避免叠 3~5 份 |
| | `target_effect_scene` | 每个目标**脚下单独**一份的特效（群星陨落：每个敌人各落一颗陨星）；填了就不再受 `hit_effect_per_target` 影响 |
| | `hit_effect_center` | true = 阵型中心也炸一次（默认）；false = 中心不炸，只在各目标脚下出特效 |
| | `screen_effect_scene` | **全屏氛围特效**，施法瞬间播一次（夜色压暗 / 流星雨 / 暴雨），根节点用 CanvasLayer 不受震屏影响 |
| | `burst_scale` | 命中爆炸的整体缩放（群体技能调大） |
| | `screen_shake` | 命中镜头抖动强度（0 = 不抖） |
| 音效 | `cast_sfx` / `hit_sfx` | 起手 / 命中 |

**视频素材转技能特效**（雷动九天就是这么做的）：mp4 → ffmpeg 抽 12~15fps 的帧 →
Pillow 裁掉水印 + 按亮度抠出 alpha + 拼 4×4 图集 → `scenes/effects/leidong_jiutian/`
里的 `AnimatedSprite2D` 在运行时把图集切成 `AtlasTexture` 逐帧播一次、播完自毁。
素材本身是"地面法阵 + 天降落雷"，所以 `hit_effect_on_ground = true` 且 `hit_effect_per_target = false`。

**群星陨落（零贴图"拼图法"）**：`scenes/effects/qunxing_yunluo/`
- `qunxing_screen.tscn`（`screen_effect_scene`）= CanvasLayer：`ColorRect` 全屏压暗 + 90 条代码画的流星线，2.4s 淡入淡出；
- `qunxing_impact.tscn`（`target_effect_scene`）= 每个目标脚下：0.22s 陨星坠落 + 0.42s 柔光爆闪/冲击波/碎星，
  发光用代码生成的 `GradientTexture2D` 径向渐变 + 加法混合（`draw_circle` 实心圆在暗背景上会糊成灰盘）；
- 配合 `hit_effect_center = false`：中心不放特效，只在每个被打的敌人脚下各落一颗。

## 执行流程

```
我方回合 → CommandMenu「法术」→ 技能列表（显示蓝耗 / 冷却 / 蓝不够）
   → skill_selected → Battle._on_skill_selected()
   ├─ ENEMY_SINGLE：进入选目标（ESC/右键取消）→ 点敌人 → _perform_skill()
   └─ ENEMY_ALL   ：不用选目标，直接 → _perform_skill() → _cast_aoe()

_perform_skill()（公共起手）
   扣蓝 → 进冷却 → cast_sfx → 施法起手 play_cast()
   ├─ 单体：飞体抵达（或直接命中）→ 开播命中特效 → 最后几帧结算和跳字
   └─ 群体：交给 _cast_aoe()

_cast_aoe()（群体技能走的路径）
   ① 只生成**一颗**飞体，目标是敌阵几何中心 _group_center()
   ② 抵达 → burst() 中心大爆炸（burst_scale 生效）+ hit_sfx + 镜头抖动（各只做一次）
   ③ 在命中动画最后几帧同帧结算所有目标 → 跳字和暴击特效各自播放到结束
```

冷却按**回合**递减（`_next_round()` 对全体单位 `tick_cooldowns()`），所以冷却 3 = 放完隔两个回合能再用。

**防御**：`take_damage()` 里 `defending` 时伤害 ×0.5（下限 1）；这个姿态只持续到**该单位自己的下一个回合开始**
（`Battle._begin_turn()` 调 `BattleUnit.begin_turn()` 取消），不是永久半伤。

**门派技能**：`SkillData` 里有一组「门派技能」字段（`max_targets` / `hits` / `fixed_damage` / `seal_chance` /
`silence_*` / `heal_power` / `hot_*` / `buff_*`），资源在 `resources/skills/sect_skills/`。
多目标技能（`max_targets > 1`）**走群体演出**：玩家点主目标后 `_expand_targets()` 补齐最近的 N-1 个敌人，
然后和 `ENEMY_ALL` 一样走 `_cast_aoe()` —— **只生成一颗弹体、只播一次命中特效**，
所有目标在同一帧结算。
> 之前 `max_targets` 走单体循环，每个敌人各播一遍特效，像连放 3 次技能（已修）。
`hits > 1` 在同一目标上连结算 N 次；`fixed_damage` 的技能伤害取 `flat_damage`（不吃攻击力）；
辅助技能（`SELF` / `ALLY_SINGLE`）走 `_perform_support()`：治疗、持续回血、增益状态。

**状态**：`BattleUnit.statuses` 是 `{stat, value, turns, per_turn, source, label}` 的数组，同种状态合并（数值相加、回合取长）。
`begin_turn()` 里结算：被 `seal` 封印 → 返回 true（`Battle._begin_turn()` 跳过这次行动）；
`hot` 按 `per_turn` 回血；其余状态回合 -1、到期移除（**`dot` 例外**，它在下文 `end_turn()` 里结算）。
`silence` 会让 `can_use_skill()` 返回 false。
数值加成参与战斗：`damage_pct` / `damage_spell`（百分比）、`spell_damage`（点数）、`crit_rate`（暴击率）、
`crit_damage_bonus`（暴击倍率，见 `BattleUnit.crit_multiplier()`）。

**持续伤害（dot）**：`BattleUnit.end_turn()` 在**每回合结束时**结算（`Battle._finish_turn()` 调），
掉完这一跳回合数才 -1，所以 `dot_turns = 3` 就是结结实实跳 3 次：

| 第几跳 | 伤害 | 配置 |
|---|---|---|
| 第一跳 | 施法者等级 × `dot_first_level` + 技能等级 × `dot_first_skill` + 施法者伤害 × `dot_first_damage` | 默认 1/1/0.25 = 等级 + 技能等级 + 伤害/4 |
| 之后每跳 | 目标**气血上限** × `dot_percent` | 药雾弥漫 = 10% |

- 走 `take_direct_damage()`：按气血上限百分比算的伤害**不吃攻防差/格挡/防御姿态**（减完防御就不是 10% 了）；
- 可能把人打死，`_die()` 照常发 `died`，`Battle._begin_turn()` 会先判胜负再进下一个人；
- 重复施放：回合数取更长、`first` 重新武装（所以每回合重放能一直吃"第一跳"）；
- 等级来源：玩家副本由 `GameRoot._make_player_team()` 写 meta `level`，敌人写地图难度，
  门派技能副本由 `_bake_sect_skill()` 写 meta `level`；没有 meta 的一律按 1 级算。

## 伤害统计（battle_stats_panel.tscn / .gd）

战斗里贴在右上角出手顺序条下面；地图上（`world_map.tscn` 的 `UI/BattleStats`）是**同一个场景**，
只是挪到「开始巡逻」按钮下方。面板本身**不记账**：数据全在 `Global`（`battle_stats_roster` /
`battle_stats_last` / `battle_stats_total`），`Battle` 把 `BattleUnit.damaged / healed` 信号转给
`Global.record_battle_*()`，两块面板监听 `Global.battle_stats_changed` 刷新自己。

- 顶部页签「总计 / 上场战斗」，左侧页签「伤害 / 治疗 / 承伤」，按当前页签降序排。
  每行是「名字 + 分段比例条 + 数值（占比）」：
  - **条形按来源拼接**：普攻骨白、持续伤害紫、持续回血青绿、其他灰；技能和承伤来源按名字从
    `SEG_PALETTE` 取色（同一个名字永远同一个颜色）。条长相对「全队最高值」，第一名正好占满；
  - 数值后面的括号是**占全队合计**的百分比（和表头「合计」同一分母），第一名的数值标金色。
- **鼠标悬停某一行**弹出明细，**拉平显示**：一行一个来源（没有大类/缩进），按数值从大到小排。
  伤害/治疗直接列到具体技能名；持续伤害、持续回血在名字后标注（如「药雾弥漫（持续伤害）」「回春诀（持续回血）」），
  免得和同一个技能的直伤重名；承伤按「谁打的」一行一个。右侧是数值和占比。
- 来源靠 `take_damage()` / `heal()` 的 `source_kind` + `source_label` 一路带到 `Global`：
  普攻传 `SOURCE_ATTACK`，技能传 `SOURCE_SKILL` + 技能名，dot/hot 由 `BattleUnit.end_turn()` / `begin_turn()`
  结算时带上，认不出的一律 `SOURCE_OTHER`。新增伤害来源只要传对 `Global.SOURCE_*`，明细里就会自动多一组。
- dot 的数值在 `SkillData` 的 `dot_turns` / `dot_percent` / `dot_first_*` 里（见上一节），
  掉血飘字用 `Battle.dot_color`（紫色）。

## 加技能 / 换素材

**加一个新技能**：复制一个 `.tres` → 改 `id` / `display_name` / 数值 / `target_mode` → 拖进 `battle.tscn` 上
`Battle` 节点的 **Default Skills** 数组（我方都默认会）；想只给某个角色就填进该角色的 `UnitStats.skills`。

**换素材（不用改代码）**：

| 想要的效果 | 拖哪里 |
|---|---|
| 投射物换个外观（静态图） | `projectile_texture` |
| 投射物换个外观（序列帧） | `sequence_frame_scene`，并留空 `projectile_texture` |
| 投射物大小 / 快慢 | `projectile_scale` / `projectile_speed` |
| 命中爆炸换成别的特效 | `hit_effect_scene` = 任意特效场景 |
| 爆炸范围大小 | `burst_scale` |
| 技能图标 / 音效 | `icon` / `cast_sfx` / `hit_sfx` |

## 扩展点

| 想做的功能 | 改哪里 |
|---|---|
| 治疗 / 增益 | `BattleUnit` 加 `status: Dictionary` + `tick_status()`，在 `_on_skill_selected()` 里补 `SELF`/`ALLY_SINGLE` 分支 |
| 灼烧 / 中毒 DOT | 同上，命中后 `target.add_status(...)`；飘字可复用 `create_floating_text()` |
| 敌人也会放技能 | `_enemy_act()` 里判断 `actor.can_use_skill(...)` 优先放技能 |
| 技能动画 | `BattleUnit.play_cast()` 现在是 Tween，换成 `AnimationPlayer.play("cast")` |
| 技能等级 | `SkillData` 加 `level`，或在 `BattleUnit.skill_damage()` 里乘系数 |

## 已验证

headless 实跑（测试脚本已删）：

```
技能表：由角色所属门派决定（见 resources/skills/sect_skills/，每派 3 个主动技能）

【群体】目标数=4 各自HP=[8.0,6.0,8.0,6.0] 单体预计伤害=4.5
		施放中 state=5（直接进 EXECUTE，不需要选目标）待选技能=(空)
		结算后 HP=[3.5,1.5,3.5,1.5] 掉血=["4.5","4.5","4.5","4.5"]
		施法者MP=6.0（20-14） 冷却=3 fx层残留=3（爆炸在播）→ 2 秒后 =0

【单体回归】Bunny 放 投射物术·像素 → 掉血=["3.5","0.0","0.0","0.0"]（只有目标掉血）fx层残留=0
```

## 顺手修掉的一个报错

`skill_projectile.gd` 里关浓烟那行原本是 `smoke.amount = 0`，而 `GPUParticles2D.amount` 最小值是 1 →
播放序列帧技能时会一直刷红字（`Amount of particles cannot be smaller than 1.`，不崩但扰人，且 amount 会停在原值上）。
已改成只关 `emitting` + 隐藏节点。

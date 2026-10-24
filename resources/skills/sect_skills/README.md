# 门派技能资源（sect_skills）

五个门派共 **15 个主动技能**，每个一份 `SkillData`（.tres）。被动技能不在这里 —— 它们只是属性加成，
数据在 `Global.SECT_SKILLS` 的 `passives` 里（`GameRoot._apply_sect_passives()` 按等级叠到战斗副本上）。

## 目录约定

```
resources/skills/sect_skills/
├── taixu/     太虚剑宗（物理/暴击）
├── piaomiao/  缥缈仙府（封系）
├── zixiao/    紫霄神道教（法系）
├── wanyao/    万药谷（治疗）
└── xingluo/   星罗教（物理）
```

文件名固定 `skill_<技能 id>.tres`，路径由 `Global.sect_skill_scene_path(skill_id)` 按这个约定推出来，
所以**改名或挪目录要同步改这里**。加载：`Global.sect_skill_resource(skill_id)`（带缓存）。

## 15 个技能

| 门派 | 文件 | 类型 | 蓝耗 | 冷却 | 目标 | 核心参数 |
|---|---|---|---|---|---|---|
| 太虚 | `skill_sanchi_qingfeng` 三尺清风 | 群体伤害 | 12 | 2 | 2 个（30 级 3 个） | power 1.15 |
| 太虚 | `skill_taixu_shenjian` 太虚神剑 | 单体连击 | 15 | 3 | 1 | power 0.95 × 3 次 |
| 太虚 | `skill_renjian_heyi` 人剑合一 | 自身增益 | 10 | 4 | 自己 | 暴击率 +10（每级 +2），3 回合 |
| 缥缈 | `skill_taixu_fengtian` 太虚封天 | 群体封印 | 20 | 4 | 全体敌人 | 封印 60% |
| 缥缈 | `skill_fengling_jue` 封灵诀 | 封法术 | 14 | 3 | 1 | 75%，2 回合 |
| 缥缈 | `skill_piaomiao_jianzhi` 缥缈剑指 | 固定伤害 | 12 | 2 | 2 个（30 级 3 个） | 固定 40 |
| 紫霄 | `skill_wulei_zhengfa` 五雷正法 | 单体法术 | 8 | 0 | 1 | power 2.4 |
| 紫霄 | `skill_leidong_jiutian` 雷动九天 | 群体法术 | 18 | 3 | 3 个（60 级 5 个） | power 1.3 |
| 紫霄 | `skill_zixiao_ningshen` 紫霄凝神 | 自身增益 | 10 | 4 | 自己 | 法伤 +10（每级 +1.5），3 回合 |
| 万药 | `skill_huichun_jue` 回春诀 | 治疗 + 持续回血 | 14 | 2 | 2 人（25/50/75 级 3/4/5） | 治疗 ×1.0 + 回血 3 回合 |
| 万药 | `skill_yaowu_miman` 药雾弥漫 | 固定伤害 | 12 | 2 | 2 个（30 级 3、60 级 4） | 固定 35 |
| 万药 | `skill_wanling_zhufu` 万灵祝福 | 全体增益 | 18 | 4 | 全体队友 | 伤害+法伤 +5（每级 +1），3 回合 |
| 星罗 | `skill_xingluo_mozhua` 星罗魔爪 | 单体连击 | 10 | 2 | 1 | power 1.05 × 2 次 |
| 星罗 | `skill_qunxing_yunluo` 群星陨落 | 群体伤害 | 16 | 3 | 3 个（30 级 4 个） | power 1.1 |
| 星罗 | `skill_xingluo_shaji` 星罗杀机 | 自身增益 | 10 | 4 | 自己 | 暴伤 +15（每级 +1），3 回合 |

数值是**首版草案**，改 `.tres` 即可（不用动代码）。
这 15 份是一次性脚本生成的（生成完脚本已删），之后就以 `.tres` 为准、在编辑器里改。

## SkillData 里「门派技能」字段

| 字段 | 含义 | 现在 |
|---|---|---|
| `sect_id` / `sect_skill_key` | 归属门派 / 对应 `Global.SECT_SKILLS` 的 id | ✅ 已填 |
| `max_targets` | 最多打几个目标（1=单体） | 数据就绪，战斗还没用 |
| `hits` | 对同一目标连续结算几次 | 数据就绪，战斗还没用 |
| `fixed_damage` / `flat_damage` | 固定伤害 | 数据就绪，战斗还没用 |
| `seal_chance` | 封印概率（0~1） | 数据就绪，战斗还没用 |
| `silence_chance` / `silence_turns` | 封法术概率 / 回合数 | 数据就绪，战斗还没用 |
| `heal_power` | 治疗量 = 施法者 healing × 它 | 数据就绪，战斗还没用 |
| `hot_turns` / `hot_power` | 持续回血回合 / 每回合系数 | 数据就绪，战斗还没用 |
| `buff_stat` / `buff_value` / `buff_per_level` / `buff_turns` / `buff_all_allies` | 状态（暴击/法伤/暴伤/伤害+法伤/防御/封印命中） | 数据就绪，战斗还没用 |

**等级相关的百分比和目标数不在 .tres 里**：目标数阈值（30/60/25/50/75 级）、每级加成、
当前技能等级都还在 `Global.SECT_SKILLS` 和 `GameRoot.sect_skill_level()`。战斗开始时按角色当前等级
把这些算好、写进**技能的副本**（见下面第 1 步），`.tres` 本身永远只存"1 级基线"。

## 已经接好的（本轮）

1. **发技能**：`GameRoot._make_player_team()` 里 `_attach_sect_skills()` 给战斗副本**赋新数组**
   （`copy.skills = 原数组 + 本门主动技能`），并按角色当前等级把目标数"烤"进**技能副本**
   （`SkillData.duplicate()`）；原 `.tres` 和 `UnitStats.skills` 都不会被污染。
2. **指令菜单**：门派技能自动出现在「法术」页（名字 + 蓝耗 + 冷却），数据来自 `BattleUnit.available_skills`。
3. **多目标**：`SkillData.max_targets > 1` 时，玩家点一个主目标，`Battle._expand_targets()` 自动补齐
   离主目标最近的 N-1 个敌人（三尺清风 2 个、雷动九天 3 个…）。
4. **连击**：`SkillData.hits > 1` 时同一个飞体命中后连结算 N 次（太虚神剑 3 连击、星罗魔爪 2 连击）。
5. **固定伤害**：`fixed_damage` 的技能伤害 = `flat_damage`，不吃攻击力（`BattleUnit.skill_damage()`）。
6. **过滤**：`Battle.is_skill_playable()` 决定菜单里放哪些技能；现在 15 个全部可执行。
7. **状态系统**（`BattleUnit.statuses`）：`{stat, value, turns, per_turn}`，同种状态自动合并（数值相加、
   回合取长）。`begin_turn()` 里结算：被封印 → 返回 true 跳过行动并消耗；`hot` 按 `per_turn` 回血；
   其余状态回合 -1、到期移除。
8. **增益接入战斗数值**：`damage_pct` / `damage_spell` 按百分比放大伤害，`spell_damage` 加点数，
   `crit_rate` 加暴击率，`crit_damage_bonus` 改暴击倍率（`BattleUnit.crit_multiplier()`）。
9. **辅助技能**：`Battle._perform_support()` + `_apply_support_to()` —— 治疗（`healing × heal_power`）、
   持续回血（`healing × hot_power` 每回合）、增益状态；`SELF` 打自己，`ALLY_SINGLE` 选队友，
   `buff_all_allies` 给全体队友，`max_targets > 1` 自动补最近的队友。
10. **封印 / 封法术**：`_apply_skill_statuses()` 按 `seal_chance` / `silence_chance` 判定，
	封印 = 跳过下回合（头顶飘「封印」），封法术 = `can_use_skill()` 直接 false（菜单置灰）。

## 还没做的

1. **状态图标**：现在只有头顶飘字，血条旁边还没有 buff/debuff 小图标。
2. **群体连击**：`_cast_aoe()` 只结算一次；现有技能没有"群体 + 连击"，需要时补循环。
3. **敌人 AI 用技能**：敌方目前只会普攻，`_enemy_act()` 还没读门派技能。
4. **数值平衡**：治疗量/封印概率/盾值这些都还是首版草案。

## 素材待补（在编辑器里拖字段即可）

每个 `.tres` 现在只有数值和 `tint`，以下字段全空，留了也不会报错（会退化成无色/无声/默认爆裂）：

- `icon` —— 技能按钮图标
- `projectile_texture` / `appearance_scene` / `sequence_frame_scene` —— 飞行体（可复用
  `scenes/effects/` 里现成的特效场景 那套，或按门派做新的外观包）
- `hit_effect_scene` —— 命中特效
- `cast_sfx` / `hit_sfx` —— 施法/命中音效
- `projectile_scale` / `projectile_speed` / `hit_particles` / `screen_shake` / `burst_scale` —— 手感微调

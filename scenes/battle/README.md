# 回合制战斗 + 技能系统（scenes/battle/）

梦幻西游式战斗：舞台（Node2D）+ UI（CanvasLayer）+ 状态机驱动的回合流程 + 数据驱动的技能。

## 文件

| 文件 | 作用 |
|---|---|
| `battle.tscn` / `battle.gd` | 战斗根：站位 Marker、回合调度、指令分发、技能执行、胜负判定 |
| `battle_unit.tscn` / `battle_unit.gd` | 战斗单位：血量/蓝量、技能冷却、选中高亮、受击与施法表现 |
| `command_menu.tscn` / `command_menu.gd` | 指令菜单（攻击/法术/道具/防御/逃跑）+ **技能二级菜单** |
| `turn_order.tscn` / `turn_order.gd` | 出手顺序条（当前出手的加亮边框） |
| `skill_projectile.tscn` / `skill_projectile.gd` | 技能飞行体 + 命中爆炸（贴图/粒子/拖尾全部数据驱动） |

> 同目录的 `battle_backup.tscn` 是之前的手搭版本，没有被覆盖，可以随时对照或删掉。

## 技能系统（火球术为例）

```
resources/skills/skill_data.gd        SkillData 资源定义
resources/skills/skill_fireball.tres  火球术：数值 + 素材引用都在这
```

| 分组 | 字段 | 说明 |
|---|---|---|
| 基础 | `id` / `display_name` / `icon` / `description` | 菜单里显示的内容 |
| 数值 | `mana_cost` | 蓝耗（火球 6） |
| | `cooldown` | 冷却回合数（火球 2；每回合开始递减） |
| | `power` | 伤害倍率：`伤害 = power × 施法者.damage`（火球 2.2） |
| | `crit_bonus` | 额外暴击率（火球 +10%，基础 10%） |
| | `target_mode` | `ENEMY_SINGLE` 已实现 / `ENEMY_ALL` 已实现 / `SELF`·`ALLY_SINGLE` 留了接口 |
| 视觉 | `projectile_texture` / `projectile_scale` / `projectile_speed` | 飞行体 |
| | `tint` | 整体染色 + 伤害飘字颜色（火球橙色） |
| | `hit_particles` / `hit_particle_texture` | 命中粒子（留空则用飞行体贴图，再没有就是白方块） |
| | `screen_shake` | 命中镜头抖动强度（0 = 不抖） |
| 音效 | `cast_sfx` / `hit_sfx` | 起手 / 命中 |

### 加一个新技能

1. 复制 `skill_fireball.tres` → 改名，改 `id` / `display_name` / 数值 / 目标模式；
2. 拖进 `battle.tscn` 上 `Battle` 节点的 **Default Skills** 数组（我方默认都会）；
   想只给某个角色，就填进那个角色的 `UnitStats.skills`（优先于 Default Skills）。

### 换素材（不用改代码）

| 想要的效果 | 拖哪里 |
|---|---|
| 换个火球 | `projectile_texture`（现在借 `assets/sprites/Projectiles/Projectile_1.png`，96×96） |
| 换技能图标 | `icon`（现在借 `assets/sprites/Upgrades/3.png`，250×250） |
| 更好看的爆炸 | `hit_particle_texture` 放一张 32×32 白色圆点 + 调 `hit_particles` 数量和 `tint` |
| 音效 | `cast_sfx`（现借 ShotgunFire.wav）/ `hit_sfx`（现借 EnemyHit.wav） |

## 执行流程

```
我方回合 → CommandMenu「法术」→ 技能列表（显示蓝耗 / 冷却 / 蓝不够）
	  → skill_selected → Battle._on_skill_selected()
	  → 单体：进入选目标（ESC/右键取消）→ 点敌人
	  → _perform_skill()：
		  扣蓝 → 进冷却 → cast_sfx → 施法起手（play_cast）
		  → SkillProjectile 飞过去（时长 = 距离 / projectile_speed）
		  → 命中：格挡判定 → 伤害（暴击再 ×1.5）→ 橙色飘字 → 受击表现
		  → 爆炸粒子 + hit_sfx + 镜头抖动 → 下一个单位
```

冷却按**回合**递减（`_next_round()` 对全体单位 `tick_cooldowns()`），所以冷却 2 = 隔一回合能再用。

## 扩展点

| 想做的功能 | 改哪里 |
|---|---|
| 群体技能 | `target_mode = ENEMY_ALL` 已经能跑（依次播飞行+爆炸）；想同时命中就把 `_perform_skill()` 的循环拆成"先飞一次 → 统一结算" |
| 治疗 / 增益 | `BattleUnit` 加 `status: Dictionary` + `tick_status()`，在 `_perform_skill()` 里按 `target_mode` 分支 |
| 灼烧 / 中毒 DOT | 同上，命中后 `target.add_status(...)` |
| 技能动画 | `BattleUnit.play_cast()` 现在是 Tween，换成 `AnimationPlayer.play("cast")` |
| 敌人也会放技能 | `_enemy_act()` 里判断 `actor.can_use_skill(...)` 优先放技能 |
| 技能等级 | `SkillData` 加 `level`，或在 `BattleUnit.skill_damage()` 里乘系数 |
| 序列帧爆炸 | `skill_projectile.gd::burst()` 里把 `GPUParticles2D` 换成 `AnimatedSprite2D` 播一次 |

## 已验证

headless 实跑（测试脚本已删）：

```
施法者=Crazy MP=20.0/20.0 可用技能=1
技能=火球术 蓝耗=6.0 冷却=2 威力=2.2 贴图=Projectile_1.png
目标=Chaser Mid HP=8.0 预计伤害≈6.6
选目标阶段 state=4 可选目标=4 待放技能=fireball
结算后 目标HP=1.4（原 8.0） 施法者MP=14.0 冷却剩余=2 fx层残留=0
```

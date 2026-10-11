## ═══════════════════════════════════════════════════════════════════════════
## SkillStats —— 技能数值（⚠ 遗留文件：当前工程里没有任何地方引用它）
## ═══════════════════════════════════════════════════════════════════════════
## 现状：
##   字段和 weapon_stats.gd 一字不差，只是类名不同。全工程只有 ItemSkill.stats
##   声明了它的类型，而 ItemSkill 自己也没被任何 .tres / .tscn 引用 —— 整条链都是悬空的。
##   现役的**回合制**技能数值在 resources/skills/skill_data.gd（SkillData），
##   由 UnitStats.skills 引用、Battle._perform_skill() 读取。
##
## 结论：改下面的默认值不会有任何游戏内效果。
## 若将来复活，各字段的详细含义可直接参考 weapon_stats.gd 里的逐条注释（数值语义完全一致）。
extends Resource
class_name SkillStats

## ── 伤害与命中 ──────────────────────────────────────────────────────────
@export var damage := 1.0                            # 基础伤害（点）。语义同 WeaponStats.damage
@export_range(0.0, 1.0) var accuracy := 0.9          # 命中精度 0~1，1 = 完全不抖。单位是**弧度**：散布 = randf_range(-1+accuracy, 1-accuracy)
@export_range(0.5, 3.0) var cooldown := 1.0          # 冷却（秒），编辑器限制 0.5~3.0
@export_range(0.0, 1.0) var crit_chance := 0.05      # 暴击概率 0~1（0.05 = 5%）
@export var crit_damage := 1.5                       # 暴击倍率（1.5 = 150%）
## ── 远程弹道 ────────────────────────────────────────────────────────────
@export var projectile_scene: PackedScene            # 投射物场景（根节点应为 Projectile）
@export var projectile_speed := 1600.0               # 投射物速度（像素/秒）

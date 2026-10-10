extends Resource
class_name SkillData

## 技能数据（resources/skills/*.tres）
##
## 数值和视觉都放这里：换素材 = 把图/音效拖进字段，不用改代码。
## 战斗里的执行流程在 Battle._perform_skill()，单位侧的蓝量/冷却在 BattleUnit。

enum TargetMode {
	ENEMY_SINGLE,   # 选一个敌人（火球现在用这个）
	ENEMY_ALL,      # 全体敌人
	SELF,           # 自己（增益，暂未实现效果）
	ALLY_SINGLE,    # 选一个队友（治疗/增益，暂未实现效果）
}

@export var id: String = ""
@export var display_name: String = "技能"
@export var icon: Texture2D
@export_multiline var description: String = ""

@export_group("数值")
@export var mana_cost := 6.0            # 蓝耗
@export var cooldown := 2               # 冷却（回合数）
@export var power := 2.2                # 伤害倍率：最终伤害 = power × 施法者.damage
@export var crit_bonus := 0.10          # 额外暴击率
@export var target_mode := TargetMode.ENEMY_SINGLE

@export_group("视觉")
@export var projectile_texture: Texture2D   # 飞行体贴图（留空 = 一个橙色圆点）
@export var projectile_scale := 1.0
@export var projectile_speed := 900.0       # 像素/秒，飞行时长 = 距离 / 速度（有上下限）
@export var tint := Color(1.0, 0.55, 0.2)    # 整体染色（火球偏橙）
@export var hit_particles := 24             # 命中粒子数量
@export var hit_particle_texture: Texture2D # 粒子贴图（留空 = 白色小方块）
@export var screen_shake := 7.0             # 命中时的镜头抖动强度（0 = 不抖）

@export_group("音效")
@export var cast_sfx: AudioStream
@export var hit_sfx: AudioStream

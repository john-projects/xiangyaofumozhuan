## SkillData —— 技能数据（resources/skills/*.tres）
##
## 纯数据 Resource（无逻辑）：数值 + 视觉/音效都放这里，换素材 = 拖字段，不用改代码。
## 持有者：UnitStats.skills（单位没配就退化成 Battle.default_skills）；执行者：Battle._perform_skill()
## 负责扣蓝、置冷却、算伤害、放特效，BattleUnit 管"本场还剩几回合冷却、蓝够不够"。
## 数据流：*.tres → UnitStats.skills 或 Battle.default_skills → 生成 BattleUnit 时填进 unit.skills →
## 玩家/AI 选中 → Battle._perform_skill(caster, target, skill) → 读数值结算 + 读视觉/音效字段播演出。
## ⚠ TargetMode 枚举整数值会存进 .tres，调整成员顺序等于改动所有已有资源的数据。
extends Resource
class_name SkillData

## 技能的目标选择模式。整数值会存进 .tres，**调整成员顺序等于改动所有已有资源的数据**（和 SoundManager.Sound 同理）。
## ENEMY_SINGLE / ENEMY_ALL 已跑通（单体选目标 / 全体不用选，各炸一次再结算伤害）；
## SELF / ALLY_SINGLE 仍是占位，等 BattleUnit 有 status（增益/持续状态）系统后再做治疗与增益。
enum TargetMode {
	ENEMY_SINGLE,   # 选一个敌人（大部分单体技能的默认值）
	ENEMY_ALL,      # 全体敌人
	SELF,           # 自己（增益，暂未实现效果）
	ALLY_SINGLE,    # 选一个队友（治疗/增益，暂未实现效果）
}

## 技能唯一 id。当前代码靠**资源引用**而不是 id 找技能（UnitStats.skills 直接持有 Resource），
## 所以它主要用于存档、调试和以后做"技能图鉴"时的稳定键。
@export var id: String = ""
## 战斗 UI 上显示的名字。默认 "技能" 是占位值 —— 忘了改的话界面上会出现一排都叫"技能"的按钮。
@export var display_name: String = "技能"
## 技能图标。留空时 UI 会退化成无图标的按钮（不报错）。
@export var icon: Texture2D
## 技能说明。@export_multiline 是为了让编辑器里出现多行文本框（否则单行框敲不了换行）。
@export_multiline var description: String = ""

@export_group("数值")
## 蓝耗（单位：点，float 因为以后可能做"半蓝""百分比减免"）。默认 6.0：配合 UnitStats.mana 默认 20 ≈ 一场放 3 次。
@export var mana_cost := 6.0
## 冷却（单位：**回合数**，int）。默认 0 = 每回合都能放；由 BattleUnit 按回合扣减（想"放完等 2 回合"就填 2）。
@export var cooldown := 0
## 伤害倍率（无量纲）：最终伤害 = power × 施法者.damage。默认 2.2 = 明显比平砍强，值得花蓝。
@export var power := 2.2
## 额外暴击率，**0~1 的小数**（不是百分数！）：0.10 = +10%，叠在单位自身暴击率上；填 1.0 就是必定暴击。
@export var crit_bonus := 0.10
## 目标模式，决定选谁打。默认 ENEMY_SINGLE：最常用、也是目前唯一完整实现的模式。
@export var target_mode := TargetMode.ENEMY_SINGLE

@export_group("门派技能")
## 归属门派（Global.SECTS 的键）；空 = 通用技能。
@export var sect_id: String = ""
## 对应 Global.SECT_SKILLS 里的技能 id：等级相关参数（目标数阈值、每级加成）都去那张表查。
@export var sect_skill_key: String = ""
## 最多打几个目标（1 = 单体；>1 = 群体多目标，战斗里要按数量选目标）。ENEMY_ALL 时忽略。
@export var max_targets := 1
## 对同一目标连续结算几次（太虚神剑 = 3 连击）。
@export var hits := 1
## 连击每一击的**单独倍率**（长度 = hits 时生效，空 = 每一击都用 power）。
## 例：太虚神剑 3 击 → [0.4, 0.6, 0.8]（越打越重，总 1.8）。
@export var hit_power: Array[float] = []
## true = 固定伤害：伤害 = flat_damage（不乘攻击力/法伤），缥缈剑指 / 药雾弥漫用。
@export var fixed_damage := false
## 1 级固定伤害基数。
@export var flat_damage := 0.0
## 固定伤害每级成长（战斗前按技能等级烤进副本：flat_damage + flat_per_level × (等级-1)）。
@export var flat_per_level := 0.0

## 伤害类型：物理走「攻击 vs 防御」，法术走「法伤 vs 法防」。
enum DamageType { PHYSICAL, MAGIC }
@export var damage_type := DamageType.PHYSICAL
## 封印概率（0~1）：命中时按它给目标上"封印"（跳过一次行动）。
@export_range(0.0, 1.0) var seal_chance := 0.0
## 封法术概率（0~1）+ 封住几回合（缥缈仙府「封灵诀」）。
@export_range(0.0, 1.0) var silence_chance := 0.0
@export var silence_turns := 0
## 治疗：>0 表示治疗技，回复量 = 施法者 healing × heal_power（万药谷「回春诀」）。
@export var heal_power := 0.0
## 持续回血：回合数 + 每回合回复（healing × hot_power）。
@export var hot_turns := 0
@export var hot_power := 0.0
## 施加状态（buff）：stat 见 BattleUnit 的 BUFF_STATS（crit_rate / spell_damage /
## crit_damage_bonus / damage_spell / defense / seal_hit），buff_per_level 按技能等级叠。
@export var buff_stat: String = ""
@export var buff_value := 0.0
@export var buff_per_level := 0.0
@export var buff_turns := 0
## true = 作用全体队友（万灵祝福）；false = 只作用于自己/单个目标。
@export var buff_all_allies := false

@export_group("视觉")
## 飞行体贴图（由公共弹道贴到 Sprite2D 上）。留空 = 画面完全交给外观包；两个都留空也能飞，只是看不见弹体。
@export var projectile_texture: Texture2D

## 元素外观包：装着"这个元素长什么样"的 Node2D 场景（序列帧、粒子层、配色…）。留空 = 只有静态贴图。
## 契约（鸭子类型，都可不实现）：setup_effect(projectile, skill) 由弹道 setup() 调；stop_flight() 由命中时调。
## 每个元素写一个外观包场景（实现 setup_effect / stop_flight 即可），弹道一行都不用改。
@export var appearance_scene: PackedScene

## 飞行体缩放（乘在贴图原始尺寸上）。默认 1.0 = 原始大小。
## ⚠ 弹道的飞行 tween 会把整个 %Visual 再乘 FLY_STRETCH(1.25) 做"鼓一下"，所以这里填的是基准尺寸。
@export var projectile_scale := 1.0
## 飞行速度，单位：**像素/秒**。飞行时长 = 距离 / 速度，但弹道里被 clampf(..., 0.18, 1.2) 钳过，保证战斗节奏。
@export var projectile_speed := 900.0
## 整体染色（乘算到 sprite 的 modulate 上）。每个技能按自己的系别填（火橙 / 冰蓝 / 青碧…）。
@export var tint := Color(1.0, 0.55, 0.2)
## 命中时迸发的粒子数量（0 = 不放粒子，但特效节点仍会创建）。默认 24 是"看得出炸了一下"又不糊屏的量。
@export var hit_particles := 24
## 粒子贴图。留空 = 白色小方块兜底。
@export var hit_particle_texture: Texture2D
## 命中时的镜头抖动强度（像素级位移幅度）。默认 7.0 = 明显但不晕；填 0.0 = 不抖（适合轻击类技能）。
@export var screen_shake := 7.0

## 命中爆发的特效场景。留空 = 用默认 scenes/effects/burst_effect.tscn（程序化的闪光/冲击波/火星/浓烟四层爆炸）。
## 填了就用它（纯 AnimatedSprite2D 的序列帧场景，由 play_sequence_once() 播一次并自毁）。
@export var hit_effect_scene: PackedScene

## true = 命中特效**贴地**播放（节点放在目标脚下的地面线），而不是放在身体中心。
## 适合"地面法阵 / 天降落雷"这类素材（雷动九天）；普通爆炸保持 false。
@export var hit_effect_on_ground := false

## true = **无弹道**：施法后不飞弹体，招式直接落在目标身上结算（只对单体路径生效，群体路径不受影响）。
## 适合"天降落雷 / 从天而降的斩击"这类不合适横向飞的招式（五雷正法）；命中特效照常走 hit_effect_scene。
@export var instant_hit := false

## true = **每一段连击各播一次命中特效**（太虚神剑这种"一击一段动画"的技能）。
## 打开后：单体的 hits 循环里每打一下就在目标脚下 new 一个 hit_effect_scene，
## 并调它的 play_segment(hit)；最后飞行体的 burst 不再重复放特效。
@export var hit_effect_per_hit := false
## 连击之间的间隔（秒）。hits > 1 时用；默认 0.12 只够数字错开，
## 要让每击看到完整动画就调大（太虚神剑三段动画 ≈ 0.9s/段）。
@export var hit_interval := 0.12

## true = 群体技能给**每个目标**再补一朵小爆炸（默认）。
## 放了整屏大特效（比如雷动九天 1 秒的雷柱）时关掉，否则 3~5 份特效会叠成一团。
@export var hit_effect_per_target := true

## 每个目标脚下**单独**放的特效场景（群星陨落用：每个被打的敌人各落一颗陨星）。
## 留空 = 沿用 hit_effect_scene 的小爆点。这个字段不受 hit_effect_per_target 影响。
@export var target_effect_scene: PackedScene

## true = 群体技能在阵型中心再炸一次（默认）；false = 中心不炸，只在每个目标脚下出特效。
@export var hit_effect_center := true

## 全屏氛围特效（施法瞬间播一次）：夜色压暗 / 流星雨 / 暴雨之类。
## 场景根节点建议用 CanvasLayer，这样不受相机和震屏影响。
@export var screen_effect_scene: PackedScene

## 命中爆发的整体缩放（1.0 = 原始大小）。群体技能调大，让爆炸能盖住整个敌阵。
@export var burst_scale := 1.0

@export_group("视觉 · 序列帧外观")
## 飞行体的序列帧场景（只在 projectile_texture 为空时生效）。留空 = 由外观包自己决定。
## 这组字段由"序列帧类外观包"读取，别的外观包是否生效由它自己决定。
@export var sequence_frame_scene: PackedScene

## true = 走"只有序列帧"的干净外观：按 flight_particle_ratio 压低飞行粒子强度。
## 为什么需要：序列帧实际内容只有 43×21 px（画布 100×100 里 97% 是留白），而单个粒子就有 50~130 px，全量会盖住素材。
@export var frames_only := false

## frames_only 模式下保留多少飞行粒子（相对默认数量的倍数，0.0~1.0）。
## ⚠ 填 0 会连火核一起关掉；建议 0.08 ~ 0.25 —— 太小看不出火心，太大就盖住素材了。
@export_range(0.0, 1.0) var flight_particle_ratio := 0.15

## frames_only 模式下是否保留浓烟尾迹。默认关：浓烟用普通混合的深色贴图，几个粒子叠起来就是一条黑带，很挡视线。
@export var show_smoke_trail := false

@export_group("音效")
## 施法瞬间的音效（出手时播）。留空 = 这段没声音，不会报错也不会用默认音顶替。
@export var cast_sfx: AudioStream
## 命中瞬间的音效。留空 = 没声音。
## ⚠ 技能命中音走这里（Battle 显式播），和 HitboxComponent 自动播的 SoundManager ENEMY_HIT 是两套来源，都配会有两层音。
@export var hit_sfx: AudioStream

extends Resource
class_name SkillData

## 技能数据（resources/skills/*.tres）
##
## 数值和视觉都放这里：换素材 = 把图/音效拖进字段，不用改代码。
## 战斗里的执行流程在 Battle._perform_skill()，单位侧的蓝量/冷却在 BattleUnit。
##
## ── 在系统里的位置 ──
##   纯数据 Resource（无逻辑），一个技能一个 resources/skills/*.tres。
##   持有者：UnitStats.skills（这个单位会哪些技能）。如果单位没配 skills，
##   战斗里会退化成 Battle.default_skills（方便先跑通再逐个配）。
##   执行者：Battle._perform_skill() 负责扣蓝、置冷却、算伤害、放特效；
##   BattleUnit 负责"本场还剩几个回合冷却、蓝够不够"这类运行时状态。
##   本文件只管"技能长什么样、要多少蓝、打谁"。
##
## ── 数据流向 ──
##   resources/skills/*.tres（本 Resource）
##     → UnitStats.skills 或 Battle.default_skills
##       → Battle 生成 BattleUnit 时填进 unit.skills
##         → 玩家/battle AI 选中技能 → Battle._perform_skill(caster, target, skill)
##           → 读本文件的数值扣蓝/算伤害，读下面的视觉/音效字段播演出
##
## ── 数值与视觉都放这里的原因 ──
##   换素材不需要改代码：贴图、缩放、速度、染色、粒子数量、音效全是 Resource 字段，
##   策划在编辑器里拖一下就能换一整套技能外观。

## 技能的目标选择模式，决定"这个技能需要对谁、怎么选"。
## 枚举的整数值会存进 .tres，所以**调整成员顺序等于改动所有已有资源的数据**（和 SoundManager.Sound 同理）。
## 现状（2026-10）：
##   · ENEMY_SINGLE → 已跑通：进入选目标 → 一颗火球飞过去炸一次（Battle._perform_skill()）；
##   · ENEMY_ALL    → 已跑通：不用选目标，一颗火球飞到敌阵中心炸开，
##                    再逐个结算全体敌人的伤害（Battle._cast_aoe()）；
##   · SELF / ALLY_SINGLE → 仍是占位：等 BattleUnit 有 status（增益/持续状态）系统后再做治疗与增益。
enum TargetMode {
	ENEMY_SINGLE,   # 选一个敌人（火球现在用这个）
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
## 技能说明。用 @export_multiline 是为了让编辑器里出现多行文本框（否则单行输入框里敲不了换行）。
@export_multiline var description: String = ""

# ────────────────────────────── 数值（战斗结算用） ──────────────────────────────
@export_group("数值")
## 蓝耗（单位：点，float 因为以后可能做"半蓝""百分比减免"）。默认 6.0：
## 配合 UnitStats.mana 默认 20，正好是"一场能放 3 次"的节奏；不够蓝时 Battle 不给放。
@export var mana_cost := 6.0            # 蓝耗
## 冷却（单位：**回合数**，int）。默认 2 = 放完要等 2 个回合才能再放。
## 它由 BattleUnit 按回合扣减；填 0 表示每回合都能放。
@export var cooldown := 0               # 冷却（回合数）
## 伤害倍率（无量纲）：最终伤害 = power × 施法者.damage。
## 默认 2.2 —— 一个明显"比平砍强"的数值，所以火球值得花蓝。
@export var power := 2.2                # 伤害倍率：最终伤害 = power × 施法者.damage
## 额外暴击率，**0~1 的小数**（不是百分数！）：0.10 = +10%，会叠在单位自身的暴击率上。
## 默认 0.10 是"偶尔暴击"的手感；填 1.0 就是必定暴击。
@export var crit_bonus := 0.10          # 额外暴击率
## 目标模式，决定选谁打。默认 ENEMY_SINGLE：最常用、也是目前唯一完整实现的模式。
@export var target_mode := TargetMode.ENEMY_SINGLE

# ────────────────────────────── 视觉（Battle 播演出用） ──────────────────────────────
@export_group("视觉")
## 飞行体贴图（由公共弹道 scenes/effects/projectile/skill_projectile.gd 贴到 Sprite2D 上）。
## 留空 = 弹体本身没有静态贴图，画面完全交给外观包（appearance_scene）；两个都留空也能飞，只是看不见弹体。
@export var projectile_texture: Texture2D   # 飞行体贴图（留空 = 只靠外观包）

## 元素外观包：一个装着"这个元素长什么样"的 Node2D 场景（序列帧、粒子层、配色……）。
## 公共弹道只做"飞行 + 拖尾 + 命中爆炸 + 生命周期"，元素专属的东西全在这里：
##   火球 → scenes/effects/fireball/fireball_appearance.tscn
##   以后的寒冰箭 → 再写一个 ice_appearance，公共弹道一行都不用改。
## 留空 = 这条弹道只有上面那张静态贴图。
## 契约（可选，鸭子类型，两个都可以不实现）：
##   setup_effect(projectile, skill) → 弹道 setup() 时调用，外观包照 SkillData 配置自己；
##   stop_flight()                   → 命中时调用，外观包停发射（保留已生成粒子自然消亡）。
@export var appearance_scene: PackedScene

## 飞行体缩放（乘在贴图原始尺寸上）。默认 1.0 = 原始大小。
## 注意公共弹道的飞行 tween 会把整个 %Visual（静态贴图 + 外观包）乘 FLY_STRETCH(1.25) 做"鼓一下"，
## 所以这里填的是**基准尺寸**，峰值由弹道决定，改这里会同步影响起飞瞬间的大小。
@export var projectile_scale := 1.0
## 飞行速度，单位：**像素/秒**。飞行时长 = 距离 / 速度，但在 skill_projectile.gd 里
## 被 clampf(..., 0.18, 1.2) 钳过 —— 太近不会"瞬移"、太远也不会飞两秒以上，保证战斗节奏。
@export var projectile_speed := 900.0       # 像素/秒，飞行时长 = 距离 / 速度（有上下限）
## 整体染色（乘算到 sprite 的 modulate 上）。默认 (1.0, 0.55, 0.2) 是**橙色**，专为火球调的；
## 换成冰系技能就改偏蓝的色值。
@export var tint := Color(1.0, 0.55, 0.2)    # 整体染色（火球偏橙）
## 命中时迸发的粒子数量（0 = 不放粒子，但特效节点仍会创建）。
## 默认 24 是"看得出炸了一下"又不糊屏的量；性能吃紧时可以调小。
@export var hit_particles := 24             # 命中粒子数量
## 粒子贴图。留空 = 白色小方块兜底。
@export var hit_particle_texture: Texture2D # 粒子贴图（留空 = 白色小方块）
## 命中时的镜头抖动强度（像素级位移幅度）。默认 7.0 = 明显但不晕；
## 填 0.0 表示不抖，适合做成"轻击"类技能。
@export var screen_shake := 7.0             # 命中时的镜头抖动强度（0 = 不抖）

## 命中爆发的特效场景。留空 = 用默认的 scenes/effects/burst_effect.tscn
## （程序化的"闪光 / 冲击波 / 火星 / 浓烟"四层爆炸）。
## 填了就用它，例如像素火焰序列 scenes/effects/fireball/effect_fireball_hit.tscn
## （纯 AnimatedSprite2D、没有 play()，由 SkillProjectile.play_sequence_once() 播一次并自毁）。
@export var hit_effect_scene: PackedScene

## 命中爆发的整体缩放（1.0 = 原始大小）。群体技能调大，让爆炸能盖住整个敌阵：
## 爆裂火球用 1.8 在敌阵中心炸开，再在每敌人身上各补一朵 0.55 倍的小爆炸（见 Battle._cast_aoe()）。
@export var burst_scale := 1.0

# ────────────────── 视觉 · 序列帧外观（像素火焰素材用） ──────────────────
# 本组字段由"序列帧类外观包"读取，当前实现是 scenes/effects/fireball/fireball_appearance.gd：
#   A) projectile_texture 非空 → 弹道用静态贴图（可染色、可自转）
#   B) projectile_texture 为空 → 外观包用序列帧（AnimatedSprite2D 播 effect_fireball_*.tscn 的 61 帧）
# ⚠ 换了别的元素外观包（比如冰系）之后，这组字段是否生效取决于那个外观包读不读它们 ——
#    契约是"外观包自己决定"，公共弹道不介入。
@export_group("视觉 · 序列帧外观")

## 飞行体的序列帧场景。留空 = 用外观包里的默认那套 effect_fireball_1。
## 你手上有三种火焰配色，对应：
##   scenes/effects/fireball/effect_fireball_1.tscn（黄橙）
##   scenes/effects/fireball/effect_fireball_2.tscn
##   scenes/effects/fireball/effect_fireball_3.tscn
## ⚠ 只在 projectile_texture 为空时生效 —— 上面填了静态贴图就用上面那套。
@export var sequence_frame_scene: PackedScene

## true = 走"只有序列帧"的干净外观：把飞行粒子的强度按 flight_particle_ratio 压低。
## 为什么需要它：序列帧的实际内容是 **43×21 px**（画布 100×100 里 97% 是透明留白），
## 而默认那套粒子单个就有 50~130 px，全量开启会把像素火焰整个盖住。
@export var frames_only := false

## frames_only 模式下保留多少飞行粒子（相对于默认数量 ×0.08 的倍数）。
## ⚠ 填 0 会连火核一起关掉；建议 0.08 ~ 0.25 —— 太小看不出火心，太大就盖住素材了。
@export_range(0.0, 1.0) var flight_particle_ratio := 0.15

## frames_only 模式下是否保留浓烟尾迹。
## 默认关：浓烟用"普通混合"的深色贴图，几个粒子叠起来就是一条黑带，非常挡视线。
@export var show_smoke_trail := false

# ────────────────────────────── 音效 ──────────────────────────────
@export_group("音效")
## 施法瞬间的音效（出手时播）。留空 = 这段没声音，不会报错也不会用默认音顶替。
@export var cast_sfx: AudioStream
## 命中瞬间的音效。留空 = 没声音。
## ⚠ 技能命中的音效走这里（Battle 显式播），和 HitboxComponent 自动播的 SoundManager ENEMY_HIT
##   是两套来源；同一个技能两边都配就会听到两层音，调音时记得一起考虑。
@export var hit_sfx: AudioStream

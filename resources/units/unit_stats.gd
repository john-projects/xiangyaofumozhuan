## UnitStats —— 玩家与敌人的"属性表"（纯数据 Resource，一个角色一个 resources/units/*.tres）
##
## 全项目共用的数值源头：不含任何逻辑、不发信号、不碰节点，只被别处读。
## 持有者：GameRoot.party（团队名册）/ GameRoot.enemy_pool、MapData.enemy_pool、BattleUnit.stats。
## 消费方：BattleUnit / Battle（血量、伤害、蓝量、暴击、格挡、技能）、WorldMap / BagPanel（头像与名字）、StatsPanel。
## 数据流：*.tres → GameRoot._make_player_team() / _make_enemy_team()（duplicate 后按地图序号加成）→ BattleUnit.stats。
## ⚠ 竞技场时代的死字段（health_increase_per_wave / gold_drop / harvesting / hp_regen / life_steal / luck…）已整体删除，
##   以后要做"掉落金币/吸血/回血/幸运"时按新系统重新加字段，不要照抄旧语义。
extends Resource
class_name UnitStats

## 单位类型：决定战斗里站位、可被谁选中、胜负判定（UI 也能用来挑图标/配色）。
## 枚举整数值会写进 .tres，不要调整成员顺序（否则所有已有资源类型会静默错位）。
enum UnitType {
	PLAYER,
	ENEMY
}

## 种族（**玩家角色**的分组，决定能拜入哪些门派）：人族 HUMAN / 魔族 DEMON / 仙族 IMMORTAL。
## 门派归属见 Global.SECTS（太虚剑宗=人族、缥缈仙府=人族+仙族、紫霄神道教=仙族、万药谷=仙族+魔族、星罗教=魔族）。
## ⚠ 同样写进 .tres，不要调整成员顺序；老 .tres 不写 race 就是人族。
## 敌人也用它：种族决定"基础属性 → 派生值"的系数表（GameRoot.ATTR_TABLE）。
enum Race {
	HUMAN,      # 人族
	DEMON,      # 魔族
	IMMORTAL,   # 仙族
}

## 显示名。也是 Global 里选人字典的**键**（键必须等于对应 UnitStats.name），所以改名会连带影响 get_selected_player()。
@export var name: String
## 单位类型（PLAYER / ENEMY）。默认是枚举第 0 项 PLAYER —— ⚠ 新建敌人 .tres 忘了改，它会以"我方"身份进战斗。
@export var type: UnitType
## 种族（玩家用来分门派；敌人用来选属性系数表）。默认 HUMAN。
@export var race: Race

@export_group("基础属性")
## 五大基础属性（默认各 11 点，和玩家 1 级时一致）：
##   体质（气血）/ 魔力（法力、治疗）/ 力量（伤害）/ 耐力（防御、格挡）/ 敏捷（速度、躲避）。
## 最终点数 = 这里的基础值 + 等级成长（每级各 +1）+ 玩家自己加的自由点；
## 气血/伤害/防御/速度等**全部由这五项算出来**（GameRoot.derived_stats）。
@export var attr_con := 11
@export var attr_mag := 11
@export var attr_str := 11
@export var attr_end := 11
@export var attr_agi := 11
## 头像/立绘。用于选人卡片、悬浮卡、战斗头像。留空不报错，只是没图。
@export var icon: Texture2D
## 动作帧目录（可选）。填了就用这套 8 方位帧动画代替静态 icon：
## 目录下应有 idle_<方位>.png / run_<方位>.png / attack_<方位>.png / cast_<方位>.png，
## 每张是横向序列帧条带（帧宽 384、高 576）。方位共 8 个：
## down / down_right / right / up_right / up / up_left / left / down_left。
## 留空 = 继续用静态 icon（敌人和还没做动画的角色都是这样）。
@export var anim_dir: String = ""
## 3D 模型路径（可选）。填了就改用「实时渲染 3D 模型」代替 2D 贴图（3D-in-2D）：
## 例 "res://assets/models/players/行修.glb"（六个玩家角色的模型都在 assets/models/players/）。
## 该 .glb 需带骨骼 + idle/run/attack/cast 动画（由 xx3d 的 export_glb.py 生成）。
## 优先级：model_glb > anim_dir > icon。留空则走下面两者。
@export var model_glb: String = ""
## 最大生命值（单位：血点；默认 1.0 = 最小值兜底，防止忘了填导致瞬间暴毙或除零）。
## ⚠ 它是**模板值**：运行时真正在跑的是 HealthComponent.max_health（setup() 时从这里拷过去）。
@export var health:= 1.0
## 攻击伤害（单位：血点，**不是倍率**）。最终伤害 = 本值（技能则再乘 SkillData.power）。默认 1.0 是最小兜底。
@export var damage:= 1.0
## 移动速度（单位：像素/秒）。**战斗里真的在用**：Battle 每回合按 turn_speed()（speed + 扰动）排出手顺序。
## ⚠ 是 float 不是 int：门派被动会给 +0.5 这类小数加成，用 int 存会被静默截断、加成完全消失。
@export var speed := 1.0

## 蓝量（技能消耗）。默认 20.0 是配合 SkillData.mana_cost 默认 6.0 定的 —— 一场大约够放 3 次技能。
@export var mana := 1.0

## ── 由"基础属性"派生（GameRoot.derived_stats 算好后写进战斗副本）──
## 物理防御：每点「耐力」按种族系数折算（人族 +1.5/点、仙族 +1.6、魔族 +1.4）。
## 战斗里真在用：BattleUnit.take_damage() 按 防御/(防御+60) 的比例减伤。
@export var defense := 0.0
## 躲避：每点「敏捷」+1.0（三族相同）。默认 0；UI 上按百分数语义显示（10 = 10%）。只展示，还没做命中/闪避判定。
@export var dodge := 0.0
## 法伤：法术技能的伤害基数（由 体质/魔力/力量/耐力 直接折算，见 GameRoot.ATTR_TABLE）。
@export var spell_damage := 0.0
## 法防：吃法术伤害时按 法防/(法防+60) 减伤。
@export var spell_defense := 0.0

## ── 战斗二级属性（输出 / 抗性）：百分比字段一律是**百分数语义**（5 表示 5%）──
## 暴击率（%）。战斗里目前固定 10% 基础暴击（BattleUnit.roll_crit），这里填的值还没参与。
@export var crit_rate := 0.0
## 暴击伤害加成（%）。战斗里暴击固定 ×1.5，这里填的是"在 150% 之上的额外加成"。
@export var crit_damage_bonus := 0.0
## 封印命中率（%）。封印系统还没做，先留着。
@export var seal_hit := 0.0
## 治疗量（点）。治疗系统还没做，先留着。
@export var healing := 0.0
## 抗暴击率（%）：被暴击的概率降低多少。
@export var crit_resist := 0.0
## 爆伤减免（%）：受到暴击时，额外伤害减少多少。
@export var crit_damage_resist := 0.0
## 抵抗封印（%）：被封印命中的概率降低多少。
@export var seal_resist := 0.0
## 格挡值（点）：格挡成功时额外抵消多少伤害（和"格挡率"是两个东西）。
@export var block_value := 0.0
## 这个单位会的技能；留空的话我方单位用 Battle.default_skills（方便先跑通再逐个配）。
## ⚠ 敌人目前不读这个字段（敌人技能由 Battle 的敌人侧逻辑决定），给敌人配技能点了也没用。
@export var skills: Array[SkillData] = []


## 种族的中文名（"人族"/"魔族"/"仙族"；不认识的枚举值返回"未知"），可直接放进 UI。
func race_name() -> String:
	return race_display_name(race)


## 按枚举值取种族中文名 —— 静态版，给"手里只有 int 没有 UnitStats"的地方用（门派表、调试打印）。
static func race_display_name(value: int) -> String:
	match value:
		Race.HUMAN:
			return "人族"
		Race.DEMON:
			return "魔族"
		Race.IMMORTAL:
			return "仙族"
		_:
			return "未知"

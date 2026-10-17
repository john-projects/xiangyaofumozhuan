extends Resource
class_name UnitStats

## UnitStats —— 玩家与敌人的"属性表"（纯数据 Resource，一个角色一个 resources/units/*.tres）。
##
## ── 在系统里的位置 ──
##   全项目共用的数值源头。它不含任何逻辑、不发信号、不碰节点，只被别处**读**。
##   持有者：GameRoot.party（团队名册）/ GameRoot.enemy_pool、MapData.enemy_pool、
##           BattleUnit.stats（战斗单位）。
##   消费方：BattleUnit / Battle（血量、伤害、蓝量、暴击、格挡、技能）、
##           WorldMap / BagPanel（头像与角色名）、StatsPanel（属性面板）。
##
## ── 数据流向 ──
##   resources/units/*.tres（本 Resource）
##     → GameRoot._make_player_team() / _make_enemy_team()（用 duplicate() 复制一份再按地图序号加成）
##     → Battle.start_battle(我方数组, 敌方数组) → BattleUnit.stats
##       → Battle 结算时取 damage / mana / skills / block_chance（暴击走 crit_chance，见 battle_unit.gd）
##
## ── 字段一览（2026-10 清理后）──
##   身份：name / type / race / icon
##   战斗：health / damage / mana / speed（出手顺序）/ block_chance（格挡率）/ skills
##   成长：defense / dodge / spell_damage（由 GameRoot.derived_stats() 按基础属性算好写进战斗副本）
##   二级：crit_rate / crit_damage_bonus / seal_hit / healing / crit_resist /
##         crit_damage_resist / seal_resist / block_value（只展示，见下）
##   ⚠ 竞技场时代那批死字段（health_increase_per_wave / damage_increase_per_wave / gold_drop /
##     harvesting / hp_regen / life_steal / luck）**已整体删除**（连同各 .tres 里的值）——
##     它们要么没有任何读取方，要么只在属性面板上占一行、对玩法零影响。
##     以后要做"掉落金币/吸血/回血/幸运"时再按新系统重新加字段，不要照抄旧语义。
##
## ── 关于赋值风格的说明（本文件的写法不统一，但保持原样不动） ──
##   `health:= 1.0`（冒号紧贴等号）和 `mana := 20.0`（冒号后有空格）在 GDScript 里**完全等价**，
##   都是"声明并类型推断赋值"，不改变类型或行为。本文件是长期迭代留下的风格差异，不要顺手统一，
##   因为那属于无意义的整格式改动。

## 单位类型。决定这个 UnitStats 被系统当成"我方"还是"敌方"处理：
##   · 战斗里决定站位、可被谁选中、胜负判定；
##   · 也能被 UI 用来挑图标/配色（目前的战斗两端都按传入的数组区分，不依赖本字段）。
## 枚举整数值会被写进 .tres，所以不要调整成员顺序（否则所有已有资源类型会静默错位）。
enum UnitType {
	PLAYER,
	ENEMY
}

## 种族（**玩家角色**的分组，决定能拜入哪些门派）。
##   人族 HUMAN / 魔族 DEMON / 仙族 IMMORTAL —— 三个门派归属见 Global.SECTS：
##     太虚剑宗 = 人族专属、缥缈仙府 = 人族＋仙族、紫霄神道教 = 仙族专属、
##     万药谷 = 仙族＋魔族、星罗教 = 魔族专属。
## ⚠ 同样会写进 .tres，**不要调整成员顺序**；新字段默认 HUMAN，
##   所以老 .tres（包括敌人）不写 race 就是人族 —— 敌人的种族目前没有任何地方读，不影响战斗。
enum Race {
	HUMAN,      # 人族
	DEMON,      # 魔族
	IMMORTAL,   # 仙族
}

## 显示名。也是 Global 里选人字典的**键**（注释里写明"键必须等于对应 UnitStats.name 的值"），
## 所以改名会连带影响 get_selected_player() 的查找 —— 它和 id 一样属于"看着像文本其实是键"的字段。
@export var name: String
## 单位类型（PLAYER / ENEMY）。默认是枚举第 0 项 PLAYER，
## ⚠ 所以新建一个敌人 .tres 时忘了改这里，它会以"我方"身份进战斗，表现会非常费解。
@export var type: UnitType
## 种族（Player 专属概念，见上面 Race 的说明）。默认 HUMAN = 人族。
## 谁读：GameRoot.join_sect()（能不能拜某个门派）、StatsPanel（名字下面的「种族 · 门派」）、
##   WorldMap._build_sect_buttons()（拜师面板按种族筛人）。
## 敌人的这个字段没人读，留默认即可。
@export var race: Race
## 头像/立绘。用于选人卡片、悬浮卡、战斗头像。留空不报错，只是没图。
@export var icon: Texture2D
## 最大生命值（单位：血点；初始值 1.0，通常玩家几十、敌人个位数）。
## 默认 1.0 是"最小值兜底"：即使某个 .tres 忘了填，单位也不会瞬间暴毙或除零。
## ⚠ 它是**模板值**：运行时真正在跑的是 HealthComponent.max_health（在 setup() 时从这里拷过去的），
##   而且如下两条路径会在战斗之间改这个模板字段本身。
@export var health:= 1.0
## 攻击伤害（单位：血点；**不是倍率**）。最终打出去的伤害 = 本值（技能则再乘 SkillData.power）。
## 默认 1.0 是最小兜底值。
@export var damage:= 1.0
## 移动速度（单位：像素/秒）。**战斗里真的在用**：Battle 每回合按 turn_speed()（speed + 扰动）排出手顺序。
## 默认 300。
## ⚠ 是 float 而不是 int：门派被动（如缥缈仙府「云海心法」每级 +0.5）会给出小数加成，
##   用 int 存的话 += 0.5 会被静默截断，加成完全消失。
## ⚠ 实时战斗时代它在 Unit._process 里直接推 position，那段（和 Unit 本身）已随竞技场移除。
@export var speed := 300.0
## 格挡成功率，**百分数语义**（0~100+，配合 Global.get_chance_success(stats.block_chance / 100) 使用）。
## 调用处（BattleUnit.roll_block()）自己先 /100 变成 0~1 再问概率 —— 所以这里填 5 表示 5%。
## 默认 0.0 = 永不格挡（不做格挡的单位不用管这个字段）。
## ⚠ 代码不做上限钳制，道具/升级理论上能把它堆到 100 以上（那就必定格挡了）。
@export var block_chance:= 0.0

## 蓝量：技能消耗（没填的 .tres 用这个默认值，不会报错）
## 默认 20.0 是配合 SkillData.mana_cost 的默认 6.0 定的 —— 一场大约够放 3 次技能。
## 它是战斗内的"模板值"，运行时余额由 BattleUnit 自己维护。
@export var mana := 20.0

# ── 由"基础属性"派生出来的三项（GameRoot.derived_stats 算好后写进战斗副本）──
## 物理防御：每点基础属性「耐力」按种族系数折算（人族 +1.5/点、仙族 +1.6、魔族 +1.4）。
## ⚠ 目前**只展示、还没参与战斗结算**（战斗里还没有"减伤"这一步）；先在属性面板里看得见。
## 默认 0。直接从 .tres 填值也可以（会作为派生前的基数叠上去）。
@export var defense := 0.0
## 躲避：每点「敏捷」+1.0（三个种族都一样）。同样是**只展示**，战斗还没做命中/闪避判定。
## 默认 0；数值在 UI 上按百分数语义显示（10 = 10%）。
@export var dodge := 0.0
## 法伤：五项基础属性都会副加一点（体质 +0.3、魔力 +0.7、力量 +0.4、耐力 +0.2）。
## 原字段叫 spirit（灵力），按需求整体改名为"法伤"；数值系数沿用原表。
## 目前**只展示**（战斗里的技能伤害还是 power × damage，还没接法伤）。
@export var spell_damage := 0.0

# ── 战斗二级属性（输出 / 抗性）──
# 这些字段目前**只展示**（战斗里还没有对应的判定），先给属性面板一个数据来源；
# 以后接暴击/封印/治疗系统时，结算处读这里即可，不用再改数据结构。
# 百分比字段一律是**百分数语义**（5 表示 5%，不是 0.05），和 block_chance 同口径。
## 暴击率（%）。战斗里目前固定 10% 基础暴击（见 BattleUnit.roll_crit），这里填的值还没参与。
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
## 这个单位会的技能；留空的话，我方单位会用 Battle.default_skills（方便先跑通再逐个配）
## 元素类型是 SkillData；同样注意 Array[T] 只能写在冒号后（`= Array[SkillData]` 会解析报错）。
## ⚠ 敌人目前不读这个字段（敌人技能由 Battle 的敌人侧逻辑决定），所以给敌人配技能点了也没用。
@export var skills: Array[SkillData] = []


## 种族的中文名（"人族"/"魔族"/"仙族"；不认识的枚举值返回"未知"）。
## 返回值：可直接放进 UI 的字符串。
func race_name() -> String:
	return race_display_name(race)


## 按枚举值取种族中文名 —— 静态版，给"手里只有 int 没有 UnitStats"的地方用
## （例如门派表的允许种族列表、调试打印）。
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

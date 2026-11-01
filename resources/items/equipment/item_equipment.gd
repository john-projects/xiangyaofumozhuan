## ItemEquipment —— 装备道具（头盔 / 武器 / 腰带 / 项链 / 衣服 / 鞋子）
##
## ItemBase 的子类：只读数据，字段在 resources/items/equipment/**/item_*.tres 里烘好（资源级随机，不是运行期随机）。
## 读它的人：BagPanel（背包/装备栏）、MerchantPanel（货架价）、hover_item_card（get_description）、GameRoot.equip_item。
## 「谁穿着什么」不在本类里：存在 Global.equipment_by_character（每个角色一套），背包内容在 Global.equipped_weapons。
## equip_type 从 ItemBase 继承，每个 .tres 必须填对（NONE = 不能装备，equip_item() 会拒绝）。
## 属性口径与 UnitStats 一致：attack / defense / health / speed 是整数直接加；crit_chance 是**百分数语义**（5 = +5%）。
## **已接入**：GameRoot.derived_stats() 会把身上所有装备累加进派生值（面板与战斗都读它）。
##   物伤（attack）只加「伤害」一栏，法伤（spell_damage）只加「法伤」一栏 —— 两者各自独立，
##   不再 1:1 双加（武器两栏的数值都按「总伤区间」给的，双加会直接翻倍）。
##   defense/health/speed/crit_chance 各加各的。
##   加新字段时：ItemEquipment 加 @export + derived_stats() 里对应叠加 + equipment_bonus() 里累加，三处都要改。
extends ItemBase
class_name ItemEquipment

## 各部位的固定主属性字段（预览时只有这些是确定的，其余都算随机词条）。
const SLOT_MAINS := {
	1: ["defense", "mana"],                    # 头盔
	5: ["defense"],                            # 衣服
	3: ["defense", "health"],                  # 腰带
	6: ["defense"],                            # 鞋子
	7: ["attack", "defense"],                  # 戒指
	4: ["attack", "spell_damage"],             # 项链
	8: ["spell_damage", "spell_defense"],      # 耳饰
	2: ["attack", "spell_damage"],             # 武器
}

## 各部位的稀有词条池（购买时从这里随机抽）。
const RARE_POOL := {
	1: ["crit_resist", "seal_resist", "defense_pct"],                     # 头盔
	5: ["health_pct", "defense_pct", "block_value", "crit_damage_resist"],  # 衣服
	3: ["health_pct", "dodge", "crit_resist"],                            # 腰带
	6: ["speed_pct", "dodge", "crit_resist"],                             # 鞋子
	7: ["physical_pct", "spell_pct", "seal_hit"],                         # 戒指
	4: ["crit_chance", "crit_damage_bonus", "healing"],                   # 项链
	8: ["crit_chance", "healing", "spell_pct"],                           # 耳饰
	2: ["physical_pct", "spell_pct", "seal_hit", "crit_chance", "healing"],  # 武器
}
## 只收「纯稀有词条」：不含 attack/spell_damage/mana/spell_defense/speed，
## 那几个是别部位的固定主属性，混进词条池会和主属性重复计算。
## 平坦类词条（其余按百分比处理）。
const RARE_FLAT := ["block_value", "dodge", "healing"]



## 品质名与颜色（0 白 / 1 蓝 / 2 紫 / 3 粉 / 4 橙），提示卡上显示用。
const TIER_NAMES := ["白", "蓝", "紫", "粉", "橙"]
const TIER_COLORS := ["#d8d8d8", "#5aa9ff", "#b46bff", "#ff7bd0", "#ff9f3a"]

## 武器类型：0=不是武器，1 剑 / 2 刀 / 3 扇 / 4 枪 / 5 杖 / 6 爪。
## 商人面板按它给武器再分一次页签；非武器保持 0。
@export var weapon_type := 0

## 武器类型名（页签与提示卡用）。0 返回空串。
const WEAPON_TYPE_NAMES := ["", "剑", "刀", "扇", "枪", "杖", "爪"]


## 武器类型值 → 中文名；0 或越界返回空串。
static func weapon_type_name(value: int) -> String:
	if value <= 0 or value >= WEAPON_TYPE_NAMES.size():
		return ""
	return WEAPON_TYPE_NAMES[value]

## 装备条件：穿戴所需等级（提示卡上显示为「等级 X」）。
@export var req_level := 0
## 装备角色：限定可穿戴的角色名，逗号分隔；空串 = 不限（只有武器会填）。
@export var req_characters := ""

## 是否已经掷过骰。false = 商店里的模板，属性卡显示区间；true = 已入包的实物。
@export var rolled := false

## 攻击（整数，加到 UnitStats.damage 上的点数）。
@export var attack := 0
## 防御（整数，减伤用；Battle 还没有减伤公式，先作为展示/预留字段）。
@export var defense := 0
## 生命上限（整数，加到 UnitStats.health 上的点数）。
@export var health := 0
## 暴击率加成，**百分数语义**（5 表示 +5%）。
@export var crit_chance := 0.0
## 速度（整数，加到 UnitStats.speed 上的点数）。
@export var speed := 0

# ── 白品质固定主属性（按部位在生成时填入）──
## 法伤（整数）。attack 走「伤害+法伤双加」，这个只加法伤一栏。
@export var spell_damage := 0
## 法防（整数）。
@export var spell_defense := 0
## 魔法上限（整数）。
@export var mana := 0

# ── 蓝品质双加：五项基础属性（加到角色的基础属性点里）──
@export var attr_con := 0
@export var attr_mag := 0
@export var attr_str := 0
@export var attr_end := 0
@export var attr_agi := 0

# ── 高级稀有词条（紫/粉/橙品质逐级追加）──
## 躲避。
@export var dodge := 0.0
## 格挡值。
@export var block_value := 0.0
## 封印命中率，百分数语义。
@export var seal_hit := 0.0
## 抵抗封印，百分数语义。
@export var seal_resist := 0.0
## 抗暴率，百分数语义。
@export var crit_resist := 0.0
## 暴击伤害加成，百分数语义。
@export var crit_damage_bonus := 0.0
## 爆伤减免，百分数语义。
@export var crit_damage_resist := 0.0
## 治疗量。
@export var healing := 0.0

# ── 百分比词条（对派生值做乘算，百分数语义）──
## 气血上限百分比。
@export var health_pct := 0.0
## 防御百分比。
@export var defense_pct := 0.0
## 速度百分比。
@export var speed_pct := 0.0
## 物伤百分比。
@export var physical_pct := 0.0
## 法伤百分比。
@export var spell_pct := 0.0

@export_group("3D 武器外观")
## 武器场景以握柄为原点，局部 +Y 指向剑尖；不配置时不显示手持模型。
@export var weapon_scene: PackedScene
## 相对右手骨骼的握点、旋转及缩放，用于校准武器美术资源。
@export var weapon_position := Vector3.ZERO
@export var weapon_rotation_degrees := Vector3.ZERO
@export var weapon_scale := 1.0


## 生成属性卡上的 BBCode 富文本：只列**非 0** 项，六项全 0 时返回一句占位，保证卡片不空。
## 参数：无（读自身字段）。返回值：BBCode 字符串，hover_item_card 直接丢给 RichTextLabel；纯函数无副作用。
## 属性卡开头的「装备说明」段：文案 + 空行 + 分隔线。已掷骰与未掷骰共用。
## 返回：RichTextLabel 用的 BBCode 行数组；没有文案时只有分隔线。
func _flavor_lines() -> Array[String]:
	var lines: Array[String] = []
	if not item_flavor.is_empty():
		lines.append("[color=#c8b48a]%s[/color]" % item_flavor)
		lines.append("")
	lines.append("[color=#6b6152]────────────────[/color]")
	return lines


func get_description() -> String:
	# 商店里的模板没掷过骰，显示区间；已入包的实物显示真实数值
	if not rolled:
		return _preview_description()
	# 布局：条件 → 装备说明 → 分隔线 → 属性（部位在卡片头部的 Label 上，这里不重复）
	var lines: Array[String] = _flavor_lines()

	# ① 白品质固定主属性
	var main_parts: Array[String] = []
	for entry in [[attack, "物伤", ""], [spell_damage, "法伤", ""], [defense, "防御", ""],
			[spell_defense, "法防", ""], [health, "气血", ""], [mana, "魔法", ""], [speed, "速度", ""]]:
		if int(entry[0]) != 0:
			main_parts.append("[color=orange]%s +%d[/color]" % [entry[1], int(entry[0])])
	# 每行一条，不再横向拼在一起
	for part in main_parts:
		lines.append(part)

	# ② 蓝品质双加基础属性
	var basic_parts: Array[String] = []
	for pair in [[attr_con, "体质"], [attr_mag, "魔力"], [attr_str, "力量"],
			[attr_end, "耐力"], [attr_agi, "敏捷"]]:
		if int(pair[0]) != 0:
			basic_parts.append("[color=white]%s +%d[/color]" % [pair[1], int(pair[0])])
	for part in basic_parts:
		lines.append(part)

	# ③ 紫/粉/橙 稀有词条
	for entry in [
		[crit_chance, "暴击率", "%"],
		[crit_damage_bonus, "暴击伤害", "%"],
		[dodge, "躲避", ""],
		[block_value, "格挡值", ""],
		[crit_resist, "抗暴率", "%"],
		[crit_damage_resist, "爆伤减免", "%"],
		[seal_hit, "封印命中", "%"],
		[seal_resist, "抵抗封印", "%"],
		[healing, "治疗量", ""],
		[health_pct, "气血", "%"],
		[defense_pct, "防御", "%"],
		[speed_pct, "速度", "%"],
		[physical_pct, "物伤", "%"],
		[spell_pct, "法伤", "%"],
	]:
		if float(entry[0]) != 0.0:
			lines.append("[color=mediumpurple]%s +%s%s[/color]" % [
				entry[1], _num(float(entry[0])), entry[2]])

	if main_parts.is_empty() and basic_parts.is_empty():
		lines.append("[color=gray]（这件装备没有属性加成）[/color]")
	return "\n".join(lines)

## 未掷骰时的预览：把每个非 0 的属性显示成「随机xxx（0~上限）」。
## 未掷骰时的预览：主属性固定照常显示，基础属性和稀有词条显示随机区间。
func _preview_description() -> String:
	# 装备说明（文案 + 分隔线）两种状态都显示
	var lines: Array[String] = _flavor_lines()
	var stat_lines: Array[String] = []

	# ① 主属性：只显示该部位的固定项，且按品质算好、不随机
	var main_fields: Array = SLOT_MAINS.get(int(equip_type), [])
	for key in main_fields:
		var v := int(get(key))
		if v != 0:
			stat_lines.append("[color=orange]%s +%d[/color]" % [_stat_name(key), v])

	# ② 基础属性：随机，±50%（条数固定）
	var attr_count := 0
	var attr_max := 0
	for v in [attr_con, attr_mag, attr_str, attr_end, attr_agi]:
		if int(v) != 0:
			attr_count += 1
			attr_max = maxi(attr_max, int(v))
	if attr_count > 0:
		var lo := maxi(1, int(round(attr_max * 0.5)))
		var hi := maxi(lo, int(round(attr_max * 1.5)))
		for i in attr_count:
			stat_lines.append("[color=white]随机基础属性（%d~%d）[/color]" % [lo, hi])

	# ③ 稀有词条：条数由品质决定（紫 1 / 粉 2 / 橙 3），种类与数值都随机
	var rare_count := maxi(0, int(item_tier) - 1)
	for i in rare_count:
		stat_lines.append("[color=mediumpurple]随机词条[/color]")

	if stat_lines.is_empty():
		stat_lines.append("[color=gray]（这件装备没有属性加成）[/color]")
	lines.append_array(stat_lines)
	return "\n".join(lines)


## 属性字段 → 中文名（预览用）。
static func _stat_name(key) -> String:
	match key:
		"attack": return "物伤"
		"spell_damage": return "法伤"
		"defense": return "防御"
		"spell_defense": return "法防"
		"health": return "气血"
		"mana": return "魔法"
		"speed": return "速度"
	return key


static func _num(v: float) -> String:
	return str(int(roundf(v)))

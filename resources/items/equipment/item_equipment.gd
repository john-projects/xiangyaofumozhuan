## ItemEquipment —— 装备道具（头盔 / 武器 / 腰带 / 项链 / 衣服 / 鞋子）
##
## ItemBase 的子类：只读数据，字段在 resources/items/equipment/**/item_*.tres 里烘好（资源级随机，不是运行期随机）。
## 读它的人：BagPanel（背包/装备栏）、MerchantPanel（货架价）、hover_item_card（get_description）、GameRoot.equip_item。
## 「谁穿着什么」不在本类里：存在 Global.equipment_by_character（每个角色一套），背包内容在 Global.equipped_weapons。
## equip_type 从 ItemBase 继承，每个 .tres 必须填对（NONE = 不能装备，equip_item() 会拒绝）。
## 属性口径与 UnitStats 一致：attack / defense / health / speed 是整数直接加；crit_chance / block_chance 是**百分数语义**（5 = +5%）。
## 目前这些数值只展示、还没参与战斗结算（战斗读的是 UnitStats），接加成时按上面口径直接加即可。
extends ItemBase
class_name ItemEquipment

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
## 格挡率加成，**百分数语义**（5 表示 +5%）。
@export var block_chance := 0.0


## 生成属性卡上的 BBCode 富文本：只列**非 0** 项，六项全 0 时返回一句占位，保证卡片不空。
## 参数：无（读自身字段）。返回值：BBCode 字符串，hover_item_card 直接丢给 RichTextLabel；纯函数无副作用。
func get_description() -> String:
	var lines: Array[String] = []
	if attack != 0:
		lines.append("[color=orange]攻击[/color] +%d" % attack)
	if defense != 0:
		lines.append("[color=skyblue]防御[/color] +%d" % defense)
	if health != 0:
		lines.append("[color=green]生命[/color] +%d" % health)
	if crit_chance != 0.0:
		lines.append("[color=red]暴击[/color] +%s%%" % _num(crit_chance))
	if speed != 0:
		lines.append("[color=yellow]速度[/color] +%d" % speed)
	if block_chance != 0.0:
		lines.append("[color=cyan]格挡[/color] +%s%%" % _num(block_chance))
	if lines.is_empty():
		return "[color=gray]（这件装备没有属性加成）[/color]"
	return "[code]" + "　".join(lines) + "[/code]"


## 数字转字符串：整数不带小数点（12 而不是 12.0），有小数才保留一位（2.5）。
## 参数 v：要显示的数值（百分数口径）。返回值：可读字符串。纯函数。
static func _num(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v

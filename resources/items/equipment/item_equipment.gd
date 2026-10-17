## ═══════════════════════════════════════════════════════════════════════════
## ItemEquipment —— 装备道具（头盔 / 武器 / 腰带 / 项链 / 衣服 / 鞋子）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   ItemBase 的第三个"能进背包、能穿上身"的子类（另外两个是 ItemWeapon / ItemUpgrade /
##   ItemPassive —— 其中只有本类和 ItemWeapon 会出现在地图线的背包里）。
##   · **谁创建**：resources/items/equipment/**/item_*.tres（26 件，图标在
##     assets/sprites/equipment/**），由编辑器或脚本生成；属性值是"随机生成后烘进资源"的，
##     所以同一件装备每次打开游戏数值都一样（资源级随机，不是运行时随机）。
##   · **谁读**：BagPanel（画背包格子 / 装备栏）、MerchantPanel（货架价格）、
##     hover_item_card（属性卡，走 get_description()）、GameRoot.equip_item()（按 equip_type 找栏位）。
##   · **谁写**：没有人写本类的字段 —— 它是只读数据。真正变化的"谁穿着什么"存在
##     Global.equipment_by_character（**每个角色一套**：角色键 → { 栏位 → 本类实例 }），
##     背包内容存在 Global.equipped_weapons（全队共用）。
##
## 栏位：
##   equip_type 从 ItemBase 继承（EquipType.HELMET / WEAPON / BELT / NECKLACE / ARMOR / BOOTS），
##   每个 .tres 必须把它填对，否则 GameRoot.equip_item() 会拒绝（NONE = 不能装备）。
##
## 属性口径（⚠ 和 UnitStats 保持一致，方便以后直接把加成算进战斗）：
##   · attack / defense / health / speed：整数，直接加到对应属性上；
##   · crit_chance / block_chance：**百分数语义**（5 = +5%），与 UnitStats.block_chance 同口径；
##   · 0 表示这件装备不提供该属性（属性卡上不显示 0 项）。
##   目前这些数值只展示、还没参与战斗结算（战斗读的是 UnitStats），接加成时按上面口径直接加即可。
extends ItemBase
class_name ItemEquipment

## 攻击（整数，加到 UnitStats.damage 上的点数）。
@export var attack := 0
## 防御（整数，减伤用；Battle 目前还没有减伤公式，先作为展示/预留字段）。
@export var defense := 0
## 生命上限（整数，加到 UnitStats.health 上的点数）。
@export var health := 0
## 暴击率加成，**百分数语义**（5 表示 +5%）。
@export var crit_chance := 0.0
## 速度（整数，加到 UnitStats.speed 上的点数）。
@export var speed := 0
## 格挡率加成，**百分数语义**（5 表示 +5%）。
@export var block_chance := 0.0


## 生成属性卡上显示的富文本（BBCode）。
## 只列出**非 0** 的属性，所以"一件纯防御的头盔"不会带一行"攻击 +0"的废话；
## 六项全 0（理论上不该有这种资源）时返回一句占位，保证卡片不会空着。
## 参数：无（读自身字段）。
## 返回值：BBCode 字符串；hover_item_card 直接丢给 RichTextLabel。
## 副作用：无（纯函数）。
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


## 数字转字符串：整数就不带小数点（12 而不是 12.0），有小数才保留一位（2.5）。
## 参数 v：要显示的数值（百分数口径）。
## 返回值：可读字符串。
## 副作用：无。
static func _num(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v

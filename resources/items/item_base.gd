## ItemBase —— 所有"可购买 / 可获得道具"的数据基类（Resource）。
##
## 体系：现在只有一个子类 ItemEquipment（装备：头盔/武器/腰带/项链/衣服/鞋子，26 件）；
## 竞技场时代的 ItemWeapon / ItemUpgrade / ItemPassive / ItemSkill 已随竞技场一起移除。
## 数据：每件装备一个 .tres（resources/items/equipment/<类型>/item_*.tres），数值和图标在编辑器里填。
## 流向：商人货架（Global.get_all_equipment → MerchantPanel → GameRoot.buy_item 扣钱入背包）、
##   穿戴（GameRoot.equip_item → Global.equipment_by_character[角色][equip_type]）、
##   悬停卡（TooltipManager 登记 ItemBase → hover_item_card 调 get_description()，按继承链命中所有子类）。
## ⚠ .tres 里存的是整数下标（item_tier = 1、item_type = 3…），两个枚举都只能在末尾追加成员，调顺序会静默错位。
extends Resource
class_name ItemBase

## 道具大类：WEAPON / UPGRADE / PASSIVE 是竞技场遗留（已移除，**不要再用**），
## 只为不改 .tres 里存的整数而保留；EQUIPMENT = 3 是地图线的装备，新资源一律填 3。
enum ItemType{
	WEAPON,
	UPGRADE,
	PASSIVE,
	EQUIPMENT
}

## 装备栏位类型，与背包角色区两侧那 6 个格子一一对应（左右各 3，顺序见 BagPanel.EQUIP_LAYOUT）；
## NONE = 不是装备（材料/消耗品），点它不会穿到任何栏位。加新类型：末尾追加 + 补 equip_type_name() + 在 EQUIP_LAYOUT 定位置。
enum EquipType{
	NONE,
	HELMET,
	WEAPON,
	BELT,
	NECKLACE,
	ARMOR,
	BOOTS
}

@export var item_name: String                # 显示名。背包格子 / 商人货架 / 属性卡标题都用它；也是商人"持×n"的判定键
@export var item_icon: Texture2D             # 图标。BagPanel / MerchantPanel / HoverItemCard 都直接取这张贴图
@export var item_tier: Global.UpgradeTier    # 稀有度（COMMON=0 / RARE=1 / EPIC=2 / LEGENDARY=3）。只影响描边颜色，不直接改数值
@export var item_type: ItemType              # 道具大类，见上面的 ItemType 注释（新资源一律填 EQUIPMENT）
@export var item_cost: int                   # 商店售价（单位：金币，常见 20~60）。0 表示非卖品；卖出时按 75% 向下取整返还
## 能穿到哪个装备栏，见 EquipType。默认 NONE = 不能装备（材料 / 消耗品都保持默认）。
## 现在的装备资源（ItemEquipment）都在 .tres 里显式填了它；忘了填会穿上不去（能买、但点了没反应）。
@export var equip_type: EquipType = EquipType.NONE

## 返回 BBCode 富文本描述，供 RichTextLabel.set_text() 直接使用（支持 [color=...]、[code] 等标签）。
## 基类返回空串：描述长什么样由子类决定（ItemEquipment 拼攻击/防御/生命/暴击/速度/格挡）；纯函数，无副作用。
func get_description() -> String:
	return ""


## 这件道具能穿到哪个栏位（返回 EquipType；NONE = 不能装备）。
## 做成函数而不是让调用方直接读字段：子类可按自己规则算，调用方一行不用动。纯读自身字段，无副作用。
func get_equip_type() -> int:
	return equip_type


## 栏位类型 → 中文名（"头盔"/"武器"/"腰带"/"项链"/"衣服"/"鞋子"）；装备栏空格标签、提示文案都走它。
## 参数 slot_type：EquipType 的成员值。返回值：中文名；未知值兜底成"装备"。
static func equip_type_name(slot_type: int) -> String:
	match slot_type:
		EquipType.HELMET:
			return "头盔"
		EquipType.WEAPON:
			return "武器"
		EquipType.BELT:
			return "腰带"
		EquipType.NECKLACE:
			return "项链"
		EquipType.ARMOR:
			return "衣服"
		EquipType.BOOTS:
			return "鞋子"
		_:
			return "装备"


## 道具大类 → 中文名（"装备"/"武器"/"升级"/"被动"），悬停提示卡的类型行用它（否则会显示英文枚举名）。
## 参数 item_type_value：ItemType 的成员值。返回值：中文名；未知值兜底成"道具"。
static func item_type_name(item_type_value: int) -> String:
	match item_type_value:
		ItemType.WEAPON:
			return "武器"
		ItemType.UPGRADE:
			return "升级"
		ItemType.PASSIVE:
			return "被动"
		ItemType.EQUIPMENT:
			return "装备"
		_:
			return "道具"

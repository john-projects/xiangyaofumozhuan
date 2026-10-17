## ═══════════════════════════════════════════════════════════════════════════
## ItemBase —— 所有"可购买 / 可获得道具"的数据基类（Resource）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   道具数据体系的根。工程里现在**只有一个子类**：
##     · ItemEquipment （resources/items/equipment/item_equipment.gd）—— 装备
##                       （头盔 / 武器 / 腰带 / 项链 / 衣服 / 鞋子，26 件，图标在 assets/sprites/equipment）
##   竞技场时代还有 ItemWeapon / ItemUpgrade / ItemPassive / ItemSkill 四个子类，
##   它们已经随竞技场一起移除（对应的 resources/items/{weapons,upgrade,passives,skills} 也没了）。
##   下面 ItemType 枚举里的 WEAPON / UPGRADE / PASSIVE 是为了**保持整数下标不变**才留着的
##   （旧 .tres 里存的是数字），新代码只需要关心 EQUIPMENT。
##
## 数据从哪来：
##   每件装备 = 一个 .tres 资源（resources/items/equipment/<类型>/item_*.tres）。
##   数值和图标在编辑器里填，代码只按 item_type / equip_type 分派行为、按 item_tier 决定外观。
##
## 数据到哪去：
##   · 商人：Global.get_all_equipment() 扫目录当货架 → MerchantPanel 画格子 → 点一下确认购买 →
##     GameRoot.buy_item() 扣 Global.coins 并把本对象 append 进 Global.equipped_weapons（背包）；
##   · 穿戴：背包里点一下 → GameRoot.equip_item(角色, 本对象) 移到
##     Global.equipment_by_character[角色][equip_type]（每个角色各一套）；
##   · 悬停提示：TooltipManager 登记了 ItemBase → hover_item_card.tscn（属性名 "item"），
##     它按"继承链"查找登记项，所以登记基类就能命中所有子类；卡片会调用本类的 get_description()
##
## 坑：
##   · item_tier 的类型写作 Global.UpgradeTier —— 枚举其实定义在 autoload 的 global.gd 里，
##     跨文件用 autoload 名当命名空间是允许的，前提是 global.gd 已在 project.godot 里登记为自动加载。
##   · .tres 里存的是整数下标（item_tier = 1、item_type = 3 …）。枚举成员顺序一旦调整，
##     所有旧资源都会静默错位、不报错。因此下面两个枚举只能在末尾追加成员。
extends Resource
class_name ItemBase

## 道具大类（历史遗留的三个值 + 现在唯一在用的 EQUIPMENT）：
##   WEAPON    = 0 → 竞技场武器（已随竞技场移除，**不要再用**）
##   UPGRADE   = 1 → 竞技场升级（已移除）
##   PASSIVE   = 2 → 竞技场被动（已移除）
##   EQUIPMENT = 3 → 地图线的**装备**（ItemEquipment：头盔/武器/腰带/项链/衣服/鞋子），
##                 进背包后可穿到某个角色的 Global.equipment_by_character 对应栏位；
##                 地图线的商人卖的就是它。
## 前三个值保留只是为了**不改 .tres 里存的整数**（EQUIPMENT 一直是 3），新资源一律填 3。
enum ItemType{
	WEAPON,
	UPGRADE,
	PASSIVE,
	EQUIPMENT
}

## 装备栏位类型 —— 和背包角色区两侧那 6 个格子一一对应（左右各 3 个，顺序见 BagPanel.EQUIP_LAYOUT）：
##   左一 头盔 / 左二 武器 / 左三 腰带 / 右一 项链 / 右二 衣服 / 右三 鞋子。
## NONE = **不是装备**（材料 / 消耗品 / 技能等）：点它不会穿到任何栏位上。
## 加新类型时：① 在本枚举**末尾**追加成员（.tres 里存的是整数下标，中间插成员会让旧资源静默错位）；
##            ② 在 equip_type_name() 里补一行中文名；③ 在 BagPanel.EQUIP_LAYOUT 里决定摆哪一格。
## 以后要加"戒指（两枚）"这种同类型多栏位，再扩一个 slot_index 概念即可，本枚举不用动。
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
@export var item_cost: int                   # 商店售价（单位：金币，默认由 .tres 决定，常见 20~60）。0 表示非卖品；卖出时按 75% 向下取整返还
## 能穿到哪个装备栏，见 EquipType。默认 NONE = 不能装备（材料 / 消耗品都保持默认）。
## 现在的装备资源（ItemEquipment）都在 .tres 里显式填了它；忘了填会穿上不去（能买、但点了没反应）。
@export var equip_type: EquipType = EquipType.NONE

## 返回 BBCode 富文本描述，供 RichTextLabel.set_text() 直接使用（支持 [color=...]、[code] 等标签）。
## 基类返回空串：因为"描述长什么样"完全取决于子类怎么解释自己的字段
##   （现在的 ItemEquipment 拼攻击/防御/生命/暴击/速度/格挡）。
## 参数：无（数据全在自身字段里）。
## 返回值：BBCode 字符串。
## 副作用：无。纯函数，不读 Global、不 emit 信号、不分配节点，可以在任何线程/任何时机安全调用。
func get_description() -> String:
	return ""


## 这件道具能穿到哪个栏位（返回 EquipType；NONE = 不能装备）。
## 做成函数而不是让调用方直接读 equip_type 字段：子类可以按自己的规则算
##   （例如以后做"某件装备只能穿副手"），调用方一行不用动。
## 参数：无。
## 返回值：int（EquipType 的成员值）。
## 副作用：无（纯读自身字段）。
func get_equip_type() -> int:
	return equip_type


## 栏位类型 → 中文名（"头盔"/"武器"/"腰带"/"项链"/"衣服"/"鞋子"）。
## 装备栏的空格子标签、提示文案、"穿上了「X」（武器栏）"这类消息都走它，
## 避免同一个名字在六个地方各写一份字符串。
## 参数 slot_type：EquipType 的成员值。
## 返回值：中文名；未知值兜底成"装备"（不报错，也不会显示成数字）。
## 副作用：无。
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


## 道具大类 → 中文名（"装备"/"武器"/"升级"/"被动"）。
## 悬停提示卡的类型行用它（以前直接显示枚举名，卡片上会出现 "EQUIPMENT" 这种英文）。
## 参数 item_type_value：ItemType 的成员值。
## 返回值：中文名；未知值兜底成"道具"。
## 副作用：无。
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

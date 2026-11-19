## ═══════════════════════════════════════════════════════════════════════════
## HoverItemCard —— 道具/武器的悬停提示卡（当前正式使用的那一张）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   由 autoload TooltipManager 统一托管（autoloads/tooltip_manager.gd）：
##     register(ItemBase, hover_item_card.tscn, &"item")
##   登记的是**基类 ItemBase**，而 TooltipManager._find_entry() 会沿 get_base_script()
##   往上爬着找登记项，所以 ItemWeapon / ItemPassive / ItemUpgrade 全都能命中它。
##
## 数据流：
##   TooltipManager._get_card() 懒加载出卡片并 add_child 到自己的 CanvasLayer
##     → _bind() 执行 `card.set("item", data)`（就是下面这个 setter）
##     → setter 更新四个展示节点，标题按品质上色
##   之后 TooltipManager 负责延迟、淡入、定位；本文件不碰位置，也不管鼠标事件
##   （TooltipManager 会把整棵子树的 mouse_filter 设成 IGNORE，否则提示卡一出现就会
##    触发下面卡片的 mouse_exited，导致疯狂闪烁）。
##
## 与同目录另外两张卡的区别：
##   · hover_card.gd    —— 最早的一版，已无人引用（且 setter 没判空）；
##   · hover_unit_card.gd —— 展示 UnitStats（角色属性），登记键 UnitStats，属性名 "unit"；
##   · 本文件           —— 展示 ItemBase（道具/武器），登记键 ItemBase，属性名 "item"。
##   三个场景的节点结构/唯一名完全一致，所以脚本可以互相顶替，但**属性名不同**，
##   换脚本就必须同步改 TooltipManager 里的登记参数，否则 _bind 会灌到不存在的属性上。
##
## 坑：
##   · 场景固定卡片宽度，绑定数据时立即按正文高度调整卡片，供 TooltipManager 定位。
##   · setter 里用了 %ItemIcon 等 @onready 变量，所以必须"先进树、后赋值"。
##     TooltipManager 的顺序恰好是对的（_get_card 里 add_child 之后才 _bind）；
##     如果谁自己在 add_child 之前赋值，会拿到 null 报错。
extends Panel
class_name HoverItemCard

# 旧：@export var item: ItemWeapon: set = _set_item
# 类型放宽到 ItemBase，这样武器和被动道具能共用同一张提示卡
## 要展示的道具数据。用 setter 形式（set = _set_item）：TooltipManager 只要 `card.set("item", data)`
## 就能把整张卡刷好，卡片脚本不需要提供 bind() 方法。
## 类型是基类 ItemBase —— 这是"一张卡同时服务武器和被动道具"的关键（见上面那行旧注释）。
## 变量名必须是 "item"：TooltipManager 登记时写死的属性名就是 &"item"。
@export var item: ItemBase: set = _set_item

## 四个 % 前缀节点都是 unique_name_in_owner（.tscn 里勾了"访问为唯一名称"），
## 用 % 取值不受父子层级调整影响。
## item_desc 是 RichTextLabel，直接吃 ItemBase.get_description() 返回的 BBCode 串
## （各子类自己实现：武器拼伤害/冷却/射程/暴击，被动拼加减属性）。
## ── 节点引用 ──────────────────────────────────────────────────────────────
@onready var item_icon: TextureRect = %ItemIcon
@onready var item_name: Label = %ItemName
@onready var item_type: RichTextLabel = %ItemType
@onready var item_desc: RichTextLabel = %ItemDesc
@onready var content_margin: MarginContainer = $MarginContainer

## item 的 setter：把道具数据灌进卡片。
## 参数 value：要展示的 ItemBase；传 null 时**提前返回**（卡片保持上一次的内容，
##   也就是说"清空提示"不是传 null 给它，而是调 TooltipManager.hide_tip()）。
## 返回值：无。
## 副作用：
##   · 写四个子控件，底板使用场景里的统一样式；
##   · 不 emit 信号、不改 Global 的任何字段。
## 时序：被 TooltipManager._bind() 在"卡片已 add_child、但可能还没显示"时调用，
##   所以这里只准备内容，可见性与位置由 TooltipManager 决定。
## 关于第一行 `item = value`：这是把值写回属性本体。用 `set = 函数` 的写法时，
##   在 setter 内部对同一属性再赋值**不会**递归调用 setter（Godot 4 的文档明确保证），
##   否则这里就无限递归爆栈了。
# 旧：func _set_item(value: ItemWeapon) -> void:
func _set_item(value: ItemBase) -> void:
	item = value
	# 判空必须放在最前面：TooltipManager 在换目标/收起时可能把数据清成 null，
	# 这里直接返回就不会去访问 value 的字段（老版本 hover_card.gd 少了这一步，会报错）。
	if value == null:
		return
	item_icon.texture = value.item_icon
	item_name.text = value.item_name
	# 装备名按品质上色（原来是单独一行「品质：橙色品质」，太占地方）
	item_name.add_theme_color_override("font_color", ItemBase.tier_color(int(value.item_tier)))
	var slot_type: int = value.get_equip_type()
	if slot_type != ItemBase.EquipType.NONE:
		var shown := ItemBase.equip_type_name(slot_type)
		# 武器再细分到具体类型（剑/刀/扇/枪/杖/爪），玩家一眼知道谁能用
		if slot_type == ItemBase.EquipType.WEAPON:
			var eq := value as ItemEquipment
			if eq != null:
				var detail := ItemEquipment.weapon_type_name(eq.weapon_type)
				if not detail.is_empty():
					shown = detail
		var lines: Array[String] = ["【部位】%s" % shown]
		if value is ItemEquipment:
			var e := value as ItemEquipment
			lines.append("【装备条件】等级 %d" % e.req_level)
			if not e.req_characters.is_empty():
				lines.append("【装备角色】%s" % e.req_characters)
		item_type.text = "\n".join(lines)
	else:
		item_type.text = "【%s】" % ItemBase.item_type_name(value.item_type)
	if value is ItemEquipment:
		var stat_font_size := item_desc.get_theme_font_size("normal_font_size") + 2
		item_desc.text = value.get_equipment_description(stat_font_size)
	else:
		item_desc.text = value.get_description()
	item_desc.size.y = item_desc.get_content_height()
	size.y = item_desc.position.y + item_desc.size.y + content_margin.get_minimum_size().y

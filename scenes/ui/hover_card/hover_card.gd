## ═══════════════════════════════════════════════════════════════════════════
## HoverCard —— 道具悬停提示卡（**最早的一版**，目前没有被任何场景使用）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置（现状要看清）：
##   本脚本只被 scenes/ui/hover_card/hover_card.tscn 引用，而**没有任何 .tscn / .gd
##   再去引用 hover_card.tscn**（全工程搜 "hover_card.tscn" 无结果）。也就是说：
##   它是一份"停用的历史版本"，留着当参考；真正在跑的两张卡是
##     · hover_item_card.gd（道具/武器提示，TooltipManager 登记为 ItemBase → 属性 item）
##     · hover_unit_card.gd（角色属性提示，TooltipManager 登记为 UnitStats → 属性 unit）
##   三者场景结构几乎一样（都是 Panel + MarginContainer/Control + %ItemIcon/%ItemName/
##   %ItemType/%ItemDesc），差别只在 setter 里的字段读取和有没有判空。
##
## 数据流：
##   ItemBase 子类（.tres 资源）→ 本脚本的 _set_shop_item(value)
##     → 写 %ItemIcon.texture / %ItemName.text / %ItemType.text / %ItemDesc.text
##     → 用 item_tier 去 Global.get_tier_style() 拿 StyleBoxFlat 当面板样式。
##   它不做定位、不做淡入淡出、不读鼠标 —— 那些是外部（旧方案里的调用方）的事，
##   这也是它被 TooltipManager 取代的原因。
##
## 坑（这份代码是"反面教材"，改的时候别照抄）：
##   · _set_shop_item() **没有判空**：赋 null 会在 `value.item_icon` 处直接报错。
##     后一版的 hover_item_card.gd 补了 `if value == null: return`，对比一下就知道为什么。
##   · setter 里用了 %ItemIcon 等 @onready 变量，所以**必须先 add_child() 再赋值**；
##     如果在节点还没进场景树时就 `card.shop_item = xxx`（或 .tscn 里预存了这个导出值），
##     @onready 还是 null，会报 "Cannot set property 'texture' on a null instance"。
##   · @export 的 setter 在**编辑器里改值**时也会被调用，那时节点不在树里 —— 同样会炸。
##     这也是为什么后两版把赋值统一挪到"入树之后由 TooltipManager 灌数据"。
extends Panel
class_name HoverCard

## 要展示的道具数据。用 setter 形式（`set = _set_shop_item`）而不是 connect 信号：
## 赋值的瞬间就把卡片内容刷好，调用方只需一行 `card.shop_item = item`。
## 类型是基类 ItemBase，所以武器(ItemWeapon)/升级(ItemUpgrade)/被动(ItemPassive) 都能塞进来。
## （变量名里的 shop 是历史遗留 —— 它并不只服务商店。）
@export var shop_item: ItemBase: set = _set_shop_item

## 四个 % 前缀的节点都是 unique_name_in_owner（在 .tscn 里勾了"访问为唯一名称"），
## 所以能从任意层级用 % 直接取，不受父子层级变化影响 —— 比 $MarginContainer/Control/... 稳。
## item_desc 是 RichTextLabel，吃 BBCode（ItemBase.get_description() 返回的就是 BBCode 串）。
@onready var item_icon: TextureRect = %ItemIcon
@onready var item_name: Label = %ItemName
@onready var item_type: Label = %ItemType
@onready var item_desc: RichTextLabel = %ItemDesc

## shop_item 的 setter：把道具数据"灌"进卡片的四个控件，并按稀有度换面板描边。
## 参数 value：要展示的 ItemBase（null 会崩，见文件头的坑）。
## 返回值：无（setter 的返回值被忽略；最后一行也不写 `shop_item = value` 之外的 return）。
## 副作用：
##   · 写四个子控件（texture / text）；
##   · add_theme_stylebox_override("panel", ...) 改本 Panel 的样式 ——
##     注意 Global.get_tier_style() 返回的是**共享的 const 资源本体**，这里只是把它挂上去读，
##     千万别在卡片里再去改它的 border_width 之类属性，那会污染全局所有同稀有度的卡片。
## 执行时机：任何对 shop_item 赋值的时候。赋值前本节点必须在场景树里（@onready 才有值）。
func _set_shop_item(value: ItemBase) -> void:
	shop_item = value
	item_icon.texture = value.item_icon
	item_name.text = value.item_name
	# ItemType 是枚举（WEAPON=0 / UPGRADE=1 / PASSIVE=2，定义在 item_base.gd）。
	# keys() 返回成员名数组，用整数下标取出名字 —— 这样 UI 上显示的是 "WEAPON" 这种英文枚举名，
	# 而不是数字。⚠ 下标来自 .tres 里存的整数，枚举成员一旦调整顺序，所有旧资源都会静默错位。
	item_type.text = ItemBase.ItemType.keys()[value.item_type]
	item_desc.text = value.get_description()
	
	# 按稀有度取描边样式（COMMON/RARE/EPIC/LEGENDARY → 四个预制的 StyleBoxFlat 常量）。
	# "panel" 是 Panel 的主题项名；ItemCard 因为是 Button，覆盖的是 "normal" 而不是 "panel"。
	var style := Global.get_tier_style(value.item_tier)
	add_theme_stylebox_override("panel", style)

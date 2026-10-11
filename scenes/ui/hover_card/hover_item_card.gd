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
##     → setter 写四个 % 节点 + 按 item_tier 换 Panel 样式
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
##   · 本卡片的尺寸必须由 .tscn 的 custom_minimum_size 固定住，且**不能放进任何 Container** ——
##     否则第一帧 size 还是 0，TooltipManager._place() 会按 0 尺寸算位置而错位。
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
@onready var item_type: Label = %ItemType
@onready var item_desc: RichTextLabel = %ItemDesc

## item 的 setter：把道具数据灌进卡片。
## 参数 value：要展示的 ItemBase；传 null 时**提前返回**（卡片保持上一次的内容，
##   也就是说"清空提示"不是传 null 给它，而是调 TooltipManager.hide_tip()）。
## 返回值：无。
## 副作用：
##   · 写四个子控件；add_theme_stylebox_override("panel", ...) 换本 Panel 的样式；
##   · Global.get_tier_style() 返回的是共享 const StyleBoxFlat，只挂不改（改它会污染全局同档次卡片）；
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
	# 枚举转名字：ItemType 是 WEAPON=0 / UPGRADE=1 / PASSIVE=2，keys() 拿到成员名数组再按下标取，
	# 所以卡上显示的是 "WEAPON" 这样的英文枚举名，而不是数字。
	# ⚠ 下标存在 .tres 里，枚举成员顺序一改，所有旧资源都会静默错位显示。
	item_type.text = ItemBase.ItemType.keys()[value.item_type]
	item_desc.text = value.get_description()
	
	# 按稀有度换面板描边（"panel" 是 Panel 控件的主题项名；Button 类要覆盖 "normal"）
	var style := Global.get_tier_style(value.item_tier)
	add_theme_stylebox_override("panel", style)

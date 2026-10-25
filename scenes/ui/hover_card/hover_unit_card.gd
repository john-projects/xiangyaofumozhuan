## ═══════════════════════════════════════════════════════════════════════════
## HoverUnitCard —— 角色（UnitStats）悬停提示卡：血/攻/速/格挡一览
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   由 autoload TooltipManager 统一托管（autoloads/tooltip_manager.gd）：
##     register(UnitStats, hover_unit_card.tscn, &"unit")
##   ⚠ 现在**没有任何界面在用这张卡**：以前唯一的调用方是选人界面（SelectionPanel，
##   已随竞技场删除）。TooltipManager 里的登记还留着，所以只要谁调
##     TooltipManager.show_for_control(某个控件, 某个 UnitStats)
##   就能直接弹出角色属性卡（队伍管理面板以后想加"点成员看属性"接一行就够）。
##
## 数据流：
##   UnitStats（.tres 资源，只读展示）→ _set_unit(value)
##     → %ItemIcon.texture / %ItemName.text / %ItemDesc.text（BBCode 拼属性表）
##   它**不写**任何游戏状态，也不按 item_tier 换样式（角色没有稀有度）——
##   这是它与 hover_item_card.gd 最大的差别（后者会 add_theme_stylebox_override）。
##
## 坑：
##   · _set_unit() **没有判空**：传 null 会在 `value.icon` 处直接报错。
##     调用方（TooltipManager.show_for_control / show_for）在 data 为 null 时会走
##     hide_tip() 分支，所以正常流程传不进来 null；但自己手动赋值前请先判空。
##   · setter 里用了 %ItemIcon 等 @onready 变量，必须"先进树、后赋值"
##     （TooltipManager._get_card 里是 add_child 之后才 _bind，顺序正确）。
##   · 下面那个多行字符串的**续行必须顶格写**（源码里没有缩进），因为缩进会被原样
##     写进 RichTextLabel 的文本里；顺手补 tab 会让提示卡里凭空多出空白。
##   · %ItemType 这个 Label 在场景里存在、脚本里也声明成了 item_type，但**从来没有被赋值** ——
##     角色卡不分"类型"，所以那个 Label 一直显示场景里的默认文本（通常是空的）。
##     看到它空着不是 bug；要清理的话记得 .tscn 里的节点和这里的变量一起删。
extends Panel
class_name HoverUnitCard

## 要展示的角色数据。setter 形式（set = _set_unit）：TooltipManager 只要 card.set("unit", data) 即可。
## 变量名必须是 "unit" —— TooltipManager 登记时写死的属性名就是 &"unit"。
## 注意这里存的是**资源（UnitStats）**，不是场上的 Unit 节点；选人阶段角色还没被实例化。
@export var unit: UnitStats: set = _set_unit

## 四个 % 前缀节点都是 unique_name_in_owner。item_type 见上面的坑（声明了但没用）。
@onready var item_icon: TextureRect = %ItemIcon
@onready var item_name: Label = %ItemName
@onready var item_type: Label = %ItemType
@onready var item_desc: RichTextLabel = %ItemDesc


## unit 的 setter：把角色数值灌进卡片。
## 参数 value：要展示的 UnitStats（null 会崩，见文件头的坑）。
## 返回值：无。
## 副作用：
##   · 写 %ItemIcon / %ItemName / %ItemDesc 三个控件；
##   · **不**读不写 Global，**不** emit 信号，**不**改样式（角色没有稀有度）；
##   · 第一行 `unit = value` 只是把值写回属性本体 —— 用 `set = 函数` 写法时，
##     setter 内部对同一属性再赋值不会递归调用 setter，否则会无限递归。
func _set_unit(value: UnitStats) -> void:
	unit = value
	item_icon.texture = value.icon
	item_name.text = value.name
	# RichTextLabel 吃 BBCode：
	#   [code]...[/code] 用等宽字体显示（属性表对齐好看）；
	#   [color=green]...[/color] 给数值上绿色。
	# 三个 %s 依次吃 health / damage / speed（数组顺序必须与占位符一一对应）。
	# 单位口径（见 resources/units/unit_stats.gd）：health/damage 是普通数值，speed 是每秒像素（默认 300）。
	# ⚠ 从下一行开始的续行在源码里是**顶格**的，缩进会被原样写进字符串，别顺手补 tab。
	item_desc.text = "[code]Health: [color=green]%s[/color]
Damage: [color=green]%s[/color]
Speed: [color=green]%s[/color][/code]" % [
		Global.format_stat(value.health),
		Global.format_stat(value.damage),
		Global.format_stat(value.speed),
	]

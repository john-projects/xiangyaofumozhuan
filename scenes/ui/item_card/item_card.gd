## ═══════════════════════════════════════════════════════════════════════════
## ItemCard —— 商店里"已经买到手"的小道具卡（被动 / 武器各占一格）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   它显示的是"背包里已拥有"的东西，而不是在卖的候选（在卖的候选是 ShopCard）。
##   工厂只有一处：ShopPanel.create_item_card()，那里统一实例化、连信号、并返回；
##   ShopPanel 再把它 add 进 %PassivesContainer（被动）或 %WeaponsContainer（武器）。
##   全工程只有 ShopPanel 在用 Global.ITEM_CARD_SCENE 实例化它（见 global.gd 的常量注释）。
##
## 数据流：
##   ShopPanel._on_item_purchased(item) / create_item_weapon(weapon) / 合成后的新武器
##     → card.item = 对应的 ItemBase
##     → _set_item() 贴图标 + 按 item_tier 换按钮样式
##   → 玩家点它 → _on_pressed() → 只有**武器**才 emit on_item_card_selected(self)
##     → ShopPanel._on_item_card_selected(card) 记住 context_card 并决定"合成/卖出"按钮可不可用。
##
## 信号（都由本卡片 emit，ShopPanel 订阅）：
##   · on_item_card_selected(card)：点选（仅武器；被动道具是纯展示、不可合成也不可卖）
##   · on_item_card_hover(card)：鼠标进入（旧方案的入口；现在实际用的是 ShopPanel 在创建时
##     直接连 card.mouse_entered，两条连接会同时触发，见下面 _on_mouse_entered 的说明）
##
## 坑：
##   · 根节点是 **Button**，所以样式覆盖的键是 "normal" 而不是 Panel 用的 "panel"。
##   · item_card.tscn 里把 `pressed` 和 `mouse_entered` 都用编辑器自连到了本脚本
##     （[connection ... from="." to="."]）。这意味着 mouse_entered 上至少有**两个**订阅者：
##     .tscn 连的 _on_mouse_entered（放音效 + emit on_item_card_hover）和 ShopPanel 代码里连的
##     _on_item_card_hover_started（弹 TooltipManager 提示）。删/改其中一个前先想清楚另一个。
##   · _set_item() 没有判空，`item = null` 会在 `item.item_icon` 处报错；
##     而 ShopPanel 的写法（先 add_child 再赋值）也说明本卡片**必须先入树**，@onready 才有值。
extends Button
class_name ItemCard

## 玩家点选了这张卡（只有武器会 emit）。参数回传自身，方便调用方拿它当"当前选中项"的锚点。
signal on_item_card_selected(card: ItemCard)
## 鼠标进入这张卡。参数回传自身 —— 旧方案靠它找到对应的数据对象，新方案（TooltipManager）
## 用的是 bind() 提前把数据和卡片绑好，所以这条信号目前主要是给外部扩展用的。
signal on_item_card_hover(card: ItemCard)

## 这张卡代表哪个道具。用 setter 形式，赋值即刷新。
## 类型是基类 ItemBase，武器/被动都塞得进来 —— 靠 item_type 区分行为（见 _on_pressed）。
@export var item: ItemBase: set = _set_item
## $ItemIcon 是**普通子节点路径**：item_card.tscn 里的 ItemIcon 没有勾 unique_name_in_owner，
## 所以不能用 %ItemIcon。@onready 在 _ready() 之前是 null。
@onready var item_icon: TextureRect = $ItemIcon


## item 的 setter：贴图标 + 按稀有度换按钮描边。
## 参数 value：要展示的 ItemBase（null 会崩，没有判空）。
## 返回值：无。
## 副作用：
##   · 写 item_icon.texture；
##   · add_theme_stylebox_override("normal", ...) 改本 Button 在**普通状态**下的样式
##     （Button 的主题项是 normal/hover/pressed/disabled，这里只覆盖 normal，
##      所以按下去时看到的仍是主题默认的 pressed 样式）；
##   · 样式来自 Global.get_tier_style()，返回的是共享 const 资源，只挂不改。
## 关于第一行 `item = value`：`set = 函数` 写法下，setter 内部对同一属性再赋值不会递归。
## 注意紧接着那行用的是 `item`（属性）而不是 `value`（形参）—— 因为上一步已经写回，
##   两者此刻等价；万一将来把第一行删掉，那行读到的就是**旧值**，会成为一个隐蔽的 bug。
func _set_item(value: ItemBase) -> void:
	item = value
	item_icon.texture = item.item_icon

	# 按稀有度取描边样式。注意键名是 "normal"（Button 的主题项），
	# 和 ShopCard / HoverItemCard 这些 Panel 用的 "panel" 不一样 —— 抄代码时最容易错这里。
	var style := Global.get_tier_style(item.item_tier)
	add_theme_stylebox_override("normal", style)

## 点击回调（item_card.tscn 里用编辑器把 Button.pressed 自连到本函数）。
## 参数：无。
## 返回值：无。
## 副作用：
##   · 播一次 UI 音效（SoundManager 是 autoload，内部自己找 AudioStreamPlayer 播放）；
##   · **只有 WEAPON 类型**才 emit on_item_card_selected(self)；
##     被动道具（PASSIVE）点下去只响一声，什么也不发生 —— 因为它不可合成也不可卖，
##     所以 ShopPanel 不会把 context_card 设成它，"合成/卖出"按钮保持禁用。
## 坑：`item` 为 null 时（卡还没赋值）这一行会报错；但 ShopPanel 总是先 add_child 再赋值，
##   而且 Button 在赋值前就可点，属于理论上的边界情况。
func _on_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	if item.item_type == ItemBase.ItemType.WEAPON:
		on_item_card_selected.emit(self)

## 鼠标进入回调（item_card.tscn 里编辑器自连的 mouse_entered → 本函数）。
## 参数：无。返回值：无。
## 副作用：
##   · 播一次 UI 音效（和 _on_pressed 同一个音，鼠标划过一张卡就会响一次）；
##   · emit on_item_card_hover(self)。
## 注意：mouse_entered 上还挂着 ShopPanel 在创建卡片时用代码连的 _on_item_card_hover_started
##   （它负责让 TooltipManager 弹提示卡）。两条连接互不依赖，顺序按连接先后。
func _on_mouse_entered() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	on_item_card_hover.emit(self)

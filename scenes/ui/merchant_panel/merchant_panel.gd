extends Control
class_name MerchantPanel

## 商人面板：把**武器**摆成方格卖（MapNPC.Action.SELL_WEAPONS 用）。
##
## ── 版面（从上到下）──
##   ① 名字（**居中**，例如"商人"）
##   ② 结果提示（"买下了 X（-12 金币）。" / "卖掉了 X（+9 金币）。" / "金币不够…"；没消息时是空行）
##   ③ **6 列方格货架**（总共 6×20 = 120 格，一屏 6×10 = 60 格，其余靠滚动；
##      现有 44 把武器只占前 44 格，剩下的是空格子）
##   没有台词行、没有金币行、没有按键提示、也没有「关闭」按钮（按要求都移除了）：
##   关交易用 Esc / B（见 WorldMap 的输入状态机），余额看**并排的背包**那一行信息。
##   货架的格子跟**背包**是同一种格子：同样按稀有度描边、悬停/焦点同样弹那张属性卡
##   （hover_item_card，走 TooltipManager）。区别只有两点：
##     · 格子上多了价格角标（右下）和"已持有 ×n"角标（左上）；
##     · 点一下**先弹确认框**（价格/买后余额），确认了才真的买。
##
## ── 买卖都走这里 ──
##   买：点货架格子 → 确认框 → `buy_requested`。
##   卖：点**背包**里的格子 → WorldMap 调 `ask_sell()` → 同一个确认框（换措辞）→ `sell_requested`。
##   两个方向共用 `%ConfirmBox`，靠 `_pending_is_sell` 分流；确认框开着时货架不可聚焦，
##   并通过 `confirm_changed` 让 WorldMap 把背包格子的焦点也收起来（模态）。
##
## ── 没有全屏遮罩（重要）──
##   本面板**故意不带 `Dim`**（早先有，已删）：交易时背包是**可交互**的（要能点着卖东西），
##   而全屏 ColorRect 默认会吃掉鼠标事件、还会把并排的背包压暗 —— 那是"背包看起来不能点"的元凶。
##   世界地图的压暗由背包那一层（0.35）负责，交易窗口自己有实底面板，不靠遮罩也看得清。
##
## ── 位置 ──
##   屏幕**最左边**（左下角锚点，距左边/下边 WINDOW_MARGIN）。交易时背包会**同时打开**并贴在
##   屏幕最右边（见 WorldMap._open_merchant）：一左一右，天然不重叠，谁也不用给谁让位。
##   位置与尺寸都是**代码算出来的**（_apply_window_geometry），.tscn 里的 offset 只是编辑器预览值
##   —— 理由同背包：高度依赖"一屏几行 + 标题/台词/提示"这些常量，写死迟早对不上；
##   视口变小时还要自动少显示几行，免得顶出屏幕。
##
## ── 在系统里的位置 ──
##   纯 UI 场景：由 WorldMap._setup_overlays() 实例化后挂在它的 UI（CanvasLayer）下面。
##   本文件**不改钱、不改背包**：确认购买后只 emit buy_requested(weapon)，
##   真正的校验与扣款在 GameRoot（weapon_can_buy / buy_weapon），买完 GameRoot 回调
##   WorldMap.notify_shop_changed()，WorldMap 让本面板按新状态重建。
##
## ── 货架从哪来 ──
##   MapNPC.sell_pool 优先；留空 → Global.get_all_weapons()（递归扫
##   res://resources/items/weapons/，当前 44 把 = 11 种武器 × 4 阶，按价格升序）。
##
## ── 买不起的格子和"两个提示叠一起"的坑 ──
##   能不能买由 GameRoot.weapon_can_buy() 统一判定（金币不够 / 背包满 BAG_SLOTS 格）：
##     · **买得起**的格子 → 接属性卡（悬停/焦点都弹），**不设** tooltip_text；
##     · **买不起**的格子 → 置灰 + 价格角标转红 + `tooltip_text` 写明原因，**不接属性卡**。
##   一条格子只走一种提示，所以不会出现"属性卡 + 原生 tooltip"两个框同时冒出来。
##   老版 ShopCard"点了没反应"的毛病这里没有：买不起一定有理由，且一定看得见。
##
## ── 键盘 ──
##   方向键由 Godot 的 GUI 焦点系统按几何位置走；W A S D 走 Global.grid_nav()
##   （上下 = 上一行同一列，中间夹着买不起的格子也会自动跳过）。
##   方格语义归本面板自己管，所以 WorldMap 的商人分支**不**替它处理 WASD，只接 Esc / E
##   （E = 按下焦点上的那一格：买得起的格子弹确认框、确认框里的「确定」就是真买）。
##   Esc 的层级：**先关确认框，再关交易窗口** —— 由 WorldMap 调 cancel_confirm() 判断。

## 确认购买后 emit：参数是要买的武器（ItemWeapon 资源，不是节点）。
signal buy_requested(weapon: ItemWeapon)
## 确认卖出后 emit：参数是要卖的武器（由**背包**点选、本面板只负责弹确认框）。
## 为什么要绕这一圈：卖出规则（能不能卖、卖多少）属于 GameRoot，界面只发请求；
##   而"确认框"只有交易窗口有，所以背包点选 → WorldMap → 本面板 ask_sell() → 确认后 emit 这个。
signal sell_requested(weapon: ItemWeapon)
## 确认框开了/关了（true = 开着）。WorldMap 收到后会同步把**背包格子**的键盘焦点收起来/放开
##   —— 确认是一次模态询问，这时不该还能用方向键跑到背包上按 E。
signal confirm_changed(open: bool)
## 关掉面板回到地图。**当前没有任何按钮发它**（「关闭」按钮已按要求移除，关闭靠 Esc / B）——
## 保留是为了以后加「关闭」这类按钮时直接接上，WorldMap 那边也已经连好了。
signal close_requested

## 货架一行几格（和背包一致）。改这个值要同时改 .tscn 里 GridContainer 的 columns。
const GRID_COLUMNS := 6
## 一屏显示几行（用户要求 6×10）。现有 44 把武器一屏看一半，其余靠滚动
## （滚轮 / 键盘往下走，follow_focus 自动滚）。
const VISIBLE_ROWS := 10
## 货架**总行数**：6 列 × 20 行 = 120 格（用户要求"总共展示 6×20"）。
## 现有 44 把武器只占前 44 格，剩下 76 格是空格子 —— 和背包一样把空格画出来
## （一眼看得出这个商人一共有多少格、还剩多少空位）；一屏只看得到 10 行，其余靠滚动。
const TOTAL_ROWS := 20
## 货架总格数（= GRID_COLUMNS × TOTAL_ROWS）。
const SHELF_SLOTS := GRID_COLUMNS * TOTAL_ROWS
## 格子之间的间距（横向纵向都用它，尺寸能按格数精确算出来）。
const GRID_SEPARATION := 10
## 格子边长（像素）。**84 是按 1920×1080 反推的**：现在一屏要显示 10 行，
## 10×84 + 9×10 = 930 是能塞进 1080 的最大值（面板总高 1038，y = 26~1064；
## 顺带和背包面板的 1044 几乎一样高，两个窗口并排看着齐）。
## 宽度 6×84 + 间距 + 滚动条 + 内边距 = 610，和背包的 662 也在同一档。
const SLOT_SIZE := 84.0
## 角标高度（价格 / 已持有），也是图标往上让位的量。
const TAG_HEIGHT := 20.0

## 窗口离屏幕右边/下边的留白，以及面板内部的四边留白（1080 高要省着用）。
const WINDOW_MARGIN := 16.0
const WINDOW_PADDING := 20.0
const WINDOW_PADDING_V := 16.0
## 各固定行的预留高度（名字行 / 提示行），用于算窗口总高。
## 台词行、金币行、按键提示行、关闭按钮行都已按需求移除，所以常量也不留了。
const HEADER_ROW_HEIGHT := 34.0
const MESSAGE_ROW_HEIGHT := 26.0
## VBox 里各块之间的间距（.tscn 里也是这个值；现在只有"名字 / 提示 / 货架"三块 → 2 道）。
const VBOX_SEPARATION := 8.0
## 给竖直滚动条留的宽度，免得第 6 列被它挤掉。
const SCROLLBAR_ALLOWANCE := 16.0

@onready var title_label: Label = %TitleLabel
@onready var message_label: Label = %MessageLabel
@onready var grid: GridContainer = %Grid
## 滚动容器。用 get_node_or_null 而不是 `%Scroll` 直取：场景万一被编辑器的旧副本覆盖
## （%Scroll 丢了），直取会在 null 上崩；这里降级成"货架不能滚"并喊一声。
@onready var scroll: ScrollContainer = get_node_or_null(^"%Scroll") as ScrollContainer
## 确认购买框（默认隐藏，点格子才弹）。缺节点时降级成"点了直接买"（见 _ask_confirm）。
@onready var confirm_box: Panel = get_node_or_null(^"%ConfirmBox") as Panel
@onready var confirm_label: Label = get_node_or_null(^"%ConfirmLabel") as Label
@onready var confirm_buy_button: Button = get_node_or_null(^"%ConfirmBuyButton") as Button
@onready var confirm_cancel_button: Button = get_node_or_null(^"%ConfirmCancelButton") as Button

## 购买按钮上的动词。WorldMap 打开本面板前用 MapNPC.shop_label 赋值（默认"购买"）。
## 放在成员变量而不是 show_shop() 的参数里：那是"面板配置"，不是"这一屏的数据"。
var buy_label := "购买"

## 当前"买得起"的格子（= 能聚焦的那些）。关闭按钮也会进焦点环。
var _slots: Array[Control] = []
## 正在等确认的那件武器（null = 没有确认框在开）。
var _pending: ItemWeapon = null
## 待确认的是"卖"（true）还是"买"（false）。确认框付款时按它分流。
var _pending_is_sell := false
## 最近一次算出来的窗口尺寸（window_width() 给背包算"并排偏移"用）。
var _window_size := Vector2.ZERO


func _ready() -> void:
	hide()
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override("h_separation", GRID_SEPARATION)
	grid.add_theme_constant_override("v_separation", GRID_SEPARATION)
	if confirm_box != null:
		confirm_box.hide()
		confirm_buy_button.pressed.connect(_confirm_pending)
		confirm_cancel_button.pressed.connect(cancel_confirm)
	if scroll != null:
		scroll.follow_focus = true
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	else:
		push_warning("MerchantPanel：场景里找不到 %Scroll —— 货架将无法滚动。"
				+ "请重新打开 scenes/ui/merchant_panel/merchant_panel.tscn")
	_apply_window_geometry()
	# 窗口大小变了就重新摆一次（最右边锚点 + 必要时少显示几行）
	get_viewport().size_changed.connect(_apply_window_geometry)


## 按"货架 + 金币 + 已持有"重建整个方格并显示。
## 参数 p_title：面板顶部的名字（**居中**，用 NPC 的 display_name，例如"商人"）。
## 参数 weapons：在卖的武器（顺序就是显示顺序 —— 由 Global.get_all_weapons() 按价格排好）。
## 参数 coins：当前金币。**只用来判定"买不买得起"**（哪些格子置灰），界面上不再显示余额
##   —— 余额看并排的背包那一行（用户要求把交易界面自己的金币展示去掉）。
## 参数 owned：已持有的武器（Global.equipped_weapons，用来显示"已持有 ×n"）。
## 副作用：show()；收起确认框；改名字；清空并重建 %Grid（货 + 空格子，总数 SHELF_SLOTS）；
##        滚动回到顶部；重算窗口尺寸。
## 货架为空（NPC 没配 sell_pool 且武器目录也扫不到）时：在提示行说明原因，并把 120 个格子
##   全画成空格子 —— 版面尺寸保持一致，不会因为"没货"变成一个奇怪的小窗。
## ⚠ 刻意**不清空提示文字**（message_label）：买完是"先 show_message()、
##   再 call_deferred(show_shop)"（直接在按钮回调里重建会把正在发信号的按钮摘掉），
##   这里清一次玩家就永远看不到"买下了 XXX！"了。要清旧提示就调 clear_message()。
func show_shop(p_title: String, weapons: Array[ItemWeapon], coins: int,
		owned: Array[ItemWeapon]) -> void:
	show()
	_hide_confirm()          # 重建了货架，之前那件"待确认"的格子已经不存在了
	title_label.text = p_title
	_slots.clear()
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	if weapons.is_empty():
		show_message("（货架是空的：这个 NPC 的 sell_pool 没配，Global.WEAPON_DIR 里也没扫到武器）")
	# 先摆货（能买得起的才是可点的），再用空格子补满整个货架（6×20 = 120 格）
	for weapon in weapons:
		grid.add_child(_make_slot(weapon, coins, owned))
	for i in range(weapons.size(), SHELF_SLOTS):
		grid.add_child(_make_empty_slot())
	if scroll != null:
		scroll.scroll_vertical = 0        # 每次打开/重建都回到最上面那几行
	_apply_window_geometry()


## 在面板上显示一句提示（"买下了 XXX（-12 金币）。" / "金币不够…" 等）。
## 由 WorldMap.notify_shop_changed() 调用。
func show_message(text: String) -> void:
	message_label.text = text


## 清掉提示文字（WorldMap 每次打开本面板时调一次，免得看到上一次留下的旧提示）。
func clear_message() -> void:
	message_label.text = ""


## 窗口宽度（像素）。给 WorldMap 算"背包要往左挪多少"用 —— 两个窗口要并排不重叠。
func window_width() -> float:
	return _window_size.x


## 确认框开着吗？（WorldMap 判断 Esc 该关确认框还是关整个交易窗口）
func is_confirm_open() -> bool:
	return _pending != null


## 关掉确认框（取消购买）。Esc 与「取消」按钮都走这里。
## 返回值：true = 刚才确实关掉了一个确认框（WorldMap 据此决定"这次 Esc 就到这儿"）。
func cancel_confirm() -> bool:
	if _pending == null:
		return false
	_hide_confirm()
	return true


## 按视觉顺序返回可聚焦的控件：所有"当前买得起"的格子。
## 买不起的格子是 disabled 的，grab_focus() 对它无效，所以必须排除（否则焦点会卡住不动）。
## 已经没有「关闭」按钮了（按需求移除），所以环里就只有货架格子。
func focus_ring() -> Array[Control]:
	return _slots.duplicate()


# ══════════════════════════════════════════════════════════
#  确认购买框
# ══════════════════════════════════════════════════════════

## 点货架格子 → 弹确认框（**不直接买**）。
## 参数 weapon：玩家点的那件武器。
## 副作用：显示确认框并把文字填成"名字 + 价格 + 买后余额"，焦点交给「确定」，
##        同时**把货架格子设成不可聚焦**（否则方向键会从确认框窜回货架）。
## ⚠ 已经在等一个确认时**直接返回**：不然连着点两件，待确认的那件会被悄悄换掉。
## ⚠ 层级：确认框在 .tscn 里设了 `z_index = 100` —— 交易时背包面板也开着，
##   按树序画下来可能会压住它，高 z_index 保证它永远画在最上面。
## 兜底：场景里没有确认框节点（旧副本被覆盖）时退化成"直接买"——功能仍在，只是少一步确认。
func _ask_confirm(weapon: ItemWeapon) -> void:
	if _pending != null:
		return
	if confirm_box == null or confirm_label == null:
		push_warning("MerchantPanel：场景里找不到 %ConfirmBox —— 本次购买跳过了确认框")
		buy_requested.emit(weapon)
		return
	var after := Global.coins - weapon.item_cost
	confirm_label.text = "买下「%s」？\n价格 %d 金币　·　买后剩 %d 金币" % [
		weapon.item_name, weapon.item_cost, after]
	_show_confirm(weapon, false)


## 背包里点了某件武器 → 弹**卖出**确认框（由 WorldMap 调用：它才知道现在是不是在交易）。
## 参数 weapon：要卖的武器。
## 参数 price：卖价（GameRoot.weapon_sell_price() 算好的，界面不自己算规则）。
## 副作用：与 _ask_confirm 一样（同一套确认框，只换措辞），确认后 emit sell_requested。
## 兜底：没有确认框节点时直接 emit sell_requested（少一步确认，但功能在）。
func ask_sell(weapon: ItemWeapon, price: int) -> void:
	if _pending != null:
		return
	if confirm_box == null or confirm_label == null:
		push_warning("MerchantPanel：场景里找不到 %ConfirmBox —— 本次卖出跳过了确认框")
		sell_requested.emit(weapon)
		return
	confirm_label.text = "卖出「%s」？\n卖价 %d 金币　·　卖后共 %d 金币" % [
		weapon.item_name, price, Global.coins + price]
	_show_confirm(weapon, true)


## 显示确认框的公共部分（买卖共用）。参数 weapon：待处理的武器；is_sell：是卖还是买。
## 副作用：记下待处理项、show()、禁用货架焦点、聚焦「确定」、收起属性卡、
##        并 emit confirm_changed(true)（WorldMap 据此把背包的格子焦点也收起来）。
func _show_confirm(weapon: ItemWeapon, is_sell: bool) -> void:
	_pending = weapon
	_pending_is_sell = is_sell
	confirm_box.show()
	_set_shelf_focus_enabled(false)
	confirm_buy_button.grab_focus()
	TooltipManager.hide_tip()      # 属性卡别和确认框挤在一起
	confirm_changed.emit(true)


## 确认：「确定购买」按钮，以及（焦点在它上面时的）E / Enter 都走这里。
## 按 _pending_is_sell 分流：买 → buy_requested；卖 → sell_requested。
func _confirm_pending() -> void:
	if _pending == null:
		return
	var weapon := _pending
	var is_sell := _pending_is_sell
	_hide_confirm()
	SoundManager.play_sound(SoundManager.Sound.UI)
	if is_sell:
		sell_requested.emit(weapon)
	else:
		buy_requested.emit(weapon)


## 收起确认框并恢复货架的焦点能力。
## 副作用：清待处理项、hide()、恢复货架焦点、emit confirm_changed(false)。
## ⚠ 这个函数只负责"收起"，**不 emit 买/卖请求** —— 请求由 _confirm_pending() 发，
##   取消（Esc / 「取消」）走这里就只是取消。
func _hide_confirm() -> void:
	_pending = null
	_pending_is_sell = false
	if confirm_box != null:
		confirm_box.hide()
	_set_shelf_focus_enabled(true)
	confirm_changed.emit(false)


## 货架格子能不能被键盘选中。
## 参数 enabled：false 时全部 FOCUS_NONE（鼠标悬停看属性、点着买不受影响）。
func _set_shelf_focus_enabled(enabled: bool) -> void:
	var mode := Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	for slot in _slots:
		(slot as Control).focus_mode = mode


# ══════════════════════════════════════════════════════════
#  货架格子
# ══════════════════════════════════════════════════════════

## 造一个货架格子（背包那种格子 + 价格角标；买得起才能点）。
## 参数 coins / owned：只用来算"能不能买""已持有几把"（判定本体在 GameRoot.weapon_can_buy）。
## 返回值：Button（买得起时接了 pressed 与属性卡；买不起时 disabled + tooltip 写原因）。
func _make_slot(weapon: ItemWeapon, coins: int, owned: Array[ItemWeapon]) -> Button:
	var slot := Button.new()
	slot.name = "Slot"
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.focus_mode = Control.FOCUS_ALL
	slot.icon = weapon.item_icon
	slot.expand_icon = true
	slot.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 描边跟稀有度走（和背包、提示卡一套配色；TIER_COLORS 是 Global 上的只读常量）
	var tier_color: Color = Global.TIER_COLORS.get(weapon.item_tier, Color(1, 1, 1, 0.4))
	slot.add_theme_stylebox_override("normal", _slot_style(tier_color, Color(1, 1, 1, 0.05)))
	slot.add_theme_stylebox_override("hover", _slot_style(tier_color, Color(1, 1, 1, 0.16)))
	slot.add_theme_stylebox_override("focus", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.18)))
	slot.add_theme_stylebox_override("pressed", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.24)))
	slot.add_theme_stylebox_override("disabled", _slot_style(Color(1, 1, 1, 0.14), Color(1, 1, 1, 0.03)))

	var reason := GameRoot.weapon_can_buy(weapon, coins, owned)
	# 价格角标（右下角）。买不起时转红，一眼能看出"哪些买不了"。
	slot.add_child(_make_tag(_price_text(weapon), false, reason.is_empty()))
	# "已持有"角标（左上角）：只在这把武器背包里有时才挂
	var have := GameRoot.weapon_owned_count(owned, weapon)
	if have > 0:
		slot.add_child(_make_tag("持×%d" % have, true, true))

	if reason.is_empty():
		slot.pressed.connect(_ask_confirm.bind(weapon))
		# 悬停 / 键盘焦点都弹同一张属性卡（TooltipManager 会把卡片锚到这个格子的右上角）
		slot.mouse_entered.connect(TooltipManager.show_for_control.bind(slot, weapon))
		slot.mouse_exited.connect(TooltipManager.hide_tip)
		slot.focus_entered.connect(TooltipManager.show_for_control.bind(slot, weapon))
		slot.focus_exited.connect(TooltipManager.hide_tip)
		_slots.append(slot)
	else:
		# 买不起：格子不可点、不接属性卡，改用原生 tooltip 说明"为什么买不了"
		slot.disabled = true
		slot.tooltip_text = reason
	return slot


## 造一个**空格子**：货架总格数是固定的 6×20，货不够就补空格（和背包一样把空格画出来）。
## 返回值：Button（disabled：不可点、不可聚焦、不弹属性卡，只有一圈暗描边）。
## 为什么不摆 Label 说明"这里是空的"：空格本身就是说明，摆文字反而比货还显眼。
func _make_empty_slot() -> Button:
	var slot := Button.new()
	slot.name = "EmptySlot"
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.disabled = true
	slot.add_theme_stylebox_override("disabled", _slot_style(Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.03)))
	return slot


## 格子上的小角标（价格 / 已持有）。
## 参数 text：角标文字。
## 参数 is_owned：true = 左上角的"已持有"角标（淡蓝），false = 右下角的价格角标（金/红）。
## 参数 affordable：价格角标的颜色 —— true 金色（买得起）、false 红色（买不起）。
## 说明：角标 mouse_filter 设成 IGNORE —— 它压在格子上，不能把鼠标事件吃掉，
##   否则格子的 mouse_entered（属性卡）会被它挡住。
func _make_tag(text: String, is_owned: bool, affordable: bool) -> Label:
	var tag := Label.new()
	tag.name = "OwnedTag" if is_owned else "PriceTag"
	tag.text = text
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_font_size_override("font_size", 14)
	tag.add_theme_stylebox_override("normal", _tag_style())
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.modulate = Color(0.75, 0.85, 1.0) if is_owned else \
			(Color(1, 0.86, 0.45) if affordable else Color(1, 0.45, 0.4))
	# 定位：锚在角上（左上 / 右下），尺寸固定，不参与容器布局
	if is_owned:
		tag.anchor_left = 0.0
		tag.anchor_right = 0.0
		tag.offset_left = 3.0
		tag.offset_right = 48.0
		tag.anchor_top = 0.0
		tag.anchor_bottom = 0.0
		tag.offset_top = 3.0
		tag.offset_bottom = 3.0 + TAG_HEIGHT
	else:
		tag.anchor_left = 1.0
		tag.anchor_right = 1.0
		tag.offset_left = -54.0
		tag.offset_right = -3.0
		tag.anchor_top = 1.0
		tag.anchor_bottom = 1.0
		tag.offset_top = -(TAG_HEIGHT + 3.0)
		tag.offset_bottom = -3.0
	return tag


## 格子的方形描边样式（和背包格子同一套观感）。
## 参数 border：描边颜色（按稀有度；置灰时是半透明白）。
## 参数 bg：底色（半透明，压在面板的深色背景上）。
## 实现细节：expand_icon 会把图标撑满按钮，所以内边距靠 StyleBox 的 content_margin 留出来；
##   这里**底部特意留出 TAG_HEIGHT 那么多**，免得图标被价格角标压住。
func _slot_style(border: Color, bg: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = int(TAG_HEIGHT) + 4
	return style


## 角标的底色样式（深色半透明 + 圆角，保证压在任何图标上都看得清）。
func _tag_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.62)
	style.set_corner_radius_all(5)
	return style


## 价格角标上的文字。item_cost 为 0 按约定是"非卖品"，这里显示成"免费"（白送）。
func _price_text(weapon: ItemWeapon) -> String:
	return "%d 金" % weapon.item_cost if weapon.item_cost > 0 else "免费"


# ══════════════════════════════════════════════════════════
#  窗口位置与尺寸（最右边，按视口自适应）
# ══════════════════════════════════════════════════════════

## 把面板摆到屏幕**最左边**，尺寸按内容算；视口不够高时先砍货架的可见行数。
## 为什么每次打开都调：窗口可能被玩家拉小过，而"一屏几行"要跟着变
##   （不然窗口高于屏幕时，标题会被顶到屏幕外）。
## 副作用：改 _window_size、scroll.custom_minimum_size.y、Panel 的 anchor/offset。
func _apply_window_geometry() -> void:
	var panel := get_node_or_null(^"Panel") as Panel
	if panel == null:
		return
	var view := get_viewport_rect().size
	var fixed := HEADER_ROW_HEIGHT + MESSAGE_ROW_HEIGHT \
			+ VBOX_SEPARATION * 2.0 + WINDOW_PADDING_V * 2.0 + WINDOW_MARGIN * 2.0
	var row_height := SLOT_SIZE + GRID_SEPARATION
	var rows := VISIBLE_ROWS
	if scroll != null:
		var rows_budget := int(floor((view.y - fixed + GRID_SEPARATION) / row_height))
		rows = clampi(rows_budget, 1, VISIBLE_ROWS)
		scroll.custom_minimum_size.y = rows * SLOT_SIZE + (rows - 1) * GRID_SEPARATION
	# 宽 = 6 列 + 滚动条 + 内边距（台词那行比这窄，不用参与比较）
	_window_size = Vector2(
			GRID_COLUMNS * SLOT_SIZE + (GRID_COLUMNS - 1) * GRID_SEPARATION
			+ SCROLLBAR_ALLOWANCE + WINDOW_PADDING * 2.0,
			fixed - WINDOW_MARGIN * 2.0 + rows * SLOT_SIZE + (rows - 1) * GRID_SEPARATION)
	# 锚到左下角：锚点 left=0 / top=1，offset 往右上"长"
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_END
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = WINDOW_MARGIN
	panel.offset_right = WINDOW_MARGIN + _window_size.x
	panel.offset_top = -(_window_size.y + WINDOW_MARGIN)
	panel.offset_bottom = -WINDOW_MARGIN
	# 货架居中（窗口比"6 列 + 滚动条"宽时，别把格子贴左边）
	if scroll != null and scroll.size_flags_horizontal != Control.SIZE_SHRINK_CENTER:
		scroll.size_flags_horizontal = Control.SIZE_SHRINK_CENTER


## 键盘补丁：W A S D 在方格上移动焦点（方向键交给 Godot 的几何导航）。
## 实现走 Global.grid_nav()，与**背包**共用同一套方格导航。
## 确认框开着时**不接管** WASD：那时焦点只在「确定 / 取消」两个按钮之间，
##   交给 Godot 的几何导航就够了（货架格子已临时设成不可聚焦，见 _ask_confirm）。
## E / Enter 不在这里处理：E 由 WorldMap 的商人分支接（→ Global.activate_focused()），
## Enter 是内置 ui_accept，GUI 自己会按。
func _unhandled_input(event: InputEvent) -> void:
	if not visible or is_confirm_open():
		return
	Global.grid_nav(event, self)

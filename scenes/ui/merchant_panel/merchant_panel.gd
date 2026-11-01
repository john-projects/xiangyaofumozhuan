extends Control
class_name MerchantPanel

## 商人面板：把装备（ItemBase / ItemEquipment）摆成方格卖（MapNPC.Action.SELL_WEAPONS 用）。
##
## 版面：名字居中 → 结果提示 → 6 列方格货架（6×20 = 120 格，一屏 6×10，其余靠滚动）；
## 没有台词/金币/按键提示/关闭按钮，关交易走 Esc / B，余额看并排的背包那一行。
## 位置：屏幕最左边（左下角锚点），交易时背包同时开在最右边；尺寸由代码按视口算，视口小就少显示几行。
## 本文件不改钱、不改背包：确认后只 emit 信号，校验与扣款在 GameRoot。
## ⚠ 根节点铺满全屏必须 mouse_filter = IGNORE，否则会吃掉并排背包的鼠标事件（.tscn 设了，_ready 再兜一次）。
## ⚠ 本面板故意不带全屏 Dim 遮罩：背包要能点，ColorRect 会吞事件并压暗背包。

## 确认购买后 emit：参数是要买的道具（ItemBase 资源，不是节点）。
signal buy_requested(item: ItemBase)
## 确认卖出后 emit（背包点选 → WorldMap → ask_sell() → 确认后发这个）；卖出规则属于 GameRoot。
signal sell_requested(item: ItemBase)
## 确认框开了/关了（true = 开着）。WorldMap 据此收起/放开背包格子的键盘焦点。
signal confirm_changed(open: bool)
## 关掉面板回到地图。当前没有按钮发它（关闭靠 Esc / B），保留给以后加「关闭」类按钮用。
## ⚠ @warning_ignore：类里没人 emit，编辑器报 "signal declared but never explicitly used" 是故意的。
@warning_ignore("unused_signal")
signal close_requested

## 货架一行几格（和背包一致）。改这个值要同时改 .tscn 里 GridContainer 的 columns。
const GRID_COLUMNS := 6
## 一屏显示几行（6×10）；货多了靠滚动（滚轮 / 键盘往下走，follow_focus 自动滚）。
const VISIBLE_ROWS := 10
## 货架总行数：6 列 × 20 行 = 120 格，货不足用空格补满（一屏只看得见 10 行）。
const TOTAL_ROWS := 20
## 货架总格数（= GRID_COLUMNS × TOTAL_ROWS）。
const SHELF_SLOTS := GRID_COLUMNS * TOTAL_ROWS
## 格子间距（横纵都用它，尺寸能按格数精确算出来）。
const GRID_SEPARATION := 10
## 格子边长（像素）。84 是按 1920×1080 反推的：10 行 = 10×84 + 9×10 = 930，能塞进 1080。
const SLOT_SIZE := 84.0
## 角标高度（价格 / 已持有），也是图标往上让位的量。
const TAG_HEIGHT := 20.0

## 窗口离屏幕右边/下边的留白。
const WINDOW_MARGIN := 16.0
## 面板内部左右留白。
const WINDOW_PADDING := 20.0
## 面板内部上下留白（1080 高要省着用）。
const WINDOW_PADDING_V := 16.0
## 名字行的预留高度（用于算窗口总高）。
const HEADER_ROW_HEIGHT := 34.0
## 提示行的预留高度（用于算窗口总高）。
## VBox 里各块之间的间距（.tscn 里同值；现在只有名字/提示/货架三块 → 2 道）。
const VBOX_SEPARATION := 8.0
## 给竖直滚动条留的宽度，免得第 6 列被它挤掉。
const SCROLLBAR_ALLOWANCE := 16.0

@onready var title_label: Label = %TitleLabel
## 弹窗消息栈（原来的顶部信息栏已移除）。
@onready var toast_stack: VBoxContainer = get_node_or_null(^"%ToastStack") as VBoxContainer
## 提示栈相对屏幕中心上移多少（与 WorldMap / PartyPanel 一致）。
const TOAST_RISE := 150.0
## 统一的弹窗消息外观（和地图提示共用一套）。
const UiToast := preload("res://scenes/shared/ui_toast.gd")
@onready var grid: GridContainer = %Grid
## 顶部页签条（按装备部位分类）。
@onready var tabs: HBoxContainer = get_node_or_null(^"%Tabs") as HBoxContainer
## 页签下方那条横线：选中页签位置留缺口，表示下面全是这个页签的货。
@onready var rule_row: Control = get_node_or_null(^"%RuleRow") as Control
## 托架折线（左右各一条 Line2D，横线 + 圆弧 + 竖线连成一根）。
@onready var line_left: Line2D = get_node_or_null(^"%LineLeft") as Line2D
@onready var line_right: Line2D = get_node_or_null(^"%LineRight") as Line2D
## 开口两侧向上的竖线：正好压在选中页签的左右边框上。

## 滚动容器。用 get_node_or_null 而不是 %Scroll 直取：旧副本丢了节点时降级成"不能滚"并喊一声。
@onready var scroll: ScrollContainer = get_node_or_null(^"%Scroll") as ScrollContainer
## 确认购买框（默认隐藏，点格子才弹）。缺节点时降级成"点了直接买"（见 _ask_confirm）。
@onready var confirm_box: Panel = get_node_or_null(^"%ConfirmBox") as Panel
@onready var confirm_label: Label = get_node_or_null(^"%ConfirmLabel") as Label
@onready var confirm_buy_button: Button = get_node_or_null(^"%ConfirmBuyButton") as Button
@onready var confirm_cancel_button: Button = get_node_or_null(^"%ConfirmCancelButton") as Button

## 购买按钮上的动词。WorldMap 打开面板前用 MapNPC.shop_label 赋值（默认"购买"）。
var buy_label := "购买"

## 当前"买得起"的格子（= 能聚焦的那些）。
var _slots: Array[Control] = []
## 本次上架的全部商品（页签只做过滤，原表不动）。
var _all_items: Array[ItemBase] = []
var _owned: Array[ItemBase] = []
var _coins := 0
## 当前页签的部位（EquipType 值）；-1 = 还没定。
var _active_type := -1
var _tab_buttons: Array[Button] = []
## 正在等确认的那件道具（null = 没有确认框在开）。
var _pending: ItemBase = null
## 待确认的是"卖"（true）还是"买"（false）。确认框付款时按它分流。
var _pending_is_sell := false
## 最近一次算出来的窗口尺寸（window_width() 给背包算并排偏移用）。
var _window_size := Vector2.ZERO
## 当前焦点停在哪件商品上（item_key）。重建货架后用它把焦点抓回去。
var _focus_key := ""
## 当前焦点格子在货架里的序号（找不到同款商品时按序号兜底）。
var _focus_index := -1
## 重建后要不要恢复滚动位置（首次打开时应回到顶部）。
var _restore_scroll := false


func _ready() -> void:
	# 根节点铺满全屏，必须忽略鼠标，否则并排的背包收不到任何事件；只影响根节点自己，子节点照常接管。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide()
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override("h_separation", GRID_SEPARATION)
	grid.add_theme_constant_override("v_separation", GRID_SEPARATION)
	if confirm_box != null:
		confirm_box.hide()
		if confirm_buy_button != null:
			confirm_buy_button.pressed.connect(_confirm_pending)
		if confirm_cancel_button != null:
			confirm_cancel_button.pressed.connect(cancel_confirm)
	if scroll != null:
		scroll.follow_focus = true
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	else:
		push_warning("MerchantPanel：场景里找不到 %Scroll —— 货架将无法滚动。"
				+ "请重新打开 scenes/ui/merchant_panel/merchant_panel.tscn")
	_apply_window_geometry()
	# 窗口大小变了就重新摆一次（左下锚点 + 必要时少显示几行）。
	get_viewport().size_changed.connect(_apply_window_geometry)


## 按"货架 + 金币 + 已持有"重建方格并显示（副作用：show、收确认框、重建 %Grid、滚动回顶、重算尺寸）。
## 参数：p_title 名字；items 在卖的东西（顺序即显示顺序）；coins 只用于判买得起；owned 用于"持×n"。
## ⚠ 刻意不清空 message_label：买完是先 show_message() 再 deferred 重建，清了就永远看不到提示。
	# 窗口大小一变，页签会重排，横线缺口也要跟着重算
	if rule_row != null:
		rule_row.resized.connect(_update_tabs_rule)



func show_shop(p_title: String, items: Array[ItemBase], coins: int,
		owned: Array[ItemBase]) -> void:
	# 先记下这次是重新打开还是买完重建：重建时保留滚动位置与选中格，
	# 真正打开商店时才回到顶部、回到第一格。
	var was_visible := visible
	show()
	_hide_confirm()          # 重建了货架，之前那件"待确认"的格子已经不存在了
	title_label.text = p_title
	_all_items = items
	_coins = coins
	_owned = owned
	_rebuild_tabs()
	_rebuild_shelf()
	_restore_scroll = was_visible
	if scroll != null:
		# 重建（买完东西）时保留原来的滚动位置；真正"打开商店"时才回到顶部
		if not _restore_scroll:
			scroll.scroll_vertical = 0
	_apply_window_geometry()
	_restore_focus(_visible_items())


## 按「部位」生成页签。只有一种部位时不显示页签条（武器商这种）。
func _rebuild_tabs() -> void:
	for child in tabs.get_children():
		tabs.remove_child(child)
		child.queue_free()
	_tab_buttons.clear()
	var types := _types_in_stock()
	tabs.visible = types.size() > 1
	if types.is_empty():
		return
	if not types.has(_active_type):
		_active_type = types[0]
	for slot_type in types:
		var button := Button.new()
		button.text = _tab_label(slot_type)
		button.toggle_mode = true
		button.button_pressed = slot_type == _active_type
		button.focus_mode = Control.FOCUS_ALL
		button.custom_minimum_size = Vector2(72 if slot_type >= WEAPON_TAB_BASE else 96, 28)
		button.pressed.connect(_on_tab_pressed.bind(slot_type))
		tabs.add_child(button)
		_tab_buttons.append(button)
	# 等这一帧布局算完再画，否则拿到的还是旧坐标
	_update_tabs_rule.call_deferred()


## 页签键：武器用 100 + weapon_type（避开 EquipType 的 1~8），其它用 equip_type。
## 这样武器商能按剑/刀/扇/枪/杖/爪 分页，防具商仍按部位分页。
const WEAPON_TAB_BASE := 100
## 开口两侧竖线往上延伸多少（压在选中页签的左右边框上，形成 ⊓ 托架）。
const BRACKET_HEIGHT := 12.0
## 托架线宽（与选中页签描边一致，略粗一点更清楚）。
const LINE_THICKNESS := 3.0
## 拐角圆弧半径（越大越圆）。
const CORNER_RADIUS := 10.0
## 圆角用多少段折线逼近（越大越圆）。
const CORNER_SEGMENTS := 8


func _tab_key(item: ItemBase) -> int:
	var slot_type: int = item.get_equip_type()
	if slot_type == ItemBase.EquipType.WEAPON:
		var eq := item as ItemEquipment
		if eq != null and eq.weapon_type > 0:
			return WEAPON_TAB_BASE + eq.weapon_type
	return slot_type


## 货架里出现过的页签键，排序：先部位（1~8），再武器类型（101~）。
func _types_in_stock() -> Array[int]:
	var out: Array[int] = []
	for item in _all_items:
		var key := _tab_key(item)
		if key != ItemBase.EquipType.NONE and not out.has(key):
			out.append(key)
	out.sort()
	return out


## 页签键 → 显示名。
func _tab_label(key: int) -> String:
	if key >= WEAPON_TAB_BASE:
		return ItemEquipment.weapon_type_name(key - WEAPON_TAB_BASE)
	return ItemBase.equip_type_name(key)


## 当前页签要显示的商品。
func _visible_items() -> Array[ItemBase]:
	var out: Array[ItemBase] = []
	for item in _all_items:
		if _tab_key(item) == _active_type:
			out.append(item)
	# 等级 → 品质 → 名字：同一套的五种品质挨在一起，再往上是下一套
	out.sort_custom(Global.equip_sort_less)
	return out


## 点页签：切类目、重建货架、焦点落到新货架第一件。
func _on_tab_pressed(slot_type: int) -> void:
	if slot_type == _active_type:
		return
	SoundManager.play_sound(SoundManager.Sound.UI)
	_active_type = slot_type
	# 页签是 toggle_mode 的按钮，要手动做成"单选"：只有当前部位那个是按下态
	var types := _types_in_stock()
	for i in _tab_buttons.size():
		if i < types.size():
			_tab_buttons[i].button_pressed = types[i] == _active_type
	_focus_key = ""
	_focus_index = 0
	_rebuild_shelf()
	_update_tabs_rule.call_deferred()
	if scroll != null:
		scroll.scroll_vertical = 0
	_apply_window_geometry()
	_restore_focus(_visible_items())


## 按当前页签重建货架（商品格 + 补满空格）。
func _rebuild_shelf() -> void:
	_slots.clear()
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	var items := _visible_items()
	if items.is_empty() and _all_items.is_empty():
		show_message("（货架是空的：这个 NPC 的 sell_pool 没配，Global.EQUIPMENT_DIR 里也没扫到装备）")
	# 先摆货（能买得起的才是可点的），再用空格子补满整个货架（6×20 = 120 格）
	for item in items:
		grid.add_child(_make_slot(item, _coins, _owned))
	for i in range(items.size(), SHELF_SLOTS):
		grid.add_child(_make_empty_slot())


func _restore_focus(items: Array[ItemBase]) -> void:
	if _slots.is_empty():
		return
	var target: Control = null
	if not _focus_key.is_empty():
		for slot in _slots:
			if String(slot.get_meta("item_key", "")) == _focus_key:
				target = slot
				break
	if target == null and _focus_index >= 0 and _focus_index < _slots.size():
		target = _slots[_focus_index]
	if target == null:
		return
	# grab_focus 对隐藏控件静默失败，所以调用前必须已经 show()（show_shop 开头已 show）
	target.grab_focus()
	if scroll != null:
		# 让这一格滚进可视范围（ensure_control_visible 由 ScrollContainer 提供）
		scroll.ensure_control_visible(target)


## 在面板上显示一句提示（"买下了 XXX（-12 金币）。" / "金币不够…" 等），由 WorldMap 调用。



## 清掉提示文字（WorldMap 每次打开本面板时调一次，免得看到上一次留下的旧提示）。



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


## 商品的唯一键：名字 + 稀有度。和 GameRoot.item_owned_count() 的判定口径一致，
## 所以"同一件商品"在重建前后能对上号。
func _item_key(item: ItemBase) -> String:
	return "%s#%d" % [item.item_name, item.item_tier]


## 按视觉顺序返回可聚焦控件：所有"当前买得起"的格子。
## 买不起的格子是 disabled 的，grab_focus() 对它无效，必须排除（否则焦点会卡住不动）。
func focus_ring() -> Array[Control]:
	return _slots.duplicate()


# ── 确认购买框 ──

## 点货架格子 → 弹确认框（不直接买）：填"名字 + 价格 + 买后余额"，焦点交给「确定」。
## 副作用：显示确认框、临时禁用货架焦点（否则方向键会窜回货架）、收起属性卡。
## ⚠ 已在等一个确认时直接返回（不然连着点两件，待确认的那件会被悄悄换掉）；缺节点时退化成直接买。
func _ask_confirm(item: ItemBase) -> void:
	if _pending != null:
		return
	if confirm_box == null or confirm_label == null:
		push_warning("MerchantPanel：场景里找不到 %ConfirmBox —— 本次购买跳过了确认框")
		buy_requested.emit(item)
		return
	var after := Global.coins - item.item_cost
	confirm_label.text = "买下「%s」？\n价格 %d 金币　·　买后剩 %d 金币" % [
		item.item_name, item.item_cost, after]
	_show_confirm(item, false)


## 背包点了某件东西 → 弹**卖出**确认框（WorldMap 调，它才知道现在是不是在交易）。
## 参数：item 要卖的道具；price 卖价（GameRoot.item_sell_price() 算好的，界面不自己算规则）。
## 兜底：没有确认框节点时直接 emit sell_requested（少一步确认，但功能在）。
func ask_sell(item: ItemBase, price: int) -> void:
	if _pending != null:
		return
	if confirm_box == null or confirm_label == null:
		push_warning("MerchantPanel：场景里找不到 %ConfirmBox —— 本次卖出跳过了确认框")
		sell_requested.emit(item)
		return
	confirm_label.text = "卖出「%s」？\n卖价 %d 金币　·　卖后共 %d 金币" % [
		item.item_name, price, Global.coins + price]
	_show_confirm(item, true)


## 显示确认框的公共部分（买卖共用）：记待处理项、按 is_sell 换「确定」措辞、禁用货架焦点。
## 副作用：show()、聚焦「确定」、收起属性卡、emit confirm_changed(true)（WorldMap 据此收背包焦点）。
func _show_confirm(item: ItemBase, is_sell: bool) -> void:
	_pending = item
	_pending_is_sell = is_sell
	confirm_box.show()
	# 买卖共用同一个确认框，按钮上的动词得跟着换：卖东西时还写着"确定购买"很容易点错。
	if confirm_buy_button != null:
		confirm_buy_button.text = "确定卖出" if is_sell else "确定%s" % buy_label
	_set_shelf_focus_enabled(false)
	if confirm_buy_button != null:
		confirm_buy_button.grab_focus()
	TooltipManager.hide_tip()      # 属性卡别和确认框挤在一起
	confirm_changed.emit(true)


## 确认：「确定购买」按钮，以及（焦点在它上面时的）E / Enter 都走这里。
## 按 _pending_is_sell 分流：买 → buy_requested；卖 → sell_requested。
func _confirm_pending() -> void:
	if _pending == null:
		return
	var item := _pending
	var is_sell := _pending_is_sell
	_hide_confirm()
	SoundManager.play_sound(SoundManager.Sound.UI)
	if is_sell:
		sell_requested.emit(item)
	else:
		buy_requested.emit(item)


## 收起确认框并恢复货架的焦点能力。
## 副作用：清待处理项、hide()、恢复货架焦点、emit confirm_changed(false)。
## ⚠ 只负责"收起"，**不 emit 买卖请求** —— 请求由 _confirm_pending() 发，取消走这里就只是取消。
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


# ── 货架格子 ──

## 造一个货架格子（背包那种格子 + 价格角标；买得起才能点）。
## 参数：item 这件货是什么；coins / owned 只用来算"能不能买""已持有几件"（判定本体在 GameRoot.item_can_buy）。
## 返回值：Button（买得起时接了 pressed 与属性卡；买不起时 disabled + tooltip 写原因）。
func _make_slot(item: ItemBase, coins: int, owned: Array[ItemBase]) -> Button:
	var slot := Button.new()
	slot.name = "Slot"
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.focus_mode = Control.FOCUS_ALL
	slot.icon = item.item_icon
	slot.expand_icon = true
	slot.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 描边跟稀有度走（和背包、提示卡一套配色；TIER_COLORS 是 Global 上的只读常量）
	var tier_color: Color = Global.TIER_COLORS.get(item.item_tier, Color(1, 1, 1, 0.4))
	# 底色也跟品质走：同一色相、极低透明度，让每档一眼能分出来又不压住图标
	var tier_bg := _tier_bg(tier_color, 0.30)
	var tier_bg_hover := _tier_bg(tier_color, 0.48)
	slot.add_theme_stylebox_override("normal", _slot_style(tier_color, tier_bg))
	slot.add_theme_stylebox_override("hover", _slot_style(tier_color, tier_bg_hover))
	slot.add_theme_stylebox_override("focus", _slot_style(Color(1, 0.9, 0.5, 1.0), _tier_bg(tier_color, 0.42)))
	slot.add_theme_stylebox_override("pressed", _slot_style(Color(1, 0.9, 0.5, 1.0), _tier_bg(tier_color, 0.55)))

	var reason := GameRoot.item_can_buy(item, coins, owned)
	# 价格角标（右下角）。金币不够时仍标红，但现在**不置灰格子** ——
	# 只要看得到就能点开属性卡，真的买不起时再在确认框里提示。
	slot.add_child(_make_tag(_price_text(item), false, reason.is_empty()))

	# 所有格子一律可点、可聚焦、可弹属性卡
	slot.set_meta("item_key", _item_key(item))
	var idx := _slots.size()
	slot.focus_entered.connect(func() -> void:
		_focus_key = _item_key(item)
		_focus_index = idx)
	slot.pressed.connect(_ask_confirm.bind(item))
	slot.mouse_entered.connect(TooltipManager.show_for_control.bind(slot, item))
	slot.mouse_exited.connect(TooltipManager.hide_tip)
	slot.focus_entered.connect(TooltipManager.show_for_control.bind(slot, item))
	slot.focus_exited.connect(TooltipManager.hide_tip)
	_slots.append(slot)
	return slot


## 造一个**空格子**：货架总格数固定 6×20，货不够就补空格（和背包一样把空格画出来）。
## 返回值：Button（disabled：不可点、不可聚焦、不弹属性卡，只有一圈暗描边）。
func _make_empty_slot() -> Button:
	var slot := Button.new()
	slot.name = "EmptySlot"
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.disabled = true
	slot.add_theme_stylebox_override("disabled", _slot_style(Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.03)))
	return slot


## 格子上的小角标（价格 / 已持有）。
## 参数：text 文字；is_owned true = 左上"已持有"（淡蓝），false = 右下角价格（金/红）；affordable 价格色。
## ⚠ mouse_filter = IGNORE：它压在格子上，不能吃掉格子的 mouse_entered（否则属性卡会被挡）。
func _make_tag(text: String, is_owned: bool, affordable: bool) -> Label:
	var tag := Label.new()
	tag.name = "OwnedTag" if is_owned else "PriceTag"
	tag.text = text
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_font_size_override("font_size", 13)
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
		tag.offset_left = -78.0
		tag.offset_right = -3.0
		tag.anchor_top = 1.0
		tag.anchor_bottom = 1.0
		tag.offset_top = -(TAG_HEIGHT + 3.0)
		tag.offset_bottom = -3.0
	return tag


## 格子的方形描边样式（和背包格子同一套观感）。
## 参数：border 描边色（按稀有度；置灰时是半透明白）；bg 底色（压面板深色背景）。
## 底部特意留出 TAG_HEIGHT 的 content_margin，免得 expand_icon 撑满后图标被价格角标压住。
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
func _price_text(item: ItemBase) -> String:
	var cost := item.item_cost
	if cost <= 0:
		return "免费"
	# 万位以上简写，格子只有 84px 宽，五位数字放不下
	if cost >= 10000:
		return "%.1f万" % (float(cost) / 10000.0)
	return "%d 金" % cost


# ── 窗口位置与尺寸（最左边，按视口自适应）──

## 把面板摆到屏幕**最左边**，尺寸按内容算；视口不够高时先砍货架的可见行数。
## 为什么每次打开都调：窗口可能被玩家拉小过，"一屏几行"要跟着变（不然标题会被顶到屏幕外）。
## 副作用：改 _window_size、scroll.custom_minimum_size.y、Panel 的 anchor/offset。
func _apply_window_geometry() -> void:
	var panel := get_node_or_null(^"Panel") as Panel
	if panel == null:
		return
	var view := get_viewport_rect().size
	var fixed := HEADER_ROW_HEIGHT \
			+ VBOX_SEPARATION * 2.0 + WINDOW_PADDING_V * 2.0 + WINDOW_MARGIN * 2.0
	var row_height := SLOT_SIZE + GRID_SEPARATION
	var rows := VISIBLE_ROWS
	if scroll != null:
		var rows_budget := int(floor((view.y - fixed + GRID_SEPARATION) / row_height))
		rows = clampi(rows_budget, 1, VISIBLE_ROWS)
		scroll.custom_minimum_size.y = rows * SLOT_SIZE + (rows - 1) * GRID_SEPARATION
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


## 键盘补丁：W A S D 在方格上移动焦点（方向键交给 Godot 的几何导航），走 Global.grid_nav()，与背包共用。
## 确认框开着时**不接管** WASD：货架格子已临时设成不可聚焦，焦点只在「确定 / 取消」之间。
## E / Enter 不在这里处理：E 由 WorldMap 的商人分支接（→ Global.activate_focused()），Enter 是内置 ui_accept。
func _unhandled_input(event: InputEvent) -> void:
	if not visible or is_confirm_open():
		return
	Global.grid_nav(event, self)


## 重画页签下面的横线：在选中页签的正下方留出缺口。
## 缺口位置按页签的**全局矩形**换算到 RuleRow 的局部坐标，窗口缩放/页签增减都跟得上。
## 重画页签下面的横线 + 开口两侧的竖线。
## 选中页签用 _active_type 在页签列表里的下标定位（不依赖 button_pressed，
## 刚重建完那一刻按钮状态可能还没同步）。
func _update_tabs_rule(retry := 3) -> void:
	if rule_row == null or line_left == null or line_right == null:
		return
	var width := rule_row.size.x
	if width <= 1.0:
		# 布局还没算完：等一帧再来
		if retry > 0:
			await get_tree().process_frame
			_update_tabs_rule(retry - 1)
		return
	var row_rect := rule_row.get_global_rect()

	# 找到选中页签
	var types := _types_in_stock()
	var index := types.find(_active_type)
	var target: Button = null
	if index >= 0 and index < _tab_buttons.size():
		target = _tab_buttons[index]
	if target == null or not is_instance_valid(target):
		# 兜底：再用 button_pressed 找一次
		for button in _tab_buttons:
			if is_instance_valid(button) and button.button_pressed:
				target = button
				break
	if target == null or not is_instance_valid(target):
		# 没有选中页签：画一条通栏直线，不留开口
		line_left.visible = false
		line_right.visible = true
		line_right.points = PackedVector2Array([
			Vector2(0.0, LINE_THICKNESS * 0.5),
			Vector2(width, LINE_THICKNESS * 0.5),
		])
		return

	var r := target.get_global_rect()
	var tab_left := r.position.x - row_rect.position.x
	var tab_right := r.end.x - row_rect.position.x
	# 页签底边在 RuleRow 上方，换成局部坐标是负数
	var tab_bottom := r.end.y - row_rect.position.y
	var gap_from := clampf(tab_left - 4.0, 0.0, width)
	var gap_to := clampf(tab_right + 4.0, 0.0, width)

	# 托架：左右各一条连续折线（横线 → 四分之一圆弧 → 竖线）
	var h := LINE_THICKNESS
	var radius := CORNER_RADIUS
	var y_line := h * 0.5
	var up_top := tab_bottom - BRACKET_HEIGHT
	var left_x := tab_left - h * 0.5
	var right_x := tab_right + h * 0.5

	if line_left != null:
		var pts := PackedVector2Array()
		pts.append(Vector2(0.0, y_line))
		pts.append(Vector2(maxf(0.0, left_x - radius), y_line))
		# 圆弧：圆心在左上，从正下(90°)扫到正右(0°)
		var cx := left_x - radius
		var cy := y_line - radius
		for i in range(CORNER_SEGMENTS + 1):
			var a := lerpf(PI * 0.5, 0.0, float(i) / float(CORNER_SEGMENTS))
			pts.append(Vector2(cx + cos(a) * radius, cy + sin(a) * radius))
		pts.append(Vector2(left_x, up_top))
		line_left.points = pts
		line_left.visible = true

	if line_right != null:
		var pts2 := PackedVector2Array()
		var rx := right_x
		var cx2 := rx + radius
		var cy2 := y_line - radius
		pts2.append(Vector2(width, y_line))
		pts2.append(Vector2(minf(width, cx2), y_line))
		# 镜像圆弧：从正下(90°)扫到正左(180°)
		for i in range(CORNER_SEGMENTS + 1):
			var a2 := lerpf(PI * 0.5, PI, float(i) / float(CORNER_SEGMENTS))
			pts2.append(Vector2(cx2 + cos(a2) * radius, cy2 + sin(a2) * radius))
		pts2.append(Vector2(rx, up_top))
		line_right.points = pts2
		line_right.visible = true


func _quarter_fan(center: Vector2, r: float, a0: float, a1: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.append(center)
	var segments := CORNER_SEGMENTS
	for i in range(segments + 1):
		var a := lerpf(a0, a1, float(i) / float(segments))
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts


func show_message(text: String) -> void:
	if toast_stack == null:
		return
	if text.strip_edges().is_empty():
		return
	for line in text.split("\n"):
		var one := line.strip_edges()
		if not one.is_empty():
			_add_toast_line(one)


func _add_toast_line(text: String) -> void:
	var box := UiToast.make_box(text)
	toast_stack.add_child(box)
	_layout_toast_stack()
	await get_tree().create_timer(UiToast.HOLD).timeout
	if not is_instance_valid(box):
		return
	var tween := create_tween()
	tween.tween_property(box, "modulate:a", 0.0, UiToast.FADE)
	await tween.finished
	if is_instance_valid(box):
		box.queue_free()
		_layout_toast_stack.call_deferred()


## 屏幕中央、整体上移 150px —— 与 WorldMap / PartyPanel 的提示栈同一个落点。
func _layout_toast_stack() -> void:
	if toast_stack == null:
		return
	toast_stack.offset_left = -UiToast.WIDTH * 0.5
	toast_stack.offset_right = UiToast.WIDTH * 0.5
	toast_stack.offset_top = -TOAST_RISE
	toast_stack.offset_bottom = toast_stack.get_combined_minimum_size().y - TOAST_RISE


## 清掉还在的提示（关面板时调，避免下次打开还挂着残影）。
func clear_message() -> void:
	if toast_stack == null:
		return
	for child in toast_stack.get_children():
		child.queue_free()
	_layout_toast_stack.call_deferred()


## 品质底色：取品质色的色相，把明度压暗、透明度压到 alpha，得到一个淡淡的染色底。
## 普通（白）没有配色，会走调用方的兜底色，不会调用本函数。
func _tier_bg(color: Color, alpha: float) -> Color:
	var c := Color(color.r, color.g, color.b, 1.0)
	return Color(c.r * 0.7, c.g * 0.7, c.b * 0.7, alpha)

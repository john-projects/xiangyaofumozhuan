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
const MESSAGE_ROW_HEIGHT := 26.0
## VBox 里各块之间的间距（.tscn 里同值；现在只有名字/提示/货架三块 → 2 道）。
const VBOX_SEPARATION := 8.0
## 给竖直滚动条留的宽度，免得第 6 列被它挤掉。
const SCROLLBAR_ALLOWANCE := 16.0

@onready var title_label: Label = %TitleLabel
@onready var message_label: Label = %MessageLabel
@onready var grid: GridContainer = %Grid
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
func show_shop(p_title: String, items: Array[ItemBase], coins: int,
		owned: Array[ItemBase]) -> void:
	# 先记下这次是重新打开还是买完重建：重建时保留滚动位置与选中格，
	# 真正打开商店时才回到顶部、回到第一格。
	var was_visible := visible
	show()
	_hide_confirm()          # 重建了货架，之前那件"待确认"的格子已经不存在了
	title_label.text = p_title
	_slots.clear()
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	if items.is_empty():
		show_message("（货架是空的：这个 NPC 的 sell_pool 没配，Global.EQUIPMENT_DIR 里也没扫到装备）")
	# 先摆货（能买得起的才是可点的），再用空格子补满整个货架（6×20 = 120 格）
	for item in items:
		grid.add_child(_make_slot(item, coins, owned))
	for i in range(items.size(), SHELF_SLOTS):
		grid.add_child(_make_empty_slot())
	_restore_scroll = was_visible
	if scroll != null:
		# 重建（买完东西）时保留原来的滚动位置；真正"打开商店"时才回到顶部
		if not _restore_scroll:
			scroll.scroll_vertical = 0
	_apply_window_geometry()
	_restore_focus(items)


## 重建货架后把焦点抓回"上一次看的那件商品"。
## 优先按商品键找（买完之后它可能因为"已持有"多了一个角标，但键不变）；
## 找不到就按序号兜底；再找不到就不动焦点（WorldMap 会调 _set_focus_ring 兜底）。
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
	slot.add_theme_stylebox_override("normal", _slot_style(tier_color, Color(1, 1, 1, 0.05)))
	slot.add_theme_stylebox_override("hover", _slot_style(tier_color, Color(1, 1, 1, 0.16)))
	slot.add_theme_stylebox_override("focus", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.18)))
	slot.add_theme_stylebox_override("pressed", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.24)))
	slot.add_theme_stylebox_override("disabled", _slot_style(Color(1, 1, 1, 0.14), Color(1, 1, 1, 0.03)))

	var reason := GameRoot.item_can_buy(item, coins, owned)
	# 价格角标（右下角）。买不起时转红，一眼能看出"哪些买不了"。
	slot.add_child(_make_tag(_price_text(item), false, reason.is_empty()))
	# "已持有"角标（左上角）：只在这件东西背包里有时才挂
	var have := GameRoot.item_owned_count(owned, item)
	if have > 0:
		slot.add_child(_make_tag("持×%d" % have, true, true))

	if reason.is_empty():
		slot.set_meta("item_key", _item_key(item))
		# 焦点进到这个格子就记住它，重建货架时把它抓回来
		var idx := _slots.size()
		slot.focus_entered.connect(func() -> void:
			_focus_key = _item_key(item)
			_focus_index = idx)
		slot.pressed.connect(_ask_confirm.bind(item))
		# 悬停 / 键盘焦点都弹同一张属性卡；买不起的格子不接，避免"属性卡 + 原生 tooltip"两个框一起冒。
		slot.mouse_entered.connect(TooltipManager.show_for_control.bind(slot, item))
		slot.mouse_exited.connect(TooltipManager.hide_tip)
		slot.focus_entered.connect(TooltipManager.show_for_control.bind(slot, item))
		slot.focus_exited.connect(TooltipManager.hide_tip)
		_slots.append(slot)
	else:
		# 买不起：格子不可点、不接属性卡，改用原生 tooltip 说明"为什么买不了"
		slot.disabled = true
		slot.tooltip_text = reason
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
	return "%d 金" % item.item_cost if item.item_cost > 0 else "免费"


# ── 窗口位置与尺寸（最左边，按视口自适应）──

## 把面板摆到屏幕**最左边**，尺寸按内容算；视口不够高时先砍货架的可见行数。
## 为什么每次打开都调：窗口可能被玩家拉小过，"一屏几行"要跟着变（不然标题会被顶到屏幕外）。
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

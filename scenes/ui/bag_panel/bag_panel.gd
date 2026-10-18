extends Control
class_name BagPanel

## 背包面板：方格背包（8 列 × 15 行 = 120 格）+ 角色区（形象 + 左右各 3 个装备栏）。
## 只读展示：不改游戏数据，点击只发信号，卖 / 穿 / 脱的规则由 WorldMap 与 GameRoot 决定。
## 角色区 ◀/▶ 只在团队名册里切换"看谁"，不动 Global.main_player_selected 与上阵名单。
## 窗口位置与尺寸由 _apply_window_geometry() 算出，不依赖 .tscn 里的 offset / 尺寸。
## 由 WorldMap._setup_overlays() 实例化后挂在 UI（CanvasLayer）下。

## 背包格子被点。卖还是穿由 WorldMap 按交易界面是否打开分流；item 是 ItemBase，兼容新装备类型。
signal item_activated(item: ItemBase)

## 已穿装备的栏位被点：请求脱下放回背包。参数是 ItemBase.EquipType 成员值。
signal unequip_requested(slot_type: int)

## 展示角色变了（◀/▶）。WorldMap 据此切换并排属性面板；本面板不 emit 反向同步。
signal character_view_changed(character: UnitStats)

## 关闭请求：当前没有按钮发它，保留给以后的「整理 / 关闭」按钮，WorldMap 已接好。
signal close_requested

## 每行格数。改这里要同步改 .tscn 里 GridContainer 的 columns。
const GRID_COLUMNS := 8
## 一屏显示的行数，只影响滚动区可见高度；视口不够时 _apply_window_geometry() 会自动调小。
## 总格数见 GameRoot.BAG_SLOTS（120），格子全部画出，其余靠滚动。
const VISIBLE_ROWS := 8
## 格子间距（横纵共用）。
const GRID_SEPARATION := 10
## 背包格子边长。68 是按 1920×1080 反推的上限；别和 EQUIP_SLOT_SIZE 合并。
const SLOT_SIZE := 68.0
## 图标内边距（expand_icon 时留边，避免贴描边）。
const SLOT_ICON_MARGIN := 8

## 形象左右各几个装备栏。
const EQUIP_SLOTS_PER_SIDE := 3
## 六个装备栏的固定顺序（左列→右列）。长度须为 EQUIP_SLOTS_PER_SIDE×2；类型定义在 ItemBase.EquipType。
const EQUIP_LAYOUT: Array[int] = [
	ItemBase.EquipType.HELMET,
	ItemBase.EquipType.WEAPON,
	ItemBase.EquipType.BELT,
	ItemBase.EquipType.NECKLACE,
	ItemBase.EquipType.ARMOR,
	ItemBase.EquipType.BOOTS,
]
## 栏位名行高；装备栏 StyleBox 的 content_margin_bottom 要留出这么多。
const EQUIP_LABEL_HEIGHT := 20.0
## 装备栏边长。比背包格子大：形象框要保持竖长，装备栏也更醒目。
const EQUIP_SLOT_SIZE := 96.0
## 形象框尺寸；高度 = 三个装备栏叠起来。
const PLAYER_FRAME_WIDTH := 240.0
const PLAYER_FRAME_HEIGHT := EQUIP_SLOTS_PER_SIDE * EQUIP_SLOT_SIZE \
		+ (EQUIP_SLOTS_PER_SIDE - 1) * GRID_SEPARATION
## 切换箭头尺寸。
const ARROW_WIDTH := 44.0
const ARROW_HEIGHT := 60.0
## 角色区各块之间的间距。
const PLAYER_ROW_SEPARATION := 16.0
## 角色区总高（金币已挪到信息行）。
const PLAYER_ROW_HEIGHT := PLAYER_FRAME_HEIGHT

## 窗口外边距与面板内边距（16 省高度）。
const WINDOW_MARGIN := 16.0
const WINDOW_PADDING := 16.0
const WINDOW_PADDING_V := 16.0
## 标题行 / 信息行的高度。
const TITLE_ROW_HEIGHT := 40.0
const INFO_ROW_HEIGHT := 26.0
## VBox 块间距（.tscn 同值）。
const VBOX_SEPARATION := 8.0
## 竖直滚动条预留宽度，免得挤掉最后一列。
const SCROLLBAR_ALLOWANCE := 16.0

@onready var coins_label: Label = %CoinsLabel
@onready var count_label: Label = %CountLabel
@onready var message_label: Label = %MessageLabel
@onready var grid: GridContainer = %Grid
## 角色区节点可能缺失（场景被旧副本覆盖），缺失就整块跳过。
@onready var player_view: TextureRect = get_node_or_null(^"%PlayerView") as TextureRect
@onready var player_fallback: Label = get_node_or_null(^"%PlayerFallback") as Label
@onready var player_name: Label = get_node_or_null(^"%PlayerNameLabel") as Label
@onready var prev_button: Button = get_node_or_null(^"%PrevPlayerButton") as Button
@onready var next_button: Button = get_node_or_null(^"%NextPlayerButton") as Button
@onready var left_slots: VBoxContainer = get_node_or_null(^"%LeftSlots") as VBoxContainer
@onready var right_slots: VBoxContainer = get_node_or_null(^"%RightSlots") as VBoxContainer

## 滚动容器由 _ensure_scroll() 解析：%Scroll 为 null 时直接取 custom_minimum_size 会崩。
var scroll: ScrollContainer

## 焦点环：只含有东西的背包格子。
var _slots: Array[Control] = []
## 已穿装备的装备栏（空栏位 disabled，不进焦点环）。
var _equip_slots: Array[Control] = []
## 格子是否允许拿焦点。刷新装备栏时要按它设 FOCUS_ALL/NONE，否则会冲掉交易确认框的模态状态。
var _slot_focus_enabled := true

## 展示中的团队名册（引用 WorldMap._party，只读）与下标；只决定"看谁 / 穿给谁"，不写回游戏数据。
var _party: Array[UnitStats] = []
var _view_index := 0


func _ready() -> void:
	hide()
	_ensure_scroll()          # 内部会把"可见行数 / 跟随焦点 / 禁横向滚动"都配好
	_build_equip_slots()
	if prev_button != null:
		prev_button.pressed.connect(_step_player.bind(-1))
	if next_button != null:
		next_button.pressed.connect(_step_player.bind(1))
	_refresh_player_view()
	grid.columns = GRID_COLUMNS
	# 间距也由代码统一设，保证尺寸算式和实际排布是同一套数字（.tscn 里填的会被这里覆盖）
	grid.add_theme_constant_override("h_separation", GRID_SEPARATION)
	grid.add_theme_constant_override("v_separation", GRID_SEPARATION)
	_apply_window_geometry()
	# 窗口大小变了就重新摆一次（右下角锚点 + 必要时少显示几行）
	get_viewport().size_changed.connect(_apply_window_geometry)


## 按背包内容重建方格并显示。items 只读；capacity 是总格数（空格也画）；members 是团队名册（引用）。
## 副作用：show、刷新金币/格数/装备栏、清空重建 %Grid、滚动回顶、重算窗口。
## ⚠ 不重置 _view_index、不清提示文字（买卖会连续重建）；要重置请显式调 reset_view() / clear_message()。
func show_bag(items: Array[ItemBase], capacity: int, members: Array[UnitStats] = []) -> void:
	show()
	_party = members
	# 名册可能变短（有人被移出团队）：下标越界就退回第一个人，避免展示/穿装备落到空角色上。
	if _view_index < 0 or _view_index >= _party.size():
		_view_index = 0
	_refresh_player_view()
	_refresh_equip_slots()    # 装备栏显示的是"当前展示的角色"那一套
	count_label.text = "背包　%d/%d" % [items.size(), capacity]
	coins_label.text = "金币：%d" % Global.coins
	_slots.clear()
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	for index in capacity:
		var item: ItemBase = items[index] if index < items.size() else null
		grid.add_child(_make_slot(item))
	scroll.scroll_vertical = 0        # 每次打开都回到顶部
	_apply_window_geometry()


## 把"正在看谁"重置回主角（打开背包时调；买卖引起的重建不调）。
func reset_view() -> void:
	_view_index = _index_of_leader()
	_refresh_player_view()
	_refresh_equip_slots()


## 切到指定角色（不重建方格、不重置滚动）。WorldMap 在属性面板换人时调；不在名册里则忽略。
## 副作用：改 _view_index 并刷新形象 / 装备栏；刻意不 emit，避免两个面板互相弹。
func show_character(character: UnitStats) -> void:
	var index := _index_of(character)
	if index < 0 or index == _view_index:
		return
	_view_index = index
	_refresh_player_view()
	_refresh_equip_slots()


## 只刷新金币（比重建 120 格省）。参数 -1 表示读 Global.coins。
func refresh_coins(coins := -1) -> void:
	coins_label.text = "金币：%d" % (Global.coins if coins < 0 else coins)


## 开关背包格子与已穿装备栏的键盘焦点。交易确认框弹出时关掉（模态只留确定 / 取消），平时开着。
func set_slot_focus_enabled(enabled: bool) -> void:
	_slot_focus_enabled = enabled
	var mode := Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	for slot in _slots:
		(slot as Control).focus_mode = mode
	for slot in _equip_slots:
		(slot as Control).focus_mode = mode
	for button in [prev_button, next_button]:
		if button != null and not button.disabled:
			button.focus_mode = mode


## 在信息行显示一句提示（留给卖出 / 合成）。
func show_message(text: String) -> void:
	message_label.text = text


## 清空提示文字（WorldMap 每次打开时调）。
func clear_message() -> void:
	message_label.text = ""


## 当前焦点环：有东西的背包格子 → 已穿装备栏 → 可用的切换箭头。W/S 走格只看 _slots。
func focus_ring() -> Array[Control]:
	var out: Array[Control] = _slots.duplicate()
	out.append_array(_equip_slots)
	for button in [prev_button, next_button]:
		if button != null and not button.disabled:
			out.append(button)
	return out


# ── 角色区（形象 + 左右各三个装备栏，每个角色各一套）──

## 造左右两排装备栏，只造一次。类型由 EQUIP_LAYOUT 决定，内容由 _refresh_equip_slots() 就地刷新。
## 缺容器时 push_warning 并跳过整块（场景可能被旧副本覆盖）。
func _build_equip_slots() -> void:
	if left_slots == null or right_slots == null:
		push_warning("BagPanel：场景里找不到 %LeftSlots / %RightSlots —— 已跳过装备栏那一块。"
				+ "请重新打开 scenes/ui/bag_panel/bag_panel.tscn")
		return
	var columns: Array[VBoxContainer] = [left_slots, right_slots]
	for col in columns.size():
		var container: VBoxContainer = columns[col]
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()
		for i in EQUIP_SLOTS_PER_SIDE:
			var layout_index := col * EQUIP_SLOTS_PER_SIDE + i
			var slot_type: int = EQUIP_LAYOUT[layout_index] if layout_index < EQUIP_LAYOUT.size() \
					else ItemBase.EquipType.NONE
			container.add_child(_make_equip_slot(slot_type))
	_refresh_equip_slots()


## 造装备栏格子的固定部分：尺寸、栏位名、事件接线。slot_type 写进 meta，刷新时靠它识别。
## 事件只接一次，内容变化不重连——这是"换角色不重建按钮"的关键。
func _make_equip_slot(slot_type: int) -> Button:
	var slot := Button.new()
	slot.name = "EquipSlot"
	slot.set_meta("slot_type", slot_type)
	slot.custom_minimum_size = Vector2(EQUIP_SLOT_SIZE, EQUIP_SLOT_SIZE)
	slot.expand_icon = true
	slot.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 栏位名（永远显示，玩家一眼知道这格收什么）
	var tag := Label.new()
	tag.name = "SlotTypeLabel"
	tag.text = ItemBase.equip_type_name(slot_type)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_font_size_override("font_size", 13)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_set_tag_bottom(tag)
	slot.add_child(tag)
	# 点一下 = 请求脱下（能不能脱、脱到哪由 GameRoot.unequip_slot() 判定）
	slot.pressed.connect(func() -> void: unequip_requested.emit(slot_type))
	# 悬停 / 键盘焦点弹属性卡。⚠ 这里**不能**把 item 绑定进去：换角色/换装备后 item 会变，
	# 而事件只连一次 —— 所以用函数调用，在弹出那一刻现取。
	slot.mouse_entered.connect(func() -> void: _show_equip_tip(slot, slot_type))
	slot.mouse_exited.connect(TooltipManager.hide_tip)
	slot.focus_entered.connect(func() -> void: _show_equip_tip(slot, slot_type))
	slot.focus_exited.connect(TooltipManager.hide_tip)
	return slot


## 按当前展示角色刷新 6 个装备栏（换人 / 穿 / 脱都走这里），并重建 _equip_slots 焦点环。
func _refresh_equip_slots() -> void:
	_equip_slots.clear()
	for container in [left_slots, right_slots]:
		if container == null:
			continue
		for child in container.get_children():
			var slot := child as Button
			if slot == null:
				continue
			_refresh_equip_slot(slot, int(slot.get_meta("slot_type", ItemBase.EquipType.NONE)))


## 刷新单个装备栏：空栏位清图标并 disabled、用原生 tooltip；有装备则画图标 + 稀有度描边 + 属性卡。
func _refresh_equip_slot(slot: Button, slot_type: int) -> void:
	var tag := slot.get_node_or_null("SlotTypeLabel") as Label
	var bottom_margin := int(EQUIP_LABEL_HEIGHT) + 4
	var character := current_character()
	var item: ItemBase = GameRoot.equipment_in(character, slot_type)

	if item == null:
		slot.icon = null
		slot.disabled = true
		slot.focus_mode = Control.FOCUS_NONE
		slot.add_theme_stylebox_override("disabled",
				_slot_style(Color(1, 1, 1, 0.14), Color(1, 1, 1, 0.03), bottom_margin))
		if tag != null:
			_set_tag_center(tag)
			tag.modulate = Color(1, 1, 1, 0.42)
		# 空栏位没有属性卡，用原生 tooltip 说明这个坑位怎么用（提到当前是谁的栏位）
		var who: String = character.name if character != null else "角色"
		slot.tooltip_text = "%s栏：把%s从背包里点一下就能给「%s」穿上" % [
			ItemBase.equip_type_name(slot_type), ItemBase.equip_type_name(slot_type), who]
		return

	# 有装备：图标 + 稀有度描边（和背包格子、提示卡一套配色）
	slot.icon = item.item_icon
	slot.disabled = false
	slot.focus_mode = Control.FOCUS_ALL if _slot_focus_enabled else Control.FOCUS_NONE
	slot.tooltip_text = ""      # 有属性卡就不再设原生 tooltip，免得两个框叠一起
	var tier_color: Color = Global.TIER_COLORS.get(item.item_tier, Color(1, 1, 1, 0.4))
	slot.add_theme_stylebox_override("normal", _slot_style(tier_color, Color(1, 1, 1, 0.07), bottom_margin))
	slot.add_theme_stylebox_override("hover", _slot_style(tier_color, Color(1, 1, 1, 0.18), bottom_margin))
	slot.add_theme_stylebox_override("focus", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.18), bottom_margin))
	slot.add_theme_stylebox_override("pressed", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.24), bottom_margin))
	if tag != null:
		_set_tag_bottom(tag)
		tag.modulate = Color(1, 1, 1, 0.85)
	_equip_slots.append(slot)


## 悬停 / 聚焦装备栏时弹属性卡。item 必须现取（事件只连一次，换人 / 换装备后会变）。
func _show_equip_tip(slot: Control, slot_type: int) -> void:
	var item: ItemBase = GameRoot.equipment_in(current_character(), slot_type)
	if item != null:
		TooltipManager.show_for_control(slot, item)


## 栏位名缩到格子底部（有装备时用）。
func _set_tag_bottom(tag: Label) -> void:
	tag.anchor_left = 0.0
	tag.anchor_right = 1.0
	tag.anchor_top = 1.0
	tag.anchor_bottom = 1.0
	tag.offset_left = 2.0
	tag.offset_right = -2.0
	tag.offset_top = -(EQUIP_LABEL_HEIGHT + 2.0)
	tag.offset_bottom = -2.0


## 栏位名居中铺满格子（空栏位用）。
func _set_tag_center(tag: Label) -> void:
	tag.anchor_left = 0.0
	tag.anchor_right = 1.0
	tag.anchor_top = 0.0
	tag.anchor_bottom = 1.0
	tag.offset_left = 2.0
	tag.offset_right = -2.0
	tag.offset_top = 0.0
	tag.offset_bottom = 0.0


## 当前展示的角色（团队为空时退回主角）。决定装备栏显示谁、点背包穿给谁；纯读。
func current_character() -> UnitStats:
	if _view_index >= 0 and _view_index < _party.size():
		var member: UnitStats = _party[_view_index]
		if member != null:
			return member
	return Global.main_player_selected


## 刷新形象 / 名字 / 箭头可用状态。贴图取 UnitStats.icon，与地图一致；不改任何游戏数据。
func _refresh_player_view() -> void:
	if player_view == null or player_fallback == null:
		return
	var stats := current_character()
	var icon: Texture2D = stats.icon if stats != null else null
	player_view.texture = icon
	player_view.visible = icon != null
	player_fallback.visible = icon == null
	player_fallback.text = "（团队里没有人）" if _party.is_empty() else "（未选角色）"
	if player_name != null:
		if stats != null and _party.size() > 1:
			player_name.text = "%s（%d/%d）" % [stats.name, _view_index + 1, _party.size()]
		else:
			player_name.text = stats.name if stats != null else ""
		player_name.visible = not player_name.text.is_empty()
	# 团队只有 1 个人（或没人）时没得切：箭头置灰（置灰按钮也不进焦点环）
	var switchable := _party.size() > 1
	if prev_button != null:
		prev_button.disabled = not switchable
	if next_button != null:
		next_button.disabled = not switchable


## ◀/▶ 回调：名册内前后翻（越界回卷）。副作用：改下标、播音效、刷新形象与装备栏、emit。
func _step_player(step: int) -> void:
	if _party.size() <= 1:
		return
	_view_index = wrapi(_view_index + step, 0, _party.size())
	SoundManager.play_sound(SoundManager.Sound.UI)
	_refresh_player_view()
	_refresh_equip_slots()
	TooltipManager.hide_tip()      # 换人了，上一位角色的属性卡不该留在屏幕上
	# 通知 WorldMap：让并排的角色属性面板也切到同一个人
	character_view_changed.emit(current_character())


## 当前主角在名册里的下标；不在名册时返回 0（展示第一个人）。
func _index_of_leader() -> int:
	var index := _index_of(Global.main_player_selected)
	return maxi(0, index)


## 角色在名册里的下标；引用相同或 resource_path 相同都算同一人，找不到返回 -1。
func _index_of(character: UnitStats) -> int:
	if character == null:
		return -1
	for i in _party.size():
		var member: UnitStats = _party[i]
		if member == character:
			return i
		# 资源可能被复制过（战斗里就是 duplicate 后再用的），所以再比一次路径
		if member != null and not member.resource_path.is_empty() \
				and member.resource_path == character.resource_path:
			return i
	return -1


# ── 窗口位置与尺寸（右下角，按视口自适应）──

## 摆到右下角并按内容算尺寸；视口不够高时先砍可见行数，避免标题被顶出屏幕。
## 副作用：改 scroll.custom_minimum_size.y 与 Panel 的 anchor/offset。
func _apply_window_geometry() -> void:
	var panel := get_node_or_null(^"Panel") as Panel
	if panel == null or scroll == null:
		return
	var view := get_viewport_rect().size
	# ① 先决定背包能显示几行：除了滚动区，其它部分（标题/角色区/信息行/边距）是固定高度
	var fixed := TITLE_ROW_HEIGHT + PLAYER_ROW_HEIGHT + INFO_ROW_HEIGHT \
			+ VBOX_SEPARATION * 3.0 + WINDOW_PADDING_V * 2.0 + WINDOW_MARGIN * 2.0
	var row_height := SLOT_SIZE + GRID_SEPARATION
	var rows_budget := int(floor((view.y - fixed + GRID_SEPARATION) / row_height))
	var rows := clampi(rows_budget, 1, VISIBLE_ROWS)
	scroll.custom_minimum_size.y = rows * SLOT_SIZE + (rows - 1) * GRID_SEPARATION
	# ② 再按"最终内容"算窗口尺寸（宽 = 背包那 8 列 vs 角色区那一行，取大的那个）
	var bag_width := GRID_COLUMNS * SLOT_SIZE + (GRID_COLUMNS - 1) * GRID_SEPARATION + SCROLLBAR_ALLOWANCE
	# 角色区那一行：左 3 格 + ◀ + 形象 + ▶ + 右 3 格，中间 4 道间距（装备栏用 EQUIP_SLOT_SIZE）
	var row_width := EQUIP_SLOT_SIZE * 2.0 + PLAYER_FRAME_WIDTH + ARROW_WIDTH * 2.0 \
			+ PLAYER_ROW_SEPARATION * 4.0
	var panel_size := Vector2(
			maxf(bag_width, row_width) + WINDOW_PADDING * 2.0,
			fixed - WINDOW_MARGIN * 2.0 + scroll.custom_minimum_size.y)
	# ③ 锚到右下角：锚点全设 1，offset 用负值往左上"长"
	panel.anchor_left = 1.0
	panel.anchor_top = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = -(panel_size.x + WINDOW_MARGIN)
	panel.offset_right = -WINDOW_MARGIN
	panel.offset_top = -(panel_size.y + WINDOW_MARGIN)
	panel.offset_bottom = -WINDOW_MARGIN
	# ④ 背包方格比窗口窄时居中（角色区那一行通常在宽度上更宽，所以格子别贴左边）
	if scroll.size_flags_horizontal != Control.SIZE_SHRINK_CENTER:
		scroll.size_flags_horizontal = Control.SIZE_SHRINK_CENTER


# ── 格子 ──

## 当前窗口高度（像素），给并排的 StatsPanel 对齐用；未算过几何时返回 0。
func panel_height() -> float:
	var node := get_node_or_null(^"Panel") as Panel
	return node.size.y if node != null else 0.0


## 重算窗口尺寸并返回高度，不显示背包。属性面板单开时也能量到"背包该有的高度"。
func refresh_panel_height() -> float:
	_apply_window_geometry()
	return panel_height()


## 拿（必要时补）滚动层并配置：一屏 VISIBLE_ROWS 行、禁横向滚动、跟随焦点。
## %Scroll 缺失时就地 new 一个并 push_warning；创建与配置放同一处，兜底出来的也不会漏配。
func _ensure_scroll() -> void:
	scroll = get_node_or_null(^"%Scroll") as ScrollContainer
	if scroll == null:
		push_warning("BagPanel：场景里找不到 %Scroll —— 已在运行时临时补一个滚动层（功能可用，但请重新打开 "
				+ "scenes/ui/bag_panel/bag_panel.tscn：编辑器里的旧副本会覆盖磁盘文件）")
		var parent := grid.get_parent()
		var index := grid.get_index()
		scroll = ScrollContainer.new()
		scroll.name = "Scroll"
		parent.add_child(scroll)
		parent.move_child(scroll, index)
		grid.reparent(scroll)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# 高度由 _apply_window_geometry() 按行数算，这里先给个 1 行的最小值免得首帧是 0
	scroll.custom_minimum_size.y = SLOT_SIZE


## 造一个背包格子。item 为 null 时是空格子（暗色、不可点、不可聚焦）；有东西则画图标 + 稀有度描边 + 属性卡。
## 点一下 emit item_activated，卖 / 穿由 WorldMap 分流。
func _make_slot(item: ItemBase) -> Button:
	var slot := Button.new()
	slot.name = "Slot"
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.focus_mode = Control.FOCUS_ALL
	# 空格子：不可点、不可聚焦，只留一个暗描边当"格位"
	if item == null:
		slot.disabled = true
		slot.add_theme_stylebox_override("disabled", _slot_style(Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.03)))
		return slot

	slot.icon = item.item_icon
	slot.expand_icon = true
	slot.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 描边颜色跟稀有度走（TIER_COLORS 是 Global 上的共享常量，只读不改）
	var tier_color: Color = Global.TIER_COLORS.get(item.item_tier, Color(1, 1, 1, 0.4))
	slot.add_theme_stylebox_override("normal", _slot_style(tier_color, Color(1, 1, 1, 0.05)))
	slot.add_theme_stylebox_override("hover", _slot_style(tier_color, Color(1, 1, 1, 0.16)))
	slot.add_theme_stylebox_override("focus", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.18)))
	slot.add_theme_stylebox_override("pressed", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.24)))

	# 悬停 / 键盘焦点都弹同一张属性卡（TooltipManager 会把卡片锚到这个格子的右上角）
	slot.mouse_entered.connect(TooltipManager.show_for_control.bind(slot, item))
	slot.mouse_exited.connect(TooltipManager.hide_tip)
	slot.focus_entered.connect(TooltipManager.show_for_control.bind(slot, item))
	slot.focus_exited.connect(TooltipManager.hide_tip)
	# 点一下 = 发"这个格子被点了"（卖还是穿，由 WorldMap 按交易界面开没开决定）
	slot.pressed.connect(_on_slot_pressed.bind(item))
	_slots.append(slot)
	return slot


## 背包格子被点：播音效并 emit item_activated。
func _on_slot_pressed(item: ItemBase) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	item_activated.emit(item)


## 方格描边样式。bottom_margin：装备栏要传 EQUIP_LABEL_HEIGHT+4，给底部栏位名留位。
## expand_icon 会撑满按钮，内边距只能靠 StyleBox 的 content_margin。
func _slot_style(border: Color, bg: Color, bottom_margin := SLOT_ICON_MARGIN) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = SLOT_ICON_MARGIN
	style.content_margin_right = SLOT_ICON_MARGIN
	style.content_margin_top = SLOT_ICON_MARGIN
	style.content_margin_bottom = bottom_margin
	return style


func _emit_close() -> void:
	close_requested.emit()


## W A S D 在方格上移动焦点（方向键交给 Godot 的几何导航）。
## 实现在 Global.grid_nav()，与商人货架共用；WorldMap 的线性焦点环在方格上会斜着走。
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	Global.grid_nav(event, self)

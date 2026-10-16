extends Control
class_name BagPanel

## 背包面板（梦幻西游那种方格背包：一行 6 格，共 120 格 = 20 行）。
##
## ── 版面（从上到下）──
##   ① 标题「背包 n/120」（居中，和最早那版一样）
##   ② 角色区：**◀ 箭头 · 玩家形象 · ▶ 箭头**，形象**左右各三个装备栏**（3 格竖排，共 6 格）
##   ③ 信息行：**左边金币**、右边留给"卖出/合成"的提示文字（就是 MessageLabel 那一行）
##   ④ 方格背包：**一行 8 格**，一屏 8×8 = 64 格，其余靠滚轮/键盘往下滚
##   没有「关闭」按钮、也没有按键提示文案 —— 关闭只用 Esc 或 B（见 WorldMap 的输入状态机）。
##   ⚠ 一行 8 格（而不是 6）是用户定的：6 列时窗口宽由角色区决定，方格两侧会空出很大一片边距；
##     8 列的宽度（630）超过角色区那一行（584），方格成了宽度主导，两侧只留内边距。
##
## ── 点了格子 = 卖 ──
##   商人的交易界面**同时打开背包**，那时点背包里的格子就是"把这件武器卖给商人"：
##   `sell_requested(weapon)` → WorldMap → 交易面板弹确认框（写清卖价）→ GameRoot 真卖。
##   单独开背包（没开商人）时点格子也会发这个请求，但 WorldMap 会回一句
##   "要跟商人交易才能卖东西"，所以不会出现"点了没反应"。
##
## ── 两种格子尺寸是分开的（重要）──
##   · `EQUIP_SLOT_SIZE = 96`：**装备栏**用的（形象区那 6 个坑位 + 决定形象框高度）；
##   · `SLOT_SIZE = 72`：**背包格子**用的（要在一屏里塞下 7 行，只能比装备栏小）。
##   一开始我把两者写成同一个数（68），结果形象区被一起压小、形象框变成 240×224 的方框
##   ——看着"变形/被缩小"。梦幻西游的纸娃娃里装备栏本来也比背包格子大，所以拆开两个常量最自然。
##
## ── 和商人做买卖时 ──
##   商人面板打开时会**同时打开背包**（"看看货、也看看自己有什么"）：
##   交易窗口贴屏幕**最左边**、背包贴**最右边**，两者天然不重叠，所以背包不需要让位。
##
## ── 箭头切的是"看谁"，不是"换队长"（重要）──
##   ◀ / ▶ 只在**团队名册**（WorldMap._party → GameRoot.party）里前后翻页，
##   换的只是这个窗口里展示的形象 + 名字（形象下面那行会写「名字（i/n）」）。
##   它**不会**动 Global.main_player_selected / GameRoot 的队长或上阵名单 ——
##   那些是"谁上场打仗"的规则，属于 GameRoot 的数据，界面只读不改（本文件全文不发任何请求信号）。
##   团队里只有 1 个人（或一个都没有）时箭头置灰：没得切，也就不会占键盘焦点的一站。
##   ⚠ 6 个装备栏现在还是**和选中的角色无关**的空占位：等接上装备系统，
##     它们应该跟着"当前展示的这个人"走（那时候才需要把 _view_index 接到 GameRoot）。
##
## ── 位置 ──
##   屏幕**右下角**（距右边/下边 WINDOW_MARGIN）。
##   ⚠ 位置与尺寸是**代码算出来的**（_apply_window_geometry），不是 .tscn 里的数字：
##     窗口高度依赖"一屏几行 + 角色区 + 标题"这些常量，写死在场景里迟早对不上；
##     而且视口变小（比如窗口没最大化）时还要自动少显示几行，免得顶出屏幕。
##     想调窗口：改下面那几个常量；.tscn 里的 offset 只是编辑器里的预览值。
##
## ── 在系统里的位置 ──
##   纯 UI 场景：由 WorldMap._setup_overlays() 实例化后挂在它的 UI（CanvasLayer）下面。
##   本文件**不改背包数据**：它只是 Global.equipped_weapons 的一个"方格视图"，
##   打开时由 WorldMap 把那个数组传进来（引用语义，但本文件只读）。
##   以后要加"装备 / 合成 / 卖出"，照招募/商店那套加一个请求信号 + GameRoot 处理即可
##   （角色区那 6 个装备栏就是留给"装备"的坑位，现在只是空框）。
##
## ── 谁往里放东西 ──
##   商人买到的武器（GameRoot.buy_weapon()）会 append 进 Global.equipped_weapons ——
##   也就是本面板的格子。所以"买了武器就进背包"这条链的落点就是这里。
##   格数上限是 GameRoot.BAG_SLOTS（默认 120 = 6 列 × 20 行）。
##
## ── 场景可能被"旧副本"覆盖（真踩过的坑）──
##   编辑器里打开着本场景时，如果 .tscn 在外部被改过，编辑器保存时会用**内存里的旧副本**
##   盖掉磁盘文件 —— 症状是 %Scroll 没了、Panel 又回到居中，运行时直接崩在
##   "Invalid access to property or key 'custom_minimum_size' on a base object of type 'Nil'"。
##   所以这里对三件事做了兜底（都会 push_warning 提醒去重开场景）：
##     · _ensure_scroll()：找不到 %Scroll 就地补一个滚动层（不崩，还能滚）；
##     · 角色区的三个容器/形象节点缺失时跳过那一块（不崩）；
##     · 位置与尺寸反正每次都由代码算，不受场景里的旧数字影响。
##
## ── 悬停/焦点显示属性（关键需求）──
##   每个有东西的格子：
##     · 鼠标移上去 → TooltipManager.show_for_control(格子, 武器) —— 弹出的是工程里
##       既有的 hover_item_card（图标 + 名字 + 类型 + 伤害/冷却/射程/暴击），
##       不是 Godot 原生的那种灰框 tooltip，所以**不要**再设 button.tooltip_text（会双份）；
##     · 键盘焦点移到格子 → 同样弹那张卡（TooltipManager 本来就支持锚到控件，
##       文档里写着"手柄/键盘导航靠它"）；
##   离开（mouse_exited / focus_exited）时 hide_tip()。
##
## ── 键盘 ──
##   方向键由 Godot 的 GUI 焦点系统按**几何位置**自动走（方格布局天然合适）；
##   W A S D 是工程自己的动作、GUI 不认，所以本文件自己处理：左右 = ±1 格、
##   上下 = ±一整行（±GRID_COLUMNS）—— 这也正是背包不能直接用 WorldMap 那套线性
##   焦点环的原因（那套上下只走一格，在 6 列网格里会变成"斜着走"）。
##   Enter / 空格 / E 目前没有动作（格子里还没有"使用"），留给以后的装备/合成。

## 点了背包里某一格（有东西的格子）：请求把这件东西**卖**给商人。
## 参数 weapon：被点的武器。
## ⚠ 本文件不判断"现在能不能卖"——那是 WorldMap/GameRoot 的事（只有在交易界面开着时才能卖，
##   没开商人时 WorldMap 会回一句"要跟商人交易才能卖"）。界面只发请求。
signal sell_requested(weapon: ItemWeapon)

## 关掉面板回到地图。**当前没有任何按钮发它**（「关闭」按钮已按要求移除，关闭靠 Esc / B）——
## 保留是为了以后加「整理」「关闭」这类按钮时直接接上，WorldMap 那边也已经连好了。
signal close_requested

## 每行几格（梦幻西游式方格）。改这个值要同时改 .tscn 里 GridContainer 的 columns。
## 8 列 = 120 格正好 15 行；也让方格宽度超过角色区，成为窗口宽度的主导（两侧不再留大片空白）。
const GRID_COLUMNS := 8
## 一屏显示几行 —— 只影响可滚动区域的**可见高度**（由代码算出来写进 ScrollContainer）。
## 格子总数另有 GameRoot.BAG_SLOTS（默认 120 = 8 列 × 15 行）：
## 120 格全部画出来，但一屏只看得到 8×8=64 格，其余靠滚轮/键盘往下滚。
## 视口不够高时 _apply_window_geometry() 会自动把这个行数调小（最少 1 行）。
const VISIBLE_ROWS := 8
## 格子之间的间距（横向纵向都用它；写在这里是为了让尺寸能按格数精确算出来）。
const GRID_SEPARATION := 10
## 单格边长（像素）——**背包格子**用。**68 是按 1920×1080 反推的**：面板要同时容下
## "标题 + 角色区（形象框 308 高）+ 信息行 + 8 行背包"，1080 减掉边距只剩约 1048，
## 解下来背包格子最大 68（再大就要么减行数、要么顶出屏幕）。
## ⚠ 别把它和 EQUIP_SLOT_SIZE 合并：装备栏比背包格子大（见文件头"两种格子尺寸"）。
## 8 列下的窗口宽度 = 8×68 + 7×10 + 滚动条 16 + 内边距 32 = 662。
const SLOT_SIZE := 68.0
## 图标相对格子的内边距（图标用 expand_icon 缩放，留边是为了别贴上描边）。
const SLOT_ICON_MARGIN := 8

## 左右各几个装备栏（用户要求：玩家形象左边 3 个、右边 3 个）。
const EQUIP_SLOTS_PER_SIDE := 3
## **装备栏**格子边长。比背包格子大：一是形象框要够"竖"（240×308 才像立绘框，压成方形就难看），
## 二是梦幻西游里纸娃娃的装备栏本来就比背包格子醒目。
const EQUIP_SLOT_SIZE := 96.0
## 玩家形象的框尺寸。高度取"三个装备栏叠起来"的高度，这样一行看起来是齐的。
const PLAYER_FRAME_WIDTH := 240.0
const PLAYER_FRAME_HEIGHT := EQUIP_SLOTS_PER_SIDE * EQUIP_SLOT_SIZE \
		+ (EQUIP_SLOTS_PER_SIDE - 1) * GRID_SEPARATION
## 形象两边的切换箭头（◀ / ▶）的尺寸。宽度只用于算窗口宽度，高度是点击手感（竖向居中）。
const ARROW_WIDTH := 44.0
const ARROW_HEIGHT := 60.0
## 角色区里"左栏 ↔ 箭头 ↔ 形象 ↔ 箭头 ↔ 右栏"之间的间距。
const PLAYER_ROW_SEPARATION := 16.0
## 角色区这一行的总高 = 形象框（金币已经挪到下面的信息行，不再占这里的高度）。
const PLAYER_ROW_HEIGHT := PLAYER_FRAME_HEIGHT

## 窗口离屏幕右边/下边的留白，以及面板内部的四边留白（16 而不是 24：1080 高要省着用）。
const WINDOW_MARGIN := 16.0
const WINDOW_PADDING := 16.0
const WINDOW_PADDING_V := 16.0
## 标题行 / 信息行的预留高度（字号 28 / 22，留够就不会挤到下面）。
## INFO_ROW_HEIGHT 是"金币 + 提示文字"那一行（就是 MessageLabel 所在的行）。
const TITLE_ROW_HEIGHT := 40.0
const INFO_ROW_HEIGHT := 26.0
## VBox 里各块之间的间距（.tscn 里也是这个值）。
const VBOX_SEPARATION := 8.0
## 给竖直滚动条留的宽度，免得第 6 列被它挤掉。
const SCROLLBAR_ALLOWANCE := 16.0

@onready var coins_label: Label = %CoinsLabel
@onready var count_label: Label = %CountLabel
@onready var message_label: Label = %MessageLabel
@onready var grid: GridContainer = %Grid
## 角色区（可能缺失 —— 场景被旧副本覆盖时，缺失就整块跳过，不崩）。
@onready var player_view: TextureRect = get_node_or_null(^"%PlayerView") as TextureRect
@onready var player_fallback: Label = get_node_or_null(^"%PlayerFallback") as Label
@onready var player_name: Label = get_node_or_null(^"%PlayerNameLabel") as Label
@onready var prev_button: Button = get_node_or_null(^"%PrevPlayerButton") as Button
@onready var next_button: Button = get_node_or_null(^"%NextPlayerButton") as Button
@onready var left_slots: VBoxContainer = get_node_or_null(^"%LeftSlots") as VBoxContainer
@onready var right_slots: VBoxContainer = get_node_or_null(^"%RightSlots") as VBoxContainer

## 滚动容器。**不能**直接写 `@onready var scroll := %Scroll` ——
## 场景被旧副本覆盖时 %Scroll 是 null，那么在 null 上取 custom_minimum_size 会当场崩。
## 所以由 _ensure_scroll() 在 _ready() 里解析（找不到就补一个）。
var scroll: ScrollContainer

## 当前焦点环：只有"有东西的格子"（空格子不可聚焦，方向键会自然跳过它们）。
var _slots: Array[Control] = []

## 角色区正在展示谁：团队名册（引用 WorldMap._party，只读）与当前下标。
## **纯展示**：不会写回 Global / GameRoot（见文件头"箭头切的是看谁"）。
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


## 按背包内容重建整个方格并显示。
## 参数 items：背包里的武器（就是 Global.equipped_weapons；只读）。
## 参数 capacity：格子总数（GameRoot.BAG_SLOTS，默认 120）。多出来的空格也会画出来 ——
##   梦幻西游那种"一眼看到还剩几格"的观感就是靠空格的，而不是只画有东西的。
##   注意：格子是**全部**画出来的（120 个节点），一屏只看得到 VISIBLE_ROWS 行，其余靠滚动。
## 参数 party：团队名册（WorldMap._party，就是 GameRoot.party 那个数组；只读）。
##   角色区的 ◀ / ▶ 在这个数组里翻页；默认空数组 = 团队没人，只显示主角或占位文字。
##   传引用而不是拷贝：团队随时可能被招募/移出改动，下次打开时现取最新内容即可。
## 副作用：show()；改信息行（金币 + 格子数）；清空并重建 %Grid（先 remove_child 再 queue_free）；
##        滚动位置回到顶部；重算窗口尺寸。
## ⚠ 这里**不重置**"正在看谁"（_view_index）：买卖时每买一件都会重建一次背包，
##   要是每次都跳回队长，玩家刚翻到的那个人就被抢走了。要重置请显式调 reset_view()
##   （WorldMap._open_bag() 打开面板时会调一次）。
## ⚠ 也刻意**不清空提示文字**（message_label）：以后"卖出成功"这类操作是
##   "先 show_message()、再 call_deferred(show_bag)"，清一次就看不到提示了。要清调 clear_message()。
func show_bag(items: Array[ItemWeapon], capacity: int, party: Array[UnitStats] = []) -> void:
	show()
	_party = party
	_refresh_player_view()
	count_label.text = "背包　%d/%d" % [items.size(), capacity]
	coins_label.text = "金币：%d" % Global.coins
	_slots.clear()
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	for index in capacity:
		var weapon: ItemWeapon = items[index] if index < items.size() else null
		grid.add_child(_make_slot(weapon))
	scroll.scroll_vertical = 0        # 每次打开都回到顶部（见函数头注释）
	_apply_window_geometry()


## 把"正在看谁"重置回当前主角（打开背包时调；买卖引起的重建不调，见 show_bag 的说明）。
func reset_view() -> void:
	_view_index = _index_of_leader()
	_refresh_player_view()


## 只刷新金币数（买卖之后调这个最省 —— 不用重建 120 个格子）。
## 参数 coins：当前金币；不传就读 Global.coins。
func refresh_coins(coins := -1) -> void:
	coins_label.text = "金币：%d" % (Global.coins if coins < 0 else coins)


## 让背包里的格子能不能被键盘选中。
## 什么时候会关掉：交易面板的**确认框**弹出来时（WorldMap 收到 MerchantPanel.confirm_changed
##   后调这里）—— 那时是一次模态询问，焦点只该在"确定/取消"两个按钮之间。
## 平时（包括交易中）**都是开的**：用户要求"交易时背包也要能交互"，
##   所以交易时方向键可以从货架走到背包、按 E 就是"卖这一件"。
## 参数 enabled：true = 正常（格子可聚焦）；false = 全部设成 FOCUS_NONE（鼠标悬停看属性不受影响）。
func set_slot_focus_enabled(enabled: bool) -> void:
	for slot in _slots:
		(slot as Control).focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	for button in [prev_button, next_button]:
		if button != null and not button.disabled:
			button.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE


## 在面板上显示一句提示（留给以后的"卖出/合成"用；现在没地方写）。
func show_message(text: String) -> void:
	message_label.text = text


## 清掉提示文字（WorldMap 每次打开本面板时调一次）。
func clear_message() -> void:
	message_label.text = ""


## 当前可以聚焦的格子（WorldMap 用它设焦点环；空格子不在里面）。
## 顺序：先背包里"有东西"的格子（第一个自动拿到焦点，于是开背包就能看到第一件武器的属性卡），
## 最后是两边的切换箭头（有得切时才有）—— W/S 的走格只看 _slots，不含箭头（见 _unhandled_input），
## 箭头靠方向键的几何导航过去，或直接用鼠标点。
func focus_ring() -> Array[Control]:
	var out: Array[Control] = _slots.duplicate()
	for button in [prev_button, next_button]:
		if button != null and not button.disabled:
			out.append(button)
	return out


# ══════════════════════════════════════════════════════════
#  角色区（玩家形象 + 左右各三个装备栏）
# ══════════════════════════════════════════════════════════

## 造左右两排装备栏（各 EQUIP_SLOTS_PER_SIDE 个空格子）。
## 调用时机：_ready() 一次。**不随背包内容重建** —— 它们是固定坑位（以后放"已装备"的东西），
##   和"背包里有什么"无关。
## 为什么在代码里造而不是在 .tscn 里摆：格数由常量决定，改 EQUIP_SLOTS_PER_SIDE 就自动生效，
##   不用再去场景里复制粘贴节点（和背包格子同一个理由）。
## 副作用：往里填 Panel，并 push_warning（场景缺容器时）。
func _build_equip_slots() -> void:
	if left_slots == null or right_slots == null:
		push_warning("BagPanel：场景里找不到 %LeftSlots / %RightSlots —— 已跳过装备栏那一块。"
				+ "请重新打开 scenes/ui/bag_panel/bag_panel.tscn")
		return
	for container in [left_slots, right_slots]:
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()
		for i in EQUIP_SLOTS_PER_SIDE:
			container.add_child(_make_equip_slot())


## 造一个装备栏空格子。
## 用 Panel 而不是 Button：现在没有"装备/卸下"的动作，做成按钮只会让玩家点了没反应，
##   还会混进键盘焦点环白占一站。等以后接上装备系统，再按需要换成 Button + 信号。
## 返回值：Panel（带描边、正方形、悬停有原生提示说明它是干嘛的）。
func _make_equip_slot() -> Panel:
	var slot := Panel.new()
	slot.name = "EquipSlot"
	slot.custom_minimum_size = Vector2(EQUIP_SLOT_SIZE, EQUIP_SLOT_SIZE)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.tooltip_text = "装备栏（未开放）"
	slot.add_theme_stylebox_override("panel", _slot_style(Color(1, 1, 1, 0.16), Color(1, 1, 1, 0.04)))
	return slot


## 把玩家形象刷成"当前展示的团队成员"。
## 数据来源：_party（团队名册）+ _view_index（◀ / ▶ 翻到第几个）；名册为空时退回
##   Global.main_player_selected（当前主角），再没有就显示占位文字。
## 贴图就是地图上那个小人用的同一张（UnitStats.icon）—— 所以背包里的形象和场上一致。
## 副作用：改 player_view.texture / 两个箭头的 disabled / 名字标签的文字；不读写游戏数据。
func _refresh_player_view() -> void:
	if player_view == null or player_fallback == null:
		return
	var stats: UnitStats = null
	if _view_index >= 0 and _view_index < _party.size():
		stats = _party[_view_index]
	if stats == null:
		stats = Global.main_player_selected
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


## ◀ / ▶ 的回调：在团队名册里前后翻一个（越界就回卷）。
## 参数 step：-1 = 上一个，+1 = 下一个。
## 副作用：改 _view_index、播 UI 音效、刷新形象/名字；**不改任何游戏数据**（见文件头）。
func _step_player(step: int) -> void:
	if _party.size() <= 1:
		return
	_view_index = wrapi(_view_index + step, 0, _party.size())
	SoundManager.play_sound(SoundManager.Sound.UI)
	_refresh_player_view()


## 团队里"当前主角"排第几（用来决定打开背包时先展示谁）。
## 返回：下标；主角不在团队里（或团队为空）时返回 0 —— 于是展示团队第一个人。
func _index_of_leader() -> int:
	var leader: UnitStats = Global.main_player_selected
	if leader == null or _party.is_empty():
		return 0
	for i in _party.size():
		var member: UnitStats = _party[i]
		if member == leader:
			return i
		# 资源可能被复制过（战斗里就是 duplicate 后再用的），所以再比一次路径
		if member != null and not member.resource_path.is_empty() \
				and member.resource_path == leader.resource_path:
			return i
	return 0


# ══════════════════════════════════════════════════════════
#  窗口位置与尺寸（右下角，按视口自适应）
# ══════════════════════════════════════════════════════════

## 把面板摆到屏幕**右下角**，尺寸按内容算；视口不够高时先砍可见行数。
## 为什么每次打开都调：窗口可能被玩家拉小过，而"一屏几行"是要跟着变的
##   （不然窗口高于屏幕时，标题会被顶到屏幕外，玩家看不到）。
## 副作用：改 scroll.custom_minimum_size.y；改 Panel 的 anchor/offset。
## 参数：无（读常量 + 视口尺寸）。返回值：无。
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
	# ② 再按"最终内容"算窗口尺寸（宽 = 背包那 6 列 vs 角色区那一行，取大的那个）
	var bag_width := GRID_COLUMNS * SLOT_SIZE + (GRID_COLUMNS - 1) * GRID_SEPARATION + SCROLLBAR_ALLOWANCE
	# 角色区那一行：左 3 格 + ◀ + 形象 + ▶ + 右 3 格，中间 4 道间距（装备栏用 EQUIP_SLOT_SIZE）
	var row_width := EQUIP_SLOT_SIZE * 2.0 + PLAYER_FRAME_WIDTH + ARROW_WIDTH * 2.0 \
			+ PLAYER_ROW_SEPARATION * 4.0
	var size := Vector2(
			maxf(bag_width, row_width) + WINDOW_PADDING * 2.0,
			fixed - WINDOW_MARGIN * 2.0 + scroll.custom_minimum_size.y)
	# ③ 锚到右下角：锚点全设 1，offset 用负值往左上"长"
	panel.anchor_left = 1.0
	panel.anchor_top = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = -(size.x + WINDOW_MARGIN)
	panel.offset_right = -WINDOW_MARGIN
	panel.offset_top = -(size.y + WINDOW_MARGIN)
	panel.offset_bottom = -WINDOW_MARGIN
	# ④ 背包方格比窗口窄时居中（角色区那一行通常在宽度上更宽，所以格子别贴左边）
	if scroll.size_flags_horizontal != Control.SIZE_SHRINK_CENTER:
		scroll.size_flags_horizontal = Control.SIZE_SHRINK_CENTER


# ══════════════════════════════════════════════════════════
#  格子
# ══════════════════════════════════════════════════════════

## 拿（必要时补）滚动层，并把它配成"一屏 VISIBLE_ROWS 行、超出就滚"。
## 参数：无。返回值：无（结果写进成员 scroll）。
## 副作用：
##   · %Scroll 存在 → 只做配置；
##   · 不存在 → new 一个 ScrollContainer 插到 Grid 原来的位置、把 Grid 挪进去，并 push_warning
##     提醒去重新打开场景（见文件头"场景可能被旧副本覆盖"）。
## 为什么配置也放这里：这样"创建"和"配置"永远是同一处，兜底补出来的滚动层不会漏配。
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


## 造一个背包格子。
## 参数 weapon：这一格放什么；null = 空格子（画成暗色、不可点、不可聚焦）。
## 有东西的格子：
##   · 用 Button.icon + expand_icon 直接显示图标（比嵌 TextureRect 简单，且自带按下/悬停反馈）；
##   · 按稀有度换描边颜色（Global.TIER_COLORS），和商店/提示卡一套配色；
##   · mouse_entered / focus_entered 弹 hover_item_card，离开时收起；
##   · **点一下 = 请求卖出**（emit sell_requested；能不能卖由 WorldMap/GameRoot 判）。
func _make_slot(weapon: ItemWeapon) -> Button:
	var slot := Button.new()
	slot.name = "Slot"
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.focus_mode = Control.FOCUS_ALL
	# 空格子：不可点、不可聚焦，只留一个暗描边当"格位"
	if weapon == null:
		slot.disabled = true
		slot.add_theme_stylebox_override("disabled", _slot_style(Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.03)))
		return slot

	slot.icon = weapon.item_icon
	slot.expand_icon = true
	slot.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 描边颜色跟稀有度走（TIER_COLORS 是 Global 上的共享常量，只读不改）
	var tier_color: Color = Global.TIER_COLORS.get(weapon.item_tier, Color(1, 1, 1, 0.4))
	slot.add_theme_stylebox_override("normal", _slot_style(tier_color, Color(1, 1, 1, 0.05)))
	slot.add_theme_stylebox_override("hover", _slot_style(tier_color, Color(1, 1, 1, 0.16)))
	slot.add_theme_stylebox_override("focus", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.18)))
	slot.add_theme_stylebox_override("pressed", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.24)))

	# 悬停 / 键盘焦点都弹同一张属性卡（TooltipManager 会把卡片锚到这个格子的右上角）
	slot.mouse_entered.connect(TooltipManager.show_for_control.bind(slot, weapon))
	slot.mouse_exited.connect(TooltipManager.hide_tip)
	slot.focus_entered.connect(TooltipManager.show_for_control.bind(slot, weapon))
	slot.focus_exited.connect(TooltipManager.hide_tip)
	# 点一下 = 请求卖出（商人收不收、现在能不能卖，都由 WorldMap/GameRoot 决定）
	slot.pressed.connect(_on_slot_pressed.bind(weapon))
	_slots.append(slot)
	return slot


## 背包格子被点：发"卖出请求"（见文件头"点了格子 = 卖"）。
## 参数 weapon：这一格的武器。副作用：播 UI 音效 + emit sell_requested。
func _on_slot_pressed(weapon: ItemWeapon) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	sell_requested.emit(weapon)


## 格子的方形描边样式（梦幻西游那种一格一格的感觉）。
## 参数 border：描边颜色（有东西时按稀有度、空格子是半透明白）。
## 参数 bg：底色（半透明，压在面板的深色背景上）。
## 说明：expand_icon 会把图标撑满按钮，所以内边距靠 StyleBox 的 content_margin 留出来 ——
##   这是 Button 唯一"正规"的留白开关（按钮没有单独的 padding 属性）。
func _slot_style(border: Color, bg: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = SLOT_ICON_MARGIN
	style.content_margin_right = SLOT_ICON_MARGIN
	style.content_margin_top = SLOT_ICON_MARGIN
	style.content_margin_bottom = SLOT_ICON_MARGIN
	return style


func _emit_close() -> void:
	close_requested.emit()


## 键盘补丁：W A S D 在方格上移动焦点（方向键交给 Godot 的几何导航，见文件头）。
## 参数 event：引擎派发的输入事件。
## 返回值：无。副作用：可能改焦点、消费掉事件。
## 实现搬到 Global.grid_nav()，与**商人货架**共用同一套方格导航
##   （两个面板都是 6 列方格，各写一遍"上下跳一行"迟早写歪一处）。
## 为什么在这里而不是 WorldMap：只有本面板知道"这是一张方格"，
##   WorldMap 那套是线性 ±1 的焦点环，在 6 列网格里会变成"斜着走"。
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	Global.grid_nav(event, self)

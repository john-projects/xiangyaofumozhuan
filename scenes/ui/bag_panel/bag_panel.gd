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
## ── 点了格子 = 卖 / 穿（看有没有开商人）──
##   同一个点击，WorldMap 按"交易界面开没开"分流（本面板不知道这些业务规则，只发请求）：
##     · 商人的交易界面**同时打开背包**时：点背包里的格子 = 把这件东西卖给他
##       （`item_activated` → WorldMap → 交易面板弹确认框（写清卖价）→ GameRoot 真卖）；
##     · 平时（没开商人）：点同一个格子 = **给当前展示的角色穿上**
##       （`item_activated` → WorldMap.equip_requested(character, item) → GameRoot.equip_item()，
##       穿到 `item.get_equip_type()` 指定的那一个装备栏）。
##   两条路都保证"点了有反应"：穿不上（不能装备 / 背包里没有）时原因会写回信息行。
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
##   换的是这个窗口里展示的形象 + 名字（形象下面那行会写「名字（i/n）」），
##   **以及 6 个装备栏显示谁的装备** —— 每个进团队的角色各有一套装备（用户要求）。
##   它**不会**动 Global.main_player_selected / GameRoot 的队长或上阵名单 ——
##   那些是"谁上场打仗"的规则，属于 GameRoot 的数据，界面只读不改（本文件全文不发任何请求信号）。
##   团队里只有 1 个人（或一个都没有）时箭头置灰：没得切，也就不会占键盘焦点的一站。
##   ⚠ 6 个装备栏是**固定类型**的（左一 头盔 / 左二 武器 / 左三 腰带 /
##     右一 项链 / 右二 衣服 / 右三 鞋子，见 EQUIP_LAYOUT）：空格子写着栏位名，
##     穿上的东西画图标 + 按稀有度描边，点一下 = 脱下来放回背包。
##     内容读 Global.equipment_by_character（GameRoot.equip_item / unequip_slot 是唯一写入点），
##     取的是 **current_character()** 那一套 —— 换角色只 `_refresh_equip_slots()`，不重建节点。
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
##   商人买到的装备（GameRoot.buy_item()）会 append 进 Global.equipped_weapons ——
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
##   Enter / 空格 / E 都等于"按下焦点上的那个格子"：背包格子 = 卖 / 穿，装备栏 = 脱。

## 点了背包里某一格（有东西的格子）。**具体干什么由 WorldMap 决定**：
##   · 交易界面开着 → 把这件东西卖给商人；
##   · 平时 → 把它穿到对应的装备栏（见文件头"点了格子 = 卖 / 穿"）。
## 参数 item：被点的道具（类型是 **ItemBase** —— 以后头盔/项链这类新装备也走同一条路）。
## ⚠ 本文件不判断"能不能卖 / 能不能穿"——那是 GameRoot 的规则，界面只发请求，
##   所以不会出现"按钮能点、点下去什么都没发生"。
signal item_activated(item: ItemBase)

## 点了**已穿上**的装备栏：请求脱下来放回背包。
## 参数 slot_type：ItemBase.EquipType 的成员值（头盔 / 武器 / 腰带 / 项链 / 衣服 / 鞋子）。
## 空装备栏是 disabled 的，所以不会发这个信号。
signal unequip_requested(slot_type: int)

## 背包界面展示的角色变了（◀ / ▶）。并排的属性面板据此切到同一个人（由 WorldMap 转发）。
signal character_view_changed(character: UnitStats)

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
## 六个装备栏的**固定顺序**：左列从上到下 → 右列从上到下。
##   左一 头盔 / 左二 武器 / 左三 腰带 / 右一 项链 / 右二 衣服 / 右三 鞋子。
## 想换栏位的摆法只改这个数组（两列各取前/后 EQUIP_SLOTS_PER_SIDE 个）；
## **类型本身**定义在 ItemBase.EquipType，中文名在 ItemBase.equip_type_name()。
## 注意它必须和 EQUIP_SLOTS_PER_SIDE × 2 一样长，多出来的会被忽略、少的按"装备(NONE)"补。
const EQUIP_LAYOUT: Array[int] = [
	ItemBase.EquipType.HELMET,
	ItemBase.EquipType.WEAPON,
	ItemBase.EquipType.BELT,
	ItemBase.EquipType.NECKLACE,
	ItemBase.EquipType.ARMOR,
	ItemBase.EquipType.BOOTS,
]
## 装备栏里那行栏位名（"头盔"/"武器"…）的高度。图标要画在它上面，
## 所以装备栏 StyleBox 的 content_margin_bottom 要留出这么多。
const EQUIP_LABEL_HEIGHT := 20.0
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
## 已穿上装备的那几个装备栏（空栏位是 disabled，不进这里，也就不占焦点）。
var _equip_slots: Array[Control] = []
## 当前是否允许格子拿键盘焦点（交易确认框弹出时会被临时关掉，见 set_slot_focus_enabled）。
## 刷新装备栏内容时要按它决定 FOCUS_ALL / FOCUS_NONE，否则刷新一次就把模态状态冲掉了。
var _slot_focus_enabled := true

## 角色区正在展示谁：团队名册（引用 WorldMap._party，只读）与当前下标。
## **纯展示**：不会写回 Global / GameRoot（见文件头"箭头切的是看谁"）。
## ⚠ 但它决定了**装备栏显示谁的装备**、以及"点背包格子穿给谁"（见 current_character）。
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
## 参数 items：背包里的东西（就是 Global.equipped_weapons；只读）。
##   ⚠ 类型是 **Array[ItemBase]** 而不是 Array[ItemWeapon]：以后头盔/项链这类新装备
##     也能直接放进背包，这个函数一行都不用改。
## 参数 capacity：格子总数（GameRoot.BAG_SLOTS，默认 120）。多出来的空格也会画出来 ——
##   梦幻西游那种"一眼看到还剩几格"的观感就是靠空格的，而不是只画有东西的。
##   注意：格子是**全部**画出来的（120 个节点），一屏只看得到 VISIBLE_ROWS 行，其余靠滚动。
## 参数 party：团队名册（WorldMap._party，就是 GameRoot.party 那个数组；只读）。
##   角色区的 ◀ / ▶ 在这个数组里翻页；默认空数组 = 团队没人，只显示主角或占位文字。
##   传引用而不是拷贝：团队随时可能被招募/移出改动，下次打开时现取最新内容即可。
## 副作用：show()；改信息行（金币 + 格子数）；**按当前展示的角色刷新 6 个装备栏**
##        （换人/穿上/脱下之后必须跟着变）；清空并重建 %Grid（先 remove_child 再 queue_free）；
##        滚动位置回到顶部；重算窗口尺寸。
## ⚠ 这里**不重置**"正在看谁"（_view_index）：买卖时每买一件都会重建一次背包，
##   要是每次都跳回队长，玩家刚翻到的那个人就被抢走了。要重置请显式调 reset_view()
##   （WorldMap._open_bag() 打开面板时会调一次）。
## ⚠ 也刻意**不清空提示文字**（message_label）：以后"卖出成功"这类操作是
##   "先 show_message()、再 call_deferred(show_bag)"，清一次就看不到提示了。要清调 clear_message()。
func show_bag(items: Array[ItemBase], capacity: int, party: Array[UnitStats] = []) -> void:
	show()
	_party = party
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
	scroll.scroll_vertical = 0        # 每次打开都回到顶部（见函数头注释）
	_apply_window_geometry()


## 把"正在看谁"重置回当前主角（打开背包时调；买卖引起的重建不调，见 show_bag 的说明）。
func reset_view() -> void:
	_view_index = _index_of_leader()
	_refresh_player_view()
	_refresh_equip_slots()


## 把"正在看谁"切到指定角色（不重建方格、不重置滚动）。
## 谁调：WorldMap —— 并排的角色属性面板换了人，背包要跟着切（反之亦然）。
## 角色不在名册里就忽略（例如他刚被移出团队）。
## 副作用：改 _view_index、刷新形象/名字/装备栏；**不**emit（避免两个面板互相弹来弹去）。
func show_character(character: UnitStats) -> void:
	var index := _index_of(character)
	if index < 0 or index == _view_index:
		return
	_view_index = index
	_refresh_player_view()
	_refresh_equip_slots()


## 只刷新金币数（买卖之后调这个最省 —— 不用重建 120 个格子）。
## 参数 coins：当前金币；不传就读 Global.coins。
func refresh_coins(coins := -1) -> void:
	coins_label.text = "金币：%d" % (Global.coins if coins < 0 else coins)


## 让背包里的格子（以及**已穿上装备的装备栏**）能不能被键盘选中。
## 什么时候会关掉：交易面板的**确认框**弹出来时（WorldMap 收到 MerchantPanel.confirm_changed
##   后调这里）—— 那时是一次模态询问，焦点只该在"确定/取消"两个按钮之间。
## 平时（包括交易中）**都是开的**：用户要求"交易时背包也要能交互"，
##   所以交易时方向键可以从货架走到背包、按 E 就是"卖这一件"。
## 参数 enabled：true = 正常（格子可聚焦）；false = 全部设成 FOCUS_NONE（鼠标悬停看属性不受影响）。
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


## 在面板上显示一句提示（留给以后的"卖出/合成"用；现在没地方写）。
func show_message(text: String) -> void:
	message_label.text = text


## 清掉提示文字（WorldMap 每次打开本面板时调一次）。
func clear_message() -> void:
	message_label.text = ""


## 当前可以聚焦的格子（WorldMap 用它设焦点环；空格子不在里面）。
## 顺序：先背包里"有东西"的格子（第一个自动拿到焦点，于是开背包就能看到第一件东西的属性卡），
## 接着是**已穿上装备的装备栏**（键盘也能脱），最后是两边的切换箭头（有得切时才有）。
## W/S 的走格只看 _slots，不含箭头和装备栏（见 _unhandled_input）；
## 装备栏靠方向键的几何导航过去，或直接用鼠标点。
func focus_ring() -> Array[Control]:
	var out: Array[Control] = _slots.duplicate()
	out.append_array(_equip_slots)
	for button in [prev_button, next_button]:
		if button != null and not button.disabled:
			out.append(button)
	return out


# ══════════════════════════════════════════════════════════
#  角色区（玩家形象 + 左右各三个装备栏，**每个角色各一套**）
# ══════════════════════════════════════════════════════════

## 造左右两排装备栏（各 EQUIP_SLOTS_PER_SIDE 个）—— **只造一次**（_ready 时）。
## 每个格子的类型由 EQUIP_LAYOUT 决定：左一 头盔 / 左二 武器 / 左三 腰带 /
## 右一 项链 / 右二 衣服 / 右三 鞋子。
## 格子的**内容**（当前展示的角色穿着什么）不在这里定：穿上/脱下、以及 ◀ / ▶ 换角色时
##   只调 _refresh_equip_slots() **就地刷新**这句话的意思 —— 按钮节点不变，键盘焦点和
##   WorldMap 记住的焦点环都不会指到已经被释放的旧按钮上。
## 为什么在代码里造而不是在 .tscn 里摆：格数和类型都由常量决定，改一处就自动生效，
##   不用再去场景里复制粘贴节点（和背包格子同一个理由）。
## 副作用：重建两个 VBox 的子节点，然后刷新一次内容；场景缺容器时 push_warning 并整块跳过（不崩）。
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


## 造一个装备栏格子的**固定部分**：尺寸、栏位名标签、事件接线。
## 参数 slot_type：这个格子收哪种装备（ItemBase.EquipType）。它被写进按钮的 meta，
##   之后 _refresh_equip_slot() 靠 meta 认出"这是哪一栏"。
## 返回值：Button（内容由 _refresh_equip_slot 填）。
## 事件只接一次（按下 = 请求脱下；悬停/聚焦 = 弹属性卡），内容变了不用重连 ——
##   这正是"换角色不重建按钮"的关键。
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


## 按"当前展示的角色"刷新 6 个装备栏的内容 —— 换角色、穿、脱都走这里。
## 参数：无（读 current_character() 与 Global.equipment_by_character）。
## 副作用：改每个按钮的图标 / 描边 / 可用状态 / tooltip；重建 _equip_slots
##        （有装备的那几格才会进键盘焦点环）。
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


## 刷新单个装备栏：这个角色这一栏穿着什么，就画成什么样。
## 参数 slot：格子按钮；slot_type：它收哪种装备。
## 返回值：无。
## 副作用：
##   · **空栏位** → 图标清空、disabled（不可点、不进焦点环）、栏位名居中、原生 tooltip 说明怎么穿；
##   · **有装备** → 图标 + 按稀有度描边 + 栏位名缩到底部、可点（点 = 脱）、悬停弹属性卡。
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


## 悬停 / 聚焦某个装备栏时弹属性卡。**现取**当前角色这一栏的装备 —— 不能提前绑定 item，
## 因为换角色/换装备后 item 会变，而事件只连了一次。
## 参数 slot：格子按钮；slot_type：它收哪种装备。
## 副作用：调 TooltipManager 显示卡片；空栏位什么都不做（交给原生 tooltip）。
func _show_equip_tip(slot: Control, slot_type: int) -> void:
	var item: ItemBase = GameRoot.equipment_in(current_character(), slot_type)
	if item != null:
		TooltipManager.show_for_control(slot, item)


## 栏位名标签：缩到格子**底部**那一行（有装备时用，图标画在它上面）。
func _set_tag_bottom(tag: Label) -> void:
	tag.anchor_left = 0.0
	tag.anchor_right = 1.0
	tag.anchor_top = 1.0
	tag.anchor_bottom = 1.0
	tag.offset_left = 2.0
	tag.offset_right = -2.0
	tag.offset_top = -(EQUIP_LABEL_HEIGHT + 2.0)
	tag.offset_bottom = -2.0


## 栏位名标签：**居中**铺满格子（空栏位用，像"坑位"）。
func _set_tag_center(tag: Label) -> void:
	tag.anchor_left = 0.0
	tag.anchor_right = 1.0
	tag.anchor_top = 0.0
	tag.anchor_bottom = 1.0
	tag.offset_left = 2.0
	tag.offset_right = -2.0
	tag.offset_top = 0.0
	tag.offset_bottom = 0.0


## 背包界面当前展示的是谁（◀ / ▶ 切换的那个团队成员；团队为空时退回当前主角）。
## 谁"当前展示"，就显示谁的装备栏、点背包格子也穿给谁 —— 这是"每人一套装备"的入口。
## 返回值：UnitStats；实在没有角色时返回 null（装备栏会全空，穿装备会被 GameRoot 拒绝）。
## 副作用：无（纯读）。
func current_character() -> UnitStats:
	if _view_index >= 0 and _view_index < _party.size():
		var member: UnitStats = _party[_view_index]
		if member != null:
			return member
	return Global.main_player_selected


## 把玩家形象刷成"当前展示的团队成员"。
## 数据来源：current_character()（团队名册 + ◀ / ▶ 的下标；名册为空时退回当前主角）。
## 贴图就是地图上那个小人用的同一张（UnitStats.icon）—— 所以背包里的形象和场上一致。
## 副作用：改 player_view.texture / 两个箭头的 disabled / 名字标签的文字；不读写游戏数据。
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


## ◀ / ▶ 的回调：在团队名册里前后翻一个（越界就回卷）。
## 参数 step：-1 = 上一个，+1 = 下一个。
## 副作用：改 _view_index、播 UI 音效、刷新形象/名字，并**把 6 个装备栏刷成新角色的那一套**
##   （每个角色各穿各的）；不改任何游戏数据（只改"看谁"）。
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


## 团队里"当前主角"排第几（用来决定打开背包时先展示谁）。
## 返回：下标；主角不在团队里（或团队为空）时返回 0 —— 于是展示团队第一个人。
func _index_of_leader() -> int:
	var index := _index_of(Global.main_player_selected)
	return maxi(0, index)


## 某个角色在名册里的下标（引用或 resource_path 相同都算同一个人）；找不到返回 -1。
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

## 当前窗口高度（像素）。给"和背包并排"的面板用：它们要看起来一样高（见 StatsPanel.set_linked_height）。
## 返回值：Panel 的 size.y；还没算过几何时返回 0（调用方按 0 处理即可）。
func panel_height() -> float:
	var node := get_node_or_null(^"Panel") as Panel
	return node.size.y if node != null else 0.0


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
## 参数 item：这一格放什么；null = 空格子（画成暗色、不可点、不可聚焦）。
##   类型是 **ItemBase**：武器、以及以后的头盔/项链等新装备都走这里，
##   因为格子只用到 item_icon / item_tier 这两个基类字段。
## 有东西的格子：
##   · 用 Button.icon + expand_icon 直接显示图标（比嵌 TextureRect 简单，且自带按下/悬停反馈）；
##   · 按稀有度换描边颜色（Global.TIER_COLORS），和商店/提示卡一套配色；
##   · mouse_entered / focus_entered 弹 hover_item_card，离开时收起；
##   · **点一下 = emit item_activated**：交易时是"卖"，平时是"穿"（由 WorldMap 分流）。
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


## 背包格子被点：发"这个格子被点了"（见文件头"点了格子 = 卖 / 穿"）。
## 参数 item：这一格的道具。副作用：播 UI 音效 + emit item_activated。
func _on_slot_pressed(item: ItemBase) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	item_activated.emit(item)


## 格子的方形描边样式（梦幻西游那种一格一格的感觉）。
## 参数 border：描边颜色（有东西时按稀有度、空格子是半透明白）。
## 参数 bg：底色（半透明，压在面板的深色背景上）。
## 参数 bottom_margin：底部留白。背包格子用默认值；**装备栏**要传 EQUIP_LABEL_HEIGHT+4 ——
##   它下面还有一行栏位名，图标不能压上去。
## 说明：expand_icon 会把图标撑满按钮，所以内边距靠 StyleBox 的 content_margin 留出来 ——
##   这是 Button 唯一"正规"的留白开关（按钮没有单独的 padding 属性）。
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

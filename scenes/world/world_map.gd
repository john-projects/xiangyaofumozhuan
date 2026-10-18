# WorldMap —— 可探索的世界地图屏幕：一张地图 = 一个"关卡外景"（scenes/world/world_map.tscn 的根脚本）。
# 职责：按 MapData 摆出地图/玩家/NPC；每帧驱动走动与最近 NPC 判定；NPC 对话面板与传送/招募/拜师按钮；
#       把界面动作翻译成 signal 交给 GameRoot。
# 约定：本节点是 Node2D 不是 Control，UI 全在子 CanvasLayer(UI) 下；setup() 先于 add_child，只存数据，
#       碰 @onready 变量会拿到 null，真正的搭建都在 _ready()。
# 坐标：MapSprite.centered = false，原点在图片左上角，world = normalized * _map_size（图片尺寸 × map_scale）。
# 坑：运行时 add_child 的 NPC/按钮 owner 为 null，只能自己 queue_free；对话面板按钮每次打开都新建。

extends Node2D
class_name WorldMap

## 可探索的地图：底图等比放大成世界，玩家自由走动、相机跟随，与 NPC 对话后传送。
## 传送双向：哪张图能去哪张由各图 NPC 的 destinations 决定；从 A 到 B 会优先出现在 B 里"指回 A"的 NPC 旁。
## 扩展点：战斗遇敌改挂 NPC、走路动画换 AnimatedSprite2D、碰撞加 TileMapLayer + CharacterBody2D、
##   面板加商店/任务/选项分支。

# ── 对外信号（本文件唯一的输出口，全部由 GameRoot 订阅）──
## 玩家点「进入战斗」。GameRoot 收到后调 enter_battle()，打哪张图由 current_map_id 决定。
signal battle_requested
## 玩家在 NPC 面板里选了目的地。参数是目标地图 id（MapData.id）。
signal travel_requested(map_id: String)

## 玩家点了某个队友的「加入」。参数 stats：要招募的 UnitStats（资源，不是节点）。
## ⚠ 只请求，本文件不改队伍；GameRoot 判定后回调 notify_party_changed() 刷新面板。
signal recruit_requested(stats: UnitStats)

## 玩家点了「移出队伍」。参数 stats：要移出的 UnitStats。只请求，由 GameRoot 移除后回调刷新。
signal party_remove_requested(stats: UnitStats)

## 玩家点了「上阵」。参数 stats：要上阵的 UnitStats。只请求，GameRoot 判规则后回调刷新。
signal party_deploy_requested(stats: UnitStats)

## 玩家点了「下阵」。参数 stats：要下阵的 UnitStats。至少要留 1 人上阵。
signal party_undeploy_requested(stats: UnitStats)

## 商人面板里点了「购买」。参数 item：要买的道具。只请求，GameRoot 判定后回调 notify_shop_changed()。
signal item_buy_requested(item: ItemBase)
## 交易时确认要卖背包里的东西。参数 item：要卖的道具。只请求，成功后回调 notify_shop_changed()。
signal item_sell_requested(item: ItemBase)
## 没开商人时点了背包里的装备：穿到当前展示的角色身上。
## 参数 character：背包当前展示的成员；item：道具。只请求，成功后回调 notify_bag_changed()。
signal equip_requested(character: UnitStats, item: ItemBase)
## 点了某角色已穿上的装备栏：脱下来放回背包。参数 slot_type：ItemBase.EquipType 成员值。
## 只请求，由 GameRoot.unequip_slot() 判定（角色为空/栏位空/背包满会拒绝）。
signal unequip_requested(character: UnitStats, slot_type: int)

## 拜师面板里点了某个队员。参数 character：该队员；sect_id：Global.SECTS 的键。
## 只请求，由 GameRoot.can_join_sect() 判定种族/已有门派，成功后回调 notify_sect_changed()。
signal sect_join_requested(character: UnitStats, sect_id: String)

## 玩家点了「返回主菜单」。GameRoot 收到后调 show_title()。
signal back_to_title_requested

# ── 常量 ──
## NPC 场景。preload：加载时解析，之后每次 _add_npc() 只 instantiate()。
const NPC_SCENE := preload("res://scenes/world/world_npc.tscn")
## 操作菜单（Esc 唤出）。见 scenes/ui/pause_menu/。
const PAUSE_MENU_SCENE := preload("res://scenes/ui/pause_menu/pause_menu.tscn")
## 队伍管理二级页（操作菜单 →「队伍管理」）。见 scenes/ui/party_panel/。
const PARTY_PANEL_SCENE := preload("res://scenes/ui/party_panel/party_panel.tscn")
## 商人面板（NPC 交互类型 SELL_WEAPONS，按 E 直接打开）。见 scenes/ui/merchant_panel/。
const MERCHANT_PANEL_SCENE := preload("res://scenes/ui/merchant_panel/merchant_panel.tscn")
## 背包（操作菜单的「背包」或地图上按 B）。见 scenes/ui/bag_panel/。
const BAG_PANEL_SCENE := preload("res://scenes/ui/bag_panel/bag_panel.tscn")
## 角色属性面板（操作菜单的「角色属性」或地图上按 C）。见 scenes/ui/stats_panel/。
const STATS_PANEL_SCENE := preload("res://scenes/ui/stats_panel/stats_panel.tscn")
## 对话面板最小高度。**必须等于 world_map.tscn 里 TravelPanel 的原始高度 200**，否则面板高度会莫名跳一下。
const PANEL_MIN_HEIGHT := 200.0
## 对话面板离屏幕底边的留白（像素）。面板是底部居中的横条，宽度靠 tscn 里的左右锚点 0.125 / 0.875。
const PANEL_BOTTOM_MARGIN := 24.0
## 选项按钮高度（像素）。不要用 52：文字只占 20 多，会显得很空；34 + 2px 行距刚好紧凑。
const PANEL_OPTION_HEIGHT := 34.0
const PANEL_OPTION_FONT := 20
## 选项文字的左内边距（像素）：默认主题只给 4px，会贴着边框。
const PANEL_BUTTON_INDENT := 16.0
## 可选项的文字颜色（金色）；置灰的（已入门派/种族不符）保持灰色。
const PANEL_OPTION_COLOR := Color(0.95, 0.82, 0.45)
## 可选项在悬停/按下/聚焦时的颜色（更亮）。
const PANEL_OPTION_COLOR_ACTIVE := Color(1.0, 0.92, 0.62)

## 玩家移动时的边缘留白（像素，世界坐标）；_move_player() 用它做 clamp。
const EDGE_MARGIN := 60.0

# ── 跟随队伍的数值（只影响观感，不影响任何玩法数据）──
## 队长每移动这么远，往轨迹里记一个点（像素）。越小越平滑，但轨迹数组涨得越快。
const TRAIL_SPACING := 2.0
## 轨迹最多保留多少个点（400 × 2px = 800px 的历史路径，够 4 个跟随者排在后面）。
const TRAIL_MAX := 400
## 每个跟随者落后多少个轨迹点（20 × 2px = 40px 一个人，5 人一支队伍约 160px）。
const TRAIL_STEP := 20
## 跟随者的"追上去"速度：每帧按 1 - exp(-speed × delta) 插值，越大跟得越紧（不至于瞬移）。
const COMPANION_FOLLOW_SPEED := 12.0

# ── 数值（可在检视面板里逐张地图微调，也可在专用子场景里覆盖）──
## 基础移动速度（像素/秒，世界坐标，已按 map_scale 放大）。380 ≈ 4096 宽的地图 11 秒横穿。
@export var move_speed := 380.0
## 按住 dash 时的速度倍率（1.9 ≈ 722 px/s，够快但仍能看清沿途）。
@export var dash_multiplier := 1.9
## 交互判定半径（像素，世界坐标）。150 ≈ 3 个角色宽度，不用精确站到 NPC 身上。
@export var interact_radius := 150.0
## 战斗结算文案停留多久（秒）后开始淡出。默认 3.0：足够读完一行"战斗胜利 + 金币"。
@export var result_toast_time := 3.0
## 普通「一行弹窗」停留时间（秒）：扫一眼就走，不打断操作。
const TOAST_TIME := 1.5
## 弹窗条的宽度（像素）。屏幕居中，太长会换行，所以给一个够读一行中文的宽度。
const TOAST_WIDTH := 720.0
## 弹窗淡出动画时长（秒）。
const TOAST_FADE_TIME := 0.35

# ── 运行时状态（换图 = 换节点，全部重新来）──
## 本屏幕要渲染的那张地图的配置。由 setup() 注入；_ready() 里若为 null 会直接 return。
var _map: MapData
## 团队大名单。本文件只展示/传递，不复制不修改；真正的副本化在 GameRoot._make_player_team()。
var _party: Array[UnitStats] = []
## 上阵名单（最多 5 人），GameRoot 在 add_child 之前用 `world.deployed = ...` 注入（引用语义，就地增删可见）。
## 本文件只读它来画「上阵/下阵」按钮的状态，从不修改。
var deployed: Array[UnitStats] = []

# ── 队伍立绘：队长名字 + 上阵队友跟随（见 _setup_party_visuals / _rebuild_companions）──
## 队长头顶的名字 Label（运行时加到 Player 下面，跟着一起走）。
var _leader_name_label: Label = null
## 场上每个上阵队友的跟随小人（Node2D：Shadow + Sprite2D + 名字 Label）。
var _companions: Array[Node2D] = []
## 队长的面包屑轨迹：索引 0 = 最新。跟随者按固定间隔取点，于是自然排成一列而不是叠在一起。
var _trail: Array[Vector2] = []
## 上一个记录进轨迹的位置（避免原地抖动也一直塞点）。
var _last_trail_pos := Vector2.INF
## 顶部要飘的结算文案（例如"战斗胜利！获得 40 金币"）。空字符串 = 不显示。
var _result := ""
## 本图是否已通关过。只影响地图名后面那句"（已通关）"。
var _cleared := false
## "我是从哪张图走过来的"（地图 id）。用来决定在目标图里出生在哪个 NPC 旁边，双向传送不迷路。
var _from_map_id := ""
## map_id → 地图显示名 的字典，由 GameRoot 传入，用于把目的地 id 翻译成按钮上的中文。
var _map_names: Dictionary = {}

## GameRoot 可在 add_child 之前设：非 INF 时优先当出生点（归一化），实现"打完战斗回到原地"。
## ⚠ Vector2.INF 是"没设过"的哨兵，必须在 add_child 前赋值（_ready() 会立刻读它）。
var spawn_override := Vector2.INF

## 世界像素尺寸 = 图片尺寸 × map_scale，所有像素换算的唯一依据。ZERO = 没配图，_process 直接跳过。
var _map_size := Vector2.ZERO
## 本次生成的 NPC 节点列表（运行时 add_child 进来的，owner 为 null）。
var _npcs: Array[WorldNPC] = []
## 当前高亮的 NPC（离玩家最近且进入 interact_radius 的那个），没有则为 null。
var _nearest: WorldNPC = null
## 对话/传送面板是否打开。为 true 时 _process 不处理走动，避免"一边看对话一边飘走"。
var _panel_open := false

## 当前打开着面板的那个 NPC（null = 面板没开）。重建按钮区要靠它区分类型；关闭面板时置 null。
var _panel_npc: WorldNPC = null

## 各浮层开关。与 _panel_open 一起构成 _ui_open()：任一为 true 就冻住走动、输入走 UI 分支。
var _menu_open := false
## 分开存是为了 _unhandled_input 里按优先级分支（交易 > 属性 > 背包 > 队伍 > 菜单 > NPC 面板）。
var _party_open := false
var _shop_open := false
var _bag_open := false
## 角色属性面板开着吗（和背包一样是"普通二级页"，不跟商人交易共存）。
var _stats_open := false

## 这次背包是从操作菜单进来的吗（决定关背包时是回游戏还是退回菜单）。见 _open_bag/_close_bag。
var _bag_from_menu := false
## 背包是"商人交易"顺手打开的吗。true 时关交易会把背包一起收掉（见 _close_merchant）。
var _bag_with_shop := false

## 这次属性面板是从操作菜单进来的吗（关掉时退回菜单，语义同 _bag_from_menu）。
var _stats_from_menu := false

## 当前商人的配置（开面板时记下，买完重建货架要用）。null = 商人面板没开。
## 商人**不走** NPC 对话面板，所以 _panel_npc 对商人一直是 null，得单独记。
var _merchant_data: MapNPC

## 当前浮层的焦点环（按视觉顺序）。W/S 用它循环；打开浮层/重建列表时填，关掉时清空。
var _focus_ring: Array[Control] = []

## 五个 UI 浮层节点（运行时实例化，见 _setup_overlays）。
var _pause_menu: PauseMenu
var _party_panel: PartyPanel
var _merchant_panel: MerchantPanel
var _bag_panel: BagPanel
var _stats_panel: StatsPanel

# ── 场景节点引用（% = unique_name_in_owner）──
# @onready 变量在 _ready() 前一刻才赋值，所以 setup() 里读它们是 null。
## 地图底图。texture / scale / centered 都在 _ready() 里按 MapData 设置。
@onready var map_sprite: Sprite2D = %MapSprite
## 玩家容器节点（本文件直接改它的 position，不用 CharacterBody2D）。
@onready var player: Node2D = %Player
## 玩家贴图。有角色 icon 时显示它，没有时隐藏并显示下面的色块兜底。
@onready var player_sprite: Sprite2D = %PlayerSprite
## 玩家占位色块（Polygon2D）。仅在角色没配 icon 时可见。
@onready var player_fallback: Polygon2D = %PlayerFallback
## 相机。它是 Player 的**子节点**，所以只要玩家移动，相机天然跟随（省掉每帧同步）。
@onready var camera: Camera2D = %Camera
## 左上角地图名标签（通关后会追加"（已通关）"）。
@onready var map_name_label: Label = %MapNameLabel
## 底部提示（"按 E 与 xxx 交谈"），由 _update_nearest() 每帧开关。
@onready var hint_label: Label = %HintLabel
## 屏幕中央的「一行弹窗」栈（VBox）：结果提示、拜师/招募回执都往这里加。
@onready var toast_stack: VBoxContainer = %ToastStack
## 右下角「进入战斗」按钮。地图的 battle_enabled 为 false 时置灰。
@onready var battle_button: Button = %BattleButton
## 左下角「返回主菜单」按钮。
@onready var back_button: Button = %BackButton
## 中央的 NPC 对话/传送面板（Panel）。默认隐藏。
@onready var panel: Panel = %TravelPanel
## UI 层（CanvasLayer）。操作菜单等浮层运行时挂到这里（见 _setup_overlays），不随相机移动、不参与 y_sort。
@onready var ui_layer: CanvasLayer = $UI
## 面板里的 NPC 名字 + 冒号（和台词**同一行**，见 PanelLine 那个 HBox）。
@onready var panel_name: Label = %PanelName
## NPC 台词。名字在它左边同一行（「名字：台词」），所以比名字单独一行时矮一截。
@onready var panel_dialogue: Label = %PanelDialogue
## 面板里动态生成传送按钮的竖排容器（每次打开都会清空重建）。
@onready var panel_buttons: VBoxContainer = %PanelButtons
## 面板右下角的「再想想」按钮，等价于按 Esc 关闭。
@onready var close_button: Button = %CloseButton

## 只存数据，搭建留给 _ready()：GameRoot 是"先 setup 再 add_child"，此时 @onready 变量全是 null。
## 参数：p_map 本图配置；p_party 出战队伍（只保引用，不复制不修改）；result_text 顶部结算文案（空串 = 不飘）；
##   p_cleared 是否已通关；p_map_names map_id → 显示名；p_from_map_id 从哪张图来（决定出生点）。
## 副作用：只写私有字段，不 emit 信号、不碰 Global、不建节点。
func setup(p_map: MapData, p_party: Array[UnitStats], result_text: String,
		p_cleared: bool, p_map_names: Dictionary, p_from_map_id := "") -> void:
	_map = p_map
	_party = p_party
	_result = result_text
	_cleared = p_cleared
	_map_names = p_map_names
	_from_map_id = p_from_map_id


## 进树时执行一次：按 _map 把整张地图搭出来（尺寸 → 玩家 → 相机 → 队伍立绘 → NPC → UI）。
## 副作用：改子节点与三个按钮的连接；_show_result() 里的 await 协程在节点释放后会因 is_instance_valid 安全退出。
func _ready() -> void:
	# 没拿到 MapData（GameRoot 忘了 setup）：直接返回，避免 _map.texture 空引用。
	if _map == null:
		push_warning("WorldMap: 没有拿到 MapData")
		return

	# ── 地图 ──
	# centered = false 是坐标约定的基石：原点回到左上角，"world = normalized × _map_size"才成立。
	map_sprite.texture = _map.texture
	map_sprite.centered = false
	map_sprite.scale = Vector2.ONE * _map.map_scale
	# 图片在编辑器里可能是 null（.tres 忘配图）：先判空再取尺寸，否则 get_size() 会报错。
	var tex_size := Vector2.ZERO
	if _map.texture != null:
		tex_size = Vector2(_map.texture.get_size())
	_map_size = tex_size * _map.map_scale
	# 尺寸为 0 时走不动也看不到东西，但不算致命错误 —— 只警告，继续跑完 UI 初始化。
	if _map_size == Vector2.ZERO:
		push_warning("WorldMap: %s 没配 texture，走不动也看不到东西" % _map.display_name)

	# ── 玩家 ──
	# 没选人时用场景里预置的蓝色方块占位，直接运行 world_map.tscn 调试也能看出玩家在哪。
	var icon := _player_icon()
	player_sprite.texture = icon
	player_fallback.visible = icon == null
	player.position = _world_pos(_spawn_normalized())

	# ── 相机（挂在玩家下面，自动跟随）──
	_setup_camera()

	# ── 队伍立绘：队长名字 + 上阵队友跟随 ──
	# 必须排在 player.position 设好之后：跟随者要靠轨迹排在队长身后。
	_setup_party_visuals()

	# ── NPC ──
	_spawn_npcs()

	# ── UI ──
	# 三个按钮只连一次 pressed；本节点随场景销毁，连接会自动断，不用手动 disconnect。
	battle_button.pressed.connect(_on_battle_pressed)
	back_button.pressed.connect(_on_back_pressed)
	close_button.pressed.connect(_close_panel)
	# battle_enabled = false 的地图（纯剧情图）置灰「进入战斗」。
	battle_button.disabled = not _map.battle_enabled
	map_name_label.text = "%s%s" % [_map.display_name, "（已通关）" if _cleared else ""]
	# 初始没有最近 NPC，提示先藏起来；面板同理。
	hint_label.visible = false
	panel.hide()
	# 浮层放在 _map 已拿到之后：操作菜单要按 _map.battle_enabled 决定「进入战斗」灰不灰。
	_setup_overlays()
	# 「再想想」和选项按钮一样：文字居左 + 同样的左内边距（整块看起来像一张选项列表）
	_indent_button(close_button)
	_show_result()


## 取当前主角的头像（读 Global.main_player_selected）。
## 返回 null 表示没选人（调用方据此显示占位色块）；返回的是共享 Resource 的贴图引用，只读。
func _player_icon() -> Texture2D:
	var stats := Global.main_player_selected
	return stats.icon if stats != null else null


## 显示 setup 时存下的结算文案；空串直接返回（淡出由 _add_toast_line 负责）。
func _show_result() -> void:
	if _result.is_empty():
		return
	show_toast(_result, result_toast_time)


## 推一条或多条「一行弹窗」提示，屏幕中央居中、往下排。
## 参数 message 可用 \n 分多条（每条一个弹窗）；seconds 停留秒数（默认 TOAST_TIME）。
func show_toast(message: String, seconds := TOAST_TIME) -> void:
	if message.strip_edges().is_empty() or toast_stack == null:
		return
	for line in message.split("\n"):
		var text := line.strip_edges()
		if text.is_empty():
			continue
		_add_toast_line(text, seconds)


## 加一条弹窗，seconds 秒后淡出移除。
## 坑：await 期间可能已换地图（本节点被 queue_free），所以每次都要 is_instance_valid。
func _add_toast_line(text: String, seconds: float) -> void:
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE     # 弹窗永远不挡鼠标
	box.add_theme_stylebox_override("panel", _toast_style())
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 22)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	toast_stack.add_child(box)
	_layout_toast_stack()
	await get_tree().create_timer(seconds).timeout
	if not is_instance_valid(box):
		return
	var tween := create_tween()
	tween.tween_property(box, "modulate:a", 0.0, TOAST_FADE_TIME)
	await tween.finished
	if is_instance_valid(box):
		box.queue_free()
		_layout_toast_stack.call_deferred()


## 重排弹窗栈：宽度固定、水平居中、上边贴屏幕中心线。
## 坑：VBoxContainer 不会自己长高，必须先按内容算高度再撑开 rect，否则子节点被压成 0 高。
func _layout_toast_stack() -> void:
	if toast_stack == null:
		return
	toast_stack.offset_left = -TOAST_WIDTH * 0.5
	toast_stack.offset_right = TOAST_WIDTH * 0.5
	toast_stack.offset_top = 0.0
	toast_stack.offset_bottom = toast_stack.get_combined_minimum_size().y


## 弹窗底板：较实的黑底 + 金边 + 圆角。⚠ alpha 别调太低（0.88），花纹地图上会看不清字。
func _toast_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.03, 0.05, 0.88)
	style.border_color = Color(0.90, 0.78, 0.45, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


# ── 坐标换算 ──

## 归一化坐标 → 世界像素坐标，全文件唯一的换算入口。输入 (0,0) 是图片左上角，(1,1) 是右下角。
## 纯函数；_map_size 为 0 时返回 (0,0)。
func _world_pos(normalized: Vector2) -> Vector2:
	return normalized * _map_size


## 出生点（归一化），优先级：spawn_override（战斗回原地）> 指回 _from_map_id 的 NPC 旁 > _map.spawn_point。
## 站在传送 NPC 旁时 +0.04 是相对图高的偏移，避免和 NPC 完全重叠（贴图互相盖住、距离判定一开始就贴着）。
func _spawn_normalized() -> Vector2:
	if spawn_override != Vector2.INF:
		return spawn_override
	if not _from_map_id.is_empty():
		for npc_data in _map.npcs:
			if npc_data != null and npc_data.destinations.has(_from_map_id):
				return npc_data.position + Vector2(0.0, 0.04)
	return _map.spawn_point


## 玩家当前位置（归一化），GameRoot 用它记住"离开这张图时站在哪"。_map_size 为 0 时返回 ZERO 防除零。
func player_normalized() -> Vector2:
	if _map_size == Vector2.ZERO:
		return Vector2.ZERO
	return player.position / _map_size


## 相机开平滑跟随，并在"地图比视口大"的方向上限制可视范围。
## 为什么加 if：limit 一旦设成 0..尺寸就把相机锁死，地图比视口小时镜头会歪在角落。
func _setup_camera() -> void:
	var view := get_viewport_rect().size
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 8.0
	if _map_size.x > view.x:
		camera.limit_left = 0
		camera.limit_right = int(_map_size.x)
	if _map_size.y > view.y:
		camera.limit_top = 0
		camera.limit_bottom = int(_map_size.y)


# ── NPC ──

## 按 MapNPC 列表生成 NPC；一个都没配时补一个"路牌"兜底（保流程能走到 next_id）。
## 兜底用的 MapNPC 是运行时 new 的临时资源，可放心就地改；.tres 里的共享资源改了会污染所有引用者。
func _spawn_npcs() -> void:
	for npc_data in _map.npcs:
		if npc_data != null:
			_add_npc(npc_data)

	# 兜底：这张图没配 NPC 时，自动放一个能去 next_id 的路牌，保证流程走得通
	if _npcs.is_empty() and not _map.next_id.is_empty():
		var fallback := MapNPC.new()
		fallback.id = "fallback_signpost"
		fallback.display_name = "路牌"
		fallback.dialogue = "（%s 还没配 NPC，先用路牌凑合）" % _map.display_name
		fallback.position = _map.exit_center
		# destinations 是 Array[String]，不能直接赋 [_map.next_id]（弱类型 Array 赋类型化数组会报错），先声明局部变量。
		var dests: Array[String] = [_map.next_id]
		fallback.destinations = dests
		fallback.teleport_label = "前往"
		_add_npc(fallback)


## 实例化 NPC 并摆到世界坐标，登记进 _npcs。
## 顺序：先 add_child 再 setup —— setup 要访问 @onready 变量（%Sprite 等），只有进树后才有。
func _add_npc(npc_data: MapNPC) -> void:
	var npc := NPC_SCENE.instantiate() as WorldNPC
	# 直接挂在 WorldMap 下（WorldMap 开了 y_sort，玩家才能绕到 NPC 身后/身前）
	add_child(npc)
	npc.setup(npc_data)
	npc.position = _world_pos(npc_data.position)
	_npcs.append(npc)


## 每帧找"最近且在 interact_radius 内"的 NPC，维护高亮与底部提示。
## best_distance 初值取半径，距离必须严格小于半径才入选（正好等于不算），边界才不抖。
## 只在 _nearest 真变化时才碰高亮，否则每帧新建 tween 会堆积。
func _update_nearest() -> void:
	var best: WorldNPC = null
	var best_distance := interact_radius
	for npc in _npcs:
		# 列表里的节点可能已经被清掉（理论上本文件不会），判一下更稳。
		if not is_instance_valid(npc):
			continue
		var distance := npc.position.distance_to(player.position)
		if distance < best_distance:
			best_distance = distance
			best = npc

	if best != _nearest:
		if _nearest != null and is_instance_valid(_nearest):
			_nearest.set_highlight(false)
		_nearest = best
		if _nearest != null:
			_nearest.set_highlight(true)

	# 先判 _nearest != null 再访问 .data.display_name，否则属性/下标会报错。
	if _nearest != null:
		hint_label.text = "按 E 与 %s 交谈" % _nearest.data.display_name
		hint_label.visible = true
	else:
		hint_label.visible = false


# ── 每帧：走动 ──

## 每帧驱动：走动 → 轨迹 → 队友跟随 → 最近 NPC 判定（顺序不能反）。
## 提前返回：_map_size 为 ZERO（没配图）或 _ui_open()（看面板/菜单时冻住，否则 WASD 会边选边跑）。
func _process(delta: float) -> void:
	if _map_size == Vector2.ZERO or _ui_open():
		return
	_move_player(delta)
	# 走动之后：记轨迹 → 队友沿着轨迹跟上（顺序不能反，否则队友永远慢一帧的位置）
	_update_trail()
	_update_companions(delta)
	_update_nearest()


## 按输入向量移动玩家并夹在地图内；dash 按住即持续冲刺，flip_h 只在 |dir.x| > 0.01 时更新以免朝向抖动。
## 上界写 maxf(EDGE_MARGIN, size - EDGE_MARGIN)：地图比两倍留白还小时，否则会把玩家拉到图外。
func _move_player(delta: float) -> void:
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if dir == Vector2.ZERO:
		return
	var speed := move_speed * (dash_multiplier if Input.is_action_pressed("dash") else 1.0)
	player.position += dir * speed * delta
	player.position.x = clampf(player.position.x, EDGE_MARGIN, maxf(EDGE_MARGIN, _map_size.x - EDGE_MARGIN))
	player.position.y = clampf(player.position.y, EDGE_MARGIN, maxf(EDGE_MARGIN, _map_size.y - EDGE_MARGIN))
	if absf(dir.x) > 0.01:
		player_sprite.flip_h = dir.x < 0.0


# ── 队伍立绘：队长名字 + 上阵队友跟随 ──
# 名字 Label 挂在角色节点下（跟着变换，不用每帧同步）；跟随用面包屑轨迹而不是固定偏移，
# 队长拐弯时队友沿走过的路跟来，不斜穿墙角也不会叠在一点。

## 建队长名字 + 队友小人（_ready 调一次；队伍变化时走 _rebuild_companions）。
func _setup_party_visuals() -> void:
	if _leader_name_label == null:
		_leader_name_label = _make_name_label(18)
		player.add_child(_leader_name_label)
	_update_leader_name()
	_rebuild_companions()


## 刷新队长头顶的名字（队长换人/改名时调；平时只在 _setup_party_visuals 里调一次）。
func _update_leader_name() -> void:
	if _leader_name_label == null:
		return
	var leader := _leader_stats()
	_leader_name_label.text = leader.name if leader != null else ""
	_leader_name_label.visible = leader != null


## 当前"队长"（地图上那个能操控的 Player）——就是选人时定下的主角。
func _leader_stats() -> UnitStats:
	return Global.main_player_selected


## 两个 UnitStats 是否同一人。用 character_key 比：资源可能被重新加载成新实例，只比引用会漏。
func _same_character(a: UnitStats, b: UnitStats) -> bool:
	if a == null or b == null:
		return a == b
	return GameRoot.character_key(a) == GameRoot.character_key(b)


## 按 deployed 重建跟随者（队长本人不算）。旧小人释放，轨迹预填一条向后的直线，队友一出生就排在身后。
## 调用点：_setup_party_visuals()、notify_party_changed()。
func _rebuild_companions() -> void:
	for node in _companions:
		if is_instance_valid(node):
			node.queue_free()
	_companions.clear()
	# 轨迹预填：从队长脚下向左铺一条直线 —— 跟随者一出生就排在队伍该在的位置，不会叠在队长身上。
	_trail.clear()
	for i in TRAIL_MAX:
		_trail.append(player.position - Vector2(TRAIL_SPACING * i, 0.0))
	_last_trail_pos = player.position
	var leader := _leader_stats()
	var index := 0
	for stats in deployed:
		if stats == null or _same_character(stats, leader):
			continue
		index += 1
		var node := _make_companion(stats)
		node.position = _trail[mini(index * TRAIL_STEP, _trail.size() - 1)]
		_companions.append(node)


## 造一个跟随小人：影子 + 立绘 + 名字（结构同 Player，只是不带相机）。
func _make_companion(stats: UnitStats) -> Node2D:
	var node := Node2D.new()
	node.name = "Companion"
	add_child(node)
	var shadow := Polygon2D.new()
	shadow.name = "Shadow"
	shadow.color = Color(0, 0, 0, 0.3)
	# 和 world_map.tscn 里 Player/Shadow 的椭圆保持一致（场景里那份没法直接复用，这里重写一份）
	shadow.polygon = PackedVector2Array([Vector2(44, 0), Vector2(38, 8), Vector2(22, 13.9),
			Vector2(0, 16), Vector2(-22, 13.9), Vector2(-38, 8), Vector2(-44, 0),
			Vector2(-38, -8), Vector2(-22, -13.9), Vector2(0, -16), Vector2(22, -13.9),
			Vector2(38, -8)])
	node.add_child(shadow)
	var sprite := Sprite2D.new()
	sprite.name = "Sprite"
	sprite.texture = stats.icon
	sprite.scale = Vector2(1.3, 1.3)      # 和 PlayerSprite 的缩放一致
	node.add_child(sprite)
	var label := _make_name_label(16)
	label.text = stats.name
	node.add_child(label)
	return node


## 造"头顶名字"标签（白字 + 黑描边，压在地图上也看得清）。参数 font_size：队长 18、队友 16。
func _make_name_label(font_size: int) -> Label:
	var label := Label.new()
	label.name = "NameLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 别挡住底下的点击
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 5)
	label.size = Vector2(220, 30)
	label.position = Vector2(-110, -78)               # 以角色脚下为原点，往上抬到头顶
	return label


## 记录队长轨迹：沿"上一记录点 → 当前位置"每 TRAIL_SPACING 像素插一个点。
## 为什么不按帧塞点：每帧位移随帧率/冲刺变化，固定像素间隔才能让队友间距稳定。
func _update_trail() -> void:
	if _last_trail_pos == Vector2.INF:
		_last_trail_pos = player.position
		return
	var delta := player.position - _last_trail_pos
	var dist := delta.length()
	if dist < TRAIL_SPACING:
		return
	var steps := int(dist / TRAIL_SPACING)
	var step_vec := delta / float(steps)
	var pos := _last_trail_pos
	for i in steps:
		pos += step_vec
		_trail.push_front(pos)
	_last_trail_pos = pos          # 不足一个间隔的零头留到下一帧，不丢
	if _trail.size() > TRAIL_MAX:
		_trail.resize(TRAIL_MAX)


## 每帧把队友朝"轨迹上属于他的点"插值挪过去（直接赋值会瞬移，插值才像"跟"上来）。
## 副作用：改小人 position 与 Sprite.flip_h。
func _update_companions(delta: float) -> void:
	if _companions.is_empty() or _trail.is_empty():
		return
	var weight := 1.0 - exp(-COMPANION_FOLLOW_SPEED * delta)
	for i in _companions.size():
		var node := _companions[i]
		if not is_instance_valid(node):
			continue
		var target: Vector2 = _trail[mini((i + 1) * TRAIL_STEP, _trail.size() - 1)]
		var before := node.position
		node.position = before.lerp(target, weight)
		var sprite := node.get_node_or_null(^"Sprite") as Sprite2D
		if sprite != null:
			var dx := node.position.x - before.x
			if absf(dx) > 0.05:
				sprite.flip_h = dx < 0.0


# ── 交互 ──

## 未被子控件消费的输入在这里处理（按钮/面板控件会先吃掉自己的事件）。
## 分支顺序即优先级，不要调换：F1 调试 > 交易 > 属性 > 背包 > 队伍管理 > 操作菜单 > NPC 面板 > 游戏。
## 交易时背包是配件，所以交易那支排在背包前面（两个开关都 true 时谁在前谁说了算）。
## 背包/交易的 WASD 交给面板自己（方格语义），这里只处理 Esc / B / E / C。
## F1 在任何状态下都先响应，不因浮层打开被吞。
## 副作用：开关浮层、移动焦点、按下焦点按钮，并 set_input_as_handled() 阻止继续冒泡。
## 坑：必须过滤 event.echo，否则按住键会一秒开几十次面板。
## 说明：方向键 / Enter / 空格被 GUI 焦点系统更早消费，走不到这里。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		_debug_print_normalized()
		get_viewport().set_input_as_handled()
		return

	if _shop_open:
		# 交易窗口：方格货架的 WASD 交给 MerchantPanel（Global.grid_nav），这里只接 Esc / B / E。
		# Esc = 先关确认框、再关整个交易；B = 收摊（顺手的背包一起收）；E = 按下焦点那一格。
		# 这一支必须排在 _bag_open 前面：交易时两个开关都 true，交易是主窗口、背包是配件。
		if event.is_action_pressed("ui_cancel"):
			if not _merchant_panel.cancel_confirm():
				_close_merchant()
			get_viewport().set_input_as_handled()
		elif _is_bag_key(event):
			_close_merchant()
			get_viewport().set_input_as_handled()
		elif _is_interact_event(event) and Global.activate_focused(self):
			get_viewport().set_input_as_handled()
		return

	if _stats_open:
		# 属性面板和背包互相独立：C / Esc 只收属性面板，B 单独开关背包。
		# ⚠ 排在 _bag_open 前面：两个都开着时 B 归这里管，否则会变成背包抢着关自己。
		if event.is_action_pressed("ui_cancel") or _is_stats_key(event):
			_close_stats()
			get_viewport().set_input_as_handled()
		elif _is_bag_key(event):
			_toggle_bag_with_stats()
			get_viewport().set_input_as_handled()
		return

	if _bag_open:
		# 背包的 WASD 交给 BagPanel（上下要跳一整行），这里不能调 _overlay_nav()，否则 WASD 被吃掉。
		if event.is_action_pressed("ui_cancel") or _is_bag_key(event):
			_close_bag()
			get_viewport().set_input_as_handled()
		elif _is_stats_key(event):
			_open_stats()          # 背包开着时按 C：属性面板叠在旁边，并对齐到同一个人
			get_viewport().set_input_as_handled()
		return

	if _party_open:
		if event.is_action_pressed("ui_cancel"):
			_back_from_party_panel()
			get_viewport().set_input_as_handled()
		elif _overlay_nav(event):
			get_viewport().set_input_as_handled()
		return

	if _menu_open:
		if event.is_action_pressed("ui_cancel"):
			_close_pause_menu()
			get_viewport().set_input_as_handled()
		elif _overlay_nav(event):
			get_viewport().set_input_as_handled()
		return

	if _panel_open:
		if event.is_action_pressed("ui_cancel"):
			_close_panel()
			get_viewport().set_input_as_handled()
		elif _overlay_nav(event):
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_cancel"):
		_open_pause_menu()
		get_viewport().set_input_as_handled()
		return

	if _is_bag_key(event):
		_open_bag()
		get_viewport().set_input_as_handled()
		return

	if _is_stats_key(event):
		_open_stats()
		get_viewport().set_input_as_handled()
		return

	if _nearest != null and _is_interact_event(event):
		_open_panel(_nearest)
		get_viewport().set_input_as_handled()


## 事件是不是"开/关背包"的 B 键。
## 硬编码 KEY_B 而不配 InputMap：界面快捷键统一这么写（F1 也是）；必须过滤 pressed/echo，否则按住会狂开关。
func _is_bag_key(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
		and event.keycode == KEY_B


## 事件是不是"开/关角色属性"的 C 键（写法同 _is_bag_key）。
func _is_stats_key(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
		and event.keycode == KEY_C


## 支持"配了 interact 动作就用它"，没配则用 E / Enter。实现在 Global，主菜单共用。
func _is_interact_event(event: InputEvent) -> bool:
	return Global.is_interact_event(event)


# ── UI 浮层：操作菜单 / 队伍管理 / 商人 / 背包 / 键盘焦点 ──

## 有没有任何挡住走动的 UI 开着（对话面板 / 菜单 / 队伍 / 商人 / 背包 / 属性）。
func _ui_open() -> bool:
	return _panel_open or _menu_open or _party_open or _shop_open or _bag_open or _stats_open


## 实例化五个 UI 浮层并接好信号（_ready 调一次）。挂 UI(CanvasLayer) 下：不随相机、不参与 y_sort。
## 为什么代码接线：这些场景是运行时 instantiate 的，编辑器里连不了信号。
## ⚠ 实例化顺序 = 绘制顺序：交易窗口必须排在背包**后面**，否则背包的全屏遮罩会把交易窗口压暗。
##   （确认框另有 z_index = 100 双保险。）
func _setup_overlays() -> void:
	_pause_menu = PAUSE_MENU_SCENE.instantiate() as PauseMenu
	ui_layer.add_child(_pause_menu)
	_pause_menu.resume_requested.connect(_close_pause_menu)
	_pause_menu.party_requested.connect(_open_party_panel)
	_pause_menu.bag_requested.connect(_on_menu_bag_requested)
	_pause_menu.stats_requested.connect(_on_menu_stats_requested)
	_pause_menu.battle_requested.connect(_on_battle_pressed)
	_pause_menu.title_requested.connect(_on_back_pressed)

	_party_panel = PARTY_PANEL_SCENE.instantiate() as PartyPanel
	ui_layer.add_child(_party_panel)
	_party_panel.close_requested.connect(_back_from_party_panel)
	_party_panel.deploy_requested.connect(_on_party_deploy_requested)
	_party_panel.undeploy_requested.connect(_on_party_undeploy_requested)
	_party_panel.remove_requested.connect(_on_party_remove_requested)

	_bag_panel = BAG_PANEL_SCENE.instantiate() as BagPanel
	ui_layer.add_child(_bag_panel)
	# 背包现在没有「关闭」按钮，这条连接留给以后；关背包只有 Esc / B 两条路。
	_bag_panel.close_requested.connect(_close_bag)
	# 点背包格子 = "这个格子被点了"：交易界面开着就是卖，否则就是穿（见 _on_bag_item_activated）
	_bag_panel.item_activated.connect(_on_bag_item_activated)
	# 点已穿上的装备栏 = 脱下来放回背包
	_bag_panel.unequip_requested.connect(_on_bag_unequip_requested)
	# 背包换了"看谁" → 并排的属性面板跟着切（反之亦然，见 _on_stats_character_view_changed）
	_bag_panel.character_view_changed.connect(_on_bag_character_view_changed)

	# 属性面板贴左下角、背包贴右下角，所以两者可以同屏、各自都能点。
	_stats_panel = STATS_PANEL_SCENE.instantiate() as StatsPanel
	ui_layer.add_child(_stats_panel)
	_stats_panel.character_view_changed.connect(_on_stats_character_view_changed)
	# 点「＋」加属性点：只重设焦点环（点数花完后「＋」置灰、要退出环），不抢焦点
	_stats_panel.points_spent.connect(_on_stats_points_spent)
	# 手动升级（面板里点「升级」）→ 顶部弹一条提示
	_stats_panel.level_up_reported.connect(show_toast)
	# 属性面板上半部分点已穿的装备栏 = 脱下。和背包同一个人（两边同步），所以直接复用那条通路。
	_stats_panel.unequip_requested.connect(_on_bag_unequip_requested)

	_merchant_panel = MERCHANT_PANEL_SCENE.instantiate() as MerchantPanel
	ui_layer.add_child(_merchant_panel)
	_merchant_panel.close_requested.connect(_close_merchant)
	_merchant_panel.buy_requested.connect(_on_item_buy_requested)
	# 卖出：确认框点「确定」后走到这里
	_merchant_panel.sell_requested.connect(_on_item_sell_requested)
	# 确认框开关 → 同步背包格子的键盘焦点（模态期间不让方向键跑到背包上按 E）
	_merchant_panel.confirm_changed.connect(_on_merchant_confirm_changed)

	# 弹窗栈永远画最上层：浮层都是后加的，不把它挪到最后，弹窗会被面板挡住。
	ui_layer.move_child(toast_stack, -1)


## 打开背包。参数 from_menu：从操作菜单进来（关背包退回菜单，否则回游戏）。
## 参数 as_companion：商人交易顺手打开（关交易时一起收掉，见 _close_merchant）。
## 副作用：重建方格、重置视角到队长、格子可聚焦、聚焦第一格（焦点落上去 TooltipManager 就会弹属性卡）。
## 每次都重建：背包随时可能被商人改动，现取最不容易看到旧内容。
func _open_bag(from_menu := false, as_companion := false) -> void:
	_bag_open = true
	_bag_from_menu = from_menu
	_bag_with_shop = as_companion
	if from_menu:
		_pause_menu.hide()
		_menu_open = false        # 菜单确实不显示了，状态位要跟着诚实（关闭时由 _close_bag 再弹回来）
	_bag_panel.clear_message()
	# 单独开背包（非交易）时点格子是穿装备，把这条提示写在信息行。
	if not as_companion:
		_bag_panel.show_message("点背包里的装备即可给当前角色穿上 · ◀/▶ 换人 · 点已穿的装备栏可脱下")
	_bag_panel.reset_view()       # 重新打开时先看队长（买卖引起的重建不会重置，见 show_bag 说明）
	_bag_panel.set_slot_focus_enabled(true)
	_rebuild_bag()
	# 属性面板也开着时：让两个窗口一样高（背包先算过尺寸，这里取它的实际高度）
	if _stats_open:
		_stats_panel.set_linked_height(_bag_panel.panel_height())
	_set_focus_ring(_combined_ring())
	_sync_world_button_focus()


## 操作菜单里点了「背包」。不能把信号直连 _open_bag：信号无参，from_menu 会丢成 false。
func _on_menu_bag_requested() -> void:
	_open_bag(true)


## 关闭背包回游戏（Esc / B 都走这里）。属性面板若还开着保持原样，焦点环回到它。
## 若这次是从菜单进来的，顺手把菜单弹回来（逐级返回）。
func _close_bag() -> void:
	_bag_open = false
	_bag_with_shop = false
	TooltipManager.hide_tip()
	_bag_panel.hide()
	if _stats_open:
		# 背包收起来后属性面板**保持一样高**（高度锚点还在，没必要缩一下再弹回来）
		_stats_panel.set_linked_height(_bag_panel.panel_height())
	_set_focus_ring(_combined_ring())
	_sync_world_button_focus()
	if _bag_from_menu:
		_bag_from_menu = false
		_open_pause_menu()


## 打开角色属性面板。参数 from_menu 语义同 _open_bag（关掉时退回菜单）。
## 不会自动打开背包（C 只开属性面板）；若背包已开着，则对齐到背包当前看的人与高度，左右并排。
func _open_stats(from_menu := false) -> void:
	_stats_open = true
	_stats_from_menu = from_menu
	if from_menu:
		_pause_menu.hide()
		_menu_open = false        # 菜单确实不显示了，状态位要跟着诚实（关闭时由 _close_stats 再弹回来）
	# 高度始终对齐"背包该有的高度"，单开时和并排时一样高。
	_stats_panel.set_linked_height(_bag_panel.refresh_panel_height())
	_stats_panel.show_stats(_party)
	if _bag_open:
		# 背包先开着的话，属性面板跟着它看同一个人
		_stats_panel.show_character(_bag_panel.current_character())
	_set_focus_ring(_combined_ring())
	_sync_world_button_focus()


## 属性面板开着时按 B：单独开关背包，不动属性面板。
func _toggle_bag_with_stats() -> void:
	if _bag_open:
		_close_bag()
	else:
		_open_bag()


## 属性面板（和一起开的背包）的焦点环。两个面板同屏都能点，只设一个环另一个就永远走不到。
## 顺序：背包格子在前（主操作），属性面板的 ◀ ▶ /「＋」在后。
func _combined_ring() -> Array[Control]:
	var out: Array[Control] = []
	if _bag_open and _bag_panel != null:
		out.append_array(_bag_panel.focus_ring())
	if _stats_open and _stats_panel != null:
		out.append_array(_stats_panel.focus_ring())
	return out


## 操作菜单里点了「角色属性」（同样为了保住 from_menu 才包一层）。
func _on_menu_stats_requested() -> void:
	_open_stats(true)


## 关闭属性面板回游戏（Esc / C 都走这里）。背包若还开着就留着，两个窗口独立。
## 若这次是从菜单进来的，顺手把菜单弹回来。
func _close_stats() -> void:
	_stats_open = false
	TooltipManager.hide_tip()
	_stats_panel.hide()
	_set_focus_ring(_combined_ring())
	_sync_world_button_focus()
	if _stats_from_menu:
		_stats_from_menu = false
		_open_pause_menu()


## 背包换了"看谁"（◀ / ▶）→ 属性面板跟着切到同一个人。
func _on_bag_character_view_changed(character: UnitStats) -> void:
	if _stats_open:
		_stats_panel.show_character(character)


## 属性面板换了"看谁" → 背包跟着切，保证"看谁"和"穿给谁"永远同一个人。
func _on_stats_character_view_changed(character: UnitStats) -> void:
	if _bag_open:
		_bag_panel.show_character(character)


## 属性面板点了一次「＋」：只更新焦点环数组，不 grab 焦点（否则每点一下焦点就跳回 ◀，没法连点）。
## 用 _combined_ring()：背包还开着，格子也得留在环里。
func _on_stats_points_spent() -> void:
	if _stats_open and _stats_panel != null:
		_focus_ring = _combined_ring()


## 按当前背包内容重建方格（打开时调；买卖/合成成功后也可以再调）。
func _rebuild_bag() -> void:
	_bag_panel.show_bag(Global.equipped_weapons, GameRoot.BAG_SLOTS, _party)


## Esc：打开操作菜单。按本图 battle_enabled 决定「进入战斗」是否置灰，并禁用地图上两个常驻按钮的焦点。
func _open_pause_menu() -> void:
	_menu_open = true
	_pause_menu.open(_map.battle_enabled)
	_set_focus_ring(_pause_menu.focus_ring())
	_sync_world_button_focus()


## 关闭操作菜单，回到游戏。
func _close_pause_menu() -> void:
	_menu_open = false
	_pause_menu.hide()
	_focus_ring.clear()
	_sync_world_button_focus()


## 打开队伍管理二级页：把操作菜单藏起来（避免两层都亮着），按 _party 与 deployed 重建列表。
func _open_party_panel() -> void:
	_party_open = true
	_pause_menu.hide()
	_menu_open = false            # 菜单确实不显示了，状态位要跟着诚实（退回时由 _back_from_party_panel 再弹回来）
	_party_panel.clear_message()
	_party_panel.show_party(_party, deployed)
	_set_focus_ring(_party_panel.focus_ring())
	_sync_world_button_focus()


## Esc /「返回」：从队伍管理退回操作菜单（二级页逐级退，而不是直接回游戏）。
func _back_from_party_panel() -> void:
	_party_open = false
	_party_panel.hide()
	_focus_ring.clear()
	_open_pause_menu()


## 点了「上阵」：只把请求转给 GameRoot。
func _on_party_deploy_requested(stats: UnitStats) -> void:
	party_deploy_requested.emit(stats)


## 点了「下阵」：同上，只转请求。
func _on_party_undeploy_requested(stats: UnitStats) -> void:
	party_undeploy_requested.emit(stats)


## 点了「移出团队」：同上，只转请求。
func _on_party_remove_requested(stats: UnitStats) -> void:
	party_remove_requested.emit(stats)


# ── 商人面板（NPC 交互类型 SELL_WEAPONS）──

## 打开商人面板：记下 _merchant_data（买完重建货架要用），按货架/金币/已持有重建，**同时打开背包**。
## ⚠ 交易时背包保持可交互（点格子 = 卖给商人），所以不要 set_slot_focus_enabled(false)；
##   只在确认框弹出时临时收焦点（见 _on_merchant_confirm_changed）。
## 注意它不置 _panel_open：商人不用小对话框面板（_open_panel 在分流处直接 return）。
func _open_merchant(data: MapNPC) -> void:
	_shop_open = true
	_merchant_data = data
	_merchant_panel.buy_label = data.shop_label
	_merchant_panel.clear_message()
	_rebuild_merchant()
	# 同时开背包（as_companion = true：关交易时会一起收掉）
	_open_bag(false, true)
	_bag_panel.set_slot_focus_enabled(true)     # 交易时背包也要能点/能键盘选（要卖东西）
	_set_focus_ring(_merchant_panel.focus_ring())
	_sync_world_button_focus()


## 关闭商人面板回游戏。背包若是交易顺手打开的，一起收掉。
func _close_merchant() -> void:
	_shop_open = false
	_merchant_data = null
	_merchant_panel.hide()
	if _bag_with_shop:
		_close_bag()               # 交易结束，配件背包一起收（_bag_with_shop 由它清掉）
	_bag_panel.set_slot_focus_enabled(true)
	_focus_ring.clear()
	_sync_world_button_focus()


## 重建货架：sell_pool 优先，留空用 Global.get_all_equipment()。
## 传当前金币与已持有：买不起的格子自动置灰，不需要手动 disabled。
func _rebuild_merchant() -> void:
	if _merchant_data == null:
		return
	var items: Array[ItemBase] = _merchant_data.sell_pool if not _merchant_data.sell_pool.is_empty() \
			else Global.get_all_equipment()
	# coins 仍要传：面板靠它判定哪些格子买不起（只是不显示金币）。
	_merchant_panel.show_shop(_merchant_data.display_name, items, Global.coins,
			Global.equipped_weapons)


## 点了「购买」：只把请求转给 GameRoot。
func _on_item_buy_requested(item: ItemBase) -> void:
	item_buy_requested.emit(item)


## 背包格子被点：开了商人就卖（_sell_bag_item），否则穿到背包当前展示的角色身上。
## 分流放在这里而不是 BagPanel："现在是在交易还是换装"是业务状态，界面只负责发请求。
func _on_bag_item_activated(item: ItemBase) -> void:
	if _shop_open:
		_sell_bag_item(item)
		return
	equip_requested.emit(_bag_panel.current_character(), item)


## 把背包里的一件东西卖给商人。先让交易面板弹确认框（写清卖价），确认后才走 GameRoot.sell_item()。
## 已有确认框时直接忽略（否则连点两件会把待确认的悄悄换掉）；卖不了只在信息行说原因。
func _sell_bag_item(item: ItemBase) -> void:
	if _merchant_panel.is_confirm_open():
		return
	var why := GameRoot.item_can_sell(item, Global.equipped_weapons)
	if not why.is_empty():
		_bag_panel.show_message("（%s）" % why)
		return
	_merchant_panel.ask_sell(item, GameRoot.item_sell_price(item))


## 点了已穿装备栏：把脱装备请求转给 GameRoot（目标角色 = 背包当前展示的人）。
## 能不能脱由 GameRoot.unequip_slot() 判，成功后回调 notify_bag_changed()。
func _on_bag_unequip_requested(slot_type: int) -> void:
	unequip_requested.emit(_bag_panel.current_character(), slot_type)


## 卖出确认框点了「确定」：转给 GameRoot。
func _on_item_sell_requested(item: ItemBase) -> void:
	item_sell_requested.emit(item)


## 确认框开关 → 同步背包格子的键盘焦点（模态期间不让方向键跑到背包上按 E）。
func _on_merchant_confirm_changed(open: bool) -> void:
	_bag_panel.set_slot_focus_enabled(not open)


## 金币/背包变化后刷新（GameRoot 买卖成功后调用；失败也调，用来显示原因）。
## 参数 message：非空时写进商人面板提示行。
## 为什么 deferred 重建：调用链多半来自按钮 pressed，立刻 remove_child 会把正在发信号的按钮摘掉。
## ⚠ 交易中不要同步背包焦点（_sync_bag_focus）：焦点归交易窗口，否则玩家挑货时焦点乱飞。
func notify_shop_changed(message := "") -> void:
	refresh_coins()
	if _bag_open:
		_rebuild_bag.call_deferred()
		if not _shop_open:
			_sync_bag_focus.call_deferred()
	if not _shop_open:
		return                       # 商人面板没开就只刷新金币，消息没地方显示（丢掉）
	if not message.is_empty():
		_merchant_panel.show_message(message)
	_rebuild_merchant.call_deferred()
	_sync_merchant_focus.call_deferred()


## 延迟同步商人面板的焦点环（重建是 deferred 的，环也得晚一步再取，否则拿到的是旧按钮）。
func _sync_merchant_focus() -> void:
	if _shop_open and _merchant_panel != null:
		_set_focus_ring(_merchant_panel.focus_ring())


## 背包/装备变化后刷新（GameRoot 穿脱装备后调用；失败也调，用来显示原因）。
## 参数 message：非空时写进背包信息行。
## 副作用：余额；背包开着则重建方格/装备栏并同步焦点环；属性面板开着也刷新（装备加成要跟着变）。
func notify_bag_changed(message := "") -> void:
	refresh_coins()
	if _stats_open:
		# 属性面板直接读 GameRoot/UnitStats，数据已经变了，重建一次就能看到新装备
		_stats_panel.refresh.call_deferred()
	if not _bag_open:
		return
	if not message.is_empty():
		_bag_panel.show_message(message)
	_rebuild_bag.call_deferred()
	if _shop_open:
		# 交易时也能脱下（脱下来就能卖）：货架的"持×n"要跟着变，所以货架也重建
		_rebuild_merchant.call_deferred()
	else:
		_sync_bag_focus.call_deferred()


## 延迟同步背包焦点环（理由同上）；属性面板也开着时用合并环，否则「＋」会从 W/S 候选里消失。
func _sync_bag_focus() -> void:
	if _bag_open and _bag_panel != null:
		_set_focus_ring(_combined_ring())


## 用 Global.coins 刷新金币显示。⚠ 地图上没有金币标签了，这里只同步背包信息行；金币真值始终在 Global.coins。
func refresh_coins() -> void:
	if _bag_panel != null:
		_bag_panel.refresh_coins()


## 浮层开着时把地图上两个常驻按钮设为不可聚焦，关掉后恢复。
## 为什么：GUI 焦点按空间方向找邻居，不禁用的话方向键会把焦点跑出浮层。
func _sync_world_button_focus() -> void:
	var mode := Control.FOCUS_NONE if _ui_open() else Control.FOCUS_ALL
	battle_button.focus_mode = mode
	back_button.focus_mode = mode


## 设置焦点环并聚焦第一个。⚠ 调用前浮层必须已经 show()：grab_focus() 对隐藏控件静默失败，键盘会整片失灵。
func _set_focus_ring(controls: Array[Control]) -> void:
	_focus_ring = controls
	if not _focus_ring.is_empty():
		_focus_ring[0].grab_focus()


## 在焦点环里前后循环（W/S）。实现在 Global.step_focus()，与主菜单共用。
func _step_focus(step: int) -> void:
	Global.step_focus(self, _focus_ring, step)


## 按下焦点上的按钮（E）。实现在 Global.activate_focused()。
func _activate_focused() -> void:
	Global.activate_focused(self)


## 浮层键盘操作：W/S 换焦点、E 确认。返回 true = 事件已被消费（调用方要 set_input_as_handled）。
## 方向键/Enter/空格在更早的 GUI 阶段就被焦点系统吃掉，这里收不到，也不会"按一次跳两格"。
func _overlay_nav(event: InputEvent) -> bool:
	if event.is_action_pressed("move_up"):
		_step_focus(-1)
		return true
	if event.is_action_pressed("move_down"):
		_step_focus(1)
		return true
	if _is_interact_event(event):
		_activate_focused()
		return true
	return false


## 收集容器里所有可点按钮（按视觉顺序），实现在 Global.collect_focusable()（与主菜单共用，置灰的不进环）。
func _collect_focusable(root: Node) -> Array[Control]:
	return Global.collect_focusable(root)


## 延迟同步队伍管理面板的焦点环（重建是 deferred 的，否则拿到的是要被释放的旧按钮）。
## 焦点落在第一个可点按钮上：列表长度刚变，记住旧下标没意义。
func _sync_party_focus() -> void:
	if _party_open and _party_panel != null:
		_set_focus_ring(_party_panel.focus_ring())


## 打开某个 NPC 的对话/传送面板（调用方保证 npc 非 null）。
## 副作用：_panel_open = true（冻住走动）；按 resolve_action() 铺按钮；panel.show() 后设焦点。
## 坑：grab_focus() 对隐藏控件无效，所以必须先 show() 再设焦点，否则键盘整片失灵且无报错。
## 坑：remove_child 后 queue_free 是刻意的 —— 只 queue_free 节点会活到帧末，布局这一帧还看得到。
func _open_panel(npc: WorldNPC) -> void:
	# 商人不用小对话框：44 件武器塞不进 600×460，直接开带滚动的大面板，且**不置 _panel_open**。
	# 分流放这里：_unhandled_input 只管"按 E 交互"，用哪种面板是交互类型的事。
	if resolve_action(npc.data) == MapNPC.Action.SELL_WEAPONS:
		_open_merchant(npc.data)
		return

	_panel_open = true
	_panel_npc = npc
	panel_name.text = "%s：" % npc.data.display_name
	panel_dialogue.text = npc.data.dialogue
	_rebuild_panel_buttons()
	# 顺序很重要：先 show() 再设焦点（grab_focus 对隐藏控件静默失败，键盘会失灵且无报错）。
	panel.show()
	_set_focus_ring(_collect_focusable(panel_buttons))
	_sync_world_button_focus()


## 把可选项文字染成金色（悬停/按下/聚焦更亮）。只给能点的上色，置灰的保持灰色。
func _paint_option_gold(button: Button) -> void:
	button.add_theme_color_override("font_color", PANEL_OPTION_COLOR)
	button.add_theme_color_override("font_hover_color", PANEL_OPTION_COLOR_ACTIVE)
	button.add_theme_color_override("font_pressed_color", PANEL_OPTION_COLOR_ACTIVE)
	button.add_theme_color_override("font_focus_color", PANEL_OPTION_COLOR_ACTIVE)


## 给按钮加左内边距，并把上下内边距压到 2px。
## ⚠ 所有状态一起改：只改 normal，鼠标移上去换 hover 样式时文字会左右跳。
## ⚠ 上下边距也要压：默认 4px 会让最小高度 ≈35，超过 PANEL_OPTION_HEIGHT = 34，行距看起来仍偏宽。
func _indent_button(button: Button) -> void:
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var base := button.get_theme_stylebox(state)
		if base == null:
			continue
		var style := base.duplicate() as StyleBox
		if style == null:
			continue
		style.content_margin_left = PANEL_BUTTON_INDENT
		style.content_margin_top = 2
		style.content_margin_bottom = 2
		button.add_theme_stylebox_override(state, style)


## 按当前 NPC 的交互类型重建按钮区（每次打开面板、招募成功后都调）。
## 一个按钮都不铺也是合法状态（TALK），面板只显示台词，靠「再想想」关闭。
func _rebuild_panel_buttons() -> void:
	for child in panel_buttons.get_children():
		panel_buttons.remove_child(child)
		child.queue_free()
	if _panel_npc == null:
		return
	match resolve_action(_panel_npc.data):
		MapNPC.Action.RECRUIT_PARTY:
			_build_recruit_buttons(_panel_npc.data)
		MapNPC.Action.JOIN_SECT:
			_build_sect_buttons(_panel_npc.data)
		MapNPC.Action.TELEPORT:
			_build_teleport_buttons(_panel_npc.data)
		MapNPC.Action.SELL_WEAPONS:
			# 正常走不到这里：商人在 _open_panel() 就分流了；留一句人话而不是误导的传送说明。
			_add_panel_note("（商人：按 E 直接开商店面板，不在这个小窗口里卖）")
		_:
			_add_panel_note("（这个 NPC 目前不送人去别处）")
	# 选项统一改样式：铺满整行、文字居左、留左内边距；能点的染金色；高度/字号也在这里统一。
	for child in panel_buttons.get_children():
		if child is Button:
			var button := child as Button
			button.size_flags_horizontal = Control.SIZE_FILL
			button.custom_minimum_size = Vector2(0, PANEL_OPTION_HEIGHT)
			button.add_theme_font_size_override("font_size", PANEL_OPTION_FONT)
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			_indent_button(button)
			if not button.disabled:
				_paint_option_gold(button)
	_fit_panel_height()


## 按按钮区实际需要把面板撑高（tscn 里默认只有 200），否则按钮和「再想想」会漏到面板外。
## 面板锚在屏幕底边（anchor_top = anchor_bottom = 1），只改 offset_top 就是"向上长高"。
## 上限取视口高度 85%，小窗口下不会顶出屏幕。
func _fit_panel_height() -> void:
	var needed := 0.0
	for child in panel_buttons.get_children():
		needed += child.get_combined_minimum_size().y
	if panel_buttons.get_child_count() > 1:
		needed += panel_buttons.get_theme_constant("separation") * float(panel_buttons.get_child_count() - 1)
	# 台词 64（名字已并进第一行）+ 关闭按钮 40 + 外框上下边距 48 + 两段间隔（6×2）= 164
	var total := needed + 164.0
	total = clampf(total, PANEL_MIN_HEIGHT, get_viewport_rect().size.y * 0.85)
	panel.offset_top = -(total + PANEL_BOTTOM_MARGIN)
	panel.offset_bottom = -PANEL_BOTTOM_MARGIN

## 把 MapNPC.Action.AUTO 解析成"具体会干什么"：有 destinations 就是 TELEPORT，否则 TALK。
## 静态函数："这条老规则"只写在这里一份，老的 .tres 不用改就能继续用。
static func resolve_action(data: MapNPC) -> MapNPC.Action:
	if data == null:
		return MapNPC.Action.TALK
	if data.action != MapNPC.Action.AUTO:
		return data.action
	return MapNPC.Action.TELEPORT if not data.destinations.is_empty() else MapNPC.Action.TALK


## 铺传送按钮。
func _build_teleport_buttons(data: MapNPC) -> void:
	if data.destinations.is_empty():
		_add_panel_note("（这个 NPC 目前不送人去别处）")
		return
	for dest_id in data.destinations:
		var button := Button.new()
		# 显示名优先查 _map_names；查不到（例如指向了一张没进 main.tscn 的地图）就退化成 id 本身。
		button.text = "%s %s" % [data.teleport_label, _map_names.get(dest_id, dest_id)]
		button.pressed.connect(_on_destination_pressed.bind(dest_id))
		panel_buttons.add_child(button)


## 铺招募按钮：每人一个，已在团队/团队已满的置灰。底部补一行团队摘要。
## 候选来源 recruit_pool 优先，留空问 Global 要目录扫描结果。
## 招募是往**团队**里加人（上阵由队伍管理面板决定），所以这里判的是"已在团队中"。
func _build_recruit_buttons(data: MapNPC) -> void:
	var candidates := _recruit_candidates(data)
	if candidates.is_empty():
		_add_panel_note("（没有可招募的队友：Global.RECRUIT_DIR 里没扫到 UnitStats）")
		return
	var count := GameRoot.party_count(_party)
	var team_full := GameRoot.MAX_TEAM_SIZE > 0 and count >= GameRoot.MAX_TEAM_SIZE
	for stats in candidates:
		var joined := GameRoot.party_has(_party, stats)
		var button := Button.new()
		if joined:
			button.text = "%s（已在团队中）" % stats.name
		elif team_full:
			button.text = "%s（团队已满 %d/%d）" % [stats.name, count, GameRoot.MAX_TEAM_SIZE]
		else:
			button.text = "%s %s   %s" % [data.recruit_label, stats.name, _stats_digest(stats)]
		button.tooltip_text = "%s（%s）\nHP %s / 伤害 %s / 速度 %s / 格挡 %s%%" % [
			stats.name, stats.race_name(), Global.format_stat(stats.health),
			Global.format_stat(stats.damage), Global.format_stat(stats.speed),
			Global.format_stat(stats.block_chance)]
		button.disabled = joined or team_full
		if not button.disabled:
			button.pressed.connect(_on_recruit_pressed.bind(stats))
		panel_buttons.add_child(button)
	_add_panel_note(_party_summary())


## 候选队友：显式 recruit_pool 优先，否则用 Global 的目录扫描（Global 那边有缓存）。
func _recruit_candidates(data: MapNPC) -> Array[UnitStats]:
	if not data.recruit_pool.is_empty():
		return data.recruit_pool
	return Global.get_recruitable_players()


## 一行属性摘要（招募按钮用）：种族 + 最影响选择的 3 项，避免按钮文字过长。
## 数值格式化统一走 Global.format_stat()，和队伍管理面板显示一致。
func _stats_digest(stats: UnitStats) -> String:
	return "%s · HP %s · 攻 %s · 速 %s" % [
		stats.race_name(),
		Global.format_stat(stats.health),
		Global.format_stat(stats.damage),
		Global.format_stat(stats.speed),
	]


## 面板底部摘要：团队人数 + 上阵人数 + 成员名单（让"团队很多人、只上阵 5 个"在招募时也可见）。
func _party_summary() -> String:
	var names := GameRoot.party_names_of(_party)
	var body := "、".join(names) if not names.is_empty() else "（空）"
	return "团队 %d 人（上阵 %d/%d）：%s" % [
		GameRoot.party_count(_party), GameRoot.party_count(deployed),
		GameRoot.MAX_DEPLOYED, body]


## 往按钮区加一行不可点击的说明文字。
## ⚠ 不要开 autowrap：Label 拿到真实宽度前算最小尺寸会按"每个字一行"报巨大高度，
##   而 _fit_panel_height() 正是按最小高度撑面板的，会被假高度带跑（实测能撑到 1013px）。
func _add_panel_note(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.clip_text = true
	panel_buttons.add_child(label)


## 招募按钮回调：播 UI 音效 + emit recruit_requested，只发请求，判定在 GameRoot。
## 刻意不关面板：玩家要能连着招第二个，也才能看到按钮变成"已在队伍中"。
func _on_recruit_pressed(stats: UnitStats) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	recruit_requested.emit(stats)


## 铺拜师按钮：团队名册每人一行，按"种族能不能拜 / 是否已有门派"决定是否可点。
## 整支团队都铺出来（而不是只铺能拜的）：玩家需要看见"为什么他不能拜"。
## 规则委托给 GameRoot.can_join_sect()，这里不自己判种族。
func _build_sect_buttons(data: MapNPC) -> void:
	var sect_id := data.sect_id
	if not Global.is_sect(sect_id):
		_add_panel_note("（这个掌门没配门派：MapNPC.sect_id 要填 Global.SECTS 的键）")
		return
	var sect_name := Global.sect_name(sect_id)
	# 不再重复门派介绍和"团队 X 人"：台词行已是掌门的话，下面直接是每个队员的按钮。
	if _party.is_empty():
		_add_panel_note("（团队里还没有人，先去招募队友）")
		return
	for member in _party:
		if member == null:
			continue
		var current := GameRoot.sect_of(member)
		var why := GameRoot.can_join_sect(member, sect_id)
		var button := Button.new()
		if not current.is_empty():
			# 已经有门派（含"已经是本门"）：置灰，写明他现在归谁
			button.text = "%s（%s）· 已入%s" % [member.name, member.race_name(),
					Global.sect_name(current)]
		elif not why.is_empty():
			# 种族不符：置灰，直接写在按钮上（完整理由在 tooltip 里）
			button.text = "%s（%s）· %s不收%s" % [member.name, member.race_name(),
					sect_name, member.race_name()]
		else:
			button.text = "拜入%s · %s（%s）" % [sect_name, member.name, member.race_name()]
		button.tooltip_text = why if not why.is_empty() else "%s拜入%s" % [member.name, sect_name]
		button.disabled = not why.is_empty()
		if not button.disabled:
			button.pressed.connect(_on_sect_join_pressed.bind(member, sect_id))
		panel_buttons.add_child(button)


## 拜师按钮回调：播 UI 音效 + emit sect_join_requested，只发请求（能不能拜由 GameRoot 判）。
## 不关面板：玩家要看到按钮变成"已入 XX"，也可能接着给另一个人拜同门。
func _on_sect_join_pressed(character: UnitStats, sect_id: String) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	sect_join_requested.emit(character, sect_id)


## 门派变化后刷新（GameRoot 拜师成功/失败后调用）。参数 message 非空时走顶部一行弹窗。
## 副作用：NPC 面板开着 → 重建按钮区与焦点环；属性面板开着 → 刷新（种族 · 门派那行要变）。
func notify_sect_changed(message := "") -> void:
	if _panel_open:
		_rebuild_panel_buttons()
		_set_focus_ring(_collect_focusable(panel_buttons))
	if not message.is_empty():
		show_toast(message)
	if _stats_open:
		_stats_panel.refresh.call_deferred()


## 队伍变化后刷新（GameRoot 招募/移除成功后调用；失败也调，用来显示原因）。
## 参数 message 非空时：NPC 面板开着走 show_toast，队伍面板开着写进它的提示行，都没开则丢掉。
## 为什么两个面板都管：招募在 NPC 面板、移除在队伍面板，但数据只有 GameRoot 一份，刷新点也只有一个。
## 为什么 deferred：整条链从按钮 pressed 发起，立刻 remove_child 会摘掉正在发信号的按钮。
func notify_party_changed(message := "") -> void:
	if _panel_open:
		_rebuild_panel_buttons()
		# 重建后按钮是新节点，焦点环必须跟着换（否则 W/S 会在已释放的旧按钮上打转）。
		_set_focus_ring(_collect_focusable(panel_buttons))
	# 结果回执统一走顶部一行弹窗（1.5s 淡出），不写进 NPC 台词行、也不打扰队伍管理面板
	if not message.is_empty() and not _party_open:
		show_toast(message)
	if _party_open:
		if not message.is_empty():
			_party_panel.show_message(message)
		_party_panel.show_party.call_deferred(_party, deployed)
		_sync_party_focus.call_deferred()
	# 上阵名单变了 → 地图上的跟随队伍跟着变；deferred 理由同上。
	_rebuild_companions.call_deferred()

## 关闭对话面板（「再想想」按钮与 Esc 都走这里）。
## 不清理 panel_buttons：下次 _open_panel() 会重建，且隐藏父节点下的旧按钮不可见也不接收输入。
func _close_panel() -> void:
	_panel_open = false
	_panel_npc = null
	_focus_ring.clear()
	panel.hide()
	_sync_world_button_focus()


## 选了传送目的地：播 UI 音效、关面板、emit travel_requested。
## 本节点不切场景：切场景/淡入淡出/记住位置都是 GameRoot 的活。
func _on_destination_pressed(map_id: String) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	_close_panel()
	travel_requested.emit(map_id)


## 「进入战斗」：播 UI 音效 + emit battle_requested。
func _on_battle_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	battle_requested.emit()


## 「返回主菜单」：播 UI 音效 + emit back_to_title_requested。
func _on_back_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	back_to_title_requested.emit()


## 调试（F1）：把鼠标位置换算成地图归一化坐标打出来，填 spawn_point / NPC.position 用。
## ⚠ 依赖本节点无位移/缩放；若以后给 WorldMap 加 position/scale，这里要先转回本地坐标。
func _debug_print_normalized() -> void:
	if _map_size == Vector2.ZERO:
		return
	var normalized := get_global_mouse_position() / _map_size
	print("[WorldMap] %s 鼠标归一化坐标: Vector2(%.3f, %.3f)" % [_map.display_name, normalized.x, normalized.y])

# ═══════════════════════════════════════════════════════════════════════════
# WorldMap —— 可探索的世界地图屏幕（一段地图 = 一个"关卡外景"）
# ═══════════════════════════════════════════════════════════════════════════
# 在系统里的位置：
#   GameRoot(唯一主场景 main.tscn) 是总导演。它把本节点 add_child 到 main.tscn 的
#   WorldRoot(Node2D) 下面，自己则留在 UIRoot/TransitionLayer 上做黑幕淡入淡出。
#   本文件是 scenes/world/world_map.tscn 的根脚本；某张地图若在 MapData.scene 里
#   填了"继承自 world_map.tscn 的专用场景"，那个场景的根脚本也是本类（子类化）。
#
# 数据和交互的来龙去脉：
#   数据从哪来：MapData(.tres) 提供图片/map_scale/spawn_point/npcs/next_id 等静态配置；
#               GameRoot 再调 world.setup() 塞进队伍、金币、上一场战斗的结算文案与"从哪张图来"。
#   数据到哪去：玩家走动只改本节点内的 player.position，不写全局；真正影响全局的动作
#               一律用 signal 抛给 GameRoot（battle_requested / travel_requested /
#               back_to_title_requested），由 GameRoot 负责切场景、改 Global.coins 等。
#
# 本文件承担的四件事：
#   1. 摆场景：把地图贴图按 map_scale 放大成"世界"，放好玩家和 NPC
#   2. 每帧驱动玩家走动（_process → _move_player）并算出"离哪个 NPC 最近"
#   3. 对话面板：显示 NPC 台词 + 由 destinations 动态生成一串传送按钮
#   4. 把三个按钮（进入战斗 / 返回主菜单 / 传送目的地）翻译成三个 signal
#
# 场景节点构成（%xxx 都是 unique_name_in_owner，见下面的 @onready 段）：
#   MapSprite(Sprite2D)      地图底图，centered = false（原点在左上角，坐标换算的前提）
#   Player(Node2D)           玩家容器；下面挂 Shadow / PlayerFallback / PlayerSprite / Camera
#                            + 运行时加的「队长名字」Label（见 _setup_party_visuals）
#   UI(CanvasLayer)          所有 HUD：地图名 / 金币 / 提示 / 结算文案 / 两个按钮 / 对话面板
#   （运行时还会往本节点下加若干个 Companion(Node2D)：上阵队友的跟随小人，
#     结构 = Shadow + Sprite2D + 名字 Label，见 _rebuild_companions）
#
# 坑（改之前务必看）：
#   · 本脚本用的是**类 Node2D**，不是 Control —— 里面所有 %控件 都位于子 CanvasLayer(UI) 下，
#     @onready 变量在 _ready() 执行之前才赋值，所以 setup() 里绝对不能碰它们（见 setup 注释）。
#   · 运行时 add_child 的 NPC 节点 owner 是 null，因此对它们只能 queue_free()，
#     不能走 owner.queue_free() 那一套（本文件没这么写，但接手的代码要注意）。
#   · 传送面板里的按钮是每次打开时**新建**的，旧的会被 remove_child + queue_free；
#     不要试图用固定节点名去找它们。
#
# 扩展点（extends 之后那段原有的说明块也列了一遍，两者互补）：
#   战斗遇敌挂野怪、走路动画换 AnimatedSprite2D、
#   加碰撞用 TileMapLayer + CharacterBody2D、面板加商店/任务/选项分支。

extends Node2D
class_name WorldMap

## 可探索的地图：地图图片等比放大成世界，玩家自由走动，相机跟随，靠跟 NPC 对话传送
##
## 坐标约定：
##   地图图片 Sprite 的 centered = false，原点在图片左上角，
##   所以 world = normalized * (图片尺寸 × map_scale)，spawn_point / NPC.position 都用归一化填。
##
## 传送是双向的：哪张图能去哪张，完全由各图 NPC 的 destinations 决定。
## 从 A 传到 B 时，会优先出现在 B 里"指向 A 的那个 NPC"旁边（来回走不会迷路）。
##
## 扩展点：
##   · 战斗遇敌    → 现在挂在 UI 的「进入战斗」按钮上，以后可以改成某个 NPC/野怪触发
##   · 走路动画    → PlayerSprite 换成 AnimatedSprite2D，在 _move_player() 里切动画
##   · 碰撞/障碍   → 现在只有边界钳制；要墙体就加 TileMapLayer + CharacterBody2D
##   · 交互扩展    → _open_panel() 现在只显示台词+传送列表，可以加商店/任务/选项分支

# ───────────────────────────────────────────────────────────────────────────
#  ── 对外信号（本文件唯一的"输出口"，全部由 GameRoot 订阅）──
# ───────────────────────────────────────────────────────────────────────────
## 玩家点了「进入战斗」按钮。GameRoot 收到后调 enter_battle()。
## 无参数 —— 打哪张图由 GameRoot 根据 current_map_id 自己查。
signal battle_requested
## 玩家在 NPC 对话面板里选了目的地。参数是目标地图的 id（MapData.id）。
## GameRoot 收到后调 travel_to(map_id)。
signal travel_requested(map_id: String)

## 玩家在 NPC 面板里点了某个队友的「加入」按钮。
## 参数 stats：要招募的 UnitStats 资源（不是节点）。
## ⚠ 本信号只**请求**，自己不改队伍：GameRoot 收到后按自己的规则判断能不能加
##   （见 main.gd 的 _on_recruit_requested），加完再回调本文件的 notify_party_changed() 刷新面板。
signal recruit_requested(stats: UnitStats)

## 玩家在队伍管理面板里点了某个队友的「移出队伍」。
## 参数 stats：要移出的 UnitStats 资源。
## 与 recruit_requested 同样是"只请求"：真正的移除由 GameRoot._on_party_remove_requested()
## 完成，完成后 GameRoot 回调本文件的 notify_party_changed() 让面板重建列表。
signal party_remove_requested(stats: UnitStats)

## 玩家在队伍管理面板里点了「上阵」（把名册里的某人放进上阵名单）。
## 参数 stats：要上阵的 UnitStats 资源。
## 同样是"只请求"：GameRoot._on_party_deploy_requested() 按规则判断（没在团队里 / 已上阵 /
## 上阵位满 都会拒绝），成功后回调 notify_party_changed() 让面板重建。
signal party_deploy_requested(stats: UnitStats)

## 玩家在队伍管理面板里点了「下阵」（把某人从上阵名单拿下来）。
## 参数 stats：要下阵的 UnitStats 资源。
## 规则：至少要留 1 人上阵（详见 GameRoot.deploy_can_remove），违反时 GameRoot 只回一条提示。
signal party_undeploy_requested(stats: UnitStats)

## 玩家在商人面板里点了某件装备的「购买」。
## 参数 item：要买的道具（ItemBase；地图线货架上是 ItemEquipment）。
## 同样是"只请求"：GameRoot._on_item_buy_requested() 按规则判定（金币够不够、背包满没满，
## 见 GameRoot.item_can_buy），买成功后再回调本文件的 notify_shop_changed() 让面板重建。
signal item_buy_requested(item: ItemBase)
## 玩家在交易时点了背包里的东西、并在确认框里点了「确定」：要**卖**掉它。
## 参数 item：要卖的道具。
## 和买一样是"只请求"：GameRoot._on_item_sell_requested() 按规则判定
##   （背包里有没有、卖价多少，见 GameRoot.item_can_sell / item_sell_price），
## 卖成功后再回调本文件的 notify_shop_changed() 刷新两个面板。
signal item_sell_requested(item: ItemBase)
## 玩家在**没开商人**时点了背包里的一件装备：要把它**穿到当前展示的角色身上**。
## 参数 character：背包界面当前展示的团队成员（◀ / ▶ 切换的那个）；
##   参数 item：要穿的道具（ItemBase）。
## 同样是"只请求"：GameRoot._on_equip_requested() → item_can_equip() 按规则判定
##   （能不能装备、对应哪个栏位），成功后回调本文件的 notify_bag_changed() 让背包和装备栏重建。
signal equip_requested(character: UnitStats, item: ItemBase)
## 玩家点了**某个角色已穿上**的装备栏：要把那件装备**脱下来放回背包**。
## 参数 character：这个装备栏属于谁（= 背包界面当前展示的角色）；
##   参数 slot_type：ItemBase.EquipType 的成员值（头盔 / 武器 / 腰带 / 项链 / 衣服 / 鞋子）。
## GameRoot._on_unequip_requested() → unequip_slot() 判定（角色为空 / 栏位空 / 背包满会拒绝）。
signal unequip_requested(character: UnitStats, slot_type: int)

## 玩家在门派掌门的拜师面板里点了某个队员：要让**这个队员**拜入那个门派。
## 参数 character：点了的队员；sect_id：这个 NPC 代表的门派（Global.SECTS 的键）。
## 只请求：GameRoot._on_join_sect_requested() → can_join_sect() 判定种族/已有门派，
## 成功后回调本文件的 notify_sect_changed() 让面板重建（按钮会变成"已有门派：XX"）。
signal sect_join_requested(character: UnitStats, sect_id: String)

## 玩家点了「返回主菜单」。GameRoot 收到后调 show_title()。
signal back_to_title_requested

# ───────────────────────────────────────────────────────────────────────────
#  ── 常量 ──
# ───────────────────────────────────────────────────────────────────────────
## NPC 场景。用 preload 而不是 load：脚本加载时就把 world_npc.tscn 解析好，
## 之后每次 _add_npc() 只是 instantiate()，没有磁盘查找开销。
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
## 玩家离地图边缘的最小留白（像素，世界坐标）。_move_player() 用它做 clamp，
## 60.0 大约是一个角色身位，防止贴图放大后角色半个身子走出图片外。
## NPC 对话面板的最小高度。**必须和 world_map.tscn 里 TravelPanel 的原始高度一致（460）**，
## 否则没打开过招募面板时，传送面板的高度会莫名其妙变一下。
const PANEL_MIN_HEIGHT := 460.0

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

# ───────────────────────────────────────────────────────────────────────────
#  ── 数值（可在检视面板里逐张地图微调；也可以在专用子场景里覆盖）──
# ───────────────────────────────────────────────────────────────────────────
## 基础移动速度，单位「像素/秒」（世界坐标，已被 map_scale 放大过，所以比较快）。
## 默认 380.0：地图 4096×2304 的情况下约 11 秒横穿全图，既不拖沓也不至于难看清 NPC。
@export var move_speed := 380.0
## 按住 dash 时的速度倍率（倍，无单位）。默认 1.9 ≈ 冲刺时 722 px/s，够快但仍能看清沿途。
@export var dash_multiplier := 1.9
## 交互判定半径，单位像素（世界坐标）。玩家与 NPC 距离小于它才算"可交谈"。
## 默认 150.0：约等于 3 个角色宽度，不用精确站到 NPC 身上。
@export var interact_radius := 150.0
## 战斗结算文案停留多久（秒）后开始淡出。默认 3.0：足够读完一行"战斗胜利 + 金币"。
@export var result_toast_time := 3.0

# ───────────────────────────────────────────────────────────────────────────
#  ── 运行时状态（只活在本屏幕的生命周期内；换图 = 换节点，全部重新来）──
# ───────────────────────────────────────────────────────────────────────────
## 本屏幕要渲染的那张地图的配置。由 setup() 注入；_ready() 里若为 null 会直接 return。
var _map: MapData
## 团队（大名单，UnitStats 资源数组）。本文件**只用来展示/传递**，
## 真正的副本化与战斗实例化在 GameRoot._make_player_team() 里做。
var _party: Array[UnitStats] = []
## 上阵名单（最多 5 人）。**由 GameRoot 在 add_child 之前注入**（写法同 spawn_override）：
##   world.deployed = deployed
## 为什么不在 setup() 的参数里：setup 的参数已经很长了，而 spawn_override 已经确立了
##   "额外数据用公开字段注入"的写法；另外它与 _party 一样是引用语义，GameRoot 就地增删后
##   本文件立刻看得到（界面文字靠 notify_party_changed() 刷新）。
## 本文件只读它来画"上阵/下阵"按钮的状态，从不修改。
var deployed: Array[UnitStats] = []

# ── 队伍立绘：队长名字 + 上阵队友跟随（见 _setup_party_visuals / _rebuild_companions）──
## 队长头顶的名字 Label（运行时加到 Player 下面，跟着一起走）。
var _leader_name_label: Label = null
## 场上每个上阵队友的跟随小人（Node2D：Shadow + Sprite2D + 名字 Label）。
var _companions: Array[Node2D] = []
## 队长的"面包屑"轨迹：索引 0 = 最新，往后的点越旧。跟随者按固定间隔取点，
## 于是自然排成一列跟在后面，而不是几个小人叠在同一个坐标上。
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

## GameRoot 可以在 add_child 之前设这个：非 INF 时优先用它当出生点（归一化坐标）
## 用来实现"打完战斗回到地图时还站在原地"
## 坑：Vector2.INF 在这里是"没设过"的哨兵值（INF 不可能是合法归一化坐标）；
##     必须在 add_child 之前赋值，因为 _ready() 会立刻读它。
var spawn_override := Vector2.INF

## 世界像素尺寸 = 图片尺寸 × map_scale。**所有像素换算的唯一依据**。
## 为 ZERO 表示这张图没配 texture，_process 会直接跳过（避免除零和乱跑）。
var _map_size := Vector2.ZERO
## 本次生成的 NPC 节点列表（运行时 add_child 进来的，owner 为 null）。
var _npcs: Array[WorldNPC] = []
## 当前高亮的 NPC（离玩家最近且进入 interact_radius 的那个），没有则为 null。
var _nearest: WorldNPC = null
## 对话/传送面板是否打开。为 true 时 _process 不处理走动，避免"一边看对话一边飘走"。
var _panel_open := false

## 当前打开着面板的那个 NPC（null = 面板没开）。
## 用途：招募成功后要重建按钮区，而重建需要知道"这是哪个 NPC 的面板"（不同类型按钮不一样）。
## 关闭面板时置 null（按钮区不清空 —— 旧按钮在隐藏的父节点下不可见也不接收输入，下次打开会重建）。
var _panel_npc: WorldNPC = null

## 操作菜单开着吗 / 队伍管理二级页开着吗 / 商人面板开着吗 / 背包开着吗。
## 这几个开关和 _panel_open 一起构成 _ui_open()：只要有任意一个是 true，
## 走动就被冻住、输入也走"UI 分支"。
var _menu_open := false
## 各占一个开关，理由同 _menu_open（也方便 _unhandled_input 里按优先级分支）。
var _party_open := false
var _shop_open := false
var _bag_open := false
## 角色属性面板开着吗（和背包一样是"普通二级页"，不跟商人交易共存）。
var _stats_open := false

## 这次背包是从操作菜单进来的吗（决定关背包时是回游戏还是退回菜单）。见 _open_bag/_close_bag。
var _bag_from_menu := false
## 这次背包是"商人交易"顺手打开的吗。true 时关交易会把背包一起收掉（见 _close_merchant）。
var _bag_with_shop := false
## 这次背包是"角色属性面板"顺手打开的吗。true 时关属性面板会把背包一起收掉（见 _close_stats）。
var _bag_with_stats := false

## 这次属性面板是从操作菜单进来的吗（关掉时退回菜单，语义同 _bag_from_menu）。
var _stats_from_menu := false

## 当前这个商人的配置（开商人面板时记下；买完重建货架要用它）。null = 商人面板没开。
## 为什么不像 NPC 对话面板那样复用 _panel_npc：商人**不走**那个面板（见 _open_panel 的分流），
##   所以 _panel_npc 对商人一直是 null，得单独记一个。
var _merchant_data: MapNPC

## 当前浮层的"焦点环"：按视觉顺序排列的可聚焦控件。W/S 用它循环切换焦点；
## 由 _set_focus_ring() 在打开浮层/重建列表时填，浮层关掉时清空。
var _focus_ring: Array[Control] = []

## 三个 UI 浮层节点（运行时实例化，见 _setup_overlays）。
## 写类型化变量是为了后面少写一次强转，也让"它们是什么"一眼可见。
var _pause_menu: PauseMenu
var _party_panel: PartyPanel
var _merchant_panel: MerchantPanel
var _bag_panel: BagPanel
var _stats_panel: StatsPanel

# ───────────────────────────────────────────────────────────────────────────
#  ── 场景节点引用（% = unique_name_in_owner，指向本场景里标记为唯一的节点）──
#  说明：@onready 变量在 _ready() 之前的最后一刻才被赋值，
#        所以 setup() 里读它们是 null —— 这也是"setup 只存数据、_ready 才搭场景"的原因。
# ───────────────────────────────────────────────────────────────────────────
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
## 顶部结算文案标签，由 _show_result() 显示并淡出。
@onready var result_label: Label = %ResultLabel
## 右下角「进入战斗」按钮。地图的 battle_enabled 为 false 时置灰。
@onready var battle_button: Button = %BattleButton
## 左下角「返回主菜单」按钮。
@onready var back_button: Button = %BackButton
## 中央的 NPC 对话/传送面板（Panel）。默认隐藏。
@onready var panel: Panel = %TravelPanel
## UI 层（CanvasLayer）。操作菜单 / 队伍管理面板运行时挂到这里（见 _setup_overlays），
## 于是它们不随相机移动、也不参与世界的 y_sort 排序。
@onready var ui_layer: CanvasLayer = $UI
## 面板里的 NPC 名字。
@onready var panel_name: Label = %PanelName
## 面板里的 NPC 台词。
@onready var panel_dialogue: Label = %PanelDialogue
## 面板里动态生成传送按钮的竖排容器（每次打开都会清空重建）。
@onready var panel_buttons: VBoxContainer = %PanelButtons
## 面板右下角的「再想想」按钮，等价于按 Esc 关闭。
@onready var close_button: Button = %CloseButton

## 只存数据；搭建放到 _ready（GameRoot 是先 setup 再 add_child）
## 参数：
##   p_map         —— 本图配置（MapData）。为 null 时 _ready() 会警告并空跑。
##   p_party       —— 出战队伍，本文件只保留引用用于展示，不复制、不修改。
##   result_text   —— 顶部要飘的结算文案，空串 = 不飘。
##   p_cleared     —— 本图是否已通关，决定地图名后缀"（已通关）"。
##   p_map_names   —— map_id → 显示名，用于把 destinations 里的 id 翻成中文按钮文字。
##   p_from_map_id —— "从哪张图传过来的"，决定出生点（见 _spawn_normalized()）。
## 返回值：无。
## 副作用：只写本对象的私有字段；不 emit 信号、不碰 Global、不建节点。
## 为什么必须与 _ready() 分开：GameRoot 是"先 setup 再 add_child"，
##   此时本节点还没进场景树，@onready 变量（map_sprite / player / 各种 Label）全是 null，
##   在这里访问它们会直接报错。所以这里只存数据，真正的搭建统一留给 _ready()。
## 注：早先这里还传过 p_coins（右上角金币标签用），标签按需求移除后这个参数也一并删掉了
##   —— 金币的真值始终是 Global.coins，界面上只在背包的信息行显示。
func setup(p_map: MapData, p_party: Array[UnitStats], result_text: String,
		p_cleared: bool, p_map_names: Dictionary, p_from_map_id := "") -> void:
	_map = p_map
	_party = p_party
	_result = result_text
	_cleared = p_cleared
	_map_names = p_map_names
	_from_map_id = p_from_map_id


## 生命周期：进树时执行一次，负责把整张地图"搭出来"。
## 顺序是有讲究的 —— 先量尺寸（_map_size），才有后面所有坐标换算的依据。
## 副作用：改本节点的子节点（贴图/位置/可见性）、connect 三个按钮的 pressed、emit 无；
##        会启动一个计时器协程（_show_result 里的 await），该协程在本节点被 queue_free 后
##        会因 is_instance_valid() 检查而安全退出。
func _ready() -> void:
	# 没有 MapData 就没法搭（GameRoot 忘了 setup 时会走到这里）：直接返回，
	# 避免后面 _map.texture 空引用崩溃。
	if _map == null:
		push_warning("WorldMap: 没有拿到 MapData")
		return

	# ── 地图 ──────────────────────────────────────────────
	# centered = false 是坐标约定的基石：贴图原点回到左上角，
	# 于是"世界坐标 = 归一化坐标 × _map_size"这条公式才成立。
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

	# ── 玩家 ──────────────────────────────────────────────
	# icon 来自"选人界面选中的那个 UnitStats"；为空则用场景里预置的蓝色方块占位，
	# 这样即使没选人（例如直接运行 world_map.tscn 调试）也能看出玩家在哪。
	var icon := _player_icon()
	player_sprite.texture = icon
	player_fallback.visible = icon == null
	player.position = _world_pos(_spawn_normalized())

	# ── 相机（挂在玩家下面，自动跟随）────────────────────
	_setup_camera()

	# ── 队伍立绘：队长名字 + 上阵队友跟随 ────────────────
	# 必须在 player.position 设好之后：跟随者要靠轨迹排在队长身后。
	_setup_party_visuals()

	# ── NPC ───────────────────────────────────────────────
	_spawn_npcs()

	# ── UI ────────────────────────────────────────────────
	# 三个按钮只连一次 pressed；本节点随场景销毁，连接会跟着断，不需要手动 disconnect。
	battle_button.pressed.connect(_on_battle_pressed)
	back_button.pressed.connect(_on_back_pressed)
	close_button.pressed.connect(_close_panel)
	# battle_enabled = false 的地图（纯剧情图）置灰「进入战斗」。
	battle_button.disabled = not _map.battle_enabled
	map_name_label.text = "%s%s" % [_map.display_name, "（已通关）" if _cleared else ""]
	# 初始没有最近 NPC，提示先藏起来；面板同理（场景里默认就是隐藏的，这里再显式关一次）。
	hint_label.visible = false
	panel.hide()
	# 两个 UI 浮层（操作菜单 / 队伍管理）在这里实例化并接线。
	# 放在 _map 已经拿到的位置之后：操作菜单要按 _map.battle_enabled 决定「进入战斗」灰不灰。
	_setup_overlays()
	_show_result()


## 取"当前主角"的头像贴图。
## 参数：无 —— 直接读 autoload Global.main_player_selected（选人界面写入的 UnitStats）。
## 返回值：贴图；没选人时返回 null（调用方据此显示占位色块）。
## 副作用：无。注意返回的是**共享 Resource 上的贴图引用**，只读，不要就地改它。
func _player_icon() -> Texture2D:
	var stats := Global.main_player_selected
	return stats.icon if stats != null else null


## 显示顶部结算文案，停留 result_toast_time 秒后淡出。
## 参数：无（文案取 setup 时存下的 _result）。
## 返回值：无（内含 await，是个协程）。
## 副作用：改 result_label 的 text/visible，并创建一条 tween 改它的 modulate:a。
## 时序/坑：
##   · 结果是空串时立刻 return，不会留下计时器；
##   · await 期间玩家可能已经点了传送 → 本节点被 GameRoot._clear_screens() queue_free，
##     所以必须用 is_instance_valid(result_label) 兜一下再往下走（否则操作已释放对象会报错）；
##   · 淡出只把 alpha 改成 0，没有把 visible 置 false，也不 queue_free —— 标签一直留在场景里。
func _show_result() -> void:
	result_label.text = _result
	result_label.visible = not _result.is_empty()
	if not result_label.visible:
		return
	await get_tree().create_timer(result_toast_time).timeout
	if not is_instance_valid(result_label):
		return
	var tween := create_tween()
	tween.tween_property(result_label, "modulate:a", 0.0, 0.6)


# ══════════════════════════════════════════════════════════
#  坐标换算
# ══════════════════════════════════════════════════════════

## 归一化坐标 → 世界像素坐标。这是全文件唯一的换算入口。
## 参数 normalized：0~1 的归一化坐标（相对地图图片，左下/右上由 centered=false 决定为左上原点）。
## 返回值：世界像素坐标（像素）。输入 (0,0) 得到图片左上角，(1,1) 得到右下角。
## 副作用：无（纯函数）。_map_size 为 0 时返回 (0,0)。
func _world_pos(normalized: Vector2) -> Vector2:
	return normalized * _map_size


## 出生点：优先用 GameRoot 指定的（战斗回来原地），否则"从某张图走过来的"就出现在那张图的 NPC 旁边
## 参数：无。
## 返回值：归一化坐标（0~1），交给 _world_pos() 换算。
## 优先级（从高到低）：
##   1. spawn_override —— GameRoot 打完战斗回地图时设置的"离开时的原地位置"；
##   2. _from_map_id 命中某 NPC 的 destinations —— 站在那个 NPC 身上往下挪一点点，
##      于是"从 A 走到 B"和"从 B 走回 A"都会出现在对应的传送 NPC 边上，不会迷路；
##   3. MapData.spawn_point —— 兜底（直接用地图自带出生点，例如从主菜单新开局）。
## 副作用：无。
## 为什么 +Vector2(0, 0.04)：0.04 是相对图片高度的偏移（约 4%），
##   目的是不要和 NPC 完全重叠（重叠会让双方贴图互相盖住，也让距离判定一开始就"贴着"）。
func _spawn_normalized() -> Vector2:
	if spawn_override != Vector2.INF:
		return spawn_override
	if not _from_map_id.is_empty():
		for npc_data in _map.npcs:
			if npc_data != null and npc_data.destinations.has(_from_map_id):
				return npc_data.position + Vector2(0.0, 0.04)
	return _map.spawn_point


## 玩家当前所在位置（归一化），GameRoot 用它记住"离开这张图时站在哪"
## 参数：无。
## 返回值：归一化坐标；_map_size 为 0（没配图）时返回 Vector2.ZERO（防除零）。
## 副作用：无（纯读）。调用方是 GameRoot._remember_position()，结果存进 _map_positions。
func player_normalized() -> Vector2:
	if _map_size == Vector2.ZERO:
		return Vector2.ZERO
	return player.position / _map_size


## 配好相机：开平滑跟随，并在"地图比窗口大"的方向上限制可视范围。
## 参数：无（读当前视口尺寸 _map_size）。
## 返回值：无。
## 副作用：改 camera 的 position_smoothing_* 与 limit_* 四个边界。
## 为什么要 if 判断：limit 一旦设成 0..尺寸，相机就被锁在那段区间里；
##   若地图比视口还小，设了 limit 反而会把镜头卡在角落（画面歪掉），所以只有"地图更大"时才设。
## 注意：本节点没有设置 zoom，视口尺寸就是玩家实际能看到的世界范围（1 像素 = 1 世界单位）。
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


# ══════════════════════════════════════════════════════════
#  NPC
# ══════════════════════════════════════════════════════════

## 按 MapData.npcs 生成所有 NPC；一个都没有时补一个"路牌"兜底。
## 参数：无（数据来自 _map）。
## 返回值：无。
## 副作用：add_child 出若干 WorldNPC 节点并登记进 _npcs。
## 为什么需要兜底：老地图资源可能还没配 npcs，但流程上"必须能走到下一张图"，
##   于是自动造一个 MapNPC（运行时 new 出来的 Resource，不落盘）放在 exit_center，
##   destinations 指向 next_id —— 保证任何配了 next_id 的地图都不会卡死玩家。
## 坑：这里 new 的 MapNPC 是**临时资源**，只被这一个 NPC 引用，可以放心就地改；
##   但如果拿的是 .tres 里的共享资源，就地改字段会污染所有引用者（比如改 position）。
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
		# 注意写法：destinations 的类型是 Array[String]，不能写成
		# `fallback.destinations = [_map.next_id]`（弱类型 Array 赋给类型化数组会报错），
		# 这里先声明一个 Array[String] 局部变量再赋值，是 GDScript 的类型要求。
		var dests: Array[String] = [_map.next_id]
		fallback.destinations = dests
		fallback.teleport_label = "前往"
		_add_npc(fallback)


## 实例化一个 NPC 节点并摆到世界坐标上。
## 参数 npc_data：该 NPC 的配置（MapNPC 资源）。
## 返回值：无（新节点存进 _npcs）。
## 副作用：add_child(npc)（会立刻触发 npc._ready()）、设置 npc.position、往 _npcs 追加。
## 顺序说明：先 add_child 再 setup —— setup() 里要访问 @onready 变量（%Sprite 等），
##   而那些变量只有在节点进树、_ready() 跑过之后才有效；若先 setup 会拿到 null。
##   （npc.setup() 里又调用 set_highlight() 创建 tween，所以它必须在树里。）
func _add_npc(npc_data: MapNPC) -> void:
	var npc := NPC_SCENE.instantiate() as WorldNPC
	# 直接挂在 WorldMap 下（WorldMap 开了 y_sort，玩家才能绕到 NPC 身后/身前）
	add_child(npc)
	npc.setup(npc_data)
	npc.position = _world_pos(npc_data.position)
	_npcs.append(npc)


## 每帧找出"离玩家最近、且在 interact_radius 内"的 NPC，并维护高亮与提示文字。
## 参数：无。
## 返回值：无。
## 副作用：
##   · 调用旧/新最近 NPC 的 set_highlight()（后者内部会 create_tween，每切换一次就新建一条）；
##   · 改 hint_label.text / visible。
## 实现细节：best_distance 初值取 interact_radius，所以距离必须**严格小于**半径才入选，
##   刚好等于半径不算 —— 这样判定边界不会来回抖动。
## 只在 _nearest 真的变化时才碰高亮：避免每帧新建 tween（那会造成 tween 堆积）。
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

	# 注意这里用的是 _nearest.data.display_name，等于 null 时下标会报错，
	# 所以必须先判 _nearest != null 再访问（下面就是这么写的）。
	if _nearest != null:
		hint_label.text = "按 E 与 %s 交谈" % _nearest.data.display_name
		hint_label.visible = true
	else:
		hint_label.visible = false


# ══════════════════════════════════════════════════════════
#  每帧：走动
# ══════════════════════════════════════════════════════════

## 每帧驱动：走动 + 最近 NPC 判定。
## 参数 delta：距上一帧的秒数（由引擎传入，单位秒）。
## 返回值：无。
## 副作用：改 player.position / player_sprite.flip_h / hint_label / NPC 高亮（见被调用的两个函数）。
## 提前返回的两种情况：
##   · _map_size == ZERO：地图没配图，走也看不到（也避免和 _map_size 相关的除零）；
##   · _ui_open() == true：正在看对话框 / 操作菜单 / 队伍管理 → 冻住移动。
##     这一条现在比过去更重要：WASD 同时被用来在菜单里选条目，不冻住就会"边选边跑"。
func _process(delta: float) -> void:
	if _map_size == Vector2.ZERO or _ui_open():
		return
	_move_player(delta)
	# 走动之后：记轨迹 → 队友沿着轨迹跟上（顺序不能反，否则队友永远慢一帧的位置）
	_update_trail()
	_update_companions(delta)
	_update_nearest()


## 按输入向量移动玩家，并把它夹在地图内。
## 参数 delta：帧间隔（秒）。
## 返回值：无。
## 副作用：改 player.position（x、y 两轴），可能改 player_sprite.flip_h。
## 细节：
##   · Input.get_vector 已经返回长度 ≤1 的向量（斜向不会变快），所以直接乘速度即可；
##   · dash 用的是"按住"判定（is_action_pressed），不是"按下一次"，可以持续冲刺；
##   · clampf 的上界写成 maxf(EDGE_MARGIN, _map_size.x - EDGE_MARGIN)：
##     地图比两倍留白还小时，上界会小于下界 —— 若不这么写，clamp 会把玩家硬拉到图片外；
##   · flip_h 只在 |dir.x| > 0.01 时更新，这样纯上下移动时不会把朝向抖掉。
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


# ══════════════════════════════════════════════════════════
#  队伍立绘：队长名字 + 上阵队友跟随
# ══════════════════════════════════════════════════════════
#  为什么这么做：
#    · 名字直接挂在角色节点下面（Label 是 Control，挂在 Node2D 下会跟着父节点变换），
#      所以不需要每帧同步位置，也不吃 UI 的输入；
#    · 跟随用"面包屑轨迹"而不是"固定偏移"：队长拐弯时队友沿着走过的路跟过来，
#      不会斜穿墙角，也不会几个小人叠在同一个点上。
#  谁读：deployed（上阵名单，GameRoot 在 add_child 之前注入）、Global.main_player_selected（谁是队长）。

## 建立"队长名字 + 队友小人"。_ready 里调一次；队伍变化时由 _rebuild_companions() 重建。
## 副作用：给 Player 挂一个名字 Label、往本节点加若干 Companion 节点。
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


## 两个 UnitStats 是不是同一个人（引用或资源路径相同）。
## 用 GameRoot.character_key() 比较：角色资源可能被重新加载成新实例，光比引用会漏。
func _same_character(a: UnitStats, b: UnitStats) -> bool:
	if a == null or b == null:
		return a == b
	return GameRoot.character_key(a) == GameRoot.character_key(b)


## 按当前上阵名单重建跟随者（队长本人不算）。
## 副作用：释放旧的小人节点、重置轨迹（预填一条"向后"的直线，让队友一开始就排在身后）。
## 谁调：_setup_party_visuals()（进地图时）、notify_party_changed()（队伍管理里上阵/下阵后）。
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


## 造一个跟随小人：影子 + 立绘 + 名字（结构和场景里的 Player 一样，只是不带相机）。
## 参数 stats：这个队友的 UnitStats（立绘取 icon）。
## 返回值：新建的 Node2D（已经 add_child 到本节点，会受 y_sort 排序）。
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


## 造一个"头顶名字"标签（白字 + 黑描边，压在地图上也看得清）。
## 参数 font_size：字号（队长 18、队友 16）。
## 返回值：Label（调用方负责 add_child 并设 text）。
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


## 记录队长的移动轨迹：沿"上一记录点 → 当前位置"这条线段，每隔 TRAIL_SPACING 像素插一个点。
## 为什么要插点而不是"每帧塞一个"：每帧移动距离随帧率/冲刺变化（普通 6px、冲刺 12px），
##   每帧塞一个点会让队友间距跟着帧率变；按固定像素间隔记录，间距才是稳定的 40px/人。
## 副作用：往 _trail 头部插点（越新的点索引越小），超过 TRAIL_MAX 就截断。
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


## 每帧把队友朝"轨迹上属于他的那个点"插值挪过去。
## 参数 delta：帧间隔（秒）。
## 副作用：改每个小人的 position / 立绘 flip_h。
## 为什么用插值而不是直接赋值：直接赋值会让队友在拐弯时瞬移；插值让队伍看起来是"跟"上来的。
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


# ══════════════════════════════════════════════════════════
#  交互
# ══════════════════════════════════════════════════════════

## 未被子控件消费掉的输入在这里处理（按钮点击、面板里的控件会先吃掉自己的事件）。
## 参数 event：引擎派发的输入事件。
## 返回值：无。
## 副作用：可能开/关各种 UI 浮层、移动键盘焦点、按下焦点按钮、
##        可能调 _debug_print_normalized()（print 输出），
##        并调用 get_viewport().set_input_as_handled() 把事件标记为已处理（防止继续冒泡）。
## 处理顺序（顺序即优先级，不要随便调换）：
##   1. F1 —— 调试用，任何状态下都先响应（包括浮层打开时），并**不因浮层打开而被吞掉**；
##   2. 交易窗口（商人）打开 —— Esc = 先关确认框、再关整个交易；B = 收摊；
##      E = 按下焦点上的那一格；**WASD 交给面板自己**（货架是方格，语义归 MerchantPanel）；
##      交易时背包是"配件"（一起开、一起关），所以这一支排在背包前面；
##   3. 背包打开 —— Esc / B = 关背包；**WASD 故意不在这里处理**（见下面"背包"分支的注释）；
##   4. 角色属性面板打开 —— Esc / C / B = 收摊（连并排的背包一起收，见 _bag_with_stats）；
##      属性面板是只读的，W/S 等输入一概忽略（背包的 WASD 由 BagPanel 自己处理）；
##   5. 队伍管理二级页打开 —— Esc = 退回操作菜单（上一级）；W/S/E 走 _overlay_nav()；其它输入忽略；
##   6. 操作菜单打开 —— Esc = 关菜单回游戏；W/S/E 走 _overlay_nav()；其它输入忽略；
##   7. NPC 对话面板打开 —— Esc = 关面板；W/S/E 走 _overlay_nav()（面板按钮也能键盘按了）；其它忽略；
##   8. 没有任何 UI —— Esc = 打开操作菜单；B = 打开背包；C = 打开角色属性（连背包一起开）；
##      有最近 NPC 且是交互键 → 打开它的面板/商店。
## 为什么用 event.pressed and not event.echo：按住键时操作系统会持续发 echo 事件，
##   不做这两项过滤会导致"按住 E 一秒开几十次面板"。
## 说明：方向键 / Enter / 空格**不会**走到这里 —— 它们被 Godot 的 GUI 焦点系统在更早的阶段
##   消费掉了（换焦点、按下焦点按钮）。所以这边只需要补上 WASD 和 E，不必重复实现一遍。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		_debug_print_normalized()
		get_viewport().set_input_as_handled()
		return

	if _shop_open:
		# 交易窗口：方格货架的 WASD 由 MerchantPanel 自己处理（Global.grid_nav：上下 = 上一行同一列），
		# 所以这里**不调 _overlay_nav()**；这里只接三种键：
		#   · Esc —— **先关确认框，再关整个交易**（cancel_confirm() 返回 true 就说明刚关的是确认框）；
		#   · B   —— 收摊（交易顺手打开的背包也一起收，见 _close_merchant）；
		#   · E   —— 按下焦点上的那一格（买得起的格子弹确认框、确认框里的「确定」就是真买；
		#            焦点在「关闭」上时就是关面板）。
		# 注意这一支必须排在 _bag_open 那支**前面**：交易时两个开关都是 true，
		#   谁在前谁说了算 —— 交易是"主窗口"，背包是配件。
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
		# ⚠ 这一支必须排在 _bag_open 那支**前面**：属性面板打开时背包是它的"配件"
		#   （_bag_with_stats），两个开关都是 true —— 属性面板是主窗口，谁在前谁说了算。
		# 属性面板是只读的（没有可操作的格子），Esc / C / B 都直接收摊，连背包一起收。
		if event.is_action_pressed("ui_cancel") or _is_stats_key(event) or _is_bag_key(event):
			_close_stats()
			get_viewport().set_input_as_handled()
		return

	if _bag_open:
		# 背包的 WASD 由 BagPanel 自己处理（方格语义，上下要跳一整行），
		# 所以这里**不调 _overlay_nav()** —— 调了会把 WASD 先吃掉，背包里就动不了了。
		if event.is_action_pressed("ui_cancel") or _is_bag_key(event):
			_close_bag()
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


## 这个事件是不是"开/关背包"的键（B）。
## 参数 event：待判定的输入事件。
## 返回值：true = 按下了 B（不是按住、不是 echo）。
## 为什么硬编码 KEY_B 而不是配一个 InputMap 动作：地图/主菜单那几个动作（move_*、dash）是
##   玩法动作，而"开背包"是纯界面快捷键；工程里 F1（调试取坐标）也是这么硬编码的，
##   保持同一种写法，改键位就改这一处（想做成可配置再把 InputMap 那一套搬过来）。
## 注意 pressed and not echo：按住 B 时系统会持续发 echo，不过滤会一秒开关几十次背包。
func _is_bag_key(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
		and event.keycode == KEY_B


## 这个事件是不是"开/关角色属性"的键（C）。
## 参数 event：待判定的输入事件。
## 返回值：true = 按下了 C（不是按住、不是 echo）。
## 为什么和 _is_bag_key 一样硬编码，而不配 InputMap 动作：见上面那条注释（界面快捷键统一写法）。
func _is_stats_key(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
		and event.keycode == KEY_C


## 支持"项目里配了 interact 动作就用它"，没配则用 E / Enter。
## 实现搬到 Global.is_interact_event()（主菜单也用同一份判断）。
func _is_interact_event(event: InputEvent) -> bool:
	return Global.is_interact_event(event)


# ══════════════════════════════════════════════════════════
#  UI 浮层：操作菜单 / 队伍管理 / 商人 / 背包 / 键盘焦点
# ══════════════════════════════════════════════════════════

## 有没有任何"挡住走动"的 UI 开着（NPC 对话面板 / 操作菜单 / 队伍管理 / 商人 / 背包 / 角色属性）。
## 用途：
##   · _process 判断要不要冻住走动（看面板时玩家不该溜走）；
##   · _unhandled_input 判断输入该走"UI 分支"还是"游戏分支"；
##   · _sync_world_button_focus() 判断地图上那两个常驻按钮要不要禁用焦点。
func _ui_open() -> bool:
	return _panel_open or _menu_open or _party_open or _shop_open or _bag_open or _stats_open


## 实例化五个 UI 浮层并接好信号（由 _ready 调一次）。
## 为什么挂在 UI（CanvasLayer）下：它们是界面，不该跟着相机跑、也不该被 y_sort 排序。
## 为什么在代码里接线（而不是 .tscn 的 [connection]）：这些场景是运行时 instantiate 的，
##   编辑器里连不了"还没被实例化的父节点"的信号。
## 注意「进入战斗」「返回主菜单」直接接到 _on_battle_pressed / _on_back_pressed ——
##   与地图上那两个常驻按钮完全同一条通路，不会出现两份行为不一致的实现。
## ⚠ **实例化顺序 = 绘制顺序**（同一个 CanvasLayer 里按树序画）：交易窗口必须排在背包**后面**。
##   原因：交易时会同时开背包，而每个面板都带一层全屏半透明遮罩（Dim）；背包要是排在后面，
##   它的遮罩会把交易窗口（以及确认框）整体压暗/盖住 —— 用户报的"购买弹窗被遮挡"就是这个。
##   （确认框另外还设了 z_index = 100 双保险，见 MerchantPanel._ask_confirm 的注释。）
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
	# 背包当前没有「关闭」按钮（按要求移除了），这条连接是留给以后加按钮用的：
	# 现在关背包只有 Esc / B 两条路，都走 _close_bag()。
	_bag_panel.close_requested.connect(_close_bag)
	# 点背包格子 = "这个格子被点了"：交易界面开着就是卖，否则就是穿（见 _on_bag_item_activated）
	_bag_panel.item_activated.connect(_on_bag_item_activated)
	# 点已穿上的装备栏 = 脱下来放回背包
	_bag_panel.unequip_requested.connect(_on_bag_unequip_requested)
	# 背包换了"看谁" → 并排的属性面板跟着切（反之亦然，见 _on_stats_character_view_changed）
	_bag_panel.character_view_changed.connect(_on_bag_character_view_changed)

	# 角色属性面板（和背包一样是"点开就盖在外面"的普通二级页）。
	# 它贴屏幕**左下角**、背包贴右下角，所以打开属性面板时背包可以同时开着、两边都能点。
	_stats_panel = STATS_PANEL_SCENE.instantiate() as StatsPanel
	ui_layer.add_child(_stats_panel)
	_stats_panel.character_view_changed.connect(_on_stats_character_view_changed)
	# 点「＋」加属性点：只重设焦点环（点数花完后「＋」置灰、要退出环），不抢焦点
	_stats_panel.points_spent.connect(_on_stats_points_spent)
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


## 打开背包（操作菜单的「背包」、地图上按 B、或商人交易顺手打开）。
## 参数 from_menu：是不是从操作菜单进来的。true = 把菜单藏起来，并且关背包时退回菜单；
##   false（按 B 直接开）= 关背包就直接回游戏。两条路的 Esc 行为不一样，所以要记下来。
## 参数 as_companion：是不是"商人交易"顺手打开的。true 时关交易会把背包一起收掉
##   （见 _close_merchant），关背包时也不会顺手弹菜单。
## 副作用：_bag_open = true；（从菜单来时）藏菜单；重置"正在看谁"为队长；格子恢复可聚焦；
##   把当前背包内容重建成方格；聚焦第一个有东西的格子（焦点一落上去 TooltipManager 就会弹
##   属性卡，所以开背包就能直接看到第一件武器）。
## 数据来源：Global.equipped_weapons（商人买到的东西都在这里）+ GameRoot.BAG_SLOTS（格数）。
## 每次都重建：背包是"随时可能被商人改"的数据，打开时现取最不容易出现"看到旧内容"。
func _open_bag(from_menu := false, as_companion := false) -> void:
	_bag_open = true
	_bag_from_menu = from_menu
	_bag_with_shop = as_companion
	if from_menu:
		_pause_menu.hide()
		_menu_open = false        # 菜单确实不显示了，状态位要跟着诚实（关闭时由 _close_bag 再弹回来）
	_bag_panel.clear_message()
	# 单独开背包（没跟商人交易）时，点格子是**穿装备**；把这条提示写在信息行，
	# 免得玩家只知道"交易时点格子能卖"，不知道平时点一下是穿。
	if not as_companion:
		_bag_panel.show_message("点背包里的装备即可给当前角色穿上 · ◀/▶ 换人 · 点已穿的装备栏可脱下")
	_bag_panel.reset_view()       # 重新打开时先看队长（买卖引起的重建不会重置，见 show_bag 说明）
	_bag_panel.set_slot_focus_enabled(true)
	_rebuild_bag()
	_set_focus_ring(_bag_panel.focus_ring())
	_sync_world_button_focus()


## 操作菜单里点了「背包」。
## 为什么不让 bag_requested 直接接 _open_bag：那个信号的参数是空的，
##   直连会让 from_menu 拿到默认值 false，于是"从菜单进来"这条信息就丢了。
func _on_menu_bag_requested() -> void:
	_open_bag(true)


## 关闭背包，回到游戏（Esc 与 B 键都走这里；背包里没有「关闭」按钮）。
## 副作用：_bag_open = false；收起提示卡（焦点没了卡片本来就会走，但鼠标可能正压着格子）；
##        隐藏面板、清焦点环、恢复地图按钮可聚焦；
##        如果这次是从操作菜单进来的，顺手把菜单再弹回来（逐级返回，和队伍管理页一致）。
func _close_bag() -> void:
	_bag_open = false
	_bag_with_shop = false
	_bag_with_stats = false
	TooltipManager.hide_tip()
	_bag_panel.hide()
	_focus_ring.clear()
	_sync_world_button_focus()
	if _bag_from_menu:
		_bag_from_menu = false
		_open_pause_menu()


## 打开角色属性面板（操作菜单的「角色属性」、或地图上按 C）。
## 参数 from_menu：是不是从操作菜单进来的。true = 把菜单藏起来，关掉时退回菜单；
##   false = 按 C 直接开，关掉就回游戏（和背包的两条路语义完全一致）。
## 副作用：_stats_open = true；（从菜单来时）藏菜单；**同时把背包也打开**（见下）；
##        按当前团队名册重建属性内容；把焦点交给背包的格子（玩家要能点着穿装备）。
## 为什么一起打开背包：属性面板贴**左下角**、背包贴**右下角**，一左一右不重叠，
##   于是"一边看这个人的属性、一边在背包里点装备穿给他"是最自然的用法（用户要求可以交互）。
##   关属性面板时会把这份"配件背包"一起收掉（见 _close_stats / _bag_with_stats）。
## 焦点归谁：背包（它能点、能滚）。属性面板只有两个切换箭头，用鼠标点即可，
##   键盘要换人可以直接在背包里按 ◀ / ▶ —— 两边是同步的。
func _open_stats(from_menu := false) -> void:
	_stats_open = true
	_stats_from_menu = from_menu
	if from_menu:
		_pause_menu.hide()
		_menu_open = false        # 菜单确实不显示了，状态位要跟着诚实（关闭时由 _close_stats 再弹回来）
	if not _bag_open:
		_open_bag(false, true)    # as_companion = true：关属性面板时一起收
		_bag_with_stats = true
	# 让属性面板和背包**一样高**（背包先算过尺寸，这里取它的实际高度）
	_stats_panel.set_linked_height(_bag_panel.panel_height())
	_stats_panel.show_stats(_party)
	# 两边先对齐到同一个人（背包刚 reset_view 到队长，属性面板也按队长开）
	_stats_panel.show_character(_bag_panel.current_character())
	# 焦点环 = 背包格子 + 属性面板的箭头/「＋」（背包在前：主操作是背包，属性面板是看数值/加点）
	_set_focus_ring(_combined_ring())
	_sync_world_button_focus()


## 属性面板（和它一起开的背包）当前的焦点环。
## 为什么要把两个面板的控件拼在一起：它们同屏、都能点/都能用键盘，
##   只给其中一个设环的话，另一个的按钮就永远走不到（W/S 会跳过它）。
## 顺序：背包格子在前（点装备是主操作），属性面板的 ◀ ▶ / 「＋」在后。
func _combined_ring() -> Array[Control]:
	var out: Array[Control] = []
	if _bag_open and _bag_panel != null:
		out.append_array(_bag_panel.focus_ring())
	if _stats_open and _stats_panel != null:
		out.append_array(_stats_panel.focus_ring())
	return out


## 操作菜单里点了「角色属性」。
## 为什么不把 stats_requested 直接接 _open_stats：信号没有参数，直连会让 from_menu 丢成 false。
func _on_menu_stats_requested() -> void:
	_open_stats(true)


## 关闭角色属性面板，回到游戏（Esc / C / B 都走这里；面板里没有「关闭」按钮）。
## 副作用：_stats_open = false；收起提示卡、隐藏面板；
##        如果背包是"跟着属性面板一起开的"（_bag_with_stats），把它也一起收掉；
##        恢复地图按钮可聚焦；如果这次是从操作菜单进来的，顺手把菜单再弹回来。
func _close_stats() -> void:
	_stats_open = false
	TooltipManager.hide_tip()
	_stats_panel.hide()
	if _bag_with_stats:
		_bag_with_stats = false
		if _bag_open:
			_close_bag()          # 里面会清焦点环 / 恢复按钮焦点
	_focus_ring.clear()
	_sync_world_button_focus()
	if _stats_from_menu:
		_stats_from_menu = false
		_open_pause_menu()


## 背包换了"看谁"（◀ / ▶）→ 属性面板跟着切到同一个人。
## 参数 character：背包当前展示的角色。
func _on_bag_character_view_changed(character: UnitStats) -> void:
	if _stats_open:
		_stats_panel.show_character(character)


## 属性面板换了"看谁" → 背包跟着切（于是"看谁"和"点格子穿给谁"永远是同一个人）。
## 参数 character：属性面板当前展示的角色。
func _on_stats_character_view_changed(character: UnitStats) -> void:
	if _bag_open:
		_bag_panel.show_character(character)


## 属性面板点了一次「＋」：只把焦点环换成新的（不抢焦点）。
## 为什么不能走 _set_focus_ring()：那个会 grab 第一个控件，玩家用键盘连点时焦点每点一下
##   就跳回 ◀，根本没法连续加同一条属性；这里只更新数组，让 W/S 的候选列表跟着变。
## 用 _combined_ring() 而不是只看属性面板：背包还开着，格子也得留在环里。
func _on_stats_points_spent() -> void:
	if _stats_open and _stats_panel != null:
		_focus_ring = _combined_ring()


## 按当前背包内容重建方格（打开时调；以后做"卖出/合成"成功后再调一次即可）。
## 参数一并传 _party：角色区的 ◀ / ▶ 要在团队名册里翻页（只读，本面板不会改它）。
func _rebuild_bag() -> void:
	_bag_panel.show_bag(Global.equipped_weapons, GameRoot.BAG_SLOTS, _party)


## Esc：打开操作菜单。
## 副作用：_menu_open = true；按本图能不能打决定「进入战斗」是否置灰；
##        把地图上那两个常驻按钮设成不可聚焦；菜单 show() 并聚焦第一项。
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


## 打开队伍管理二级页（从操作菜单的「队伍管理」进来）。
## 副作用：_party_open = true；把操作菜单先藏起来（二级页盖在它上面，藏掉免得两层都亮着）；
##        让面板按当前"团队 + 上阵名单"重建列表；把焦点交给它的按钮列表。
func _open_party_panel() -> void:
	_party_open = true
	_pause_menu.hide()
	_menu_open = false            # 菜单确实不显示了，状态位要跟着诚实（退回时由 _back_from_party_panel 再弹回来）
	_party_panel.clear_message()
	_party_panel.show_party(_party, deployed)
	_set_focus_ring(_party_panel.focus_ring())
	_sync_world_button_focus()


## Esc / 「返回」：从队伍管理退回到操作菜单。
## 为什么是"退回菜单"而不是"直接回游戏"：它是操作菜单下的二级页，按 Esc 应该逐级退，
## 玩家想继续游戏的话再按一次 Esc 就行（或者直接选菜单里的「继续游戏」）。
func _back_from_party_panel() -> void:
	_party_open = false
	_party_panel.hide()
	_focus_ring.clear()
	_open_pause_menu()


## 队伍管理面板里点了「上阵」：只把请求转给 GameRoot（真正改数据的地方）。
## 参数 stats：要上阵的成员。
func _on_party_deploy_requested(stats: UnitStats) -> void:
	party_deploy_requested.emit(stats)


## 队伍管理面板里点了「下阵」：同上，只转请求。
## 参数 stats：要下阵的成员。
func _on_party_undeploy_requested(stats: UnitStats) -> void:
	party_undeploy_requested.emit(stats)


## 队伍管理面板里点了「移出团队」：只把请求转给 GameRoot（真正改队伍的地方）。
## 参数 stats：要移出的成员。
func _on_party_remove_requested(stats: UnitStats) -> void:
	party_remove_requested.emit(stats)


# ══════════════════════════════════════════════════════════
#  商人面板（NPC 交互类型 SELL_WEAPONS）
# ══════════════════════════════════════════════════════════

## 打开商人面板。
## 参数 data：那个商人的配置（display_name 当标题、dialogue 当台词、shop_label 当按钮措辞、
##            sell_pool 当货架）。
## 副作用：_shop_open = true；记下 _merchant_data（买完重建货架要用它）；按"货架 + 当前金币 +
##        已持有"重建面板；**同时打开背包**（"看看货、也看看自己有什么"）；
##        地图上那两个常驻按钮设为不可聚焦。
## 位置：交易窗口贴**最左边**、背包贴**最右边**（各自的面板自己算），一左一右不重叠。
## ⚠ 交易时背包**保持可交互**（用户要求）：点背包里的格子就是把东西卖给商人
##   （_bag_panel.item_activated → _on_bag_item_activated → _sell_bag_item → 交易面板弹确认框）。
##   所以这里**不再**调用 set_slot_focus_enabled(false)；只在确认框弹出时临时收焦点
##   （见 _on_merchant_confirm_changed）。
## 注意它**不置 _panel_open**：商人不用那个小对话框面板（方格货架铺不下），
##   所以 _open_panel() 在分流时就直接 return 了（见那里的注释）。
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


## 关闭商人面板，回到游戏（Esc 与「关闭」按钮都走这里）。
## 副作用：_shop_open = false；收起面板；**如果背包是交易顺手打开的，一起收掉**；
##        恢复背包格子的键盘焦点能力；清焦点环。
func _close_merchant() -> void:
	_shop_open = false
	_merchant_data = null
	_merchant_panel.hide()
	if _bag_with_shop:
		_close_bag()               # 交易结束，配件背包一起收（_bag_with_shop 由它清掉）
	_bag_panel.set_slot_focus_enabled(true)
	_focus_ring.clear()
	_sync_world_button_focus()


## 按当前数据重建商人面板的货架（打开时、以及每次买完都调）。
## 货架来源：MapNPC.sell_pool 优先，留空 → Global.get_all_equipment()（现有全部装备，
##   按"栏位 → 价格"排序）。老武器（ItemWeapon）不再进地图线的货架。
## 传的是**当前**金币与已持有列表：于是"买完一件之后买不起的立刻变灰"是自动的，
##   不需要谁去手动把按钮 disabled 一遍。
func _rebuild_merchant() -> void:
	if _merchant_data == null:
		return
	var items: Array[ItemBase] = _merchant_data.sell_pool if not _merchant_data.sell_pool.is_empty() \
			else Global.get_all_equipment()
	# 注意：只传名字（面板顶部居中显示），不再传台词/金币 —— 那两行按需求移除了。
	# coins 仍然要传：面板要靠它判定"哪些格子买不起"（置灰），只是不显示而已。
	_merchant_panel.show_shop(_merchant_data.display_name, items, Global.coins,
			Global.equipped_weapons)


## 商人面板里的「购买」：只把请求转给 GameRoot（真正扣钱 + 入包的地方）。
## 参数 item：要买的道具。
func _on_item_buy_requested(item: ItemBase) -> void:
	item_buy_requested.emit(item)


## 背包里点了一格（BagPanel.item_activated）—— 同一个点击，按"有没有开商人"分流：
##   · 交易界面开着 → 卖掉（_sell_bag_item：让交易面板弹"卖出"确认框）；
##   · 没开商人     → 给**背包界面当前展示的那个角色**穿上
##     （equip_requested(character, item) → GameRoot.equip_item()）。
## 为什么分流放在这里而不是背包面板里：面板只该知道"这一格被点了 / 现在展示的是谁"，
##   "现在是在交易还是在换装"是地图/GameRoot 的业务状态（和买卖一样，界面只发请求）。
## 参数 item：被点的道具（ItemBase）。
func _on_bag_item_activated(item: ItemBase) -> void:
	if _shop_open:
		_sell_bag_item(item)
		return
	equip_requested.emit(_bag_panel.current_character(), item)


## 把背包里的一件东西卖给商人（只有交易界面开着时才走这里）。
## 参数 item：被点的那件道具（装备/以后别的可卖品都走这条）。
## 规则：先让交易面板弹确认框（写清卖价），确认后才走 GameRoot.sell_item()。
## 已经在等一个确认时直接忽略：不然连着点两件，待确认的那件会被悄悄换掉。
## 卖不了（背包里已经没有 / 非卖品）时只在信息行说原因，不弹空框。
func _sell_bag_item(item: ItemBase) -> void:
	if _merchant_panel.is_confirm_open():
		return
	var why := GameRoot.item_can_sell(item, Global.equipped_weapons)
	if not why.is_empty():
		_bag_panel.show_message("（%s）" % why)
		return
	_merchant_panel.ask_sell(item, GameRoot.item_sell_price(item))


## 点了某个角色已穿上的装备栏（BagPanel.unequip_requested）：把请求转给 GameRoot。
## 参数 slot_type：ItemBase.EquipType 的成员值。目标角色 = 背包界面当前展示的那个人
##   （BagPanel.current_character()）。真正"能不能脱"（角色为空 / 栏位空 / 背包满）由
##   GameRoot.unequip_slot() 判定，成功后回调 notify_bag_changed() 重建背包和装备栏。
func _on_bag_unequip_requested(slot_type: int) -> void:
	unequip_requested.emit(_bag_panel.current_character(), slot_type)


## 交易面板的卖出确认框点了「确定」：转给 GameRoot（真正出包 + 加钱的地方）。
## 参数 item：要卖的道具。
func _on_item_sell_requested(item: ItemBase) -> void:
	item_sell_requested.emit(item)


## 交易面板的确认框开了/关了：同步背包格子的键盘焦点。
## 参数 open：true = 确认框开着（这是一次模态询问，背包格子暂时不能聚焦）；
##            false = 收起了，恢复背包可聚焦（交易时背包本来就该能点/能选）。
func _on_merchant_confirm_changed(open: bool) -> void:
	_bag_panel.set_slot_focus_enabled(not open)


## 金币/背包变化后刷新界面（GameRoot 买/卖成功后调用；失败时也调用，用来显示原因）。
## 参数 message：非空时作为商人面板的提示文字（"买下了 XXX（-12 金币）。" / "金币不够…"）。
## 副作用：刷新背包信息行的余额；商人面板开着时重建货架（灰不灰、"已持有 ×n" 全跟着变）；
##        背包开着时也重建方格（交易中背包内容会变 —— 买东西进来、卖东西出去）。
## 为什么要 call_deferred 重建：这条链很可能是"某个按钮的 pressed 回调"发起的，
##   立刻 remove_child 会把正在发信号的按钮从树上摘掉 —— 延到帧末最省心（同队伍面板）。
## ⚠ 交易中**不要**去同步背包的焦点（_sync_bag_focus）：背包格子现在是可聚焦的，
##   每买卖一次就把焦点抢回背包，玩家正在货架上挑东西的焦点就飞了。焦点归交易窗口。
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


## 背包 / 装备变化后刷新界面（GameRoot 穿脱装备后调用；失败时也调用，用来显示原因）。
## 参数 message：非空时写进**背包信息行**（"穿上了「X」（武器栏）。" / "背包满了…"）。
## 和 notify_shop_changed 的分工：那条是"和商人有关的刷新"（还会重建货架、写商人提示行）；
##   这条只管背包 + 装备栏，所以**没开商人**（换装）时也能用。
## 副作用：刷新余额；背包开着时重建方格与装备栏（延到帧末，理由同 notify_shop_changed）、
##        并把焦点环同步成新的格子（穿/脱会换掉一批按钮）；
##        角色属性面板开着时也让它重读一遍（左边那 6 个装备格和"装备加成"要跟着变）。
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


## 延迟同步背包的焦点环（理由同上）。
## 属性面板也开着时用合并环，否则「＋」会从 W/S 的候选里消失。
func _sync_bag_focus() -> void:
	if _bag_open and _bag_panel != null:
		_set_focus_ring(_combined_ring())


## 用 Global.coins 的当前值刷新界面上的金币显示。
## 为什么需要：金币会被商人买卖改掉，界面要跟着变。
## ⚠ 地图上**没有**金币标签了（右上角那个已按需求移除），所以这里只做一件事：
##   把并排/右下角的背包信息行同步一下（`BagPanel.refresh_coins()`）。
##   金币的真值始终是 Global.coins，本文件不再保存任何金币快照字段。
func refresh_coins() -> void:
	if _bag_panel != null:
		_bag_panel.refresh_coins()


## 打开浮层时把地图上那两个常驻按钮设成"不可聚焦"，关掉浮层后再恢复。
## 为什么需要：Godot 的 GUI 焦点系统是按**空间方向**找邻居的，浮层开着时按方向键
##   可能跳到「进入战斗」/「返回主菜单」上 —— 焦点就跑出浮层了。把它们的 focus_mode
##   设成 NONE，方向键只能在浮层的按钮里转，和 W/S 的 _focus_ring 行为也就一致了。
func _sync_world_button_focus() -> void:
	var mode := Control.FOCUS_NONE if _ui_open() else Control.FOCUS_ALL
	battle_button.focus_mode = mode
	back_button.focus_mode = mode


## 设置当前浮层的"焦点环"（按视觉顺序排列的可聚焦按钮），并聚焦第一个。
## 参数 controls：控件列表；传空数组 = 清空（浮层关掉时）。
## 注意：调用前浮层必须已经 show() —— grab_focus() 对"隐藏在不可见父节点下"的控件是无效的
##   （静默失败，键盘就整片失灵），所以本函数的调用点全都排在 show() 之后。
func _set_focus_ring(controls: Array[Control]) -> void:
	_focus_ring = controls
	if not _focus_ring.is_empty():
		_focus_ring[0].grab_focus()


## 在焦点环里前后循环移动焦点（W/S 用）。
## 实现搬到 Global.step_focus()，与主菜单共用（含"焦点不在环里时从第一个开始"的兜底）。
func _step_focus(step: int) -> void:
	Global.step_focus(self, _focus_ring, step)


## 按下当前焦点上的按钮（E 键用）。
## 实现搬到 Global.activate_focused()，与主菜单共用。
func _activate_focused() -> void:
	Global.activate_focused(self)


## 浮层里的键盘操作：W/S 换焦点、E 确认。
## 参数 event：待判定的输入事件。
## 返回值：true = 这个事件已经被消费掉（调用方要调 set_input_as_handled）。
## 说明：方向键 / Enter / 空格不在这里处理 —— 它们在更早的 GUI 阶段就被焦点系统消费掉了，
##   _unhandled_input 根本收不到，所以也不会出现"按一次跳两格"。
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


## 收集一个容器里所有可点按钮（按视觉顺序）。
## 实现搬到 Global.collect_focusable() 了 —— 主菜单也要键盘操作，两边共用同一套规则
## （尤其是"置灰按钮不进环"这条，两处各写一遍迟早会分叉）。这里保留同名包装，调用处不用改。
func _collect_focusable(root: Node) -> Array[Control]:
	return Global.collect_focusable(root)


## 延迟同步队伍管理面板的焦点环。
## 为什么延迟：重建成员行是 call_deferred 的（见 notify_party_changed），焦点环得晚一步再取，
## 否则拿到的是马上要被释放的旧按钮。
## 焦点落在环的第一个可点按钮上（移除一位成员后跳到最上面那行）—— 行为可预期，
## 不搞"记住原来第几行"那套，因为列表长度刚变过，那个下标已经没有意义了。
func _sync_party_focus() -> void:
	if _party_open and _party_panel != null:
		_set_focus_ring(_party_panel.focus_ring())


## 打开某个 NPC 的对话/传送面板。
## 参数 npc：要交谈的 NPC（调用方已确保非 null）。
## 返回值：无。
## 副作用：
##   · 置 _panel_open = true（于是 _process 停止处理走动）；
##   · 记住是哪个 NPC（_panel_npc），然后调 _rebuild_panel_buttons() 铺按钮区 ——
##     具体铺什么由 MapNPC.action 决定（传送 / 招募队友 / 只给一句台词）；
##   · panel.show()。
## 坑：
##   · remove_child 之后又 queue_free 是刻意写法 —— 只 queue_free 的话节点会留到帧末，
##     这一帧内 get_children() 仍能拿到它们；先 remove_child 保证布局立刻干净；
##   · button.pressed.connect(...bind(dest_id)) —— bind 会把 dest_id 作为**最后一个**参数追加，
##     所以 _on_destination_pressed(map_id) 的形参顺序必须与之对应；
##   · 运行时 new 出来的按钮 owner 是 null，只能 queue_free 自己，不能走 owner 那条路。
func _open_panel(npc: WorldNPC) -> void:
	# 商人不走"小对话框铺按钮"这条路：44 把武器塞进 600×460 的小面板根本看不了，
	# 所以直接开一个带滚动列表的大面板（_open_merchant），并且**不置 _panel_open**。
	# 分流放在这里而不是调用点：_unhandled_input 只管"按 E 和最近的 NPC 交互"，
	#   "这个 NPC 该用哪种面板"是交互类型的事，归本函数管（和 resolve_action 同一个地方）。
	if resolve_action(npc.data) == MapNPC.Action.SELL_WEAPONS:
		_open_merchant(npc.data)
		return

	_panel_open = true
	_panel_npc = npc
	panel_name.text = npc.data.display_name
	panel_dialogue.text = npc.data.dialogue
	_rebuild_panel_buttons()
	# 顺序很重要：先把面板 show() 出来，再设焦点。
	# grab_focus() 对"隐藏在不可见父节点下"的控件是无效的（静默失败），
	# 反过来写的话用 E 打开面板后键盘就整片失灵，而且没有任何报错提示。
	panel.show()
	_set_focus_ring(_collect_focusable(panel_buttons))
	_sync_world_button_focus()


## 按当前 NPC 的交互类型重建按钮区。
## 调用时机：每次打开面板（_open_panel）以及招募成功后刷新（notify_party_changed）。
## 副作用：清空 panel_buttons 的子节点（先 remove_child 再 queue_free，理由同旧代码的注释），
##        再按类型铺新按钮。
## 坑：一个按钮都不铺也是合法状态（TALK 类型）—— 面板只显示台词，靠「再想想」关闭。
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
			# 正常走不到这里：商人在 _open_panel() 就被分流到商人面板了，压根不会打开本面板。
			# 留着这一支是为了"万一日后有人手动对商人调面板"时给一句人话，而不是那句误导的传送说明。
			_add_panel_note("（商人：按 E 直接开商店面板，不在这个小窗口里卖）")
		_:
			_add_panel_note("（这个 NPC 目前不送人去别处）")
	_fit_panel_height()


## 按按钮区的实际需要把面板撑高，避免按钮溢出面板背景。
## 为什么需要：world_map.tscn 里 TravelPanel 是**固定 460 高**的居中面板，而招募 NPC 有 5 个候选
## （5×52 + 4×12 = 308 px 的按钮区），加上名字/台词/关闭按钮后总需求约 626 px ——
## 不调整的话后两个按钮和「再想想」会被画到面板外面去（Control 容器默认不裁剪，会直接漏到游戏画面上）。
## 做法：面板是"居中锚点 + 对称 offset"，高度 = offset_bottom - offset_top，改这一对即可；
##   上限取视口高度的 85%，小窗口下也不会顶出屏幕（真超了就靠 VBox 自己挤，属于极端情况）。
## 参数：无（直接读 panel_buttons 里已有子节点的最小尺寸）。
## 副作用：改 panel 的 offset_top / offset_bottom。
func _fit_panel_height() -> void:
	var needed := 0.0
	for child in panel_buttons.get_children():
		needed += child.get_combined_minimum_size().y
	if panel_buttons.get_child_count() > 1:
		needed += panel_buttons.get_theme_constant("separation") * float(panel_buttons.get_child_count() - 1)
	# 名字 ~40 + 台词 90 + 关闭按钮 52 + 外框上下边距 48 + 三段间隔（16×3）= 278
	var total := needed + 278.0
	total = clampf(total, PANEL_MIN_HEIGHT, get_viewport_rect().size.y * 0.85)
	panel.offset_top = -total * 0.5
	panel.offset_bottom = total * 0.5

## 把 MapNPC.Action.AUTO 解析成"具体会干什么"。
## 静态函数：面板、GameRoot、以后的成就/任务系统想判断"这个 NPC 是干什么的"都可以问它，
## 于是"有 destinations 就算传送 NPC"这条老规则只写在这里一份（老的 .tres 不用改就能继续用）。
static func resolve_action(data: MapNPC) -> MapNPC.Action:
	if data == null:
		return MapNPC.Action.TALK
	if data.action != MapNPC.Action.AUTO:
		return data.action
	return MapNPC.Action.TELEPORT if not data.destinations.is_empty() else MapNPC.Action.TALK


## 铺传送按钮（从 _open_panel 里原样搬过来的，行为不变）。
func _build_teleport_buttons(data: MapNPC) -> void:
	if data.destinations.is_empty():
		_add_panel_note("（这个 NPC 目前不送人去别处）")
		return
	for dest_id in data.destinations:
		var button := Button.new()
		# 显示名优先查 _map_names；查不到（例如指向了一张没进 main.tscn 的地图）就退化成 id 本身。
		button.text = "%s %s" % [data.teleport_label, _map_names.get(dest_id, dest_id)]
		button.custom_minimum_size = Vector2(300, 52)
		button.add_theme_font_size_override("font_size", 22)
		button.pressed.connect(_on_destination_pressed.bind(dest_id))
		panel_buttons.add_child(button)


## 铺招募按钮：每个候选队友一个按钮，已在队里 / 队伍已满的按钮置灰不可点。
## 候选来源：MapNPC.recruit_pool 优先，留空则问 Global 要目录扫描结果（见 _recruit_candidates）。
## 面板底部再补一行"团队 n 人（上阵 m/5）：…"，玩家点完一眼能看到结果，不用猜有没有生效。
## 说明：招募是往**团队**里加人（上阵由队伍管理面板决定），所以这里判的是"已在团队中"；
##   团队默认不限人数（GameRoot.MAX_TEAM_SIZE = 0），只有把它设成正数才会有"团队已满"这一档。
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
		button.custom_minimum_size = Vector2(0, 52)
		button.add_theme_font_size_override("font_size", 20)
		button.disabled = joined or team_full
		if not button.disabled:
			button.pressed.connect(_on_recruit_pressed.bind(stats))
		panel_buttons.add_child(button)
	_add_panel_note(_party_summary())


## 候选队友列表：显式 recruit_pool 优先，否则用 Global 的目录扫描。
## 为什么不缓存"合并后的候选"：recruit_pool 是 .tres 里的数据，运行期可能被编辑器改，
## 每次开面板现取最不容易出现"改了没生效"的困惑；Global 那边自己有缓存，开销可忽略。
func _recruit_candidates(data: MapNPC) -> Array[UnitStats]:
	if not data.recruit_pool.is_empty():
		return data.recruit_pool
	return Global.get_recruitable_players()


## 一行属性摘要（招募按钮文字用）。只挑最影响选择的 3 项 + 种族（种族决定能拜哪个门派，
##   所以招募时就该看见），避免按钮文字过长挤成一团。
## 数值格式化统一走 Global.format_stat()：队伍管理面板用的是同一个函数，两处显示不会不一致。
func _stats_digest(stats: UnitStats) -> String:
	return "%s · HP %s · 攻 %s · 速 %s" % [
		stats.race_name(),
		Global.format_stat(stats.health),
		Global.format_stat(stats.damage),
		Global.format_stat(stats.speed),
	]


## 面板底部的摘要文字：团队人数 + 上阵人数 + 团队成员名单。
## 一行里同时给出两个数字，是为了让"团队可以很多人、但只有 5 个上阵"这件事在招募时也可见。
func _party_summary() -> String:
	var names := GameRoot.party_names_of(_party)
	var body := "、".join(names) if not names.is_empty() else "（空）"
	return "团队 %d 人（上阵 %d/%d）：%s" % [
		GameRoot.party_count(_party), GameRoot.party_count(deployed),
		GameRoot.MAX_DEPLOYED, body]


## 往按钮区加一行不可点击的说明文字。
## 抽出来的原因：以前这句 Label 是内联写在 _open_panel 里的，现在"传送/招募/兜底"三条路都要用。
## ⚠ 这里**不要**开 autowrap：容器里的 Label 在拿到真实宽度之前算最小尺寸时，自动换行会按
##    "每个字一行"报一个巨大的最小高度（实测 25 字的队伍摘要把面板撑到了 1013 px），
##    而 _fit_panel_height() 正是按子节点的最小高度算面板高度的，会被这个假高度带跑。
##    说明文字都很短（一行放得下），横向溢出的极端情况远比纵向撑破面板好看。
func _add_panel_note(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.clip_text = true
	panel_buttons.add_child(label)


## 招募按钮回调。本函数**只发请求**：真正的入队判定在 GameRoot._on_recruit_requested()。
## 参数 stats：候选角色（由 bind 绑进来的 UnitStats 资源）。
## 副作用：播 UI 音效、emit recruit_requested(stats)。刻意**不关面板** —— 玩家要能连着招第二个，
##   也才能看到按钮变成"已在队伍中"。
func _on_recruit_pressed(stats: UnitStats) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	recruit_requested.emit(stats)


## 铺拜师按钮：团队名册里的每个人一行，按"种族能不能拜"和"是不是已有门派"决定是否可点。
## 参数 data：掌门的 MapNPC（datasect_id 指向 Global.SECTS 的键）。
## 副作用：往 panel_buttons 里加"门派说明 + 每个队员一个按钮 + 团队摘要"。
## 为什么把整支团队都铺出来（而不是只铺能拜的）：玩家需要看见"为什么他不能拜"——
##   只列能拜的人，玩家会以为那个人不在团队里，或者面板坏了。
## 委托判定给 GameRoot.can_join_sect()：这里**不自己判种族**，规则只有一份。
func _build_sect_buttons(data: MapNPC) -> void:
	var sect_id := data.sect_id
	if not Global.is_sect(sect_id):
		_add_panel_note("（这个掌门没配门派：MapNPC.sect_id 要填 Global.SECTS 的键）")
		return
	var sect_name := Global.sect_name(sect_id)
	_add_panel_note("%s（只收%s）：%s" % [sect_name, Global.sect_races_text(sect_id),
			Global.sect_desc(sect_id)])
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
		button.custom_minimum_size = Vector2(0, 52)
		button.add_theme_font_size_override("font_size", 20)
		button.disabled = not why.is_empty()
		if not button.disabled:
			button.pressed.connect(_on_sect_join_pressed.bind(member, sect_id))
		panel_buttons.add_child(button)
	_add_panel_note(_party_summary())


## 拜师按钮回调。只发请求：能不能拜由 GameRoot.can_join_sect() 判。
## 参数 character：要拜师的那位队员；sect_id：掌门代表的门派。
## 副作用：播 UI 音效、emit sect_join_requested(character, sect_id)。不关面板 ——
##   玩家要能看到按钮变成"已入 XX"，也可能接着给队里另一个人拜同门。
func _on_sect_join_pressed(character: UnitStats, sect_id: String) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	sect_join_requested.emit(character, sect_id)


## 门派变化后刷新界面（GameRoot 拜师成功/失败后调用；失败时也调，用来显示原因）。
## 参数 message：非空时写进 NPC 面板的台词行（"陆孤鸣拜入太虚剑宗！" / "行修是仙族…"）。
## 副作用：NPC 面板开着 → 换台词、重建按钮区、重设焦点环；角色属性面板开着 → 重读一次
##   （名字下面那行「种族 · 门派」要跟着变）。
func notify_sect_changed(message := "") -> void:
	if _panel_open:
		if not message.is_empty():
			panel_dialogue.text = message
		_rebuild_panel_buttons()
		_set_focus_ring(_collect_focusable(panel_buttons))
	if _stats_open:
		_stats_panel.refresh.call_deferred()


## 队伍变化后刷新界面（GameRoot 招募/移除成功后调用；失败时也调用，用来显示失败原因）。
## 参数 message：非空时作为提示文字（例如"Knight 加入了队伍！"/"队伍已经满了（5 人）。"）。
## 副作用：
##   · NPC 对话面板开着 → 台词换成 message、重建按钮区、重设焦点环；
##   · 队伍管理面板开着 → 提示行显示 message、重建成员行、重设焦点环；
##   · 两个都没开 → 什么都不做（message 直接丢掉）。
## 为什么两个面板都要管：招募发生在 NPC 面板里、移除发生在队伍管理面板里，
##   但两者最后都走到这一个函数 —— 这就是"队伍数据只有 GameRoot 一份"带来的好处：刷新点也只有一个。
## 为什么队伍面板要 call_deferred 重建：这条调用链很可能是"队伍管理面板里某个按钮的
##   pressed 回调"发起的，立刻 remove_child 会把正在发信号的按钮从树上摘掉；延到帧末最省心。
func notify_party_changed(message := "") -> void:
	if _panel_open:
		if not message.is_empty():
			panel_dialogue.text = message
		_rebuild_panel_buttons()
		# 重建后按钮是新节点，焦点环必须跟着换（否则 W/S 会在已释放的旧按钮上打转）。
		_set_focus_ring(_collect_focusable(panel_buttons))
	if _party_open:
		if not message.is_empty():
			_party_panel.show_message(message)
		_party_panel.show_party.call_deferred(_party, deployed)
		_sync_party_focus.call_deferred()
	# 上阵名单变了 → 地图上的跟随队伍跟着变（多一个/少一个人）。
	# 用 call_deferred：这条链路是从队伍管理面板的按钮回调里发起的，立刻 queue_free 会摘掉
	# 正在发信号的那个按钮所在的树（和 _party_panel.show_party 同一个理由）。
	_rebuild_companions.call_deferred()

## 关闭对话面板。由「再想想」按钮和 Esc 两处调用。
## 参数：无。返回值：无。
## 副作用：_panel_open = false（走动恢复）、panel.hide()。
## 说明：关闭时**不**清空 panel_buttons —— 下次 _open_panel() 自己会重建，
##   留在树上的旧按钮因为隐藏的父节点不可见，也不接收输入。
func _close_panel() -> void:
	_panel_open = false
	_panel_npc = null
	_focus_ring.clear()
	panel.hide()
	_sync_world_button_focus()


## 玩家选了某个传送目的地（按钮回调）。
## 参数 map_id：目标地图 id（由 bind 绑进来的，见 _open_panel）。
## 返回值：无。
## 副作用：播 UI 音效、关面板、emit travel_requested(map_id) → GameRoot.travel_to()。
## 本节点自己不切场景：切场景、淡入淡出、记住当前位置都是 GameRoot 的活。
func _on_destination_pressed(map_id: String) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	_close_panel()
	travel_requested.emit(map_id)


## 「进入战斗」按钮回调。
## 参数：无。返回值：无。副作用：播 UI 音效 + emit battle_requested（GameRoot.enter_battle）。
func _on_battle_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	battle_requested.emit()


## 「返回主菜单」按钮回调。
## 参数：无。返回值：无。副作用：播 UI 音效 + emit back_to_title_requested（GameRoot.show_title）。
func _on_back_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	back_to_title_requested.emit()


## 调试：把鼠标位置换算成地图归一化坐标打出来（填 spawn_point / NPC.position 用）
## 参数：无（读全局鼠标位置）。
## 返回值：无。副作用：仅 print，无状态改变。
## 换算依据：本节点没有位移/旋转（世界坐标原点 = 图片左上角），所以
##   get_global_mouse_position() 直接除以 _map_size 就是归一化坐标。
##   ⚠ 如果以后给 WorldMap 加了 position/scale，这个换算就不再成立，需要先转回本地坐标。
func _debug_print_normalized() -> void:
	if _map_size == Vector2.ZERO:
		return
	var normalized := get_global_mouse_position() / _map_size
	print("[WorldMap] %s 鼠标归一化坐标: Vector2(%.3f, %.3f)" % [_map.display_name, normalized.x, normalized.y])

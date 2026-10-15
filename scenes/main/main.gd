# ═══════════════════════════════════════════════════════════════════════════
# GameRoot —— 游戏总入口 / 屏幕调度器（唯一主场景 main.tscn 的根脚本）
# ═══════════════════════════════════════════════════════════════════════════
# 在系统里的位置：
#   main.tscn 是 project.godot 里配置的**唯一主场景**，所以本脚本是整局游戏的"根"。
#   它自己**不画任何东西**：画面全部由它 add_child 进来的"屏幕"负责。
#   项目里的屏幕分两类、各有一个容器（都是 main.tscn 里的节点，见下面的 @onready）：
#     · WorldRoot(Node2D)      —— 世界类屏幕：WorldMap / Battle / Arena
#     · UIRoot(CanvasLayer)    —— UI 类屏幕：TitleScreen / SelectionPanel
#     · TransitionLayer(CanvasLayer, layer=200) —— 最上层的黑幕 ColorRect(Fade)，做淡入淡出
#
# 它是全项目唯一"持有流程状态"的地方：
#   current_map_id（当前在哪张图）、party（队伍）、cleared_maps（通关记录）、
#   _map_positions（每张图离开时站的归一化位置）、in_battle（是否在战斗中）。
#   其余系统只拿 MapData / UnitStats 这类资源，互不引用 —— 依赖方向是"屏幕 → GameRoot"单向的。
#
# 屏幕之间怎么通信（本文件的核心模式）：
#   屏幕只 emit 信号（battle_requested / travel_requested / back_to_title_requested /
#   on_selection_completed / battle_ended …），GameRoot 订阅这些信号并决定下一屏是谁。
#   所以"改流程"= 改本文件，屏幕本身不需要知道别的屏幕存在。
#
# 一次完整的新游戏流程（照着读一遍就理解本文件了）：
#   _ready() → fade 全黑 → await show_title()
#     → 主菜单「新的征程」→ start_new_game()（清空所有局内状态、金币重置）
#     → start_game_with_defaults()（**跳过选人/选武器界面**：直接取 default_leader / default_weapon）
#         → _on_selection_completed()
#             → party（团队）= [队长]、deployed（上阵）= [队长]，初始武器入包，emit map_changed
#     → show_map()（把 WorldMap 挂到 WorldRoot 下）
#         → 地图里点「进入战斗」→ enter_battle() → _swap(battle, world_root)
#             → 打完 emit battle_ended → _on_battle_ended()：记通关、发奖励、回地图（原地）
#         → 地图里点传送 → travel_to(next_id)：记住位置、换 current_map_id、show_map() 到新图
#   竞技场（TitleScreen 的「经典模式」）走另一条线：enter_arena() → Arena 自成一体的玩法。
#
# ⚠ 选人界面（SelectionPanel）现在**不在主流程里**了：主菜单「新的征程」直接用
#   default_leader + default_weapon 开局。想恢复"选人 → 选武器"的老流程：
#   把 start_new_game() 末尾的 start_game_with_defaults() 换回 show_character_select() 即可
#   （面板场景与脚本一直留着，一行都没删）。
#
# 数据流（谁写 Global）：
#   本文件会写 Global.coins（start_new_game 重置 / _on_battle_ended 发奖励）、
#   Global.equipped_weapons（清空 / 追加初始武器）、Global.main_player_selected 与
#   main_weapon_selected（start_new_game 里置 null）、Global.player（由
#   Global.get_selected_player() 在 Arena 那边赋值，本文件不碰）。
#
# 坑（改之前务必看）：
#   · 本文件大量使用 await（等 tween、等 fade、等信号）—— 每个用到 await 的函数都是**协程**，
#     调用方如果不 await（例如 travel_to 里那句 show_map(...)）它会在第一个 await 处"挂起并返回"，
#     剩下的部分在后台继续跑。这是刻意的：调用方不需要等过场演完。
#   · _swap() 会清空**两个**容器（WorldRoot + UIRoot），所以任何时刻只存在一个"屏幕"。
#   · 运行时 add_child 进来的屏幕 owner 是 null：只能 queue_free() 自己，
#     不能写 owner.queue_free()（_clear_screens 里就是这么做的）。
#   · 换屏不是换 SceneTree 场景（不调 change_scene_to_*）：全局 autoload（Global/SoundManager）
#     一直都在，而 Global 里的字段**跨屏存活、不会自动重置** —— 新开一局必须像
#     start_new_game() 那样逐项手动清（注意它并**没有**清 Global.player）。

extends Node
class_name GameRoot

## 游戏总入口（唯一主场景）
##
## 流程：
##   主菜单(TitleScreen) → 选人(SelectionPanel) → 世界地图(WorldMap, 走动探索)
##        → 点地图上的传送点前往下一张图 / 点「进入战斗」打当前地图的敌人
##        → 回合制战斗(Battle) → 结算 → 回地图 → …（最后一张图是终点）
##
## 地图串联（顺序）：建邺城 → 东海湾 → 傲来国 → 花果山
##   每张图的配置在 resources/maps/*.tres（MapData），next_id 指向下一张，
##   最后一张 next_id 留空。要加新图（比如狮驼岭）：
##     复制一个 .tres → 改 id / display_name / texture / next_id → 加进 main.tscn 的 Maps 数组
##
## 场景里的三个容器：
##   WorldRoot        Node2D     —— 世界类屏幕（战斗 / 竞技场）
##   UIRoot           CanvasLayer—— UI 屏幕（主菜单 / 地图 / 选人）
##   TransitionLayer  CanvasLayer—— 最高层黑幕，淡入淡出
##
## 扩展点：
##   · 存档         → 存/读 current_map_id、party、Global.coins、cleared_maps
##   · 伙伴/队伍    → party 现在只有主角，加伙伴就往里 append（战斗最多 4 个站位）
##   · 地图解锁     → _on_battle_ended() 里已记录 cleared_maps，可在 travel_to() 里加"先打赢才能走"
##   · 每图不同敌人 → MapData.enemy_pool，留空则用本文件的 enemy_pool
##   · 关卡演出     → MapData.bgm + _swap 前后的过场

# ───────────────────────────────────────────────────────────────────────────
#  ── 对外信号 ──
# ───────────────────────────────────────────────────────────────────────────
## 地图变了（选人完成进入第一张图、或 travel_to 换图时 emit）。
## ⚠ 目前**全项目没有任何地方 connect 它** —— 属于预留的扩展点
##   （以后做"地图名飘字幕 / BGM 切换 / 成就统计"就接这里）。
signal map_changed(map_id: String)

## 队伍成员发生变化（招募成功时 emit；以后做"队友离队/换人"也会 emit）。
## ⚠ 目前没人 connect 它 —— 地图面板的刷新是 GameRoot 主动调 WorldMap.notify_party_changed()
##   做到的（因为那个面板开着的时候才知道要刷）。这个信号留给"别的界面也要跟着变"的场景。
signal party_changed

# ───────────────────────────────────────────────────────────────────────────
#  ── 屏幕场景常量 ──
#  全部 preload：脚本加载时就解析好，换屏时只做 instantiate()，没有磁盘查找开销。
#  ⚠ preload 是编译期绑定：这些路径被改名/删除会直接报错，改文件名时必须同步改这里。
# ───────────────────────────────────────────────────────────────────────────
## 主菜单场景（TitleScreen）。
const TITLE_SCENE := preload("res://scenes/main/title_screen.tscn")
## 通用世界地图场景。某张地图若在 MapData.scene 里配了专用场景，则改用那个（见 show_map）。
const WORLD_MAP_SCENE := preload("res://scenes/world/world_map.tscn")
## 回合制战斗场景（Battle）。
const BATTLE_SCENE := preload("res://scenes/battle/battle.tscn")
## 竞技场场景（Arena，经典模式）。
const ARENA_SCENE := preload("res://scenes/arena/arena.tscn")
## 选人界面场景（SelectionPanel）。
const SELECTION_SCENE := preload("res://scenes/ui/selection_panel/selection_panel.tscn")
## 默认队长：主菜单「新的征程」**跳过选人界面**时直接用的 UnitStats。
## 换人只要改这一行（或是在 main.tscn 的检查器里填 default_leader 覆盖它）。
## ⚠ 用"敌人"资源当队长也是安全的（想快速测队伍/敌人数量时可以这么干）：
##   战斗走的是 Battle.start_battle(我方数组, 敌方数组) 显式传参，
##   UnitStats.type 只影响 Arena 那条老玩法，本项目里没有任何代码读它。
const DEFAULT_LEADER := preload("res://resources/units/players/stats_player_well_rounded.tres")
## 默认初始武器：跳过选武器界面时塞进 Global.equipped_weapons 的那一把。
## 取的是原来选人界面里的第一把（拳头），保证"直接开局"和"手选最左边那个"效果一致。
const DEFAULT_START_WEAPON := preload("res://resources/items/weapons/melee/punch/item_punch_1.tres")

# ───────────────────────────────────────────────────────────────────────────
#  ── 配置（在 main.tscn 的检视面板里填；改这些等于改关卡结构与难度曲线）──
# ───────────────────────────────────────────────────────────────────────────
## 地图顺序表。**数组顺序 = 关卡顺序**，map_difficulty() 就是靠下标算的，
## 所以调整顺序会连带改变难度与奖励，而不需要改任何代码。
@export var maps: Array[MapData] = []
## 起始地图 id。留空 = 用 maps[0].id（见 _first_map_id）。
@export var start_map_id := ""                 # 留空 = maps[0].id
## 全局敌人池。某张图没配 MapData.enemy_pool 时用这个（见 _make_enemy_team）。
@export var enemy_pool: Array[UnitStats] = []  # 某张图没配 enemy_pool 时用这个
## 每前进一张图，敌人血量/伤害 +15%（是**增量**不是倍率本身）。
## 默认 0.15：第 1 图 ×1.0、第 2 图 ×1.15、第 3 图 ×1.30、第 4 图 ×1.45 —— 缓坡式加压。
@export var enemy_scale_per_map := 0.15        # 每前进一张图，敌人血量/伤害 +15%
## 通关奖励公式的系数：奖励金币 = coin_reward_per_map × 地图序号（序号从 1 起算）。
## 默认 40：第 1 图 40、第 2 图 80、第 3 图 120、第 4 图 160 —— 越靠后越值得打。
@export var coin_reward_per_map := 40          # 通关奖励 = coin_reward_per_map * 地图序号
## 新开一局时的初始金币。默认 500（和 Global.coins 的默认值刻意保持一致，避免两处对不上）。
@export var starting_coins := 500
## 跳过选人界面时的队长（UnitStats）。**在 main.tscn 的检查器里填**；留空 = 用 DEFAULT_LEADER。
## 想临时试别的角色/敌人，填这里最省事（不用改代码、也不用改那句 preload）。
@export var default_leader: UnitStats
## 跳过选武器界面时的初始武器（ItemWeapon）。留空 = 用 DEFAULT_START_WEAPON。
@export var default_weapon: ItemWeapon

# ── 场景容器引用（% = main.tscn 里标记为 unique_name_in_owner 的节点）────────
## 世界类屏幕容器（Node2D）。WorldMap / Battle / Arena 都挂这里（受世界坐标与 y_sort 影响）。
@onready var world_root: Node2D = %WorldRoot
## UI 类屏幕容器（CanvasLayer）。TitleScreen / SelectionPanel 挂这里（不随相机移动）。
@onready var ui_root: CanvasLayer = %UIRoot
## 最上层黑幕（TransitionLayer 的 layer=200 之下的 ColorRect）。
## 只用它的 modulate.a 做淡入淡出：1.0 = 全黑、0.0 = 全透明。
@onready var fade: ColorRect = %Fade

# ───────────────────────────────────────────────────────────────────────────
#  ── 局内状态（活到下一次 start_new_game；换屏**不会**自动重置）──
# ───────────────────────────────────────────────────────────────────────────
## 玩家当前所在的地图 id。初值由 _ready() 里的 _first_map_id() 给出（maps 为空时是 ""）。
var current_map_id := ""
## **上阵**人数上限 = Battle 的 Stage/PlayerSlots 站位数量（前三后二，见 battle.tscn）。
## 超过这个数 Battle._spawn_team() 会 push_warning 并丢掉多出来的人，所以在这里先拦住
## （队伍管理面板里"上阵"按钮会置灰）。
## ⚠ 它**不是团队人数上限**：团队（大名单）可以有很多人，能上场的只有这么多。
const MAX_DEPLOYED := 5

## 团队（大名单）人数上限。0 = 不限。
## 留这个旋钮是为了以后想加"最多带 12 人"这类限制时有个统一的地方改；
## 默认不限，因为真正的限制在"上阵最多 5 人"上。
const MAX_TEAM_SIZE := 0

## 敌方队伍人数上限。= Battle 的 Stage/EnemySlots 站位数量（前三后二，见 battle.tscn），
## 再多就没有位置可站（Battle._spawn_team() 会 push_warning 并把多出来的人丢掉）。
## 实际数量由 _make_enemy_team() 决定：以**上阵人数**为基准 ±1，再钳进 [1, 本值]。
const MAX_ENEMY_COUNT := 5

## 团队（大名单）：第 0 位是队长，后面是招募来的队友。上限见 MAX_TEAM_SIZE（默认不限）。
## ⚠ 在团队里 ≠ 会出战：出战的是下面的 deployed（上阵名单）。队伍管理面板负责两件事的切换。
## ⚠ 这个数组是**引用语义**地传给 WorldMap 的（GDScript 的 Array 按引用传参），所以这里
##   append 之后，它手里的 _party 立刻就是同一份新数据 —— 需要刷新的只是界面文字。
##   ⚠ 也正因为是引用：**只能 clear()/append()/remove_at() 改内容，不要整个重新赋值** ——
##   整个换掉会让 WorldMap 手里的旧数组变成孤儿，界面从此不再跟着变。
var party: Array[UnitStats] = []

## 上阵名单（**最多 MAX_DEPLOYED = 5 人**）：真正进战斗的这几个人，必须是 party 的子集。
## 进战斗前会被 _make_player_team() 逐个 duplicate() 成副本，所以战斗中的掉血不会污染 .tres。
## 与 party 一样是引用语义交给 WorldMap 展示，所以也**不要整个重新赋值**。
var deployed: Array[UnitStats] = []
## 已通关地图集合：map_id -> true。用于地图名后缀"（已通关）"与将来"必须先打赢才能走"。
var cleared_maps: Dictionary = {}              # map_id -> true
## 是否正在战斗中。enter_battle() 置 true、_on_battle_ended() 置 false。
## ⚠ 目前没有任何地方读它 —— 属于预留状态位（存档 / 统计可以用）。
var in_battle := false

## 上一次战斗的结算文案（胜/负 + 奖励）。写：_on_battle_ended()；读：传给地图显示 + 主菜单副标题。
var _last_result := ""
## 每张地图"玩家离开时的归一化位置"：map_id -> Vector2。
## 写：_remember_position()（进战斗前 / 传送前）；读：show_map(restore_position = true)，
## 赋给 WorldMap.spawn_override，从而实现"打完战斗回到原地"。
var _map_positions: Dictionary = {}            # map_id -> 玩家离开时的归一化位置（战斗回来原地）


## 生命周期：设好初始状态，然后进主菜单。
## 参数：无。返回值：无（内含 await，是协程；await 之后本函数就结束了）。
## 副作用：
##   · fade.modulate.a = 1.0 —— 先把黑幕拉满，避免启动那一帧露出空场景（瞬时黑屏）；
##   · maps 为空时 push_warning（**不**中断，至少让玩家能看到主菜单并点退出）；
##   · 否则把 current_map_id 设成 _first_map_id()；
##   · await show_title()（会一直挂到玩家在主菜单做出选择之后）。
## 注意：后续流程完全由信号驱动（不是直线脚本），所以这里不需要"一直等下去"的循环 ——
##   玩家点「新的征程」后是 TitleScreen emit 信号 → start_new_game() 接管，与 _ready() 无关了。
func _ready() -> void:
	fade.modulate.a = 1.0
	if maps.is_empty():
		push_warning("GameRoot: maps 是空的 —— 在 main.tscn 的 Maps 数组里填地图资源")
	else:
		current_map_id = _first_map_id()
	await show_title()


# ══════════════════════════════════════════════════════════
#  地图数据
# ══════════════════════════════════════════════════════════

## 决定"从哪张图开始"。
## 参数：无。返回值：地图 id；maps 为空时返回空串 ""。
## 副作用：无（纯查询）。
## 优先级：start_map_id（且必须能在 maps 里查到）→ maps[0].id → ""。
## 为什么加 get_map(start_map_id) != null 这层校验：start_map_id 是手填字符串，
##   写错（或对应地图被删）不该让游戏起不来，静默回落到第一张更稳。
func _first_map_id() -> String:
	if not start_map_id.is_empty() and get_map(start_map_id) != null:
		return start_map_id
	if maps.is_empty():
		return ""
	return maps[0].id


## 按 id 查地图配置。
## 参数 map_id：目标地图的 MapData.id。
## 返回值：命中的 MapData；找不到返回 null。
## 副作用：无（线性遍历；地图只有个位数，不需要额外索引）。
## 说明：`if map != null` 是为了容忍 main.tscn 的 Maps 数组里留了空槽（未填的 .tres 元素）。
func get_map(map_id: String) -> MapData:
	for map in maps:
		if map != null and map.id == map_id:
			return map
	return null


## 查某张地图在 maps 数组里的下标（0 起算）。
## 参数 map_id：目标地图的 MapData.id。
## 返回值：下标；**找不到时返回 0**（刻意的：等于把它当成第一张图，
##   比返回 -1 更不容易让调用方算出负数难度或负数奖励）。
## 副作用：无。
func map_index(map_id: String) -> int:
	for i in maps.size():
		if maps[i] != null and maps[i].id == map_id:
			return i
	return 0


## 当前地图的难度档（第 1 张 = 1）
## 参数：无（读 current_map_id）。返回值：难度档，1 起算（= 下标 + 1）。
## 副作用：无。
## 两个消费方：_on_battle_ended()（奖励 = coin_reward_per_map × 本值）、
##   _make_enemy_team()（**只用来缩放敌人的血量/伤害**；敌人数量现在按我方队伍人数算，与本档无关）。
func map_difficulty() -> int:
	return map_index(current_map_id) + 1


# ══════════════════════════════════════════════════════════
#  屏幕切换（带淡入淡出）
# ══════════════════════════════════════════════════════════

## 清空所有屏幕（两个容器一起清）。
## 参数：无。返回值：无。
## 副作用：对 world_root 和 ui_root 的每个子节点执行 remove_child + queue_free。
## 为什么用"两步"（先 remove_child 再 queue_free）：
##   queue_free() 只是"排到帧末释放"，调用之后节点仍挂在父节点上，同帧内 get_children()
##   还会拿到它们（还占布局、还能收输入）。先 remove_child 让它们立刻离树、不再渲染/响应输入，
##   queue_free 负责真正回收。
## 注意：
##   · `for parent in [world_root, ui_root]` 是数组字面量迭代 —— 两个容器**一起清**，
##     所以本项目的约定是"任何时刻只有一个屏幕存活"，别指望 UI 与世界同时留在树里；
##   · 运行时 add_child 进来的屏幕 owner 为 null，所以这里写 child.queue_free()（正确）；
##     写成 child.owner.queue_free() 会因为 owner 是 null 直接失败。
func _clear_screens() -> void:
	for parent in [world_root, ui_root]:
		for child in parent.get_children():
			parent.remove_child(child)
			child.queue_free()


## 换屏：淡出 → 清空旧屏幕 → 挂新屏幕 → 淡入。
## 参数 screen：要挂上去的场景实例；parent：挂到哪个容器（传 null 表示 ui_root）。
## 返回值：无（协程：两个 await 都被等待，所以整个过场演完才返回）。
## 副作用：两次黑幕补间、清空两个容器的子节点、把 screen 挂到 target 下。
## 为什么写 `parent if parent != null else ui_root`：
##   GDScript 的默认参数不能用另一个成员变量（@onready 变量此刻还没赋值），
##   所以约定"传 null 就走 UI 容器"，于是调用处能写 _swap(screen) 或 _swap(screen, world_root)。
## 顺序讲究：必须先 await fade_out()（屏幕全黑）再 _clear_screens()，
##   否则玩家会看见旧屏幕被瞬间抽走、新屏幕突然出现的"闪跳"。
func _swap(screen: Node, parent: Node = null) -> void:
	var target: Node = parent if parent != null else ui_root
	await fade_out()
	_clear_screens()
	target.add_child(screen)
	await fade_in()


## 黑幕淡出（画面变全黑）。
## 参数 duration：时长（秒），默认 0.3（无类型标注 = 推断为 float）。
## 返回值：无（协程：await tween.finished，所以调用方 await 它会等动画真的结束）。
## 副作用：
##   · fade.mouse_filter = STOP —— 在"变黑途中"就吞掉鼠标事件，
##     防止玩家在黑屏期间点到即将被清掉的旧界面按钮；
##   · 创建 tween 把 fade.modulate:a 补间到 1.0。
## 说明：create_tween() 创建的 tween 绑定在本节点（GameRoot 永不销毁），所以不存在
##   "tween 目标被 free 掉"的问题 —— 这也是过场动画放在 GameRoot 而不是屏幕内部的原因之一。
func fade_out(duration := 0.3) -> void:
	fade.mouse_filter = Control.MOUSE_FILTER_STOP
	var tween := create_tween()
	tween.tween_property(fade, "modulate:a", 1.0, duration)
	await tween.finished


## 黑幕淡入（画面恢复可见）。
## 参数 duration：时长（秒），默认 0.3。
## 返回值：无（协程：await tween.finished）。
## 副作用：创建 tween 把 fade.modulate:a 补间到 0.0；动画结束后把 fade.mouse_filter 设回 IGNORE。
## 注意 set 的时机：MOUSE_FILTER_IGNORE 是在 **await 之后**才赋值的 ——
##   这正是"等黑幕真的透明了才放行输入"的实现；若写在 tween 之前，
##   黑幕还没淡出玩家就能点到新屏幕的按钮（过场就没意义了）。
func fade_in(duration := 0.3) -> void:
	var tween := create_tween()
	tween.tween_property(fade, "modulate:a", 0.0, duration)
	await tween.finished
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE


# ══════════════════════════════════════════════════════════
#  流程各站
# ══════════════════════════════════════════════════════════

## 显示主菜单（游戏启动后的第一屏，也是「返回主菜单」的目的地）。
## 参数：无。返回值：无（协程：await _swap(screen)，等过场演完）。
## 副作用：
##   · 实例化 TitleScreen 并把 _last_result 写进它的 last_result（**必须在 add_child 之前**，
##     因为 TitleScreen._ready() 会立刻读它显示副标题；_swap 内部才 add_child）；
##   · connect 三条信号：new_game_requested → start_new_game、
##     arena_requested → enter_arena、quit_requested → 一个直接调 get_tree().quit() 的 lambda；
##   · await _swap(screen)（默认挂到 ui_root）。
## 关于那个 lambda：信号是"无参"的，而 get_tree().quit() 需要 scene tree，
##   所以用匿名函数包一层（函数引用也能连，但这里要传调用结果所以必须包）。
##   该 Callable 挂在 screen 上，screen 被清掉时连接一起消失，不会泄漏。
func show_title() -> void:
	var screen := TITLE_SCENE.instantiate() as TitleScreen
	screen.last_result = _last_result
	screen.new_game_requested.connect(start_new_game)
	screen.arena_requested.connect(enter_arena)
	screen.quit_requested.connect(func() -> void: get_tree().quit())
	await _swap(screen)


## 开始一局新游戏：把所有**局内状态**清干净，然后用默认队长直接开局。
## 参数：无。返回值：无（本身不含 await；末尾的 start_game_with_defaults() 没被 await）。
## 副作用（这份清单就是"新档重置"的完整定义）：
##   · party / cleared_maps / _map_positions / _last_result 清空；
##   · current_map_id 回到 _first_map_id()；
##   · Global.coins = starting_coins（**唯一的金币重置点**）；
##   · Global.equipped_weapons.clear()（否则上一局的装备会带进新档）；
##   · Global.main_player_selected / main_weapon_selected 置 null（清掉上次选人结果）；
##   · 调用 start_game_with_defaults()（**跳过选人界面**，直接按 default_leader 开局）。
## ⚠ 注意它**没有清 Global.player**：那个字段仍指向上一次造出来的旧节点
##   （可能已被回收）。这正是项目里到处写 is_instance_valid(Global.player) 的原因，
##   以后加"存档/重开"时要把这一项也补上。
## 为什么这些状态由 GameRoot 清而不是 Global 自己清：Global 是 autoload，跨屏存活，
##   它只知道"当前值"，不知道"什么时候算新的一局" —— 那个时机只有 GameRoot 懂。
func start_new_game() -> void:
	party.clear()
	deployed.clear()
	cleared_maps.clear()
	_map_positions.clear()
	_last_result = ""
	current_map_id = _first_map_id()
	Global.coins = starting_coins
	Global.equipped_weapons.clear()
	Global.main_player_selected = null
	Global.main_weapon_selected = null
	start_game_with_defaults()


## 用"默认队长 + 默认武器"直接开局（不经过选人/选武器界面）。
## 参数：无（读 default_leader / default_weapon，留空则回落到本文件顶部的两个 preload 常量）。
## 返回值：无（不含 await；末尾 _on_selection_completed() 未被 await）。
## 副作用：写 Global.main_player_selected / Global.main_weapon_selected，然后复用 _on_selection_completed()
##   —— 组队、初始武器入包、emit map_changed、进第一张地图这四件事都只写在那一个地方，
##   所以"跳过选人"和"手选角色"走的是同一段收尾逻辑，不会出现两套行为不一致。
## 想换回选人界面：把 start_new_game() 末尾的调用换成 show_character_select() 即可。
func start_game_with_defaults() -> void:
	var leader := default_leader if default_leader != null else DEFAULT_LEADER
	if leader == null:
		push_warning("GameRoot: 没有配置默认队长（default_leader / DEFAULT_LEADER），无法直接开局")
		return
	Global.main_player_selected = leader
	Global.main_weapon_selected = default_weapon if default_weapon != null else DEFAULT_START_WEAPON
	_on_selection_completed()


## 显示选人界面（SelectionPanel）。
## ⚠ 当前**不在主流程里**：主菜单「新的征程」走的是 start_game_with_defaults()。
##   想恢复"选人 → 选武器"的老流程，只要把 start_new_game() 末尾那一行换回本函数即可。
## 参数：无。返回值：无（协程：await _swap(panel)）。
## 副作用：实例化 SelectionPanel、把它的 on_selection_completed 连到本文件的
##   _on_selection_completed、await _swap(panel)（挂到 ui_root），并等过场结束。
## 说明：连的是"面板自己"的信号（面板内部管玩家/武器的挑选），GameRoot 只关心"选完了"。
func show_character_select() -> void:
	var panel := SELECTION_SCENE.instantiate() as SelectionPanel
	panel.on_selection_completed.connect(_on_selection_completed)
	await _swap(panel)


## 队长/武器确定 → 组成队伍、准备初始武器，进入第一张地图。
## 谁调它：两条路都汇到这里 ——
##   · start_game_with_defaults()（**当前主流程**：跳过选人界面，直接用默认队长+默认武器）；
##   · SelectionPanel 的 on_selection_completed（老流程，面板还留着，见 show_character_select()）。
## 参数：无（队长与武器在 Global.main_player_selected / main_weapon_selected 里）。
## 返回值：无（不含 await；末尾 show_map() 未被 await）。
## 副作用：
##   · Global.main_player_selected 为 null 时警告并**直接 return**（不往下走，避免用 null 组队）；
##   · party = [队长]（团队名册，第 0 位永远是队长）、deployed = [队长]（队长默认上阵）；
##     招募来的队友会在之后由 add_party_member() 追加，上阵/下阵由队伍管理面板切换；
##   · Global.equipped_weapons.clear() 后把初始武器 append 进去
##     （清一次是为了防止"重复开局"导致武器翻倍）；
##   · emit map_changed(current_map_id)（当前无人接听，属于预留）；
##   · 调 show_map() 进入第一张图。
## 注意 party 里放的是**资源引用**（不是节点）：战斗前 _make_player_team() 会 duplicate() 成副本，
##   所以战斗中的掉血不会污染 .tres。
func _on_selection_completed() -> void:
	if Global.main_player_selected == null:
		push_warning("GameRoot: 还没选角色")
		return
	# 用 clear()+append() 而不是 `party = [...]`：数组是"引用语义"交给 WorldMap 的，
	# 整个重新赋值会让地图手里的旧数组变孤儿，界面从此不再跟着变（见 party 字段的注释）。
	party.clear()
	party.append(Global.main_player_selected)
	# 队长默认上阵：开局只有他一个人，如果不上阵就会连战斗都进不去。
	deployed.clear()
	deployed.append(Global.main_player_selected)
	Global.equipped_weapons.clear()
	if Global.main_weapon_selected != null:
		Global.equipped_weapons.append(Global.main_weapon_selected)
	map_changed.emit(current_map_id)
	show_map()


## 显示世界地图（换图、从战斗回来、或开局选完人都走这里）。
## 参数：
##   result_text      —— 顶部要飘的结算文案（默认空串 = 不飘）。
##   from_map_id      —— "从哪张图传过来的"，交给 WorldMap 决定出生点（默认空 = 用地图自带出生点）。
##   restore_position —— 是否使用 _map_positions 里记录的位置（打完战斗回地图时为 true）。
## 返回值：无（协程：await _swap(world, world_root)）。
## 副作用：
##   · 找不到地图时警告 + await show_title() 退回主菜单（避免黑屏卡死）；
##   · 可能实例化 MapData.scene 指定的**专用场景**（而不是通用 world_map.tscn）；
##   · 给 world.spawn_override 赋值（必须在 add_child 之前 —— WorldMap._ready() 会立刻读它）；
##   · 给 world.deployed 赋值（上阵名单，同样是"add_child 之前的注入"，用于队伍管理面板显示状态）；
##   · 调 world.setup(...)（同样必须在 add_child 之前，见 WorldMap.setup 的注释）；
##   · connect 七条信号：battle_requested → enter_battle、travel_requested → travel_to、
##     back_to_title_requested → show_title、recruit_requested → _on_recruit_requested、
##     party_remove_requested → _on_party_remove_requested、
##     party_deploy_requested → _on_party_deploy_requested、
##     party_undeploy_requested → _on_party_undeploy_requested；
##   · await _swap(world, world_root) —— 世界类屏幕挂到 **world_root**（不是 ui_root）。
## 细节：
##   · 连接在 add_child **之前**完成，这样屏幕一进树（甚至 _ready 里就 emit）也不会漏事件；
##   · `packed.instantiate() as WorldMap`：如果专用场景的根节点没挂 WorldMap（或其子类）脚本，
##     这里会得到 null，紧接着 world.spawn_override 就会报错 —— 做专用场景时必须"新建继承场景"；
##   · 传的是 Global.coins 的**当前快照**，所以地图上的金币数只反映进入那一刻的余额。
func show_map(result_text := "", from_map_id := "", restore_position := false) -> void:
	var map := get_map(current_map_id)
	if map == null:
		push_warning("GameRoot: 找不到地图 %s" % current_map_id)
		await show_title()
		return

	# 这张图配了专用场景就用它（继承自 world_map.tscn），否则用通用的
	var packed: PackedScene = map.scene if map.scene != null else WORLD_MAP_SCENE
	var world := packed.instantiate() as WorldMap
	if restore_position and _map_positions.has(map.id):
		world.spawn_override = _map_positions[map.id]     # 打完战斗回到原地
	world.deployed = deployed      # 上阵名单（引用语义；队伍管理面板要按它显示"上阵/下阵"）
	world.setup(map, party, Global.coins, result_text, cleared_maps.has(map.id), _map_names(), from_map_id)
	world.battle_requested.connect(enter_battle)
	world.travel_requested.connect(travel_to)
	world.back_to_title_requested.connect(show_title)
	world.recruit_requested.connect(_on_recruit_requested)
	world.party_deploy_requested.connect(_on_party_deploy_requested)
	world.party_undeploy_requested.connect(_on_party_undeploy_requested)
	world.party_remove_requested.connect(_on_party_remove_requested)
	await _swap(world, world_root)


## 前往另一张地图（地图里跟 NPC 对话选目的地，最终走到这里）
## 参数 next_id：目标地图 id（来自 WorldMap.travel_requested，实际是 MapNPC.destinations 里的值）。
## 返回值：无（本身不含 await；末尾的 show_map() 未被 await，过场在后台继续）。
## 副作用：
##   · 目标不存在时警告并 return（不换图）；
##   · _remember_position() 把"当前这张图站的位置"记下来（⚠ 必须在改 current_map_id **之前**
##     调用，否则记的会变成目标图的 key）；
##   · 改 current_map_id、emit map_changed、调 show_map(...)。
## 为什么传 from_id 给 show_map：WorldMap 会优先把玩家放在"目标图里指向 from_id 的那个 NPC"
##   旁边（双向传送不迷路），这就是 from_map_id 参数的唯一用途。
## 注意：这里调 show_map() 时没有 await —— 它会执行到第一个 await（fade_out 里的 await）时
##   把控制权交还，剩下的过场在后台跑完。这是有意的（信号回调不该被过场阻塞），
##   但也意味着 travel_to 之后的代码不能假设"图已经换好了"。
func travel_to(next_id: String) -> void:
	var next := get_map(next_id)
	if next == null:
		push_warning("GameRoot: 没有这张地图 -> %s" % next_id)
		return
	# TODO: 想"必须先打赢才能走"就在这里判断 cleared_maps.has(current_map_id)
	_remember_position()
	var from_id := current_map_id
	current_map_id = next.id
	map_changed.emit(current_map_id)
	show_map("抵达 %s" % next.display_name, from_id)


## 构造 map_id → 地图显示名 的字典，交给 WorldMap 把目的地 id 翻成中文按钮文字。
## 参数：无。返回值：{地图id: display_name} 的新字典。
## 副作用：无（每次调用都新建字典；地图只有个位数，开销可忽略）。
## 说明：用 `var names := {}` 推断成弱类型 Dictionary —— 因为它是"临时查表"，
##   不需要 Dictionary[String, String] 那层类型约束。
func _map_names() -> Dictionary:
	var names := {}
	for map in maps:
		if map != null:
			names[map.id] = map.display_name
	return names


## 取当前挂在 world_root 下的世界地图节点（用来问它"玩家站在哪"）。
## 参数：无。返回值：WorldMap 实例；没有则 null。
## 副作用：无（只遍历子节点）。
## 为什么用 `is WorldMap` 而不是记成员变量：世界类屏幕也可能被换成 Battle/Arena，
##   而 GameRoot 不保存世界地图引用（避免野引用）。这里按类型找一次最省心，
##   world_root 的子节点最多一个。
func _current_world_map() -> WorldMap:
	for child in world_root.get_children():
		if child is WorldMap:
			return child
	return null


## 记住玩家在这张图站的位置（传送前 / 进战斗前调用）
## 参数：无。返回值：无。
## 副作用：写 _map_positions[current_map_id] = world.player_normalized()
##   （归一化坐标，不是像素 —— 这样即使换了贴图尺寸也还有大致意义）。
## 说明：当前不在世界地图（例如在竞技场）时 _current_world_map() 返回 null，
##   此时直接跳过 —— 于是 _map_positions 里保留的是**上一次**在这张图的位置，
##   对"回地图"来说这恰好是想要的行为。
func _remember_position() -> void:
	var world := _current_world_map()
	if world != null:
		_map_positions[current_map_id] = world.player_normalized()


## 进入回合制战斗（WorldMap 的「进入战斗」按钮 → battle_requested → 本函数）。
## 参数：无（敌方队伍由 _make_enemy_team() 现算）。
## 返回值：无（协程：await _swap(battle, world_root)）。
## 副作用：
##   · 上阵名单为空时警告 + show_map() 退回地图（不空手进战斗）；
##   · _remember_position() —— 记下位置，打完回来还站这儿；
##   · 敌人池为空时警告并 return（防止进一场没有敌人的战斗）；
##   · 实例化 Battle、把 auto_start_demo 设 false、connect battle_ended、
##     in_battle = true、await _swap(battle, world_root)，最后调 battle.start_battle(我方, 敌方)。
## 三处顺序讲究（每一条都不能挪）：
##   1. `battle.auto_start_demo = false` **必须在 add_child 之前**：
##      Battle 的这个字段默认是 true（为"编辑器里单独运行本场景时自动开打"准备的），
##      而 Battle._ready() 会读它并自己 start_battle() —— 如果 add_child 之后才改，
##      战斗已经用 DEMO 队伍开打了，真正的 start_battle() 会撞车；
##   2. `battle.battle_ended.connect(...)` 也要在 add_child 之前：战斗可能在 _ready 阶段
##      就结束（理论上），先连上才不会漏掉结束事件；
##   3. `battle.start_battle(...)` 放在 `await _swap(...)` **之后**：
##      等淡入完成、战斗真正可见了再开打，否则玩家会在黑屏期间错过开场。
## 另外：start_battle 内部有 await（整个战斗流程），这里**不 await 它**——
##   不然 enter_battle 会一直挂到战斗结束；战斗结束走的是 battle_ended 信号回调。
func enter_battle() -> void:
	if deployed.is_empty():
		push_warning("GameRoot: 没有上阵的队员（去队伍管理里上阵，或先招募队友）")
		show_map()
		return
	_remember_position()                    # 打完回来还站在这儿
	var enemies := _make_enemy_team()
	if enemies.is_empty():
		push_warning("GameRoot: 敌人池是空的 —— 给地图资源或 GameRoot.enemy_pool 填敌人")
		return

	var battle := BATTLE_SCENE.instantiate() as Battle
	battle.auto_start_demo = false          # ★ 必须在 add_child 之前
	battle.battle_ended.connect(_on_battle_ended)
	in_battle = true
	await _swap(battle, world_root)
	battle.start_battle(_make_player_team(), enemies)


## 进入竞技场（主菜单「经典模式」→ arena_requested → 本函数）。
## 参数：无。返回值：无（协程：await _swap(arena, world_root)）。
## 副作用：实例化 Arena 并挂到 world_root 下。
## 说明：
##   · 竞技场是"自成一体的玩法"（内置 SelectionPanel / 波次 / 商店），
##     所以这里**不需要**先清 Global 状态、也不需要 party —— 它自己走选人流程
##     （只有 Arena 会调 Global.get_selected_player() 造玩家）；
##   · `var arena := ARENA_SCENE.instantiate()` 故意没标类型（原写法）：
##     它只用来传给 _swap，不需要访问 Arena 的任何成员；
##   · 注意它**不**重置 Global.coins / equipped_weapons —— 竞技场和地图线共用同一个金币数。
func enter_arena() -> void:
	# 保留原来自成一体的竞技场模式（内置选人/波次/商店）
	var arena := ARENA_SCENE.instantiate()
	await _swap(arena, world_root)


# ══════════════════════════════════════════════════════════
#  战斗结算
# ══════════════════════════════════════════════════════════

## 战斗结束回调（Battle 的 battle_ended 信号 → 本函数）。
## 参数 player_won：true = 我方胜利（Battle._finish_battle() 判定后 emit）。
## 返回值：无（不含 await；末尾 show_map() 未被 await）。
## 副作用：
##   · in_battle = false；
##   · 胜利时：cleared_maps[本图 id] = true（**通关记录，唯一写入点**）、
##     Global.coins += coin_reward_per_map * map_difficulty()、写 _last_result 文案；
##   · 失败时：只写 _last_result（不记通关、不发奖励，可以原地再挑战）；
##   · show_map(_last_result, "", true) —— 回到地图，restore_position = true
##     于是 GameRoot 用 _map_positions 把玩家放回"进战斗前站的地方"。
## 细节：
##   · `map.id if map != null else current_map_id` 和 map_name 那行都是同一套兜底写法：
##     地图可能在运行期被删（改了 main.tscn 的 Maps），用 id/current_map_id 兜住不崩；
##   · 这里**不直接**清掉战斗屏幕：show_map() → _swap() 会先 await fade_out()（0.3 秒），
##     所以真正的 _clear_screens()（会把 Battle 释放掉）发生在信号 emit 返回之后 ——
##     也就是说不会出现"在 Battle 自己的信号回调里把它 free 掉"那种危险时序；
##   · 奖励公式只加金币，经验 / 掉落 / 战后商店都还没接（见下面那条 TODO）。
## 注意：Battle 侧对 battle_ended 做了"只发一次"的保护，所以这里不会被重复调用、
##   奖励也不会发两份。
func _on_battle_ended(player_won: bool) -> void:
	in_battle = false
	var map := get_map(current_map_id)
	var map_name := map.display_name if map != null else current_map_id

	if player_won:
		cleared_maps[map.id if map != null else current_map_id] = true
		var reward := coin_reward_per_map * map_difficulty()
		Global.coins += reward
		_last_result = "%s：战斗胜利！获得 %d 金币" % [map_name, reward]
		# TODO: 经验 / 掉落 / 战后商店接这里
	else:
		_last_result = "%s：战斗失败…（可以再挑战一次）" % map_name
	show_map(_last_result, "", true)         # 回到地图上原来的位置


# ══════════════════════════════════════════════════════════
#  队伍生成
# ══════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════
#  团队（party）与上阵名单（deployed）
# ═══════════════════════════════════════════════════════════════════════════
#  这里是队伍**唯一**的写入点。地图上的招募按钮与队伍管理面板都只 emit 请求信号
#  （recruit_requested / party_deploy_requested / party_undeploy_requested / party_remove_requested），
#  能不能加、能不能上阵，一律由下面这几个函数决定 —— 规则只有一份，
#  面板只负责显示"同一套规则算出来的结果"，不会出现"按钮能点但点完没反应"。
#
#  两层结构（这是本段的核心概念）：
#    · party      —— **团队（大名单）**：招到的人都在这里，人数上限见 MAX_TEAM_SIZE（默认不限）；
#    · deployed   —— **上阵名单**：真正进战斗的那几个人，最多 MAX_DEPLOYED = 5 人，
#                    且必须是 party 的子集（移出团队会自动把人从上阵名单里摘掉）。
#  两者都是"资源引用"数组（Array[UnitStats]，不是节点、不是副本）：
#    · 数组实例被引用语义地传给 WorldMap，append 后它立刻看得到（界面文字需要另行刷新）；
#    · 战斗前 _make_player_team() 才逐项 duplicate()，所以打到一半掉血不会改到 .tres。
#    ⚠ 正因为是引用语义：这两个数组**只能就地增删，不要整个重新赋值**。

## 队伍里非 null 的成员数。party 允许留空位（见 _make_enemy_team 的注释），所以不能用 size()。
## 做成静态函数的原因：WorldMap 手里也有同一份数组，画招募按钮要按**同样的规则**判断按钮灰不灰，
## 静态函数让两边共用一份判定，避免出现"面板说能加、点下去却加不进去"。
static func party_count(p_party: Array[UnitStats]) -> int:
	var n := 0
	for stats in p_party:
		if stats != null:
			n += 1
	return n


## p_party 里是否已经有这个角色。
## 判定顺序：引用 → resource_path → name。
##   · 先比引用是最快的路径（同一个 .tres 只会加载出一个实例）；
##   · 再比 resource_path，对付"同一份资源被两条路径各加载一次"的情况（例如显式 recruit_pool 与目录扫描）；
##   · 最后比 name —— 名字是 Global.available_players 的键（名字相同即同一角色），兜底安全。
static func party_has(p_party: Array[UnitStats], stats: UnitStats) -> bool:
	if stats == null:
		return false
	for member in p_party:
		if member == null:
			continue
		if member == stats:
			return true
		if not member.resource_path.is_empty() and member.resource_path == stats.resource_path:
			return true
		if member.name == stats.name:
			return true
	return false


## 这个角色现在能不能**加入团队**（去重 + 团队人数上限）。
## 参数 max_size：覆盖上限；-1（默认）= 用 MAX_TEAM_SIZE，而 MAX_TEAM_SIZE = 0 表示不限人数。
## ⚠ 这里**不**看上阵人数 —— 上阵有自己的一套规则（deploy_can_add / deploy_can_remove）。
## 做成静态函数是因为 WorldMap 手里也有同一份数组，画招募按钮要用**同样的规则**判断灰不灰。
static func party_can_join(p_party: Array[UnitStats], stats: UnitStats, max_size := -1) -> bool:
	if stats == null:
		return false
	var limit := max_size if max_size >= 0 else MAX_TEAM_SIZE
	if limit > 0 and party_count(p_party) >= limit:
		return false
	return not party_has(p_party, stats)


## 上阵名单里有几个人。
## 语义上与 party_count() 完全一样（都是"非 null 元素个数"），单独包一层是为了让调用处
## 读起来是"上阵几人"而不是"数组里有几个"，不容易和团队人数看混。
static func deployed_count(p_deployed: Array[UnitStats]) -> int:
	return party_count(p_deployed)


## 这个人现在是不是在上阵名单里。
static func is_deployed(p_deployed: Array[UnitStats], stats: UnitStats) -> bool:
	return party_has(p_deployed, stats)


## 这个人现在能不能上阵：没在上阵名单里，且上阵位没满。
static func deploy_can_add(p_deployed: Array[UnitStats], stats: UnitStats) -> bool:
	if stats == null:
		return false
	if party_count(p_deployed) >= MAX_DEPLOYED:
		return false
	return not party_has(p_deployed, stats)


## 这个人现在能不能下阵：确实在上阵名单里，且下阵之后还剩至少 1 人。
## "至少留 1 人上阵"是硬约束：一个上阵的人都没有就进不了战斗（enter_battle 会拦），
## 与其让玩家点出一个空阵容，不如把按钮置灰并写明原因（见 PartyPanel._make_member_row）。
static func deploy_can_remove(p_deployed: Array[UnitStats], stats: UnitStats) -> bool:
	if stats == null or not party_has(p_deployed, stats):
		return false
	return party_count(p_deployed) > 1


## 队伍成员名列表（给 UI 拼文字用；跳过空位）。
## 返回 PackedStringArray 而不是 Array[String]：Godot 的 String.join() 只收 PackedStringArray，
## 这样调用方可以直接 "、".join(GameRoot.party_names_of(party))，不必再转一次。
static func party_names_of(p_party: Array[UnitStats]) -> PackedStringArray:
	var names := PackedStringArray()
	for stats in p_party:
		if stats != null:
			names.append(stats.name)
	return names


## 把队友招进**团队（大名单）**。返回值：true = 加进去了；false = 没加（团队满 / 已在团队里 / 传了 null）。
## 副作用：就地 append 到 party（引用语义，WorldMap 同步看到）；
##        **有空的上阵位时顺手把他上阵**；emit party_changed。
## 为什么顺手自动上阵：招募的直觉是"这人来跟我一起打"。上阵位满了就只进名册，
##   队伍管理面板里会显示"待上阵"，玩家自己去决定换谁下来。
## 注意：本函数**不**负责刷新界面 —— 界面由调用方（_on_recruit_requested 等）去通知 WorldMap，
##   因为"要不要弹提示"是界面的事，不是队伍数据的事。
func add_party_member(stats: UnitStats) -> bool:
	if not party_can_join(party, stats):
		return false
	party.append(stats)
	if deploy_can_add(deployed, stats):
		deployed.append(stats)
	party_changed.emit()
	return true


## 把队友移出**团队**。返回值：true = 移掉了；false = 不在团队里 / 想移的是队长 / 传了 null。
## 队长（下标 0）不允许移除 —— 移除队长会让整局没有稳定的大名单首位，属于数据损坏而非法操作。
## 副作用：party.remove_at() + **同时从上阵名单里摘掉**（移出团队的人当然不能再上阵）+ emit party_changed。
func remove_party_member(stats: UnitStats) -> bool:
	if stats == null:
		return false
	for i in party.size():
		var member := party[i]
		if member == null:
			continue
		if member == stats or member.name == stats.name:
			if i == 0:
				push_warning("GameRoot: 队长不能移出团队")
				return false
			party.remove_at(i)
			_undeploy_silently(member)
			party_changed.emit()
			return true
	return false


## 让某个队员**上阵**。返回值：true = 成功；false = 没成（不在团队 / 已上阵 / 上阵位已满）。
## 副作用：deployed.append() + emit party_changed。
## 上阵位满时**不**自动踢人下来：换谁下来是玩家的决定，不是代码的（面板会把按钮置灰并写明原因）。
func deploy_member(stats: UnitStats) -> bool:
	if not party_has(party, stats):
		return false
	if not deploy_can_add(deployed, stats):
		return false
	deployed.append(stats)
	party_changed.emit()
	return true


## 让某个队员**下阵**。返回值：true = 成功；false = 没成（不在上阵名单 / 只剩他一个）。
## 副作用：从 deployed 里摘掉 + emit party_changed。
func undeploy_member(stats: UnitStats) -> bool:
	if not deploy_can_remove(deployed, stats):
		return false
	_undeploy_silently(stats)
	party_changed.emit()
	return true


## 把某人从 deployed 里摘掉：不检查规则、不发信号（内部工具）。
## 为什么要单独一个"不检查"的版本：remove_party_member() 里那人**可能正被下阵规则保护**
##   （例如上阵只剩他一个时 deploy_can_remove() 会返回 false），但"被移出团队"必须无条件生效。
func _undeploy_silently(stats: UnitStats) -> void:
	if stats == null:
		return
	for i in deployed.size():
		var member := deployed[i]
		if member != null and (member == stats or member.name == stats.name):
			deployed.remove_at(i)
			return


## 世界地图的招募按钮回调（WorldMap.recruit_requested → 这里）。
## 参数 stats：玩家点了「加入」的那个角色（UnitStats 资源，由 WorldMap 从面板按钮 bind 过来）。
## 副作用：
##   · 成功后 add_party_member()（进名册 + 有空位就上阵 + emit party_changed），再让地图面板把台词
##     换成"XXX 加入了团队！"（并注明是已上阵还是待上阵），按钮重建后那个人会变成灰的"已在团队"；
##   · 失败时不改任何状态，只把原因写回面板台词（"已经在团队里了" / "团队已经满了"）。
## 注意：_current_world_map() 可能返回 null（理论上进战斗时不会有招募面板，但别假设），
##   所以下面所有对 world 的访问都判了 null。
func _on_recruit_requested(stats: UnitStats) -> void:
	var world := _current_world_map()
	if not party_can_join(party, stats):
		var why := "团队已经满了（上限 %d 人）。" % MAX_TEAM_SIZE
		if stats != null and party_has(party, stats):
			why = "%s 已经在团队里了。" % stats.name
		if world != null:
			world.notify_party_changed(why)
		return
	add_party_member(stats)
	var tail := "（已上阵）" if is_deployed(deployed, stats) else "（先进名册，上阵位已满）"
	if world != null:
		world.notify_party_changed("%s 加入了团队！%s" % [stats.name, tail])


## 队伍管理面板里点了「上阵」（WorldMap.party_deploy_requested → 这里）。
## 参数 stats：要上阵的成员。
## 副作用：成功后 deploy_member()（改 deployed + emit party_changed），再让面板刷新成"XXX 已上阵。"；
##        失败时只把原因写回面板（"上阵位已经满了" / "不在团队里"）。
func _on_party_deploy_requested(stats: UnitStats) -> void:
	var world := _current_world_map()
	if not deploy_member(stats):
		var why := "上阵位已经满了（%d 人），先让一个下阵。" % MAX_DEPLOYED
		if stats != null and not party_has(party, stats):
			why = "%s 不在团队里。" % stats.name
		elif stats != null and is_deployed(deployed, stats):
			why = "%s 已经在上阵名单里了。" % stats.name
		if world != null:
			world.notify_party_changed(why)
		return
	if world != null:
		world.notify_party_changed("%s 已上阵。" % stats.name)


## 队伍管理面板里点了「下阵」（WorldMap.party_undeploy_requested → 这里）。
## 参数 stats：要下阵的成员。
## 副作用：成功后 undeploy_member()（改 deployed + emit party_changed），面板刷新成"XXX 已下阵。"；
##        失败时只把原因写回面板（"至少要留 1 人上阵" / "本来就没上阵"）。
func _on_party_undeploy_requested(stats: UnitStats) -> void:
	var world := _current_world_map()
	if not undeploy_member(stats):
		var why := "至少要留 1 人上阵。"
		if stats != null and not is_deployed(deployed, stats):
			why = "%s 本来就没在上阵名单里。" % stats.name
		if world != null:
			world.notify_party_changed(why)
		return
	if world != null:
		world.notify_party_changed("%s 已下阵。" % stats.name)


## 队伍管理面板里点了「移出团队」（WorldMap.party_remove_requested → 这里）。
## 参数 stats：要移出的成员（UnitStats 资源，由 WorldMap 从面板按钮 bind 过来）。
## 副作用：
##   · 成功后 remove_party_member()（出团队 + 顺带从 deployed 摘掉 + emit party_changed），
##     再让地图那边把提示写成"XXX 已离开团队。"（面板会重建成只剩剩下的人）；
##   · 失败时不改任何状态，只把原因写回去（"队长不能移出团队。"）。
## 注意：移出**不用**关面板 —— 玩家通常想连着踢几个 / 看着列表变化。
##   这与"招募"一样，界面刷新交给 WorldMap.notify_party_changed()。
func _on_party_remove_requested(stats: UnitStats) -> void:
	var world := _current_world_map()
	if not remove_party_member(stats):
		var why := "这个成员不在团队里。"
		if stats != null and not party.is_empty() and party[0] == stats:
			why = "队长不能移出团队。"
		if world != null:
			world.notify_party_changed(why)
		return
	if world != null:
		world.notify_party_changed("%s 已离开团队。" % stats.name)


## 把**上阵名单**（deployed）变成一份**可以随便改**的我方队伍，交给 Battle。
## 参数：无（读成员 deployed）。
## 返回值：新的 Array[UnitStats]，长度 = deployed 里非 null 的元素个数（最多 MAX_DEPLOYED = 5）。
## 副作用：无（不写 Global、不改 deployed 里的原资源 —— 这正是本函数存在的意义）。
## ⚠ 用的是 deployed 而**不是** party：团队名册可以有很多人，但只有上阵的那几个进战斗。
## 为什么要 duplicate()：
##   UnitStats 是 Resource（引用语义），战斗会改血量/蓝量等字段。如果直接把 .tres 本体扔进战斗，
##   一场战斗就会永久改坏整个项目里所有引用同一资源的角色；复制一份后，
##   战斗怎么改都只影响这一局的副本（顺带也为以后"战斗结束回写血量"留了接口）。
## 坑：duplicate() 默认是**浅拷贝**（参数 subresources = false），所以 UnitStats 里的数组字段
##   （例如 skills）在副本和原件之间是**共享同一个 Array 实例**的 —— 战斗逻辑只读它所以没问题，
##   但谁要是就地往哪个副本的 skills 里 append，原 .tres 也会跟着变。
func _make_player_team() -> Array[UnitStats]:
	var out: Array[UnitStats] = []
	for stats in deployed:
		if stats == null:
			continue
		# duplicate：战斗改的是副本，不污染 .tres（以后做"战斗结束回写血量"也方便）
		out.append(stats.duplicate() as UnitStats)
	return out


## 按"当前地图 + 难度档"生成敌方队伍（每张图一套缩放规则）。
## 参数：无（读 current_map_id / maps / enemy_pool）。
## 返回值：新的 Array[UnitStats]；池子为空时返回空数组（调用方 enter_battle 会据此中止）。
## 副作用：无（全部是 duplicate 出来的副本；原 .tres 只读不写）。
##
## 敌人池的选择（一行三元表达式，注意短路求值）：
##   MapData.enemy_pool 非空就用它，否则回落到 GameRoot.enemy_pool（本文件的全局池）。
##   条件里先判 map != null，所以 map 为 null 时不会去访问 map.enemy_pool（短路保护）。
##
## 数量公式：count = clampi(上阵人数 ± 1, 1, MAX_ENEMY_COUNT)
##   · 基准是**上阵人数**（deployed，也就是这场战斗真正上场的人数），不是难度档、也不是团队总人数 ——
##     团队名册里坐板凳的人不该让敌人变多，只有真上场的人才会；
##   · ±1 用 randi_range(-1, 1)，三种结果等概率：少 1 人 / 一样多 / 多 1 人。
##     想改成"必定 +1 或 -1、绝不相同"，把这一行换成
##       var count := clampi(deployed_count(deployed) + (-1 if randi() % 2 == 0 else 1), 1, MAX_ENEMY_COUNT)
##     即可（其余逻辑不用动）；
##   · 下界 1：0 个敌人的话 Battle.start_battle() 会判定"有一方队伍是空的"、警告后回 IDLE，
##     也就是打不起来 —— 所以再少也要留 1 只；
##   · 上界 MAX_ENEMY_COUNT：对齐 Stage/EnemySlots 的 Marker2D 数量（前三后二），再多没位置站。
##   · 难度档 difficulty 仍然要算，但**只**用来算下面的 scale。
## 血量/伤害缩放：scale = 1.0 + (difficulty - 1) × enemy_scale_per_map，
##   并且都是用**原始 base 的值**乘 scale（而不是在副本上累乘）——
##   所以同一只敌人被抽到多次也不会出现"越乘越大"的复利。
## 取值方式：pool[i % pool.size()] —— 池子不够 count 只时**循环取**（同一只敌人可能出现多次），
##   因此池子里至少要有一只，否则 pool.size() 为 0 会除零（上面的 empty 判断挡住了这种情况）。
## maxf(1.0, ...) 是下限兜底：即使配置把 health/damage 写成 0 或负数，
##   也不会造出"一碰就死"或"给对方回血"的敌人。
func _make_enemy_team() -> Array[UnitStats]:
	var out: Array[UnitStats] = []
	var map := get_map(current_map_id)
	var pool: Array[UnitStats] = map.enemy_pool if map != null and not map.enemy_pool.is_empty() else enemy_pool
	if pool.is_empty():
		return out

	var difficulty := map_difficulty()
	var count := clampi(deployed_count(deployed) + randi_range(-1, 1), 1, MAX_ENEMY_COUNT)
	var scale: float = 1.0 + (difficulty - 1) * enemy_scale_per_map
	for i in count:
		var base: UnitStats = pool[i % pool.size()]
		if base == null:
			continue
		var scaled := base.duplicate() as UnitStats
		scaled.health = maxf(1.0, base.health * scale)
		scaled.damage = maxf(1.0, base.damage * scale)
		out.append(scaled)
	return out

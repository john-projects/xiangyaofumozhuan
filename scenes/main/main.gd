# ═══════════════════════════════════════════════════════════════════════════
# GameRoot —— 游戏总入口 / 屏幕调度器（唯一主场景 main.tscn 的根脚本）
# ═══════════════════════════════════════════════════════════════════════════
# 在系统里的位置：
#   main.tscn 是 project.godot 里配置的**唯一主场景**，所以本脚本是整局游戏的"根"。
#   它自己**不画任何东西**：画面全部由它 add_child 进来的"屏幕"负责。
#   项目里的屏幕分两类、各有一个容器（都是 main.tscn 里的节点，见下面的 @onready）：
#     · WorldRoot(Node2D)      —— 世界类屏幕：WorldMap / Battle
#     · UIRoot(CanvasLayer)    —— UI 类屏幕：TitleScreen
#     · TransitionLayer(CanvasLayer, layer=200) —— 最上层的黑幕 ColorRect(Fade)，做淡入淡出
#
# 它是全项目唯一"持有流程状态"的地方：
#   current_map_id（当前在哪张图）、party（队伍）、cleared_maps（通关记录）、
#   _map_positions（每张图离开时站的归一化位置）、in_battle（是否在战斗中）。
#   其余系统只拿 MapData / UnitStats 这类资源，互不引用 —— 依赖方向是"屏幕 → GameRoot"单向的。
#
# 屏幕之间怎么通信（本文件的核心模式）：
#   屏幕只 emit 信号（battle_requested / travel_requested / back_to_title_requested /
#   battle_ended …），GameRoot 订阅这些信号并决定下一屏是谁。
#   所以"改流程"= 改本文件，屏幕本身不需要知道别的屏幕存在。
#
# 一次完整的新游戏流程（照着读一遍就理解本文件了）：
#   _ready() → fade 全黑 → await show_title()
#     → 主菜单「新的征程」→ start_new_game()（清空所有局内状态、金币重置）
#     → start_game_with_defaults()（直接用 default_leader 开局）
#         → _begin_new_run()
#             → party（团队）= [队长]、deployed（上阵）= [队长]，emit map_changed
#     → show_map()（把 WorldMap 挂到 WorldRoot 下）
#         → 地图里点「进入战斗」→ enter_battle() → _swap(battle, world_root)
#             → 打完 emit battle_ended → _on_battle_ended()：记通关、发奖励、回地图（原地）
#         → 地图里点传送 → travel_to(next_id)：记住位置、换 current_map_id、show_map() 到新图
#
# 数据流（谁写 Global）：
#   本文件会写 Global.coins（start_new_game 重置 / _on_battle_ended 发奖励）、
#   Global.equipped_weapons / Global.equipment_by_character（开局清空，之后只由买/卖/穿脱改）、
#   Global.main_player_selected（start_new_game 里置 null）。
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
#     start_new_game() 那样逐项手动清。

extends Node
class_name GameRoot

## 游戏总入口（唯一主场景）
##
## 流程：
##   主菜单(TitleScreen) → 世界地图(WorldMap, 走动探索)
##        → 点地图上的传送点前往下一张图 / 点「进入战斗」打当前地图的敌人
##        → 回合制战斗(Battle) → 结算 → 回地图 → …（最后一张图是终点）
##
## 地图串联（顺序）：建邺城 → 东海湾 → 傲来国 → 花果山
##   每张图的配置在 resources/maps/*.tres（MapData），next_id 指向下一张，
##   最后一张 next_id 留空。要加新图（比如狮驼岭）：
##     复制一个 .tres → 改 id / display_name / texture / next_id → 加进 main.tscn 的 Maps 数组
##
## 场景里的三个容器：
##   WorldRoot        Node2D     —— 世界类屏幕（地图 / 战斗）
##   UIRoot           CanvasLayer—— UI 屏幕（主菜单）
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
## 默认队长：主菜单「新的征程」直接用的 UnitStats。
## 换人只要改这一行（或是在 main.tscn 的检查器里填 default_leader 覆盖它）。
## ⚠ 用"敌人"资源当队长也是安全的（想快速测队伍/敌人数量时可以这么干）：
##   战斗走的是 Battle.start_battle(我方数组, 敌方数组) 显式传参，不读 UnitStats.type。
const DEFAULT_LEADER := preload("res://resources/units/players/stats_player_well_rounded.tres")

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

# ── 等级与经验（玩家等级，全队共享；满级 100）──────────────────────────────
## 满级。到这一级之后经验不再增长（打赢也只给金币）。
const MAX_LEVEL := 100
## 经验曲线：**升到下一级所需经验** need(L) = round(EXP_BASE + EXP_LINEAR×L + EXP_QUAD×L²)
## （L = 当前等级，1..99）。三个系数是这条曲线的全部"旋钮"，改这里就能整体调快/调慢：
##   · EXP_BASE   —— 低等级的下限（别让前几级"一场战斗直接跳 10 级"）；
##   · EXP_LINEAR —— 中期的线性增长（每级多要多少）；
##   · EXP_QUAD   —— 后期的二次项（越往高级越吃经验）。
## 现值 60 / 20 / 0.42：L1 要 80、L10 要 302、L50 要 2110、L99 要 6156，
## 1→100 累计 **242,852 经验**（≈ 400~650 场战斗，见 README 的节奏表）。
## ⚠ 改完记得跑一次 _verify_level 的曲线检查（会核对单调递增与总量）。
const EXP_BASE := 60.0
const EXP_LINEAR := 20.0
const EXP_QUAD := 0.42
## 每级属性加成（乘算）：**已被"基础属性"系统取代** —— 现在升级靠
## ATTR_PER_LEVEL / ATTR_FREE_PER_LEVEL 发属性点，不再是全局百分比倍率。
## 保留这个常量只是为了让旧存档/旧文档有个对照；代码里已经没人读它了。
const LEVEL_GROWTH_PER_LEVEL := 0.0
## 每场胜利的经验 = exp_reward_per_map × 地图难度 + exp_per_enemy × 敌人数量。
## 默认 120 / 20：第 1 图 2 个敌人 = 160、第 4 图 5 个敌人 = 580 —— 越靠后的图越值得刷。
@export var exp_reward_per_map := 120
@export var exp_per_enemy := 20

# ── 基础属性（五项；升级自动 +1，另给自由点）──────────────────────────────
## 五项基础属性的键（顺序 = UI 顺序 = 系数表的顺序）。
## con 体质 / mag 魔力 / str 力量 / end 耐力 / agi 敏捷。
const ATTR_KEYS := ["con", "mag", "str", "end", "agi"]
## 五项基础属性的中文名（和 ATTR_KEYS 一一对应）。
const ATTR_NAMES := ["体质", "魔力", "力量", "耐力", "敏捷"]
## 每升 1 级：五项基础属性**各 +本值**（自动，不受操作影响）。
const ATTR_PER_LEVEL := 1
## 每升 1 级：额外获得这么多点**自由属性点**，玩家自己加到任意一项上。
const ATTR_FREE_PER_LEVEL := 5
## 种族 × 基础属性 → 派生属性的**系数表**（用户给的数值，一字不改）。
## 结构：种族 → 属性键 → { 派生键: 每点加成 }。
## 派生键含义：hp=气血、mana=魔法、damage=伤害、defense=防御、speed=速度、dodge=躲避、
##   spell_damage=法伤（原"灵力"），以及 crit_rate / crit_damage_bonus / seal_hit / healing /
##   crit_resist / crit_damage_resist / seal_resist / block_value 这些二级属性。
## 用法：某项基础属性的总点数 × 对应系数，再把五项加总（+ .tres 里的基础值），见 derived_stats()。
## 为什么要按种族分表：人族均衡、仙族防高法强（耐力/魔力系数高）、魔族血多物理强（体质/力量高）。
const ATTR_TABLE := {
	UnitStats.Race.HUMAN: {
		"con": {"hp": 5.0, "spell_damage": 0.3, "speed": 0.1},
		"mag": {"mana": 3.0, "spell_damage": 0.7},
		"str": {"damage": 0.75, "spell_damage": 0.4},
		"end": {"defense": 1.5, "spell_damage": 0.2, "speed": 0.1},
		"agi": {"speed": 0.7, "dodge": 1.0},
	},
	UnitStats.Race.IMMORTAL: {
		"con": {"hp": 4.5, "spell_damage": 0.3, "speed": 0.1},
		"mag": {"mana": 3.5, "spell_damage": 0.7},
		"str": {"damage": 0.65, "spell_damage": 0.4},
		"end": {"defense": 1.6, "spell_damage": 0.2, "speed": 0.1},
		"agi": {"speed": 0.7, "dodge": 1.0},
	},
	UnitStats.Race.DEMON: {
		"con": {"hp": 6.0, "spell_damage": 0.3, "speed": 0.1},
		"mag": {"mana": 2.5, "spell_damage": 0.7},
		"str": {"damage": 0.85, "spell_damage": 0.4},
		"end": {"defense": 1.4, "spell_damage": 0.2, "speed": 0.1},
		"agi": {"speed": 0.7, "dodge": 1.0},
	},
}
## 开局用的队长（UnitStats）。**在 main.tscn 的检查器里填**；留空 = 用 DEFAULT_LEADER。
## 想临时试别的角色/敌人，填这里最省事（不用改代码、也不用改那句 preload）。
@export var default_leader: UnitStats

# ── 场景容器引用（% = main.tscn 里标记为 unique_name_in_owner 的节点）────────
## 世界类屏幕容器（Node2D）。WorldMap / Battle 都挂这里（受世界坐标与 y_sort 影响）。
@onready var world_root: Node2D = %WorldRoot
## UI 类屏幕容器（CanvasLayer）。TitleScreen 挂这里（不随相机移动）。
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
## 这一场战斗的敌人数量（enter_battle 生成敌人后记下）。
## 为什么记：结算是 _on_battle_ended() 里做的，那时敌人队伍早已随 Battle 场景释放，
##   而经验奖励要按"打了几个"算（exp_per_enemy × 数量），所以进战斗时先存一份。
var _last_enemy_count := 0
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
#  等级与经验
# ══════════════════════════════════════════════════════════
#  数值全在文件顶部：MAX_LEVEL / EXP_BASE / EXP_LINEAR / EXP_QUAD / exp_reward_per_map / exp_per_enemy。
#  成长全在"基础属性"那一段（ATTR_* / ATTR_TABLE），等级只负责发点。这里只放"怎么算"和"什么时候加"。
#
#  设计目标（满级 100）：
#    · 前 10 级很便宜（1~3 场一场一级），让玩家很快看到"升级"这件事；
#    · 中期线性增长（每级多 20 左右），节奏稳定；
#    · 后期二次项接管（每级 +0.42×L²），越练越慢但不失控 —— 1→100 累计 242,842 经验，
#      按"第 4 张图 3 个敌人"（约 540/场）算 ≈ 450 场，按混合地图打 ≈ 600 场。
#    · 升级只发属性点（见下面"基础属性"一段），不再有全局百分比倍率。

## 从 level 升到 level+1 需要的经验。
## 参数 level：当前等级（1..MAX_LEVEL-1）。
## 返回值：所需经验（整数）；level >= MAX_LEVEL（或 < 1）时返回 0（满级不再需要经验）。
## 公式：round(EXP_BASE + EXP_LINEAR×L + EXP_QUAD×L²)，三个系数就是整条曲线的旋钮。
## 为什么用 round 而不是 ceil：让 L1 = 80 这种整数，玩家看得舒服；经验本身是整数，不存在"差一点"。
static func exp_to_next(level: int) -> int:
	if level < 1 or level >= MAX_LEVEL:
		return 0
	return int(roundf(EXP_BASE + EXP_LINEAR * level + EXP_QUAD * level * level))


## 这场战斗该给多少经验（胜利结算用）。
## 参数 enemy_count：这一场敌人的数量（_last_enemy_count）。
## 返回值：经验点数，= exp_reward_per_map × 地图难度 + exp_per_enemy × 敌人数量。
##   例：第 1 图 2 敌 = 120×1 + 20×2 = 160；第 4 图 5 敌 = 480 + 100 = 580。
## 为什么按"地图难度 + 敌人数量"：难度保证越靠后的图越值得打（和金币一致），
##   数量保证"以少打多"这种难打的战斗不吃亏。
func exp_reward(enemy_count: int) -> int:
	return exp_reward_per_map * map_difficulty() + exp_per_enemy * maxi(0, enemy_count)


# ══════════════════════════════════════════════════════════
#  基础属性（体质 / 魔力 / 力量 / 耐力 / 敏捷）与派生属性
# ══════════════════════════════════════════════════════════
#  模型（三句话）：
#    1. 每项基础属性 = 等级自动给的 (等级-1)×ATTR_PER_LEVEL + 玩家自由分配的点数；
#    2. 派生属性 = .tres 里的基础值 + Σ(每项基础属性点数 × 种族系数)，系数见 ATTR_TABLE；
#    3. 战斗用的就是派生后的值（_make_player_team 写进副本），原先"每级 ×1.5%"的倍率已停用。
#  谁写：add_player_exp() 只改等级（自动成长随之现算）；allocate_attr() 是自由点的唯一写入点。

## 五项基础属性的**总点数**（自动成长 + 自由分配）。
## 参数 character：角色；返回值：长度 5 的 Array[int]，顺序同 ATTR_KEYS。
## 为什么自动成长不存字典、而是按"等级 - 1"现算：存了的话每升一级都要遍历全队去加，
##   还可能出现"某个角色的自动成长没跟上"的脏数据；现算永远和等级一致。
static func attribute_points(character: UnitStats) -> Array[int]:
	var out: Array[int] = [0, 0, 0, 0, 0]
	if character == null:
		return out
	var auto_points := maxi(0, Global.player_level - 1) * ATTR_PER_LEVEL
	var alloc := _attr_alloc(character)
	for i in ATTR_KEYS.size():
		out[i] = auto_points + int(alloc[i])
	return out


## 某个角色手上还剩多少**自由属性点**没花。
## 参数 character：角色。
## 返回值：剩余点数（等级 1 = 0；每升一级 +ATTR_FREE_PER_LEVEL，花掉就减）。
static func free_attribute_points(character: UnitStats) -> int:
	if character == null:
		return 0
	var total := maxi(0, Global.player_level - 1) * ATTR_FREE_PER_LEVEL
	var spent := 0
	for value in _attr_alloc(character):
		spent += int(value)
	return maxi(0, total - spent)


## 读取某个角色"已分配的自由点"（长度 5 的**副本**；没有记录就全 0）。
## 返回副本而不是字典里那个数组：调用方拿到后怎么改都不会绕过 allocate_attr 写脏数据。
static func _attr_alloc(character: UnitStats) -> Array[int]:
	var out: Array[int] = [0, 0, 0, 0, 0]
	if character == null:
		return out
	var raw = Global.attr_alloc_by_character.get(character_key(character))
	if raw == null:
		return out
	for i in mini(ATTR_KEYS.size(), (raw as Array).size()):
		out[i] = int(raw[i])
	return out


## 把自由属性点加到某一项上。
## 参数 character：角色；index：0..4（顺序同 ATTR_KEYS）；amount：加几点（默认 1）。
## 返回值：空串 = 成功；否则是不能加的原因（可直接显示）。
## 副作用：写 Global.attr_alloc_by_character[角色键]（唯一写入点）。
static func allocate_attr(character: UnitStats, index: int, amount := 1) -> String:
	if character == null:
		return "没有选中角色。"
	if index < 0 or index >= ATTR_KEYS.size():
		return "没有这项基础属性。"
	if amount <= 0:
		return "加点数量必须大于 0。"
	if free_attribute_points(character) < amount:
		return "没有足够的自由属性点（还剩 %d 点）。" % free_attribute_points(character)
	var key := character_key(character)
	var alloc := _attr_alloc(character)
	alloc[index] += amount
	Global.attr_alloc_by_character[key] = alloc
	return ""


## 一次性提交"一组加减"（属性面板的「确认加点」走这里）。
## 参数 character：角色；deltas：长度 5 的数组，每项是这一项要加/减的点数（可正可负）。
## 返回值：空串 = 成功；否则是拒绝原因（点不够 / 会减成负数 / 数组长度不对）。
## 副作用：写 Global.attr_alloc_by_character[角色键]（和 allocate_attr 同一个存储，唯一写入点）。
## 为什么要有批量接口：面板上玩家先按「＋/－」改一组**暂存**的差值，点「确认」才真正落盘；
##   逐项调 allocate_attr 做不到"先减后加"（减需要动已有分配），也会在中途出现负数/超额状态。
## 校验规则：每一项的最终分配不能 < 0；所有差值之和不能超过当前剩余自由点（= 确认后 free 不为负）。
static func apply_attr_deltas(character: UnitStats, deltas: Array) -> String:
	if character == null:
		return "没有选中角色。"
	if deltas.size() != ATTR_KEYS.size():
		return "属性点数不对。"
	var alloc := _attr_alloc(character)
	var added := 0
	for i in deltas.size():
		var delta := int(deltas[i])
		if alloc[i] + delta < 0:
			return "%s 不能减到 0 以下。" % ATTR_NAMES[i]
		added += delta
	if added > free_attribute_points(character):
		return "没有足够的自由属性点（还剩 %d 点）。" % free_attribute_points(character)
	if added == 0:
		return ""
	for i in deltas.size():
		alloc[i] += int(deltas[i])
	Global.attr_alloc_by_character[character_key(character)] = alloc
	return ""


## 按种族系数把"基础属性"折算成派生属性（这是战斗/面板真正用的数值）。
## 参数 character：角色。
## 返回值：Dictionary，键为：
##   · 由基础属性算出来的：hp / mana / damage / defense / speed / dodge / spell_damage（法伤）；
##   · 只是"带出来"的二级属性：crit_rate / crit_damage_bonus / seal_hit / healing /
##     crit_resist / crit_damage_resist / seal_resist / block_value（读 .tres 上的值，暂不受属性影响）。
##   值 = character 自己的基础值 + Σ(五项基础属性点数 × 该种族的对应系数)。
## ⚠ 这是**纯函数**：只读 Global 与 character，不写任何状态（面板刷新时随便调）。
static func derived_stats(character: UnitStats) -> Dictionary:
	var out := {
		"hp": 0.0, "mana": 0.0, "damage": 0.0, "defense": 0.0,
		"speed": 0.0, "dodge": 0.0, "spell_damage": 0.0,
		"crit_rate": 0.0, "crit_damage_bonus": 0.0, "seal_hit": 0.0, "healing": 0.0,
		"crit_resist": 0.0, "crit_damage_resist": 0.0, "seal_resist": 0.0, "block_value": 0.0,
	}
	if character == null:
		return out
	out["hp"] = character.health
	out["mana"] = character.mana
	out["damage"] = character.damage
	out["speed"] = character.speed
	out["defense"] = character.defense
	out["dodge"] = character.dodge
	out["spell_damage"] = character.spell_damage
	out["crit_rate"] = character.crit_rate
	out["crit_damage_bonus"] = character.crit_damage_bonus
	out["seal_hit"] = character.seal_hit
	out["healing"] = character.healing
	out["crit_resist"] = character.crit_resist
	out["crit_damage_resist"] = character.crit_damage_resist
	out["seal_resist"] = character.seal_resist
	out["block_value"] = character.block_value
	var race: int = character.race
	var table: Dictionary = ATTR_TABLE.get(race, ATTR_TABLE[UnitStats.Race.HUMAN])
	var points := attribute_points(character)
	for i in ATTR_KEYS.size():
		var coef: Dictionary = table.get(ATTR_KEYS[i], {})
		for key in coef:
			out[key] += float(coef[key]) * points[i]
	return out


## 加经验（**唯一的经验入口**）：会一路处理"连升多级"，并把溢出经验留到下一级。
## 参数 amount：这次获得多少经验（<= 0 直接忽略）。
## 返回值：这次升了几级（0 = 没升；满级后再加也是 0）。
## 副作用：改 Global.player_exp / player_level；满级时把经验归零（不再累积）。
## 为什么用 while 而不是 if：一场战斗的经验可能一次顶好几级（尤其前期），
##   只扣一次 need 会让玩家"卡在 5 级却攒着 3000 经验"，下次再打赢才补一级 —— 看起来像 bug。
func add_player_exp(amount: int) -> int:
	if amount <= 0:
		return 0
	if Global.player_level >= MAX_LEVEL:
		return 0
	Global.player_exp += amount
	var gained := 0
	while Global.player_level < MAX_LEVEL:
		var need := exp_to_next(Global.player_level)
		if Global.player_exp < need:
			break
		Global.player_exp -= need
		Global.player_level += 1
		gained += 1
	if Global.player_level >= MAX_LEVEL:
		Global.player_exp = 0            # 满级后经验条满格，不再累积（避免"无限经验"的假数字）
	# 门派技能跟着角色等级一起长（每个已拜师角色 +gained 级，封顶 100）
	if gained > 0:
		_bump_sect_skill_levels(gained)
	return gained


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
##   · connect 两条信号：new_game_requested → start_new_game、
##     quit_requested → 一个直接调 get_tree().quit() 的 lambda；
##   · await _swap(screen)（默认挂到 ui_root）。
## 关于那个 lambda：信号是"无参"的，而 get_tree().quit() 需要 scene tree，
##   所以用匿名函数包一层（函数引用也能连，但这里要传调用结果所以必须包）。
##   该 Callable 挂在 screen 上，screen 被清掉时连接一起消失，不会泄漏。
func show_title() -> void:
	var screen := TITLE_SCENE.instantiate() as TitleScreen
	screen.last_result = _last_result
	screen.new_game_requested.connect(start_new_game)
	screen.quit_requested.connect(func() -> void: get_tree().quit())
	await _swap(screen)


## 开始一局新游戏：把所有**局内状态**清干净，然后用默认队长直接开局。
## 参数：无。返回值：无（本身不含 await；末尾的 start_game_with_defaults() 没被 await）。
## 副作用（这份清单就是"新档重置"的完整定义）：
##   · party / cleared_maps / _map_positions / _last_result 清空；
##   · current_map_id 回到 _first_map_id()；
##   · Global.coins = starting_coins（**唯一的金币重置点**）；
##   · Global.player_level / player_exp 回到 1 / 0（等级也属于"局内进度"，新档从头练）；
##   · Global.equipped_weapons.clear() / Global.equipment_by_character.clear()（背包与所有人的装备栏回到空）；
##   · Global.main_player_selected 置 null；
##   · 调用 start_game_with_defaults()（直接按 default_leader 开局）。
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
	Global.player_level = 1
	Global.player_exp = 0
	Global.equipped_weapons.clear()
	Global.equipment_by_character.clear()   # 全队每个人的装备栏都清空，否则新档会带着上一局的头盔/武器
	Global.sect_by_character.clear()        # 门派也是局内进度：新档所有人回到"无门派"
	Global.sect_skill_level_by_character.clear()  # 门派技能等级一起清
	Global.attr_alloc_by_character.clear()  # 属性加点同理：新档从 0 开始练
	Global.main_player_selected = null
	start_game_with_defaults()


## 用默认队长直接开局。
## 参数：无（读 default_leader，留空则回落到本文件顶部的 DEFAULT_LEADER）。
## 返回值：无（不含 await；末尾 _begin_new_run() 未被 await）。
## 副作用：写 Global.main_player_selected，然后交给 _begin_new_run() 组队、进第一张图。
func start_game_with_defaults() -> void:
	var leader := default_leader if default_leader != null else DEFAULT_LEADER
	if leader == null:
		push_warning("GameRoot: 没有配置默认队长（default_leader / DEFAULT_LEADER），无法直接开局")
		return
	Global.main_player_selected = leader
	_begin_new_run()


## 队长确定 → 组成队伍，进入第一张地图。
## 谁调它：start_game_with_defaults()（**唯一入口**；选人界面已随竞技场一起移除）。
## 参数：无（队长在 Global.main_player_selected 里）。
## 返回值：无（不含 await；末尾 show_map() 未被 await）。
## 副作用：
##   · Global.main_player_selected 为 null 时警告并**直接 return**（不往下走，避免用 null 组队）；
##   · party = [队长]（团队名册，第 0 位永远是队长）、deployed = [队长]（队长默认上阵）；
##     招募来的队友会在之后由 add_party_member() 追加，上阵/下阵由队伍管理面板切换；
##   · Global.equipped_weapons.clear()（背包清空；Global.equipment_by_character 也清空 —— 所有装备栏回到空）；
##     ⚠ 开局**不送任何装备**，装备全靠商人和战斗奖励；
##   · emit map_changed(current_map_id)（当前无人接听，属于预留）；
##   · 调 show_map() 进入第一张图。
## 注意 party 里放的是**资源引用**（不是节点）：战斗前 _make_player_team() 会 duplicate() 成副本，
##   所以战斗中的掉血不会污染 .tres。
func _begin_new_run() -> void:
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
	Global.equipment_by_character.clear()   # 同 start_new_game()：所有人的装备栏都要回到空
	Global.sect_by_character.clear()        # 门派同理：回到"无门派"
	Global.sect_skill_level_by_character.clear()  # 门派技能等级一并清空
	Global.attr_alloc_by_character.clear()  # 属性自由点也清空
	# 同理：等级/经验也属于"这一局"的进度，重开一局要从 1 级重新练
	Global.player_level = 1
	Global.player_exp = 0
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
##   · connect 十一条信号：battle_requested → enter_battle、travel_requested → travel_to、
##     back_to_title_requested → show_title、recruit_requested → _on_recruit_requested、
##     party_remove_requested → _on_party_remove_requested、
##     party_deploy_requested → _on_party_deploy_requested、
##     party_undeploy_requested → _on_party_undeploy_requested、
##     item_buy_requested → _on_item_buy_requested、
##     item_sell_requested → _on_item_sell_requested、
##     equip_requested → _on_equip_requested、unequip_requested → _on_unequip_requested；
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
	world.setup(map, party, result_text, cleared_maps.has(map.id), _map_names(), from_map_id)
	world.battle_requested.connect(enter_battle)
	world.travel_requested.connect(travel_to)
	world.back_to_title_requested.connect(show_title)
	world.recruit_requested.connect(_on_recruit_requested)
	world.party_deploy_requested.connect(_on_party_deploy_requested)
	world.party_undeploy_requested.connect(_on_party_undeploy_requested)
	world.item_buy_requested.connect(_on_item_buy_requested)
	world.item_sell_requested.connect(_on_item_sell_requested)
	# 装备栏：点背包里的装备 = 穿；点已穿的栏位 = 脱（都在 GameRoot 改数据，见 equip_item）
	world.equip_requested.connect(_on_equip_requested)
	world.unequip_requested.connect(_on_unequip_requested)
	# 门派：拜师面板里点某个队员 = 让他拜入这个 NPC 的门派（种族/已有门派由 can_join_sect 判）
	world.sect_join_requested.connect(_on_join_sect_requested)
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
## 为什么用 `is WorldMap` 而不是记成员变量：世界类屏幕也可能被换成 Battle，
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
	_last_enemy_count = enemies.size()      # 结算时按"打了几个"给经验（见 exp_reward）

	var battle := BATTLE_SCENE.instantiate() as Battle
	battle.auto_start_demo = false          # ★ 必须在 add_child 之前
	battle.battle_ended.connect(_on_battle_ended)
	in_battle = true
	await _swap(battle, world_root)
	battle.start_battle(_make_player_team(), enemies)


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
		# 经验：和金币同一条公式思路（难度越高越多），另加"按敌人数量"的份（见 exp_reward）
		var exp := exp_reward(_last_enemy_count)
		var levels_gained := add_player_exp(exp)
		var exp_text := "获得 %d 金币、%d 经验" % [reward, exp]
		if Global.player_level >= MAX_LEVEL:
			exp_text = "获得 %d 金币（已满级，经验不再增长）" % reward
		_last_result = "%s：战斗胜利！%s" % [map_name, exp_text]
		if levels_gained > 0:
			_last_result += "　★ 升到 %d 级！获得 %d 点自由属性" % [
					Global.player_level, levels_gained * ATTR_FREE_PER_LEVEL]
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
##   · 最后比 name —— 同名的 UnitStats 视为同一角色（.tres 被复制/重载过也能认出来），兜底安全。
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


# ═══════════════════════════════════════════════════════════════════════════
#  装备背包（商人 NPC 卖装备用）+ 装备栏（背包角色区那 6 个格子）
# ═══════════════════════════════════════════════════════════════════════════
#  背包就是 Global.equipped_weapons（**数据**列表，不是节点；元素类型是 ItemBase）。
#  地图线现在装的全是 ItemEquipment（头盔/武器/腰带/项链/衣服/鞋子，见
#  resources/items/equipment/），老的 ItemWeapon 已经随竞技场一起移除。
#  这里只做四件事：
#    · 给出"能不能买"的**统一判定**（面板画按钮和真正购买共用同一份，见 item_can_buy）；
#    · 买下时扣钱 + 记进列表（buy_item）；
#    · 把结果接到界面刷新上（_on_item_buy_requested → WorldMap.notify_shop_changed）；
#    · 穿/脱装备（equip_item / unequip_slot：在背包和 Global.equipment_by_character 之间搬东西）。
#
#  ⚠ 与老的竞技场商店（ShopPanel / ShopCard）的关系：
#    那套是"候选池 → 按波数随机抽 4 件 → 买到手还要 Global.player.add_weapon() 造 Weapon 节点"；
#    地图模式没有玩家节点（战斗里的单位是 BattleUnit，数值全来自 UnitStats），
#    所以这里**只记数据**，不造节点。容量用同一个常量 BAG_SLOTS（老的 ShopCard 里也改成引用它了）。

## 背包格数。梦幻西游式的方格背包：BagPanel 一行 8 格，120 格 = 15 行。
## 面板只显示前 7 行（8×7=56 格），剩下的靠**滚动**看（ScrollContainer + follow_focus，
## 键盘往下走会自动滚过去）—— 所以"能放 120 件"和"一屏只看 56 格"是两件事。
## 买到的东西都进 Global.equipped_weapons，超过这个数就买不进去（商人按钮会置灰并说明）。
## ⚠ 与 BagPanel.GRID_COLUMNS（每行几格）要能整除得好看，但**不必**相等。
const BAG_SLOTS := 120


## 背包里同名道具有几件（商人面板用它显示"已持有 ×n"）。
## 判定顺序与 party_has() 一致：引用 → resource_path → item_name。
## 参数 p_equipped：背包内容（Array[ItemBase]）。
## 参数 item：要比对的那件（装备/武器都行）。
static func item_owned_count(p_equipped: Array[ItemBase], item: ItemBase) -> int:
	if item == null:
		return 0
	var n := 0
	for owned in p_equipped:
		if owned == null:
			continue
		if owned == item:
			n += 1
		elif not owned.resource_path.is_empty() and owned.resource_path == item.resource_path:
			n += 1
		elif owned.item_name == item.item_name:
			n += 1
	return n


## 现在能不能买这件东西：返回**空串** = 能买；否则返回"不能买的原因"（面板直接显示这句话）。
## 做成静态函数的原因与队伍那套一样：MerchantPanel 要按同样的规则决定按钮灰不灰，
## 两边共用一份判定，就不会出现"按钮能点、点下去却什么都没发生"——
## 老 ShopCard 正是反例（金币不够 / 背包满时静默 return，玩家只会觉得按钮坏了）。
static func item_can_buy(item: ItemBase, coins: int, p_equipped: Array[ItemBase]) -> String:
	if item == null:
		return "这件东西不存在。"
	if item.item_cost > 0 and coins < item.item_cost:
		return "金币不够（需要 %d，现在 %d）。" % [item.item_cost, coins]
	if p_equipped.size() >= BAG_SLOTS:
		return "背包满了（%d 格都占着），先卖出或合成。" % BAG_SLOTS
	return ""


## 买下一件东西：扣 Global.coins + 记进 Global.equipped_weapons。
## 参数 item：要买的道具（调用方通常已用 item_can_buy() 校验过；这里再校验一次更稳）。
## 返回值：true = 买成功；false = 没买（金币不够 / 背包满 / 传了 null）。
## 副作用：改 Global.coins、Global.equipped_weapons —— 这里是背包**唯一的写入点**。
## 刻意**不**发信号：数据变化和界面刷新是两件事；界面刷新由调用方走 WorldMap.notify_shop_changed()。
func buy_item(item: ItemBase) -> bool:
	if not item_can_buy(item, Global.coins, Global.equipped_weapons).is_empty():
		return false
	Global.coins -= item.item_cost
	Global.equipped_weapons.append(item)
	return true


## 商人面板的「购买」回调（WorldMap.item_buy_requested → 这里）。
## 参数 item：玩家点了购买的那件东西（由 WorldMap 从面板按钮 bind 过来）。
## 副作用：成功后 buy_item()（扣钱 + 入包），再让商人面板按新状态重建 ——
##   余额、按钮灰不灰、"已持有 ×n" 都会跟着变；失败时只把原因写回面板（不改任何状态）。
func _on_item_buy_requested(item: ItemBase) -> void:
	var world := _current_world_map()
	var why := item_can_buy(item, Global.coins, Global.equipped_weapons)
	if not why.is_empty():
		if world != null:
			world.notify_shop_changed(why)
		return
	buy_item(item)
	if world != null:
		world.notify_shop_changed("买下了 %s（-%d 金币）。" % [item.item_name, item.item_cost])


# ── 卖出（交易界面上把背包里的东西卖回给商人）────────────────────────────
## 卖出返还比例。**与老的 ShopPanel._on_sell_button_pressed() 保持一致**
##   （那边写的是 `int(item_cost * 0.75)`，截断不是四舍五入：21 金币卖 15）。
## 留 25% 折旧，买卖来回会亏，避免"低买高卖刷钱"。
const SELL_REFUND_RATIO := 0.75


## 这件东西卖出去能拿多少金币：`int(item_cost × SELL_REFUND_RATIO)`（截断）。
## 参数 item：要卖的道具。返回值：金币数；道具为空 / 非卖品（item_cost ≤ 0）时返回 0。
static func item_sell_price(item: ItemBase) -> int:
	if item == null or item.item_cost <= 0:
		return 0
	return int(item.item_cost * SELL_REFUND_RATIO)


## 现在能不能卖这件东西：返回**空串** = 能卖；否则返回不能卖的原因（界面直接显示这句话）。
## 做成静态函数的原因与 item_can_buy 一样：商人面板画"卖"确认框、真正卖的时候，
##   两边共用同一份判定。规则：背包里得有它、并且它得卖得出价钱。
static func item_can_sell(item: ItemBase, p_equipped: Array[ItemBase]) -> String:
	if item == null:
		return "这件东西不存在。"
	if item_owned_count(p_equipped, item) <= 0:
		return "背包里没有「%s」。" % item.item_name
	if item_sell_price(item) <= 0:
		return "「%s」卖不出价钱（非卖品）。" % item.item_name
	return ""


## 卖掉一件东西：从 Global.equipped_weapons 里移除一件 + 把卖价加进 Global.coins。
## 参数 item：要卖的道具（调用方通常已用 item_can_sell() 校验过；这里再校验一次更稳）。
## 返回值：true = 卖成功；false = 没卖（背包里没有 / 非卖品 / 传了 null）。
## 副作用：改 Global.coins、Global.equipped_weapons —— 与 buy_item 一样，这里是背包的写入点。
## 注意 erase() 删的是"第一件相等的元素"：同一件东西在背包里有多件（多次购买会 append 同一个
##   资源实例）时只减一件，符合"卖一件"的语义。
func sell_item(item: ItemBase) -> bool:
	if not item_can_sell(item, Global.equipped_weapons).is_empty():
		return false
	Global.equipped_weapons.erase(item)
	Global.coins += item_sell_price(item)
	return true


## 商人面板的「卖出确认」回调（WorldMap.item_sell_requested → 这里）。
## 参数 item：玩家在背包里点着要卖的那件东西。
## 副作用：成功后 sell_item()（出包 + 加钱），再让两个面板按新状态重建
##   （商人货架的"持×n"、背包的格子与金币都跟着变）；失败时只把原因写回面板。
func _on_item_sell_requested(item: ItemBase) -> void:
	var world := _current_world_map()
	var why := item_can_sell(item, Global.equipped_weapons)
	if not why.is_empty():
		if world != null:
			world.notify_shop_changed(why)
		return
	var price := item_sell_price(item)
	sell_item(item)
	if world != null:
		world.notify_shop_changed("卖掉了 %s（+%d 金币）。" % [item.item_name, price])


# ── 装备栏（每个角色 6 个格子：头盔 / 武器 / 腰带 / 项链 / 衣服 / 鞋子）──────────
#  数据模型：Global.equipment_by_character = { 角色键 → { 栏位类型(ItemBase.EquipType) → ItemBase } }。
#  角色键见 character_key()；**每个进团队的角色各有一套**，互不影响。
#  和背包（Global.equipped_weapons，全队共用）互补：
#    **穿上 = 从背包取出放进这个角色的栏位**，脱下 = 反过来。
#    所以"背包里没有 = 队伍里某个人身上穿着"这种推断是成立的，卖出前必须先脱。
#
#  界面上怎么触发：
#    · 背包里点一件装备 → BagPanel.item_activated → WorldMap（没开商店时）equip_requested
#      → 这里，目标角色 = 背包界面当前展示的那个人（◀ / ▶ 切换）；
#    · 点一个**已穿上**的装备栏 → BagPanel.unequip_requested → WorldMap → 这里。
#  能不能穿由 item_can_equip() 统一判定（以后加"等级不够 / 职业不符"这类规则只改它）。


## 角色 → 装备表的键。
## 优先用资源路径：同一个角色即使被**重新加载**（新实例）也能对上原来那套装备，
##   而且两个同名但 .tres 不同的角色不会被混成一个人。
## 没有路径的资源（运行期 duplicate() 出来的副本，战斗里用的就是这种）退回 name ——
##   它们只用于战斗结算，不会成为团队成员，所以不必和原角色共享装备。
## 最后用实例 id 兜底（正常走不到，纯防御）。空角色返回空串。
static func character_key(character: UnitStats) -> String:
	if character == null:
		return ""
	if not character.resource_path.is_empty():
		return character.resource_path
	if not character.name.is_empty():
		return character.name
	return "instance_%d" % character.get_instance_id()


## 某个角色穿在身上的整套装备（栏位类型 → ItemBase）。
## 参数 character：团队里的某个 UnitStats。
## 返回值：字典；没穿任何东西（或角色为空）时返回**空字典**。
## 副作用：无（纯读）。⚠ 返回的是存储里的那个字典本体，**只读**，要改请走 equip_item/unequip_slot。
static func equipment_of(character: UnitStats) -> Dictionary:
	var key := character_key(character)
	if key.is_empty():
		return {}
	return Global.equipment_by_character.get(key, {})


## 某个角色的某个装备栏现在穿着什么。
## 参数 character：角色；slot_type：ItemBase.EquipType 的成员值（NONE 没有意义，返回 null）。
## 返回值：那件道具；空栏位返回 null。
## 副作用：无（纯读）。
static func equipment_in(character: UnitStats, slot_type: int) -> ItemBase:
	return equipment_of(character).get(slot_type)


## 这件道具现在能不能穿到这个角色身上：返回**空串** = 能穿；否则返回原因（界面直接显示）。
## 规则（以后扩展就加在这里，界面和真正执行共用同一份判定）：
##   · 没有选中角色 / 空道具 / 不能装备（EquipType.NONE）→ 说清楚原因；
##   · 不在背包里（可能正被别的角色穿着、或数据不同步）→ 说清楚原因。
## 参数 character：目标角色；item：要穿的道具。
static func item_can_equip(character: UnitStats, item: ItemBase) -> String:
	if character == null:
		return "现在没有选中角色。"
	if item == null:
		return "这件东西不存在。"
	if item.get_equip_type() == ItemBase.EquipType.NONE:
		return "「%s」不能装备。" % item.item_name
	if not Global.equipped_weapons.has(item):
		return "背包里没有「%s」。" % item.item_name
	return ""


## 把背包里的一件装备穿到这个角色对应的栏位（栏位上原来那件自动回背包）。
## 参数 character：目标角色；item：要穿的道具（必须已经在背包里，且 get_equip_type() != NONE）。
## 返回值：空串 = 穿成功；否则是不能穿的原因（原样给界面显示）。
## 副作用：改 Global.equipped_weapons（移出 item、放回旧装备）与
##        Global.equipment_by_character[角色的键]（写入/覆盖）。
## 注意：**交换**而不是"栏位已占用就报错"——玩家换装时最自然的期望是旧的回背包，
##   而不是先去脱一次。背包满也不会失败：旧装备腾出来的位置正好接住它。
static func equip_item(character: UnitStats, item: ItemBase) -> String:
	var why := item_can_equip(character, item)
	if not why.is_empty():
		return why
	var slot_type: int = item.get_equip_type()
	var key := character_key(character)
	var slots: Dictionary = Global.equipment_by_character.get(key, {})
	var old: ItemBase = slots.get(slot_type)
	Global.equipped_weapons.erase(item)
	if old != null:
		Global.equipped_weapons.append(old)
	slots[slot_type] = item
	Global.equipment_by_character[key] = slots      # 新角色第一次穿时要把这张表写回外层字典
	return ""


## 把某个角色某个栏位上的装备脱下来放回背包。
## 参数 character：角色；slot_type：ItemBase.EquipType 的成员值。
## 返回值：空串 = 脱成功；否则是不能脱的原因（角色为空 / 栏位空 / 背包满）。
## 副作用：改 Global.equipment_by_character（删栏位；整套空了就把角色键也删掉）与
##        Global.equipped_weapons（append 回背包）。
## 背包满时**不**脱：不然这件东西就没地方去了（宁可让玩家先卖一件腾一格）。
static func unequip_slot(character: UnitStats, slot_type: int) -> String:
	if character == null:
		return "现在没有选中角色。"
	var key := character_key(character)
	var slots: Dictionary = Global.equipment_by_character.get(key, {})
	var item: ItemBase = slots.get(slot_type)
	if item == null:
		return "%s的%s栏现在是空的。" % [character.name, ItemBase.equip_type_name(slot_type)]
	if Global.equipped_weapons.size() >= BAG_SLOTS:
		return "背包满了（%d 格都占着），先腾出一格再脱。" % BAG_SLOTS
	slots.erase(slot_type)
	if slots.is_empty():
		Global.equipment_by_character.erase(key)     # 一点东西都没穿了就别留着空表
	else:
		Global.equipment_by_character[key] = slots
	Global.equipped_weapons.append(item)
	return ""


## 背包里点了某件装备（WorldMap.equip_requested → 这里）：给**当前展示的角色**穿上，然后刷新背包。
## 参数 character：背包界面当前展示的角色；item：被点的道具。
## 副作用：成功后 Global.equipment_by_character / equipped_weapons 变化；
##   失败只把原因写回背包信息行。
func _on_equip_requested(character: UnitStats, item: ItemBase) -> void:
	var world := _current_world_map()
	var why := equip_item(character, item)
	var message := why
	if message.is_empty():
		message = "给%s穿上了「%s」（%s栏）。" % [character.name, item.item_name,
				ItemBase.equip_type_name(item.get_equip_type())]
	if world != null:
		world.notify_bag_changed(message)


## 点了已穿上的装备栏（WorldMap.unequip_requested → 这里）：从那个角色身上脱下来放回背包。
## 参数 character：那个角色；slot_type：ItemBase.EquipType 的成员值。
## 副作用：同 _on_equip_requested —— 成功后背包多一件、该角色的栏位变空，界面按新状态重建。
func _on_unequip_requested(character: UnitStats, slot_type: int) -> void:
	var world := _current_world_map()
	var item: ItemBase = equipment_in(character, slot_type)
	var who: String = character.name if character != null else ""
	var why := unequip_slot(character, slot_type)
	var message := why
	if message.is_empty():
		message = "从%s身上脱下了「%s」，已放回背包。" % [who, item.item_name if item != null else ""]
	if world != null:
		world.notify_bag_changed(message)


# ══════════════════════════════════════════════════════════
#  门派（拜师）
# ══════════════════════════════════════════════════════════
#  规则只有一份：五个门派的种族限制在 Global.SECTS 里，能不能拜由 can_join_sect() 判；
#  拜师面板只负责"把队员按能不能拜列出来"，**不自己再判一遍** —— 两处规则分叉是这类系统最常见的 bug。

## 某个角色当前的门派 id（"" = 无门派，默认状态）。
## 参数 character：角色；返回值：Global.SECTS 的键或空串。
static func sect_of(character: UnitStats) -> String:
	if character == null:
		return ""
	return String(Global.sect_by_character.get(character_key(character), ""))


## 这个角色现在能不能拜入这个门派。
## 参数 character：角色；sect_id：Global.SECTS 的键。
## 返回值：**空串 = 可以拜**；否则是不能拜的原因（可直接拿去显示，不用再拼文案）。
## 判定顺序：角色为空 → 门派不存在 → 已经有门派 → 种族不符。
## 为什么把"已有门派"排在种族前面：两种情况都拜不了，但"他已经有门派了"对玩家信息量更大
##   （而且一个角色同时只属于一个门派是硬规则；想改投得先做"叛出师门"，目前没做）。
static func can_join_sect(character: UnitStats, sect_id: String) -> String:
	if character == null:
		return "没有选中角色。"
	if not Global.is_sect(sect_id):
		return "没有这个门派。"
	var current := sect_of(character)
	if not current.is_empty():
		return "%s已经拜入%s了，不能改投他派。" % [character.name, Global.sect_name(current)]
	if not Global.sect_accepts(sect_id, character.race):
		return "%s是%s，%s只收%s。" % [character.name, character.race_name(),
				Global.sect_name(sect_id), Global.sect_races_text(sect_id)]
	return ""


## 让某个角色拜入某个门派。
## 参数/返回值同 can_join_sect（空串 = 成功）。
## 副作用：成功时写 Global.sect_by_character[character_key(character)] = sect_id，
##   并**自动学会该门派全部技能（1 级）**：Global.sect_skill_level_by_character[角色键] = 1。
## ⚠ 这是门派状态（和门派技能等级）的**唯一写入点**；界面只发请求（WorldMap.sect_join_requested）。
static func join_sect(character: UnitStats, sect_id: String) -> String:
	var why := can_join_sect(character, sect_id)
	if not why.is_empty():
		return why
	var key := character_key(character)
	Global.sect_by_character[key] = sect_id
	# 拜入门派 = 立刻学会本门 2 被动 + 3 主动（都是 1 级），之后随玩家升级一起长
	Global.sect_skill_level_by_character[key] = 1
	return ""


## 某个角色当前的门派技能等级（0 = 还没学/没门派；1..SECT_SKILL_MAX_LEVEL）。
## 一个门派的 5 个技能共享这一个等级（同时学会、一起升级）。
static func sect_skill_level(character: UnitStats) -> int:
	if character == null:
		return 0
	return int(Global.sect_skill_level_by_character.get(character_key(character), 0))


## 玩家升级时，把**所有已拜师角色**的门派技能等级 +gained（封顶 SECT_SKILL_MAX_LEVEL）。
## 参数 gained：这次升了几级。
## 副作用：改 Global.sect_skill_level_by_character。
## 为什么遍历整张表而不是只加队里那几个：团队名册会变，但"门派技能"是角色自己的进度，
##   角色离开团队再回来，技能等级也该跟着涨（和装备/门派一样的归属逻辑）。
static func _bump_sect_skill_levels(gained: int) -> void:
	if gained <= 0:
		return
	for key in Global.sect_skill_level_by_character.keys():
		var current := int(Global.sect_skill_level_by_character[key])
		Global.sect_skill_level_by_character[key] = mini(Global.SECT_SKILL_MAX_LEVEL, current + gained)


## 门派技能的一行摘要（属性面板用）："门派技能 Lv.3：太虚剑典 · 剑心通明 · …"。
## 没拜师时返回提示文字。
static func sect_skill_summary(character: UnitStats) -> String:
	var sect_id := sect_of(character)
	if sect_id.is_empty():
		return "门派技能：拜入门派后自动学习"
	var level := sect_skill_level(character)
	var names := Global.sect_skill_names(sect_id)
	return "门派技能 Lv.%d：%s" % [level, " · ".join(names)]


## 门派技能的完整说明（悬停提示用）：每个技能一行，主动技能带上"当前目标数"。
static func sect_skill_details(character: UnitStats) -> String:
	var sect_id := sect_of(character)
	if sect_id.is_empty():
		return "还没有门派 —— 去建邺城找五位掌门拜师。"
	var level := sect_skill_level(character)
	var lines: Array[String] = []
	for skill in Global.sect_passives(sect_id):
		lines.append("【被动】%s Lv.%d\n%s" % [skill["name"], level, skill["desc"]])
	for skill in Global.sect_actives(sect_id):
		var extra := ""
		if skill.has("targets") or bool(skill.get("targets_all", false)):
			extra = "（当前目标：%s）" % Global.sect_skill_targets_text(skill, level)
		lines.append("【主动】%s Lv.%d%s\n%s" % [skill["name"], level, extra, skill["desc"]])
	return "\n\n".join(lines)


## 拜师面板点了某个队员（WorldMap.sect_join_requested → 这里）。
## 参数 character：要点的那位队员；sect_id：那个 NPC 对应的门派。
## 副作用：成功后门派写入 Global（并学会本门技能）；无论成败都把结果文案交回地图。
func _on_join_sect_requested(character: UnitStats, sect_id: String) -> void:
	var world := _current_world_map()
	var why := join_sect(character, sect_id)
	var message := why
	if message.is_empty():
		message = "%s拜入%s，学会了本门 5 个技能（Lv.1）！" % [character.name, Global.sect_name(sect_id)]
	if world != null:
		world.notify_sect_changed(message)


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
		var copy := stats.duplicate() as UnitStats
		# 等级 + 基础属性 → 派生属性（见 derived_stats）。战斗读的就是这份最终值：
		#   气血 / 魔法 / 伤害 / 速度 直接覆盖；防御 / 躲避 / 法伤 以及二级属性只带进去（战斗还没用）。
		# 注意这里**不再**乘"每级 ×1.5%"的旧倍率 —— 成长全部由属性点承担。
		var d := derived_stats(stats)
		copy.health = maxf(1.0, float(d["hp"]))
		copy.damage = maxf(1.0, float(d["damage"]))
		copy.mana = maxf(1.0, float(d["mana"]))
		copy.speed = maxf(1.0, float(d["speed"]))
		copy.defense = float(d["defense"])
		copy.dodge = float(d["dodge"])
		copy.spell_damage = float(d["spell_damage"])
		copy.crit_rate = float(d["crit_rate"])
		copy.crit_damage_bonus = float(d["crit_damage_bonus"])
		copy.seal_hit = float(d["seal_hit"])
		copy.healing = float(d["healing"])
		copy.crit_resist = float(d["crit_resist"])
		copy.crit_damage_resist = float(d["crit_damage_resist"])
		copy.seal_resist = float(d["seal_resist"])
		copy.block_value = float(d["block_value"])
		# 门派被动（太虚剑典 +伤害、剑心通明 +暴击 …）按门派技能等级叠上去
		_apply_sect_passives(copy, stats)
		out.append(copy)
	return out


## 把门派**被动技能**的加成叠到战斗副本上（按该角色的门派技能等级）。
## 参数 copy：这一场我方单位的副本；source：原 UnitStats（查门派和技能等级用）。
## 副作用：改 copy 的 damage/health/crit_rate/speed/defense/spell_damage/healing/seal_hit。
## 为什么作用在副本上：和等级/属性一样，战斗只该改副本，不能污染 .tres；
##   而且加成是"这一场才生效"的临时值。
static func _apply_sect_passives(copy: UnitStats, source: UnitStats) -> void:
	var sect_id := sect_of(source)
	if sect_id.is_empty():
		return
	var level := sect_skill_level(source)
	if level <= 0:
		return
	for skill in Global.sect_passives(sect_id):
		var amount := float(skill.get("per_level", 0.0)) * level
		match String(skill.get("stat", "")):
			"damage_pct":
				copy.damage *= 1.0 + amount / 100.0
			"hp_pct":
				copy.health *= 1.0 + amount / 100.0
			"crit_rate":
				copy.crit_rate += amount
			"crit_damage_bonus":
				copy.crit_damage_bonus += amount
			"speed":
				copy.speed += amount
			"defense":
				copy.defense += amount
			"spell_damage":
				copy.spell_damage += amount
			"healing":
				copy.healing += amount
			"seal_hit":
				copy.seal_hit += amount


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

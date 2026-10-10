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

signal map_changed(map_id: String)

const TITLE_SCENE := preload("res://scenes/main/title_screen.tscn")
const WORLD_MAP_SCENE := preload("res://scenes/world/world_map.tscn")
const BATTLE_SCENE := preload("res://scenes/battle/battle.tscn")
const ARENA_SCENE := preload("res://scenes/arena/arena.tscn")
const SELECTION_SCENE := preload("res://scenes/ui/selection_panel/selection_panel.tscn")

@export var maps: Array[MapData] = []
@export var start_map_id := ""                 # 留空 = maps[0].id
@export var enemy_pool: Array[UnitStats] = []  # 某张图没配 enemy_pool 时用这个
@export var enemy_scale_per_map := 0.15        # 每前进一张图，敌人血量/伤害 +15%
@export var coin_reward_per_map := 40          # 通关奖励 = coin_reward_per_map * 地图序号
@export var starting_coins := 500

@onready var world_root: Node2D = %WorldRoot
@onready var ui_root: CanvasLayer = %UIRoot
@onready var fade: ColorRect = %Fade

var current_map_id := ""
var party: Array[UnitStats] = []
var cleared_maps: Dictionary = {}              # map_id -> true
var in_battle := false

var _last_result := ""
var _map_positions: Dictionary = {}            # map_id -> 玩家离开时的归一化位置（战斗回来原地）


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

func _first_map_id() -> String:
	if not start_map_id.is_empty() and get_map(start_map_id) != null:
		return start_map_id
	if maps.is_empty():
		return ""
	return maps[0].id


func get_map(map_id: String) -> MapData:
	for map in maps:
		if map != null and map.id == map_id:
			return map
	return null


func map_index(map_id: String) -> int:
	for i in maps.size():
		if maps[i] != null and maps[i].id == map_id:
			return i
	return 0


## 当前地图的难度档（第 1 张 = 1）
func map_difficulty() -> int:
	return map_index(current_map_id) + 1


# ══════════════════════════════════════════════════════════
#  屏幕切换（带淡入淡出）
# ══════════════════════════════════════════════════════════

func _clear_screens() -> void:
	for parent in [world_root, ui_root]:
		for child in parent.get_children():
			parent.remove_child(child)
			child.queue_free()


func _swap(screen: Node, parent: Node = null) -> void:
	var target: Node = parent if parent != null else ui_root
	await fade_out()
	_clear_screens()
	target.add_child(screen)
	await fade_in()


func fade_out(duration := 0.3) -> void:
	fade.mouse_filter = Control.MOUSE_FILTER_STOP
	var tween := create_tween()
	tween.tween_property(fade, "modulate:a", 1.0, duration)
	await tween.finished


func fade_in(duration := 0.3) -> void:
	var tween := create_tween()
	tween.tween_property(fade, "modulate:a", 0.0, duration)
	await tween.finished
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE


# ══════════════════════════════════════════════════════════
#  流程各站
# ══════════════════════════════════════════════════════════

func show_title() -> void:
	var screen := TITLE_SCENE.instantiate() as TitleScreen
	screen.last_result = _last_result
	screen.new_game_requested.connect(start_new_game)
	screen.arena_requested.connect(enter_arena)
	screen.quit_requested.connect(func() -> void: get_tree().quit())
	await _swap(screen)


func start_new_game() -> void:
	party.clear()
	cleared_maps.clear()
	_map_positions.clear()
	_last_result = ""
	current_map_id = _first_map_id()
	Global.coins = starting_coins
	Global.equipped_weapons.clear()
	Global.main_player_selected = null
	Global.main_weapon_selected = null
	show_character_select()


func show_character_select() -> void:
	var panel := SELECTION_SCENE.instantiate() as SelectionPanel
	panel.on_selection_completed.connect(_on_selection_completed)
	await _swap(panel)


func _on_selection_completed() -> void:
	if Global.main_player_selected == null:
		push_warning("GameRoot: 还没选角色")
		return
	party = [Global.main_player_selected]
	Global.equipped_weapons.clear()
	if Global.main_weapon_selected != null:
		Global.equipped_weapons.append(Global.main_weapon_selected)
	map_changed.emit(current_map_id)
	show_map()


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
	world.setup(map, party, Global.coins, result_text, cleared_maps.has(map.id), _map_names(), from_map_id)
	world.battle_requested.connect(enter_battle)
	world.travel_requested.connect(travel_to)
	world.back_to_title_requested.connect(show_title)
	await _swap(world, world_root)


## 前往另一张地图（地图里跟 NPC 对话选目的地，最终走到这里）
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


func _map_names() -> Dictionary:
	var names := {}
	for map in maps:
		if map != null:
			names[map.id] = map.display_name
	return names


func _current_world_map() -> WorldMap:
	for child in world_root.get_children():
		if child is WorldMap:
			return child
	return null


## 记住玩家在这张图站的位置（传送前 / 进战斗前调用）
func _remember_position() -> void:
	var world := _current_world_map()
	if world != null:
		_map_positions[current_map_id] = world.player_normalized()


func enter_battle() -> void:
	if party.is_empty():
		push_warning("GameRoot: 队伍是空的，先进选人界面")
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


func enter_arena() -> void:
	# 保留原来自成一体的竞技场模式（内置选人/波次/商店）
	var arena := ARENA_SCENE.instantiate()
	await _swap(arena, world_root)


# ══════════════════════════════════════════════════════════
#  战斗结算
# ══════════════════════════════════════════════════════════

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

func _make_player_team() -> Array[UnitStats]:
	var out: Array[UnitStats] = []
	for stats in party:
		if stats == null:
			continue
		# duplicate：战斗改的是副本，不污染 .tres（以后做"战斗结束回写血量"也方便）
		out.append(stats.duplicate() as UnitStats)
	return out


func _make_enemy_team() -> Array[UnitStats]:
	var out: Array[UnitStats] = []
	var map := get_map(current_map_id)
	var pool: Array[UnitStats] = map.enemy_pool if map != null and not map.enemy_pool.is_empty() else enemy_pool
	if pool.is_empty():
		return out

	var difficulty := map_difficulty()
	var count: int = clampi(1 + (difficulty - 1) / 2, 1, 4)   # 和 battle 的 4 个站位对齐
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

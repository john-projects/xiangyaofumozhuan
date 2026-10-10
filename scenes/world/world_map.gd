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

signal battle_requested
signal travel_requested(map_id: String)
signal back_to_title_requested

const NPC_SCENE := preload("res://scenes/world/world_npc.tscn")
const EDGE_MARGIN := 60.0

@export var move_speed := 380.0
@export var dash_multiplier := 1.9
@export var interact_radius := 150.0
@export var result_toast_time := 3.0

var _map: MapData
var _party: Array[UnitStats] = []
var _coins := 0
var _result := ""
var _cleared := false
var _from_map_id := ""
var _map_names: Dictionary = {}

## GameRoot 可以在 add_child 之前设这个：非 INF 时优先用它当出生点（归一化坐标）
## 用来实现"打完战斗回到地图时还站在原地"
var spawn_override := Vector2.INF

var _map_size := Vector2.ZERO
var _npcs: Array[WorldNPC] = []
var _nearest: WorldNPC = null
var _panel_open := false

@onready var map_sprite: Sprite2D = %MapSprite
@onready var player: Node2D = %Player
@onready var player_sprite: Sprite2D = %PlayerSprite
@onready var player_fallback: Polygon2D = %PlayerFallback
@onready var camera: Camera2D = %Camera
@onready var map_name_label: Label = %MapNameLabel
@onready var coins_label: Label = %CoinsLabel
@onready var hint_label: Label = %HintLabel
@onready var result_label: Label = %ResultLabel
@onready var battle_button: Button = %BattleButton
@onready var back_button: Button = %BackButton
@onready var panel: Panel = %TravelPanel
@onready var panel_name: Label = %PanelName
@onready var panel_dialogue: Label = %PanelDialogue
@onready var panel_buttons: VBoxContainer = %PanelButtons
@onready var close_button: Button = %CloseButton


## 只存数据；搭建放到 _ready（GameRoot 是先 setup 再 add_child）
func setup(p_map: MapData, p_party: Array[UnitStats], p_coins: int, result_text: String,
		p_cleared: bool, p_map_names: Dictionary, p_from_map_id := "") -> void:
	_map = p_map
	_party = p_party
	_coins = p_coins
	_result = result_text
	_cleared = p_cleared
	_map_names = p_map_names
	_from_map_id = p_from_map_id


func _ready() -> void:
	if _map == null:
		push_warning("WorldMap: 没有拿到 MapData")
		return

	# ── 地图 ──────────────────────────────────────────────
	map_sprite.texture = _map.texture
	map_sprite.centered = false
	map_sprite.scale = Vector2.ONE * _map.map_scale
	var tex_size := Vector2.ZERO
	if _map.texture != null:
		tex_size = Vector2(_map.texture.get_size())
	_map_size = tex_size * _map.map_scale
	if _map_size == Vector2.ZERO:
		push_warning("WorldMap: %s 没配 texture，走不动也看不到东西" % _map.display_name)

	# ── 玩家 ──────────────────────────────────────────────
	var icon := _player_icon()
	player_sprite.texture = icon
	player_fallback.visible = icon == null
	player.position = _world_pos(_spawn_normalized())

	# ── 相机（挂在玩家下面，自动跟随）────────────────────
	_setup_camera()

	# ── NPC ───────────────────────────────────────────────
	_spawn_npcs()

	# ── UI ────────────────────────────────────────────────
	battle_button.pressed.connect(_on_battle_pressed)
	back_button.pressed.connect(_on_back_pressed)
	close_button.pressed.connect(_close_panel)
	battle_button.disabled = not _map.battle_enabled
	map_name_label.text = "%s%s" % [_map.display_name, "（已通关）" if _cleared else ""]
	coins_label.text = "金币：%d" % _coins
	hint_label.visible = false
	panel.hide()
	_show_result()


func _player_icon() -> Texture2D:
	var stats := Global.main_player_selected
	return stats.icon if stats != null else null


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

func _world_pos(normalized: Vector2) -> Vector2:
	return normalized * _map_size


## 出生点：优先用 GameRoot 指定的（战斗回来原地），否则"从某张图走过来的"就出现在那张图的 NPC 旁边
func _spawn_normalized() -> Vector2:
	if spawn_override != Vector2.INF:
		return spawn_override
	if not _from_map_id.is_empty():
		for npc_data in _map.npcs:
			if npc_data != null and npc_data.destinations.has(_from_map_id):
				return npc_data.position + Vector2(0.0, 0.04)
	return _map.spawn_point


## 玩家当前所在位置（归一化），GameRoot 用它记住"离开这张图时站在哪"
func player_normalized() -> Vector2:
	if _map_size == Vector2.ZERO:
		return Vector2.ZERO
	return player.position / _map_size


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
		var dests: Array[String] = [_map.next_id]
		fallback.destinations = dests
		fallback.teleport_label = "前往"
		_add_npc(fallback)


func _add_npc(npc_data: MapNPC) -> void:
	var npc := NPC_SCENE.instantiate() as WorldNPC
	# 直接挂在 WorldMap 下（WorldMap 开了 y_sort，玩家才能绕到 NPC 身后/身前）
	add_child(npc)
	npc.setup(npc_data)
	npc.position = _world_pos(npc_data.position)
	_npcs.append(npc)


func _update_nearest() -> void:
	var best: WorldNPC = null
	var best_distance := interact_radius
	for npc in _npcs:
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

	if _nearest != null:
		hint_label.text = "按 E 与 %s 交谈" % _nearest.data.display_name
		hint_label.visible = true
	else:
		hint_label.visible = false


# ══════════════════════════════════════════════════════════
#  每帧：走动
# ══════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if _map_size == Vector2.ZERO or _panel_open:
		return
	_move_player(delta)
	_update_nearest()


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
#  交互
# ══════════════════════════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		_debug_print_normalized()
		get_viewport().set_input_as_handled()
		return

	if _panel_open:
		if event.is_action_pressed("ui_cancel"):
			_close_panel()
			get_viewport().set_input_as_handled()
		return

	if _nearest != null and _is_interact_event(event):
		_open_panel(_nearest)
		get_viewport().set_input_as_handled()


## 支持"项目里配了 interact 动作就用它"，没配则用 E / Enter
func _is_interact_event(event: InputEvent) -> bool:
	if InputMap.has_action(&"interact") and event.is_action_pressed(&"interact"):
		return true
	return event is InputEventKey and event.pressed and not event.echo \
		and (event.keycode == KEY_E or event.keycode == KEY_ENTER)


func _open_panel(npc: WorldNPC) -> void:
	_panel_open = true
	panel_name.text = npc.data.display_name
	panel_dialogue.text = npc.data.dialogue

	for child in panel_buttons.get_children():
		panel_buttons.remove_child(child)
		child.queue_free()

	if npc.data.destinations.is_empty():
		var none := Label.new()
		none.text = "（这个 NPC 目前不送人去别处）"
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		panel_buttons.add_child(none)
	else:
		for dest_id in npc.data.destinations:
			var button := Button.new()
			button.text = "%s %s" % [npc.data.teleport_label, _map_names.get(dest_id, dest_id)]
			button.custom_minimum_size = Vector2(300, 52)
			button.add_theme_font_size_override("font_size", 22)
			button.pressed.connect(_on_destination_pressed.bind(dest_id))
			panel_buttons.add_child(button)

	panel.show()


func _close_panel() -> void:
	_panel_open = false
	panel.hide()


func _on_destination_pressed(map_id: String) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	_close_panel()
	travel_requested.emit(map_id)


func _on_battle_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	battle_requested.emit()


func _on_back_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	back_to_title_requested.emit()


## 调试：把鼠标位置换算成地图归一化坐标打出来（填 spawn_point / NPC.position 用）
func _debug_print_normalized() -> void:
	if _map_size == Vector2.ZERO:
		return
	var normalized := get_global_mouse_position() / _map_size
	print("[WorldMap] %s 鼠标归一化坐标: Vector2(%.3f, %.3f)" % [_map.display_name, normalized.x, normalized.y])

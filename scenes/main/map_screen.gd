extends Control
class_name MapScreen

## ⚠️ 已废弃（2026-10）：地图改成了"可探索世界地图" scenes/world/world_map.tscn
##    —— 玩家能走动、相机跟随、靠跟 NPC 对话传送（且双向）。
##    本文件保留仅作参考，GameRoot 已经不再加载它，可以直接删掉。

## 地图界面：显示当前地图图片 + 可点击的传送点 + 顶部信息 + 底部按钮
##
## 传送点位置来自 MapData.exit_center / exit_size（归一化 0~1，相对地图图片），
## 运行时换算成像素并贴在图片对应位置，所以窗口怎么缩放都跟着走。
##
## 调传送点坐标的小技巧：运行游戏进地图后，把鼠标移到图上的出口处，按 F1，
## 控制台会打印该点的归一化坐标，把 x/y 填进对应 .tres 的 exit_center 即可。

signal battle_requested
signal travel_requested(next_id: String)
signal back_to_title_requested

var _map: MapData
var _party: Array[UnitStats] = []
var _coins := 0
var _result := ""
var _cleared := false

var _exit_button: Button

@onready var map_image: TextureRect = %MapImage
@onready var hotspots: Control = %Hotspots
@onready var map_name_label: Label = %MapNameLabel
@onready var coins_label: Label = %CoinsLabel
@onready var party_label: Label = %PartyLabel
@onready var result_label: Label = %ResultLabel
@onready var battle_button: Button = %BattleButton
@onready var next_button: Button = %NextButton
@onready var back_button: Button = %BackButton


## 只存数据；渲染放到 _ready（GameRoot 是先 setup 再 add_child）
func setup(map: MapData, party: Array[UnitStats], coins: int, result_text: String, cleared: bool) -> void:
	_map = map
	_party = party
	_coins = coins
	_result = result_text
	_cleared = cleared


func _ready() -> void:
	_render()
	battle_button.pressed.connect(_on_battle_pressed)
	next_button.pressed.connect(_on_next_pressed)
	back_button.pressed.connect(_on_back_pressed)
	resized.connect(_layout_exit)
	map_image.resized.connect(_layout_exit)      # 容器排版变化时也要跟着挪
	_layout_exit()
	call_deferred("_layout_exit")                # 等 AspectRatioContainer 完成第一次排版


func _render() -> void:
	if _map == null:
		push_warning("MapScreen: 没有拿到 MapData")
		return

	map_image.texture = _map.texture
	map_name_label.text = "%s%s" % [_map.display_name, "（已通关）" if _cleared else ""]
	coins_label.text = "金币：%d" % _coins
	result_label.text = _result
	result_label.visible = not _result.is_empty()

	var lines: Array[String] = []
	for stats in _party:
		if stats != null:
			lines.append("%s    HP %.0f    ATK %.0f    SPD %d" % [stats.name, stats.health, stats.damage, int(stats.speed)])
	party_label.text = "出战队伍：\n" + ("\n".join(lines) if not lines.is_empty() else "（还没选角色）")

	battle_button.disabled = not _map.battle_enabled
	next_button.disabled = _map.next_id.is_empty()
	if not _map.next_id.is_empty():
		next_button.text = _map.exit_label
	_create_exit_button()


func _create_exit_button() -> void:
	if _exit_button != null and is_instance_valid(_exit_button):
		_exit_button.queue_free()
		_exit_button = null
	if _map.next_id.is_empty():
		return

	_exit_button = Button.new()
	_exit_button.text = _map.exit_label
	_exit_button.add_theme_font_size_override("font_size", 22)
	_exit_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_exit_button.pressed.connect(_on_next_pressed)
	hotspots.add_child(_exit_button)


## 把归一化坐标换算成像素，贴在图片上（窗口缩放时会重算）
func _layout_exit() -> void:
	if _exit_button == null or not is_instance_valid(_exit_button) or _map == null:
		return
	var rect := map_image.get_rect()                     # 图片实际显示区域（MapArea 里那块 16:9）
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var size := Vector2(0.16, 0.12) * rect.size          # 旧版热点大小（MapData.exit_size 已移除）
	var center := rect.position + _map.exit_center * rect.size
	_exit_button.size = size
	_exit_button.position = center - size * 0.5


# ══════════════════════════════════════════════════════════
#  按钮
# ══════════════════════════════════════════════════════════

func _on_battle_pressed() -> void:
	_click()
	battle_requested.emit()


func _on_next_pressed() -> void:
	if _map == null or _map.next_id.is_empty():
		return
	_click()
	travel_requested.emit(_map.next_id)


func _on_back_pressed() -> void:
	_click()
	back_to_title_requested.emit()


func _click() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)


## 调试：把鼠标所在位置换算成地图归一化坐标打出来，方便填 exit_center
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		var rect := map_image.get_rect()
		if rect.size.x <= 0.0:
			return
		var n := (get_local_mouse_position() - rect.position) / rect.size
		print("[MapScreen] %s 鼠标归一化坐标: Vector2(%.3f, %.3f)" % [_map.display_name, n.x, n.y])
		get_viewport().set_input_as_handled()

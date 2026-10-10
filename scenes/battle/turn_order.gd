extends Panel
class_name TurnOrder

## 出手顺序条：按 Battle 给的队列显示图标，当前出手的加亮边框。
## 单位数量不多时直接重建最省事；上百个单位再改成对象池（复用节点只改内容）。

const PLAYER_BORDER := Color(0.35, 0.85, 0.45)
const ENEMY_BORDER := Color(0.95, 0.42, 0.42)
const CURRENT_BORDER := Color(1.0, 0.85, 0.3)
const DEAD_ALPHA := 0.3

@onready var icons: HBoxContainer = %Icons

var _queue: Array = []
var _current: BattleUnit


func update_order(units: Array) -> void:
	_queue = units
	_rebuild()


func set_current(unit: BattleUnit) -> void:
	_current = unit
	_rebuild()


func clear_current() -> void:
	_current = null
	_rebuild()


func _rebuild() -> void:
	# 先 remove_child 再 queue_free：否则本帧结束前容器里会同时存在新旧图标
	for child in icons.get_children():
		icons.remove_child(child)
		child.queue_free()

	for unit in _queue:
		if not is_instance_valid(unit):
			continue
		icons.add_child(_make_icon(unit, unit == _current))


func _make_icon(unit: BattleUnit, is_current: bool) -> Control:
	var size := 64.0 if is_current else 52.0

	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(size, size)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.10, 0.12, 0.92)
	style.set_corner_radius_all(10)
	style.set_border_width_all(3 if is_current else 2)
	style.border_color = CURRENT_BORDER if is_current else (PLAYER_BORDER if unit.is_player else ENEMY_BORDER)
	panel.add_theme_stylebox_override("panel", style)

	var tex := TextureRect.new()
	tex.texture = unit.stats.icon if unit.stats != null else null
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(tex)
	tex.set_anchors_preset(Control.PRESET_FULL_RECT)

	if not unit.alive:
		panel.modulate.a = DEAD_ALPHA

	return panel

extends CanvasLayer
## 群星陨落 · 全屏氛围层（施法时播一次，1.5 秒后自毁）。
##
## 拼图法：不画任何贴图，全靠代码画——
##   · ColorRect：全屏压暗（模拟"夜幕降临"）；
##   · MeteorField：一堆斜向坠落的流星线（_draw 直接画线，比几十个精灵省事）。
## 挂在 CanvasLayer 上，所以不受相机/震屏影响，永远铺满屏幕。
## 层级用 0：盖在战场之上、战斗 UI（UI 层 = 1）之下。

const DURATION := 2.4
const FADE_IN := 0.18
const FADE_OUT := 0.55
## 压暗程度（0 = 不压暗，1 = 全黑）。
const DARKEN := 0.68

var _t := 0.0
var _rect: ColorRect
var _field: MeteorField


## 屏幕上的流星线：位置随机、往左下斜落，落出屏幕就从顶部重来。
class MeteorField extends Node2D:
	var drops: Array[Dictionary] = []

	func _process(delta: float) -> void:
		for d in drops:
			d["pos"] = d["pos"] + d["vel"] * delta
			var pos: Vector2 = d["pos"]
			if pos.y > 1000.0 or pos.x < -80.0:
				d["pos"] = Vector2(randf_range(200.0, 1900.0), randf_range(-700.0, -80.0))
		queue_redraw()

	func _draw() -> void:
		for d in drops:
			var pos: Vector2 = d["pos"]
			var len: float = d["len"]
			var col: Color = d["color"]
			draw_line(pos, pos + Vector2(-len * 0.32, len), col, d["width"])


func _ready() -> void:
	layer = 0
	_rect = ColorRect.new()
	_rect.name = "Dark"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.color = Color(0.02, 0.03, 0.08, 0.0)
	add_child(_rect)

	_field = MeteorField.new()
	_field.name = "Meteors"
	add_child(_field)
	for i in 90:
		_field.drops.append({
			"pos": Vector2(randf_range(200.0, 1900.0), randf_range(-700.0, 900.0)),
			"vel": Vector2(randf_range(-520.0, -380.0), randf_range(1100.0, 1600.0)),
			"len": randf_range(28.0, 90.0),
			"width": randf_range(1.5, 3.5),
			"color": Color(0.75, 0.85, 1.0, randf_range(0.25, 0.75)),
		})


func _process(delta: float) -> void:
	_t += delta
	# 先淡入、后淡出，中间保持最暗
	var fade_in := clampf(_t / FADE_IN, 0.0, 1.0)
	var fade_out := clampf((DURATION - _t) / FADE_OUT, 0.0, 1.0)
	_rect.color.a = DARKEN * fade_in * fade_out
	_field.modulate.a = fade_in * fade_out
	if _t >= DURATION:
		queue_free()

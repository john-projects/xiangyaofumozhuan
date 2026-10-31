extends Node2D
## 幽火：我方角色阵亡后留在原地的一团鬼火。
##
## 为什么用 _draw() 画而不是贴图/粒子：
##   1. 不需要额外美术资源，颜色/大小/飘动都能直接调
##   2. 全部用圆和三角形这类**凸图形**拼 —— 不会出现多边形自交的渲染瑕疵
##   3. 加法混合（见 _ready 的 CanvasItemMaterial）叠在战斗背景上就是发光效果
##
## 用法：instantiate 出来、设好 global_position、add_child()，它会自己一直燃烧。
## **不会自行 queue_free** —— 战斗结束随场景一起卸载。

## 火焰整体半径（像素）。
@export var radius := 42.0
## 一次亮度呼吸的周期（秒）。
@export var pulse_period := 1.6
## 火焰横向摆动幅度（像素）。
@export var sway := 5.0
## 外圈光晕色 / 火身色 / 焰心色。
@export var glow_color := Color(0.22, 0.70, 1.0, 0.30)
@export var body_color := Color(0.42, 0.88, 1.0, 0.60)
@export var core_color := Color(0.92, 0.99, 1.0, 0.95)
## 火星数量与上升高度。
@export var spark_count := 8
@export var spark_rise := 64.0

var _t := 0.0
var _sparks: Array = []


func _ready() -> void:
	# 加法混合：不加后处理也有"发光"感，且在明亮背景上也不会糊成一团黑
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	z_index = 30
	for i in spark_count:
		_sparks.append({
			"phase": randf(),
			"x": randf_range(-0.7, 0.7),
			"size": randf_range(0.5, 1.1),
		})


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	# 呼吸：亮度和体积一起起伏
	var b := 1.0 + 0.12 * sin(_t / pulse_period * TAU)
	var r := radius * b
	# 整体轻摆（两个不同频率叠加，避免看出循环）
	var ox := sway * sin(_t * 1.7) + sway * 0.35 * sin(_t * 3.9)
	var base := Vector2(ox, 0.0)

	# ① 外圈光晕：三层同心圆，越外越淡
	for i in 3:
		var k := 1.0 + i * 0.34
		var c := glow_color
		c.a *= 1.0 - i * 0.30
		draw_circle(base + Vector2(0, -r * 0.55), r * k, c)

	# ② 火身：下大上小的两个圆 + 顶部一个三角形，拼出水滴轮廓（都是凸形）
	draw_circle(base + Vector2(0, -r * 0.42), r * 0.72, body_color)
	draw_circle(base + Vector2(ox * 0.6, -r * 1.02), r * 0.46, body_color)
	var tip := PackedVector2Array([
		base + Vector2(-r * 0.30, -r * 1.20),
		base + Vector2(r * 0.30, -r * 1.20),
		base + Vector2(ox * 1.6, -r * 1.85),
	])
	draw_colored_polygon(tip, body_color)

	# ③ 焰心：小而亮，偏下
	draw_circle(base + Vector2(ox * 0.4, -r * 0.50), r * 0.26, core_color)

	# ④ 火星：从火身上方飘起，越飘越淡越小
	for s in _sparks:
		var p := fmod(float(s["phase"]) + _t / 1.9, 1.0)
		var y := -r * 1.15 - p * spark_rise
		var x := float(s["x"]) * r * (0.9 + p * 0.7) + ox * 1.8
		var c := core_color
		c.a *= (1.0 - p) * 0.8
		draw_circle(Vector2(x, y), 2.6 * float(s["size"]) * (1.0 - p * 0.5), c)

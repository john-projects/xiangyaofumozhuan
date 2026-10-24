extends Node2D
## 缥缈剑指（piaomiao_jianzhi）· 多目标：剑丝穿云 + 冰莲绽放。
##
## 时间轴（总 1.50s）：
##   0.00–0.28  指尖聚气（向内收束的光点）
##   0.18–0.60  三道剑丝自左上斜刺而入，切开云雾
##   0.35–1.00  冰莲绽放（内外两层花瓣反向旋转）
##   0.50–1.20  花瓣飘散
##   1.05–1.50  余韵光尘
##
## 用法：挂到每个被命中的目标脚下（target_effect_scene）。

const DURATION := 1.50
const PINK := Color(1.0, 0.55, 0.88)
const JADE := Color(0.42, 1.0, 0.96)
const GOLD := Color(1.0, 0.8, 0.4)

var _t := 0.0
var _tint := Color(0.85, 0.8, 1.0)


func _ready() -> void:
	z_index = 5
	# 加法混合：仙法都是发光体，叠在场景上才亮
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat


func play(tint: Color = Color(0.85, 0.8, 1.0), _count: int = 0) -> void:
	_tint = tint
	_t = 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _t >= DURATION:
		queue_free()


func _draw() -> void:
	_draw_charge()
	_draw_silk_blades()
	_draw_ice_lotus()
	_draw_petals()
	_draw_dust()


## ① 聚气：一圈向内收束的细光丝。
func _draw_charge() -> void:
	var p := clampf(_t / 0.28, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var radius := 70.0 * (1.0 - p) + 8.0
	var alpha := p * (1.0 - p) * 4.0
	for i in 10:
		var a := TAU * float(i) / 10.0 + _t * 2.0
		var dir := Vector2(cos(a), sin(a))
		FxDraw.streak(self, dir * radius, dir * (radius * 0.25), 2.0,
				Color(JADE.r, JADE.g, JADE.b, alpha * 0.7))
	FxDraw.glow(self, Vector2.ZERO, 18.0 + 10.0 * p, Color(1, 1, 1, alpha * 0.5), 4)


## ② 剑丝：三道极细的光丝斜穿而入，带收尖拖尾。
func _draw_silk_blades() -> void:
	var angles := [-0.42, -0.28, -0.14]
	for i in angles.size():
		var start: float = 0.18 + 0.05 * float(i)
		var p := (_t - start) / 0.42
		if p < 0.0 or p > 1.0:
			continue
		var alpha := 1.0 - p
		var dir := Vector2(cos(angles[i]), sin(angles[i]))
		var head := -dir * 320.0 + dir * 660.0 * p
		var tail := head - dir * 220.0
		FxDraw.taper(self, tail, head, 9.0 * alpha + 2.0, 1.0,
				Color(JADE.r, JADE.g, JADE.b, alpha * 0.85))
		FxDraw.taper(self, tail + dir * 40.0, head, 3.0 * alpha + 1.0, 0.6,
				Color(1, 1, 1, alpha * 0.95))
		# 切开云雾的痕迹
		var nrm := Vector2(-dir.y, dir.x)
		FxDraw.streak(self, -nrm * 26.0 * p, nrm * 26.0 * p, 8.0 * alpha,
				Color(PINK.r, PINK.g, PINK.b, alpha * 0.35))


## ③ 冰莲：内层六瓣 + 外层八瓣，反向旋转，边缘带高光。
func _draw_ice_lotus() -> void:
	var p := clampf((_t - 0.35) / 0.65, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var ease_p := 1.0 - pow(1.0 - p, 3.0)
	var alpha := (1.0 - p) * 0.9
	var radius := 96.0 * ease_p
	var c := Color(JADE.r, JADE.g, JADE.b, alpha * 0.75)
	FxDraw.lotus(self, Vector2.ZERO, radius, 8, _t * 1.4, c, 0.24)
	var inner := Color(PINK.r, PINK.g, PINK.b, alpha * 0.7)
	FxDraw.lotus(self, Vector2.ZERO, radius * 0.62, 6, -_t * 2.0 + 0.3, inner, 0.22)
	var white := Color(1, 1, 1, alpha * 0.55)
	FxDraw.lotus(self, Vector2.ZERO, radius * 0.3, 5, _t * 2.6, white, 0.3)
	FxDraw.glow(self, Vector2.ZERO, radius * 0.55, Color(GOLD.r, GOLD.g, GOLD.b, alpha * 0.25), 4)


## ④ 花瓣飘散：从花心向外飘出的小花瓣，边转边落。
func _draw_petals() -> void:
	var p := clampf((_t - 0.50) / 0.70, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var alpha := (1.0 - p) * 0.85
	for i in 14:
		var a := TAU * float(i) / 14.0 + float(i) * 0.8
		var r := 30.0 + 110.0 * p
		var pos := Vector2(cos(a) * r, sin(a) * r * 0.6 - 20.0 * p)
		var ang := a + _t * 3.0
		FxDraw.blade(self, pos, 12.0, 5.0, ang,
				Color(PINK.r, PINK.g, PINK.b, alpha * 0.8))


## ⑤ 余韵光尘：稀疏小点缓缓上浮。
func _draw_dust() -> void:
	var p := clampf((_t - 1.00) / 0.50, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var alpha := (1.0 - p) * 0.75
	for i in 16:
		var a := TAU * float(i) / 16.0 + 0.5
		var r := 20.0 + 60.0 * p
		var pos := Vector2(cos(a) * r, sin(a) * r * 0.5 - 50.0 * p)
		draw_circle(pos, 1.6, Color(1, 1, 1, alpha))

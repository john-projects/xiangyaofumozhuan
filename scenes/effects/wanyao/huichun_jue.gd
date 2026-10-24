extends Node2D
## 回春诀（huichun_jue）· 单体治疗：青草灵芝 + 治愈光柱 + 叶片环绕。
##
## 时间轴（总 1.80s）：
##   0.00–0.45  地面冒出青草与灵芝
##   0.25–1.10  翠绿光柱自脚下升起，托住目标
##   0.35–1.30  叶片与露珠螺旋上升
##   1.10–1.80  原地留下一圈金绿光环（表示持续回血）
##
## 用法：治疗/持续回血，Battle 给每个被治疗的队友各放一个。

const DURATION := 1.80
## 万药谷配色：草木青碧 + 暖金 + 乳白
const LEAF := Color(0.55, 1.0, 0.62)
const GOLD := Color(1.0, 0.85, 0.48)
const MIST := Color(0.85, 1.0, 0.92)

var _t := 0.0
var _tint := Color(0.7, 1.0, 0.8)


func _ready() -> void:
	z_index = 4
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat


func play(tint: Color = Color(0.7, 1.0, 0.8), _count: int = 0) -> void:
	_tint = tint
	_t = 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _t >= DURATION:
		queue_free()


func _draw() -> void:
	_draw_grass()
	_draw_pillar()
	_draw_leaves()
	_draw_ring()


## ① 青草：叶片从地面向上"长"出来（长度随进度变长）。
func _draw_grass() -> void:
	var p := clampf(_t / 0.45, 0.0, 1.0)
	if p <= 0.0:
		return
	var alpha := clampf(1.0 - (_t - 1.2) / 0.6, 0.0, 1.0) * 0.9
	for i in 9:
		var a := TAU * float(i) / 9.0 + 0.4
		var len := (34.0 + 12.0 * sin(float(i) * 2.1)) * (1.0 - pow(1.0 - p, 2.0))
		var base := Vector2(cos(a) * (26.0 + 8.0 * sin(float(i))), 6.0 + sin(a) * 8.0)
		var tip := base + Vector2(cos(a) * 10.0, -len)
		FxDraw.taper(self, base, tip, 7.0, 1.0, Color(LEAF.r, LEAF.g, LEAF.b, alpha * 0.75))
	# 灵芝：两朵小伞
	if p > 0.6:
		var q := clampf((p - 0.6) / 0.4, 0.0, 1.0)
		for i in 2:
			var pos := Vector2(-30.0 + 60.0 * float(i), -6.0)
			var r := 13.0 * q
			draw_circle(pos, r, Color(GOLD.r, GOLD.g, GOLD.b, alpha * 0.5))
			FxDraw.streak(self, pos, pos + Vector2(0, 7.0), 3.0,
					Color(GOLD.r, GOLD.g, GOLD.b, alpha * 0.6))


## ② 治愈光柱：底部宽、往上散成光点。
func _draw_pillar() -> void:
	var p := clampf((_t - 0.25) / 0.85, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var alpha := sin(p * PI) * 0.8
	var top := Vector2(0, -170.0)
	var bottom := Vector2(0, 0)
	FxDraw.taper(self, top, bottom, 18.0, 86.0, Color(LEAF.r, LEAF.g, LEAF.b, alpha * 0.28))
	FxDraw.taper(self, top + Vector2(0, 40.0), bottom, 8.0, 40.0,
			Color(MIST.r, MIST.g, MIST.b, alpha * 0.35))
	FxDraw.glow(self, Vector2(0, -4), 60.0, Color(LEAF.r, LEAF.g, LEAF.b, alpha * 0.3), 4)


## ③ 叶片与露珠：绕轴螺旋上升。
func _draw_leaves() -> void:
	var p := clampf((_t - 0.35) / 0.95, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var alpha := sin(p * PI) * 0.9
	for i in 12:
		var a := TAU * float(i) / 12.0 + _t * 2.6
		var r := 30.0 + 28.0 * sin(p * PI + float(i))
		var y := -20.0 - 120.0 * p - float(i) * 3.0
		var pos := Vector2(cos(a) * r, y + sin(a) * 10.0)
		FxDraw.blade(self, pos, 14.0, 5.0, a + PI * 0.5,
				Color(LEAF.r, LEAF.g, LEAF.b, alpha * 0.85))
	for i in 8:
		var a2 := TAU * float(i) / 8.0 - _t * 1.8
		var r2 := 16.0 + 22.0 * sin(p * PI * 1.3 + float(i))
		var y2 := -10.0 - 90.0 * p
		draw_circle(Vector2(cos(a2) * r2, y2 + sin(a2) * 8.0), 2.2,
				Color(MIST.r, MIST.g, MIST.b, alpha * 0.8))


## ④ 脚下留环：金绿色双环，缓慢旋转、缓慢淡出。
func _draw_ring() -> void:
	var p := clampf((_t - 1.05) / 0.75, 0.0, 1.0)
	if p <= 0.0:
		return
	var fade := 1.0 if p < 0.55 else clampf((1.0 - p) / 0.45, 0.0, 1.0)
	var r := 44.0 + 14.0 * p
	var c := Color(GOLD.r, GOLD.g, GOLD.b, 0.8 * fade)
	FxDraw.ring(self, Vector2(0, 4), r, 2.6, c)
	FxDraw.ring(self, Vector2(0, 4), r * 0.72, 1.6,
			Color(LEAF.r, LEAF.g, LEAF.b, 0.7 * fade))
	for i in 12:
		var a := _t * 1.6 + TAU * float(i) / 12.0
		var dir := Vector2(cos(a), sin(a) * 0.4)
		FxDraw.streak(self, Vector2(0, 4) + dir * (r + 2.0), Vector2(0, 4) + dir * (r + 8.0),
				2.2, Color(GOLD.r, GOLD.g, GOLD.b, 0.6 * fade))

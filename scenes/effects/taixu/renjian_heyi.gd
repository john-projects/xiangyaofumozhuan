extends Node2D
## 人剑合一（renjian_heyi）· 自身增益特效（挂在角色脚下）。
##
## 时间轴（总 2.45s）：
##   0.00–2.20  脚下符文环展开并旋转，逐渐收拢
##   0.20–1.85  12 道剑刃螺旋上升（半径收缩、越转越快，带光轨）
##   1.60–1.95  头顶剑丸下落（从 -200 落到 -70），中心越来越亮
##   1.95        剑丸坠入 → 冲击波 + 爆闪
##   2.00        上升光尘（一次喷射 36 颗，向上飘）
##
## 接口：play(tint, count)。挂在角色身上时用 global_position 跟随即可。

const DURATION := 2.45
const BLADE_COUNT := 12

var _t := 0.0
var _tint := Color(0.85, 0.95, 1.0)
var _dust: CPUParticles2D


func _ready() -> void:
	z_index = 4
	# 自身增益走 screen_effect_scene，Battle 不会帮我们乘 burst_scale，所以这里自己放大
	scale = Vector2(2.0, 2.0)
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	_build_dust()


func _build_dust() -> void:
	_dust = CPUParticles2D.new()
	_dust.one_shot = true
	_dust.emitting = false
	_dust.explosiveness = 1.0
	_dust.amount = 36
	_dust.lifetime = 1.1
	_dust.direction = Vector2(0, -1)
	_dust.spread = 38.0
	_dust.initial_velocity_min = 40.0
	_dust.initial_velocity_max = 150.0
	_dust.gravity = Vector2(0, -30)
	_dust.scale_amount_min = 0.25
	_dust.scale_amount_max = 0.7
	_dust.texture = FxDraw.dot_texture(16)
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	_dust.color_ramp = ramp
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_dust.material = mat
	add_child(_dust)


func play(tint: Color = Color(0.85, 0.95, 1.0), count: int = 36) -> void:
	_tint = tint
	_t = 0.0
	_dust.amount = clampi(count, 16, 64)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if not _dust.emitting and _t >= 2.00:
		_dust.emitting = true
		_dust.restart()
	if _t >= DURATION:
		queue_free()


func _draw() -> void:
	_draw_ground_ring()
	_draw_blades()
	_draw_orb()
	_draw_shockwave()


## ① 脚下符文环：两圈 + 16 段刻度，半径随时间轻微收拢。
func _draw_ground_ring() -> void:
	var fade := clampf(_t / 0.20, 0.0, 1.0) * clampf((2.20 - _t) / 0.30, 0.0, 1.0)
	if fade <= 0.0:
		return
	var shrink := lerpf(1.15, 0.75, clampf(_t / 2.0, 0.0, 1.0))
	var spin := _t * 2.0
	var c := _tint
	c.a = fade * 0.6
	FxDraw.ring(self, Vector2.ZERO, 70.0 * shrink, 3.0, c)
	c.a = fade * 0.35
	FxDraw.ring(self, Vector2.ZERO, 46.0 * shrink, 1.6, c)
	var tick := _tint
	tick.a = fade * 0.85
	for i in 16:
		var a := -spin + TAU * float(i) / 16.0
		var dir := Vector2(cos(a), sin(a))
		FxDraw.streak(self, dir * 50.0 * shrink, dir * 64.0 * shrink, 2.0, tick)


## ② 12 道剑刃螺旋上升：半径收拢、高度上升、角度加速。
func _draw_blades() -> void:
	var p := clampf((_t - 0.20) / 1.65, 0.0, 1.0)
	if p <= 0.0:
		return
	for i in BLADE_COUNT:
		# ⚠ 每片剑刃错开相位（而不是同时在同一高度），才是一条"螺旋梯"，不是一圈平摊
		var pp := fmod(p + float(i) / float(BLADE_COUNT), 1.0)
		var fade := sin(pp * PI)
		if fade <= 0.01:
			continue
		var a := TAU * float(i) / float(BLADE_COUNT) + _t * 3.4 + pp * 2.4
		var radius := lerpf(102.0, 40.0, pp)
		var height := lerpf(-10.0, -230.0, pp)
		var pos := Vector2(cos(a) * radius, height + sin(a) * 10.0)
		var ang := a + PI * 0.5
		var c := _tint
		c.a = fade * 0.9
		FxDraw.blade(self, pos, 54.0, 9.0, ang, c)
		FxDraw.glow(self, pos, 12.0, Color(_tint.r, _tint.g, _tint.b, fade * 0.45), 3)
		# 光轨：连到"上一段螺旋位置"
		var prev_pp := maxf(0.0, pp - 0.12)
		var prev := Vector2(cos(a - 0.6) * lerpf(102.0, 40.0, prev_pp),
				lerpf(-10.0, -230.0, prev_pp))
		FxDraw.streak(self, prev, pos, 4.0,
				Color(_tint.r, _tint.g, _tint.b, fade * 0.35))


## ③ 头顶剑丸：从 -200 落到 -70，越来越亮，然后炸开。
func _draw_orb() -> void:
	var p := (_t - 1.55) / 0.42
	if p < 0.0:
		return
	var pos := Vector2(0, lerpf(-200.0, -70.0, clampf(p, 0.0, 1.0)))
	var grow := clampf(p, 0.0, 1.0)
	if p <= 1.0:
		FxDraw.glow(self, pos, 16.0 + 26.0 * grow, Color(_tint.r, _tint.g, _tint.b, 0.75), 5)
		FxDraw.glow(self, pos, 8.0 + 10.0 * grow, Color(1, 1, 1, 0.9), 3)
		# 旋转的光环
		var a := _t * 9.0
		FxDraw.ring(self, pos, 18.0 + 12.0 * grow, 2.0,
				Color(1, 1, 1, 0.5 * (1.0 - grow * 0.4)))
		for k in 3:
			var ang := a + TAU * float(k) / 3.0
			FxDraw.glow(self, pos + Vector2(cos(ang), sin(ang)) * (20.0 + 10.0 * grow),
					4.0, Color(1, 1, 1, 0.8), 2)


## ④ 剑丸坠入：冲击波 + 中心爆闪。
func _draw_shockwave() -> void:
	var p := (_t - 1.95) / 0.45
	if p < 0.0 or p > 1.0:
		return
	var alpha := 1.0 - p
	FxDraw.ring(self, Vector2(0, -30), 30.0 + 190.0 * p, 7.0 * alpha + 1.0,
			Color(_tint.r, _tint.g, _tint.b, alpha * 0.7))
	FxDraw.glow(self, Vector2(0, -30), 90.0 * (0.5 + 0.5 * p),
			Color(1, 1, 1, alpha * 0.35), 4)

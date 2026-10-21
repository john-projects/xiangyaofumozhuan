extends Node2D
## 群星陨落 · 单个目标脚下的"陨石砸落"（节点原点 = 目标脚底）。
##
## 拼图法（零外部贴图，全代码画）：
##   ① 坠落段（0.30s）：**4 颗陨石**从"施法方 → 被击方"的方向斜砸下来
##      （错开 0~0.09s，落点散在脚下 ±80px），每颗都是"长尾迹 + 白芯 + 大光斑头部"；
##   ② 命中段（0.84s）：柔光爆闪 + 光柱 + 两道冲击波 + 一圈溅射碎星 + 各落点余闪；
## 总时长约 1.14s，播完 queue_free()。缩放由 SkillData.burst_scale 控制。
##
## 方向：Battle 会在生成后调 set_impact_direction(施法者位置 - 目标位置)，
## 让陨石从施法者那一侧斜插过来（不再固定 45°）。

const FALL_TIME := 0.55
const BURST_TIME := 0.60
## 一共几颗陨石砸向这个目标。
const METEOR_COUNT := 4
## 陨石从多远处砸下来（沿坠落方向的长度）——越长，进场越"从天上压下来"。
const FALL_DISTANCE := 430.0

var _t := 0.0
## 坠落方向（单位向量）；默认斜向下，Battle 会用 set_impact_direction() 覆盖。
var _dir := Vector2(-0.62, 0.78).normalized()
## 本实例的陨石：from/to/delay/len
var _meteors: Array[Dictionary] = []
## 径向渐变光斑（中心白 → 边缘透明），所有"发光"都用它拉伸绘制。
var _glow: GradientTexture2D


func _ready() -> void:
	z_index = 5
	# 加法混合：光斑叠在暗背景上才是"发光"
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	_glow = _make_glow_texture()
	_build_meteors()


## 设定坠落方向：参数 d = 目标位置 - 施法者位置（屏幕坐标）。
## 做法：取水平方向为主、再压一个向下的量，避免"平着飞过来"。
func set_impact_direction(d: Vector2) -> void:
	if d.length() < 1.0:
		return
	_dir = (d.normalized() * 0.85 + Vector2(0.0, 1.0)).normalized()
	_build_meteors()


## 生成 4 颗陨石：落点在脚下附近散开，出发点沿 _dir 反方向退到天上。
func _build_meteors() -> void:
	_meteors.clear()
	for i in METEOR_COUNT:
		var land := Vector2(randf_range(-80.0, 80.0), randf_range(-12.0, 12.0))
		_meteors.append({
			"from": land - _dir * FALL_DISTANCE,
			"to": land,
			"delay": randf_range(0.0, 0.09),
			"len": randf_range(320.0, 460.0),
		})


## 生成 256×256 的径向渐变（白心 → 透明边），做成可复用的光斑贴图。
func _make_glow_texture() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	grad.colors = PackedColorArray([
		Color(1, 1, 1, 1.0),
		Color(0.85, 0.92, 1.0, 0.55),
		Color(0.7, 0.82, 1.0, 0.0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256
	return tex


## 兼容 BurstEffect 接口：Battle/弹道会调 play(tint, count)，否则会被当成「纯序列帧」而当场释放。
func play(_tint: Color = Color.WHITE, _count: int = 0) -> void:
	_t = 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _t > FALL_TIME + BURST_TIME:
		queue_free()


## 以 (cx, cy) 为中心画一张半径 r 的柔光。
func _draw_glow(cx: float, cy: float, r: float, tint: Color) -> void:
	if _glow == null:
		return
	draw_texture_rect(_glow, Rect2(cx - r, cy - r, r * 2.0, r * 2.0), false, tint)


func _draw() -> void:
	if _t <= FALL_TIME:
		_draw_fall()
	else:
		_draw_impact((_t - FALL_TIME) / BURST_TIME)


## 坠落：4 颗陨石沿 _dir 加速砸下（p² 加速），锥形光斑尾迹 + 大光斑头部。
func _draw_fall() -> void:
	for meteor in _meteors:
		var delay: float = meteor["delay"]
		var p := clampf((_t - delay) / FALL_TIME, 0.0, 1.0)
		if p <= 0.0:
			continue
		var from: Vector2 = meteor["from"]
		var to: Vector2 = meteor["to"]
		var head := from.lerp(to, p * p)
		var length: float = meteor["len"]
		# 尾迹：3 层锥形多边形（宽 → 窄、暗 → 亮），叠出"越靠近头部越亮"的拖尾
		var tail := head - _dir * length
		draw_colored_polygon(_tail_quad(head, tail, 56.0, 6.0), Color(0.45, 0.62, 1.0, 0.18))
		draw_colored_polygon(_tail_quad(head, tail, 28.0, 3.0), Color(0.62, 0.78, 1.0, 0.30))
		draw_colored_polygon(_tail_quad(head, tail, 11.0, 1.5), Color(0.92, 0.96, 1.0, 0.55))
		# 叠一串柔光把多边形的硬边糊掉，看起来才是"发光气体"而不是纸片
		for i in 7:
			var f := float(i) / 6.0
			var p_glow := head - _dir * length * f
			_draw_glow(p_glow.x, p_glow.y, lerpf(64.0, 12.0, f),
					Color(0.8, 0.9, 1.0, lerpf(0.8, 0.0, f)))
		# 头部大光斑
		_draw_glow(head.x, head.y, 120.0, Color(0.78, 0.88, 1.0, 0.9))
		_draw_glow(head.x, head.y, 46.0, Color(1, 1, 1, 1.0))


## 以 head 为宽端、tail 为窄端的锥形四边形（用于画拖尾）。
func _tail_quad(head: Vector2, tail: Vector2, w_head: float, w_tail: float) -> PackedVector2Array:
	var perp := _dir.orthogonal()
	return PackedVector2Array([
		head + perp * w_head,
		head - perp * w_head,
		tail - perp * w_tail,
		tail + perp * w_tail,
	])


## 命中：柔光爆闪 → 光柱 → 冲击波 → 碎星，全部按 b（0→1）衰减；
## 各陨石的落点再留一点小余闪，让"4 颗分别砸中"看得见。
func _draw_impact(raw_b: float) -> void:
	var b := clampf(raw_b, 0.0, 1.0)
	var alpha := 1.0 - b
	# ① 各落点余闪
	for meteor in _meteors:
		var land: Vector2 = meteor["to"]
		_draw_glow(land.x, land.y, 70.0 * alpha + 16.0, Color(0.85, 0.94, 1.0, alpha * 0.9))
	# ② 中心爆闪光斑（前 40% 最亮，迅速扩散变淡）
	var flash_r := lerpf(60.0, 260.0, minf(1.0, b * 1.6))
	_draw_glow(0.0, 0.0, flash_r, Color(1, 1, 1, alpha * alpha * 1.2))
	_draw_glow(0.0, 0.0, flash_r * 0.45, Color(0.9, 0.95, 1.0, alpha * 1.4))
	# ③ 余烬光柱（沿坠落方向反向射出，前 60% 时间）：锥形，越远越宽越淡
	if b < 0.6:
		var k2 := 1.0 - b / 0.6
		var tip := -_dir * 340.0
		draw_colored_polygon(_tail_quad(tip, Vector2.ZERO, 66.0, 18.0),
				Color(0.55, 0.72, 1.0, k2 * 0.22))
		draw_colored_polygon(_tail_quad(tip, Vector2.ZERO, 26.0, 8.0),
				Color(0.9, 0.95, 1.0, k2 * 0.45))
	# ④ 两道冲击波
	draw_arc(Vector2.ZERO, lerpf(18.0, 230.0, b), 0.0, TAU, 64,
			Color(0.8, 0.9, 1.0, alpha * 0.55), 14.0)
	draw_arc(Vector2.ZERO, lerpf(10.0, 150.0, b), 0.0, TAU, 56,
			Color(1, 1, 1, alpha * 0.45), 6.0)
	# ⑤ 溅射碎星（外圈逐步散开）
	for i in 12:
		var ang := TAU * float(i) / 12.0
		var dist := lerpf(18.0, 210.0, b)
		var p := Vector2(cos(ang), sin(ang)) * dist
		_draw_glow(p.x, p.y, 20.0 * alpha + 5.0, Color(0.85, 0.94, 1.0, alpha))

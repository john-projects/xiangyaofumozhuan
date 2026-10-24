class_name FxDraw
extends RefCounted
## 技能特效的绘制小工具：剑光、环、花瓣、剑刃、裂纹。
##
## 为什么用 draw_* 而不是贴图：
##   项目里的特效（群星陨落 / 雷动九天）都是纯代码画的，不依赖外部素材，
##   改颜色/尺寸只改参数。这里把常用形状抽成静态函数，三个剑系技能共用。
##
## 所有函数都接收 CanvasItem（Node2D 的 _draw 里传 self），坐标是本地坐标。

## 剑光：一段弯月形的弧，两端尖、中段亮。angle 是弧的法线方向（弧度）。
static func crescent(ci: CanvasItem, center: Vector2, radius: float, angle: float,
		thickness: float, color: Color, arc_span: float = 2.2, streak: float = 0.0) -> void:
	# streak > 0 时把弧沿法线拉长，做出"高速划过"的拖尾
	var steps := 14
	var outer: PackedVector2Array = []
	var inner: PackedVector2Array = []
	for i in steps + 1:
		var t := float(i) / steps
		var a := angle - arc_span * 0.5 + arc_span * t
		# 两端细、中段粗
		var taper := sin(t * PI)
		var r := radius + streak * taper
		outer.append(center + Vector2(cos(a), sin(a)) * r)
		inner.append(center + Vector2(cos(a), sin(a)) * (r - thickness * taper))
	var poly := outer
	inner.reverse()
	poly.append_array(inner)
	ci.draw_colored_polygon(poly, color)


## 细长剑刃：一个两端尖的菱形，angle 为朝向。
static func blade(ci: CanvasItem, center: Vector2, length: float, width: float,
		angle: float, color: Color) -> void:
	var dir := Vector2(cos(angle), sin(angle))
	var nrm := Vector2(-dir.y, dir.x)
	var tip := center + dir * length * 0.5
	var tail := center - dir * length * 0.5
	var mid := center + dir * length * 0.08
	var poly := PackedVector2Array([
		tip,
		mid + nrm * width * 0.5,
		tail,
		mid - nrm * width * 0.5,
	])
	ci.draw_colored_polygon(poly, color)


## 圆环：width 是环壁厚度。
static func ring(ci: CanvasItem, center: Vector2, radius: float, width: float,
		color: Color) -> void:
	ci.draw_arc(center, maxf(0.1, radius), 0.0, TAU, 64, color, maxf(1.0, width), true)


## 花瓣状放射（剑花）：petals 片花瓣从中心张开。
static func lotus(ci: CanvasItem, center: Vector2, radius: float, petals: int,
		angle: float, color: Color, width_ratio: float = 0.28) -> void:
	for i in petals:
		var a := angle + TAU * float(i) / petals
		var dir := Vector2(cos(a), sin(a))
		var nrm := Vector2(-dir.y, dir.x)
		var len := radius * (0.75 + 0.25 * sin(float(i) * 1.7))
		var tip := center + dir * len
		var poly := PackedVector2Array([
			center,
			center + dir * len * 0.45 + nrm * len * width_ratio,
			tip,
			center + dir * len * 0.45 - nrm * len * width_ratio,
		])
		ci.draw_colored_polygon(poly, color)


## 裂纹：从中心向外的一条锯齿折线（每帧固定随机种子，避免抖动）。
static func crack(ci: CanvasItem, center: Vector2, length: float, angle: float,
		seed_value: int, color: Color, width: float = 2.0, segments: int = 6) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var pts := PackedVector2Array()
	var pos := center
	var dir := Vector2(cos(angle), sin(angle))
	pts.append(pos)
	for i in segments:
		var step := length / segments
		dir = dir.rotated(rng.randf_range(-0.45, 0.45))
		pos += dir * step
		pts.append(pos)
	ci.draw_polyline(pts, color, maxf(1.0, width), true)


## 光斑：中心亮、边缘透明（用多层圆模拟径向渐变，加法混合下很自然）。
static func glow(ci: CanvasItem, center: Vector2, radius: float, color: Color,
		layers: int = 5) -> void:
	for i in layers:
		var t := float(i + 1) / layers
		var c := color
		c.a = color.a * (1.0 - t) * 0.55
		ci.draw_circle(center, radius * t, c)


## 一条从 a 到 b 的光带（剑气轨迹）。
static func streak(ci: CanvasItem, a: Vector2, b: Vector2, width: float,
		color: Color) -> void:
	var dir := (b - a)
	if dir.length() < 0.01:
		return
	var nrm := Vector2(-dir.y, dir.x).normalized() * width * 0.5
	var poly := PackedVector2Array([
		a + nrm, b + nrm, b - nrm, a - nrm,
	])
	ci.draw_colored_polygon(poly, color)


## 收尖的光刃：尾端宽、前端收成尖（比等宽光带更像"剑气"）。
static func taper(ci: CanvasItem, tail: Vector2, head: Vector2, w_tail: float,
		w_head: float, color: Color) -> void:
	var d := head - tail
	if d.length() < 0.01:
		return
	var dir := d.normalized()
	var nrm := Vector2(-dir.y, dir.x)
	var poly := PackedVector2Array([
		tail + nrm * w_tail * 0.5,
		head + nrm * w_head * 0.5,
		head - nrm * w_head * 0.5,
		tail - nrm * w_tail * 0.5,
	])
	ci.draw_colored_polygon(poly, color)

## 粒子用的圆点贴图：中心白、边缘透明（代码生成，不依赖外部素材）。
static func dot_texture(size: int = 32) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(size - 1, size - 1) * 0.5
	var r := float(size) * 0.5
	for y in size:
		for x in size:
			var d := (Vector2(x, y) - c).length() / r
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)
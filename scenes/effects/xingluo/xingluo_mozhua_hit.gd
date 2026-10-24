extends Node2D
## 星罗魔爪 · 单次命中表现。
## 连击第 1 击划出顺向三爪，第 2 击反向交叉；星痕、白热刃芯和碎星均程序绘制。

const LIFETIME := 0.54
const SPARK_COUNT := 28

var _time := 0.0
var _segment := 0
var _tint := Color(0.95, 0.45, 0.8, 1.0)
var _forward := Vector2.RIGHT
var _sparks: Array[Dictionary] = []


func _ready() -> void:
	z_index = 6
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = additive


func set_attack_direction(direction: Vector2) -> void:
	if direction.length_squared() > 0.001:
		_forward = direction.normalized()


func play(tint: Color = Color(0.95, 0.45, 0.8, 1.0), _count: int = SPARK_COUNT) -> void:
	play_segment(0, tint)


func play_segment(index: int, tint: Color = Color(0.95, 0.45, 0.8, 1.0)) -> void:
	_segment = clampi(index, 0, 1)
	_tint = tint
	_time = 0.0
	_sparks.clear()
	for i in SPARK_COUNT:
		var angle := randf_range(-PI, PI)
		var speed := randf_range(90.0, 310.0)
		_sparks.append({
			"delay": randf_range(0.015, 0.11),
			"life": randf_range(0.16, 0.34),
			"velocity": Vector2.RIGHT.rotated(angle) * speed,
			"size": randf_range(2.0, 5.0),
		})
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	if _time >= LIFETIME:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var fade := 1.0 - smoothstep(0.18, LIFETIME, _time)
	var reveal := smoothstep(0.0, 0.12, _time)
	var side := _forward.orthogonal()
	var angle := -0.48 if _segment == 0 else 0.48
	var slash_axis := _forward.rotated(angle).normalized()
	var slash_side := slash_axis.orthogonal()
	var slash_length := lerpf(30.0, 150.0 if _segment == 1 else 132.0, reveal)
	var curve_sign := 1.0 if _segment == 0 else -1.0

	# 五道有长短变化的魔爪刃痕，外层幽紫、内部粉白，拉出更华丽的撕裂感。
	for claw in 5:
		var claw_offset := float(claw) - 2.0
		var length_factor := 0.78 if claw == 0 or claw == 4 else 1.0
		var offset := side * claw_offset * 19.0
		var start := -slash_axis * slash_length * length_factor * 0.5 + offset
		var finish := slash_axis * slash_length * length_factor * 0.5 + offset
		var control := (start + finish) * 0.5 + slash_side * curve_sign * (17.0 + absf(claw_offset) * 2.0)
		var points := PackedVector2Array()
		for step in 13:
			var t := float(step) / 12.0
			var point := start.lerp(control, t).lerp(control.lerp(finish, t), t)
			points.append(point)
		draw_polyline(points, Color(_tint.r, _tint.g * 0.48, _tint.b, 0.25 * fade), 32.0, true)
		draw_polyline(points, Color(_tint.r, _tint.g, _tint.b, 0.86 * fade), 9.0, true)
		draw_polyline(points, Color(1.0, 0.90, 1.0, 0.98 * fade), 2.8, true)
		if claw % 2 == 0:
			_draw_star(finish, 7.0 * fade, Color(1.0, 0.93, 1.0, 0.9 * fade))

	# 命中中心的短闪与扩散环，不盖住角色剪影。
	var flash := (1.0 - smoothstep(0.025, 0.17, _time)) * fade
	if flash > 0.0:
		draw_circle(Vector2.ZERO, lerpf(8.0, 27.0, reveal), Color(_tint.r, _tint.g, _tint.b, 0.38 * flash))
		_draw_star(Vector2.ZERO, 15.0 * flash, Color(1.0, 0.92, 1.0, 0.95 * flash))
	var ring_progress := clampf((_time - 0.045) / 0.34, 0.0, 1.0)
	var ring_alpha := (1.0 - ring_progress) * fade * (0.78 if _segment == 1 else 0.62)
	if ring_alpha > 0.0:
		var ring_radius := lerpf(18.0, 98.0 if _segment == 1 else 82.0, ring_progress)
		draw_arc(Vector2.ZERO, ring_radius, 0.0, TAU, 48,
				Color(_tint.r, _tint.g, _tint.b, ring_alpha), 4.0, true)
		draw_arc(Vector2.ZERO, ring_radius * 0.72, 0.35, TAU * 0.78,
				40, Color(1.0, 0.78, 0.96, ring_alpha * 0.62), 1.8, true)
		for point_index in 6:
			var point_angle := TAU * float(point_index) / 6.0 - _time * 1.5
			var point := Vector2.RIGHT.rotated(point_angle) * ring_radius
			_draw_star(point, 4.5 * ring_alpha, Color(1.0, 0.91, 1.0, ring_alpha))

	# 碎星从斩痕中心向外飞散，带短尾并自然淡出。
	for spark in _sparks:
		var age := _time - float(spark["delay"])
		var life := float(spark["life"])
		if age < 0.0 or age >= life:
			continue
		var velocity: Vector2 = spark["velocity"]
		var position := velocity * age + Vector2(0.0, 95.0) * age * age * 0.5
		var alpha := 1.0 - age / life
		var size: float = spark["size"]
		draw_line(position, position - velocity.normalized() * size * 2.8,
				Color(_tint.r, _tint.g, _tint.b, alpha * 0.9), size * 0.9, true)
		draw_circle(position, size * 0.45, Color(1.0, 0.88, 1.0, alpha))


func _draw_star(center: Vector2, radius: float, color: Color) -> void:
	var points := PackedVector2Array([
		center + Vector2(0.0, -radius),
		center + Vector2(radius * 0.19, -radius * 0.19),
		center + Vector2(radius, 0.0),
		center + Vector2(radius * 0.19, radius * 0.19),
		center + Vector2(0.0, radius),
		center + Vector2(-radius * 0.19, radius * 0.19),
		center + Vector2(-radius, 0.0),
		center + Vector2(-radius * 0.19, -radius * 0.19),
	])
	draw_colored_polygon(points, color)

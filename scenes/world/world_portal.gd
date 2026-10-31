extends Node2D
class_name WorldPortal
## 地面传送光圈的表现层。逻辑（要不要传送、传去哪）在 WorldMap 里；
## 这里只负责画和"玩家在不在圈里"。
##
## 配色与混合方式的取舍（踩过两个坑）：
##   ① 一开始用金色 —— 和暖色的村庄地面、金色 NPC 名字牌撞色，看不见。
##   ② 改成青蓝 + 加法混合 —— 在**亮色地面**（桃花滩的白沙）上直接过曝泛白，
##      圆环边界完全消失，比金色更糟。
##   现在：**普通混合** + 深色描边 + 靛蓝紫主色。
##     · 只有普通混合才画得出"暗"，而暗色才是明亮背景上的对比来源
##     · 外圈一道深色描边，无论地面是白沙、青苔还是石板都能把圆环"框"出来
##     · 靛蓝紫和沙滩（暖黄）、海水（青）、桃花（粉）三者都不撞

## 圆环横向半径（世界像素基准，实际按 radius 缩放）。
const RING_RX := 1.0
## 椭圆压扁比例：等距视角下地面上的圆看起来是扁的（约 0.42）。
const SQUASH := 0.42
## 脉动周期（秒）。
const PULSE := 1.9

## 主色：靛蓝紫。亮而饱和，压在暖色地面上反差最大。
const RING_COLOR := Color(0.46, 0.34, 1.0, 1.0)
## 外圈亮色：纯白。深色描边外面套白环，在任意底色上都是最高对比。
const OUTER_COLOR := Color(1.0, 1.0, 1.0, 1.0)
## 内芯亮色（接近白紫），只用在细环与光点上。
const CORE_COLOR := Color(0.88, 0.82, 1.0, 1.0)
## 描边色：深靛蓝。明暗反差全靠它。
const EDGE_COLOR := Color(0.09, 0.05, 0.22, 0.9)

var portal: MapPortal
## 世界半径（像素），由 WorldMap 传入。
var radius := 105.0
## 圈上写的名字（如"桃花滩"）。
var display_label := ""

var _t := 0.0
var _label: Label


func setup(p_portal: MapPortal, p_radius: float, p_label: String) -> void:
	portal = p_portal
	radius = p_radius
	display_label = p_label
	# 不要设负 z_index：地图底图是 z=0 的 Sprite，负值会把光圈整个藏到底图下面。
	# 靠 WorldMap 的 y_sort + 树顺序就已经在底图之上、人物之下。
	z_index = 0
	_make_label()
	set_process(true)


func _make_label() -> void:
	if display_label.is_empty():
		return
	_label = Label.new()
	_label.name = "PortalLabel"
	_label.text = display_label
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.60, 1.0))
	_label.add_theme_color_override("font_outline_color", Color(0.05, 0.02, 0.14, 0.95))
	_label.add_theme_constant_override("outline_size", 6)
	_label.size = Vector2(220, 30)
	# 名字压在圈的上方（世界坐标 -y 向上，椭圆是扁的，所以抬到半径的 1.2 倍高）
	_label.position = Vector2(-110, -radius * SQUASH - 34.0)
	add_child(_label)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


## 玩家世界坐标是否踩进圈里。用椭圆判定（和画出来的形状一致），
## 这样"看起来踩到了"和"实际触发了"是同一件事。
func contains(world_point: Vector2) -> bool:
	var d := world_point - global_position
	var rx := radius * RING_RX
	var ry := radius * SQUASH
	return (d.x * d.x) / (rx * rx) + (d.y * d.y) / (ry * ry) <= 1.0


func _draw() -> void:
	var pulse := 0.5 + 0.5 * sin(_t / PULSE * TAU)
	var rx := radius * (0.94 + 0.06 * pulse)
	var ry := rx * SQUASH

	# ① 暗底：一圈偏黑的椭圆，先把"这块有东西"压出来。
	#    明亮沙滩上如果没有这层，彩色圆环会被背景亮度吃掉。
	var dark := EDGE_COLOR
	dark.a = 0.50
	_fill_ellipse(Vector2.ZERO, rx * 1.12, ry * 1.12, dark)

	# ② 地面填充：主色半透明，做出"一圈发光的地砖"
	var fill := RING_COLOR
	fill.a = 0.45 + 0.10 * pulse
	_fill_ellipse(Vector2.ZERO, rx * 0.98, ry * 0.98, fill)
	# 中心压暗一点，像个"坑口"，和外围亮环形成反差
	var hole := EDGE_COLOR
	hole.a = 0.28
	_fill_ellipse(Vector2.ZERO, rx * 0.60, ry * 0.60, hole)

	# ③ 光柱：从圈心往上拉的梯形，远处也能看到入口在哪
	var beam_h := radius * 2.4
	var beam := PackedVector2Array([
		Vector2(-rx * 0.46, -ry * 0.25),
		Vector2(rx * 0.46, -ry * 0.25),
		Vector2(rx * 0.18, -beam_h),
		Vector2(-rx * 0.18, -beam_h),
	])
	var bc := RING_COLOR
	bc.a = 0.28
	draw_colored_polygon(beam, bc)
	# 光柱中轴：更亮更窄的一条
	var beam2 := PackedVector2Array([
		Vector2(-rx * 0.15, -ry * 0.25),
		Vector2(rx * 0.15, -ry * 0.25),
		Vector2(rx * 0.06, -beam_h * 0.92),
		Vector2(-rx * 0.06, -beam_h * 0.92),
	])
	var b2 := CORE_COLOR
	b2.a = 0.32
	draw_colored_polygon(beam2, b2)

	# ④ 主圆环：先画深色宽描边，再叠亮色细环 —— 描边是"看得清"的关键
	for ring in 2:
		var k := 1.0 if ring == 0 else 0.84
		var pts := PackedVector2Array()
		for i in 49:
			var a := TAU * float(i) / 48.0
			pts.append(Vector2(cos(a) * rx * k, sin(a) * ry * k))
		var outline := EDGE_COLOR
		outline.a = 0.90
		draw_polyline(pts, outline, (5.5 if ring == 0 else 7.5) + 3.0, true)
		var c := OUTER_COLOR if ring == 0 else CORE_COLOR
		c.a = 1.0
		draw_polyline(pts, c, 5.5 if ring == 0 else 7.5, true)

	# ⑤ 缓慢旋转的四个刻度（同样"深描边 + 亮芯"）
	var spin := _t * 0.6
	for i in 4:
		var a := spin + TAU * float(i) / 4.0
		var inner := Vector2(cos(a) * rx * 0.90, sin(a) * ry * 0.90)
		var outer := Vector2(cos(a) * rx * 1.08, sin(a) * ry * 1.08)
		var oc := EDGE_COLOR
		oc.a = 0.85
		draw_line(inner, outer, oc, 7.0, true)
		var cc := OUTER_COLOR
		cc.a = 1.0
		draw_line(inner, outer, cc, 4.0, true)

	# ⑥ 上升的光点
	for i in 6:
		var p := fmod(_t / 2.4 + float(i) / 6.0, 1.0)
		var angle := TAU * float(i) / 6.0 + spin * 0.4
		var x := cos(angle) * rx * 0.58
		var y := sin(angle) * ry * 0.58 - p * radius * 0.8
		var ec := EDGE_COLOR
		ec.a = (1.0 - p) * 0.55
		draw_circle(Vector2(x, y), 5.0 * (1.0 - p * 0.5), ec)
		var c := CORE_COLOR
		c.a = (1.0 - p) * 0.95
		draw_circle(Vector2(x, y), 3.2 * (1.0 - p * 0.5), c)


## 用多边形逼近填一个椭圆。
func _fill_ellipse(center: Vector2, rx: float, ry: float, color: Color) -> void:
	var pts := PackedVector2Array()
	for i in 33:
		var a := TAU * float(i) / 32.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, color)

extends Node2D
## 封灵诀（fengling_jue）· 单体封灵：玉符贴印 + 金丝锁链 + 凝滞雾气。
##
## 时间轴（总 1.35s）：
##   0.00–0.30  玉符从画外飞来（旋转，带光尾）
##   0.25–0.55  印文环炸开（双层符文环反向旋转）
##   0.35–1.10  三道金丝锁链绕目标螺旋收拢
##   0.40–1.15  头顶浮出方印（"封"字简化成印章线条）
##   0.55–1.20  凝滞雾气扩散一圈
##   1.15–1.35  碎成光尘消散
##
## 接口：play(tint, count)，Battle 摆到目标身上调用。

const DURATION := 1.35
## 缥缈仙府配色：雾白 + 藕荷 + 琉璃金
const PINK := Color(1.0, 0.55, 0.88)
const JADE := Color(0.42, 1.0, 0.96)
const GOLD := Color(1.0, 0.8, 0.4)

var _t := 0.0
var _tint := Color(0.78, 0.72, 1.0)


func _ready() -> void:
	z_index = 5
	# 加法混合：仙法都是发光体，叠在场景上才亮
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat


func play(tint: Color = Color(0.78, 0.72, 1.0), _count: int = 0) -> void:
	_tint = tint
	_t = 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _t >= DURATION:
		queue_free()


func _draw() -> void:
	_draw_fog()
	_draw_tablet()
	_draw_rune_rings()
	_draw_chains()
	_draw_seal()
	_draw_dust()


## ① 凝滞雾气：几层柔光向外推开，越到后面越淡。
func _draw_fog() -> void:
	var p := clampf((_t - 0.45) / 0.75, 0.0, 1.0)
	if p <= 0.0:
		return
	var alpha := (1.0 - p) * 0.16
	for i in 3:
		var r := 60.0 + 90.0 * p + i * 26.0
		FxDraw.glow(self, Vector2(0, -40), r * (1.0 - i * 0.18), Color(JADE.r, JADE.g, JADE.b, alpha), 3)


## ② 玉符：从左上飞入，边飞边转，落定在胸口位置。
func _draw_tablet() -> void:
	if _t > 0.34:
		return
	var p := clampf(_t / 0.30, 0.0, 1.0)
	var ease_p := 1.0 - pow(1.0 - p, 3.0)
	var pos := Vector2(-280.0, -140.0).lerp(Vector2(0, -40), ease_p)
	var ang := lerpf(-2.4, 0.0, ease_p)
	# 光尾
	FxDraw.streak(self, pos - Vector2(cos(ang), sin(ang)) * 70.0, pos, 10.0,
			Color(PINK.r, PINK.g, PINK.b, 0.35 * (1.0 - p * 0.4)))
	# 玉牌本体：两片叠出厚度
	for pass_i in 2:
		var off := Vector2(0, -3.0 * pass_i)
		var c := Color(JADE.r, JADE.g, JADE.b, 0.85 - pass_i * 0.25)
		var w := 26.0
		var h := 40.0
		var pts := PackedVector2Array()
		var dir := Vector2(cos(ang), sin(ang))
		var nrm := Vector2(-dir.y, dir.x)
		for corner in [Vector2(-w, -h), Vector2(w, -h), Vector2(w, h), Vector2(-w, h)]:
			pts.append(pos + off + dir * corner.y + nrm * corner.x)
		draw_colored_polygon(pts, c)
	# 玉牌上的云纹
	var g := Color(GOLD.r, GOLD.g, GOLD.b, 0.75)
	FxDraw.ring(self, pos, 12.0, 1.6, g)
	FxDraw.ring(self, pos, 6.0, 1.2, g)


## ③ 印文环：两层符文环一正一反转，并向外扩张。
func _draw_rune_rings() -> void:
	var p := clampf((_t - 0.22) / 0.45, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var ease_p := 1.0 - pow(1.0 - p, 2.0)
	var alpha := (1.0 - p) * 0.85
	var radius := 46.0 + 62.0 * ease_p
	var c := Color(_tint.r, _tint.g, _tint.b, alpha)
	FxDraw.ring(self, Vector2(0, -40), radius, 2.5, c)
	# 符文（短刻线）沿环分布，外圈顺时针、内圈逆时针
	for layer in 2:
		var r := radius - layer * 14.0
		var spin := _t * (2.6 if layer == 0 else -3.4)
		for i in 12:
			var a := spin + TAU * float(i) / 12.0
			var dir := Vector2(cos(a), sin(a))
			var pos := Vector2(0, -40) + dir * r
			FxDraw.streak(self, pos - dir * 4.0, pos + dir * 4.0, 3.0,
					Color(GOLD.r, GOLD.g, GOLD.b, alpha * 0.8))


## ④ 金丝锁链：三条链子绕中心螺旋收拢，用一串小球表示链节。
func _draw_chains() -> void:
	var p := clampf((_t - 0.32) / 0.78, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var alpha := sin(p * PI) * 0.95
	for chain in 3:
		var base := TAU * float(chain) / 3.0 + _t * 2.2
		var r := lerpf(105.0, 40.0, p)
		var y0 := lerpf(-150.0, -20.0, p)
		# 先连成一条链身（折线），再在节点上补"链环"——只画点会显得零散
		var pts := PackedVector2Array()
		for k in 15:
			var tt := float(k) / 14.0
			var a := base + tt * 2.6
			var rr := r * (1.0 - tt * 0.35)
			pts.append(Vector2(cos(a) * rr, y0 + tt * 110.0 + sin(a) * rr * 0.35))
		draw_polyline(pts, Color(GOLD.r, GOLD.g, GOLD.b, alpha * 0.55), 3.2, true)
		for k in pts.size():
			var tt2 := float(k) / float(pts.size() - 1)
			var c := Color(GOLD.r, GOLD.g, GOLD.b, alpha * (1.0 - tt2 * 0.3))
			draw_arc(pts[k], 3.4, 0.0, TAU, 12, c, 2.2, true)


## ⑤ 封印方印：头顶浮起一方印，内部是简化的"封"字笔画。
func _draw_seal() -> void:
	var p := clampf((_t - 0.38) / 0.55, 0.0, 1.0)
	if p <= 0.0:
		return
	var fade := 1.0 if p < 0.7 else clampf((1.0 - p) / 0.3, 0.0, 1.0)
	var center := Vector2(0, -175.0 - 18.0 * p)
	var half := 26.0
	var c := Color(GOLD.r, GOLD.g, GOLD.b, 0.9 * fade)
	# 外框
	var corners := PackedVector2Array([
		center + Vector2(-half, -half), center + Vector2(half, -half),
		center + Vector2(half, half), center + Vector2(-half, half),
	])
	draw_polyline(PackedVector2Array([corners[0], corners[1], corners[2], corners[3], corners[0]]),
			c, 2.4, true)
	# 内部笔画（"封"的骨架：一竖两横）
	FxDraw.streak(self, center + Vector2(0, -16), center + Vector2(0, 16), 2.6, c)
	FxDraw.streak(self, center + Vector2(-13, -6), center + Vector2(13, -6), 2.2, c)
	FxDraw.streak(self, center + Vector2(-13, 6), center + Vector2(6, 6), 2.2, c)
	FxDraw.glow(self, center, 44.0, Color(PINK.r, PINK.g, PINK.b, 0.22 * fade), 3)


## ⑥ 收尾光尘：向上飘散的小点。
func _draw_dust() -> void:
	var p := clampf((_t - 0.85) / 0.5, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var alpha := (1.0 - p) * 0.8
	for i in 18:
		var a := TAU * float(i) / 18.0
		var r := 20.0 + 70.0 * p
		var pos := Vector2(cos(a) * r, -40.0 + sin(a) * r * 0.7 - 40.0 * p)
		draw_circle(pos, 1.8, Color(1, 1, 1, alpha * 0.8))

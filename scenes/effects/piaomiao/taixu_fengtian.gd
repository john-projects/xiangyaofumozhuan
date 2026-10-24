extends Node2D
## 太虚封天（taixu_fengtian）· 群体封印：云海翻涌 + 天幕光罩 + 符字锁死。
##
## 时间轴（总 2.50s）：
##   0.00–0.60  云海自脚下翻涌铺开
##   0.20–1.20  天幕光罩落下（半球线框，经线纬线）
##   0.50–1.90  十二枚符字沿大环依次点亮
##   1.00–1.90  六道光柱自天而降
##   1.90–2.50  光罩收束 → 碎成光屑
##
## 用法：挂在敌阵中心（群体技能的中心爆点），所以画面比单体特效大一圈。

const DURATION := 2.50
const RUNE_COUNT := 12
const PINK := Color(1.0, 0.55, 0.88)
const JADE := Color(0.42, 1.0, 0.96)
const GOLD := Color(1.0, 0.8, 0.4)

var _t := 0.0
var _tint := Color(0.8, 0.75, 1.0)


func _ready() -> void:
	z_index = 6
	# 加法混合：仙法都是发光体，叠在场景上才亮
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat


func play(tint: Color = Color(0.8, 0.75, 1.0), _count: int = 0) -> void:
	_tint = tint
	_t = 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _t >= DURATION:
		queue_free()


func _draw() -> void:
	_draw_cloud_sea()
	_draw_dome()
	_draw_runes()
	_draw_pillars()
	_draw_collapse()


## ① 云海：几团柔光椭圆缓缓外扩、缓慢旋转（用少量大光斑冒充云雾）。
func _draw_cloud_sea() -> void:
	var p := clampf(_t / 0.60, 0.0, 1.0)
	if p <= 0.0:
		return
	var fade := clampf(1.0 - (_t - 1.9) / 0.6, 0.0, 1.0)
	for i in 6:
		var a := TAU * float(i) / 6.0 + _t * 0.25
		var r := 70.0 + 26.0 * sin(_t * 1.2 + float(i))
		var pos := Vector2(cos(a) * (120.0 + 40.0 * p), 30.0 + sin(a) * 34.0)
		var c := Color(JADE.r, JADE.g, JADE.b, 0.10 * p * fade)
		FxDraw.glow(self, pos, r * (0.6 + 0.4 * p), c, 4)


## ② 天幕光罩：半球线框（经线 + 两条纬线），从下往上"长"出来。
func _draw_dome() -> void:
	var p := clampf((_t - 0.20) / 1.00, 0.0, 1.0)
	if p <= 0.0:
		return
	var fade := 1.0 if _t < 1.9 else clampf((2.5 - _t) / 0.6, 0.0, 1.0)
	var grow := 1.0 - pow(1.0 - p, 3.0)
	var radius := 235.0 * grow
	var center := Vector2(0, 10)
	var c := Color(_tint.r, _tint.g, _tint.b, 0.5 * fade)
	# 经线：以 center 为圆心的上半圆弧
	for i in 9:
		var a := PI + PI * float(i) / 8.0
		var pts := PackedVector2Array()
		for k in 17:
			var tt := float(k) / 16.0
			var aa := PI + PI * tt
			pts.append(center + Vector2(cos(aa), sin(aa)) * radius * (0.55 + 0.45 * absf(cos(a))))
		draw_polyline(pts, Color(c.r, c.g, c.b, c.a * 0.45), 1.6, true)
	# 纬线：两条椭圆
	for j in 2:
		var h := 0.35 + 0.3 * float(j)
		var rr := radius * sqrt(maxf(0.0, 1.0 - h * h))
		var y := center.y - radius * h
		var pts2 := PackedVector2Array()
		for k in 33:
			var aa := TAU * float(k) / 32.0
			pts2.append(Vector2(cos(aa) * rr, y + sin(aa) * rr * 0.22))
		draw_polyline(pts2, c, 1.8, true)


## ③ 符字：十二枚沿大环依次亮起，亮过的会短暂闪一下再暗下去。
func _draw_runes() -> void:
	var p := clampf((_t - 0.50) / 1.40, 0.0, 1.0)
	if p <= 0.0:
		return
	var fade := 1.0 if _t < 1.9 else clampf((2.4 - _t) / 0.5, 0.0, 1.0)
	for i in RUNE_COUNT:
		# 每一枚按顺序点亮：i/RUNE_COUNT 就是它的相对时刻
		var local := clampf((p - float(i) / float(RUNE_COUNT) * 0.7) / 0.3, 0.0, 1.0)
		if local <= 0.0:
			continue
		var pulse := sin(local * PI)
		var a := TAU * float(i) / float(RUNE_COUNT) + _t * 0.35
		var radius := 190.0
		var pos := Vector2(cos(a) * radius, sin(a) * radius * 0.42 + 10.0)
		var c := Color(GOLD.r, GOLD.g, GOLD.b, (0.35 + 0.65 * pulse) * fade)
		# 符字用一小段折线概括（不依赖字体）
		FxDraw.streak(self, pos + Vector2(-9, -9), pos + Vector2(9, -9), 2.2, c)
		FxDraw.streak(self, pos + Vector2(0, -9), pos + Vector2(0, 9), 2.2, c)
		FxDraw.streak(self, pos + Vector2(-7, 4), pos + Vector2(7, 4), 1.8, c)
		FxDraw.glow(self, pos, 14.0 + 8.0 * pulse, Color(PINK.r, PINK.g, PINK.b, 0.25 * pulse * fade), 3)


## ④ 光柱：六道自天而降，落点在环内。
func _draw_pillars() -> void:
	var p := clampf((_t - 1.00) / 0.90, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var alpha := sin(p * PI) * 0.75
	for i in 6:
		var a := TAU * float(i) / 6.0 + 0.3
		var x := cos(a) * 150.0
		var y := sin(a) * 60.0 + 10.0
		var top := Vector2(x * 0.35, -300.0)
		var bottom := Vector2(x, y)
		FxDraw.taper(self, top, bottom, 26.0, 6.0,
				Color(JADE.r, JADE.g, JADE.b, alpha * 0.35))
		FxDraw.taper(self, top, bottom, 8.0, 2.0,
				Color(1, 1, 1, alpha * 0.55))


## ⑤ 收束碎裂：一圈环向内收 + 光屑炸开。
func _draw_collapse() -> void:
	var p := clampf((_t - 1.90) / 0.55, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var alpha := 1.0 - p
	var radius := 210.0 * (1.0 - p) + 30.0
	FxDraw.ring(self, Vector2(0, 10), radius, 3.0 + 2.0 * alpha,
			Color(GOLD.r, GOLD.g, GOLD.b, alpha * 0.8))
	for i in 28:
		var a := TAU * float(i) / 28.0 + float(i) * 0.7
		var r := 20.0 + 240.0 * p
		var pos := Vector2(cos(a) * r, 10.0 + sin(a) * r * 0.45 - 60.0 * p)
		draw_circle(pos, 1.8 * alpha + 0.6, Color(1, 1, 1, alpha * 0.7))

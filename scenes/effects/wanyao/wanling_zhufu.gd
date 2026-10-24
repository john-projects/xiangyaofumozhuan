extends Node2D
## 万灵祝福（wanling_zhufu）· 单体祝福表现：符文雨 + 灵蝶环绕 + 金绿光环。
##
## 时间轴（总 2.40s）：
##   0.00–0.50  头顶展开一幅小卷轴
##   0.30–1.60  金色符文自卷轴洒落
##   0.90–2.00  灵蝶绕目标盘旋
##   1.30–2.40  脚下绽开金绿光环并缓慢淡出
##
## 用法：全体增益，Battle 给每个被祝福的队友各放一个。

const DURATION := 2.40
const LEAF := Color(0.58, 1.0, 0.66)
const GOLD := Color(1.0, 0.86, 0.5)
const WING := Color(1.0, 0.78, 0.92)

var _t := 0.0
var _tint := Color(0.9, 1.0, 0.7)


func _ready() -> void:
	z_index = 4
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat


func play(tint: Color = Color(0.9, 1.0, 0.7), _count: int = 0) -> void:
	_tint = tint
	_t = 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _t >= DURATION:
		queue_free()


func _draw() -> void:
	_draw_scroll()
	_draw_runes()
	_draw_butterflies()
	_draw_ring()


## ① 小卷轴：头顶横向展开（两端卷起画成两个圆）。
func _draw_scroll() -> void:
	var p := clampf(_t / 0.50, 0.0, 1.0)
	if p <= 0.0:
		return
	var fade := clampf(1.0 - (_t - 1.5) / 0.7, 0.0, 1.0)
	var w := 110.0 * (1.0 - pow(1.0 - p, 3.0))
	var y := -190.0
	var c := Color(GOLD.r, GOLD.g, GOLD.b, 0.75 * fade)
	FxDraw.streak(self, Vector2(-w, y), Vector2(w, y), 7.0, c)
	draw_circle(Vector2(-w, y), 8.0, Color(GOLD.r, GOLD.g, GOLD.b, 0.85 * fade))
	draw_circle(Vector2(w, y), 8.0, Color(GOLD.r, GOLD.g, GOLD.b, 0.85 * fade))
	FxDraw.glow(self, Vector2(0, y), 60.0, Color(GOLD.r, GOLD.g, GOLD.b, 0.18 * fade), 4)


## ② 符文雨：从卷轴位置向下飘落，边落边转，落地淡出。
func _draw_runes() -> void:
	var p := clampf((_t - 0.30) / 1.40, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	for i in 16:
		var seed := float(i) * 2.17
		var start := fmod(seed, 1.0) * 0.55
		var local := clampf((p - start) / 0.45, 0.0, 1.0)
		if local <= 0.0 or local >= 1.0:
			continue
		var x := sin(seed * 3.3) * 78.0 + sin(local * 3.0 + seed) * 10.0
		var y := -180.0 + 150.0 * local
		var alpha := (1.0 - local) * 0.9
		var ang := local * 2.4 + seed
		var c := Color(GOLD.r, GOLD.g, GOLD.b, alpha)
		# 符字用三笔概括
		var dir := Vector2(cos(ang), sin(ang))
		var nrm := Vector2(-dir.y, dir.x)
		FxDraw.streak(self, Vector2(x, y) - dir * 7.0, Vector2(x, y) + dir * 7.0, 2.2, c)
		FxDraw.streak(self, Vector2(x, y) - nrm * 6.0, Vector2(x, y) + nrm * 6.0, 1.8, c)
		FxDraw.glow(self, Vector2(x, y), 8.0, Color(WING.r, WING.g, WING.b, alpha * 0.35), 2)


## ③ 灵蝶：绕目标螺旋盘旋，翅膀用两片椭圆概括。
func _draw_butterflies() -> void:
	var p := clampf((_t - 0.85) / 1.15, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var fade := sin(p * PI)
	for i in 5:
		var a := TAU * float(i) / 5.0 + _t * 2.2
		var r := 60.0 + 26.0 * sin(_t * 1.8 + float(i))
		var y := -90.0 - 40.0 * sin(_t * 1.3 + float(i) * 1.7)
		var pos := Vector2(cos(a) * r, y + sin(a) * 16.0)
		var flap := 0.35 + 0.65 * absf(sin(_t * 9.0 + float(i)))
		var c := Color(WING.r, WING.g, WING.b, fade * 0.8)
		var ang := a + PI * 0.5
		FxDraw.blade(self, pos, 16.0 * flap, 8.0, ang + 0.9, c)
		FxDraw.blade(self, pos, 16.0 * flap, 8.0, ang - 0.9, c)
		draw_circle(pos, 1.8, Color(1, 1, 1, fade * 0.9))


## ④ 光环：脚下金绿双环向外绽开，缓慢旋转。
func _draw_ring() -> void:
	var p := clampf((_t - 1.25) / 1.15, 0.0, 1.0)
	if p <= 0.0:
		return
	var ease_p := 1.0 - pow(1.0 - p, 3.0)
	var fade := 1.0 if p < 0.5 else clampf((1.0 - p) / 0.5, 0.0, 1.0)
	var r := 40.0 + 60.0 * ease_p
	FxDraw.ring(self, Vector2(0, 6), r, 3.0,
			Color(GOLD.r, GOLD.g, GOLD.b, 0.85 * fade))
	FxDraw.ring(self, Vector2(0, 6), r * 0.7, 2.0,
			Color(LEAF.r, LEAF.g, LEAF.b, 0.75 * fade))
	for i in 10:
		var a := -_t * 1.8 + TAU * float(i) / 10.0
		var dir := Vector2(cos(a), sin(a) * 0.42)
		FxDraw.blade(self, Vector2(0, 6) + dir * (r + 4.0), 12.0, 4.0, a,
				Color(LEAF.r, LEAF.g, LEAF.b, 0.7 * fade))

extends Node2D
## 药雾弥漫（yaowu_miman）· 单体中毒：药雾铺开 + 毒泡上浮 + 青烟。
##
## 时间轴（总 2.20s）：
##   0.00–0.50  药葫芦倾倒，雾团从中心喷出
##   0.20–1.30  药雾横向铺开笼罩目标
##   0.60–1.70  毒泡在雾中上浮，随机破裂闪十字光
##   0.50–1.90  目标脚下升起三缕青烟
##   1.70–2.20  雾散
##
## 用法：挂到每个被打到的目标脚下（target_effect_scene）。

const DURATION := 2.20
const MIST := Color(0.62, 0.95, 1.0)
const TOXIC := Color(0.78, 1.0, 0.55)
const WHITE := Color(0.92, 1.0, 0.98)
const GOLD := Color(1.0, 0.85, 0.5)

var _t := 0.0
var _tint := Color(0.7, 0.95, 0.8)


func _ready() -> void:
	z_index = 5
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat


func play(tint: Color = Color(0.7, 0.95, 0.8), _count: int = 0) -> void:
	_tint = tint
	_t = 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()
	if _t >= DURATION:
		queue_free()


func _draw() -> void:
	_draw_mist()
	_draw_bubbles()
	_draw_smoke()
	_draw_specks()


## ① 药雾：几团柔光气球状雾团向外推，带缓慢起伏。
func _draw_mist() -> void:
	var p := clampf(_t / 1.30, 0.0, 1.0)
	if p <= 0.0:
		return
	var fade := 1.0 if _t < 1.7 else clampf((2.2 - _t) / 0.5, 0.0, 1.0)
	var ease_p := 1.0 - pow(1.0 - p, 2.0)
	for i in 7:
		var a := TAU * float(i) / 7.0 + _t * 0.5
		var r := (30.0 + 92.0 * ease_p) * (0.7 + 0.3 * sin(float(i) * 1.9))
		var pos := Vector2(cos(a) * r * 0.9, -16.0 + sin(a) * r * 0.32)
		var size := (42.0 + 26.0 * ease_p) * (0.8 + 0.2 * sin(float(i) * 2.7))
		FxDraw.glow(self, pos, size, Color(MIST.r, MIST.g, MIST.b, 0.16 * fade), 4)
	# 中心更浓的一团
	FxDraw.glow(self, Vector2(0, -20), 70.0 + 40.0 * ease_p,
			Color(TOXIC.r, TOXIC.g, TOXIC.b, 0.12 * fade), 5)


## ② 毒泡：从下往上浮动，到一定高度破裂（画一个十字闪）。
func _draw_bubbles() -> void:
	var p := clampf((_t - 0.55) / 1.15, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var fade := 1.0 - p * 0.5
	for i in 18:
		var seed := float(i) * 2.399
		var start := fmod(seed, 1.0) * 0.5
		var local := clampf((p - start) / 0.5, 0.0, 1.0)
		if local <= 0.0 or local >= 1.0:
			continue
		var a := seed * 3.1 + _t * 1.2
		var r := 20.0 + fmod(seed * 7.0, 60.0)
		var y := -10.0 - 90.0 * local
		var pos := Vector2(cos(a) * r, y + sin(a) * 6.0)
		var radius := 3.0 + fmod(seed * 3.0, 4.0)
		var alpha := (1.0 - local) * 0.85 * fade
		draw_arc(pos, radius, 0.0, TAU, 14, Color(TOXIC.r, TOXIC.g, TOXIC.b, alpha), 1.8, true)
		draw_circle(pos, radius * 0.35, Color(WHITE.r, WHITE.g, WHITE.b, alpha * 0.7))
		# 破裂瞬间的十字闪
		if local > 0.82:
			var burst := (local - 0.82) / 0.18
			var bc := Color(WHITE.r, WHITE.g, WHITE.b, (1.0 - burst) * 0.9)
			FxDraw.streak(self, pos - Vector2(7, 0), pos + Vector2(7, 0), 2.4, bc)
			FxDraw.streak(self, pos - Vector2(0, 7), pos + Vector2(0, 7), 2.4, bc)


## ③ 青烟：三道自下而上飘散的细烟（用渐细的小圆点串起来）。
func _draw_smoke() -> void:
	var p := clampf((_t - 0.45) / 1.45, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var alpha := sin(p * PI) * 0.7
	for s in 3:
		var base_x := -34.0 + 34.0 * float(s)
		for k in 8:
			var tt := float(k) / 7.0
			var y := -4.0 - tt * (110.0 * p + 20.0)
			var x := base_x + sin(tt * 3.0 + _t * 2.0 + float(s)) * (8.0 + 10.0 * tt)
			draw_circle(Vector2(x, y), maxf(0.8, 3.6 * (1.0 - tt)),
					Color(MIST.r, MIST.g, MIST.b, alpha * (1.0 - tt * 0.7)))


## ④ 药渣碎屑：小颗粒随雾旋转，快速闪一下。
func _draw_specks() -> void:
	var p := clampf((_t - 0.20) / 1.50, 0.0, 1.0)
	if p <= 0.0 or p >= 1.0:
		return
	var fade := 1.0 - p
	for i in 26:
		var seed := float(i) * 1.618
		var a := seed * TAU + _t * 1.8
		var r := 18.0 + fmod(seed * 11.0, 80.0)
		var y := -8.0 + sin(seed * 5.0) * 40.0 - 24.0 * p
		var pos := Vector2(cos(a) * r, y + sin(a) * 12.0)
		draw_circle(pos, 1.4 + fmod(seed * 2.0, 1.2),
				Color(GOLD.r, GOLD.g, GOLD.b, fade * 0.7))


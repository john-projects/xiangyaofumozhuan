extends Node
class_name EffectTex

## 程序化贴图 + 共用材质工厂。
##
## 为什么需要它：粒子渲染的是"带贴图的四边形"，贴图决定 70% 的观感。
## 这里用 Godot 内置的 GradientTexture2D / NoiseTexture2D / ImageTexture 生成，
## 所以这套特效不需要任何外部素材就能跑，之后再换成手绘贴图也随时可以。

static var _glow: Texture2D
static var _dot: Texture2D
static var _ring: Texture2D
static var _noise: Texture2D
static var _additive: CanvasItemMaterial
static var _mix: CanvasItemMaterial


## 径向渐变光晕：中心白、向外淡出。火核 / 火团 / 闪光 / 浓烟都用它
static func glow() -> Texture2D:
	if _glow == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		# 中段保持较实，只在边缘陡降，看起来像一团火而不是一个模糊圆
		g.add_point(0.45, Color(1, 1, 1, 0.72))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(0.5, 0.0)
		t.width = 128
		t.height = 128
		_glow = t
	return _glow


## 硬质小亮点：火星用
static func dot() -> Texture2D:
	if _dot == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.55, Color(1, 1, 1, 1))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(0.5, 0.0)
		t.width = 24
		t.height = 24
		_dot = t
	return _dot


## 圆环：冲击波用。
## 只生成 64×64（4096 次 set_pixel，瞬间完成），靠纹理过滤放大，
## 对"发光圆环"这种软边图形完全够用，看不出低分辨率。
static func ring() -> Texture2D:
	if _ring == null:
		var size := 64
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var c := Vector2(size, size) * 0.5
		var outer := size * 0.5 - 1.0
		var inner := outer * 0.78
		var band := (outer - inner) * 0.5
		var mid := (inner + outer) * 0.5
		for y in size:
			for x in size:
				var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
				var a := clampf(1.0 - absf(d - mid) / band, 0.0, 1.0)
				img.set_pixel(x, y, Color(1, 1, 1, a))
		_ring = ImageTexture.create_from_image(img)
	return _ring


## 噪声：浓烟用。打碎边缘，避免"一堆圆球"的塑料感
## ⚠ 注意：这是【满幅不透明】的灰度图（全部像素 alpha = 1.0）。
## 直接当粒子贴图会渲染成硬邦邦的方块 —— 想要烟，请用下面的 smoke()。
static func noise() -> Texture2D:
	if _noise == null:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = 0.018
		n.fractal_octaves = 4
		var t := NoiseTexture2D.new()
		t.noise = n
		t.width = 128
		t.height = 128
		_noise = t
	return _noise


static var _smoke: Texture2D

## 浓烟贴图：噪声（打碎形状）+ 径向 alpha 遮罩（做出柔边）
##
## 为什么要自己合成：NoiseTexture2D 的 alpha 恒为 1，用它当粒子贴图 = 一堆不透明方块。
## 把噪声的亮度当"密度"、再乘一个从中心到边缘衰减的 alpha，
## 就得到"中心浓、边缘透"的烟团，放大后不会有硬边。
static func smoke() -> Texture2D:
	if _smoke == null:
		var size := 128
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = 0.022
		n.fractal_octaves = 4
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var c := Vector2(size, size) * 0.5
		var max_d := size * 0.5
		for y in size:
			for x in size:
				var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / max_d
				# 中心 55% 保持实心，之后平滑衰减到 0
				var falloff := 1.0 - smoothstep(0.0, 1.0, clampf((d - 0.55) / 0.45, 0.0, 1.0))
				# 噪声值当密度，映射到 0.35~1.0，避免整体太淡
				var dens := clampf(n.get_noise_2d(float(x), float(y)) * 0.5 + 0.5, 0.0, 1.0)
				dens = 0.35 + dens * 0.65
				img.set_pixel(x, y, Color(1, 1, 1, falloff * dens))
		_smoke = ImageTexture.create_from_image(img)
	return _smoke


## 加法混合：火 / 光 / 火星用（亮的东西叠起来更亮）
static func additive() -> CanvasItemMaterial:
	if _additive == null:
		_additive = CanvasItemMaterial.new()
		_additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return _additive


## 普通混合：浓烟用（烟是遮光的，用加法会变成发光的雾）
static func mix() -> CanvasItemMaterial:
	if _mix == null:
		_mix = CanvasItemMaterial.new()
		_mix.blend_mode = CanvasItemMaterial.BLEND_MODE_MIX
	return _mix


## 由采样点构造曲线（给 scale_curve 用，控制粒子随时间缩放）
## 注意：scale_curve 要的是 Texture2D，不是 Curve
static func curve(values: Array) -> CurveTexture:
	var c := Curve.new()
	var n := values.size()
	c.min_value = 0.0
	c.max_value = 2.0
	for i in n:
		var x := 0.0 if n <= 1 else float(i) / float(n - 1)
		c.add_point(Vector2(x, values[i]))
	var t := CurveTexture.new()
	t.curve = c
	return t


## 由颜色构造渐变（给 color_ramp 用，控制粒子随时间变色）
static func ramp(colors: Array) -> GradientTexture1D:
	var g := Gradient.new()
	g.set_color(0, colors[0])
	g.set_color(1, colors[colors.size() - 1])
	for i in range(1, colors.size() - 1):
		g.add_point(float(i) / float(colors.size() - 1), colors[i])
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


## 把一组颜色往某个色调靠拢（让特效跟随 SkillData.tint 变色）
static func tint_ramp(colors: Array, tint: Color) -> GradientTexture1D:
	var out := []
	for c in colors:
		out.append(Color(c.r * tint.r, c.g * tint.g, c.b * tint.b, c.a))
	return ramp(out)

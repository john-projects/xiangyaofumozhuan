extends RefCounted
## 静态立绘的「手持武器光效」工具：给一个 Sprite2D 套上
##   ① 外发光 + 呼吸 + 流光（shader）
##   ② 5 帧光环（AnimatedSprite2D）
##   ③ 飘散粒子（GPUParticles2D）
## 全部按装备品质（item_tier 0~4）分级，白装无光效。
##
## 用法（world_map / battle_unit 里）：
##   HeldWeaponFx.apply(sprite, item.item_tier)

## 各品质：光色 / 强度 / 粒子数 / 速度
const TIER_FX := [
	{"color": Color(1.00, 1.00, 1.00), "strength": 0.0, "amount": 0,  "speed": 0.0},
	{"color": Color(0.35, 0.66, 1.00), "strength": 0.9, "amount": 6,  "speed": 1.6},
	{"color": Color(0.71, 0.42, 1.00), "strength": 1.5, "amount": 12, "speed": 2.2},
	{"color": Color(1.00, 0.48, 0.82), "strength": 2.1, "amount": 20, "speed": 2.8},
	{"color": Color(1.00, 0.62, 0.23), "strength": 2.8, "amount": 30, "speed": 3.6},
]

const GLOW_SHADER := "res://scenes/characters/weapon_glow.gdshader"
const FX_SHEET := "res://assets/sprites/effects/weapon_fx_5.png"
const SPARK := "res://assets/sprites/effects/spark.png"
const FX_FRAMES := 5


## 给 sprite 套上对应品质的光效。重复调用会更新参数，不会重复建节点。
static func apply(sprite: Sprite2D, tier: int) -> void:
	if sprite == null:
		return
	var t := clampi(tier, 0, TIER_FX.size() - 1)
	var cfg: Dictionary = TIER_FX[t]
	var strength := float(cfg["strength"])

	# ① shader
	if strength <= 0.001:
		sprite.material = null
	else:
		var mat := sprite.material as ShaderMaterial
		if mat == null or mat.shader == null:
			var sh: Shader = load(GLOW_SHADER)
			if sh != null:
				mat = ShaderMaterial.new()
				mat.shader = sh
				sprite.material = mat
		if mat != null:
			mat.set_shader_parameter("glow_color", cfg["color"])
			mat.set_shader_parameter("glow_strength", strength)
			# 静态立绘里武器只有 ~87px，外发光宽度要小
			mat.set_shader_parameter("glow_width", 0.010 + 0.004 * strength)
			mat.set_shader_parameter("pulse_speed", 1.2 + 0.7 * float(cfg["speed"]))
			mat.set_shader_parameter("sweep_speed", 0.0 if t <= 1 else 0.35 + 0.22 * float(cfg["speed"]))

	_apply_frames(sprite, t, cfg)
	_apply_particles(sprite, cfg)


# ── 5 帧光环 ──
static func _apply_frames(sprite: Sprite2D, tier: int, cfg: Dictionary) -> void:
	var node := sprite.get_node_or_null("WeaponGlowFx") as AnimatedSprite2D
	if tier <= 0:
		if node != null:
			node.visible = false
		return

	if node == null:
		node = _make_frames(sprite)
		if node == null:
			return
	node.sprite_frames.set_animation_speed("fx", 9.0 * (1.0 + 0.35 * float(cfg["speed"])))
	node.scale = Vector2.ONE * (0.42 + 0.10 * float(cfg["strength"]))
	var col: Color = cfg["color"]
	col.a = clampf(0.45 + 0.22 * float(cfg["strength"]), 0.0, 1.0)
	node.modulate = col
	node.visible = true
	if not node.is_playing():
		node.play("fx")


static func _make_frames(sprite: Sprite2D) -> AnimatedSprite2D:
	if not ResourceLoader.exists(FX_SHEET):
		return null
	var sheet: Texture2D = load(FX_SHEET)
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")
	sf.add_animation("fx")
	sf.set_animation_loop("fx", true)
	sf.set_animation_speed("fx", 9.0)
	var fw := sheet.get_width() / FX_FRAMES
	var fh := sheet.get_height()
	for i in range(FX_FRAMES):
		var at := AtlasTexture.new()
		at.atlas = sheet
		at.region = Rect2(i * fw, 0, fw, fh)
		sf.add_frame("fx", at)

	var node := AnimatedSprite2D.new()
	node.name = "WeaponGlowFx"
	node.sprite_frames = sf
	node.animation = "fx"
	node.centered = true
	node.z_index = -1
	# 放在武器中心
	var w := 0.0
	var h := 0.0
	if sprite.texture != null:
		w = sprite.texture.get_width() * sprite.scale.x
		h = sprite.texture.get_height() * sprite.scale.y
	node.position = sprite.position + Vector2(w * 0.5, h * 0.5)
	sprite.get_parent().add_child(node)
	return node


# ── 粒子 ──
static func _apply_particles(sprite: Sprite2D, cfg: Dictionary) -> void:
	var fx := sprite.get_node_or_null("WeaponFx") as GPUParticles2D
	var amount := int(cfg["amount"])
	if amount <= 0:
		if fx != null:
			fx.emitting = false
		return
	if fx == null:
		fx = _make_particles(sprite)
		if fx == null:
			return
	fx.amount = amount
	fx.modulate = cfg["color"]
	fx.speed_scale = maxf(0.35, float(cfg["speed"]))
	fx.emitting = true


static func _make_particles(sprite: Sprite2D) -> GPUParticles2D:
	if not ResourceLoader.exists(SPARK):
		return null
	var fx := GPUParticles2D.new()
	fx.name = "WeaponFx"
	fx.texture = load(SPARK)
	fx.amount = 12
	fx.lifetime = 0.9
	fx.randomness = 0.8
	fx.local_coords = false
	fx.z_index = 2
	fx.emitting = false

	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	# 立绘里的武器只有 ~87px，盒子小一点
	m.emission_box_extents = Vector3(16, 40, 1)
	m.direction = Vector3(0, -1, 0)
	m.spread = 55.0
	m.initial_velocity_min = 6.0
	m.initial_velocity_max = 20.0
	m.gravity = Vector3(0, -14, 0)
	m.scale_min = 0.08
	m.scale_max = 0.22
	m.damping_min = 4.0
	m.damping_max = 10.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0))
	ramp.set_color(1, Color(1, 1, 1, 0))
	ramp.add_point(0.25, Color(1, 1, 1, 1))
	ramp.add_point(0.7, Color(1, 1, 1, 0.6))
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	m.color_ramp = rt
	fx.process_material = m

	sprite.add_child(fx)
	return fx

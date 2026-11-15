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
	{"color": Color(1.00, 1.00, 1.00), "strength": 0.0, "amount": 0, "speed": 0.0},
	{"color": Color(0.35, 0.66, 1.00), "strength": 0.9, "amount": 30, "speed": 1.5},
	{"color": Color(0.71, 0.42, 1.00), "strength": 0.9, "amount": 30, "speed": 1.5},
	{"color": Color(1.00, 0.48, 0.82), "strength": 0.9, "amount": 30, "speed": 1.5},
	{"color": Color(1.00, 0.62, 0.23), "strength": 0.9, "amount": 30, "speed": 1.5},
]

const GLOW_SHADER := "res://scenes/characters/weapon_glow.gdshader"
const FX_SHEET := "res://assets/sprites/effects/weapon_fx_5.png"
const SPARK := "res://assets/sprites/effects/spark.png"
const FX_FRAMES := 5
## 在 256×256 缩略图上标记扇轴和扇沿半径，按手持图套装序号排列。
const FAN_AXES := [
	Vector3(123, 184, 111), Vector3(128, 184, 112), Vector3(123, 186, 113), Vector3(119, 163, 103),
	Vector3(120, 169, 107), Vector3(126, 170, 106), Vector3(117, 176, 111), Vector3(121, 178, 105),
	Vector3(118, 174, 108), Vector3(117, 173, 108), Vector3(118, 183, 115), Vector3(127, 180, 111),
	Vector3(129, 181, 112), Vector3(118, 173, 105), Vector3(122, 177, 111), Vector3(122, 168, 104),
]
## 每只爪选三条清晰的刃口。每条用 (指节 x, y, 爪尖 x, y) 标记。
const CLAW_BLADES := [
	[Vector4(68, 153, 102, 226), Vector4(98, 143, 129, 222), Vector4(126, 133, 166, 207)],
	[Vector4(87, 158, 133, 227), Vector4(113, 146, 155, 221), Vector4(137, 137, 173, 209)],
	[Vector4(87, 170, 81, 233), Vector4(114, 164, 132, 235), Vector4(142, 154, 168, 221)],
	[Vector4(86, 155, 128, 234), Vector4(113, 139, 153, 224), Vector4(138, 125, 182, 206)],
	[Vector4(92, 156, 117, 225), Vector4(119, 147, 146, 219), Vector4(142, 135, 173, 205)],
	[Vector4(97, 161, 114, 220), Vector4(114, 159, 142, 230), Vector4(135, 154, 168, 223)],
	[Vector4(78, 163, 122, 233), Vector4(110, 154, 147, 236), Vector4(140, 147, 174, 223)],
	[Vector4(59, 169, 79, 232), Vector4(93, 167, 128, 235), Vector4(125, 158, 148, 230)],
	[Vector4(76, 166, 124, 237), Vector4(107, 157, 134, 234), Vector4(134, 143, 164, 223)],
	[Vector4(84, 172, 101, 225), Vector4(103, 167, 137, 233), Vector4(128, 160, 154, 233)],
	[Vector4(71, 172, 110, 235), Vector4(103, 164, 133, 236), Vector4(137, 154, 164, 223)],
	[Vector4(80, 164, 131, 233), Vector4(113, 156, 151, 225), Vector4(144, 149, 179, 218)],
	[Vector4(67, 174, 111, 236), Vector4(96, 164, 144, 232), Vector4(128, 157, 156, 223)],
	[Vector4(72, 166, 86, 225), Vector4(98, 162, 120, 218), Vector4(124, 158, 128, 230)],
	[Vector4(57, 173, 70, 229), Vector4(88, 164, 114, 235), Vector4(117, 153, 164, 217)],
	[Vector4(70, 169, 84, 232), Vector4(101, 165, 120, 229), Vector4(129, 156, 144, 222)],
]
const ANIM_LAYOUT := preload("res://scenes/characters/weapon_anim_layout.gd")
const ANIM_CELL := 448


## 给 sprite 套上对应品质的光效。重复调用会更新参数，不会重复建节点。
static func apply(sprite: Sprite2D, tier: int, item_ref = null) -> void:
	if sprite == null:
		return
	var host := sprite.get_parent() as Node2D
	if host == null:
		return
	host.show()
	# Animation and quality effects are independent layers.
	_apply_anim(sprite, anim_path(item_ref))
	var t := clampi(tier, 0, TIER_FX.size() - 1)
	var cfg: Dictionary = TIER_FX[t]
	var weapon_type := int(item_ref.weapon_type) if item_ref != null else 0
	# 昆仑及后续八档已有动画光效，降低额外光环与散射粒子。
	var subdued_spear := weapon_type == 4 and int(item_ref.req_level) >= 80
	if subdued_spear:
		cfg = cfg.duplicate()
		cfg["strength"] = float(cfg["strength"]) * 0.60
		cfg["amount"] = roundi(float(cfg["amount"]) * 0.35)
		cfg["halo_alpha"] = 0.32
	# 白装扇、爪也有专属流光，但仍不挂通用品质光环。
	if t == 0 and (weapon_type == 3 or weapon_type == 6):
		cfg = cfg.duplicate()
		cfg["strength"] = 0.42
		cfg["color"] = Color(0.67, 0.85, 1.0)
	var strength := float(cfg["strength"])
	# ① shader
	if strength <= 0.001:
		_set_style_clock(sprite, null, null, 0)
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
			mat.set_shader_parameter("glow_width", 0.005 + 0.002 * strength)
			mat.set_shader_parameter("pulse_speed", 1.2 + 0.7 * float(cfg["speed"]))
			mat.set_shader_parameter("sweep_speed", 0.0 if t <= 1 else 0.35 + 0.22 * float(cfg["speed"]))
			mat.set_shader_parameter("sweep_strength", 0.85 if subdued_spear else 1.5)

	var active_anim := host.get_node_or_null("WeaponAnim") as AnimatedSprite2D
	if active_anim != null:
		active_anim.material = sprite.material
	_apply_weapon_fx(sprite, t, cfg, weapon_type)
	_align_weapon_bottom(sprite, weapon_type)


static func _apply_weapon_fx(sprite: Sprite2D, tier: int, cfg: Dictionary, weapon_type: int) -> void:
	var host := sprite.get_parent()
	if host == null:
		return
	var layout := {}
	var compact := weapon_type == 3 or weapon_type == 6
	if tier > 0 or compact:
		var visual: Node2D = sprite
		var texture := sprite.texture
		var origin := sprite.get_rect().position
		var anim := host.get_node_or_null("WeaponAnim") as AnimatedSprite2D
		if anim != null and anim.visible:
			visual = anim
			texture = anim.sprite_frames.get_frame_texture("fx", 0)
			origin = anim.offset
			if anim.centered:
				origin -= texture.get_size() * 0.5
			anim.material = sprite.material
			var frame_key := str(anim.get_meta("sheet_path", "")).get_file().get_basename()
			if ANIM_LAYOUT.FRAMES.has(frame_key):
				var frame_layout: Vector3 = ANIM_LAYOUT.FRAMES[frame_key]
				anim.set_meta("fx_grip", Vector2(frame_layout.x, frame_layout.y))
			_set_style_clock(sprite, null, null, 0)
			if anim.material is ShaderMaterial:
				anim.material.set_shader_parameter("glow_width", 0.0018)
		if texture != null:
			var shape := _measure_weapon(visual, texture, compact)
			_configure_style(visual, origin, texture.get_size(), sprite.texture, shape, weapon_type, cfg)
			var start: Vector2 = visual.transform * (origin + shape[0])
			var end: Vector2 = visual.transform * (origin + shape[1])
			var axis := end - start
			var size: Vector2 = shape[2] * visual.scale.abs()
			layout = {
				"glow": end,
				"glow_size": maxf(size.x, size.y) * 0.65,
				"center": (start + end) * 0.5,
				"angle": visual.rotation if compact else axis.angle(),
				"extents": size * 0.36 if compact else Vector2(
					axis.length() * 0.42, minf(size.x, size.y) * 0.18),
				"compact": compact,
			}
	_apply_frames(host, cfg, layout if tier > 0 else {})
	_apply_particles(host, cfg, layout)


static func _configure_style(visual: Node2D, origin: Vector2, texture_size: Vector2,
		base_texture: Texture2D, shape: PackedVector2Array, weapon_type: int, cfg: Dictionary) -> void:
	var material := visual.material as ShaderMaterial
	if material == null:
		return
	var style := 1 if weapon_type == 3 else (2 if weapon_type == 6 else 0)
	material.set_shader_parameter("style_mode", style)
	material.set_shader_parameter("style_origin", origin)
	material.set_shader_parameter("style_size", texture_size)
	_set_style_clock(visual, material, base_texture, style)
	if style == 0:
		return
	material.set_shader_parameter("style_phase", float(visual.get_instance_id() % 29) / 29.0)
	material.set_shader_parameter("glow_strength", float(cfg["strength"]) * 0.48)
	var index := -1
	if base_texture != null and base_texture.resource_path.begins_with("res://assets/sprites/weapons_held/"):
		index = int(base_texture.resource_path.get_file().get_basename()) - 1
	var color: Color = cfg["color"]
	if style == 1:
		var center := (shape[0] + Vector2(0.0, shape[2].y * 0.18)) / texture_size
		var fan := Vector3(center.x, center.y, shape[2].x * 0.53 / texture_size.x)
		if visual is Sprite2D and index >= 0 and index < FAN_AXES.size():
			fan = FAN_AXES[index] / 256.0
		if index == 4:
			color = Color(0.58, 1.0, 0.88)
		material.set_shader_parameter("fan_axis", fan)
	else:
		var paths: Array = []
		if visual is Sprite2D and index >= 0 and index < CLAW_BLADES.size():
			for blade: Vector4 in CLAW_BLADES[index]:
				paths.append(blade / 256.0)
		else:
			var center := shape[0] / texture_size
			var size := shape[2] / texture_size
			for i in range(3):
				var start := center + size * Vector2(-0.26 + 0.19 * i, -0.06 - 0.07 * i)
				var tip := start + size * Vector2(0.19, 0.43)
				paths.append(Vector4(start.x, start.y, tip.x, tip.y))
		for i in range(3):
			material.set_shader_parameter("claw_path_%d" % i, paths[i])
		if index == 5:
			color = Color(1.0, 0.62, 0.25)
		elif index == 9:
			color = Color(0.65, 0.57, 1.0)
	material.set_shader_parameter("style_color", color)


## 武器刚显示时立刻开始第一轮，同一件武器重复刷新时保留播放进度。
static func _set_style_clock(visual: Node2D, material: ShaderMaterial, texture: Texture2D, style: int) -> void:
	var key := [material, texture, style]
	if visual.has_meta("fx_style_clock"):
		if style != 0 and visual.get_meta("fx_style_key") == key:
			return
		var previous: Tween = visual.get_meta("fx_style_clock")
		previous.kill()
		visual.remove_meta("fx_style_clock")
		visual.remove_meta("fx_style_key")
	if style == 0 or not visual.is_inside_tree():
		return
	material.set_shader_parameter("style_clock", 0.0)
	var clock := visual.create_tween().set_loops()
	clock.tween_property(material, "shader_parameter/style_clock", 240.0, 240.0).from(0.0)
	visual.set_meta("fx_style_clock", clock)
	visual.set_meta("fx_style_key", key)


## 在贴图坐标中测量握端、尖端和可见尺寸，排除透明留白与很淡的光晕。
static func _measure_weapon(visual: Node2D, texture: Texture2D, compact: bool) -> PackedVector2Array:
	if visual.has_meta("fx_texture") and visual.get_meta("fx_texture") == texture and visual.get_meta("fx_compact") == compact:
		return visual.get_meta("fx_shape")
	var image := texture.get_image()
	var size := texture.get_size()
	var grip: Vector2 = visual.get_meta("fx_grip", HELD_GRIP * (size / 1024.0))
	var points := PackedVector2Array()
	var bounds := Rect2()
	var sum := Vector2.ZERO
	var nearest := INF
	if image != null and not image.is_empty():
		if image.is_compressed():
			image.decompress()
		if not image.is_compressed():
			var step := maxi(1, int(maxf(size.x, size.y) / 200.0))
			for y in range(0, image.get_height(), step):
				for x in range(0, image.get_width(), step):
					if image.get_pixel(x, y).a < 0.45:
						continue
					var point := Vector2(x + 0.5, y + 0.5)
					bounds = Rect2(point, Vector2.ZERO) if points.is_empty() else bounds.expand(point)
					points.append(point)
					sum += point
	var start := size * 0.5
	var end := start
	if not points.is_empty():
		start = sum / float(points.size())
		end = start
		size = bounds.size
		if not compact:
			for point in points:
				var distance := point.distance_squared_to(grip)
				if distance < nearest:
					nearest = distance
					start = point
			var farthest := 0.0
			for point in points:
				farthest = maxf(farthest, point.distance_squared_to(start))
			# 取尖端附近实体的中心，避免个别火星把光环拉离刀尖。
			var tip_sum := Vector2.ZERO
			var tip_count := 0
			for point in points:
				if point.distance_squared_to(start) >= farthest * 0.82:
					tip_sum += point
					tip_count += 1
			if tip_count > 0:
				end = tip_sum / float(tip_count)
	var shape := PackedVector2Array([start, end, size])
	visual.set_meta("fx_texture", texture)
	visual.set_meta("fx_compact", compact)
	visual.set_meta("fx_shape", shape)
	return shape


# ── 5 帧光环 ──
static func _apply_frames(host: Node, cfg: Dictionary, layout: Dictionary) -> void:
	var node := host.get_node_or_null("WeaponGlowFx") as AnimatedSprite2D
	if layout.is_empty():
		if node != null:
			node.pause()
			node.hide()
		return

	if node == null:
		node = _make_frames(host)
		if node == null:
			return
	node.sprite_frames.set_animation_speed("fx", 9.0 * (1.0 + 0.35 * float(cfg["speed"])))
	var sheet_w := node.sprite_frames.get_frame_texture("fx", 0).get_width()
	node.scale = Vector2.ONE * (float(layout["glow_size"]) / maxf(1.0, sheet_w))
	node.position = layout["glow"]
	var col: Color = cfg["color"]
	col.a = 0.18 if layout.get("compact", false) else float(cfg.get("halo_alpha", 1.0))
	node.modulate = col
	node.visible = true
	if not node.is_playing():
		node.play("fx")


static func _make_frames(host: Node) -> AnimatedSprite2D:
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
	node.z_index = 0
	host.add_child(node)
	host.move_child(node, 0)
	return node


# ── 粒子 ──
static func _apply_particles(host: Node, cfg: Dictionary, layout: Dictionary) -> void:
	var fx := host.get_node_or_null("WeaponFx") as GPUParticles2D
	var amount := int(cfg["amount"])
	# 扇沿和爪尖的点光由材质定点绘制。
	if amount <= 0 or layout.is_empty() or layout.get("compact", false):
		if fx != null:
			fx.emitting = false
			fx.hide()
		return
	if fx == null:
		fx = _make_particles(host)
		if fx == null:
			return
	fx.amount = amount
	fx.position = layout["center"]
	fx.rotation = layout["angle"]
	var extents: Vector2 = layout["extents"]
	var material := fx.process_material as ParticleProcessMaterial
	material.emission_box_extents = Vector3(extents.x, extents.y, 1.0)
	fx.visibility_rect = Rect2(-extents, extents * 2.0).grow(350.0)
	fx.modulate = cfg["color"]
	fx.speed_scale = maxf(0.35, float(cfg["speed"]))
	fx.show()
	fx.emitting = true


static func _make_particles(host: Node) -> GPUParticles2D:
	if not ResourceLoader.exists(SPARK):
		return null
	var fx := GPUParticles2D.new()
	fx.name = "WeaponFx"
	fx.texture = load(SPARK)
	fx.amount = 12
	fx.lifetime = 1.4
	fx.randomness = 0.8
	fx.local_coords = true
	fx.z_index = 0
	fx.emitting = false

	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.direction = Vector3(0, -1, 0)
	m.spread = 180.0
	m.initial_velocity_min = 70.0
	m.initial_velocity_max = 210.0
	m.gravity = Vector3(0, -30, 0)
	m.scale_min = 0.45
	m.scale_max = 1.10
	m.damping_min = 20.0
	m.damping_max = 60.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0))
	ramp.set_color(1, Color(1, 1, 1, 0))
	ramp.add_point(0.25, Color(1, 1, 1, 1))
	ramp.add_point(0.7, Color(1, 1, 1, 0.6))
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	m.color_ramp = rt
	fx.process_material = m

	host.add_child(fx)
	return fx


## 该武器的动画条带路径（没有动画的武器返回空串）
static func anim_path(item) -> String:
	if item == null:
		return ""
	var wt := int(item.weapon_type)
	if wt < 1 or wt > 6:
		return ""
	# 套装序号：依次尝试 ① .tres 文件名 ② 图标文件名 ③ 需求等级推算
	var idx := 0
	var rp: String = item.resource_path
	if rp != "":
		var m := RegEx.create_from_string("item_(\\d+)_").search(rp.get_file())
		if m != null:
			idx = int(m.get_string(1))
	if idx <= 0 and item.item_icon != null and item.item_icon.resource_path != "":
		var m2 := RegEx.create_from_string("_(\\d+)\\.png$").search(item.item_icon.resource_path)
		if m2 != null:
			idx = int(m2.get_string(1))
	if idx <= 0:
		idx = int(floor(int(item.req_level) / 10.0)) + 1
	idx = clampi(idx, 1, 16)
	var path := "res://assets/sprites/units/players/weapon_anim/%d_%02d.png" % [wt, idx]
	return path if ResourceLoader.exists(path) else ""


## 清除手持武器，包括作为静态精灵兄弟节点的动画。
static func hide_weapon(body: Sprite2D) -> void:
	if body == null:
		return
	var host := body.get_parent() as Node2D
	if host == null:
		return
	host.hide()
	var anim := host.get_node_or_null("WeaponAnim") as AnimatedSprite2D
	if anim != null:
		anim.pause()
	_apply_frames(host, {}, {})
	_apply_particles(host, {"amount": 0}, {})


## 让单帧中的握点对准父节点 WeaponPivot。
static func _apply_anim(body: Sprite2D, path: String) -> bool:
	var host := body.get_parent()
	var node := host.get_node_or_null("WeaponAnim") as AnimatedSprite2D
	var key := path.get_file().get_basename()
	if path.is_empty() or not ANIM_LAYOUT.FRAMES.has(key):
		if node != null:
			node.pause()
			node.hide()
		body.show()
		return false

	if node != null and node.get_meta("sheet_path", "") != path:
		host.remove_child(node)
		node.queue_free()
		node = null
	if node == null:
		node = _make_anim(host, path)
		if node == null:
			body.show()
			return false
		node.set_meta("sheet_path", path)

	var frame_layout: Vector3 = ANIM_LAYOUT.FRAMES[key]
	var static_height := float(body.texture.get_height()) * body.scale.y if body.texture != null else float(ANIM_CELL)
	var k := float(body.get_meta("target_h", static_height)) * frame_layout.z
	node.scale = Vector2.ONE * k
	node.position = -Vector2(frame_layout.x, frame_layout.y) * k
	node.show()
	body.hide()
	if not node.is_playing():
		node.play("fx")
	return true


static func _make_anim(parent: Node, sheet_path: String) -> AnimatedSprite2D:
	var sheet := load(sheet_path) as Texture2D
	if sheet == null or sheet.get_size() != Vector2(ANIM_CELL * 4, ANIM_CELL * 2):
		return null
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("fx")
	frames.set_animation_loop("fx", true)
	frames.set_animation_speed("fx", 8.0)
	for i in range(8):
		var frame := AtlasTexture.new()
		frame.atlas = sheet
		frame.region = Rect2((i % 4) * ANIM_CELL, floori(float(i) / 4.0) * ANIM_CELL, ANIM_CELL, ANIM_CELL)
		frame.filter_clip = true
		frames.add_frame("fx", frame)

	var node := AnimatedSprite2D.new()
	node.name = "WeaponAnim"
	node.sprite_frames = frames
	node.animation = "fx"
	node.centered = false
	parent.add_child(node)
	return node


# ── 手持图（和背包图标分开的一套）──

## 手持图的握把点在贴图里的坐标（见 make_held_weapons.py）
const HELD_GRIP := Vector2(120, 950)
## 枪尾在对齐后的动画格中的坐标。
const SPEAR_ANIM_TAIL := Vector2(69.73, 374.78)

## 各类型的武器长度 = **角色身高的几倍**（不是绝对像素）。
## 立绘本体会被缩到 ~195px，用绝对像素会变成只有几十像素。
const HELD_RATIO := {
	1: 1.72,   # 剑（调大：之前和刀共用 1.55，显得小）
	2: 1.38,   # 刀（调小：之前和剑共用 1.55，显得大）
	3: 1.35,   # 扇
	4: 2.05 * 0.75,   # 枪
	5: 1.55,   # 杖
	6: 1.05,   # 爪（调小）
}

## 手持图路径：weapons_held/<weapon_type>/<套装>.png；没有就返回空
static func held_path(item) -> String:
	if item == null:
		return ""
	var wt := int(item.weapon_type)
	if wt < 1 or wt > 6:
		return ""
	var idx := 0
	var rp: String = item.resource_path
	if rp != "":
		var m := RegEx.create_from_string("item_(\\d+)_").search(rp.get_file())
		if m != null:
			idx = int(m.get_string(1))
	if idx <= 0 and item.item_icon != null and item.item_icon.resource_path != "":
		var m2 := RegEx.create_from_string("_(\\d+)\\.png$").search(item.item_icon.resource_path)
		if m2 != null:
			idx = int(m2.get_string(1))
	if idx <= 0:
		idx = int(floor(int(item.req_level) / 10.0)) + 1
	idx = clampi(idx, 1, 16)
	var path := "res://assets/sprites/weapons_held/%d/%02d.png" % [wt, idx]
	return path if ResourceLoader.exists(path) else ""


## 拿手持图；没有就退回背包图标
static func held_texture(item) -> Texture2D:
	var p := held_path(item)
	if p != "":
		return load(p)
	return item.item_icon if item != null else null


## 该武器相对角色身高的长度比例
static func held_ratio(item) -> float:
	var wt := int(item.weapon_type) if item != null else 0
	return float(HELD_RATIO.get(wt, 1.55))


## Align the visible weapon to the portrait's feet, moving the whole FX group.
## Measure once on refresh, never per animation frame (avoids vertical jitter).
static func _align_weapon_bottom(body: Sprite2D, weapon_type: int) -> void:
	var pivot := body.get_parent() as Node2D
	if pivot == null:
		return
	var portrait := pivot.get_parent() as Sprite2D
	if portrait == null or portrait.texture == null:
		return
	var visual: Node2D = body
	var textures: Array[Texture2D] = [body.texture]
	var origin := body.get_rect().position
	var anim := pivot.get_node_or_null("WeaponAnim") as AnimatedSprite2D
	if weapon_type == 4:
		# 以硬质枪尾对齐脚底。飘带和光效的外轮廓不参与定位。
		var tail := pivot.transform * (anim.transform * SPEAR_ANIM_TAIL) if anim != null and anim.visible \
				else pivot.transform * (body.transform * (origin + HELD_GRIP))
		_align_tail_to_feet(pivot, portrait, tail.y)
		return
	if anim != null and anim.visible:
		visual = anim
		textures.clear()
		for frame in range(anim.sprite_frames.get_frame_count("fx")):
			textures.append(anim.sprite_frames.get_frame_texture("fx", frame))
		origin = anim.offset
		if anim.centered:
			origin -= textures[0].get_size() * 0.5
	var weapon_bottom := -INF
	var transform_to_portrait := pivot.transform * visual.transform
	for texture in textures:
		if texture == null:
			continue
		var image := texture.get_image()
		if image == null:
			continue
		if image.is_compressed():
			image.decompress()
		# Ignore faint glow; include the visible tassels and ribbons.
		var step := maxi(1, int(maxi(image.get_width(), image.get_height()) / 200))
		for y in range(0, image.get_height(), step):
			for x in range(0, image.get_width(), step):
				if image.get_pixel(x, y).a >= 0.45:
					var point := transform_to_portrait * (origin + Vector2(x, y))
					weapon_bottom = maxf(weapon_bottom, point.y)
	if not is_finite(weapon_bottom):
		return
	_align_tail_to_feet(pivot, portrait, weapon_bottom)


static func _align_tail_to_feet(pivot: Node2D, portrait: Sprite2D, weapon_bottom: float) -> void:
	var portrait_image := portrait.texture.get_image()
	if portrait_image == null:
		return
	if portrait_image.is_compressed():
		portrait_image.decompress()
	var feet := portrait.get_rect().position.y + portrait_image.get_used_rect().end.y
	pivot.position.y += feet - weapon_bottom

## Use the base anchor on every refresh to prevent cumulative shifting.
static func weapon_hand_position(portrait: Sprite2D, base_position: Vector2) -> Vector2:
	if portrait == null or portrait.texture == null:
		return base_position
	var image := portrait.texture.get_image()
	if image == null:
		return base_position
	if image.is_compressed():
		image.decompress()
	return base_position + Vector2(float(image.get_used_rect().size.x) * 0.5, 0.0)

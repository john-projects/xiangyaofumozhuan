extends Node2D
## 星罗杀机 · 施法/增益光环 v2 —— 加大加华丽（纯程序化，零外部素材）。
##
## 观感：开场一蓬猩红火花迸发 → 脚下双层血色法环持续向外扩散（3 波）→
## 猩红杀气螺旋绕体盘旋上升 → 一道血色光柱自下而上撑起气势 →
## 心口暗红杀气骤亮骤暗 + 血尘上浮，约 2.6s 后淡出消散。
## 与紫霄凝神（紫雷 · 法系）区分：星罗走暗红杀伐路子，动静更大、明暗对比更狠。
##
## 接入：SkillData.hit_effect_scene 指向本场景（辅助技能 _spawn_support_effect()
## 没配 target_effect_scene 时会退回 hit_effect_scene，在目标脚下播放并调
## play(tint, count)：tint = SkillData.tint（品红 0.95, 0.5, 0.85））。
## 节点原点 = 单位脚下（origin 在脚底），所有层往上（-y）铺。
## 贴图全部来自 EffectTex 工厂，不用任何外部图片。

const DURATION := 2.6

var _played := false


func play(tint: Color = Color(0.95, 0.5, 0.85), particle_count: int = 20) -> void:
	if _played:
		return
	_played = true
	_build_opening_burst(tint, particle_count)   # 开场迸发（华丽感的"起手式"）
	_build_double_ring(tint)                     # 双层血色法环 + 扩散波
	_build_spiral(tint, particle_count)          # 螺旋绕体杀气
	_build_motes(tint, particle_count)           # 上升血尘
	_build_pillar(tint)                          # 血色光柱
	_build_kill_glow(tint)                       # 心口杀气
	# 收尾：最后 0.5s 整体淡出（同时让持续发射的粒子停喷，避免淡出时还冒新的）
	var tw := create_tween()
	tw.tween_interval(DURATION - 0.6)
	tw.tween_callback(_stop_emitting)
	tw.tween_property(self, "modulate:a", 0.0, 0.5)
	tw.tween_callback(queue_free)


## 开场迸发：一团暗红光斑炸开 + 猩红火花四溅（one-shot，起手撑住气势）。
func _build_opening_burst(tint: Color, particle_count: int) -> void:
	var s := Sprite2D.new()
	s.texture = EffectTex.glow()
	s.material = EffectTex.additive()
	s.modulate = Color(tint.r, tint.g * 0.4, tint.b * 0.6, 1.0)
	s.scale = Vector2(3.2, 2.0)
	s.position = Vector2(0, -20)
	add_child(s)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(s, "scale", Vector2(0.4, 0.3), 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(s, "modulate:a", 0.0, 0.4)

	var p := GPUParticles2D.new()
	p.amount = maxi(16, particle_count)
	p.lifetime = 0.5
	p.one_shot = true
	p.explosiveness = 1.0
	p.texture = EffectTex.dot()
	p.material = EffectTex.additive()
	p.position = Vector2(0, -24)
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, -1, 0)
	m.spread = 75.0
	m.initial_velocity_min = 180.0
	m.initial_velocity_max = 420.0
	m.gravity = Vector3(0, 700, 0)
	m.damping_min = 80.0
	m.damping_max = 140.0
	m.scale_min = 0.4
	m.scale_max = 0.9
	m.scale_curve = EffectTex.curve([1.3, 0.7, 0.1])
	m.color_ramp = EffectTex.tint_ramp([
		Color(1.0, 0.9, 0.9, 1.0),
		Color(1.0, 0.6, 0.6, 0.85),
		Color(1.0, 0.3, 0.3, 0.0),
	], tint)
	p.process_material = m
	p.emitting = true
	add_child(p)


## 双层血色法环：内环常驻急促脉动，外环一道道向外扩散（3 波冲击感）。
func _build_double_ring(tint: Color) -> void:
	# 内环：常驻脉动
	var inner := Sprite2D.new()
	inner.texture = EffectTex.ring()
	inner.material = EffectTex.additive()
	inner.modulate = Color(tint.r * 0.8, tint.g * 0.35, tint.b * 0.65, 0.95)
	inner.scale = Vector2(0.85, 0.32)
	add_child(inner)
	var tw := create_tween()
	tw.set_loops(3)
	tw.tween_property(inner, "scale", Vector2(1.15, 0.44), 0.4) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(inner, "scale", Vector2(0.85, 0.32), 0.4) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

	# 外环：3 波向外扩散淡出（错峰起跳，连绵不断）
	for wave in 3:
		var outer := Sprite2D.new()
		outer.texture = EffectTex.ring()
		outer.material = EffectTex.additive()
		outer.modulate = Color(tint.r, tint.g * 0.5, tint.b * 0.75, 0.0)
		outer.scale = Vector2(0.9, 0.34)
		add_child(outer)
		var wt := create_tween()
		wt.tween_interval(wave * 0.7)
		wt.tween_callback(func() -> void:
			outer.modulate.a = 0.85)
		wt.set_parallel(true)
		wt.tween_property(outer, "scale", Vector2(2.6, 1.0), 0.6) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		wt.tween_property(outer, "modulate:a", 0.0, 0.6) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


## 螺旋杀气：更大范围、更高转速，绕体盘旋的同时缓缓上升（v1 是平面转，v2 拧成螺旋）。
func _build_spiral(tint: Color, particle_count: int) -> void:
	var p := GPUParticles2D.new()
	p.amount = maxi(18, particle_count + 8)
	p.lifetime = 2.0
	p.texture = EffectTex.dot()
	p.material = EffectTex.additive()
	p.position = Vector2(0, -40)
	p.emitting = true
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 30.0
	m.gravity = Vector3(0, -55, 0)
	# ⚠ Godot 4.7 里"绕体盘旋"叫 angular_velocity（旧名 orbital_velocity 已移除）
	m.angular_velocity_min = -5.0
	m.angular_velocity_max = 5.0
	m.radial_velocity_min = 8.0
	m.radial_velocity_max = 30.0
	m.scale_min = 0.4
	m.scale_max = 0.85
	m.scale_curve = EffectTex.curve([0.4, 1.0, 0.5])
	m.color_ramp = EffectTex.tint_ramp([
		Color(1.0, 0.6, 0.6, 0.0),
		Color(1.0, 1.0, 1.0, 1.0),
		Color(1.0, 0.35, 0.4, 0.0),
	], tint)
	p.process_material = m
	add_child(p)


## 上升血尘：暗红碎屑从脚下往头顶飘。
func _build_motes(tint: Color, particle_count: int) -> void:
	var p := GPUParticles2D.new()
	p.amount = maxi(8, particle_count / 2)
	p.lifetime = 1.5
	p.texture = EffectTex.dot()
	p.material = EffectTex.additive()
	p.position = Vector2(0, -6)
	p.emitting = true
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(20, 4, 1)
	m.direction = Vector3(0, -1, 0)
	m.spread = 18.0
	m.initial_velocity_min = 25.0
	m.initial_velocity_max = 65.0
	m.gravity = Vector3(0, -18, 0)
	m.scale_min = 0.25
	m.scale_max = 0.55
	m.scale_curve = EffectTex.curve([0.3, 1.0, 0.0])
	m.color_ramp = EffectTex.tint_ramp([
		Color(1.0, 0.7, 0.7, 0.0),
		Color(1.0, 0.8, 0.8, 0.8),
		Color(1.0, 0.4, 0.4, 0.0),
	], tint)
	p.process_material = m
	add_child(p)


## 血色光柱：一道竖光自下而上撑起整体气势（alpha 呼吸 + 出现时从脚下升起）。
func _build_pillar(tint: Color) -> void:
	var s := Sprite2D.new()
	s.texture = _beam_tex()
	s.material = EffectTex.additive()
	s.modulate = Color(tint.r, tint.g * 0.45, tint.b * 0.7, 0.0)
	s.scale = Vector2(3.0, 0.78)
	s.position = Vector2(0, -84)
	add_child(s)
	var tw := create_tween()
	tw.tween_property(s, "modulate:a", 0.3, 0.35)
	tw.tween_property(s, "modulate:a", 0.14, 0.5)
	tw.tween_property(s, "modulate:a", 0.26, 0.5)
	tw.tween_property(s, "modulate:a", 0.0, 0.6)


## 心口杀气：一团暗红光斑骤亮骤暗（不规则闪烁 = 杀机涌动）。
func _build_kill_glow(tint: Color) -> void:
	var s := Sprite2D.new()
	s.texture = EffectTex.glow()
	s.material = EffectTex.additive()
	s.modulate = Color(tint.r * 0.7, tint.g * 0.25, tint.b * 0.55, 0.55)
	s.scale = Vector2(1.5, 1.9)
	s.position = Vector2(0, -40)   # 心口高度
	add_child(s)
	var tw := create_tween()
	for i in 4:
		tw.tween_property(s, "modulate:a", randf_range(0.15, 0.3), 0.18)
		tw.tween_property(s, "modulate:a", randf_range(0.6, 0.9), 0.12)
	tw.tween_property(s, "modulate:a", 0.2, 0.3)


## 淡出前停掉所有持续发射（粒子不再补充，随寿命自然消亡；one-shot 层不受影响）。
func _stop_emitting() -> void:
	for child in get_children():
		if child is GPUParticles2D:
			(child as GPUParticles2D).emitting = false


## 竖直光柱贴图：上下两端透明、中段实心（竖向线性渐变）。
func _beam_tex() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.0))
	g.set_color(1, Color(1, 1, 1, 0.0))
	g.add_point(0.2, Color(1, 1, 1, 0.9))
	g.add_point(0.55, Color(1, 1, 1, 1.0))
	g.add_point(0.85, Color(1, 1, 1, 0.55))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_LINEAR
	t.fill_from = Vector2(0.5, 0.0)
	t.fill_to = Vector2(0.5, 1.0)
	t.width = 32
	t.height = 256
	return t

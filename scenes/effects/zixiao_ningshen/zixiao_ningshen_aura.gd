extends Node2D
## 紫霄凝神 · 施法/增益光环（纯程序化，零外部素材）。
##
## 观感：施法者脚下泛起紫电法环并脉动，周身电屑绕体盘旋上升，
## 头顶一道淡淡的紫色雷光柱若隐若现，约 2.2s 后淡出消散。
##
## 接入：SkillData.hit_effect_scene 指向本场景（辅助技能 _spawn_support_effect()
## 没配 target_effect_scene 时会退回 hit_effect_scene，在目标脚下播放并调
## play(tint, count)：tint = SkillData.tint，count = SkillData.hit_particles）。
## 节点原点 = 单位脚下（origin 在脚底），所有层往上（-y）铺。
## 贴图全部来自 EffectTex 工厂，不用任何外部图片。

const DURATION := 2.2

var _played := false


func play(tint: Color = Color(0.8, 0.6, 1.0), particle_count: int = 20) -> void:
	if _played:
		return
	_played = true
	_build_ring(tint)
	_build_orbit(tint, particle_count)
	_build_motes(tint, particle_count)
	_build_pillar(tint)
	# 收尾：最后 0.5s 整体淡出（同时让绕体粒子停喷，避免淡出时还冒新的）
	var tw := create_tween()
	tw.tween_interval(DURATION - 0.6)
	tw.tween_callback(_stop_emitting)
	tw.tween_property(self, "modulate:a", 0.0, 0.5)
	tw.tween_callback(queue_free)


## 脚下法环：加法混合圆环，呼吸式脉动两次。
func _build_ring(tint: Color) -> void:
	var s := Sprite2D.new()
	s.texture = EffectTex.ring()
	s.material = EffectTex.additive()
	s.modulate = Color(tint.r, tint.g, tint.b, 0.85)
	s.scale = Vector2(0.75, 0.28)
	add_child(s)
	var tw := create_tween()
	tw.set_loops(2)
	tw.tween_property(s, "scale", Vector2(1.05, 0.38), 0.55) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(s, "scale", Vector2(0.75, 0.28), 0.55) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## 绕体电屑：围绕腰部一圈持续盘旋（轨道速度绕原点转）+ 缓缓上升。
func _build_orbit(tint: Color, particle_count: int) -> void:
	var p := GPUParticles2D.new()
	p.amount = maxi(10, particle_count)
	p.lifetime = 1.8
	p.texture = EffectTex.dot()
	p.material = EffectTex.additive()
	p.position = Vector2(0, -34)   # 腰部高度
	p.emitting = true
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 22.0
	m.gravity = Vector3(0, -30, 0)
	# ⚠ Godot 4.7 里"绕体盘旋"叫 angular_velocity（旧名 orbital_velocity 已移除）
	m.angular_velocity_min = -2.8
	m.angular_velocity_max = 2.8
	m.radial_velocity_min = 5.0
	m.radial_velocity_max = 20.0
	m.initial_velocity_min = 5.0
	m.initial_velocity_max = 15.0
	m.scale_min = 0.4
	m.scale_max = 0.8
	m.scale_curve = EffectTex.curve([0.4, 1.0, 0.5])
	m.color_ramp = EffectTex.tint_ramp([
		Color(1.0, 1.0, 1.0, 0.0),
		Color(1.0, 1.0, 1.0, 1.0),
		Color(1.0, 1.0, 1.0, 0.0),
	], tint)
	p.process_material = m
	add_child(p)


## 上升电尘：脚下往头顶飘的细碎光点（比绕体那层更慢更淡）。
func _build_motes(tint: Color, particle_count: int) -> void:
	var p := GPUParticles2D.new()
	p.amount = maxi(6, particle_count / 2)
	p.lifetime = 1.2
	p.texture = EffectTex.dot()
	p.material = EffectTex.additive()
	p.position = Vector2(0, -6)
	p.emitting = true
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(16, 4, 1)
	m.direction = Vector3(0, -1, 0)
	m.spread = 15.0
	m.initial_velocity_min = 30.0
	m.initial_velocity_max = 70.0
	m.gravity = Vector3(0, -20, 0)
	m.scale_min = 0.3
	m.scale_max = 0.6
	m.scale_curve = EffectTex.curve([0.3, 1.0, 0.0])
	m.color_ramp = EffectTex.tint_ramp([
		Color(1.0, 1.0, 1.0, 0.0),
		Color(1.0, 1.0, 1.0, 0.9),
		Color(1.0, 1.0, 1.0, 0.0),
	], tint)
	p.process_material = m
	add_child(p)


## 头顶雷光柱：一道淡淡的竖光若隐若现（alpha 呼吸）。
func _build_pillar(tint: Color) -> void:
	var s := Sprite2D.new()
	s.texture = _beam_tex()
	s.material = EffectTex.additive()
	s.modulate = Color(tint.r, tint.g, tint.b, 0.16)
	s.scale = Vector2(2.4, 0.62)
	s.position = Vector2(0, -70)
	add_child(s)
	var tw := create_tween()
	tw.set_loops(3)
	tw.tween_property(s, "modulate:a", 0.3, 0.35) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(s, "modulate:a", 0.12, 0.35) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## 淡出前停掉两处持续发射（粒子不再补充，随寿命自然消亡）。
func _stop_emitting() -> void:
	for child in get_children():
		if child is GPUParticles2D:
			(child as GPUParticles2D).emitting = false


## 竖直光柱贴图：上下两端透明、中段实心（和五雷正法命中那根同款，更淡更矮）。
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

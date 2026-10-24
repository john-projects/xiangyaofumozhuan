extends Node2D
## 五雷正法 · 命中特效（纯程序化，零外部素材）。
##
## 观感：一道紫雷光柱从天贯下劈中目标 —— 白热核心 + 紫色电弧外缘，
## 命中瞬间白光炸开、火星四溅、冲击波环铺开、水平电弧乱窜后熄灭。
##
## 接入：SkillData.hit_effect_scene 指向本场景。
## 公共弹道 burst() / Battle._spawn_hit_burst() 按鸭子类型调 play(tint, count)：
##   tint  = SkillData.tint（紫霄紫 0.75, 0.55, 1）
##   count = SkillData.hit_particles
## 节点原点 = 目标 body_center()（脚下往上抬半个身高），光柱贯穿原点。
## 贴图全部来自 EffectTex 工厂（glow/dot/ring），不用任何外部图片。

## 最长层（火星 0.6s + 闪烁淡出 0.5s）+ 余量
const LIFETIME := 1.5

var _played := false


func play(tint: Color = Color(0.75, 0.55, 1.0), particle_count: int = 24) -> void:
	if _played:
		return
	_played = true
	_build_beam(tint)
	_build_impact_core(tint)
	_build_flash(tint, particle_count)
	_build_sparks(tint, particle_count)
	_build_ring(tint)
	_build_crackle(tint, particle_count)
	get_tree().create_timer(LIFETIME).timeout.connect(queue_free)


## 天降雷柱：紫色电弧外缘（宽）+ 白热核心（窄）。
## 亮 0.14s → 外缘抖 3 下（电弧忽明忽暗）→ 一起淡出。
func _build_beam(tint: Color) -> void:
	var outer := _beam_sprite(Color(tint.r, tint.g, tint.b, 0.9), Vector2(2.6, 2.1), -30.0)
	var core := _beam_sprite(Color(1.0, 0.97, 1.0, 1.0), Vector2(1.0, 2.0), -30.0)
	add_child(outer)
	add_child(core)

	var tw := create_tween()
	tw.tween_interval(0.14)
	for i in 3:
		tw.tween_property(outer, "modulate:a", randf_range(0.25, 0.6), 0.045)
		tw.tween_property(outer, "modulate:a", 1.0, 0.045)
	tw.tween_property(outer, "modulate:a", 0.0, 0.28)

	var tw2 := create_tween()
	tw2.tween_interval(0.22)
	tw2.tween_property(core, "modulate:a", 0.0, 0.16)


## 命中白光：一个大光斑从亮缩到没（先于粒子，撑起"重击感"）。
func _build_impact_core(tint: Color) -> void:
	var s := Sprite2D.new()
	s.texture = EffectTex.glow()
	s.material = EffectTex.additive()
	s.modulate = Color(1.0, 0.95, 1.0, 1.0).lerp(tint, 0.35)
	s.scale = Vector2(2.4, 1.8)
	add_child(s)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(s, "scale", Vector2(0.5, 0.4), 0.3) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(s, "modulate:a", 0.0, 0.3)


## 闪光：白热向外铺开的一圈小光团。
func _build_flash(tint: Color, particle_count: int) -> void:
	var p := _one_shot_particles(maxi(8, particle_count / 2), 0.3, EffectTex.glow())
	var m := ParticleProcessMaterial.new()
	m.spread = 180.0
	m.initial_velocity_min = 60.0
	m.initial_velocity_max = 180.0
	m.gravity = Vector3.ZERO
	m.damping_min = 40.0
	m.damping_max = 80.0
	m.scale_min = 0.6
	m.scale_max = 1.4
	m.scale_curve = EffectTex.curve([1.6, 0.5])
	m.color_ramp = EffectTex.tint_ramp([
		Color(1.0, 1.0, 1.0, 1.0),
		Color(1.0, 1.0, 1.0, 0.6),
		Color(1.0, 1.0, 1.0, 0.0),
	], tint)
	p.process_material = m
	add_child(p)


## 火星：高速向四周甩出 + 重力下落 + 拖出渐短的紫电屑。
func _build_sparks(tint: Color, particle_count: int) -> void:
	var p := _one_shot_particles(maxi(12, particle_count * 2), 0.6, EffectTex.dot())
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, -1, 0)
	m.spread = 70.0
	m.initial_velocity_min = 240.0
	m.initial_velocity_max = 560.0
	m.gravity = Vector3(0, 980, 0)
	m.damping_min = 60.0
	m.damping_max = 120.0
	m.scale_min = 0.6
	m.scale_max = 1.3
	m.scale_curve = EffectTex.curve([1.1, 0.7, 0.15])
	m.color_ramp = EffectTex.tint_ramp([
		Color(1.0, 1.0, 1.0, 1.0),
		Color(1.0, 1.0, 1.0, 0.8),
		Color(1.0, 1.0, 1.0, 0.0),
	], tint)
	p.process_material = m
	add_child(p)


## 冲击波环：压扁成椭圆（横版透视），快速铺开淡出。
func _build_ring(tint: Color) -> void:
	var s := Sprite2D.new()
	s.texture = EffectTex.ring()
	s.material = EffectTex.additive()
	s.modulate = Color(tint.r, tint.g, tint.b, 1.0)
	s.scale = Vector2(0.5, 0.18)
	add_child(s)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(s, "scale", Vector2(2.6, 0.95), 0.32) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(s, "modulate:a", 0.0, 0.32) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


## 电弧乱窜：命中点附近水平窜动的短命电屑（雷的"噼啪"感全靠这层）。
func _build_crackle(tint: Color, particle_count: int) -> void:
	var p := _one_shot_particles(maxi(6, particle_count / 3), 0.16, EffectTex.dot())
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(1, 0, 0)
	m.spread = 85.0
	m.initial_velocity_min = 180.0
	m.initial_velocity_max = 420.0
	m.gravity = Vector3.ZERO
	m.damping_min = 200.0
	m.damping_max = 300.0
	m.scale_min = 0.5
	m.scale_max = 1.1
	m.scale_curve = EffectTex.curve([1.3, 0.3])
	m.color_ramp = EffectTex.tint_ramp([
		Color(1.0, 1.0, 1.0, 1.0),
		Color(1.0, 1.0, 1.0, 0.7),
		Color(1.0, 1.0, 1.0, 0.0),
	], tint)
	p.process_material = m
	p.position = Vector2(0, 26)
	add_child(p)


## ---- 小工具 ----

## 一次性爆发粒子骨架（one_shot + explosiveness 1，创建即喷）。
func _one_shot_particles(amount: int, lifetime: float, tex: Texture2D) -> GPUParticles2D:
	var p := GPUParticles2D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.one_shot = true
	p.explosiveness = 1.0
	p.texture = tex
	p.material = EffectTex.additive()
	p.emitting = true
	return p


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


## 按贴图 + 缩放 + 高度偏移拼一根光柱精灵（贴图 32×256，缩放后约 83×537 / 32×512）。
func _beam_sprite(color: Color, scl: Vector2, y_offset: float) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = _beam_tex()
	s.material = EffectTex.additive()
	s.modulate = color
	s.scale = scl
	s.position = Vector2(0, y_offset)
	return s

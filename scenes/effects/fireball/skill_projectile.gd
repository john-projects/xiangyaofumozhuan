extends Node2D
class_name SkillProjectile

## 技能飞行体 + 命中爆炸（8 层特效，零素材可跑）
##
## 用法（Battle 里，调用方式与之前完全一致）：
##   var p := SKILL_PROJECTILE_SCENE.instantiate() as SkillProjectile
##   fx_root.add_child(p)
##   p.setup(skill, caster.global_position)
##   await p.fly_to(target.global_position)   # 抵达那一刻返回
##   target.take_damage(dmg)                  # 结算伤害
##   p.burst()                                # 播爆炸并自动释放
##
## 8 层特效拆解：
##   飞行中 → 火核 FireCore / 拖尾 Line2D + TrailParticles / 火团 FireBlob / 火星 Sparks / 浓烟 Smoke
##   命中时 → 闪光 / 冲击波 / 火星溅射 / 浓烟（都在 burst_effect.tscn）+ 镜头震动（Battle 负责）
##
## 全部视觉参数来自 SkillData：贴图、缩放、速度、染色、粒子数量。
## 想换外观不用改代码，改 resources/skills/*.tres 即可。

const EffectTex := preload("res://scenes/effects/effect_tex.gd")
const BURST_EFFECT_SCENE := preload("res://scenes/effects/burst_effect.tscn")
## 默认序列帧火焰。本脚本现在就在 scenes/effects/fireball/ 下，所以是"同目录"引用
const DEFAULT_FIREBALL_SCENE := preload("res://scenes/effects/fireball/effect_fireball_1.tscn")

## 火色（不直接用 SkillData.tint，偏暗的染色会让火显脏；tint 只用在飞行体本体和拖尾上）
const FIRE_HOT := Color(1.0, 0.96, 0.78, 1.0)
const FIRE_MID := Color(1.0, 0.68, 0.22, 1.0)
const FIRE_LOW := Color(0.85, 0.28, 0.06, 0.7)
const FIRE_OUT := Color(0.30, 0.10, 0.04, 0.0)
const SMOKE_TINT := Color(0.30, 0.27, 0.25, 1.0)

var _skill: SkillData
var _cached_glow: Texture2D
var _cached_additive: CanvasItemMaterial
## 本次施法的飞行粒子强度系数（1.0 = 默认那套完整 8 层；frames_only 时会被压低）
var _flight_ratio := 1.0
## 头部粒子（火核 / 火团）强度：保底较高，否则头会显得比尾巴还薄
var _head_ratio := 1.0
## 尾部粒子（拖尾）强度：压得比头部低，尾巴疏了才看得出收尖
var _tail_ratio := 1.0
## 本次施法是否要保留浓烟尾迹
var _use_smoke_trail := true

@onready var sprite: Sprite2D = %Sprite
## 火焰序列帧外观（scenes/effects/fireball/effect_fireball_1.tscn，61 帧循环，60fps）。
## ⚠ 它【不参与旋转】：序列帧跟着弹道角度转会火苗歪掉，所以飞行中只有静态 Sprite 自转，
## 序列帧始终保持正立。它和 sprite 由 setup() 按"技能有没有配 projectile_texture"二选一显示。
@onready var effect_fireball: Node2D = %EffectFireball
@onready var trail: Line2D = %Trail
@onready var fire_core: GPUParticles2D = %FireCore
@onready var fire_blob: GPUParticles2D = %FireBlob
@onready var trail_particles: GPUParticles2D = %TrailParticles
@onready var sparks: GPUParticles2D = %Sparks
@onready var smoke: GPUParticles2D = %Smoke
@onready var burst_particles: GPUParticles2D = %Burst


func setup(skill: SkillData, start_pos: Vector2) -> void:
	_skill = skill
	global_position = start_pos

	# ---- 飞行体外观：两套二选一 ----
	# A) skill.projectile_texture 非空 → 静态 Sprite（支持 SkillData.tint 染色、可自转）
	# B) 为空                          → 序列帧 AnimatedSprite2D（配色是素材自带的，与 tint 无关）
	# B 用的是哪套序列帧：skill.sequence_frame_scene，留空则用默认的 effect_fireball_1。
	var use_static := skill.projectile_texture != null
	sprite.visible = use_static
	effect_fireball.visible = not use_static

	if use_static:
		sprite.texture = skill.projectile_texture
		sprite.modulate = skill.tint
		sprite.scale = Vector2.ONE * skill.projectile_scale
	else:
		_apply_sequence_frames(skill)

	# ── 粒子配比：头要密、尾要疏，所以"头"和"尾"用不同的基准数 ──
	# 背景（为什么不是统一乘 _flight_ratio）：
	#   早先三层都用 skill.hit_particles × _flight_ratio 算，
	#   在 frames_only（ratio = 0.15）下火核只剩 2、火团只剩 3、尾迹只剩 4 个粒子，
	#   结果是"头很薄、尾巴反而靠火团的向上漂移撑粗" —— 完全反了。
	#   所以这里改成：头两层用固定基准数（再乘 ratio 时保底给足），尾迹单独按 ratio 压。

	# ---- 火核 / 火团：头部两层必须 local_coords = true ----
	# ⚠ 这是"头大尾小"的另一个关键点：
	#   如果头部也用 local_coords = false，粒子会被弹体甩在后面并不断累积，
	#   尾巴越远越粗 —— 那就变成了火箭尾焰，跟火球正好相反。
	#   改成 true 后，头部粒子跟着弹体走，稳定地烧成"实心一颗"。
	# 火核：头部的亮点，小扩散、短寿命
	_prepare(fire_core, maxi(12, skill.hit_particles / 3), FIRE_HOT, FIRE_MID, FIRE_OUT, 45.0)
	fire_core.amount = maxi(10, int(fire_core.amount * _head_ratio))
	fire_core.lifetime = 0.35
	fire_core.local_coords = true
	var core_pm := fire_core.process_material as ParticleProcessMaterial
	if core_pm != null:
		core_pm.gravity = Vector3.ZERO

	# 火团：头部的体积，中等扩散
	_prepare(fire_blob, maxi(16, skill.hit_particles), FIRE_MID, FIRE_LOW, FIRE_OUT, 70.0)
	fire_blob.amount = maxi(12, int(fire_blob.amount * _head_ratio))
	fire_blob.lifetime = 0.6
	fire_blob.local_coords = true
	var blob_pm := fire_blob.process_material as ParticleProcessMaterial
	if blob_pm != null:
		blob_pm.gravity = Vector3.ZERO

	# ---- 拖尾：唯一留在世界坐标（local_coords = false）的一层，靠它拖出锥形 ----
	_prepare(trail_particles, maxi(10, int(skill.hit_particles * _tail_ratio)), FIRE_MID, FIRE_LOW, FIRE_OUT)
	trail_particles.local_coords = false

	# ---- 飞行中偶尔崩出的火星 ----
	_prepare(sparks, maxi(1, int(skill.hit_particles / 4.0 * _flight_ratio)), FIRE_HOT, Color(1.0, 0.5, 0.12, 0.8), FIRE_OUT)

	# ---- 上升的浓烟尾迹（普通混合，不能发光）----
	# ⚠ 贴图必须换成 EffectTex.smoke()：
	#    场景里烘焙的是裸 NoiseTexture2D，它的 alpha 恒为 1、是【满幅不透明方块】，
	#    直接渲染会看到弹道上飘着一串黑方块。smoke() 给它叠了径向 alpha 遮罩才有柔边。
	smoke.texture = EffectTex.smoke()
	if _use_smoke_trail:
		smoke.amount = maxi(4, skill.hit_particles / 6)
		# 再压一点不透明度，避免烟盖住火焰主体
		smoke.modulate = Color(SMOKE_TINT.r, SMOKE_TINT.g, SMOKE_TINT.b, 0.55)
		smoke.emitting = true
	else:
		# 彻底关掉浓烟：既是性能考虑，也因为几个深色粒子叠起来就是一条黑带，很挡视线
		smoke.amount = 0
		smoke.emitting = false

	# ---- 兜底爆炸层：真正的爆炸走 burst_effect.tscn，这层只在它加载失败时兜底 ----
	burst_particles.texture = skill.hit_particle_texture if skill.hit_particle_texture != null else _glow()
	burst_particles.amount = maxi(1, skill.hit_particles)
	burst_particles.emitting = false

	# ---- Line2D 拖尾仍然按 SkillData 染色 ----
	trail.modulate = Color(skill.tint.r, skill.tint.g, skill.tint.b, 0.5)
	trail.clear_points()

	# 飞行时轻轻自转
	# 注意：set_loops() 是 Tween 的方法，不是 Tweener 的，不能链在 tween_property() 后面
	var spin := create_tween()
	spin.set_loops()
	spin.tween_property(sprite, "rotation", TAU, 0.6)


## 序列帧外观：决定用哪套素材、按什么缩放，并设置本次的粒子强度。
##
## 关键尺寸事实：你的像素火焰素材单帧画布是 100×100，但**实际内容只有约 43×21 px**
## （并集包围盒 51×31），其余 97% 是透明留白。所以：
##   · projectile_scale = 0.9 时屏幕上火球只有约 39×19 px，会被粒子盖住；
##   · 想要它明显，得把 scale 放大到 3~4 倍；
##   · 帧内容偏在画布左上（x 15~65 / y 39~69），所以放大后视觉中心会略微偏左上。
func _apply_sequence_frames(skill: SkillData) -> void:
	# 按技能配置换掉整棵序列帧子树（三种火焰配色各是一个独立场景）
	var want: PackedScene = skill.sequence_frame_scene
	if want == null:
		want = _fireball_scene()
	if effect_fireball != null and want != null and effect_fireball.scene_file_path != want.resource_path:
		for c in effect_fireball.get_children():
			c.queue_free()
		var fresh = want.instantiate()
		effect_fireball.add_child(fresh)

	effect_fireball.scale = Vector2.ONE * skill.projectile_scale

	if skill.frames_only:
		# 只留极少量粒子做点缀：素材本身才是主角
		_flight_ratio = clampf(skill.flight_particle_ratio, 0.0, 1.0)
		# 头尾分开控制：
		#   头部保底 —— head_ratio = 0.55 + ratio（ratio=0.15 时约 0.7），
		#             配合 base 12/26 得到 8/18 个，头才够实、像一颗火球；
		#   尾巴压低 —— tail_ratio = ratio × 3（约 0.45），尾迹疏了收尖的锥形才看得出来。
		_head_ratio = clampf(0.55 + _flight_ratio, 0.0, 1.0)
		_tail_ratio = clampf(_flight_ratio * 3.0, 0.0, 1.0)
		_use_smoke_trail = skill.show_smoke_trail
	else:
		_flight_ratio = 1.0
		_head_ratio = 1.0
		_tail_ratio = 1.0
		_use_smoke_trail = true


## 默认序列帧素材。迁移到 scenes/effects/fireball/ 之后它和我们同目录，
## 直接用上面常量 DEFAULT_FIREBALL_SCENE 即可，不再需要惰性 load。
func _fireball_scene() -> PackedScene:
	return DEFAULT_FIREBALL_SCENE


## 统一给一层粒子设贴图 / 加法混合 / 颜色渐变 / 数量 / 扩散角
## spread_deg：扩散角（度）。头部两层传小值（45~70）把它收成实心一团，
##             尾巴层保持默认 180°。这是"头大尾小"能不能成立的关键旋钮：
##             原来头也是 180°，粒子被弹体落下后四面散开，中段反而比头还粗。
func _prepare(p: GPUParticles2D, amount: int, c0: Color, c1: Color, c2: Color, spread_deg: float = -1.0) -> void:
	if p == null:
		return
	p.texture = _glow()
	p.material = _additive()
	p.amount = maxi(1, amount)
	var pm := p.process_material as ParticleProcessMaterial
	if pm != null:
		pm.color_ramp = EffectTex.ramp([c0, c1, c2])
		if spread_deg >= 0.0:
			pm.spread = spread_deg


func _glow() -> Texture2D:
	if _cached_glow == null:
		_cached_glow = EffectTex.glow()
	return _cached_glow


func _additive() -> CanvasItemMaterial:
	if _cached_additive == null:
		_cached_additive = EffectTex.additive()
	return _cached_additive


## 飞向目标点，抵达那一刻返回（时长 = 距离 / 速度，有上下限）
func fly_to(target_pos: Vector2) -> void:
	if _skill == null:
		return
	var distance := global_position.distance_to(target_pos)
	var duration := clampf(distance / maxf(1.0, _skill.projectile_speed), 0.18, 1.2)

	# 拖尾：Line2D 设了 top_level，所以它的点是世界坐标（不跟着飞行体跑）
	trail.clear_points()
	trail.add_point(global_position)
	trail.add_point(target_pos)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "global_position", target_pos, duration)
	tween.tween_property(sprite, "scale", Vector2.ONE * _skill.projectile_scale * 1.25, duration)
	await tween.finished


## 命中爆炸：把"命中层"集中释放，然后自己 queue_free
## 镜头震动不在这里做 —— 由 Battle._shake_camera() 负责，保持原有分工
func burst() -> void:
	# 先把飞行层停掉（序列帧外观也要一起藏掉，否则弹体消失了火焰还停在原地）
	sprite.visible = false
	effect_fireball.visible = false
	trail.visible = false
	for p in [fire_core, fire_blob, trail_particles, sparks, smoke]:
		if p != null:
			p.emitting = false

	var tint := FIRE_MID
	var count := 26
	if _skill != null:
		tint = _skill.tint
		count = _skill.hit_particles

	# 命中层：独立场景，放一次后自毁
	# 用世界坐标挂在父节点下，所以本体马上消失也不影响爆炸继续播
	var parent := get_parent()
	if parent != null and BURST_EFFECT_SCENE != null:
		# 不写 as BurstEffect：新脚本的 class_name 需要编辑器索引一次才进全局类缓存，
		# 用 preload 的常量实例化更稳，立刻可用
		var boom = BURST_EFFECT_SCENE.instantiate()
		parent.add_child(boom)
		boom.global_position = global_position
		boom.play(tint, count)

	# 兜底层：让旧的 Burst 粒子跟着喷一下（正常情况下 BurstEffect 已经覆盖了观感）
	if burst_particles != null:
		burst_particles.modulate = tint
		burst_particles.emitting = true

	queue_free()

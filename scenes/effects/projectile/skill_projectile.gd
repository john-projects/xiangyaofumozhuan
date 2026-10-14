extends Node2D
class_name SkillProjectile

## 公共技能弹道 —— 所有元素共用的一条弹道。
##
## 它只负责"通用骨架"：
##   · 静态贴图（可选，走 SkillData.projectile_texture）
##   · 元素外观插槽 %Appearance（走 SkillData.appearance_scene）
##   · 拖尾 / 飞行位移 / 命中爆炸 / 生命周期
##
## 元素专属的东西**一律不在这里**：火球的序列帧与五层粒子在
## scenes/effects/fireball/fireball_appearance.gd 里，寒冰箭再写一个 ice_appearance 即可复用同一条弹道。
## 这里不该出现任何 "fire" 字样的常量、节点或配色。
##
## 用法（Battle 里，和以前完全一致）：
##   var p := SKILL_PROJECTILE_SCENE.instantiate() as SkillProjectile
##   fx_root.add_child(p)
##   p.setup(skill, caster.global_position)
##   await p.fly_to(target.global_position)   # 抵达那一刻返回
##   p.burst()                                # 播命中爆炸并自动释放
##
## 外观包契约（鸭子类型，两个都可选）：
##   · setup_effect(projectile: SkillProjectile, skill: SkillData) → setup() 里调用，外观包按 SkillData 配置自己；
##   · stop_flight() → burst() 里调用，外观包停发射（但让已生成的粒子自然消亡，不要瞬间消失）。
##   两个都没实现也能用：那它就只是一个挂在插槽里的静态装饰。

const BURST_EFFECT_SCENE := preload("res://scenes/effects/burst_effect.tscn")
## 飞行途中整体"鼓一下"的峰值倍率（作用在 %Visual 上，同时影响静态贴图和外观包）
const FLY_STRETCH := 1.25

var _skill: SkillData
var _appearance: Node = null
var _cached_glow: Texture2D
var _cached_additive: CanvasItemMaterial

@onready var visual: Node2D = %Visual
@onready var sprite: Sprite2D = %Sprite
@onready var appearance_slot: Node2D = %Appearance
@onready var trail: Line2D = %Trail
@onready var burst_particles: GPUParticles2D = %Burst


func setup(skill: SkillData, start_pos: Vector2) -> void:
	_skill = skill
	global_position = start_pos

	# ---- 静态贴图（可选）：只有配了 projectile_texture 才显示 ----
	var use_static := skill.projectile_texture != null
	sprite.visible = use_static
	if use_static:
		sprite.texture = skill.projectile_texture
		sprite.modulate = skill.tint
		sprite.scale = Vector2.ONE * skill.projectile_scale

	# ---- 元素外观包（可选）：火球/冰箭/雷击的视觉都在各自的外观包里 ----
	_attach_appearance(skill)

	# ---- 拖尾线：白色渐变 + SkillData.tint 染色，所以任何元素都能直接用 ----
	# ⚠ 场景里它是 visible = false（当前"看得见的拖尾"由外观包的 TrailParticles 负责）。
	#    想启用这条线就在下面加 trail.visible = true；它设了 top_level，点是世界坐标。
	trail.modulate = Color(skill.tint.r, skill.tint.g, skill.tint.b, 0.5)
	trail.clear_points()

	# ---- 兜底爆炸粒子：真正的爆炸走命中特效场景，这层只在它缺失时兜底 ----
	burst_particles.texture = skill.hit_particle_texture if skill.hit_particle_texture != null else _glow()
	burst_particles.amount = maxi(1, skill.hit_particles)
	burst_particles.emitting = false


## 把 SkillData.appearance_scene 挂到 %Appearance 插槽；实现了 setup_effect() 就交给它自己配置。
## 参数 skill：本次技能的 SkillData（外观包靠它拿 tint / 尺寸 / 粒子密度这些参数）。
## 返回值：无。副作用：会实例化一个场景挂在 %Appearance 下（保存在 _appearance，burst() 时要用）。
## 兜底：如果这个场景**没有** setup_effect()（比如直接把纯素材场景 effect_fireball_1.tscn 塞了进来），
##      弹道就只做最浅的一层：按 projectile_scale 缩放它。
##      为什么要有这条兜底：纯素材场景没有脚本，"谁来读 projectile_scale"就没有答案，
##      结果就是"改了缩放没反应"（踩过）。但注意兜底**只缩放**：
##      染色、粒子层、序列帧换色这些都得靠外观包自己实现，所以正式用法仍然是挂外观包。
func _attach_appearance(skill: SkillData) -> void:
	if skill.appearance_scene == null:
		return
	_appearance = skill.appearance_scene.instantiate()
	appearance_slot.add_child(_appearance)
	if _appearance.has_method("setup_effect"):
		_appearance.call("setup_effect", self, skill)
	else:
		_appearance.scale = Vector2.ONE * maxf(0.01, skill.projectile_scale)


## 飞向目标点，抵达那一刻返回（时长 = 距离 / 速度，被 clampf 限制在 0.18~1.2s）
## 参数 target_pos：目标的世界坐标。
## 副作用：会 tween 自身 global_position 和 %Visual 的 scale；会重画拖尾线的两个点。
func fly_to(target_pos: Vector2) -> void:
	if _skill == null:
		return
	var distance := global_position.distance_to(target_pos)
	var duration := clampf(distance / maxf(1.0, _skill.projectile_speed), 0.18, 1.2)

	# 拖尾：Line2D 设了 top_level，所以它的点用世界坐标（不跟着弹体跑）
	trail.clear_points()
	trail.add_point(global_position)
	trail.add_point(target_pos)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "global_position", target_pos, duration)
	tween.tween_property(visual, "scale", Vector2.ONE * FLY_STRETCH, duration)
	await tween.finished


## 命中爆炸：收掉飞行层，在当前位置放"命中特效场景"，然后自己 queue_free。
## 用哪个命中场景：SkillData.hit_effect_scene，留空用 BURST_EFFECT_SCENE（程序化爆炸）；
## 缩放用 SkillData.burst_scale。镜头震动不在这里做 —— 由 Battle._shake_camera() 负责。
## 副作用：会 new 一个命中特效挂在父节点下（世界坐标，所以本体消失不影响它继续播）。
func burst() -> void:
	sprite.visible = false
	trail.visible = false
	# 外观包自己收尾（停发射、藏序列帧），让已经喷出去的粒子自然消亡；
	# 没实现 stop_flight() 的就只好整个藏掉。
	if _appearance != null and _appearance.has_method("stop_flight"):
		_appearance.call("stop_flight")
	else:
		visual.visible = false

	var tint := Color(1.0, 0.55, 0.2)
	var count := 26
	var effect_scene := BURST_EFFECT_SCENE
	var effect_scale := 1.0
	if _skill != null:
		tint = _skill.tint
		count = _skill.hit_particles
		if _skill.hit_effect_scene != null:
			effect_scene = _skill.hit_effect_scene
		effect_scale = maxf(0.05, _skill.burst_scale)

	var parent := get_parent()
	if parent != null and effect_scene != null:
		# 不写 as BurstEffect：新脚本的 class_name 需要编辑器索引一次才进全局类缓存，
		# 用 preload 的常量实例化更稳，立刻可用
		var boom = effect_scene.instantiate()
		parent.add_child(boom)
		boom.global_position = global_position
		boom.scale = Vector2.ONE * effect_scale
		# 命中层有两种形态：
		#   A) 带 play(tint, count) 的程序化爆炸（BurstEffect）→ 交给它自己染色和排布；
		#   B) 纯序列帧素材（没有任何脚本）→ 用下面的静态工具播一次。
		if boom.has_method("play"):
			boom.play(tint, count)
		else:
			play_sequence_once(boom)

	# 兜底层：让 Burst 粒子跟着喷一下（正常情况下命中特效已经覆盖了观感）
	if burst_particles != null:
		burst_particles.modulate = tint
		burst_particles.emitting = true

	queue_free()


## 播放"纯序列帧"的命中特效（例如 effect_fireball_hit.tscn：只有一个 AnimatedSprite2D，没有脚本）。
## 参数 node：已经 add_child 进场景树的特效根节点（调用方负责 add_child 和 global_position）。
## 返回值：无（同步返回，播完由定时器自毁）。
## 为什么需要它：那类素材烘焙的动画是 loop = 1（一直循环），而命中特效只该播一次。
## 做法：从头播一遍，按"帧数 / fps"算出时长，定时停帧并 queue_free。
## 坑（刻意避开的做法）：**不要去改 anim.sprite_frames.set_animation_loop()** ——
##   场景里的 SpriteFrames 是内嵌 SubResource，实例之间共享；改了会污染所有实例，
##   而且编辑器下次保存场景时会把这个改动写回 .tscn 文件。
## 容错：找不到 AnimatedSprite2D、没有 SpriteFrames 或没有 default 动画时直接释放，不报错。
static func play_sequence_once(node: Node) -> void:
	var anim := node.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if anim == null:
		anim = node.find_child("AnimatedSprite2D", true, false) as AnimatedSprite2D
	if anim == null or anim.sprite_frames == null or not anim.sprite_frames.has_animation(&"default"):
		node.queue_free()
		return

	anim.stop()
	anim.frame = 0
	anim.play(&"default")

	var frames := anim.sprite_frames.get_frame_count(&"default")
	var fps := anim.sprite_frames.get_animation_speed(&"default")
	var duration := float(frames) / maxf(1.0, fps)
	node.get_tree().create_timer(duration).timeout.connect(func() -> void:
		if is_instance_valid(anim):
			anim.stop()
		if is_instance_valid(node):
			node.queue_free())


## 径向光晕贴图（静态贴图/兜底粒子用）——公共资源，不含任何元素语义
func _glow() -> Texture2D:
	if _cached_glow == null:
		_cached_glow = EffectTex.glow()
	return _cached_glow


## 加法混合材质（光效类默认用它）
func _additive() -> CanvasItemMaterial:
	if _cached_additive == null:
		_cached_additive = EffectTex.additive()
	return _cached_additive

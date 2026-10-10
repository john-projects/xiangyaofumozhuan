extends Node2D
class_name SkillProjectile

## 技能飞行体 + 命中爆炸（零素材可跑：贴图和粒子都可以留空）
##
## 用法（Battle 里）：
##   var p := SKILL_PROJECTILE_SCENE.instantiate() as SkillProjectile
##   fx_root.add_child(p)
##   p.setup(skill, caster.global_position)
##   await p.fly_to(target.global_position)   # 抵达那一刻返回
##   target.take_damage(dmg)                  # 结算伤害
##   p.burst()                                # 播爆炸并自动释放

var _skill: SkillData

@onready var sprite: Sprite2D = %Sprite
@onready var burst_particles: GPUParticles2D = %Burst
@onready var trail: Line2D = %Trail


func setup(skill: SkillData, start_pos: Vector2) -> void:
	_skill = skill
	global_position = start_pos

	sprite.texture = skill.projectile_texture
	sprite.modulate = skill.tint
	sprite.scale = Vector2.ONE * skill.projectile_scale

	# 没给粒子贴图时，用飞行的贴图当粒子（再没有就是白色小方块）
	var particle_texture := skill.hit_particle_texture if skill.hit_particle_texture != null else skill.projectile_texture
	burst_particles.texture = particle_texture
	burst_particles.amount = maxi(1, skill.hit_particles)
	burst_particles.modulate = skill.tint
	burst_particles.emitting = false

	trail.modulate = Color(skill.tint.r, skill.tint.g, skill.tint.b, 0.5)
	trail.clear_points()

	# 飞行时轻轻自转
	var spin := create_tween().set_loops()
	spin.tween_property(sprite, "rotation", TAU, 0.6).from(0.0)


## 飞向目标点，抵达那一刻返回（距离越远飞得越久，但有时长上下限）
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


## 命中爆炸：粒子喷一下 + 贴图放大淡出，然后自己释放
func burst() -> void:
	sprite.visible = false
	trail.visible = false
	burst_particles.emitting = true

	var tween := create_tween()
	tween.tween_property(burst_particles, "modulate:a", 0.0, 0.35)
	tween.tween_interval(0.45)          # 等粒子寿命走完再释放
	tween.tween_callback(queue_free)

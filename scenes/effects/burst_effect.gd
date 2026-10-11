extends Node2D
class_name BurstEffect

## 命中爆炸：把 8 层特效里"命中时集中释放"的那几层组合在一起。
##
## 层对应关系（参考那段"一个火球八层"的拆解）：
##   飞行中：火核 FireCore / 拖尾 Trail / 火团 FireBlob / 火星 Sparks / 浓烟 Smoke
##   命中时：闪光 Flash / 冲击波 Shockwave / 火星溅射 Sparks / 浓烟 Smoke / 镜头震动（Battle 负责）
##
## 节点结构存在 burst_effect.tscn 里，所以可以在编辑器里逐层调参。
## 本脚本只负责"按 SkillData 染色 + 播放一次 + 自毁"。

const LIFETIME := 1.6   # 最长的那层（浓烟 1.5s）+ 余量
const EffectTex := preload("res://scenes/effects/effect_tex.gd")

@onready var _flash: GPUParticles2D = $Flash
@onready var _ring: Sprite2D = $Shockwave
@onready var _sparks: GPUParticles2D = $Sparks
@onready var _smoke: GPUParticles2D = $Smoke

var _played := false


## tint 来自 SkillData.tint，让火球整体配色跟技能资源一致
## particle_count 来自 SkillData.hit_particles，控制粒子的疏密
func play(tint: Color = Color(1, 0.55, 0.2), particle_count: int = 26) -> void:
	if _played:
		return
	_played = true

	# ---- 闪光：白热向外铺开 ----
	if _flash != null:
		_flash.modulate = tint
		_flash.amount = maxi(8, particle_count / 2)
		var fm := _flash.process_material as ParticleProcessMaterial
		if fm != null:
			fm.color_ramp = EffectTex.tint_ramp([
				Color(1.0, 0.95, 0.75, 1.0),
				Color(1.0, 0.8, 0.4, 0.5),
				Color(1.0, 0.4, 0.1, 0.0),
			], tint)
		_flash.restart()
		_flash.emitting = true

	# ---- 冲击波：小环快速铺开并淡出 ----
	if _ring != null:
		_ring.modulate = Color(tint.r, tint.g, tint.b, 1.0)
		_ring.scale = Vector2(0.8, 0.8)
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_property(_ring, "scale", Vector2(3.4, 3.4), 0.32) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(_ring, "modulate:a", 0.0, 0.32) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

	# ---- 火星：高速甩出 + 重力下落 ----
	if _sparks != null:
		_sparks.modulate = tint
		_sparks.amount = maxi(10, particle_count * 2)
		_sparks.restart()
		_sparks.emitting = true

	# ---- 浓烟：向上飘，普通混合（不能用加法，否则烟会发光）----
	if _smoke != null:
		# ⚠ 场景里烘焙的是裸 NoiseTexture2D（alpha 恒为 1 = 不透明方块），
		#    必须换成带径向 alpha 遮罩的 smoke()，否则爆炸里会看到黑方块
		_smoke.texture = EffectTex.smoke()
		_smoke.modulate = Color(tint.r * 0.5 + 0.3, tint.g * 0.4 + 0.25, tint.b * 0.4 + 0.22, 0.6)
		_smoke.restart()
		_smoke.emitting = true

	get_tree().create_timer(LIFETIME).timeout.connect(queue_free)

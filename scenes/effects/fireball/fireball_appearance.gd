extends Node2D
class_name FireballAppearance

## 火球外观包：像素火焰序列帧 + 五层飞行粒子（火核 / 火团 / 拖尾 / 火星 / 浓烟）。
##
## 这里是"火球专属"的全部内容 —— 公共弹道 scenes/effects/projectile/skill_projectile.gd
## 里不含任何火的语义。以后做寒冰箭：复制本目录的做法写一个 ice_appearance（配色/粒子换成冰的），
## 弹道一行都不用改。
##
## 接入方式：SkillData.appearance_scene = fireball_appearance.tscn
## 公共弹道会调用的契约：
##   · setup_effect(projectile, skill)  → 按 SkillData 配置自己（下面读的字段见 _apply_sequence_frames / _prepare_particles）
##   · stop_flight()                    → 命中时停发射（保留已生成粒子自然消亡，不要瞬间消失）
## 读取的 SkillData 字段：tint / projectile_scale / sequence_frame_scene / frames_only /
##                       flight_particle_ratio / show_smoke_trail / hit_particles
##
## 绘制层级（烘在本场景里，不要在代码里改）：
##   序列帧 EffectFireball z_index = 5，五层粒子是 Smoke 0 / TrailParticles 1 / FireBlob 2 / FireCore 3 / Sparks 4。
##   序列帧必须最高，否则像素帧动画会被粒子整片盖住 —— 这正是本场景当初的坑。
##   想让"火星飘在火焰前面"：把 Sparks 改成 6，并让序列帧降到 5 以下。

## 默认序列帧素材（帧动画场景）。三套配色见同目录 effect_fireball_1/2/3.tscn
const DEFAULT_FIREBALL_SCENE := preload("res://scenes/effects/fireball/effect_fireball_1.tscn")

## 火色。刻意不用 SkillData.tint：偏暗的染色会让火显脏；
## tint 只用在弹体本身和拖尾上（公共弹道负责）。
const FIRE_HOT := Color(1.0, 0.96, 0.78, 1.0)
const FIRE_MID := Color(1.0, 0.68, 0.22, 1.0)
const FIRE_LOW := Color(0.85, 0.28, 0.06, 0.7)
const FIRE_OUT := Color(0.30, 0.10, 0.04, 0.0)
const SMOKE_TINT := Color(0.30, 0.27, 0.25, 1.0)

## 本次施法的飞行粒子强度（1.0 = 默认那套完整观感；frames_only 时会被压低）
var _flight_ratio := 1.0
## 头部粒子（火核 / 火团）强度：保底较高，否则头会显得比尾巴还薄
var _head_ratio := 1.0
## 尾部粒子（拖尾）强度：压得比头部低，尾巴疏了才看得出收尖
var _tail_ratio := 1.0
## 本次施法是否要保留浓烟尾迹
var _use_smoke_trail := true

var _cached_glow: Texture2D
var _cached_additive: CanvasItemMaterial

@onready var frames: Node2D = %EffectFireball
@onready var fire_core: GPUParticles2D = %FireCore
@onready var fire_blob: GPUParticles2D = %FireBlob
@onready var trail_particles: GPUParticles2D = %TrailParticles
@onready var sparks: GPUParticles2D = %Sparks
@onready var smoke: GPUParticles2D = %Smoke


# ══════════════════════════════════════════════════════════
#  公共弹道调用的契约
# ══════════════════════════════════════════════════════════

## 按 SkillData 配置这套火球外观。由公共弹道在 setup() 里调用。
## 参数 _projectile：公共弹道根节点（这套外观不需要反过来操作它，留参数是为了以后扩展）；
##        skill：本次技能资源。
func setup_effect(_projectile: Node2D, skill: SkillData) -> void:
	if skill == null:
		return
	_apply_sequence_frames(skill)
	_prepare_particles(skill)


## 命中瞬间调用：藏掉序列帧、停掉五层粒子的发射。
## 刻意不 queue_free：已经喷出去的粒子让它自然消亡，硬切会很生硬。
func stop_flight() -> void:
	frames.visible = false
	for p in [fire_core, fire_blob, trail_particles, sparks, smoke]:
		if p != null:
			p.emitting = false


# ══════════════════════════════════════════════════════════
#  序列帧外观
# ══════════════════════════════════════════════════════════

## 序列帧外观：决定用哪套素材、按什么缩放，并设置本次的粒子强度。
##
## 关键尺寸事实：像素火焰素材单帧画布是 100×100，但**实际内容只有约 43×21 px**
## （并集包围盒 51×31），其余 97% 是透明留白。所以：
##   · projectile_scale = 0.9 时屏幕上火球只有约 39×19 px，会被粒子盖住；
##   · 想要它明显，得把 scale 放大到 3~4 倍（skill_fireball_sequence 用 4.0、爆裂火球用 5.5）；
##   · 帧内容偏在画布左上（x 15~65 / y 39~69），所以放大后视觉中心会略微偏左上。
func _apply_sequence_frames(skill: SkillData) -> void:
	# 按技能配置换掉整棵序列帧子树（三种火焰配色各是一个独立场景）
	frames.visible = true
	var want: PackedScene = skill.sequence_frame_scene
	if want == null:
		want = DEFAULT_FIREBALL_SCENE
	if frames != null and want != null and frames.scene_file_path != want.resource_path:
		# frames 本身是"装着帧动画场景的容器"，直接比对它的子场景路径
		for child in frames.get_children():
			child.queue_free()
		var fresh = want.instantiate()
		frames.add_child(fresh)

	frames.scale = Vector2.ONE * skill.projectile_scale

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


# ══════════════════════════════════════════════════════════
#  五层飞行粒子
# ══════════════════════════════════════════════════════════

## 布置五层飞行粒子。配比思路（踩过的坑都写在注释里）：
## 头要密、尾要疏，所以"头"和"尾"用不同的基准数。
## 早先三层都用 hit_particles × _flight_ratio 算，在 frames_only（ratio = 0.15）下
## 火核只剩 2、火团只剩 3、尾迹只剩 4 个粒子，结果"头很薄、尾巴反而靠火团的向上漂移撑粗" —— 完全反了。
func _prepare_particles(skill: SkillData) -> void:
	# ---- 火核 / 火团：头部两层必须 local_coords = true ----
	# ⚠ 这是"头大尾小"的另一个关键点：
	#   如果头部也用 local_coords = false，粒子会被弹体甩在后面并不断累积，
	#   尾巴越远越粗 —— 那就变成了火箭尾焰，跟火球正好相反。
	#   改成 true 后，头部粒子跟着弹体走，稳定地烧成"实心一颗"。
	# 火核：头部的亮点，小扩散、短寿命
	@warning_ignore("integer_division")
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
	smoke.material = EffectTex.mix()
	if _use_smoke_trail:
		smoke.visible = true
		@warning_ignore("integer_division")
		smoke.amount = maxi(4, skill.hit_particles / 6)
		# 再压一点不透明度，避免烟盖住火焰主体
		smoke.modulate = Color(SMOKE_TINT.r, SMOKE_TINT.g, SMOKE_TINT.b, 0.55)
		smoke.emitting = true
	else:
		# 彻底关掉浓烟：既是性能考虑，也因为几个深色粒子叠起来就是一条黑带，很挡视线
		# ⚠ 不要写 smoke.amount = 0：GPUParticles2D.amount 的最小值是 1，
		#    赋 0 会报 "Amount of particles cannot be smaller than 1."（不会崩，但会一直刷红字，
		#    而且 amount 会停在原值上，等于没关掉）。正确做法是保留 amount、只关 emitting，
		#    再把节点隐藏，这样连上一发残留的粒子也看不见。
		smoke.emitting = false
		smoke.visible = false


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

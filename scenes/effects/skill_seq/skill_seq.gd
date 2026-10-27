## SkillSeq —— 技能序列帧特效（把技能视频转成的横向网格图集播一遍就自毁）
##
## 为什么用**加法混合**而不是抠 alpha：技能 VFX 是发光体，黑 = 加 0 = 天然透明；
## 抠 alpha 会把光晕的渐变切成硬边（和 scenes/effects/README.md 里的结论一致）。
##
## 两种接入方式：
##   ① 命中/增益特效：Battle 通过 SkillData.hit_effect_scene / target_effect_scene 实例化，
##      因为它实现了 play(tint, count)，Battle 走"程序化特效"那条分支（鸭子类型）→ 必须 autoplay = false；
##   ② 全屏动画：挂在 SkillData.screen_effect_scene，Battle 只 instantiate + add_child、**不会**调 play()，
##      所以那种场景要把 autoplay 打开（群星陨落 / 太虚封天 这类多目标技能只播一次全屏）。
##
## 素材：assets/sprites/skills/<key>_seq.png（8 列网格，RGB 无 alpha，暗部已压成纯黑）
## 生成脚本在 skillvfx/build_sheets.py，改帧数/尺寸要重新生成图集。
extends Node2D
class_name SkillSeq

## 一段动画播完（自毁之前）发一次。Battle 用它实现"等这一段打完再跳伤害数字"。
signal finished

## 图集（8 列网格）。
@export var sheet: Texture2D
## 总帧数（最后一格可能不满，多余格子是黑的，不影响）。
@export var frames := 60
## 图集列数。
@export var cols := 8
## 图集**行数**。必须按图集的真实行数填，不能从 frames/cols 推算。
## ⚠ 坑：之前是 `vframes = ceil(frames/cols)`，一旦把 frames 截短（62→50），
##   推算出的行数会小于图集实际行数，每帧取到的区域整体错位 —— 画面变成乱切的碎片。
@export var rows := 8
## 播放帧率：素材按 12fps 抽帧、按 24fps 播放，等于 2 倍速（5 秒 → 2.5 秒）。
@export var fps := 24.0
## 整体缩放。384px 宽的帧 × 1.4 ≈ 540px，在 1680 宽的画布上刚好是"覆盖半个战场"。
@export var scale_mul := 1.4
## true = 一进场景树就自己播（给 screen_effect_scene 用，Battle 不会替它调 play()）。
@export var autoplay := false
## 全屏播放时的最小覆盖半径（半宽、半高，像素）。
## 为什么需要：覆盖范围是"从锚点量到最远的单位"，而两个锚点在阵型里的纵向位置不同 ——
##   敌方锚点 Back2(-500,-350) 在阵型**最上面**，半高 = 350 + pad；
##   我方锚点 Front1(400,175)  在阵型**中间**，半高只有 175 + pad。
## 结果同一招打敌方是一屏大、打我方只剩 63% 大。这里兜一个下限，两边就一样了。
const MIN_COVER_HALF := Vector2(370.0, 470.0)
## 收尾淡出时长（秒）。
## 为什么需要：有些技能视频是**首尾相接的循环**（封灵诀：尾帧和首帧像素差只有 5，
## 其它技能都是 30+），整段播完会看到"效果散掉 → 又重新亮起来"，像放了两遍。
## 这些技能把 frames 截在效果散掉的那一帧，再靠这一段淡出，就不会有"重新亮起"。
const FADE_OUT := 0.3
## 段数：>1 时 play_segment(i) 只播第 i 段。
## 多段技能（太虚神剑 3 段 / 星罗魔爪 2 段）每一下打出去播一段不同的动画，
## 而不是同一段动画重复 N 次。
@export var segments := 1
## 手动分段边界（帧号，元素数 = 段数 + 1）。留空 = 按总帧数等分。
## 为什么要能手填：等分常常切在"过渡帧"上（比如 3 连斩的第三段只剩消散的火星）。
## 按招式真实节拍切才对得上"每一下都是一招"。
@export var seg_bounds: PackedInt32Array

var _sprite: Sprite2D
var _t := 0.0
var _frame := -1
var _playing := false
## 当前播放的帧区间：从 _from 播到 _to（不含 _to）。
var _from := 0
var _to := 0


func _ready() -> void:
	set_process(false)
	if sheet == null:
		queue_free()
		return
	var rows_total := maxi(1, rows)
	_sprite = Sprite2D.new()
	_sprite.texture = sheet
	_sprite.hframes = cols
	_sprite.vframes = rows_total
	_sprite.frame = 0
	_sprite.scale = Vector2.ONE * scale_mul
	# 加色混合：黑像素 = 不发光 = 不可见，所以不需要 alpha。
	_sprite.material = EffectTex.additive()
	# 全屏模式要盖住所有单位（默认 z=1 会被立绘挡住）。
	_sprite.z_index = 60 if autoplay else 1
	add_child(_sprite)
	visible = false
	if autoplay:
		play()


## Battle 的鸭子类型入口（和 burst_effect.tscn 的 play(tint, count) 同签名）。
## tint 不拿来染整段动画 —— 视频素材本身已经上过色，再乘一层会脏。
func play(tint: Color = Color.WHITE, count: int = -1) -> void:
	_start(0, frames)


## 多段技能入口：Battle._spawn_per_hit_effect() 每打一下调一次，index 从 0 开始。
## 把总帧数等分成 segments 段，第 index 段播完就自毁（不等整段动画结束）。
func play_segment(index: int, tint: Color = Color.WHITE) -> void:
	# 手填了边界就按边界切（边界是闭开区间：第 i 段 = seg_bounds[i] 到 seg_bounds[i+1]）
	if seg_bounds.size() >= 2:
		var k := clampi(index, 0, seg_bounds.size() - 2)
		_start(seg_bounds[k], seg_bounds[k + 1])
		return
	var n := maxi(1, segments)
	var i := clampi(index, 0, n - 1)
	_start(int(round(float(frames) * i / float(n))),
			int(round(float(frames) * (i + 1) / float(n))))


func _start(from: int, to: int) -> void:
	if sheet == null:
		queue_free()
		return
	visible = true
	_t = 0.0
	_frame = -1
	_from = maxi(0, from)
	_to = clampi(to, _from + 1, frames)
	_playing = true
	set_process(true)


## 让全屏动画正好盖住这批单位（多目标技能专用）。
## 参数 units：要覆盖的单位；anchor：原点（世界坐标），传 INF 则取包围盒中点。
##   实际用法是传敌方/我方阵型的 **Back2** 站位 —— 动画从这个角起、往外铺满整队。
## 参数 pad：覆盖范围外再留多少余量（像素）。
##   ⚠ 这个值直接决定**屏上尺寸**：屏宽 = 2×(离原点最远的单位偏移 + pad)，
##     和素材分辨率、scale_mul 都无关。260 会让动画撑到 2168px（比 1680 的视口还宽），
##     既过大又把图拉 5.6 倍显得糊，所以收到 120：
##     敌阵最远的单位距 Back2 约 (250, 350) → 覆盖半径 (370, 470) → 屏上约 1671×940，
##     正好铺满一屏，边缘单位落在羽化起点（半径 0.7）之外一点点，还能看见。
func fit_units(units: Array, anchor := Vector2.INF, pad := 120.0) -> void:
	if _sprite == null or units.is_empty():
		return
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	var n := 0
	for u in units:
		if not is_instance_valid(u):
			continue
		var p: Vector2 = (u as Node2D).global_position
		mn = mn.min(p)
		mx = mx.max(p)
		n += 1
	if n == 0:
		return

	# 原点：优先用传进来的锚点（Back2），否则退回阵型中心
	var origin := (mn + mx) * 0.5
	if anchor != Vector2.INF:
		origin = anchor
	global_position = origin

	# 尺寸：按"离原点最远的那个单位"算半宽半高 —— 锚点不在中心时要更大才盖得住
	var half := Vector2.ZERO
	for u in units:
		if not is_instance_valid(u):
			continue
		var d: Vector2 = (u as Node2D).global_position - origin
		half.x = maxf(half.x, absf(d.x))
		half.y = maxf(half.y, absf(d.y))
	half += Vector2(pad, pad)
	# 兜底下限：保证同一招无论打敌方还是打我方，屏上尺寸一致（见 MIN_COVER_HALF 注释）。
	half = half.max(MIN_COVER_HALF)

	var fw := float(_sprite.texture.get_width()) / float(cols) * scale_mul
	var fh := float(_sprite.texture.get_height()) / float(_sprite.vframes) * scale_mul
	if fw <= 0.0 or fh <= 0.0:
		return
	scale = Vector2.ONE * maxf(half.x / (fw * 0.5), half.y / (fh * 0.5))


## 本次（或整段）动画还剩多少秒。
## Battle 在放特效后调一次，用来算"下一个行动要等多久"。
## 还没开播时返回整段长度（按当前 segments/seg_bounds 推断）。
func duration() -> float:
	var n := _to - _from
	if n <= 0:
		if seg_bounds.size() >= 2:
			n = seg_bounds[1] - seg_bounds[0]
		elif segments > 1:
			n = int(round(float(frames) / float(maxi(1, segments))))
		else:
			n = frames
	return float(maxi(n, 1)) / maxf(fps, 1.0)


func _process(delta: float) -> void:
	if not _playing:
		return
	_t += delta
	var f := _from + int(_t * fps)
	if f >= _to:
		_playing = false
		finished.emit()
		queue_free()
		return
	# 收尾淡出：剩下的帧数不足 FADE_OUT 秒就按比例降 alpha，避免最后一帧"啪"地消失。
	var left := float(_to - f) / maxf(fps, 1.0)
	if left < FADE_OUT:
		_sprite.modulate.a = clampf(left / FADE_OUT, 0.0, 1.0)
	if f != _frame:
		_frame = f
		_sprite.frame = f

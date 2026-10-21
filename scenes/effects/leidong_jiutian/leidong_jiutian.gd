extends Node2D
## 雷动九天 · 命中特效（1 秒 / 15 帧，从 10 秒 AI 视频 2.1~3.1s 截取）。
##
## 素材：assets/sprites/skills/leidong_jiutian/
##   · frame_001..015.png —— 单帧（已抠像，带 alpha，去掉了 AI 水印）
##   · leidong_jiutian_atlas.png —— 4×4 图集（运行时切成 AtlasTexture，比 15 个 ext_resource 干净）
##
## 用法：Battle 命中时 instantiate 到命中点，scale 由 SkillData.burst_scale 控制；
## 播完一帧不循环、立即 queue_free()。**贴地播放**（节点原点 = 地面线），
## 因为素材本身是"地面法阵 + 天降落雷"，不是空中爆点。

## 图集：15 帧按 4 列排布，每帧 640×384。
const ATLAS := preload("res://assets/sprites/skills/leidong_jiutian/leidong_jiutian_atlas.png")
const FRAME_COUNT := 15
const FRAME_W := 640
const FRAME_H := 384
const COLUMNS := 4
## 播放帧率：15fps ≈ 素材原速（1 秒 15 帧）。
const FPS := 15.0
## 素材里"地面线"大约在图片高度的 86% 处（往下是石头地面），把这条线对齐到节点原点。
const GROUND_RATIO := 0.86

var _sprite: AnimatedSprite2D = null


func _ready() -> void:
	_sprite = AnimatedSprite2D.new()
	_sprite.name = "Frames"
	_sprite.sprite_frames = _build_frames()
	_sprite.centered = true
	# 图片中心回到原点后，再把地面线压到 y=0
	_sprite.offset = Vector2(0.0, -FRAME_H * (GROUND_RATIO - 0.5))
	# 抠像后是半透明紫色雷光：用普通混合保住颜色（加法混合会过曝成一片白）
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MIX
	_sprite.material = mat
	# 素材本身很亮（白核紫光），压低一点避免糊成一片白
	_sprite.modulate = Color(0.88, 0.84, 1.0, 0.92)
	add_child(_sprite)
	_sprite.play("play")
	_sprite.animation_finished.connect(_on_finished)


## 兼容 BurstEffect 的接口：弹道/Battle 会调 play(tint, count)。
## 这是预渲染序列帧，tint/count 用不上，只负责从头播一遍（重复调用就重播）。
func play(_tint: Color = Color.WHITE, _count: int = 0) -> void:
	if _sprite == null:
		return
	_sprite.play("play")


## 把 4×4 图集切成 15 个 AtlasTexture，拼成不循环的 "play" 动画。
func _build_frames() -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("play")
	frames.set_animation_speed("play", FPS)
	frames.set_animation_loop("play", false)
	for i in FRAME_COUNT:
		var tex := AtlasTexture.new()
		tex.atlas = ATLAS
		tex.region = Rect2(float(i % COLUMNS) * FRAME_W, float(i / COLUMNS) * FRAME_H, FRAME_W, FRAME_H)
		frames.add_frame("play", tex)
	return frames

## 播完不硬切：用 0.15s 淡出再释放，避免最后一帧"啪"地消失。
func _on_finished() -> void:
	if _sprite == null:
		queue_free()
		return
	var tween := create_tween()
	tween.tween_property(_sprite, "modulate:a", 0.0, 0.15)
	tween.finished.connect(queue_free)
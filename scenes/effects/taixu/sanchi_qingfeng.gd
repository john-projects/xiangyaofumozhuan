extends Node2D
## 三尺青锋 · 视频素材版（替换掉原来的纯代码绘制）。
##
## 素材：assets/sprites/skills/sanchi_qingfeng/sanchi_qingfeng_atlas.png
##       8 列 × 8 行，每帧 480×277，共 60 帧（15fps，约 4 秒）
## 黑底 + 加法混合：黑色自然透明，不需要抠图。
##
## 接口和原来一致：Battle 会 instantiate 后摆到目标位置，然后调 play(tint, count)。

const ATLAS := "res://assets/sprites/skills/sanchi_qingfeng/sanchi_qingfeng_atlas.png"
const FRAME_W := 480
const FRAME_H := 277
const COLUMNS := 8
const FRAME_COUNT := 60
const FPS := 15.0
## 画面相对"脚下"要抬高多少：视频是居中构图，抬到胸口位置才不会一半埋进地里。
const LIFT := 110.0

var _t := 0.0
var _sprite: Sprite2D
var _frame := -1


func _ready() -> void:
	z_index = 5
	# 素材已带 alpha（黑底转透明），用普通混合：加法混合在亮背景上会糊成一片白
	_sprite = Sprite2D.new()
	_sprite.texture = load(ATLAS)
	_sprite.centered = true
	_sprite.region_enabled = true
	_sprite.region_rect = Rect2(0, 0, FRAME_W, FRAME_H)
	_sprite.position = Vector2(0, -LIFT)
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_sprite)


## tint：技能配色（轻轻地染一下，别把视频原来的青金色盖掉）；count 不用。
func play(tint: Color = Color(0.75, 0.9, 1.0), _count: int = 0) -> void:
	_t = 0.0
	_frame = -1
	if _sprite != null:
		_sprite.modulate = Color.WHITE.lerp(tint, 0.25)


func _process(delta: float) -> void:
	_t += delta
	var idx := int(_t * FPS)
	if idx >= FRAME_COUNT:
		queue_free()
		return
	if idx != _frame:
		_frame = idx
		var col := idx % COLUMNS
		var row := idx / COLUMNS
		_sprite.region_rect = Rect2(col * FRAME_W, row * FRAME_H, FRAME_W, FRAME_H)

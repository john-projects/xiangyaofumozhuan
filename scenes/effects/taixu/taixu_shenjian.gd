extends Node2D
## 太虚神剑 · 三次斩击各用一段视频素材。
##
## 素材（每段一张图集，6 列）：
##   seg1_atlas.png  第 1 击：1~22 帧
##   seg2_atlas.png  第 2 击：23~37 帧
##   seg3_atlas.png  第 3 击：38~52 帧
## 黑底 + 加法混合：黑色自然透明。
##
## 接口：
##   play(tint, count)          → 默认播第 1 段（兼容旧调用）
##   play_segment(n, tint)      → 播第 n 段（0/1/2），Battle 的每次命中各调一次
##
## Battle 会为每次命中 new 一个实例并调 play_segment(hit)，所以每个实例只负责一段。

const SEGMENTS := [
	{"atlas": "res://assets/sprites/skills/taixu_shenjian/seg1_atlas.png",
		"frames": 15, "columns": 5},
	{"atlas": "res://assets/sprites/skills/taixu_shenjian/seg2_atlas.png",
		"frames": 15, "columns": 5},
	{"atlas": "res://assets/sprites/skills/taixu_shenjian/seg3_atlas.png",
		"frames": 16, "columns": 5},
]
const FRAME_W := 480
const FRAME_H := 277
const FPS := 15.0
## 画面抬高量：视频构图是"剑插在法阵中央"，抬起来让法阵落在脚下。
const LIFT := 96.0

var _t := 0.0
var _sprite: Sprite2D
var _frame := -1
var _segment := 0
var _mat: CanvasItemMaterial


func _ready() -> void:
	z_index = 6
	# 素材已经带 alpha（黑底转透明），用普通混合就够了：
	# 加法混合在桃花村这种亮背景上会被"加"到发白，反而看不清。
	_sprite = Sprite2D.new()
	_sprite.centered = true
	_sprite.region_enabled = true
	_sprite.region_rect = Rect2(0, 0, FRAME_W, FRAME_H)
	_sprite.position = Vector2(0, -LIFT)
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_sprite)
	_apply_segment(0)


func play(tint: Color = Color(0.8, 0.92, 1.0), _count: int = 0) -> void:
	play_segment(0, tint)


## 播第 index 段（0/1/2）。参数 tint 只是轻微染色，别把素材本身的金蓝色盖掉。
func play_segment(index: int, tint: Color = Color(0.8, 0.92, 1.0)) -> void:
	_segment = clampi(index, 0, SEGMENTS.size() - 1)
	_t = 0.0
	_frame = -1
	_apply_segment(_segment)
	_sprite.modulate = Color.WHITE.lerp(tint, 0.2)


func _apply_segment(index: int) -> void:
	var seg: Dictionary = SEGMENTS[index]
	_sprite.texture = load(String(seg["atlas"]))
	_frame = -1
	_sprite.region_rect = Rect2(0, 0, FRAME_W, FRAME_H)


func _process(delta: float) -> void:
	_t += delta
	var seg: Dictionary = SEGMENTS[_segment]
	var total: int = int(seg["frames"])
	var columns: int = int(seg["columns"])
	var idx := int(_t * FPS)
	if idx >= total:
		queue_free()
		return
	if idx != _frame:
		_frame = idx
		var col := idx % columns
		var row := idx / columns
		_sprite.region_rect = Rect2(col * FRAME_W, row * FRAME_H, FRAME_W, FRAME_H)

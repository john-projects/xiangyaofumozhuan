extends Node2D
## 角色骨骼动画：运行时生成 idle / walk / attack / cast 四条动画，
## 全部通过旋转 Bone2D 实现（2D 剪纸动画）。
##
## 为什么用脚本建动画：手写 .tscn 里的 Animation 资源又长又难改；
## 代码里一行一个关键帧，改数值一眼就能找到。
##
## 关键帧表示：每根骨头给一个 Array，元素是 Vector2(时间秒, 旋转弧度)。
## ⚠ GDScript 没有元组，别写 (0.0, 0.0)，要用 Vector2 或数组。

@onready var anim: AnimationPlayer = $AnimationPlayer


func _ready() -> void:
	# 先建空库，避免 get_animation_library("") 在没有库时刷一条 ERROR
	if not anim.has_animation_library(""):
		anim.add_animation_library("", AnimationLibrary.new())
	_make("idle", 2.0, {
		"关节/hip/spine:rotation": [Vector2(0.0, 0.0), Vector2(1.0, 0.012), Vector2(2.0, 0.0)],
		"关节/hip/spine/chest/neck/head:rotation": [Vector2(0.0, 0.0), Vector2(0.7, -0.02), Vector2(1.5, 0.018), Vector2(2.0, 0.0)],
		"关节/hip/spine/chest/arm_l:rotation": [Vector2(0.0, 0.05), Vector2(1.0, 0.09), Vector2(2.0, 0.05)],
		"关节/hip/spine/chest/arm_r:rotation": [Vector2(0.0, -0.05), Vector2(1.0, -0.09), Vector2(2.0, -0.05)],
	})
	_make("walk", 0.8, {
		"关节/hip/leg_l:rotation": [Vector2(0.0, 0.32), Vector2(0.4, -0.32), Vector2(0.8, 0.32)],
		"关节/hip/leg_r:rotation": [Vector2(0.0, -0.32), Vector2(0.4, 0.32), Vector2(0.8, -0.32)],
		"关节/hip/spine/chest/arm_l:rotation": [Vector2(0.0, -0.22), Vector2(0.4, 0.22), Vector2(0.8, -0.22)],
		"关节/hip/spine/chest/arm_r:rotation": [Vector2(0.0, 0.22), Vector2(0.4, -0.22), Vector2(0.8, 0.22)],
		"关节/hip/spine:rotation": [Vector2(0.0, -0.03), Vector2(0.4, 0.03), Vector2(0.8, -0.03)],
	})
	_make("attack", 0.55, {
		"关节/hip/spine/chest/arm_r:rotation": [Vector2(0.0, -0.05), Vector2(0.12, -0.9), Vector2(0.28, 0.35), Vector2(0.55, -0.05)],
		"关节/hip/spine/chest/arm_r/fore_r:rotation": [Vector2(0.0, 0.0), Vector2(0.12, -0.5), Vector2(0.3, 0.2), Vector2(0.55, 0.0)],
		"关节/hip/spine:rotation": [Vector2(0.0, 0.0), Vector2(0.14, -0.16), Vector2(0.34, 0.06), Vector2(0.55, 0.0)],
		"关节/hip/spine/chest/neck/head:rotation": [Vector2(0.0, 0.0), Vector2(0.14, 0.1), Vector2(0.55, 0.0)],
	})
	_make("cast", 0.8, {
		"关节/hip/spine/chest/arm_l:rotation": [Vector2(0.0, 0.05), Vector2(0.25, 0.75), Vector2(0.6, 0.6), Vector2(0.8, 0.05)],
		"关节/hip/spine/chest/arm_r:rotation": [Vector2(0.0, -0.05), Vector2(0.25, -0.75), Vector2(0.6, -0.6), Vector2(0.8, -0.05)],
		"关节/hip/spine:rotation": [Vector2(0.0, 0.0), Vector2(0.25, 0.1), Vector2(0.6, 0.06), Vector2(0.8, 0.0)],
		"关节/hip/spine/chest/neck/head:rotation": [Vector2(0.0, 0.0), Vector2(0.25, -0.12), Vector2(0.8, 0.0)],
	})
	anim.play("idle")



## 建一条动画：tracks = { 骨骼属性路径: Array[Vector2](时间, 弧度) }
func _make(name: String, length: float, tracks: Dictionary) -> void:
	var a := Animation.new()
	a.length = length
	a.loop_mode = Animation.LOOP_LINEAR
	for path in tracks:
		var t := a.add_track(Animation.TYPE_VALUE)
		a.track_set_path(t, NodePath(path))
		a.track_set_interpolation_type(t, Animation.INTERPOLATION_CUBIC)
		for k in tracks[path]:
			a.track_insert_key(t, k.x, k.y)
	var lib := anim.get_animation_library("")
	if lib == null:
		lib = AnimationLibrary.new()
		anim.add_animation_library("", lib)
	lib.add_animation(name, a)

extends Node2D
## 角色骨骼动画：运行时生成 idle / walk / attack / cast 四条动画。
## 全部通过旋转关节节点实现（2D 剪纸动画）。
##
## 为什么用脚本建动画：手写 .tscn 里的 Animation 资源又长又难改；
## 代码里一行一个关键帧，改数值一眼就能找到。
##
## ⚠ 动画是运行时建的，**编辑器的 AnimationPlayer 面板里看不到**。
##    要看效果：打开场景按 F6 运行，然后用数字键 1~4 切换。
##
## 按键：
##   1 = idle（待机）  2 = walk（走路）
##   3 = attack（攻击） 4 = cast（施法）
##
## 关键帧表示：每根骨头给一个 Array，元素是 Vector2(时间秒, 旋转弧度)。
## ⚠ GDScript 没有元组，别写 (0.0, 0.0)，要用 Vector2 或数组。

## 一次性动画播完自动回 idle 的名字
const ONESHOT := ["attack", "cast"]

@onready var anim: AnimationPlayer = $AnimationPlayer

## 屏幕左上角的提示（F6 运行时才创建）
var _hint: Label = null


func _ready() -> void:
	# 先建空库，避免 get_animation_library("") 在没有库时刷一条 ERROR
	if not anim.has_animation_library(""):
		anim.add_animation_library("", AnimationLibrary.new())

	_make("idle", 2.0, true, {
		"关节/hip/spine:rotation": [Vector2(0.0, 0.0), Vector2(1.0, 0.012), Vector2(2.0, 0.0)],
		"关节/hip/spine/chest/neck/head:rotation": [Vector2(0.0, 0.0), Vector2(0.7, -0.02), Vector2(1.5, 0.018), Vector2(2.0, 0.0)],
		"关节/hip/spine/chest/arm_l:rotation": [Vector2(0.0, 0.05), Vector2(1.0, 0.09), Vector2(2.0, 0.05)],
		"关节/hip/spine/chest/arm_r:rotation": [Vector2(0.0, -0.05), Vector2(1.0, -0.09), Vector2(2.0, -0.05)],
	})
	# ── 走路：正面视角，不能左右摆腿 ──
	# 正面角色走路靠三件事，全都是**上下**方向的：
	#   ① 两条腿交替抬起（position.y 上下）—— 没有腿骨的角色跳过
	#   ② 上半身轻微起伏（spine 上下）
	#   ③ 手臂只做几度微摆，负责"有在动"的感觉
	# ⚠ position 轨道写的是**完整**坐标不是增量，所以基准值**从场景里现读**，
	#   这样在编辑器里挪过腿/躯干之后动画不会把角色弹回原位。
	# ⚠ 不同版本拆件用的骨头不一样（v4 没有腿骨），所以所有节点都要判空。
	var lift := 26.0            # 抬腿高度
	var bob := 9.0              # 身体起伏
	var leg_l := get_node_or_null("关节/hip/leg_l") as Node2D
	var leg_r := get_node_or_null("关节/hip/leg_r") as Node2D
	var sp := get_node_or_null("关节/hip/spine") as Node2D
	var tracks := {}
	if leg_l != null:
		var bl := leg_l.position
		tracks["关节/hip/leg_l:position"] = [bl, Vector2(bl.x, bl.y - lift), bl, bl, bl]
	if leg_r != null:
		var br := leg_r.position
		tracks["关节/hip/leg_r:position"] = [br, br, br, Vector2(br.x, br.y - lift), br]
	if sp != null:
		var bs := sp.position
		tracks["关节/hip/spine:position"] = [
			bs, Vector2(bs.x, bs.y + bob * 0.5), Vector2(bs.x, bs.y + bob),
			Vector2(bs.x, bs.y + bob * 0.5), bs]
	tracks["关节/hip/spine/chest/arm_l:rotation"] = [Vector2(0.0, -0.05), Vector2(0.25, -0.09), Vector2(0.5, -0.05), Vector2(0.75, -0.09), Vector2(0.8, -0.05)]
	tracks["关节/hip/spine/chest/arm_r:rotation"] = [Vector2(0.0, 0.05), Vector2(0.25, 0.09), Vector2(0.5, 0.05), Vector2(0.75, 0.09), Vector2(0.8, 0.05)]
	tracks["关节/hip/spine/chest/neck/head:rotation"] = [Vector2(0.0, 0.0), Vector2(0.4, 0.015), Vector2(0.8, 0.0)]
	_make("walk", 0.8, true, tracks)
	_make("attack", 0.55, false, {
		"关节/hip/spine/chest/arm_r:rotation": [Vector2(0.0, -0.05), Vector2(0.12, -0.9), Vector2(0.28, 0.35), Vector2(0.55, -0.05)],
		"关节/hip/spine/chest/arm_r/fore_r:rotation": [Vector2(0.0, 0.0), Vector2(0.12, -0.5), Vector2(0.3, 0.2), Vector2(0.55, 0.0)],
		"关节/hip/spine:rotation": [Vector2(0.0, 0.0), Vector2(0.14, -0.16), Vector2(0.34, 0.06), Vector2(0.55, 0.0)],
		"关节/hip/spine/chest/neck/head:rotation": [Vector2(0.0, 0.0), Vector2(0.14, 0.1), Vector2(0.55, 0.0)],
	})
	_make("cast", 0.8, false, {
		"关节/hip/spine/chest/arm_l:rotation": [Vector2(0.0, 0.05), Vector2(0.25, 0.75), Vector2(0.6, 0.6), Vector2(0.8, 0.05)],
		"关节/hip/spine/chest/arm_r:rotation": [Vector2(0.0, -0.05), Vector2(0.25, -0.75), Vector2(0.6, -0.6), Vector2(0.8, -0.05)],
		"关节/hip/spine:rotation": [Vector2(0.0, 0.0), Vector2(0.25, 0.1), Vector2(0.6, 0.06), Vector2(0.8, 0.0)],
		"关节/hip/spine/chest/neck/head:rotation": [Vector2(0.0, 0.0), Vector2(0.25, -0.12), Vector2(0.8, 0.0)],
	})

	# 一次性动画播完回 idle（不接这条的话 attack 会**停在最后一帧**）
	anim.animation_finished.connect(_on_anim_finished)
	anim.play("idle")
	design_height = _measure_height()
	_build_hint()


## 建一条动画：tracks = { 骨骼属性路径: Array[Vector2](时间, 弧度) }
func _make(anim_name: String, length: float, loop: bool, tracks: Dictionary) -> void:
	var a := Animation.new()
	a.length = length
	a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
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
	lib.add_animation(anim_name, a)


# ── 调试用：数字键切换动画 ──────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var map := {
		KEY_1: "idle",
		KEY_2: "walk",
		KEY_3: "attack",
		KEY_4: "cast",
	}
	var key: int = event.keycode
	if map.has(key):
		play(map[key])
		get_viewport().set_input_as_handled()
	elif key == KEY_R:
		# 回到 rest 姿势（所有关节旋转归零），方便检查各件对齐
		anim.stop()
		for b in ["hip", "spine", "chest", "neck", "head", "arm_l", "fore_l",
				"hand_l", "arm_r", "fore_r", "hand_r", "leg_l", "leg_r"]:
			var n := get_node_or_null("关节/hip/" + b)
			if n == null:
				n = _find_bone(b)
			if n != null:
				n.rotation = 0.0
		_update_hint("rest（静止姿势）")
		get_viewport().set_input_as_handled()


## 播动画（外部也调这个：rig.play("walk")）
func play(anim_name: String) -> void:
	if not anim.has_animation(anim_name):
		return
	anim.play(anim_name)
	_update_hint(anim_name)


func _find_bone(bone: String) -> Node:
	for n in get_node("关节").get_children():
		if n.name == bone:
			return n
		if n.find_child(bone, true, false) != null:
			return n.find_child(bone, true, false)
	return null


func _on_anim_finished(anim_name: String) -> void:
	if anim_name in ONESHOT:
		anim.play("idle")
		_update_hint("idle")


# ── 屏幕提示 ──────────────────────────────────────────────────────

func _build_hint() -> void:
	if not OS.has_feature("editor") and not OS.is_debug_build():
		return
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_hint = Label.new()
	_hint.position = Vector2(24, 20)
	_hint.add_theme_font_size_override("font_size", 22)
	_hint.add_theme_color_override("font_color", Color(1, 1, 0.8))
	layer.add_child(_hint)
	_update_hint("idle")


func _update_hint(anim_name: String) -> void:
	if _hint == null:
		return
	_hint.text = "当前动画：%s\n[1] idle   [2] walk   [3] attack   [4] cast   [R] 静止姿势" % anim_name


# ── 自身尺寸（外部用它算缩放）────────────────────────────────────

## 这套拆件拼起来的**设计高度**（脚底到头顶，像素）。
## _ready 里量出来，world_map / battle_unit 用它把角色缩到游戏里的目标高度。
var design_height := 1.0


## 量身高：遍历所有 Sprite2D，取最上面那个顶点到脚底（原点）的距离。
## 用 to_global 而不是自己算 matrix，这样哪怕某个部件被转过、缩放过也准。
func _measure_height() -> float:
	var top := 0.0
	var found := false
	for n in find_children("*", "Sprite2D", true, false):
		var s := n as Sprite2D
		if s.texture == null:
			continue
		var w := s.texture.get_width() * s.scale.x
		var h := s.texture.get_height() * s.scale.y
		# centered=false 时贴图占局部 (0,0)-(w,h)，取四角里最高的那个
		for p in [Vector2(0, 0), Vector2(w, 0), Vector2(0, h), Vector2(w, h)]:
			var y := s.to_global(p).y
			if not found or y < top:
				top = y
				found = true
	if not found:
		return 1.0
	return maxf(1.0, -top)

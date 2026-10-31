class_name CharAnim2D
extends Node
## 给一个 Sprite2D 播放「8 方位 × 4 动作」的帧动画。
##
## 为什么不用 AnimatedSprite2D / SpriteFrames：
##   项目的战斗单位、地图角色、轮廓 shader 全部围绕 Sprite2D.texture 写的
##   （sprite.texture / flip_h / offset / outline.texture 都是直接读它）。
##   换成 AnimatedSprite2D 要连带改轮廓、缩放归一、点击区域一堆地方。
##   这里改成"一个 Sprite2D + region 换帧"：sprite.texture 指向条带图，
##   sprite.region_rect 指向当前帧 —— 上层代码完全不用动。
##
## 资源约定（见 UnitStats.anim_dir）：
##   <目录>/<动作>_<方位>.png，横向排 N 帧，每帧 320×480。
##   动作：idle / run / attack / cast
##   方位：down / down_right / right / up_right / up / up_left / left / down_left
##
## 用法：
##   var anim := CharAnim2D.new()
##   add_child(anim)
##   if anim.setup(sprite, stats.anim_dir):
##       anim.play("run", "down")
##       anim.play_once("attack")        # 播完自动回到 idle

## 单帧尺寸（像素）。所有条带图必须一致，否则 region 会错位。
const FRAME_W := 320
const FRAME_H := 480

## 8 个方位。**顺序有意义**：_facing_from_vector() 按角度 45° 分扇区，下标要和这里对应。
## 素材只有两个斜向时：四个正方向吸附到最近的斜向。
const SNAP_DIR := {
	"down": "down_right",
	"right": "down_right",
	"up": "up_left",
	"left": "up_left",
}
## 缺哪一侧就用另一侧镜像（sprite.flip_h）。只列"靠镜像补出来"的方向。
const MIRROR_DIR := {
	"down_left": "down_right",
	"up_right": "up_left",
}
const DIRS: Array[String] = ["right", "down_right", "down", "down_left",
		"left", "up_left", "up", "up_right"]

const ACTIONS: Array[String] = ["idle", "run", "attack", "cast"]

## 每个动作的播放帧率（帧/秒）。跑步要快一些，否则 8 帧看着像滑步；
## attack / cast 定得高，是为了让 6 帧的时长贴近战斗里原来的演出节奏（约 0.3s）。
const FPS := {"idle": 6.0, "run": 14.0, "attack": 16.0, "cast": 16.0}
## 是否循环。attack / cast 是一次性动作，播完要回到 idle。
const LOOPS := {"idle": true, "run": true, "attack": false, "cast": false}

## 一次性动作播完时发（参数是动作名）。外部想接"打完该干嘛"可以连它。
signal action_finished(action: String)
## 每换一帧发一次。战斗单位的轮廓（Sprite 下的 Outline）靠它同步 region。
signal frame_changed

## 被驱动的精灵。region 相关属性由本节点独占修改。
var sprite: Sprite2D = null
## 条带图所在目录（res:// 路径，不带结尾斜杠）。
var base_dir := ""

var _sheets := {}            # "idle_down" -> Texture2D（按需加载并缓存）
var _action := "idle"
var _dir := "down"
var _frame := 0
var _time := 0.0
## 当前是不是"一次性动作播放中"。是的话播完会回到 _rest_*。
var _once := false
## 一次性动作结束后要回到的状态（战斗里就是 idle + 朝向右侧）。
var _rest_action := "idle"
var _rest_dir := "down"


## 绑定精灵并检查资源是否存在。返回 false 表示这个角色没有动画（调用方应继续用静态 icon）。
## 参数 p_sprite：要被驱动的 Sprite2D；p_dir：UnitStats.anim_dir 的内容。
## 副作用：给 sprite 打开 region、载入第一张图。
func setup(p_sprite: Sprite2D, p_dir: String) -> bool:
	if p_sprite == null or p_dir.is_empty():
		return false
	# 必须先设 base_dir 再探资源 —— _load_sheet 是靠 base_dir 拼路径的。
	base_dir = p_dir.rstrip("/")
	_sheets.clear()
	# 素材可能只有一个斜向（配合镜像用），所以不硬性要求 idle_down，任一 idle_* 即可。
	if _load_sheet("idle", "down") == null and _load_sheet("idle", "down_right") == null \
			and _load_sheet("idle", "up_left") == null:
		# 配了 anim_dir 却找不到文件时明确报出来，否则会静默退回静态图、很难查。
		push_warning("CharAnim2D: %s 下没有任何 idle_*.png（回退到静态立绘）" % base_dir)
		base_dir = ""
		return false
	sprite = p_sprite
	sprite.region_enabled = true
	_apply_frame()
	return true


## 切换动作/方位。同一动作同一方位重复调用会被忽略（避免每帧重置到第 0 帧）。
## 参数 action：idle / run / attack / cast；dir：八个方位之一。
func play(action: String, dir: String = "") -> void:
	if sprite == null:
		return
	var d := dir if not dir.is_empty() else _dir
	if action == _action and d == _dir:
		return
	_action = action
	_dir = d
	_frame = 0
	_time = 0.0
	_once = false
	_apply_frame()


## 播放一次性动作（attack / cast），播完自动回到 idle（保持当前朝向）。
## 参数 action：动作名；dir：可选指定朝向，留空沿用当前朝向。
func play_once(action: String, dir: String = "") -> void:
	if sprite == null:
		return
	var d := dir if not dir.is_empty() else _dir
	_action = action
	_dir = d
	_frame = 0
	_time = 0.0
	_once = true
	_rest_action = "idle"
	_rest_dir = d
	_apply_frame()


## 设置朝向（不动作切换）。参数 dir：八个方位之一。
## 注意：一次性动作播放中调它会被忽略 —— 否则挥刀到一半转身会很怪。
func set_facing(dir: String) -> void:
	if _once or sprite == null:
		return
	_rest_dir = dir
	if dir != _dir:
		_dir = dir
		_frame = 0
		_time = 0.0
		_apply_frame()


## 按移动向量自动选朝向。参数 v：屏幕方向（x 右、y 下），零向量表示没动。
## 8 扇区：把角度按 45° 切分，边界落在纯 45° 的方向上。
func facing_from_vector(v: Vector2) -> String:
	if v.length_squared() < 1e-6:
		return _dir
	# angle(): 0 = 右, PI/2 = 下（屏幕 y 向下），所以扇区顺序是 右→右下→下→左下→左→…
	var idx := int(round(v.angle() / (PI / 4.0)))
	idx = ((idx % 8) + 8) % 8
	return DIRS[idx]


## 当前动作是否是一次性动作、且还在播。
func is_playing_once() -> bool:
	return _once


func _process(delta: float) -> void:
	if sprite == null or not sprite.is_visible_in_tree():
		return
	_time += delta
	var fps: float = FPS.get(_action, 8.0)
	var count := _frame_count()
	if count <= 1:
		return
	var step := int(_time * fps)
	if step <= 0:
		return
	if step + _frame < count:
		_frame += step
		_time -= float(step) / fps
		_apply_frame()
	else:
		if LOOPS.get(_action, true):
			_frame = (step + _frame) % count
			_time = 0.0
			_apply_frame()
		else:
			# 一次性动作播完：发信号 + 回到静止状态
			_frame = count - 1
			_time = 0.0
			_apply_frame()
			var done := _action
			_once = false
			_action = _rest_action
			_dir = _rest_dir
			_frame = 0
			_apply_frame()
			action_finished.emit(done)


## 当前条带图的帧数（宽度 / 帧宽）。
func _frame_count() -> int:
	var r := _resolve(_action, _dir)
	var t: Texture2D = _sheets.get("%s_%s" % [String(r[0]), String(r[1])], null)
	if t == null:
		return 1
	return maxi(1, int(t.get_width() / FRAME_W))


## 把当前 _frame 写进 sprite.region_rect。
## 副作用：改 sprite.texture（换方位/动作时）和 region_rect（每帧）。
func _apply_frame() -> void:
	var r := _resolve(_action, _dir)
	var t := _load_sheet(String(r[0]), String(r[1]))
	if t == null:
		return
	# 镜像：素材是另一侧的，水平翻转补出这一侧
	sprite.flip_h = bool(r[2])
	if sprite.texture != t:
		sprite.texture = t
	var count := maxi(1, int(t.get_width() / FRAME_W))
	_frame = clampi(_frame, 0, count - 1)
	sprite.region_enabled = true
	sprite.region_rect = Rect2(float(_frame * FRAME_W), 0.0, float(FRAME_W), float(FRAME_H))
	frame_changed.emit()


## 把 (动作, 方位) 解析成实际要用的 (动作, 方位, 是否镜像)。
## 优先级：原样有素材 → 正方向吸附斜向 → 缺侧走镜像 → 动作整组缺失退回 idle。
func _resolve(action: String, dir: String) -> Array:
	var d := dir
	# ① 正方向吸附到斜向（只在"该动作下这个正方向真的没有素材"时才吸附）
	if SNAP_DIR.has(d) and _load_sheet(action, d) == null:
		d = String(SNAP_DIR[d])
	# ② 缺侧镜像
	var flip := false
	if _load_sheet(action, d) == null and MIRROR_DIR.has(d):
		d = String(MIRROR_DIR[d])
		flip = true
	# ③ 这个动作完全没有素材 → 用同朝向的 idle（角色至少还在呼吸）
	if _load_sheet(action, d) == null and action != "idle":
		action = "idle"
		if _load_sheet(action, d) == null and MIRROR_DIR.has(d):
			d = String(MIRROR_DIR[d])
			flip = true
	return [action, d, flip]


## 按需加载条带图并缓存。返回 null 表示该动作/方位没有资源。
func _load_sheet(action: String, dir: String) -> Texture2D:
	var key := "%s_%s" % [action, dir]
	if _sheets.has(key):
		return _sheets[key]
	if base_dir.is_empty():
		return null
	var path := "%s/%s.png" % [base_dir, key]
	if not ResourceLoader.exists(path):
		return null
	var t := load(path) as Texture2D
	_sheets[key] = t
	return t

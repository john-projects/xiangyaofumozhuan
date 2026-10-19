class_name Model3DAvatar
extends Node2D
## 用「3D 模型实时渲染」扮演 2D 角色（3D-in-2D）。
##
## 结构（全部代码构建，避免手写 .tscn 时 ViewportTexture 连不上）：
##   Model3DAvatar (Node2D)
##    ├── SubViewport     透明背景、每帧更新、自带独立 3D 世界
##    │    ├── Camera3D   正交、等轴测角度（-35.264°, 45°）
##    │    ├── DirectionalLight3D + WorldEnvironment（环境光，防止背面死黑）
##    │    └── 模型实例（.glb）
##    └── Sprite2D        纹理 = SubViewport.get_texture()
##
## 为什么用 Sprite2D 而不是 SubViewportContainer：
##   SubViewportContainer 是 Control，塞进 Node2D 的 y_sort 里会破坏前后遮挡；
##   Sprite2D 是 CanvasItem，能正常参与 y_sort、flip、modulate、描边 shader。
##
## 用法：
##   var av := Model3DAvatar.new()
##   add_child(av)
##   if av.setup("res://assets/models/xingxiu/xingxiu_rigged.glb", 195.0):
##       av.play("run")
##       av.face_from_vector(dir)

## 视口分辨率。越大越清晰，显存和填充率也越高；2D 显示高度只有 ~195，256 足够。
const VIEW_W := 256
const VIEW_H := 384
## 相机正交尺寸（世界单位）。模型高约 1.90，留 10% 余量。
const ORTHO_SIZE := 2.10
## 相机俯角。**用 0**：2D 地图上其他角色都是正视立绘，俯视会把角色压扁显得"变形"。
## （之前设成 -35.264° 的等轴测角，正是"看起来被拉长/压扁"的原因之一。）
const ISO_PITCH := 0.0
const ISO_YAW := 0.0

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _sprite: Sprite2D = null
var _model: Node3D = null
var _anim: AnimationPlayer = null
var _ready_ok := false

## 模型根节点的额外 Y 旋转。正视角下模型朝 +Z（面向相机）= 游戏里的"正下"，所以偏移为 0。
var _yaw_offset := 0.0


## 建立视口/相机/灯光并载入模型。
## 参数 glb_path：res:// 下的 .glb 路径；display_height：希望在 2D 屏幕上显示的高度（像素）。
## 返回 true 表示成功；失败会 push_warning 并返回 false（调用方应回退到静态立绘）。
func setup(glb_path: String, display_height := 195.0) -> bool:
	if not ResourceLoader.exists(glb_path):
		push_warning("Model3DAvatar: 找不到 %s" % glb_path)
		return false
	var packed := load(glb_path)
	if packed == null or not (packed is PackedScene):
		push_warning("Model3DAvatar: %s 不是 PackedScene（Godot 是否已导入？）" % glb_path)
		return false

	# ── SubViewport ──
	_viewport = SubViewport.new()
	_viewport.name = "Viewport3D"
	_viewport.size = Vector2i(VIEW_W, VIEW_H)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	add_child(_viewport)

	# ── 灯光 & 环境（没有环境光的话模型背面会死黑）──
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.76, 0.86)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	_viewport.add_child(we)

	var key := DirectionalLight3D.new()
	key.light_energy = 1.15
	key.light_color = Color(1.0, 0.96, 0.90)
	key.rotation_degrees = Vector3(-48, 38, 0)
	key.shadow_enabled = false
	_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.35
	fill.light_color = Color(0.72, 0.82, 1.0)
	fill.rotation_degrees = Vector3(-15, -130, 0)
	fill.shadow_enabled = false
	_viewport.add_child(fill)

	# ── 相机 ──
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = ORTHO_SIZE
	_camera.rotation_degrees = Vector3(ISO_PITCH, ISO_YAW, 0)
	# 沿自身 +Z（后方）退开，保证模型在视锥内
	_camera.position = _camera.transform.basis.z * 6.0 + Vector3(0, 0.05, 0)
	_viewport.add_child(_camera)

	# ── 模型 ──
	_model = Node3D.new()
	_model.name = "ModelRoot"
	_model.rotation_degrees = Vector3(0, _yaw_offset, 0)
	_viewport.add_child(_model)
	var inst = packed.instantiate()
	_model.add_child(inst)
	_anim = _find_animation_player(inst)

	# ── 显示用 Sprite2D ──
	_sprite = Sprite2D.new()
	_sprite.name = "Sprite3DView"
	_sprite.texture = _viewport.get_texture()
	# 视口像素 → 世界像素：让整张视口在 2D 里显示成 display_height 那么高
	_sprite.scale = Vector2.ONE * (display_height / float(VIEW_H))
	# 脚底锚定：正视角下模型投影高 = 1.898，占正交尺寸 2.10 的 90.4%，
	# 所以脚底在视口中心下方 45.2% 处。
	_sprite.offset = Vector2(0.0, -VIEW_H * 0.452)

	# 诊断输出：出问题时这几行能直接定位是视口尺寸、相机还是贴图不对
	var tex_size := Vector2.ZERO
	if _sprite.texture != null:
		tex_size = _sprite.texture.get_size()
	print("[Model3DAvatar] 视口=%s 贴图=%s 相机 ort=%s size=%.2f 精灵缩放=%.4f"
			% [_viewport.size, tex_size, _camera.projection, _camera.size, _sprite.scale.x])
	var mi := _find_mesh_instance(inst)
	if mi != null:
		print("[Model3DAvatar] 网格 AABB 尺寸=%s（原始应为约 1.19 × 1.90 × 0.81）"
				% mi.get_aabb().size)
	add_child(_sprite)

	_ready_ok = true
	return true


func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root
	for c in root.get_children():
		var r := _find_animation_player(c)
		if r != null:
			return r
	return null


func _find_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root
	for c in root.get_children():
		var r := _find_mesh_instance(c)
		if r != null:
			return r
	return null


## 播放动画。参数 anim：idle / run / attack / cast（导出时写进 GLB 的片段名）。
func play(anim: String, blend := 0.15) -> void:
	if _anim == null:
		return
	if _anim.current_animation == anim and _anim.is_playing():
		return
	_anim.play(anim, blend)


## 播放一次性动作，播完自动回 idle。返回片段时长（秒），0 表示没有这个片段。
func play_once(anim: String, blend := 0.08) -> float:
	if _anim == null or not _anim.has_animation(anim):
		return 0.0
	_anim.play(anim, blend)
	var dur := _anim.get_animation(anim).length
	get_tree().create_timer(dur).timeout.connect(func() -> void:
		if is_instance_valid(self) and _anim != null:
			_anim.play("idle", 0.18))
	return dur


## 按 2D 移动向量转 3D 模型的朝向。
## 参数 v：屏幕方向（x 右、y 下）。
## 换算：模型 rotation.y=0 时朝 +Z（面向相机）= 屏幕"下"，
##       所以 θ = atan2(v.x, v.y)：右→90°、下→0°、左→-90°、上→180°。
func face_from_vector(v: Vector2) -> void:
	if _model == null or v.length_squared() < 1e-6:
		return
	_model.rotation_degrees.y = rad_to_deg(atan2(v.x, v.y)) + _yaw_offset


## 直接把模型转到某个方位（8 方位名，和贴图方案保持一致）。
func face_dir(dir: String) -> void:
	const DEG := {"down": 0.0, "down_right": 45.0, "right": 90.0, "down_left": -45.0,
			"up": 180.0, "up_right": 135.0, "left": -90.0, "up_left": -135.0}
	if _model == null:
		return
	_model.rotation_degrees.y = DEG.get(dir, 0.0) + _yaw_offset


## 是否初始化成功（失败时调用方应回退到静态贴图）。
func is_ready() -> bool:
	return _ready_ok

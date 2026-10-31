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
##   if av.setup("res://assets/models/players/行修.glb", 195.0):
##       av.play("run")
##       av.face_from_vector(dir)

## 动作留白：横向原来的三倍、纵向 1.5 倍，避免挥袖/武器被矩形边界裁掉。
## 相机范围与分辨率同比扩大，保持人物的像素密度；校准仍以人物身高为准。
const VIEW_W := 768
const VIEW_H := 576
const ORTHO_SIZE := 3.15
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
var _weapon_socket: BoneAttachment3D = null
var _weapon: Node3D = null
var _weapon_item: ItemEquipment = null
var _calibrated := false
var _action_revision := 0
## 希望模型在 2D 屏幕上显示的高度（像素）；_calibrate() 用它换算精灵缩放。
var _display_height := 195.0

## 模型根节点的额外 Y 旋转。正视角下模型朝 +Z（面向相机）= 游戏里的"正下"，所以偏移为 0。
var _yaw_offset := 0.0


## 建立视口/相机/灯光并载入模型。
## 参数 glb_path：res:// 下的 .glb 路径；display_height：希望在 2D 屏幕上显示的高度（像素）。
## 返回 true 表示成功；失败会 push_warning 并返回 false（调用方应回退到静态立绘）。
func setup(glb_path: String, display_height := 195.0, map_view := false) -> bool:
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
	env.ambient_light_color = Color(0.88, 0.86, 0.82) if map_view else Color(0.72, 0.76, 0.86)
	env.ambient_light_energy = 0.70 if map_view else 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	_viewport.add_child(we)

	var key := DirectionalLight3D.new()
	key.light_energy = 0.80 if map_view else 1.15
	key.light_color = Color(1.0, 0.96, 0.90)
	key.rotation_degrees = Vector3(-48, 38, 0)
	key.shadow_enabled = false
	_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.18 if map_view else 0.35
	fill.light_color = Color(0.72, 0.82, 1.0)
	fill.rotation_degrees = Vector3(-15, -130, 0)
	fill.shadow_enabled = false
	_viewport.add_child(fill)

	# ── 相机 ──
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = ORTHO_SIZE
	# 地图轻微俯视，保留 Q 版比例；战斗继续使用原来的取景。
	_camera.rotation_degrees = Vector3(-12.0 if map_view else ISO_PITCH, ISO_YAW, 0)
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
	# 行修的原动作带大幅转身和长收招；游戏内改用站姿衍生的短上身动作。
	if glb_path.ends_with("/行修.glb"):
		_build_compact_actions()
	# 不同来源的模型原点不一样（有的在脚底、有的在身体中心）：先按网格包围盒把**身体中心**挪到原点，
	# 否则"原点在脚底"的模型会把头挤出画面（Meshy 的模型就是这样，头直接被裁掉）。
	var bounds := _model_bounds(inst)
	if bounds.size.y > 0.0:
		_model.position = -bounds.get_center()
	_setup_weapon_socket(inst)

	# ── 显示用 Sprite2D ──
	_sprite = Sprite2D.new()
	_sprite.name = "Sprite3DView"
	_sprite.texture = _viewport.get_texture()
	# 视口像素 → 世界像素：先按"整张视口 = display_height"估算，真正的大小由 _calibrate() 按实际像素量出来再修正。
	_sprite.scale = Vector2.ONE * (display_height / float(VIEW_H))
	# 脚底锚定的初值（旧模型的近似值），_calibrate() 会按真实 alpha 包围盒重算
	_sprite.offset = Vector2(0.0, -VIEW_H * 0.452)
	_display_height = display_height

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
	# 不同来源的模型（Meshy / 自建）骨骼姿势缩放差很多，AABB 不可靠：
	# 等第一帧画完，用视口里真实的 alpha 包围盒把「身高」和「脚底」校准一次。
	_calibrate.call_deferred()

	_ready_ok = true
	play("idle", 0.0)
	return true


## 手部挂点跟随骨骼，不需要逐帧维护武器坐标。
func _setup_weapon_socket(inst: Node) -> void:
	var skeletons := inst.find_children("*", "Skeleton3D", true, false)
	for node in skeletons:
		var skeleton := node as Skeleton3D
		for i in skeleton.get_bone_count():
			var bone := skeleton.get_bone_name(i)
			if bone.to_lower().replace("_", "").replace(":", "").ends_with("righthand"):
				_weapon_socket = BoneAttachment3D.new()
				_weapon_socket.name = "WeaponSocket"
				_weapon_socket.bone_name = bone
				skeleton.add_child(_weapon_socket)
				return


## 替换/卸下武器。只实例化外观，装备属性与背包仍由 GameRoot 管理。
func set_weapon(item: ItemEquipment) -> void:
	if item == _weapon_item:
		return
	_weapon_item = item
	if _weapon != null:
		_weapon.get_parent().remove_child(_weapon)
		_weapon.queue_free()
		_weapon = null
	if item == null or item.weapon_scene == null:
		return
	if _weapon_socket == null:
		push_warning("Model3DAvatar: 模型缺少右手骨骼，无法挂载武器")
		return
	var instance := item.weapon_scene.instantiate()
	if not instance is Node3D:
		instance.free()
		push_warning("Model3DAvatar: 武器场景根节点必须是 Node3D")
		return
	_weapon = instance as Node3D
	_weapon_socket.add_child(_weapon)
	_weapon.position = item.weapon_position
	_weapon.rotation_degrees = item.weapon_rotation_degrees
	_weapon.scale = Vector3.ONE * item.weapon_scale
	# 首帧身高校准只测人物，避免长剑改变人物的大小和脚底锚点。
	_weapon.visible = _calibrated


## 按视口第一帧的实际像素校准显示：身高 = display_height，脚底落在原点。
## 为什么不用 AABB：绑定姿势的 AABB 和骨骼摆出来的实际大小可能差一倍（Meshy 的模型尤其明显）。
func _calibrate() -> void:
	if _sprite == null or _viewport == null:
		return
	await RenderingServer.frame_post_draw
	if not is_instance_valid(self) or _sprite == null:
		return
	var img := _viewport.get_texture().get_image()
	if img == null or img.is_empty():
		return
	var used := img.get_used_rect()
	if used.size.y <= 0:
		return
	# 身高：让 alpha 包围盒的高度正好等于 display_height
	_sprite.scale = Vector2.ONE * (_display_height / float(used.size.y))
	# 脚底：包围盒底边（used.end.y）对齐到节点原点 y=0
	_sprite.offset = Vector2(VIEW_W * 0.5 - float(used.get_center().x),
			VIEW_H * 0.5 - float(used.end.y))
	_calibrated = true
	if is_instance_valid(_weapon):
		_weapon.visible = true
	print("[Model3DAvatar] 校准：alpha 包围盒=%s → 缩放=%.4f 偏移=%s"
			% [used, _sprite.scale.x, _sprite.offset])


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


## 所有网格的世界包围盒并集（用来找"身体中心"，不依赖模型原点在哪）。
## 用 global_transform × aabb：模型实例已经在视口树里，变换有效。
func _model_bounds(root: Node) -> AABB:
	var out := AABB()
	var first := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var box: AABB = mi.global_transform * mi.get_aabb()
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out


## 逻辑动作名 → 各模型可能用的剪辑名（不同美术导出的命名不统一，按这张表兜底）。
## Meshy 那套：Alert=站立、Running=跑、Walking=走、Attack=攻击、Skill_01=施法、Dead=倒地。
const ANIM_ALIASES := {
	"idle": ["idle", "Idle", "Alert", "Standing", "Stand"],
	"run": ["run", "Run", "Running", "Walk", "Walking"],
	"walk": ["walk", "Walk", "Walking"],
	"attack": ["attack", "Attack", "Attack_01"],
	"cast": ["cast", "Cast", "Skill_01", "Skill", "Spell"],
	"dead": ["dead", "Dead", "Death"],
}


## 播放循环动画。参数 anim：逻辑动作名（idle / run / walk / attack / cast / dead）；
## 实际剪辑名由 _resolve_anim() 模糊匹配（精确 → 别名表 → 包含关键词），找不到就什么也不做。
func play(anim: String, blend := 0.15) -> void:
	if _anim == null:
		return
	var clip := _resolve_anim(anim)
	if clip.is_empty():
		return
	if _anim.current_animation == clip and _anim.is_playing():
		return
	_action_revision += 1
	_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR if anim in ["idle", "run", "walk"] else Animation.LOOP_NONE
	_anim.play(clip, blend)


## 把逻辑动作名解析成这个模型真实存在的剪辑名；找不到返回 ""。
func _resolve_anim(anim: String) -> String:
	if _anim == null:
		return ""
	if _anim.has_animation("compact/" + anim):
		return "compact/" + anim
	var list := _anim.get_animation_list()
	if list.has(anim):
		return anim
	for candidate in ANIM_ALIASES.get(anim, []):
		if list.has(candidate):
			return candidate
	# 最后退化成"包含关键词"（大小写不敏感），兼容 Move_Run / run_cycle 这类命名
	var low := anim.to_lower()
	for clip in list:
		if String(clip).to_lower().contains(low):
			return String(clip)
	return ""


## 保留 idle 的腿、髋部和根节点，只做一次小幅挥击/抬手。
## 每个实例独立建库，原 GLB 和其他角色不受影响。
func _build_compact_actions() -> void:
	if _anim == null:
		return
	var idle_clip := _resolve_anim("idle")
	if idle_clip.is_empty():
		return
	var rest := _anim.get_animation(idle_clip)
	var library := AnimationLibrary.new()
	for action in ["attack", "cast"]:
		var clip := Animation.new()
		clip.length = 0.48
		var phases := [0.0, 0.22, 0.44, 0.64, 1.0]
		for track in rest.get_track_count():
			var kind := rest.track_get_type(track)
			if kind not in [Animation.TYPE_ROTATION_3D, Animation.TYPE_POSITION_3D, Animation.TYPE_SCALE_3D]:
				continue
			var out := clip.add_track(kind)
			var path := rest.track_get_path(track)
			clip.track_set_path(out, path)
			var bone := String(path).to_lower().replace("_", "")
			for i in phases.size():
				var time: float = phases[i] * clip.length
				if kind == Animation.TYPE_ROTATION_3D:
					var base := rest.rotation_track_interpolate(track, 0.0)
					var delta := Vector3.ZERO
					if action == "attack":
						var stroke: float = [0.0, -0.4, 1.0, 0.65, 0.0][i]
						if bone.ends_with("rightarm"):
							delta.x = 80.0 * stroke
						elif bone.ends_with("rightforearm"):
							delta.x = 18.0 * stroke
						elif bone.ends_with("leftarm"):
							delta.x = -25.0 * stroke
						elif bone.ends_with("spine1"):
							delta.x = 12.0 * stroke
						elif bone.ends_with("spine2"):
							delta.x = 12.0 * stroke
							delta.y = 16.0 * stroke
						elif bone.ends_with("head"):
							delta.x = -6.0 * stroke
							delta.y = -4.0 * stroke
					else:
						var lift: float = [0.0, 0.45, 1.0, 0.8, 0.0][i]
						if bone.ends_with("rightarm") or bone.ends_with("leftarm"):
							delta.x = -50.0 * lift
						elif bone.ends_with("rightforearm") or bone.ends_with("leftforearm"):
							delta.x = -22.0 * lift
					clip.rotation_track_insert_key(out, time, base * Quaternion.from_euler(delta * PI / 180.0))
				elif kind == Animation.TYPE_POSITION_3D:
					clip.position_track_insert_key(out, time, rest.position_track_interpolate(track, 0.0))
				else:
					clip.scale_track_insert_key(out, time, rest.scale_track_interpolate(track, 0.0))
		library.add_animation(action, clip)
	_anim.add_animation_library("compact", library)


## 播放一次性动作，播完自动回 idle。返回片段时长（秒），0 表示没有这个片段。
## 参数 anim 同样走 _resolve_anim()：模型里叫 "Attack"/"Skill_01" 也能用 "attack"/"cast" 调用。
func play_once(anim: String, blend := 0.08) -> float:
	if _anim == null:
		return 0.0
	var clip := _resolve_anim(anim)
	if clip.is_empty():
		return 0.0
	_action_revision += 1
	var revision := _action_revision
	_anim.get_animation(clip).loop_mode = Animation.LOOP_NONE
	_anim.play(clip, blend)
	var dur := _anim.get_animation(clip).length
	if anim == "dead":
		return dur
	var idle_clip := _resolve_anim("idle")
	get_tree().create_timer(dur).timeout.connect(func() -> void:
		if is_instance_valid(self) and _anim != null and revision == _action_revision and not idle_clip.is_empty():
			play("idle", 0.06 if clip.begins_with("compact/") else 0.18))
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

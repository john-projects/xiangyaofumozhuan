extends Node2D
## 同一场景既可在编辑器预览，也可把关键帧应用到当前装备的握点。

@export_range(0.0, 1.0, 0.01) var attack_front_recovery_start := 0.89

@onready var _pose: Node2D = $Pose
@onready var _preview: Sprite2D = $Pose/Weapon
@onready var _player: AnimationPlayer = $AnimationPlayer
@onready var _preview_rest_transform: Transform2D = _preview.transform

var _pivot: Node2D
var _weapon_frames: AnimatedSprite2D
var _tween: Tween
var _rest_transform := Transform2D.IDENTITY
var _rest_modulate := Color.WHITE
var _rest_frame := 0
var _rest_progress := 0.0
var _was_playing := false


func clip_length(action: StringName, fallback: float) -> float:
	var clip := _player.get_animation(action) if _player.has_animation(action) else null
	return clip.length if clip != null and clip.length > 0.0 else fallback


func play_on(pivot: Node2D, action: StringName, duration: float, facing: float,
		travel_scale: Vector2, front_shift: Vector2 = Vector2.ZERO) -> void:
	restore()
	if not is_instance_valid(pivot) or not _player.has_animation(action) or duration <= 0.0:
		return
	hide()
	_pivot = pivot
	_rest_transform = pivot.transform
	_rest_modulate = pivot.modulate
	_weapon_frames = pivot.get_node_or_null("WeaponAnim") as AnimatedSprite2D
	if _weapon_frames != null and _weapon_frames.visible:
		_rest_frame = _weapon_frames.frame
		_rest_progress = _weapon_frames.frame_progress
		_was_playing = _weapon_frames.is_playing()
		_weapon_frames.pause()
	else:
		_weapon_frames = null

	_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_player.play(action)
	var length := clip_length(action, duration)
	var sample := _sample.bind(facing, travel_scale, front_shift, length)
	sample.call(0.0)
	_tween = create_tween()
	_tween.tween_method(sample, 0.0, length, duration)
	_tween.finished.connect(restore)


func _sample(time: float, facing: float, travel_scale: Vector2, front_shift: Vector2, length: float) -> void:
	if not is_instance_valid(_pivot):
		return
	_player.seek(time, true)
	var travel := Vector2(_pose.position.x * facing, _pose.position.y) * travel_scale
	# 攻击开头把握点带到人物身前，收招时移回原来的握点。
	var phase := time / length
	var front_weight := smoothstep(0.0, 0.20, phase) * (1.0 - smoothstep(attack_front_recovery_start, 1.0, phase))
	travel += front_shift * front_weight
	var pose_transform := Transform2D(
		_rest_transform.get_rotation() + _pose.rotation * facing,
		_rest_transform.get_scale() * _pose.scale,
		_rest_transform.get_skew(),
		_rest_transform.origin + travel
	)
	# 武器局部轨迹使用相对于预览握点的变换，例如普攻时沿刀身轴线镜像。
	if not _preview.transform.is_equal_approx(_preview_rest_transform):
		pose_transform *= _preview_rest_transform.affine_inverse() * _preview.transform
	_pivot.transform = pose_transform
	_pivot.modulate = _rest_modulate * _pose.modulate
	if is_instance_valid(_weapon_frames):
		var count := _weapon_frames.sprite_frames.get_frame_count(_weapon_frames.animation)
		if count > 0:
			_weapon_frames.set_frame_and_progress(mini(_preview.frame, count - 1), 0.0)


func restore() -> void:
	if _tween != null and _tween.is_running():
		_tween.kill()
	_tween = null
	if is_instance_valid(_pivot):
		_pivot.transform = _rest_transform
		_pivot.modulate = _rest_modulate
	_pivot = null
	if is_instance_valid(_weapon_frames):
		if _was_playing:
			_weapon_frames.play()
		_weapon_frames.set_frame_and_progress(_rest_frame, _rest_progress)
	_weapon_frames = null
	_player.stop()
	_preview.transform = _preview_rest_transform

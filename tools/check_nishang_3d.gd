extends Node
## Godot --headless --path . res://tools/check_nishang_3d.tscn
## 渲染预览：不传 --headless，并附加 -- --preview=<绝对 PNG 路径>。

var failures := 0


func _ready() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	var character := load("res://resources/units/players/霓裳.tres") as UnitStats
	_check(not character.model_glb.is_empty(), "霓裳应启用 3D 模型")
	var window := get_tree().root
	window.size = Vector2i(1000, 900)
	window.content_scale_size = window.size
	window.content_scale_factor = 1.0
	var avatars: Array[Model3DAvatar] = []
	for i in 4:
		var avatar := Model3DAvatar.new()
		add_child(avatar)
		_check(avatar.setup(character.model_glb, 320.0), "模型应加载成功")
		avatar.position = Vector2(260 + (i % 2) * 480, 370 + int(i / 2) * 440)
		avatar.face_dir("down_right" if i < 2 else "up_left")
		avatar.play("idle" if i % 2 == 0 else "run", 0.0)
		_check(avatar._weapon_socket != null, "应能找到右手骨骼作为未来武器挂点")
		var skeleton := avatar._weapon_socket.get_parent() as Skeleton3D
		_check(skeleton.get_bone_count() == 54, "重绑模型应有 54 根骨骼")
		var meshes := avatar._model.find_children("*", "MeshInstance3D", true, false)
		_check(not meshes.is_empty() and (meshes[0] as MeshInstance3D).skin != null, "模型应有蒙皮")
		var run_clip := avatar._resolve_anim("run")
		_check(not run_clip.is_empty(), "应有跑步剪辑")
		if i % 2 == 1:
			var leg := skeleton.find_bone("mixamorig_LeftUpLeg")
			if leg < 0:
				leg = skeleton.find_bone("mixamorig:LeftUpLeg")
			_check(leg >= 0, "应有腿部骨骼")
			var before := skeleton.get_bone_pose_rotation(leg)
			avatar._anim.advance(0.2)
			_check(not before.is_equal_approx(skeleton.get_bone_pose_rotation(leg)), "跑步应驱动腿部骨骼")
		avatars.append(avatar)
		var label := Label.new()
		label.text = ["站立 · 正面", "跑步 · 正面", "站立 · 背面", "跑步 · 背面"][i]
		label.position = avatar.position + Vector2(-90, 15)
		label.add_theme_font_size_override("font_size", 24)
		add_child(label)
	await _check_battle(character)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--preview="):
			for i in avatars.size():
				avatars[i]._anim.seek(0.2 if i % 2 == 1 else 0.0, true)
				avatars[i]._anim.pause()
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			_check(window.get_texture().get_image().save_png(arg.trim_prefix("--preview=")) == OK, "应成功保存预览")
	print("[nishang-3d] failures=%d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_battle(character: UnitStats) -> void:
	var unit := load("res://scenes/battle/battle_unit.tscn").instantiate() as BattleUnit
	add_child(unit)
	unit.position = Vector2(2000, 2000)
	unit.setup(character.duplicate(), true)
	_check(unit._model3d != null and not unit.sprite.visible, "战斗应显示 3D 模型")
	_check(not unit._model3d._resolve_anim("attack").is_empty(), "重做后应有专用攻击剪辑")
	_check(not unit._model3d._resolve_anim("cast").is_empty(), "重做后应有专用施法剪辑")
	# 避开初次同步载入模型的大帧耗时，再采样短暂的出招反馈。
	await get_tree().process_frame
	await get_tree().process_frame
	unit.attack_swing()
	await get_tree().create_timer(0.15).timeout
	_check(unit._model3d._anim.current_animation == unit._model3d._resolve_anim("attack"), "出招应播放专用骨骼动画")
	await get_tree().create_timer(0.7).timeout
	_check(unit._model3d.scale.is_equal_approx(Vector2.ONE) and is_zero_approx(unit._model3d.rotation), "出招后应恢复大小与角度")
	unit.play_cast()
	await get_tree().create_timer(0.1).timeout
	_check(unit._model3d.scale.x > 1.0, "施法反馈应作用于可见模型")
	await get_tree().create_timer(0.3).timeout
	await unit.play_hit(Vector2(1800, 2000))
	_check(is_zero_approx(unit._model3d.rotation), "受击后应回正")
	unit.set_defending(true)
	await get_tree().create_timer(0.2).timeout
	_check(unit._model3d.modulate.is_equal_approx(unit.DEFEND_TINT), "防御染色应作用于可见模型")
	unit.set_defending(false)
	unit._die()
	await get_tree().create_timer(0.6).timeout
	_check(absf(unit._model3d.rotation) > 1.0, "缺倒地剪辑时可见模型应倒地")
	unit.queue_free()
	await get_tree().process_frame

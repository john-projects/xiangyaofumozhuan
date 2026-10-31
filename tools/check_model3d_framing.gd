extends Node
## Render every action at multiple times/directions, checking transparent margins.
func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var window := get_tree().root
	window.size = Vector2i(1200, 500)
	window.content_scale_size = window.size
	window.content_scale_factor = 1.0
	var avatars: Array[Model3DAvatar] = []
	for i in 4:
		var av := Model3DAvatar.new()
		add_child(av)
		av.setup("res://assets/models/players/行修.glb", 210.0, true)
		av.position = Vector2(150 + i * 300, 390)
		av.face_dir(["up_left", "left", "down_right", "right"][i])
		if not OS.get_cmdline_user_args().has("--unarmed"):
			av.set_weapon(load("res://resources/items/equipment/weapon/item_weapon_02.tres"))
		av._anim.pause()
		avatars.append(av)
	await RenderingServer.frame_post_draw
	var failures := 0
	var min_margin := 9999
	for action in ["idle", "run", "attack", "cast"]:
		for sample in 40:
			for av in avatars:
				var clip := av._resolve_anim(action)
				av._anim.play(clip, 0.0)
				av._anim.seek(av._anim.get_animation(clip).length * sample / 40.0, true)
				av._anim.pause()
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			for av in avatars:
				var rect := av._viewport.get_texture().get_image().get_used_rect()
				var margin := mini(mini(rect.position.x, rect.position.y), mini(av.VIEW_W - rect.end.x, av.VIEW_H - rect.end.y))
				min_margin = mini(min_margin, margin)
				if margin < 3:
					failures += 1
					push_error("Clipped action=%s sample=%d rect=%s" % [action, sample, rect])
	for i in avatars.size():
		var av := avatars[i]
		var clip := av._resolve_anim("attack")
		av._anim.play(clip, 0.0)
		av._anim.seek(av._anim.get_animation(clip).length * (0.15 + i * 0.2), true)
		av._anim.pause()
		var label := Label.new()
		label.text = "攻击 · %d%%" % (15 + i * 20)
		label.position = Vector2(80 + i * 300, 435)
		add_child(label)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			window.get_texture().get_image().save_png(arg.trim_prefix("--output="))
		if arg.begins_with("--motion-dir="):
			var dir := arg.trim_prefix("--motion-dir=")
			DirAccess.make_dir_recursive_absolute(dir)
			for frame in 12:
				for av in avatars:
					var clip := av._resolve_anim("attack")
					av._anim.play(clip, 0.0)
					av._anim.seek(av._anim.get_animation(clip).length * frame / 12.0, true)
					av._anim.pause()
				await get_tree().process_frame
				await RenderingServer.frame_post_draw
				window.get_texture().get_image().save_png(dir.path_join("attack_%02d.png" % frame))
	print("[framing] samples=640 failures=%d minimum_margin=%d" % [failures, min_margin])
	get_tree().quit(0 if failures == 0 else 1)

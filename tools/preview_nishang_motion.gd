extends Node
## Compare the previous rig and rebuilt rig at identical times and view angles.
## -- --output=<absolute directory> saves a loop of PNGs and a contact sheet.

func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var out := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			out = arg.trim_prefix("--output=")
	if out.is_empty():
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out)
	var window := get_tree().root
	window.size = Vector2i(1200, 470)
	window.content_scale_size = window.size
	window.content_scale_factor = 1.0
	var avatars: Array[Model3DAvatar] = []
	for i in 4:
		var av := Model3DAvatar.new()
		add_child(av)
		var path := "res://assets/models/players/霓裳.glb" if i % 2 == 0 else "res://assets/models/nishang/nishang_rigged.glb"
		av.setup(path, 320.0)
		av.position = Vector2(150 + i * 300, 390)
		av.face_dir("down_right" if i < 2 else "up_left")
		av.play("idle", 0.0)
		av._anim.advance(0.0)
		av._anim.pause()
		avatars.append(av)
		var label := Label.new()
		label.text = ["旧版 · 正面", "新版 · 正面", "旧版 · 背面", "新版 · 背面"][i]
		label.position = av.position + Vector2(-75, 20)
		label.add_theme_font_size_override("font_size", 22)
		add_child(label)
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var sheet := Image.create(1200, 470 * 4, false, Image.FORMAT_RGBA8)
	for frame in 24:
		for av in avatars:
			var clip := av._resolve_anim("run")
			var duration := av._anim.get_animation(clip).length
			av._anim.play(clip, 0.0)
			av._anim.seek(duration * frame / 24.0, true)
			av._anim.pause()
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := window.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		img.save_png(out.path_join("run_%02d.png" % frame))
		if frame % 6 == 0:
			sheet.blit_rect(img, Rect2i(0, 0, 1200, 470), Vector2i(0, frame / 6 * 470))
	sheet.save_png(out.path_join("run_contact_sheet.png"))
	print("[nishang-motion] saved ", out)
	get_tree().quit()

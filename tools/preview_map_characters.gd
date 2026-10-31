extends Node
## Render the actual world scene with both 3D party members for visual review.
func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var window := get_tree().root
	window.size = Vector2i(1280, 800)
	window.content_scale_size = Vector2i(1280, 800)
	window.content_scale_factor = 1.0
	var world := load("res://scenes/world/world_map.tscn").instantiate() as WorldMap
	var party: Array[UnitStats] = [load("res://resources/units/players/行修.tres"), load("res://resources/units/players/霓裳.tres")]
	world.deployed.assign(party)
	world.setup(load("res://resources/maps/map_taohuacun.tres"), party, "", false, {})
	add_child(world)
	world.set_process(false)
	# 在出生点南侧的道路查看落地效果，避开底图里的摊位。
	world.player.position += Vector2(0, 220)
	world._companions[0].position = world.player.position + Vector2(140, 40)
	if world._player_model3d != null:
		world._player_model3d.face_dir("down_right")
	elif world._player_anim != null:
		world._player_anim.play("idle", "down_right")
	var companion := world._companions[0].get_node_or_null("Model3D") as Model3DAvatar
	if companion != null:
		companion.face_dir("down_left")
	await get_tree().create_timer(0.8).timeout
	await RenderingServer.frame_post_draw
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			window.get_texture().get_image().save_png(arg.trim_prefix("--output="))
	print("[map-preview] party_height=", world._unit_height())
	get_tree().quit()

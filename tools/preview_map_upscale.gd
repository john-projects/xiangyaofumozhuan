extends Node
## Isolated A/B preview: no edits to the playable map, NPC positions or camera.
func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var variant := "sr"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--variant="):
			variant = arg.trim_prefix("--variant=")
	var source := "E:/dream/godot/各种UI图/map/01_桃花村-ai.png"
	if variant == "sr":
		source = ProjectSettings.globalize_path("res://output/upscale_taohuacun/01_桃花村-ai-4x.png")
	var image := Image.load_from_file(source)
	if image == null:
		get_tree().quit(1)
		return
	var original := load("res://resources/maps/map_taohuacun.tres") as MapData
	var test_map := original.duplicate() as MapData
	var world_size := Vector2(original.texture.get_size()) * original.map_scale
	test_map.texture = ImageTexture.create_from_image(image)
	test_map.map_scale = world_size.x / image.get_width()
	test_map.npcs = []
	test_map.portals = []
	test_map.props = []
	test_map.walk_mask = null
	test_map.spawn_point = Vector2(0.50, 0.48)
	var window := get_tree().root
	window.size = Vector2i(1280, 800)
	window.content_scale_size = Vector2i(1280, 800)
	window.content_scale_factor = 1.0
	var world := load("res://scenes/world/world_map.tscn").instantiate() as WorldMap
	var party: Array[UnitStats] = [load("res://resources/units/players/行修.tres")]
	world.deployed.assign(party)
	world.setup(test_map, party, "", false, {})
	add_child(world)
	world.set_process(false)
	# Standalone previews have no character-selection session.
	world.player_sprite.texture = party[0].icon
	world.player_sprite.visible = true
	world.player_sprite.scale = Vector2.ONE * (test_map.unit_height / party[0].icon.get_height())
	world._anchor_sprite_feet(world.player_sprite)
	world.player_fallback.visible = false
	world.camera.position_smoothing_enabled = false
	world.camera.reset_smoothing()
	assert(world._map_size.is_equal_approx(world_size), "Upscale changed map dimensions")
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	var output := "res://output/upscale_taohuacun/game_" + variant + ".png"
	window.get_texture().get_image().save_png(ProjectSettings.globalize_path(output))
	print("[map-upscale] ", variant, " texture=", image.get_size(), " map_scale=", test_map.map_scale, " world_size=", world._map_size)
	get_tree().quit()

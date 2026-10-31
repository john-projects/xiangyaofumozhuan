extends Node
## Review the real battle layout without starting turn execution.
func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var window := get_tree().root
	window.size = Vector2i(1440, 900)
	var battle := load("res://scenes/battle/battle.tscn").instantiate() as Battle
	battle.auto_start_demo = false
	var map := load("res://resources/maps/map_taohuacun.tres") as MapData
	battle.set_backdrop(map.texture)
	add_child(battle)
	var players: Array[UnitStats] = []
	for who in ["行修", "厉狂澜", "夜魑", "陆孤鸣", "霓裳"]:
		var stats := load("res://resources/units/players/%s.tres" % who).duplicate() as UnitStats
		stats.health = 90.0
		stats.mana = 50.0
		players.append(stats)
	var enemies: Array[UnitStats] = []
	for who in ["八爪鱼", "蟹怪", "八爪鱼", "蟹怪"]:
		var stats := load("res://resources/units/enemies/%s.tres" % who).duplicate() as UnitStats
		stats.health = 90.0
		enemies.append(stats)
	battle._players = battle._spawn_team(players, battle.player_slots, true)
	battle._enemies = battle._spawn_team(enemies, battle.enemy_slots, false)
	battle._players[0].set_selected(true)
	for unit in battle._players:
		assert(is_equal_approx(unit.body_center_offset, -105.0))
		assert(is_equal_approx(unit.click_area.scale.x, 0.875))
	battle.turn_order.update_order(battle._players + battle._enemies)
	await get_tree().create_timer(0.8).timeout
	await RenderingServer.frame_post_draw
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			window.get_texture().get_image().save_png(arg.trim_prefix("--output="))
	print("[battle-preview] display, plates and click bounds verified")
	get_tree().quit()

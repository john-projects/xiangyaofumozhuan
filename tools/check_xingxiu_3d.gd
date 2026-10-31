extends Node
## Godot --headless --path . res://tools/check_xingxiu_3d.tscn
## 有渲染窗口时可附加 -- --preview=<绝对 PNG 路径>，输出换剑与跑步对照图。

var failures := 0
@onready var root: Window = get_tree().root


func _ready() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1


func _run() -> void:
	var character := load("res://resources/units/players/行修.tres") as UnitStats
	_check(not character.model_glb.is_empty(), "行修必须启用 3D 模型")
	var stage := Node2D.new()
	root.add_child(stage)
	root.size = Vector2i(1000, 620)
	root.content_scale_size = Vector2i(1000, 620)
	root.content_scale_factor = 1.0
	var avatars: Array[Model3DAvatar] = []
	var weapons: Array[ItemEquipment] = [
		load("res://resources/items/equipment/weapon/item_weapon_01.tres"),
		load("res://resources/items/equipment/weapon/item_weapon_02.tres"),
	]
	for i in 3:
		var avatar := Model3DAvatar.new()
		stage.add_child(avatar)
		_check(avatar.setup(character.model_glb, 340.0), "3D 模型应成功加载")
		avatar.position = Vector2(170 + i * 330, 510)
		avatar.face_dir("down_right" if i != 2 else "up_left")
		avatar.set_weapon(weapons[i % 2])
		_check(avatar._weapon_socket != null, "应找到右手骨骼")
		_check(avatar._weapon != null, "应实例化武器外观")
		_check(not avatar._resolve_anim("idle").is_empty(), "应有站立动画")
		_check(not avatar._resolve_anim("run").is_empty(), "应有跑步动画")
		if i == 0:
			avatar.set_weapon(weapons[1])
			_check(avatar._weapon.name == "IronSword", "换剑应替换为精铁剑")
			avatar.set_weapon(null)
			_check(avatar._weapon == null, "卸下武器应清除外观")
			avatar.set_weapon(weapons[0])
		avatar.play("run" if i == 2 else "idle", 0.0)
		var clip := avatar._anim.current_animation
		_check(avatar._anim.get_animation(clip).loop_mode == Animation.LOOP_LINEAR, "站立和跑步必须循环")
		avatar._anim.advance(0.3)
		avatars.append(avatar)
		var label := Label.new()
		label.text = ["木剑 · 站立", "精铁剑 · 站立", "木剑 · 背面跑步"][i]
		label.position = Vector2(avatar.position.x - 100, 550)
		label.add_theme_font_size_override("font_size", 24)
		stage.add_child(label)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	# 连续动作不应被上一动作的回 idle 计时器打断。
	var probe := avatars[0]
	var duration := probe.play_once("attack", 0.0)
	var skeleton := probe._weapon_socket.get_parent() as Skeleton3D
	var arm_index := skeleton.find_bone("mixamorig_RightArm")
	var hand_index := skeleton.find_bone("mixamorig_RightHand")
	probe._anim.seek(0.0, true)
	probe._anim.advance(0.0)
	var arm_before := skeleton.get_bone_pose_rotation(arm_index)
	var hand_before := skeleton.get_bone_global_pose(hand_index).origin
	probe._anim.seek(duration * 0.44, true)
	probe._anim.advance(0.0)
	var hand_travel := hand_before.distance_to(skeleton.get_bone_global_pose(hand_index).origin)
	_check(arm_before.angle_to(skeleton.get_bone_pose_rotation(arm_index)) > 1.0, "出招应有清楚的手臂旋转")
	_check(hand_travel > 0.15, "手部应有足够位移，在游戏尺寸下能读出攻击")
	print("[attack-motion] hand_travel=", hand_travel)
	_check(duration > 0.0, "应有攻击动画")
	_check(is_equal_approx(duration, 0.48), "行修普攻应为 0.48 秒短动作")
	_check(is_equal_approx(probe._anim.get_animation(probe._resolve_anim("cast")).length, 0.48), "行修施法应为 0.48 秒")
	probe.play("run", 0.0)
	await get_tree().create_timer(duration + 0.1).timeout
	_check(probe._anim.current_animation == probe._resolve_anim("run"), "旧攻击回调不应打断新的跑步")
	probe.play("idle", 0.0)
	await _check_equipment_flow(character, weapons)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--preview="):
			for i in avatars.size():
				avatars[i].play("run" if i == 2 else "idle", 0.0)
				avatars[i]._anim.seek(0.25 if i == 2 else 0.5, true)
				avatars[i]._anim.pause()
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var result := root.get_texture().get_image().save_png(arg.trim_prefix("--preview="))
			_check(result == OK, "预览 PNG 应成功保存")
	print("[xingxiu-3d] failures=%d" % failures)
	stage.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if failures == 0 else 1)


func _check_equipment_flow(character: UnitStats, weapons: Array[ItemEquipment]) -> void:
	root.get_node("Global").equipped_weapons.assign(weapons)
	_check(GameRoot.equip_item(character, weapons[0]).is_empty(), "应能通过装备流程穿上木剑")
	# 战斗副本不能以自己的 resource_path 查装备，要保留原角色的外观快照。
	var game := GameRoot.new()
	game.deployed.assign([character])
	var team := game._make_player_team()
	_check(team[0].weapon_visual == weapons[0], "战斗副本应带入原角色的武器")
	var unit := load("res://scenes/battle/battle_unit.tscn").instantiate() as BattleUnit
	root.add_child(unit)
	unit.setup(team[0], true)
	_check(unit._model3d != null and not unit.sprite.visible, "战斗应使用 3D 外观")
	_check(unit._model3d._weapon != null, "战斗应显示已装备的剑")
	unit.position = Vector2(2000, 2000)
	var target := load("res://scenes/battle/battle_unit.tscn").instantiate() as BattleUnit
	root.add_child(target)
	var enemy := UnitStats.new()
	enemy.name = "测试目标"
	enemy.icon = character.icon
	target.setup(enemy, false)
	target.position = Vector2(1600, 1900)
	var home := unit.position
	var original_z := unit.z_index
	await unit.attack_approach(target)
	_check(is_equal_approx(unit.position.y, target.position.y), "冲刺应到达目标所在横线")
	var impact_count := [0]
	var impact_elapsed := [0]
	var started := Time.get_ticks_msec()
	await unit.attack_swing(func() -> void:
		impact_count[0] += 1
		impact_elapsed[0] = Time.get_ticks_msec() - started)
	_check(impact_count[0] == 1, "普攻应只触发一次伤害回调")
	_check(impact_elapsed[0] >= 100 and impact_elapsed[0] < 330, "伤害应在挥击中段触发")
	await unit.attack_return(home)
	_check(unit.position.is_equal_approx(home) and unit.z_index == original_z, "归位应恢复位置和层级")
	_check(unit._model3d._anim.current_animation == unit._model3d._resolve_anim("idle"), "归位后应回站立动画")
	unit.queue_free()
	target.queue_free()
	# 不进完整地图也能验证地图外观更新接口，覆盖队长和跟随队友两条路径。
	var world := load("res://scenes/world/world_map.tscn").instantiate() as WorldMap
	world.deployed.assign([character])
	var companion := Node2D.new()
	companion.set_meta("character", character)
	world.add_child(companion)
	var avatar := Model3DAvatar.new()
	avatar.name = "Model3D"
	companion.add_child(avatar)
	root.add_child(world)
	world.set_process(false)
	avatar.setup(character.model_glb)
	world._player_model3d = avatar
	world._companions.append(companion)
	world._refresh_weapon_visuals()
	_check(avatar._weapon.name == "WoodenSword", "地图应显示已装备的木剑")
	_check(GameRoot.equip_item(character, weapons[1]).is_empty(), "应能切换精铁剑")
	world.notify_bag_changed()
	_check(avatar._weapon.name == "IronSword", "背包换剑应立即更新地图外观")
	_check(GameRoot.unequip_slot(character, ItemBase.EquipType.WEAPON).is_empty(), "应能卸下武器")
	world.notify_bag_changed()
	_check(avatar._weapon == null, "卸下武器应同步移除地图外观")
	world.queue_free()
	game.free()
	await get_tree().process_frame

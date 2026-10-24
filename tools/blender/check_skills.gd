extends SceneTree
## 检查三个太虚剑宗技能的特效挂载是否正确。

func _initialize() -> void:
	var paths := [
		"res://resources/skills/sect_skills/taixu/skill_sanchi_qingfeng.tres",
		"res://resources/skills/sect_skills/taixu/skill_taixu_shenjian.tres",
		"res://resources/skills/sect_skills/taixu/skill_renjian_heyi.tres",
	]
	for p in paths:
		var s = load(p)
		if s == null:
			print("[chk] 加载失败 ", p)
			continue
		print("[chk] %s  target=%s  screen=%s  burst_scale=%.1f  hits=%d" % [
			s.display_name,
			str(s.target_effect_scene.resource_path if s.target_effect_scene else "—"),
			str(s.screen_effect_scene.resource_path if s.screen_effect_scene else "—"),
			s.burst_scale, s.hits])
	quit()

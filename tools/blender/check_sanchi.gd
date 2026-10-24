extends SceneTree
## 临时：查三尺青锋在运行时的目标数为什么会变成 1。

func _initialize() -> void:
	var entry := {}
	for e in Global.sect_actives("taixu"):
		if String(e["id"]) == "sanchi_qingfeng":
			entry = e
	print("[chk] SECT_SKILLS 条目 targets = ", entry.get("targets", []))
	for lv in [1, 10, 29, 30, 50]:
		print("[chk] level=", lv, " → sect_skill_targets = ", Global.sect_skill_targets(entry, lv))

	var res: SkillData = Global.sect_skill_resource("sanchi_qingfeng")
	if res == null:
		print("[chk] 资源加载失败")
		quit()
		return
	print("[chk] 资源 max_targets = ", res.max_targets, "  target_mode = ", res.target_mode,
			"  hit_effect = ", str(res.target_effect_scene))
	var baked: SkillData = res.duplicate()
	var t := Global.sect_skill_targets(entry, 1)
	baked.max_targets = t if t > 0 else 1
	print("[chk] 烤完后 max_targets = ", baked.max_targets)
	quit()

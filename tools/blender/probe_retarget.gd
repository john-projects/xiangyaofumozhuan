extends SceneTree
## 打印 Godot 里重定向相关类的 API，确认怎么用。

func _initialize() -> void:
	for cls in ["RetargetModifier3D", "SkeletonProfileHumanoid", "BoneMap", "SkeletonProfile"]:
		print("=== ", cls, " ===")
		if not ClassDB.class_exists(cls):
			print("  (不存在)")
			continue
		var props := []
		for p in ClassDB.class_get_property_list(cls):
			if p.usage & PROPERTY_USAGE_EDITOR:
				props.append("%s:%s" % [p.name, type_string(p.type)])
		print("  属性: ", props)
		var methods := []
		for m in ClassDB.class_get_method_list(cls):
			if not m.name.begins_with("_"):
				methods.append(m.name)
		print("  方法: ", methods)
	quit()

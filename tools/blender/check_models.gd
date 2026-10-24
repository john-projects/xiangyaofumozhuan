extends SceneTree
## 检查 5 个角色 GLB 在 Godot 里的结构：骨骼数、动画名、是否蒙皮。

const MODELS := [
	"res://assets/models/players/厉狂澜.glb",
	"res://assets/models/players/夜魑.glb",
	"res://assets/models/players/燕如意.glb",
	"res://assets/models/players/霓裳.glb",
	"res://assets/models/players/陆孤鸣.glb",
	"res://assets/models/players/行修.glb",
]


func _initialize() -> void:
	for path in MODELS:
		var fname: String = path.get_file()
		if not ResourceLoader.exists(path):
			print("[chk] %s 不存在" % fname)
			continue
		var ps: PackedScene = load(path)
		var root: Node = ps.instantiate()
		var skel := _find(root, "Skeleton3D")
		var anim := _find(root, "AnimationPlayer")
		var mesh := _find(root, "MeshInstance3D")
		var anims: Array = []
		if anim != null:
			anims = anim.get_animation_list()
		print("[chk] %s 骨骼=%d 动画=%s 蒙皮=%s" % [
			fname,
			skel.get_bone_count() if skel else 0,
			str(anims),
			str(mesh != null and mesh.skin != null)])
		if skel != null and skel.get_bone_count() > 0:
			print("[chk]    前 3 骨骼: %s" % str([
				skel.get_bone_name(0), skel.get_bone_name(1), skel.get_bone_name(2)]))
		root.free()
	quit()


func _find(node: Node, cls: String) -> Node:
	if node.is_class(cls):
		return node
	for c in node.get_children():
		var r := _find(c, cls)
		if r:
			return r
	return null

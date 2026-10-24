extends SceneTree
## 检查 5 个角色的动画列表。

const MODELS := ["厉狂澜", "夜魑", "燕如意", "霓裳", "陆孤鸣", "行修"]


func _initialize() -> void:
	for m in MODELS:
		var path := "res://assets/models/players/%s.glb" % m
		if not ResourceLoader.exists(path):
			print("[chk] %s 不存在" % m)
			continue
		var root: Node = load(path).instantiate()
		var anim := _find(root, "AnimationPlayer") as AnimationPlayer
		var names := []
		if anim != null:
			names = anim.get_animation_list()
		print("[chk] %s 动画=%s" % [m, str(names)])
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

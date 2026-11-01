extends Node2D
## 2D 骨骼角色（剪纸动画）：Skeleton2D + Bone2D 搭骨架，每个部件一张 Sprite2D 挂在骨头上。
##
## 为什么用 Bone2D + Sprite2D 而不是 Polygon2D 蒙皮：
##   Q 版立绘是硬边色块，**不需要形变**；剪纸动画足够，而且不用描权重，改姿势只转骨头。
##
## 坐标：原点在**脚底**，y 向上为负（和 WorldMap / BattleUnit 的脚底锚定一致）。
## 关节高度按全身立绘（403×670）逐行量出来的，见 rig_preview2.py。
##
## 用法：
##   var rig := UNIT_RIG_SCENE.instantiate()
##   rig.setup("陆孤鸣")          # 部件目录 assets/sprites/units/players/parts/<名字>/
##   rig.play_idle()              # 呼吸
##   rig.play_attack()            # 挥一下

const PARTS_ROOT := "res://assets/sprites/units/players/parts/"
const H := 670.0

## 关节 y（相对脚底，向上为负）
const JOINT := {
	"foot": 0.0, "knee": -60.0, "hip": -130.0, "waist": -190.0,
	"chest": -280.0, "neck": -380.0, "head": -450.0,
	"shoulder": -350.0, "elbow": -250.0, "hand": -170.0,
}
const SHOULDER_DX := 72.0

## 部件配置：名字 → [文件, 缩放, 锚点x, 锚点y, 挂在哪个关节, dx, dy, 层级]
## 锚点 (0,0)=左上，(1,1)=右下；Sprite2D 用 centered=false 后按左上角摆。
const RIG := {
	"skirt":    ["skirt_front", 0.85, 0.5, 0.0, "spine", 0.0, 6.0, 10],
	"boot_l":   ["boot_1", 0.90, 0.5, 1.0, "leg_l", -39.0, 0.0, 5],
	"boot_r":   ["boot_2", 0.90, 0.5, 1.0, "leg_r", 39.0, 0.0, 5],
	"body":     ["robe_front", 0.78, 0.5, 0.0, "chest", 0.0, 0.0, 20],
	"arm_l_up": ["sleeve_a", 0.90, 0.5, 0.0, "arm_l", 0.0, -10.0, 15],
	"arm_r_up": ["sleeve_a", 0.90, 0.5, 0.0, "arm_r", 0.0, -10.0, 15],
	"arm_l_lo": ["forearm_a", 0.85, 0.5, 0.0, "fore_l", 0.0, 4.0, 16],
	"arm_r_lo": ["forearm_b", 0.85, 0.5, 0.0, "fore_r", 0.0, 4.0, 16],
	"head":     ["face_1", 1.50, 0.5, 0.5, "head", 0.0, 0.0, 30],
}

## 肢体拓扑：每根骨头 → (父骨, 关节名, x 偏移)
const BONES := [
	["hip",   "",       "hip",      0.0],
	["spine", "hip",    "waist",    0.0],
	["chest", "spine",  "chest",    0.0],
	["neck",  "chest",  "neck",     0.0],
	["head",  "neck",   "head",     0.0],
	["arm_l",  "chest", "shoulder", -SHOULDER_DX],
	["fore_l", "arm_l", "elbow",    -SHOULDER_DX],
	["arm_r",  "chest", "shoulder",  SHOULDER_DX],
	["fore_r", "arm_r", "elbow",     SHOULDER_DX],
	["leg_l",  "hip",   "hip",      -39.0],
	["leg_r",  "hip",   "hip",       39.0],
]

var character_name := ""
var _bones: Dictionary = {}
var _sprites: Dictionary = {}
var _idle_t := 0.0
var _idling := true


## 建骨架 + 挂部件。部件目录不存在时只留空节点，不报错。
func setup(name: String) -> void:
	character_name = name
	for b in BONES:
		var bname: String = b[0]
		var parent_name: String = b[1]
		var joint: String = b[2]
		var dx: float = b[3]
		var bone := Bone2D.new()
		bone.name = bname
		var parent_node: Node = _bones[parent_name] if parent_name != "" else null
		if parent_node == null:
			var skel := Skeleton2D.new()
			skel.name = "Skeleton"
			add_child(skel)
			skel.add_child(bone)
			bone.position = Vector2(0, JOINT["hip"])
		else:
			# 相对父骨定位：父骨在关节 joint_parent，本骨在自己的 joint
			parent_node.add_child(bone)
			var pj: String = ""
			for pb in BONES:
				if pb[0] == parent_name:
					pj = pb[2]
			bone.position = Vector2(dx - _dx_of(parent_name), JOINT[joint] - JOINT[pj])
		_bones[bname] = bone

	for key in RIG:
		var cfg: Array = RIG[key]
		_make_sprite(key, cfg)


func _dx_of(bone_name: String) -> float:
	for b in BONES:
		if b[0] == bone_name:
			return b[3]
	return 0.0


func _make_sprite(key: String, cfg: Array) -> void:
	var fname: String = cfg[0]
	var scale_v: float = cfg[1]
	var ax: float = cfg[2]
	var ay: float = cfg[3]
	var bone_name: String = cfg[4]
	var dx: float = cfg[5]
	var dy: float = cfg[6]
	var z: int = cfg[7]

	var path := PARTS_ROOT + character_name + "/" + fname + ".png"
	if not ResourceLoader.exists(path):
		return
	var spr := Sprite2D.new()
	spr.name = key
	spr.texture = load(path)
	spr.centered = false
	spr.scale = Vector2.ONE * scale_v
	spr.z_index = z
	# 挂到对应关节的骨头上：骨头的局部原点在关节处，这里把精灵按锚点摆过去
	var host: Node2D = _bones.get(bone_name, _bones["hip"])
	host.add_child(spr)
	var size := spr.texture.get_size() * scale_v
	spr.position = Vector2(dx - size.x * ax, dy - size.y * ay)
	_sprites[key] = spr



## 呼吸：躯干轻微上下 + 头部反向补偿，避免"整条人整体上下平移"的僵硬感。
func play_idle() -> void:
	_idling = true


func _process(delta: float) -> void:
	if not _idling or _bones.is_empty():
		return
	_idle_t += delta
	var s := sin(_idle_t * 2.2)
	if _bones.has("spine"):
		_bones["spine"].position.y = JOINT["waist"] - JOINT["hip"] + s * 1.6
	if _bones.has("head"):
		_bones["head"].rotation = sin(_idle_t * 1.7) * 0.02
	if _bones.has("arm_l"):
		_bones["arm_l"].rotation = 0.06 + s * 0.02
	if _bones.has("arm_r"):
		_bones["arm_r"].rotation = -0.06 - s * 0.02

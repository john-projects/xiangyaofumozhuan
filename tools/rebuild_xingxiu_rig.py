"""Rebuild Xingxiu's production rig, skin weights and four game actions in Blender.

Run from the project root:
  blender --background --factory-startup --python tools/rebuild_xingxiu_rig.py

The source GLB is intentionally the original unrigged mesh.  Blender's bone-heat
weights are generated from this new anatomical rig; no previous skeleton/weights
are read or reused.
"""
import bpy
import bmesh
import math
import os
from mathutils import Matrix, Vector

# Re-running the deterministic build should not leave Blender's .blend1 backups.
bpy.context.preferences.filepaths.save_version = 0

SOURCE = r"E:/dream/godot/各种UI图/players/行修.glb"
OUTPUT = r"E:/dream/godot/xiangyaofumozhuan/assets/models/xingxiu/xingxiu_rigged.glb"
AUTHORING = r"E:/dream/godot/xiangyaofumozhuan/assets/models/xingxiu/xingxiu_rigged.blend"
FPS = 30

if not os.path.isfile(SOURCE):
	raise FileNotFoundError(SOURCE)

# Start with the original static model so old armatures, weights and animations
# cannot leak into the rebuilt asset.
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=SOURCE)
mesh = next(obj for obj in bpy.context.scene.objects if obj.type == "MESH")
for obj in list(bpy.context.scene.objects):
	if obj != mesh:
		bpy.data.objects.remove(obj, do_unlink=True)
mesh.name = "Xingxiu_Mesh"
mesh.data.name = "Xingxiu_Body"
mesh.parent = None
mesh_transform = mesh.matrix_world.copy()
source_to_blender = mesh_transform @ Matrix.Rotation(math.pi / 2, 4, "X")

# The source is upright on Y, with the face toward +Z.  Each entry defines the
# visible joint locations in the source mesh's bind pose.  Twist bones split long
# sleeves/limbs into short sections so elbows, wrists, knees and ankles deform
# without hinging the entire limb at one point.
specs = {}
def bone(name, head, tail, parent=None, deform=True):
	specs[name] = {
		"head": tuple(source_to_blender @ Vector(head)),
		"tail": tuple(source_to_blender @ Vector(tail)),
		"parent": parent,
		"deform": deform,
	}

bone("root", (0, -0.96, 0), (0, -0.06, 0), deform=False)
bone("hips", (0, -0.06, 0), (0, 0.10, 0), "root")
bone("spine_01", (0, 0.10, 0), (0, 0.27, 0), "hips")
bone("spine_02", (0, 0.27, 0), (0, 0.43, 0), "spine_01")
bone("spine_03", (0, 0.43, 0), (0, 0.58, 0), "spine_02")
bone("neck", (0, 0.58, 0), (0, 0.70, 0), "spine_03")
bone("head", (0, 0.70, 0), (0, 0.93, 0), "neck")

for side, sign in (("L", 1), ("R", -1)):
	# The source character is modeled in an arms-out pose; shoulder, elbow and
	# wrist centers therefore stay on the same horizontal bind-pose line.
	bone(f"clavicle_{side}", (sign * 0.04, 0.52, 0), (sign * 0.18, 0.52, 0), "spine_03")
	bone(f"upperarm_{side}", (sign * 0.18, 0.52, 0), (sign * 0.31, 0.52, 0), f"clavicle_{side}")
	bone(f"upperarm_twist_{side}", (sign * 0.31, 0.52, 0), (sign * 0.40, 0.52, 0), f"upperarm_{side}")
	bone(f"forearm_{side}", (sign * 0.40, 0.52, 0), (sign * 0.48, 0.52, 0), f"upperarm_twist_{side}")
	bone(f"forearm_twist_{side}", (sign * 0.48, 0.52, 0), (sign * 0.54, 0.52, 0), f"forearm_{side}")
	bone(f"hand_{side}", (sign * 0.54, 0.52, 0), (sign * 0.58, 0.52, 0.02), f"forearm_twist_{side}")
	# Fine finger controls follow the small hands without letting the whole sleeve bend.
	for finger, vertical, depth, length in (("thumb", 0.035, -0.025, 0.075), ("index", 0.025, 0.035, 0.105), ("middle", 0.005, 0.055, 0.115), ("ring", -0.018, 0.035, 0.105), ("pinky", -0.040, 0.012, 0.085)):
		start = (sign * 0.575, 0.52 + vertical, depth)
		end = (sign * (0.575 + length), 0.52 + vertical, depth + 0.005)
		bone(f"{finger}_{side}", start, end, f"hand_{side}")

for side, sign in (("L", 1), ("R", -1)):
	bone(f"thigh_{side}", (sign * 0.105, -0.08, 0), (sign * 0.105, -0.28, 0), "hips")
	bone(f"thigh_twist_{side}", (sign * 0.105, -0.28, 0), (sign * 0.105, -0.47, 0), f"thigh_{side}")
	bone(f"shin_{side}", (sign * 0.105, -0.47, 0), (sign * 0.105, -0.67, 0), f"thigh_twist_{side}")
	bone(f"shin_twist_{side}", (sign * 0.105, -0.67, 0), (sign * 0.105, -0.84, 0), f"shin_{side}")
	bone(f"foot_{side}", (sign * 0.105, -0.84, 0), (sign * 0.105, -0.91, 0.12), f"shin_twist_{side}")
	bone(f"toe_{side}", (sign * 0.105, -0.91, 0.12), (sign * 0.105, -0.92, 0.25), f"foot_{side}")

arm_data = bpy.data.armatures.new("Xingxiu_AnatomicalRig")
armature = bpy.data.objects.new("Xingxiu_Rig", arm_data)
bpy.context.collection.objects.link(armature)
bpy.context.view_layer.objects.active = armature
armature.select_set(True)
mesh.select_set(False)
bpy.ops.object.mode_set(mode="EDIT")
edit_bones = {}
for name, data in specs.items():
	edit = arm_data.edit_bones.new(name)
	edit.head = data["head"]
	edit.tail = data["tail"]
	edit.use_deform = data["deform"]
	edit_bones[name] = edit
for name, data in specs.items():
	if data["parent"]:
		edit_bones[name].parent = edit_bones[data["parent"]]
		edit_bones[name].use_connect = (edit_bones[name].head - edit_bones[data["parent"]].tail).length < 1e-5
	# Keep local Z aimed toward the character's true front. glTF Y-up is imported
	# by Blender as Z-up, so source +Z (front) becomes Blender -Y.
	try:
		front = source_to_blender.to_3x3() @ Vector((0, 0, 1))
		edit_bones[name].align_roll(front)
	except Exception:
		pass
bpy.ops.object.mode_set(mode="OBJECT")

# The source contains open, floating cloth ribbons, so Blender's bone-heat
# solver cannot solve every disconnected shell. Build normalized smooth weights
# from capsule distances and anatomical regions instead. Region gates prevent
# nearby but unrelated bones (for example, arms and torso) from competing.
import numpy as np

mesh.data.transform(mesh_transform)
mesh.matrix_world.identity()
flat_positions = np.empty(len(mesh.data.vertices) * 3, dtype=np.float32)
mesh.data.vertices.foreach_get("co", flat_positions)
positions = flat_positions.reshape((-1, 3)).astype(np.float32)
origin = source_to_blender @ Vector((0, 0, 0))
relative_positions = positions - np.asarray(origin, dtype=np.float32)
right_axis = np.asarray(source_to_blender.to_3x3() @ Vector((1, 0, 0)), dtype=np.float32)
up_axis = np.asarray(source_to_blender.to_3x3() @ Vector((0, 1, 0)), dtype=np.float32)
front_axis = np.asarray(source_to_blender.to_3x3() @ Vector((0, 0, 1)), dtype=np.float32)
xs = relative_positions @ right_axis
ys = relative_positions @ up_axis
zs = relative_positions @ front_axis
vertex_count = len(positions)

def ramp(values, low, high):
	u = np.clip((values - low) / (high - low), 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)

def window(values, low, high, fade=0.10):
	return ramp(values, low, low + fade) * (1.0 - ramp(values, high - fade, high))

def bone_region(name):
	if name == "root":
		return np.zeros(vertex_count, dtype=np.float32)
	if name == "hips":
		pelvis = window(ys, -0.56, 0.18, 0.14)
		# Keep the central robe with the hips, while leaving the large side sleeves
		# free to follow the arm chain instead of being dragged by the torso.
		robe = window(ys, -0.78, 0.12, 0.14) * ramp(np.abs(xs), 0.29, 0.44)
		return pelvis + 0.8 * robe
	if name.startswith("spine_"):
		limits = {"spine_01": (-0.08, 0.31), "spine_02": (0.18, 0.49), "spine_03": (0.37, 0.64)}[name]
		return window(ys, limits[0], limits[1], 0.14) * (1.0 - ramp(np.abs(xs), 0.34, 0.51))
	if name == "neck":
		return window(ys, 0.49, 0.76, 0.12) * (1.0 - ramp(np.abs(xs), 0.18, 0.34))
	if name == "head":
		return ramp(ys, 0.57, 0.76) * (1.0 - ramp(np.abs(xs), 0.15, 0.32))
	side = 1.0 if name.endswith("_L") else -1.0 if name.endswith("_R") else 0.0
	if side and (name.startswith("clavicle_") or name.startswith("upperarm") or name.startswith("forearm") or name.startswith("hand_")):
		side_x = xs * side
		arm_height = window(ys, 0.06, 0.72, 0.12)
		if name.startswith("clavicle_"):
			return window(side_x, 0.07, 0.25, 0.06) * window(ys, 0.30, 0.64, 0.10)
		if name.startswith("upperarm"):
			return window(side_x, 0.16, 0.38, 0.09) * arm_height
		if name.startswith("forearm"):
			return window(side_x, 0.34, 0.56, 0.09) * arm_height
		if name.startswith("hand_"):
			return window(side_x, 0.52, 0.68, 0.07) * window(ys, 0.32, 0.68, 0.10)
	if side and any(name.startswith(prefix) for prefix in ("thigh_", "shin_", "foot_", "toe_")):
		side_gate = ramp(xs * side, 0.015, 0.17)
		if name.startswith("thigh_"):
			leg_gate = window(ys, -0.75, -0.48, 0.10)
		elif name.startswith("shin_"):
			leg_gate = window(ys, -0.91, -0.65, 0.10)
		elif name.startswith("foot_"):
			leg_gate = ramp(-ys, 0.76, 0.87) * (1.0 - ramp(-ys, 0.94, 0.98))
		else:
			leg_gate = ramp(-ys, 0.84, 0.91) * ramp(zs, -0.02, 0.12)
		# A broad outer robe follows the pelvis even when its surface lies over the legs.
		leg_gate *= 1.0 - 0.86 * ramp(np.abs(xs), 0.20, 0.39) * window(ys, -0.72, 0.10, 0.15)
		return side_gate * leg_gate
	if name.endswith("_L") or name.endswith("_R"):
		# Small digit bones only affect vertices at the end of the corresponding hand.
		return ramp(xs * side, 0.53, 0.61) * window(ys, 0.43, 0.62, 0.07) * ramp(zs, -0.05, 0.05)
	return np.zeros(vertex_count, dtype=np.float32)

def bone_radius(name):
	if name == "hips": return 0.26
	if name.startswith("spine_"): return 0.17
	if name in ("neck", "head"): return 0.14 if name == "neck" else 0.20
	if name.startswith("clavicle_"): return 0.13
	if name.startswith("upperarm"): return 0.13
	if name.startswith("forearm"): return 0.115
	if name.startswith("hand_"): return 0.10
	if any(name.startswith(prefix) for prefix in ("thumb_", "index_", "middle_", "ring_", "pinky_")): return 0.065
	if name.startswith("thigh"): return 0.145
	if name.startswith("shin"): return 0.125
	if name.startswith("foot_"): return 0.12
	return 0.09

weight_field = np.zeros((vertex_count, len(specs)), dtype=np.float32)
for bone_index, (name, data) in enumerate(specs.items()):
	region = bone_region(name)
	if not np.any(region > 0):
		continue
	start = np.asarray(data["head"], dtype=np.float32)
	end = np.asarray(data["tail"], dtype=np.float32)
	segment = end - start
	length_squared = float(np.dot(segment, segment))
	to_point = positions - start
	t = np.clip((to_point @ segment) / max(length_squared, 1e-8), 0.0, 1.0)
	closest = start + t[:, None] * segment
	distance_squared = np.sum((positions - closest) ** 2, axis=1)
	radius = bone_radius(name)
	strength = 5.0 if name.startswith(("upperarm", "forearm", "hand_", "thumb_", "index_", "middle_", "ring_", "pinky_")) else 1.6 if name.startswith("clavicle_") else 1.0
	weight_field[:, bone_index] = np.exp(-distance_squared / (2.0 * radius * radius)) * region * strength

# Give every point at least one valid influence. The hips are the safe fallback
# for decorative mesh fragments that sit outside the anatomical regions.
empty = np.max(weight_field, axis=1) < 1e-8
weight_field[empty, 1] = 1.0
top_indices = np.argpartition(weight_field, -4, axis=1)[:, -4:]
top_weights = np.take_along_axis(weight_field, top_indices, axis=1)
order = np.argsort(top_weights, axis=1)[:, ::-1]
top_indices = np.take_along_axis(top_indices, order, axis=1)
top_weights = np.take_along_axis(top_weights, order, axis=1)
top_weights /= np.maximum(top_weights.sum(axis=1, keepdims=True), 1e-8)
group_index_by_bone = {}
for bone_index, (name, data) in enumerate(specs.items()):
	if not data["deform"]:
		continue
	group = mesh.vertex_groups.new(name=name)
	group_index_by_bone[bone_index] = group.index
bm = bmesh.new()
bm.from_mesh(mesh.data)
deform_layer = bm.verts.layers.deform.verify()
for vertex_index, vertex in enumerate(bm.verts):
	deform = vertex[deform_layer]
	for slot in range(4):
		bone_index = int(top_indices[vertex_index, slot])
		group_index = group_index_by_bone.get(bone_index)
		weight = float(top_weights[vertex_index, slot])
		if group_index is not None and weight > 1e-5:
			deform[group_index] = weight
bm.to_mesh(mesh.data)
bm.free()
armature_modifier = mesh.modifiers.new("Xingxiu_Armature", "ARMATURE")
armature_modifier.object = armature
armature_modifier.use_deform_preserve_volume = True
mesh.parent = armature
mesh.matrix_parent_inverse = armature.matrix_world.inverted()

# Organize the editable rig into clean Blender bone collections.
collections = {
	"Core": {"root", "hips", "spine_01", "spine_02", "spine_03", "neck", "head"},
	"Arms": {name for name in specs if any(name.startswith(prefix) for prefix in ("clavicle_", "upperarm", "forearm", "hand_"))},
	"Hands": {name for name in specs if any(name.startswith(prefix) for prefix in ("thumb_", "index_", "middle_", "ring_", "pinky_"))},
	"Legs": {name for name in specs if any(name.startswith(prefix) for prefix in ("thigh", "shin", "foot_", "toe_"))},
}
for collection_name, names in collections.items():
	collection = arm_data.collections.new(collection_name)
	for name in names:
		collection.assign(arm_data.bones[name])
armature.show_in_front = True
arm_data.display_type = "OCTAHEDRAL"

# Keep animation curves deterministic: sample smooth motion at 30 fps and key
# every animated joint. Godot imports these actions by their exact names.
armature.animation_data_create()
armature.data.pose_position = "POSE"
for pose_bone in armature.pose.bones:
	pose_bone.rotation_mode = "XYZ"

def smooth_keys(keys, t):
	if t <= keys[0][0]:
		return keys[0][1]
	for index in range(1, len(keys)):
		if t <= keys[index][0]:
			t0, a = keys[index - 1]
			t1, b = keys[index]
			u = max(0.0, min(1.0, (t - t0) / (t1 - t0)))
			u = u * u * (3.0 - 2.0 * u)
			return tuple(a[i] + (b[i] - a[i]) * u for i in range(3))
	return keys[-1][1]

def blend_pose(cues, t):
	return {name: smooth_keys(keys, t) for name, keys in cues.items()}

def action_pose(name, t, duration):
	if name == "idle":
		phase = 2 * math.pi * t / duration
		breath, sway = math.sin(phase), math.sin(phase * 0.5)
		pose = {
			"spine_01": (0, 0.25 * sway, 0.15 * sway),
			"spine_02": (1.8 * breath, 0.3 * sway, 0),
			"spine_03": (1.1 * breath, 0, 0),
			"neck": (0, 0, 0), "head": (0, 0, 0),
			# Relax the source T-pose into a readable hands-down idle stance.
			"upperarm_L": (0.4 * breath, 0, -60 - 0.5 * sway),
			"upperarm_R": (0.4 * breath, 0, 60 + 0.5 * sway),
			"upperarm_twist_L": (0, 0, -10), "upperarm_twist_R": (0, 0, 10),
			"forearm_L": (0, 0, -12 - 0.2 * sway), "forearm_R": (0, 0, 12 + 0.2 * sway),
			"forearm_twist_L": (0, 0, -2), "forearm_twist_R": (0, 0, 2),
		}
		return pose, (0, 0.004 * math.sin(phase), 0)
	if name == "run":
		phase = 2 * math.pi * t / duration
		swing = math.sin(phase)
		pose = {
			"spine_01": (-6, 0, 0), "spine_02": (3, 0, 0), "spine_03": (2, 0, 0),
			"neck": (0, 0, 0), "head": (0, 0, 0),
			"thigh_L": (0, 0, 10 * swing), "thigh_R": (0, 0, -10 * swing),
			"thigh_twist_L": (0, 0, 2 * swing), "thigh_twist_R": (0, 0, -2 * swing),
			"shin_L": (0, 0, -18 * max(0, swing)), "shin_R": (0, 0, -18 * max(0, -swing)),
			"shin_twist_L": (0, 0, -4 * max(0, swing)), "shin_twist_R": (0, 0, -4 * max(0, -swing)),
			"foot_L": (0, 0, 6 * max(0, swing)), "foot_R": (0, 0, 6 * max(0, -swing)),
			"upperarm_L": (0, 0, -60 - 15 * swing), "upperarm_R": (0, 0, 60 + 15 * swing),
			"upperarm_twist_L": (0, 0, -10 - 4 * swing), "upperarm_twist_R": (0, 0, 10 + 4 * swing),
			"forearm_L": (0, 0, -12 - 15 * max(0, swing)), "forearm_R": (0, 0, 12 + 15 * max(0, -swing)),
			"forearm_twist_L": (0, 0, -3), "forearm_twist_R": (0, 0, 3),
		}
		return pose, (0, 0.006 * (0.5 - 0.5 * math.cos(2 * phase)), 0)
	if name == "attack":
		cues = {
			"spine_01": [(0,(0,0,0)),(.17,(-4,0,0)),(.43,(2,0,0)),(.61,(0,0,0)),(.78,(0,0,0))],
			"spine_02": [(0,(0,0,0)),(.17,(-5,-8,0)),(.43,(3,14,0)),(.61,(0,5,0)),(.78,(0,0,0))],
			"spine_03": [(0,(0,0,0)),(.17,(-3,-4,0)),(.43,(2,8,0)),(.61,(0,2,0)),(.78,(0,0,0))],
			"upperarm_R": [(0,(0,0,60)),(.17,(12,0,10)),(.43,(-24,0,-24)),(.61,(-12,0,20)),(.78,(0,0,60))],
			"upperarm_twist_R": [(0,(0,0,10)),(.17,(0,0,4)),(.43,(-5,0,-12)),(.61,(-3,0,7)),(.78,(0,0,10))],
			"forearm_R": [(0,(0,0,12)),(.17,(-12,0,0)),(.43,(-4,0,-18)),(.61,(-14,0,-8)),(.78,(0,0,12))],
			"forearm_twist_R": [(0,(0,0,3)),(.17,(0,0,3)),(.43,(0,0,-6)),(.61,(0,0,-2)),(.78,(0,0,3))],
			"clavicle_R": [(0,(0,0,0)),(.17,(0,0,-8)),(.43,(0,0,10)),(.61,(0,0,4)),(.78,(0,0,0))],
			"upperarm_L": [(0,(0,0,-60)),(.17,(-4,0,-50)),(.43,(8,0,-70)),(.61,(0,0,-63)),(.78,(0,0,-60))],
			"upperarm_twist_L": [(0,(0,0,-10)),(.17,(0,0,-8)),(.43,(0,0,-14)),(.61,(0,0,-11)),(.78,(0,0,-10))],
			"forearm_L": [(0,(0,0,-12)),(.17,(-10,0,-6)),(.43,(0,0,-18)),(.61,(-5,0,-12)),(.78,(0,0,-12))],
			"neck": [(0,(0,0,0)),(.17,(0,0,0)),(.43,(0,0,0)),(.61,(0,0,0)),(.78,(0,0,0))],
			"head": [(0,(0,0,0)),(.17,(0,0,0)),(.43,(0,0,0)),(.61,(0,0,0)),(.78,(0,0,0))],
		}
		return blend_pose(cues, t), (0, 0, 0)
	if name == "cast":
		cues = {
			"spine_01": [(0,(0,0,0)),(.23,(-4,0,0)),(.61,(-2,0,0)),(.79,(3,0,0)),(1.08,(0,0,0))],
			"spine_02": [(0,(0,0,0)),(.23,(-6,-2,0)),(.61,(-4,2,0)),(.79,(5,0,0)),(1.08,(0,0,0))],
			"spine_03": [(0,(0,0,0)),(.23,(-4,0,0)),(.61,(-2,0,0)),(.79,(4,0,0)),(1.08,(0,0,0))],
			"upperarm_L": [(0,(0,0,-60)),(.23,(0,0,-20)),(.61,(0,0,8)),(.79,(0,0,-24)),(1.08,(0,0,-60))],
			"upperarm_R": [(0,(0,0,60)),(.23,(0,0,20)),(.61,(0,0,-8)),(.79,(0,0,24)),(1.08,(0,0,60))],
			"upperarm_twist_L": [(0,(0,0,-10)),(.23,(0,0,-4)),(.61,(0,0,3)),(.79,(0,0,-5)),(1.08,(0,0,-10))],
			"upperarm_twist_R": [(0,(0,0,10)),(.23,(0,0,4)),(.61,(0,0,-3)),(.79,(0,0,5)),(1.08,(0,0,10))],
			"forearm_L": [(0,(0,0,-12)),(.23,(0,0,-25)),(.61,(0,0,-38)),(.79,(0,0,-18)),(1.08,(0,0,-12))],
			"forearm_R": [(0,(0,0,12)),(.23,(0,0,25)),(.61,(0,0,38)),(.79,(0,0,18)),(1.08,(0,0,12))],
			"clavicle_L": [(0,(0,0,0)),(.23,(0,0,-8)),(.61,(0,0,-5)),(.79,(0,0,6)),(1.08,(0,0,0))],
			"clavicle_R": [(0,(0,0,0)),(.23,(0,0,8)),(.61,(0,0,5)),(.79,(0,0,-6)),(1.08,(0,0,0))],
			"head": [(0,(0,0,0)),(.23,(0,0,0)),(.61,(0,0,0)),(.79,(0,0,0)),(1.08,(0,0,0))],
			"neck": [(0,(0,0,0)),(.23,(0,0,0)),(.61,(0,0,0)),(.79,(0,0,0)),(1.08,(0,0,0))],
		}
		return blend_pose(cues, t), (0, 0, 0)
	return {}, (0, 0, 0)

actions = [("idle", 3.2), ("run", 0.8), ("attack", 0.78), ("cast", 1.08)]
for name, duration in actions:
	if armature.animation_data.action:
		armature.animation_data.action = None
	action = bpy.data.actions.new(name)
	armature.animation_data.action = action
	frame_count = int(round(duration * FPS)) + 1
	animated_names = set()
	for sample in range(frame_count):
		t = duration * sample / (frame_count - 1)
		pose, hip_offset = action_pose(name, t, duration)
		frame = 1 + sample
		bpy.context.scene.frame_set(frame)
		# Every clip keys the full rig, so switching actions never carries a
		# previous clip's leg, hand, head or cloth pose into the next one.
		for bone_name, pose_bone in armature.pose.bones.items():
			degrees = pose.get(bone_name, (0, 0, 0))
			pose_bone.rotation_euler = tuple(math.radians(value) for value in degrees)
			pose_bone.keyframe_insert(data_path="rotation_euler", frame=frame, group=bone_name)
			if bone_name in pose:
				animated_names.add(bone_name)
		hips = armature.pose.bones["hips"]
		hips.location = hip_offset
		hips.keyframe_insert(data_path="location", frame=frame, group="hips")
	action.use_fake_user = True
	print("ACTION", name, "frames", frame_count, "bones", len(animated_names))

# Return to a neutral pose so both the saved .blend and GLB start correctly.
armature.animation_data.action = bpy.data.actions.get("idle")
bpy.context.scene.frame_set(1)
for pose_bone in armature.pose.bones:
	pose_bone.rotation_euler = (0, 0, 0)
	pose_bone.location = (0, 0, 0)

bpy.ops.wm.save_as_mainfile(filepath=AUTHORING)
bpy.ops.object.select_all(action="DESELECT")
mesh.select_set(True)
armature.select_set(True)
bpy.context.view_layer.objects.active = armature
bpy.ops.export_scene.gltf(
	filepath=OUTPUT,
	export_format="GLB",
	export_animations=True,
	export_animation_mode="ACTIONS",
	export_skins=True,
	export_materials="EXPORT",
	export_apply=False,
)
print("EXPORTED", OUTPUT, "bones", len(specs), "animations", [name for name, _ in actions])

import bpy
import math
from mathutils import Vector

MODEL = r"E:/dream/godot/xiangyaofumozhuan/assets/models/xingxiu/xingxiu_rigged.glb"
OUT = r"E:/dream/godot/xiangyaofumozhuan/tools"
BLEND = r"E:/dream/godot/xiangyaofumozhuan/assets/models/xingxiu/xingxiu_rigged.blend"

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.wm.open_mainfile(filepath=BLEND)
armature = next(obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE")
mesh = next(obj for obj in bpy.context.scene.objects if obj.type == "MESH")

scene = bpy.context.scene
scene.render.engine = "BLENDER_EEVEE"
scene.eevee.taa_render_samples = 32
scene.render.resolution_x = 512
scene.render.resolution_y = 768
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.film_transparent = False
scene.view_settings.view_transform = "AgX"
scene.world.color = (0.055, 0.07, 0.10)

camera_data = bpy.data.cameras.new("PreviewCamera")
camera = bpy.data.objects.new("PreviewCamera", camera_data)
scene.collection.objects.link(camera)
camera.location = (0, -4.5, 0)
camera.rotation_euler = (math.pi / 2, 0, 0)
camera_data.type = "ORTHO"
camera_data.ortho_scale = 2.18
scene.camera = camera

def area_light(name, location, power, color, size):
	data = bpy.data.lights.new(name, "AREA")
	data.energy = power
	data.color = color
	data.shape = "DISK"
	data.size = size
	obj = bpy.data.objects.new(name, data)
	scene.collection.objects.link(obj)
	obj.location = location
	obj.rotation_euler = (Vector((0, 0, 0)) - obj.location).to_track_quat("-Z", "Y").to_euler()

area_light("Key", (2.4, 2.0, 3.0), 850, (1.0, 0.86, 0.68), 3.2)
area_light("Fill", (-2.6, 0.4, 2.4), 620, (0.48, 0.68, 1.0), 3.5)
area_light("Rim", (0.0, 1.8, -2.0), 900, (0.55, 0.72, 1.0), 2.4)

renders = {"idle": 38, "run": 10, "attack": 10, "cast": 14}
for action_name, frame in renders.items():
	action = bpy.data.actions.get(action_name)
	if action is None:
		raise RuntimeError("Missing action: " + action_name)
	armature.animation_data_create()
	armature.animation_data.action = action
	scene.frame_set(frame)
	scene.render.filepath = f"{OUT}/preview_{action_name}.png"
	bpy.ops.render.render(write_still=True)
	print("RENDERED", action_name, frame, scene.render.filepath)

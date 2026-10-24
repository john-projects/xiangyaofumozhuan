# -*- coding: utf-8 -*-
"""pose_test.py —— 把骨架摆个姿势并渲染，检查蒙皮是否正常（有没有炸开/硬折）。

    blender -b --python pose_test.py -- --blend X.blend --out DIR
"""

from __future__ import annotations

import math
import os
import sys

import bpy
from mathutils import Euler, Vector


def main() -> None:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = {"blend": argv[0], "out": argv[1] if len(argv) > 1 else "."}
    bpy.ops.wm.open_mainfile(filepath=os.path.abspath(opts["blend"]))

    arm = next(o for o in bpy.context.scene.objects if o.type == "ARMATURE")
    mesh = next(o for o in bpy.context.scene.objects if o.type == "MESH")

    # 权重统计
    counts = {}
    for v in mesh.data.vertices:
        for g in v.groups:
            name = mesh.vertex_groups[g.group].name
            counts[name] = counts.get(name, 0) + 1
    print("[pose] 每个骨骼影响的顶点数：",
          {k: counts.get(k, 0) for k in sorted(counts)})

    # 摆姿势：抬右臂、抬左腿
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="POSE")
    pose = arm.pose.bones
    for name, rot in {
        "upper_arm.L": (0, 0, math.radians(-55)),
        "upper_leg.R": (math.radians(-35), 0, 0),
        "head": (0, 0, math.radians(12)),
    }.items():
        if name in pose:
            pose[name].rotation_mode = "XYZ"
            pose[name].rotation_euler = Euler(rot, "XYZ")
    bpy.ops.object.mode_set(mode="OBJECT")

    # 渲染正面
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 16
    scene.view_settings.view_transform = "Standard"

    if scene.world is None:
        scene.world = bpy.data.worlds.new("W")
    scene.world.use_nodes = True
    bg = next((n for n in scene.world.node_tree.nodes if n.type == "BACKGROUND"), None)
    if bg is not None:
        bg.inputs[0].default_value = (0.2, 0.22, 0.24, 1)
        bg.inputs[1].default_value = 0.9

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 3.0
    sun.rotation_euler = (math.radians(55), 0, math.radians(35))
    scene.collection.objects.link(sun)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 2.6
    cam_data.clip_end = 100
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.rotation_euler = Vector((0, -1, 0)).to_track_quat("Z", "Y").to_euler()
    cam.location = Vector((0, -6, 0))

    scene.render.resolution_x = 720
    scene.render.resolution_y = 960
    os.makedirs(opts["out"], exist_ok=True)
    scene.render.filepath = os.path.join(opts["out"], "posed.png")
    bpy.ops.render.render(write_still=True)
    print("[pose] 渲染完成", scene.render.filepath)


if __name__ == "__main__":
    main()

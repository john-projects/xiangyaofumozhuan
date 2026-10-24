# -*- coding: utf-8 -*-
"""inspect_model.py —— 导入一个 GLB，渲染正面/侧面正交视图，用于判断姿势和比例。

    blender -b --python inspect_model.py -- --glb path.glb --out DIR
"""

from __future__ import annotations

import math
import os
import sys

import bpy
from mathutils import Vector


def parse_args() -> dict:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = {"glb": "", "out": ""}
    i = 0
    while i < len(argv):
        if argv[i] in ("--glb", "--out"):
            opts[argv[i][2:]] = argv[i + 1]
            i += 1
        i += 1
    return opts


def bounds(objects):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for ob in objects:
        if ob.type != "MESH":
            continue
        for corner in ob.bound_box:
            w = ob.matrix_world @ Vector(corner)
            lo = Vector((min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z)))
            hi = Vector((max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z)))
    return lo, hi


def main() -> None:
    opts = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)

    bpy.ops.import_scene.gltf(filepath=os.path.abspath(opts["glb"]))
    objs = list(bpy.context.scene.objects)
    print("[inspect] 对象：", [(o.name, o.type) for o in objs])

    meshes = [o for o in objs if o.type == "MESH"]
    if not meshes:
        print("[inspect] 没有 mesh")
        return
    lo, hi = bounds(meshes)
    size = hi - lo
    print(f"[inspect] 包围盒 {tuple(round(v,3) for v in lo)} ~ {tuple(round(v,3) for v in hi)}")
    print(f"[inspect] 尺寸 X={size.x:.3f} Y={size.y:.3f} Z={size.z:.3f}")
    tris = sum(len(o.data.polygons) for o in meshes)
    print(f"[inspect] 面数 {tris}，材质 {len(bpy.data.materials)}")

    # 渲染两张正交图：正面(-Y 方向看)、侧面(+X 方向看)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 16
    scene.view_settings.view_transform = "Standard"

    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.22, 0.24, 0.26, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.9

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 3.0
    sun.rotation_euler = (math.radians(55), 0, math.radians(35))
    scene.collection.objects.link(sun)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = max(size.x, size.z) * 1.25
    cam_data.clip_end = max(size) * 20
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam

    center = (lo + hi) * 0.5
    dist = max(size) * 3

    os.makedirs(opts["out"], exist_ok=True)
    views = {
        "front": Vector((0, -1, 0)),
        "side": Vector((1, 0, 0)),
    }
    scene.render.resolution_x = 720
    scene.render.resolution_y = 960
    for name, d in views.items():
        cam.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
        cam.location = center + d * dist
        scene.render.filepath = os.path.join(opts["out"], f"{name}.png")
        bpy.ops.render.render(write_still=True)
        print(f"[inspect] 渲染 {name} -> {scene.render.filepath}")


if __name__ == "__main__":
    main()

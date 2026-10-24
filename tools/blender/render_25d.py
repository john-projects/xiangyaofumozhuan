# -*- coding: utf-8 -*-
"""render_25d.py —— Blender 端：把搭好的 3D 小村庄渲成"2.5D 分层素材"给 Godot 用。

用法（命令行，无界面）：
    blender.exe -b --python render_25d.py -- --demo --out out/demo
    blender.exe -b --python render_25d.py -- --scene my.blend --out out/taohuacun --res 4096x2304

它会输出：
    ground.png        地面层：只留地面/水/路，但**保留物件的投影**
    props/<name>.png  每个物件单独一张（透明背景，同一机位同一光照）
    mask.png          俯视黑白掩膜（白=可走，黑=阻挡），给 Godot 的 walk_mask
    preview.png       完整画面（验收用）
    meta.json         尺寸、俯角、每个物件的归一化坐标

约定（自己搭场景时照这个来）：
    · 地面/水/路：普通网格，名字随便，别用 prop_ 前缀；
    · 每个物件：一个 Empty 名字以 `prop_` 开头，模型作为它的子物体；
    · 物件原点放在**接地点**（脚下），meta.json 会按它算归一化坐标。
"""

from __future__ import annotations

import json
import math
import os
import sys

import bpy
from mathutils import Euler, Vector

# ── 参数 ──────────────────────────────────────────────────────────────────
def parse_args() -> dict:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = {
        "demo": False, "scene": "", "out": "", "res": "1024x576",
        "elevation": 30.0, "samples": 32, "preview": True,
    }
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--demo":
            opts["demo"] = True
        elif a in ("--scene", "--out", "--res", "--elevation", "--samples"):
            opts[a[2:]] = argv[i + 1]
            i += 1
        elif a == "--no-preview":
            opts["preview"] = False
        i += 1
    return opts


def log(msg: str) -> None:
    print(f"[render_25d] {msg}", flush=True)


# ── 场景工具 ──────────────────────────────────────────────────────────────
def new_material(name: str, color, roughness=0.9, emission=None):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = (*color, 1.0)
        bsdf.inputs["Roughness"].default_value = roughness
        if emission is not None:
            bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
            bsdf.inputs["Emission Strength"].default_value = 2.0
    return mat


def add_box(name, loc, size, color, parent=None, collection=None):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (size[0] / 2.0, size[1] / 2.0, size[2] / 2.0)
    obj.data.materials.append(new_material(name + "_mat", color))
    if parent is not None:
        obj.parent = parent
        obj.matrix_parent_inverse = parent.matrix_world.inverted()
    if collection is not None:
        move_to_collection(obj, collection)
    return obj


def add_cylinder(name, loc, radius, depth, color, parent=None, collection=None):
    bpy.ops.mesh.primitive_cylinder_add(vertices=16, radius=radius, depth=depth, location=loc)
    obj = bpy.context.active_object
    obj.name = name
    obj.data.materials.append(new_material(name + "_mat", color))
    if parent is not None:
        obj.parent = parent
        obj.matrix_parent_inverse = parent.matrix_world.inverted()
    if collection is not None:
        move_to_collection(obj, collection)
    return obj


def add_sphere(name, loc, radius, color, parent=None, collection=None):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=20, ring_count=12, radius=radius, location=loc)
    obj = bpy.context.active_object
    obj.name = name
    obj.data.materials.append(new_material(name + "_mat", color))
    if parent is not None:
        obj.parent = parent
        obj.matrix_parent_inverse = parent.matrix_world.inverted()
    if collection is not None:
        move_to_collection(obj, collection)
    return obj


def move_to_collection(obj, coll):
    for c in list(obj.users_collection):
        c.objects.unlink(obj)
    coll.objects.link(obj)


def make_prop(name: str, location, collection) -> bpy.types.Object:
    """一个物件 = 一个空物体（名字 prop_xxx），模型挂在它下面。"""
    empty = bpy.data.objects.new(f"prop_{name}", None)
    empty.empty_display_size = 0.5
    empty.location = location
    collection.objects.link(empty)
    return empty


# ── 演示村庄（没有资产时用来验证整条管线）───────────────────────────────
def build_demo():
    scene = bpy.context.scene
    props_coll = bpy.data.collections.new("Props")
    scene.collection.children.link(props_coll)

    ground = add_box("Ground", (0, 0, -0.5), (44, 34, 1.0), (0.44, 0.60, 0.36))
    add_box("River", (6.0, 0, -0.35), (4.0, 34, 0.5), (0.26, 0.50, 0.64))
    add_box("Road", (-2.0, 0, 0.02), (3.2, 34, 0.06), (0.72, 0.66, 0.52))

    # 两栋房子
    for i, (x, y, w, d, h) in enumerate([(-7.0, -6.0, 6.0, 5.0, 2.6), (-7.5, 4.0, 5.0, 4.2, 2.2)]):
        p = make_prop(f"house_{'ab'[i]}", (x, y, 0), props_coll)
        add_box(f"house_{i}_body", (x, y, h / 2), (w, d, h), (0.90, 0.87, 0.80), p, props_coll)
        add_box(f"house_{i}_roof", (x, y, h + 0.5), (w * 1.12, d * 1.12, 1.0), (0.24, 0.26, 0.30), p, props_coll)

    # 两棵树
    for i, (x, y) in enumerate([(-1.0, -8.0), (9.5, 6.0)]):
        p = make_prop(f"tree_{i}", (x, y, 0), props_coll)
        add_cylinder(f"tree_{i}_trunk", (x, y, 1.0), 0.18, 2.0, (0.33, 0.22, 0.14), p, props_coll)
        add_sphere(f"tree_{i}_leaf", (x, y, 2.8), 1.3, (0.28, 0.48, 0.26), p, props_coll)

    # 桥
    p = make_prop("bridge", (6.0, 2.5, 0), props_coll)
    add_box("bridge_deck", (6.0, 2.5, 0.12), (5.2, 2.6, 0.24), (0.55, 0.40, 0.26), p, props_coll)
    for side in (-1, 1):
        add_box(f"bridge_rail_{side}", (6.0, 2.5 + side * 1.2, 0.9),
                (5.2, 0.12, 0.12), (0.45, 0.32, 0.20), p, props_coll)

    # 灯笼
    for i, (x, y) in enumerate([(-3.6, -3.0), (-3.6, 1.5)]):
        p = make_prop(f"lantern_{i}", (x, y, 0), props_coll)
        add_cylinder(f"lantern_{i}_post", (x, y, 1.1), 0.07, 2.2, (0.28, 0.20, 0.14), p, props_coll)
        add_sphere(f"lantern_{i}_bulb", (x, y, 2.3), 0.22, (0.95, 0.35, 0.28),
                   p, props_coll).data.materials[-1] = new_material("lantern_glow", (0.95, 0.35, 0.28),
                                                                   emission=(1.0, 0.45, 0.3))
    log("演示村庄已生成")


# ── 灯光 / 世界 / 渲染设置 ────────────────────────────────────────────────
def setup_world_and_render(res_x, res_y, samples):
    scene = bpy.context.scene
    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.55, 0.62, 0.72, 1.0)
    bg.inputs[1].default_value = 0.55

    sun_data = bpy.data.lights.new("Sun", type="SUN")
    sun_data.energy = 3.2
    sun_data.angle = math.radians(2.0)
    sun = bpy.data.objects.new("Sun", sun_data)
    bpy.context.scene.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(50), 0.0, math.radians(-38))

    scene.render.engine = "CYCLES"
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.render.film_transparent = True
    scene.render.resolution_x = res_x
    scene.render.resolution_y = res_y
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.view_transform = "AgX" if "AgX" in [v.name for v in bpy.types.ColorManagedViewSettings.bl_rna.properties["view_transform"].enum_items] else "Filmic"


# ── 相机：正交 + 2.5D 角度 ───────────────────────────────────────────────
def setup_camera(elevation_deg: float, res_x: int, res_y: int,
                 objs) -> bpy.types.Object:
    scene = bpy.context.scene
    cam_data = bpy.data.cameras.new("Cam25D")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("Cam25D", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam

    # 俯角 θ：相机绕 X 旋转 90°-θ（Blender 相机的默认朝向是 -Z）
    # ⚠ 这里必须用 Euler 自己算方向：刚 new 出来的对象 matrix_world 还没更新，
    #   直接读 cam.matrix_world 会拿到单位矩阵，相机就会朝着错误的方向（渲出来一片空）。
    rot = Euler((math.radians(90.0 - elevation_deg), 0.0, math.radians(45.0)), "XYZ")
    cam.rotation_euler = rot
    basis = rot.to_matrix()
    cam_dir = basis @ Vector((0, 0, -1))     # 相机看向的方向
    right = basis @ Vector((1, 0, 0))
    up = basis @ Vector((0, 1, 0))

    # 用所有物体的包围盒算投影范围，自动框住
    corners = []
    for obj in objs:
        if obj.type != "MESH":
            continue
        for c in obj.bound_box:
            corners.append(obj.matrix_world @ Vector(c))
    if not corners:
        corners = [Vector((0, 0, 0)), Vector((1, 1, 1))]

    center = sum(corners, Vector()) / len(corners)
    xs = [(c - center).dot(right) for c in corners]
    ys = [(c - center).dot(up) for c in corners]
    w = max(xs) - min(xs)
    h = max(ys) - min(ys)
    # Blender 的 ortho_scale 对应画面"较长的那条边"
    cam_data.ortho_scale = max(w, h * (res_x / res_y)) * 1.06
    cam.location = center - cam_dir * 80.0
    log(f"相机：俯角 {elevation_deg}°，ortho_scale={cam_data.ortho_scale:.2f}，"
        f"投影范围 {w:.1f}×{h:.1f}")
    return cam



# ── 渲染各层 ─────────────────────────────────────────────────────────────
def render_to(path: str):
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def set_camera_visible(obj, visible: bool, keep_shadow: bool):
    """visible=False 时：keep_shadow=True → 只对相机不可见（阴影仍在），否则彻底不渲染。"""
    if visible:
        obj.hide_render = False
        try:
            obj.visible_camera = True
        except AttributeError:
            pass
    else:
        if keep_shadow:
            obj.hide_render = False
            try:
                obj.visible_camera = False
            except AttributeError:
                obj.hide_render = True
        else:
            obj.hide_render = True


def _prop_objects(p) -> list:
    """物件的全部网格 = 空物体本身 + 所有子孙（visibility 必须逐个设置，空物体不传递）。"""
    return [p] + [c for c in p.children_recursive]


def render_layers(out_dir: str, props: list, ground_objs: list, preview: bool):
    os.makedirs(out_dir, exist_ok=True)
    props_dir = os.path.join(out_dir, "props")
    os.makedirs(props_dir, exist_ok=True)

    # ① 地面层：物件对相机不可见，但保留阴影
    for p in props:
        for obj in _prop_objects(p):
            set_camera_visible(obj, False, keep_shadow=True)
    for g in ground_objs:
        set_camera_visible(g, True, keep_shadow=True)
    render_to(os.path.join(out_dir, "ground.png"))
    log("ground.png 完成")

    # ② 物件层：逐个单独渲
    for p in props:
        for other in props:
            for obj in _prop_objects(other):
                set_camera_visible(obj, False, keep_shadow=False)
        for g in ground_objs:
            set_camera_visible(g, False, keep_shadow=False)
        for obj in _prop_objects(p):
            set_camera_visible(obj, True, keep_shadow=False)
        render_to(os.path.join(props_dir, f"{p.name[5:]}.png"))
        log(f"props/{p.name[5:]}.png 完成")

    # ③ 预览：全部可见
    if preview:
        for p in props:
            for obj in _prop_objects(p):
                set_camera_visible(obj, True, keep_shadow=True)
        for g in ground_objs:
            set_camera_visible(g, True, keep_shadow=True)
        render_to(os.path.join(out_dir, "preview.png"))
        log("preview.png 完成")


# ── 俯视掩膜 ─────────────────────────────────────────────────────────────
def render_mask(out_dir: str, props: list, ground_objs: list, res_x: int, res_y: int):
    scene = bpy.context.scene
    saved = {}
    white = new_material("mask_white", (1, 1, 1), emission=(1, 1, 1))
    black = new_material("mask_black", (0, 0, 0), emission=(0, 0, 0))

    def swap(obj, mat):
        if obj.type != "MESH":
            return
        saved[obj.name] = [s.material for s in obj.material_slots]
        for slot in obj.material_slots:
            slot.material = mat

    for g in ground_objs:
        swap(g, white)
    for p in props:
        for child in p.children_recursive:
            swap(child, black)

    # 俯视相机
    cam_data = bpy.data.cameras.new("MaskCam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("MaskCam", cam_data)
    scene.collection.objects.link(cam)
    old_cam = scene.camera
    scene.camera = cam

    corners = []
    for g in ground_objs:
        if g.type == "MESH":
            for c in g.bound_box:
                corners.append(g.matrix_world @ Vector(c))
    center = sum(corners, Vector()) / max(1, len(corners))
    xs = [c.x for c in corners]
    ys = [c.y for c in corners]
    cam.location = (center.x, center.y, 60.0)
    cam.rotation_euler = (0, 0, math.radians(45))
    cam_data.ortho_scale = max(max(xs) - min(xs), max(ys) - min(ys)) * 1.42

    saved_film = scene.render.film_transparent
    scene.render.film_transparent = False
    old_samples = scene.cycles.samples
    scene.cycles.samples = 4
    render_to(os.path.join(out_dir, "mask.png"))
    scene.cycles.samples = old_samples
    scene.render.film_transparent = saved_film
    scene.camera = old_cam
    bpy.data.objects.remove(cam, do_unlink=True)

    for name, mats in saved.items():
        obj = bpy.data.objects.get(name)
        if obj is None:
            continue
        for slot, mat in zip(obj.material_slots, mats):
            slot.material = mat
    log("mask.png 完成")


# ── 元数据 ───────────────────────────────────────────────────────────────
def write_meta(out_dir: str, props: list, ground_objs: list,
               res_x: int, res_y: int, elevation: float):
    """物件的归一化坐标用**相机投影**算，而不是用地面包围盒：
    投影坐标直接就是它在渲染图里的位置（0~1，原点左上），Godot 里填进 MapProp.position 即可。"""
    from bpy_extras.object_utils import world_to_camera_view

    scene = bpy.context.scene
    cam = scene.camera
    items = []
    for p in props:
        co = world_to_camera_view(scene, cam, p.matrix_world.translation)  # (u, v, depth)
        u = round(min(1.0, max(0.0, co.x)), 4)
        v = round(min(1.0, max(0.0, 1.0 - co.y)), 4)   # Blender 的 v 从下往上，转成图像坐标
        items.append({
            "name": p.name[5:],
            "file": f"props/{p.name[5:]}.png",
            "position": [u, v],
        })
    meta = {
        "size": [res_x, res_y],
        "elevation_deg": elevation,
        "ground": "ground.png",
        "mask": "mask.png",
        "props": items,
    }
    with open(os.path.join(out_dir, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    log(f"meta.json：{len(items)} 个物件")


# ── 主流程 ───────────────────────────────────────────────────────────────
def main():
    opts = parse_args()
    out = os.path.abspath(opts["out"] or "out/render")
    res_x, res_y = (int(v) for v in str(opts["res"]).lower().split("x"))
    elevation = float(opts["elevation"])
    samples = int(opts["samples"])

    bpy.ops.wm.read_factory_settings(use_empty=True)
    if opts["scene"]:
        bpy.ops.wm.open_mainfile(filepath=os.path.abspath(opts["scene"]))
        log(f"打开场景 {opts['scene']}")
    else:
        build_demo()

    setup_world_and_render(res_x, res_y, samples)

    # 收集：prop_ 开头的空物体 = 物件；其余网格 = 地面/水/路
    props = [o for o in bpy.context.scene.objects if o.name.startswith("prop_")]
    prop_children = set()
    for p in props:
        for c in p.children_recursive:
            prop_children.add(c)
    ground_objs = [o for o in bpy.context.scene.objects
                   if o.type == "MESH" and o not in prop_children]
    log(f"物件 {len(props)} 个，地面物体 {len(ground_objs)} 个")

    all_objs = props + ground_objs
    setup_camera(elevation, res_x, res_y, all_objs)
    render_layers(out, props, ground_objs, opts["preview"])
    render_mask(out, props, ground_objs, res_x, res_y)
    write_meta(out, props, ground_objs, res_x, res_y, elevation)
    log(f"全部完成 → {out}")


if __name__ == "__main__":
    main()

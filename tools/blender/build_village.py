# -*- coding: utf-8 -*-
"""build_village.py —— Blender 端：按布局 JSON 把一堆现成 3D 资产"拼"成一张村庄场景。

分工：
    你负责给资产（.glb / .fbx / .obj，带贴图）；
    这个脚本负责：导入 → 统一脚底对齐 → 按坐标摆位 → 生成 .blend；
    然后 render_25d.py 负责：正交渲染 → 地面层 / 物件层 / 掩膜 / meta.json。

用法：
    blender.exe -b --python build_village.py -- --layout layout.json --out village.blend

布局 JSON（village_layout.json）：
{
  "map_size": [60, 60],                  // 世界尺寸，米
  "ground_color": [0.44, 0.60, 0.36],
  "water": [{"center": [10, 0], "size": [4, 60]}],
  "roads": [{"center": [-1.5, 0], "size": [3.2, 60]}],
  "assets_dir": "assets",                // 相对于 json 所在目录
  "props": [
    {"name": "house_a", "asset": "house_a.glb", "pos": [-5, -6], "rot": 0, "scale": 1},
    {"name": "tree_1",  "asset": "tree.glb",    "pos": [3, 4],   "rot": 30, "scale": 1.2}
  ]
}

约定：
  · 坐标是米；(0,0) 是地图中心，X 向右、Y 向"屏幕里"（和渲染相机的 yaw 45° 对应）；
  · 每个资产会自动**脚底对齐 z=0、水平居中到原点**，所以不用担心模型原点乱；
  · 每个物件会包在 `prop_<name>` 空物体里 —— render_25d.py 就按这个前缀识别物件。
"""

from __future__ import annotations

import json
import math
import os
import sys

import bpy
from mathutils import Vector


def parse_args() -> dict:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = {"layout": "", "out": ""}
    i = 0
    while i < len(argv):
        if argv[i] in ("--layout", "--out"):
            opts[argv[i][2:]] = argv[i + 1]
            i += 1
        i += 1
    return opts


def log(msg: str) -> None:
    print(f"[build_village] {msg}", flush=True)


def make_material(name: str, color):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = (*color, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.9
    return mat


def add_slab(name: str, center, size, color, z=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(center[0], center[1], z - size[2] / 2.0))
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (size[0] / 2.0, size[1] / 2.0, size[2] / 2.0)
    obj.data.materials.append(make_material(name + "_mat", color))
    return obj


def import_asset(path: str) -> list:
    """按扩展名导入，返回新导入的对象列表。"""
    before = set(bpy.context.scene.objects)
    ext = os.path.splitext(path)[1].lower()
    if ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    elif ext == ".obj":
        bpy.ops.wm.obj_import(filepath=path)
    else:
        raise RuntimeError(f"不支持的格式：{ext}")
    return [o for o in bpy.context.scene.objects if o not in before]


def normalize_asset(objs: list) -> list:
    """把导入的模型整理成"脚底在 z=0、水平居中在原点"，返回顶层对象列表。"""
    meshes = [o for o in objs if o.type == "MESH"]
    if not meshes:
        return []
    bpy.context.view_layer.update()
    corners = []
    for o in meshes:
        for c in o.bound_box:
            corners.append(o.matrix_world @ Vector(c))
    min_v = Vector((min(c.x for c in corners), min(c.y for c in corners), min(c.z for c in corners)))
    max_v = Vector((max(c.x for c in corners), max(c.y for c in corners), max(c.z for c in corners)))
    center = Vector(((min_v.x + max_v.x) / 2.0, (min_v.y + max_v.y) / 2.0, 0.0))

    # 顶层 = 没有父物体的那些
    roots = [o for o in objs if o.parent is None]
    for r in roots:
        r.location = r.location - Vector((center.x, center.y, min_v.z))
    bpy.context.view_layer.update()
    return roots


def place_instance(roots: list, empty, pos, rot_deg, scale, coll):
    """把资产挂到空物体下（空物体 = 物件的接地点/旋转/缩放中心）。

    ⚠ 必须用 bpy.ops.object.duplicate() 整组复制，不能自己 obj.copy() 逐个造：
    带骨骼/形变的模型（glTF 的 skeleton + Armature Modifier）逐个复制会失去绑定，
    渲染出来是"爆炸的多边形"。
    """
    bpy.ops.object.select_all(action="DESELECT")
    group = []
    for r in roots:
        group.append(r)
        group.extend(r.children_recursive)
    for o in group:
        o.select_set(True)
    bpy.context.view_layer.objects.active = group[0] if group else None
    bpy.ops.object.duplicate(linked=True)          # linked=True：共享网格数据，省内存
    dups = list(bpy.context.selected_objects)

    for o in dups:
        for c in list(o.users_collection):
            c.objects.unlink(o)
        coll.objects.link(o)

    for o in dups:
        if o.parent is None:                       # 顶层挂到空物体上
            o.parent = empty
            o.matrix_parent_inverse = empty.matrix_world.inverted()

    empty.location = (pos[0], pos[1], 0.0)
    empty.rotation_euler = (0.0, 0.0, math.radians(rot_deg))
    empty.scale = (scale, scale, scale)
    bpy.context.view_layer.update()


def main():
    opts = parse_args()
    if not opts["layout"]:
        log("缺少 --layout")
        sys.exit(1)
    layout_path = os.path.abspath(opts["layout"])
    layout = json.load(open(layout_path, encoding="utf-8-sig"))   # 兼容 Windows 记事本写的 BOM
    base_dir = os.path.dirname(layout_path)
    assets_rel = layout.get("assets_dir", "assets")
    # 资产目录：先按 json 所在目录找，找不到再按当前工作目录找（方便从项目根跑）
    assets_dir = assets_rel if os.path.isabs(assets_rel) else os.path.join(base_dir, assets_rel)
    if not os.path.isdir(assets_dir):
        alt = os.path.abspath(assets_rel)
        if os.path.isdir(alt):
            assets_dir = alt

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    props_coll = bpy.data.collections.new("Props")
    scene.collection.children.link(props_coll)
    assets_coll = bpy.data.collections.new("_AssetsSource")
    scene.collection.children.link(assets_coll)

    # ── 地面 / 水 / 路 ──
    w, d = layout.get("map_size", [60, 60])
    add_slab("Ground", (0, 0), (w, d, 1.0), layout.get("ground_color", [0.44, 0.60, 0.36]))
    for i, water in enumerate(layout.get("water", [])):
        add_slab(f"Water_{i}", water["center"], (water["size"][0], water["size"][1], 0.5),
                 layout.get("water_color", [0.26, 0.50, 0.64]), z=0.02)
    for i, road in enumerate(layout.get("roads", [])):
        add_slab(f"Road_{i}", road["center"], (road["size"][0], road["size"][1], 0.06),
                 layout.get("road_color", [0.72, 0.66, 0.52]), z=0.02)
    log(f"地面 {w}×{d}，水 {len(layout.get('water', []))} 块，路 {len(layout.get('roads', []))} 条")

    # ── 资产：同一种资产只导入一次，按需复制 ──
    cache = {}
    placed = 0
    for item in layout.get("props", []):
        asset = item["asset"]
        if asset not in cache:
            path = os.path.join(assets_dir, asset)
            if not os.path.exists(path):
                log(f"⚠ 找不到资产，跳过：{path}")
                cache[asset] = []
                continue
            imported = import_asset(path)
            roots = normalize_asset(imported)
            # 源对象挪到 _AssetsSource 集合（不参与渲染）
            for o in imported:
                if o.parent is None:
                    for c in list(o.users_collection):
                        c.objects.unlink(o)
                    assets_coll.objects.link(o)
            cache[asset] = roots
            log(f"导入资产 {asset}（{len(roots)} 个顶层对象）")

        roots = cache[asset]
        if not roots:
            continue
        empty = bpy.data.objects.new(f"prop_{item['name']}", None)
        empty.empty_display_size = 0.4
        props_coll.objects.link(empty)
        bpy.context.view_layer.update()
        place_instance(roots, empty, item["pos"], item.get("rot", 0.0), item.get("scale", 1.0),
                       props_coll)
        placed += 1

    # 隐藏资产源集合（不参与渲染，但保留在文件里方便替换）
    assets_coll.hide_render = True
    log(f"摆放 {placed} 个物件")

    out = os.path.abspath(opts["out"] or "village.blend")
    bpy.ops.wm.save_as_mainfile(filepath=out)
    log(f"已保存 {out}")


if __name__ == "__main__":
    main()

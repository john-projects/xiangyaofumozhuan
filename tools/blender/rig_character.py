# -*- coding: utf-8 -*-
"""rig_character.py —— 给一个"纯静态"的 GLB 角色绑一套人形骨骼并蒙皮。

    blender -b --python rig_character.py -- --glb 输入.glb --out 输出.glb [--blend 保存.blend]

流程：
    1) 导入 GLB，量出包围盒（模型是 chibi 比例，按比例布骨）
    2) 建人形骨架：root / hips / spine / chest / neck / head /
       shoulder/upper_arm/forearm/hand ×2 / upper_leg/lower_leg/foot ×2
    3) 蒙皮：优先 Blender 的"自动权重"（骨骼热量），失败就退化成
       "按到骨段的距离"分配权重（chibi + 硬甲这种模型反而更稳）
    4) 导出 GLB（带 skin），Godot 重新导入后就是可动骨架
"""

from __future__ import annotations

import math
import os
import sys

import bpy
import numpy as np
from mathutils import Vector


def parse_args() -> dict:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = {"glb": "", "out": "", "blend": ""}
    i = 0
    while i < len(argv):
        if argv[i].startswith("--") and argv[i][2:] in opts:
            opts[argv[i][2:]] = argv[i + 1]
            i += 1
        i += 1
    return opts


def log(msg: str) -> None:
    print(f"[rig] {msg}", flush=True)


def mesh_bounds(objs) -> tuple[Vector, Vector]:
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for ob in objs:
        if ob.type != "MESH":
            continue
        for corner in ob.bound_box:
            w = ob.matrix_world @ Vector(corner)
            lo = Vector((min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z)))
            hi = Vector((max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z)))
    return lo, hi


def build_armature(lo: Vector, hi: Vector) -> bpy.types.Object:
    """按包围盒比例摆一套人形骨骼（chibi 比例：头大、腿短）。"""
    H = hi.z - lo.z
    z0 = lo.z
    cx = (lo.x + hi.x) * 0.5
    cy = (lo.y + hi.y) * 0.5

    def z(r: float) -> float:
        return z0 + H * r

    # 各关节高度（按 0~1 的"从脚底算起"比例）
    hips_z, spine_z, chest_z = z(0.40), z(0.50), z(0.58)
    neck_z, head_z, head_top = z(0.645), z(0.68), z(0.92)
    shoulder_z = z(0.60)
    elbow_z, wrist_z = z(0.50), z(0.44)
    knee_z, ankle_z, toe_z = z(0.22), z(0.04), z(0.02)

    arm_x = H * 0.095          # 肩关节到中轴的距离
    elbow_x = H * 0.20
    wrist_x = H * 0.28
    hand_x = H * 0.33
    leg_x = H * 0.075

    bones = [
        # 名字, head, tail, parent, 是否连接
        ("root", (cx, cy, z0), (cx, cy, z(0.12)), None, False),
        ("hips", (cx, cy, hips_z), (cx, cy, spine_z), "root", False),
        ("spine", (cx, cy, spine_z), (cx, cy, chest_z), "hips", True),
        ("chest", (cx, cy, chest_z), (cx, cy, neck_z), "spine", True),
        ("neck", (cx, cy, neck_z), (cx, cy, head_z), "chest", True),
        ("head", (cx, cy, head_z), (cx, cy, head_top), "neck", True),

        ("shoulder.L", (cx + arm_x * 0.35, cy, shoulder_z), (cx + arm_x, cy, shoulder_z), "chest", False),
        ("upper_arm.L", (cx + arm_x, cy, shoulder_z), (cx + elbow_x, cy, elbow_z), "shoulder.L", True),
        ("forearm.L", (cx + elbow_x, cy, elbow_z), (cx + wrist_x, cy, wrist_z), "upper_arm.L", True),
        ("hand.L", (cx + wrist_x, cy, wrist_z), (cx + hand_x, cy, wrist_z - H * 0.02), "forearm.L", True),

        ("shoulder.R", (cx - arm_x * 0.35, cy, shoulder_z), (cx - arm_x, cy, shoulder_z), "chest", False),
        ("upper_arm.R", (cx - arm_x, cy, shoulder_z), (cx - elbow_x, cy, elbow_z), "shoulder.R", True),
        ("forearm.R", (cx - elbow_x, cy, elbow_z), (cx - wrist_x, cy, wrist_z), "upper_arm.R", True),
        ("hand.R", (cx - wrist_x, cy, wrist_z), (cx - hand_x, cy, wrist_z - H * 0.02), "forearm.R", True),

        ("upper_leg.L", (cx + leg_x, cy, hips_z), (cx + leg_x, cy, knee_z), "hips", False),
        ("lower_leg.L", (cx + leg_x, cy, knee_z), (cx + leg_x, cy, ankle_z), "upper_leg.L", True),
        ("foot.L", (cx + leg_x, cy, ankle_z), (cx + leg_x, cy - H * 0.06, toe_z), "lower_leg.L", True),

        ("upper_leg.R", (cx - leg_x, cy, hips_z), (cx - leg_x, cy, knee_z), "hips", False),
        ("lower_leg.R", (cx - leg_x, cy, knee_z), (cx - leg_x, cy, ankle_z), "upper_leg.R", True),
        ("foot.R", (cx - leg_x, cy, ankle_z), (cx - leg_x, cy - H * 0.06, toe_z), "lower_leg.R", True),
    ]

    arm_data = bpy.data.armatures.new("Armature")
    arm_obj = bpy.data.objects.new("Armature", arm_data)
    bpy.context.scene.collection.objects.link(arm_obj)

    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="EDIT")
    created = {}
    for name, head, tail, parent, connect in bones:
        eb = arm_data.edit_bones.new(name)
        eb.head = Vector(head)
        eb.tail = Vector(tail)
        created[name] = eb
    for name, head, tail, parent, connect in bones:
        if parent:
            created[name].parent = created[parent]
            created[name].use_connect = connect
    bpy.ops.object.mode_set(mode="OBJECT")
    log(f"骨架 {len(bones)} 根骨骼，高度 {H:.3f}")
    return arm_obj


def auto_weights(mesh_obj: bpy.types.Object, arm_obj: bpy.types.Object) -> bool:
    """尝试 Blender 自动权重（骨骼热量）。失败返回 False。"""
    bpy.ops.object.select_all(action="DESELECT")
    mesh_obj.select_set(True)
    arm_obj.select_set(True)
    bpy.context.view_layer.objects.active = arm_obj
    try:
        bpy.ops.object.parent_set(type="ARMATURE_AUTO")
        return True
    except Exception as exc:  # noqa: BLE001
        log(f"自动权重失败：{exc}")
        return False


def distance_weights(mesh_obj: bpy.types.Object, arm_obj: bpy.types.Object) -> None:
    """退化方案：每个顶点按"到各骨段的距离"分配给最近的两根骨骼。"""
    mesh = mesh_obj.data
    mw = mesh_obj.matrix_world
    verts = np.array([(mw @ v.co)[:] for v in mesh.vertices], dtype=np.float32)

    segs = []
    for b in arm_obj.data.bones:
        if b.name == "root":
            continue
        h = np.array(b.head_local[:], dtype=np.float32)
        t = np.array(b.tail_local[:], dtype=np.float32)
        segs.append((b.name, h, t))

    # 距离矩阵：顶点 × 骨段
    dists = np.zeros((len(verts), len(segs)), dtype=np.float32)
    for i, (_name, h, t) in enumerate(segs):
        seg = t - h
        seg_len2 = float(seg @ seg) or 1e-6
        rel = verts - h[None, :]
        tt = np.clip(rel @ seg / seg_len2, 0.0, 1.0)
        proj = h[None, :] + tt[:, None] * seg[None, :]
        dists[:, i] = np.linalg.norm(verts - proj, axis=1)

    # 每根骨骼建一个顶点组
    groups = {}
    for name, _h, _t in segs:
        groups[name] = mesh_obj.vertex_groups.get(name) or mesh_obj.vertex_groups.new(name=name)

    order = np.argsort(dists, axis=1)[:, :2]
    for vi in range(len(verts)):
        i0, i1 = order[vi]
        d0, d1 = dists[vi, i0], dists[vi, i1]
        # 越接近第二近的骨骼，混合越多（关节处过渡）
        w1 = float(np.clip(0.5 * (1.0 - (d1 - d0) / (d1 + d0 + 1e-6)), 0.0, 0.45))
        w0 = 1.0 - w1
        groups[segs[i0][0]].add([vi], w0, "REPLACE")
        groups[segs[i1][0]].add([vi], w1, "REPLACE")

    mesh_obj.parent = arm_obj
    mod = mesh_obj.modifiers.get("Armature") or mesh_obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm_obj
    log(f"距离权重完成：{len(verts)} 顶点 × {len(segs)} 骨段")


def main() -> None:
    opts = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(opts["glb"]))

    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit("没有找到 mesh")
    lo, hi = mesh_bounds(meshes)
    log(f"包围盒 {tuple(round(v, 3) for v in lo)} ~ {tuple(round(v, 3) for v in hi)}")

    arm_obj = build_armature(lo, hi)

    # ⚠ 自动权重（骨骼热量）在无界面模式下会"静默成功但权重全空"（20 个顶点组、0 权重）。
    #   这里改成先试一次、检查是否真有权重，没有就直接用距离权重兜底。
    used_auto = False
    for mesh in meshes:
        used_auto = auto_weights(mesh, arm_obj) or used_auto

    has_weight = False
    for mesh in meshes:
        for v in mesh.data.vertices[:500]:
            if len(v.groups) > 0:
                has_weight = True
                break
    if used_auto and has_weight:
        log("自动权重可用")
    else:
        log("自动权重没有产出权重，改用距离权重")
        for mesh in meshes:
            for vg in list(mesh.vertex_groups):
                mesh.vertex_groups.remove(vg)
            distance_weights(mesh, arm_obj)

    # 权重平滑：把关节处的过渡揉开，避免硬折
    for mesh in meshes:
        bpy.ops.object.select_all(action="DESELECT")
        mesh.select_set(True)
        bpy.context.view_layer.objects.active = mesh
        try:
            bpy.ops.object.vertex_group_smooth(group_select_mode="ALL", factor=0.5, repeat=3)
        except Exception as exc:  # noqa: BLE001
            log(f"权重平滑跳过：{exc}")

    if opts.get("blend"):
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(opts["blend"]))
        log(f"blend 已保存 {opts['blend']}")

    out = os.path.abspath(opts["out"])
    bpy.ops.export_scene.gltf(
        filepath=out,
        export_format="GLB",
        use_selection=False,
        export_apply=False,
        export_skins=True,
        export_animations=True,
        export_yup=True,
    )
    log(f"导出 {out}（{os.path.getsize(out) / 1024 / 1024:.1f} MB）")


if __name__ == "__main__":
    main()

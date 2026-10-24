# -*- coding: utf-8 -*-
"""retarget_with_donor.py —— 用"行修"的 62 骨 Mixamo 骨架 + 6 个动作，套到其它角色上。

    blender -b --python retarget_with_donor.py -- \
        --donor assets/models/players/行修.glb \
        --out-dir DIR \
        --targets a.glb b.glb ...

做法：
    1) 先把 donor 导入，只留骨架（62 骨，带 Alert/Attack/Dead/Running/Skill_01/Walking 六个动作）
    2) 每个目标：导入 → 按高度缩放到 donor 比例 → 对齐脚底与中心
    3) 用"顶点到骨段距离"蒙皮（donor 的骨骼名保持 mixamorig:*，Godot 里动作能直接匹配）
    4) 导出 GLB：带 skin + 6 个动画
"""

from __future__ import annotations

import os
import sys

import bpy
import numpy as np
from mathutils import Vector


def log(msg: str) -> None:
    print(f"[retarget] {msg}", flush=True)


def scene_meshes():
    return [o for o in bpy.context.scene.objects if o.type == "MESH"]


def bbox(objs):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for ob in objs:
        for c in ob.bound_box:
            w = ob.matrix_world @ Vector(c)
            lo = Vector((min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z)))
            hi = Vector((max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z)))
    return lo, hi


def skin_to_armature(mesh_obj, arm_obj) -> None:
    """按"顶点到骨段距离"分配两只骨骼的混合权重（世界坐标）。"""
    mw = mesh_obj.matrix_world
    aw = arm_obj.matrix_world
    verts = np.array([(mw @ v.co)[:] for v in mesh_obj.data.vertices], dtype=np.float32)

    segs = []
    for b in arm_obj.data.bones:
        h = aw @ b.head_local
        t = aw @ b.tail_local
        segs.append((b.name, np.array(h[:], dtype=np.float32), np.array(t[:], dtype=np.float32)))
    log(f"  骨骼 {len(segs)} 根，顶点 {len(verts)}")

    dists = np.zeros((len(verts), len(segs)), dtype=np.float32)
    for i, (_n, h, t) in enumerate(segs):
        seg = t - h
        seg_len2 = float(seg @ seg) or 1e-6
        rel = verts - h[None, :]
        tt = np.clip(rel @ seg / seg_len2, 0.0, 1.0)
        proj = h[None, :] + tt[:, None] * seg[None, :]
        dists[:, i] = np.linalg.norm(verts - proj, axis=1)

    groups = {}
    for name, _h, _t in segs:
        groups[name] = mesh_obj.vertex_groups.get(name) or mesh_obj.vertex_groups.new(name=name)

    order = np.argsort(dists, axis=1)[:, :2]
    for vi in range(len(verts)):
        i0, i1 = int(order[vi, 0]), int(order[vi, 1])
        d0, d1 = float(dists[vi, i0]), float(dists[vi, i1])
        w1 = float(np.clip(0.5 * (1.0 - (d1 - d0) / (d1 + d0 + 1e-6)), 0.0, 0.45))
        groups[segs[i0][0]].add([vi], 1.0 - w1, "REPLACE")
        groups[segs[i1][0]].add([vi], w1, "REPLACE")

    mesh_obj.parent = arm_obj
    mesh_obj.matrix_parent_inverse = arm_obj.matrix_world.inverted()
    mod = mesh_obj.modifiers.get("Armature") or mesh_obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm_obj


def process(target: str, donor: str, out: str) -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(donor))

    arms = [o for o in bpy.context.scene.objects if o.type == "ARMATURE"]
    if not arms:
        raise SystemExit("donor 没有骨架")
    arm = arms[0]
    donor_meshes = scene_meshes()
    lo_d, hi_d = bbox(donor_meshes)
    h_donor = hi_d.z - lo_d.z
    for m in donor_meshes:
        bpy.data.objects.remove(m, do_unlink=True)
    log(f"donor 骨架 {arm.name}：{len(arm.data.bones)} 骨，高度 {h_donor:.3f}")

    bpy.ops.import_scene.gltf(filepath=os.path.abspath(target))
    meshes = scene_meshes()
    lo_t, hi_t = bbox(meshes)
    h_target = hi_t.z - lo_t.z
    scale = h_donor / h_target if h_target > 1e-6 else 1.0
    log(f"目标 {os.path.basename(target)}：高度 {h_target:.3f}，缩放 {scale:.3f}")

    # 缩放 + 对齐（脚底 z 对齐 donor 脚底，水平居中）
    for m in meshes:
        m.scale = m.scale * scale
    bpy.context.view_layer.update()
    lo_t2, hi_t2 = bbox(meshes)
    delta = Vector((lo_d.x + (hi_d.x - lo_d.x) * 0.5 - (lo_t2.x + (hi_t2.x - lo_t2.x) * 0.5),
                    lo_d.y + (hi_d.y - lo_d.y) * 0.5 - (lo_t2.y + (hi_t2.y - lo_t2.y) * 0.5),
                    lo_d.z - lo_t2.z))
    for m in meshes:
        m.location = m.location + delta
    bpy.context.view_layer.update()

    for m in meshes:
        skin_to_armature(m, arm)

    # 确认六个动作都挂着（导出时按 ACTIONS 模式逐个导出）
    for act in bpy.data.actions:
        act.use_fake_user = True
    log(f"  动作：{[a.name for a in bpy.data.actions]}")

    bpy.ops.export_scene.gltf(
        filepath=os.path.abspath(out),
        export_format="GLB",
        use_selection=False,
        export_skins=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_yup=True,
    )
    log(f"  导出 {os.path.basename(out)}（{os.path.getsize(out) / 1024 / 1024:.1f} MB）")


def main() -> None:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    donor = ""
    out_dir = ""
    targets = []
    i = 0
    while i < len(argv):
        if argv[i] == "--donor":
            donor = argv[i + 1]
            i += 2
            continue
        if argv[i] == "--out-dir":
            out_dir = argv[i + 1]
            i += 2
            continue
        targets.append(argv[i])
        i += 1

    os.makedirs(out_dir, exist_ok=True)
    for t in targets:
        stem = os.path.splitext(os.path.basename(t))[0]
        try:
            process(t, donor, os.path.join(out_dir, f"{stem}.glb"))
        except Exception as exc:  # noqa: BLE001
            log(f"{stem} 失败：{exc}")


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""rig_all.py —— 批量给"纯静态"的角色 GLB 绑骨骼（Mixamo 命名）+ 加 idle 呼吸动画。

    blender -b --python rig_all.py -- --glb a.glb b.glb --out-dir DIR

对每个模型：
  1) 导入，量包围盒
  2) 建 20 根人形骨骼，命名用 Mixamo 规范（mixamorig:Hips 等），方便以后套 Mixamo 动画
  3) 蒙皮：顶点到骨段距离分配（两只骨骼混合），Blender 自动权重在无界面下会静默失败
  4) 生成一个 48 帧 @24fps 的 "idle" 呼吸循环
  5) 导出 GLB（带 skin + animation）
"""

from __future__ import annotations

import math
import os
import sys

import bpy
import numpy as np
from mathutils import Euler, Vector

# 逻辑名 → Mixamo 骨骼名
BONE_NAMES = {
    "root": "root",
    "hips": "mixamorig:Hips",
    "spine": "mixamorig:Spine",
    "chest": "mixamorig:Spine1",
    "neck": "mixamorig:Neck",
    "head": "mixamorig:Head",
    "shoulder.L": "mixamorig:LeftShoulder",
    "upper_arm.L": "mixamorig:LeftArm",
    "forearm.L": "mixamorig:LeftForeArm",
    "hand.L": "mixamorig:LeftHand",
    "shoulder.R": "mixamorig:RightShoulder",
    "upper_arm.R": "mixamorig:RightArm",
    "forearm.R": "mixamorig:RightForeArm",
    "hand.R": "mixamorig:RightHand",
    "upper_leg.L": "mixamorig:LeftUpLeg",
    "lower_leg.L": "mixamorig:LeftLeg",
    "foot.L": "mixamorig:LeftFoot",
    "upper_leg.R": "mixamorig:RightUpLeg",
    "lower_leg.R": "mixamorig:RightLeg",
    "foot.R": "mixamorig:RightFoot",
}


def parse_args() -> dict:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = {"glb": [], "out_dir": ""}
    i = 0
    while i < len(argv):
        if argv[i] == "--out-dir":
            opts["out_dir"] = argv[i + 1]
            i += 1
        elif argv[i].startswith("--"):
            opts[argv[i][2:]] = []
            i += 1
            while i < len(argv) and not argv[i].startswith("--"):
                opts[argv[i - 1 - (len(argv[i - 1]) and 0)][2:] if False else "glb"].append(argv[i])
                i += 1
            i -= 1
        i += 1
    return opts


def log(msg: str) -> None:
    print(f"[rig] {msg}", flush=True)


def bounds(objs):
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


def build_armature(lo: Vector, hi: Vector):
    H = hi.z - lo.z
    z0 = lo.z
    cx = (lo.x + hi.x) * 0.5
    cy = (lo.y + hi.y) * 0.5

    def z(r: float) -> float:
        return z0 + H * r

    hips_z, spine_z, chest_z = z(0.40), z(0.50), z(0.58)
    neck_z, head_z, head_top = z(0.645), z(0.68), z(0.92)
    shoulder_z = z(0.60)
    elbow_z, wrist_z = z(0.50), z(0.44)
    knee_z, ankle_z, toe_z = z(0.22), z(0.04), z(0.02)

    arm_x, elbow_x, wrist_x, hand_x = H * 0.095, H * 0.20, H * 0.28, H * 0.33
    leg_x = H * 0.075

    spec = [
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

    data = bpy.data.armatures.new("Armature")
    obj = bpy.data.objects.new("Armature", data)
    bpy.context.scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    created = {}
    for name, head, tail, _p, _c in spec:
        eb = data.edit_bones.new(BONE_NAMES[name])
        eb.head = Vector(head)
        eb.tail = Vector(tail)
        created[name] = eb
    for name, _h, _t, parent, connect in spec:
        if parent:
            created[name].parent = created[parent]
            created[name].use_connect = connect
    bpy.ops.object.mode_set(mode="OBJECT")
    return obj


def distance_weights(mesh_obj, arm_obj) -> None:
    mesh = mesh_obj.data
    mw = mesh_obj.matrix_world
    verts = np.array([(mw @ v.co)[:] for v in mesh.vertices], dtype=np.float32)

    segs = []
    for b in arm_obj.data.bones:
        if b.name == "root":
            continue
        segs.append((b.name, np.array(b.head_local[:], dtype=np.float32),
                     np.array(b.tail_local[:], dtype=np.float32)))

    dists = np.zeros((len(verts), len(segs)), dtype=np.float32)
    for i, (_n, h, t) in enumerate(segs):
        seg = t - h
        seg_len2 = float(seg @ seg) or 1e-6
        rel = verts - h[None, :]
        tt = np.clip(rel @ seg / seg_len2, 0.0, 1.0)
        proj = h[None, :] + tt[:, None] * seg[None, :]
        dists[:, i] = np.linalg.norm(verts - proj, axis=1)

    groups = {n: (mesh_obj.vertex_groups.get(n) or mesh_obj.vertex_groups.new(name=n))
              for n, _h, _t in segs}

    order = np.argsort(dists, axis=1)[:, :2]
    for vi in range(len(verts)):
        i0, i1 = int(order[vi, 0]), int(order[vi, 1])
        d0, d1 = float(dists[vi, i0]), float(dists[vi, i1])
        w1 = float(np.clip(0.5 * (1.0 - (d1 - d0) / (d1 + d0 + 1e-6)), 0.0, 0.45))
        groups[segs[i0][0]].add([vi], 1.0 - w1, "REPLACE")
        groups[segs[i1][0]].add([vi], w1, "REPLACE")

    mesh_obj.parent = arm_obj
    mod = mesh_obj.modifiers.get("Armature") or mesh_obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm_obj


def lower_arms(arm_obj, out_deg: float = 20.0) -> None:
    """把上臂从"平举"转到"自然下垂"，然后再把姿势烘成静置姿势。

    模型本身是 T/A-pose（手臂平举或斜举），骨骼默认也沿手臂方向；
    直接调骨骼把手臂转到接近竖直向下，稍微向外撇一点避免插进裙子/铠甲。
    """
    from mathutils import Matrix

    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="POSE")

    for side, sign in (("L", 1.0), ("R", -1.0)):
        pb = arm_obj.pose.bones.get(BONE_NAMES[f"upper_arm.{side}"])
        if pb is None:
            continue
        cur = (pb.tail - pb.head)
        if cur.length < 1e-6:
            continue
        cur.normalize()
        # 目标：主要向下，稍微朝外（防止手臂贴身穿模）
        target = Vector((sign * math.sin(math.radians(out_deg)), 0.0,
                         -math.cos(math.radians(out_deg)))).normalized()
        axis = cur.cross(target)
        if axis.length < 1e-6:
            continue
        angle = cur.angle(target)
        head = pb.head.copy()
        rot = Matrix.Rotation(angle, 4, axis.normalized())
        pb.matrix = Matrix.Translation(head) @ rot @ Matrix.Translation(-head) @ pb.matrix

        # 手肘微屈，避免完全笔直
        fb = arm_obj.pose.bones.get(BONE_NAMES[f"forearm.{side}"])
        if fb is not None:
            fdir = (fb.tail - fb.head).normalized()
            faxis = fdir.cross(Vector((0.0, -1.0, 0.0)))
            if faxis.length > 1e-6:
                fhead = fb.head.copy()
                frot = Matrix.Rotation(math.radians(12.0), 4, faxis.normalized())
                fb.matrix = (Matrix.Translation(fhead) @ frot @
                             Matrix.Translation(-fhead) @ fb.matrix)

    bpy.ops.object.mode_set(mode="OBJECT")

    # ⚠ 关键：只把姿势烘成 rest 是不够的——顶点位置还留在 T-pose，
    #   导出的 GLB 在引擎里（Godot）会按 T-pose 显示。
    #   所以先把"手臂下垂"的形变**烘进网格**（应用 Armature 修改器），再改 rest pose。
    for ob in list(bpy.context.scene.objects):
        if ob.type != "MESH":
            continue
        has_arm = any(m.type == "ARMATURE" and m.object == arm_obj for m in ob.modifiers)
        if not has_arm:
            continue
        bpy.ops.object.select_all(action="DESELECT")
        ob.select_set(True)
        bpy.context.view_layer.objects.active = ob
        for mod in [m for m in ob.modifiers if m.type == "ARMATURE"]:
            bpy.ops.object.modifier_apply(modifier=mod.name)

    # 现在把姿势定为静置姿势（骨骼从此就是下垂的）
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="POSE")
    bpy.ops.pose.select_all(action="SELECT")
    bpy.ops.pose.armature_apply(selected=False)
    bpy.ops.object.mode_set(mode="OBJECT")

    # 重新挂上 Armature 修改器（后面 idle 动画还要用它）
    for ob in list(bpy.context.scene.objects):
        if ob.type != "MESH":
            continue
        if not any(m.type == "ARMATURE" for m in ob.modifiers):
            mod = ob.modifiers.new("Armature", "ARMATURE")
            mod.object = arm_obj
            ob.parent = arm_obj
    log("手臂已放下：形变烘进网格 + rest pose 更新")


def _action_fcurves(act):
    """Blender 4.4+ 的 Action 是分层/分槽的，fcurves 不在顶层了；两种结构都兼容。"""
    if hasattr(act, "fcurves"):
        return list(act.fcurves)
    out = []
    for layer in getattr(act, "layers", []):
        for strip in getattr(layer, "strips", []):
            for slot in getattr(act, "slots", []):
                bag = strip.channelbag(slot)
                if bag is not None:
                    out.extend(bag.fcurves)
    return out


def add_idle_action(arm_obj, frames: int = 48) -> None:
    """48 帧呼吸循环：胸腔起伏 + 头微动 + 手臂轻摆，首尾同帧保证无缝。"""
    scene = bpy.context.scene
    scene.render.fps = 24
    arm_obj.animation_data_create()
    act = bpy.data.actions.new("idle")
    act.use_fake_user = True
    arm_obj.animation_data.action = act
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="POSE")

    def key(frame: int, pose: dict) -> None:
        scene.frame_set(frame)
        for bone_name, euler in pose.items():
            pb = arm_obj.pose.bones.get(bone_name)
            if pb is None:
                continue
            pb.rotation_mode = "XYZ"
            pb.rotation_euler = Euler([math.radians(v) for v in euler], "XYZ")
            pb.keyframe_insert("rotation_euler", frame=frame)

    rest = {BONE_NAMES[k]: (0, 0, 0) for k in
            ("hips", "spine", "chest", "neck", "head",
             "shoulder.L", "upper_arm.L", "shoulder.R", "upper_arm.R")}
    mid = dict(rest)
    mid[BONE_NAMES["chest"]] = (2.2, 0, 0)
    mid[BONE_NAMES["spine"]] = (1.0, 0, 0)
    mid[BONE_NAMES["head"]] = (-1.6, 0, 0)
    mid[BONE_NAMES["upper_arm.L"]] = (0, 0, -1.6)
    mid[BONE_NAMES["upper_arm.R"]] = (0, 0, 1.6)

    key(1, rest)
    key(frames // 2, mid)
    key(frames, rest)

    curves = _action_fcurves(act)
    for fcurve in curves:
        for kp in fcurve.keyframe_points:
            kp.interpolation = "BEZIER"

    bpy.ops.object.mode_set(mode="OBJECT")
    scene.frame_start = 1
    scene.frame_end = frames
    log(f"idle 动作：{frames} 帧 @24fps，{len(curves)} 条曲线")


def _rotate_global(pb, axis: str, deg: float) -> None:
    """绕"世界轴"旋转一根骨骼（绕它的骨头端点转），比直接改局部欧拉角直观。"""
    from mathutils import Matrix
    if abs(deg) < 1e-6:
        return
    head = pb.head.copy()
    rot = Matrix.Rotation(math.radians(deg), 4, axis)
    pb.matrix = Matrix.Translation(head) @ rot @ Matrix.Translation(-head) @ pb.matrix


def add_run_action(arm_obj, frames: int = 32, thigh: float = 20.0,
                   knee: float = 26.0, arm_swing: float = 16.0,
                   bob: float = 0.012) -> None:
    """走路/跑步循环（32 帧 @24fps ≈ 1.33s）：双脚前后小幅摆动 + 手臂反向摆 + 身体轻微起伏。

    相位（0 / 0.25 / 0.5 / 0.75）：
        0    左腿在前、右腿在后（右膝弯）
        0.25 交叉过渡（双腿并拢、身体最高）
        0.5  右腿在前、左腿在后（左膝弯）
        0.75 交叉过渡
    """
    from mathutils import Matrix

    scene = bpy.context.scene
    scene.render.fps = 24
    arm_obj.animation_data_create()
    act = bpy.data.actions.new("run")
    act.use_fake_user = True
    arm_obj.animation_data.action = act
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="POSE")

    legs = (BONE_NAMES["upper_leg.L"], BONE_NAMES["lower_leg.L"],
            BONE_NAMES["upper_leg.R"], BONE_NAMES["lower_leg.R"])
    arms = (BONE_NAMES["upper_arm.L"], BONE_NAMES["forearm.L"],
            BONE_NAMES["upper_arm.R"], BONE_NAMES["forearm.R"])
    all_bones = legs + arms + (BONE_NAMES["hips"], BONE_NAMES["spine"], BONE_NAMES["chest"],
                               BONE_NAMES["head"])

    def reset_pose() -> None:
        for name in all_bones:
            pb = arm_obj.pose.bones.get(name)
            if pb is None:
                continue
            pb.rotation_mode = "QUATERNION"
            pb.rotation_quaternion = (1, 0, 0, 0)
            pb.location = (0, 0, 0)
            pb.scale = (1, 1, 1)

    def key_all(frame: int) -> None:
        for name in all_bones:
            pb = arm_obj.pose.bones.get(name)
            if pb is None:
                continue
            pb.keyframe_insert("rotation_quaternion", frame=frame)
            pb.keyframe_insert("location", frame=frame)

    def pose_phase(swing: float, bend_l: float, bend_r: float,
                   arm_l: float, arm_r: float, lift: float) -> None:
        """swing>0 = 左腿在前；lift = 髋部抬高（交叉过渡时的上下起伏）。"""
        reset_pose()
        lu = arm_obj.pose.bones.get(BONE_NAMES["upper_leg.L"])
        ru = arm_obj.pose.bones.get(BONE_NAMES["upper_leg.R"])
        ll = arm_obj.pose.bones.get(BONE_NAMES["lower_leg.L"])
        rl = arm_obj.pose.bones.get(BONE_NAMES["lower_leg.R"])
        # 世界 X 轴旋转：负角度 = 往 -Y（角色正面）抬
        _rotate_global(lu, "X", -swing)
        _rotate_global(ru, "X", swing)
        # 膝盖只能往后弯：脚往 +Y 收
        _rotate_global(ll, "X", bend_l)
        _rotate_global(rl, "X", bend_r)
        # 手臂反向摆
        _rotate_global(arm_obj.pose.bones.get(BONE_NAMES["upper_arm.L"]), "X", arm_l)
        _rotate_global(arm_obj.pose.bones.get(BONE_NAMES["upper_arm.R"]), "X", arm_r)
        _rotate_global(arm_obj.pose.bones.get(BONE_NAMES["forearm.L"]), "X", -abs(arm_l) * 0.4)
        _rotate_global(arm_obj.pose.bones.get(BONE_NAMES["forearm.R"]), "X", -abs(arm_r) * 0.4)
        # 躯干前倾 + 髋部起伏
        _rotate_global(arm_obj.pose.bones.get(BONE_NAMES["chest"]), "X", -3.0)
        hips = arm_obj.pose.bones.get(BONE_NAMES["hips"])
        if hips is not None:
            hips.location = (0.0, 0.0, lift)

    half = frames // 2
    quarter = frames // 4
    # 相位 0：左前右后
    pose_phase(thigh, 4.0, knee, arm_swing, -arm_swing, -bob)
    key_all(1)
    # 相位 0.25：过渡
    pose_phase(0.0, 10.0, 10.0, 0.0, 0.0, bob)
    key_all(1 + quarter)
    # 相位 0.5：右前左后
    pose_phase(-thigh, knee, 4.0, -arm_swing, arm_swing, -bob)
    key_all(1 + half)
    # 相位 0.75：过渡
    pose_phase(0.0, 10.0, 10.0, 0.0, 0.0, bob)
    key_all(1 + half + quarter)
    # 回到相位 0，闭环
    pose_phase(thigh, 4.0, knee, arm_swing, -arm_swing, -bob)
    key_all(1 + frames)

    curves = _action_fcurves(act)
    for fcurve in curves:
        for kp in fcurve.keyframe_points:
            kp.interpolation = "BEZIER"

    bpy.ops.object.mode_set(mode="OBJECT")
    log(f"run 动作：{frames} 帧 @24fps，{len(curves)} 条曲线")


def rig_one(glb: str, out: str, blend: str, arms_out: float = 20.0) -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(glb))
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not meshes:
        log(f"{glb} 没有 mesh，跳过")
        return
    lo, hi = bounds(meshes)
    log(f"{os.path.basename(glb)} 包围盒 Z {lo.z:.2f}~{hi.z:.2f}")

    arm = build_armature(lo, hi)
    for mesh in meshes:
        distance_weights(mesh, arm)
    lower_arms(arm, arms_out)   # 手臂放下 + 烘成静置姿势（arms_out = 外撇角）
    add_idle_action(arm)
    add_run_action(arm)

    if blend:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend))
    bpy.ops.export_scene.gltf(
        filepath=os.path.abspath(out),
        export_format="GLB",
        use_selection=False,
        export_skins=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_yup=True,
    )
    log(f"导出 {os.path.basename(out)}（{os.path.getsize(out) / 1024 / 1024:.1f} MB）")


def main() -> None:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    out_dir = ""
    arms_out = 20.0
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--out-dir":
            out_dir = argv[i + 1]
            i += 2
            continue
        if argv[i] == "--arms-out":
            arms_out = float(argv[i + 1])
            i += 2
            continue
        files.append(argv[i])
        i += 1

    log(f"外撇角 {arms_out}°")
    os.makedirs(out_dir, exist_ok=True)
    for f in files:
        stem = os.path.splitext(os.path.basename(f))[0]
        try:
            rig_one(f, os.path.join(out_dir, f"{stem}.glb"),
                    os.path.join(out_dir, f"{stem}.blend"), arms_out)
        except Exception as exc:  # noqa: BLE001
            log(f"{stem} 失败：{exc}")


if __name__ == "__main__":
    main()

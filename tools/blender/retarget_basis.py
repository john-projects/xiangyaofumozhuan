# -*- coding: utf-8 -*-
"""retarget_basis.py —— 把行修的动作"按局部旋转增量"转给其它角色（不做世界空间对齐）。

    blender -b --python retarget_basis.py -- \
        --donor assets/models/players/行修.glb \
        --target assets/models/players/陆孤鸣.glb \
        --out out.glb [--actions Running,Walking]

为什么用 matrix_basis：
    matrix_basis 是"相对 rest 的局部变换"。把它从 donor 复制到 target，
    等于把"转了多少度"原样搬过去，不关心两边 rest 姿态/比例是否相同。
    两边都源自 Mixamo 命名，骨骼局部轴一致，所以这是最稳的搬法。
"""

from __future__ import annotations

import os
import sys

import math

import bpy


def log(msg: str) -> None:
    print(f"[basis] {msg}", flush=True)


def main() -> None:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = {"donor": "", "target": "", "out": "", "actions": ""}
    i = 0
    while i < len(argv):
        if argv[i] in ("--donor", "--target", "--out", "--actions"):
            opts[argv[i][2:]] = argv[i + 1]
            i += 1
        i += 1

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(opts["target"]))
    target_arm = next(o for o in bpy.context.scene.objects if o.type == "ARMATURE")
    target_names = {b.name for b in target_arm.data.bones}
    log(f"目标 {target_arm.name}：{len(target_names)} 骨")
    # 目标自带的动作（idle / run）要保留；后面导入 donor 时带来的动作才需要清理
    keep_actions = set(bpy.data.actions)

    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(opts["donor"]))
    new = [o for o in bpy.context.scene.objects if o not in before]
    donor_arm = next(o for o in new if o.type == "ARMATURE")
    for o in new:
        if o.type == "MESH":
            bpy.data.objects.remove(o, do_unlink=True)

    mapped = [b.name for b in donor_arm.data.bones if b.name in target_names]
    log(f"可映射骨骼 {len(mapped)} 根：{mapped[:6]}…")

    wanted = [a.strip() for a in opts["actions"].split(",") if a.strip()]
    actions = [a for a in bpy.data.actions if a not in keep_actions and (not wanted or a.name in wanted)]
    log(f"动作：{[a.name for a in actions]}")

    bpy.context.view_layer.objects.active = target_arm
    bpy.ops.object.mode_set(mode="POSE")
    for pb in target_arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
    bpy.ops.object.mode_set(mode="OBJECT")

    # 行修模型的正面朝 +Y，我们的模型朝 -Y：整体绕 Z 转 180°，否则动作会让角色背对镜头
    from mathutils import Matrix
    hips_head = target_arm.matrix_world @ target_arm.data.bones['mixamorig:Hips'].head_local
    yaw = (Matrix.Translation(hips_head) @ Matrix.Rotation(math.pi, 4, 'Z') @
           Matrix.Translation(-hips_head))

    for act in actions:
        if donor_arm.animation_data is None:
            donor_arm.animation_data_create()
        donor_arm.animation_data.action = act
        start, end = [int(round(v)) for v in act.frame_range]

        target_arm.animation_data_create()
        new_act = bpy.data.actions.new("RT_" + act.name)
        keep_actions.add(new_act)
        new_act.use_fake_user = True
        target_arm.animation_data.action = new_act

        bpy.ops.object.mode_set(mode="POSE")
        for f in range(start, end + 1):
            bpy.context.scene.frame_set(f)
            bpy.context.view_layer.update()
            for name in mapped:
                d_pb = donor_arm.pose.bones.get(name)
                t_pb = target_arm.pose.bones.get(name)
                if d_pb is None or t_pb is None:
                    continue
                # 世界空间的"旋转增量"：delta = pose_world @ rest_world^-1
                rest_w = donor_arm.matrix_world @ d_pb.bone.matrix_local
                pose_w = donor_arm.matrix_world @ d_pb.matrix
                delta = pose_w @ rest_w.inverted()
                t_rest_w = target_arm.matrix_world @ t_pb.bone.matrix_local
                t_pb.matrix = target_arm.matrix_world.inverted() @ (yaw @ delta @ t_rest_w)
                t_pb.keyframe_insert("rotation_quaternion", frame=f)
                if name in ("mixamorig:Hips", "mixamorig_Hips"):
                    t_pb.keyframe_insert("location", frame=f)
        bpy.ops.object.mode_set(mode="OBJECT")
        log(f"  复制 {act.name}：{start}~{end} 帧")

    # 清场：只保留目标自己的动作（烘焙前就存在的）+ 我们新烘的，
    # 把 donor 里带进来的一堆原始动作删掉，否则导出的 GLB 里会有两套同名动画。
    for act in list(bpy.data.actions):
        if act in keep_actions:
            continue
        try:
            act.use_fake_user = False
            bpy.data.actions.remove(act)
        except Exception as exc:  # noqa: BLE001
            log(f"  删除动作 {act.name} 失败：{exc}")
    for act in list(bpy.data.actions):
        if act.name.startswith("RT_"):
            act.name = act.name[3:]

    bpy.data.objects.remove(donor_arm, do_unlink=True)
    bpy.ops.export_scene.gltf(
        filepath=os.path.abspath(opts["out"]),
        export_format="GLB",
        use_selection=False,
        export_skins=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_yup=True,
    )
    log(f"导出 {opts['out']}（{os.path.getsize(opts['out']) / 1024 / 1024:.1f} MB）")


if __name__ == "__main__":
    main()

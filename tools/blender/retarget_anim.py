# -*- coding: utf-8 -*-
"""retarget_anim.py —— 把"行修"的 Mixamo 动作重定向到我们 20 骨的角色上。

    blender -b --python retarget_anim.py -- \
        --donor assets/models/players/行修.glb \
        --target assets/models/players/陆孤鸣.glb \
        --out out.glb [--actions Running,Walking]

原理：
    不做"换骨架"（比例不同会扯坏网格），而是：
      1) 把 donor 的骨架导入并对齐到目标身体（按髋部高度缩放）
      2) 给目标的每根骨骼加 Copy Rotation 约束（世界空间）指向 donor 同名骨骼
      3) 逐个动作 bake（视觉关键帧）到目标骨架上
      4) 导出目标 GLB，动作名保持 donor 的（Running / Walking / Attack / …）

    骨骼名能对上，是因为两边都用了 mixamorig:* 命名。
"""

from __future__ import annotations

import os
import sys

import bpy
from mathutils import Vector


def log(msg: str) -> None:
    print(f"[anim] {msg}", flush=True)


def parse_args() -> dict:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = {"donor": "", "target": "", "out": "", "actions": ""}
    i = 0
    while i < len(argv):
        if argv[i] in ("--donor", "--target", "--out", "--actions"):
            opts[argv[i][2:]] = argv[i + 1]
            i += 1
        i += 1
    return opts


def armature_of(scene) -> bpy.types.Object | None:
    for o in scene.objects:
        if o.type == "ARMATURE":
            return o
    return None


def bone_world(arm: bpy.types.Object, name: str) -> Vector | None:
    b = arm.data.bones.get(name)
    if b is None:
        return None
    return arm.matrix_world @ b.head_local


def main() -> None:
    opts = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)

    # ── 目标：已绑好 20 骨的角色 ──
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(opts["target"]))
    target_arm = armature_of(bpy.context.scene)
    if target_arm is None:
        raise SystemExit("目标没有骨架")
    t_hips = bone_world(target_arm, "mixamorig:Hips") or bone_world(target_arm, "mixamorig_Hips")
    log(f"目标骨架 {target_arm.name}：{len(target_arm.data.bones)} 骨")

    # ── donor：行修 ──
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(opts["donor"]))
    new_objs = [o for o in bpy.context.scene.objects if o not in before]
    donor_arm = next((o for o in new_objs if o.type == "ARMATURE"), None)
    if donor_arm is None:
        raise SystemExit("donor 没有骨架")
    for o in new_objs:
        if o.type == "MESH":
            bpy.data.objects.remove(o, do_unlink=True)

    log("  目标 hips=" + str(t_hips) + " head=" + str(bone_world(target_arm, "mixamorig:Head")))
    log("  donor  hips=" + str(bone_world(donor_arm, "mixamorig:Hips")) + " head=" + str(bone_world(donor_arm, "mixamorig:Head")))
    d_hips = bone_world(donor_arm, "mixamorig:Hips")
    d_head = bone_world(donor_arm, "mixamorig:Head")
    t_head = bone_world(target_arm, "mixamorig:Head")
    # 用"髋到头的距离"算比例（不能用 hips 的绝对 z：两边脚底高度不同，会算出负数）
    ratio = 1.0
    if None not in (t_hips, t_head, d_hips, d_head):
        d_span = (d_head - d_hips).length
        t_span = (t_head - t_hips).length
        if d_span > 1e-6:
            ratio = t_span / d_span
    donor_arm.scale = donor_arm.scale * ratio
    bpy.context.view_layer.update()
    d_hips2 = bone_world(donor_arm, "mixamorig:Hips")
    if t_hips is not None and d_hips2 is not None:
        donor_arm.location += Vector((t_hips.x - d_hips2.x, t_hips.y - d_hips2.y,
                                      t_hips.z - d_hips2.z))
    bpy.context.view_layer.update()
    # 朝向对齐：行修的正面朝 +Y，我们的模型朝 -Y，绕 Z 转 180° 再重定向
    import math
    donor_arm.rotation_mode = "XYZ"
    donor_arm.rotation_euler = (donor_arm.rotation_euler[0], donor_arm.rotation_euler[1],
                              donor_arm.rotation_euler[2] + math.pi)
    bpy.context.view_layer.update()
    log(f"donor 对齐：缩放 {ratio:.3f}，绕 Z 转 180°")

    # ── 给目标骨加 Copy Rotation 约束 ──
    bpy.context.view_layer.objects.active = target_arm
    bpy.ops.object.mode_set(mode="POSE")
    constrained = []
    for pb in target_arm.pose.bones:
        db = donor_arm.data.bones.get(pb.name)
        if db is None:
            continue
        con = pb.constraints.new("COPY_ROTATION")
        con.target = donor_arm
        con.subtarget = pb.name
        con.target_space = "WORLD"
        con.owner_space = "WORLD"
        constrained.append(pb.name)
    bpy.ops.object.mode_set(mode="OBJECT")
    log(f"约束 {len(constrained)} 根骨骼")

    wanted = [a.strip() for a in opts["actions"].split(",") if a.strip()] or None
    donor_actions = [a for a in bpy.data.actions if a.name in (wanted or [a.name])]
    log(f"要烘焙的动作：{[a.name for a in donor_actions]}")

    for act in donor_actions:
        if donor_arm.animation_data is None:
            donor_arm.animation_data_create()
        donor_arm.animation_data.action = act
        # 动作帧范围
        start, end = [int(round(v)) for v in act.frame_range]
        bpy.context.scene.frame_start = start
        bpy.context.scene.frame_end = end

        bpy.ops.object.select_all(action="DESELECT")
        target_arm.select_set(True)
        bpy.context.view_layer.objects.active = target_arm
        bpy.ops.object.mode_set(mode="POSE")
        bpy.ops.pose.select_all(action="SELECT")
        bpy.ops.nla.bake(frame_start=start, frame_end=end, only_selected=False,
                         visual_keying=True, clear_constraints=False,
                         clear_parents=False, use_current_action=False, bake_types={"POSE"})
        bpy.ops.object.mode_set(mode="OBJECT")
        baked = target_arm.animation_data.action
        baked.name = act.name
        baked.use_fake_user = True
        log(f"  烘焙 {act.name}：{start}~{end} 帧")

    # 清掉约束，避免导出时叠加
    bpy.ops.object.mode_set(mode="POSE")
    for pb in target_arm.pose.bones:
        for con in list(pb.constraints):
            pb.constraints.remove(con)
    bpy.ops.object.mode_set(mode="OBJECT")

    # 把 donor 骨架删掉（它不该进导出）
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

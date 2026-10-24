# -*- coding: utf-8 -*-
"""inspect_donor.py —— 看行修.glb 的骨架结构（骨骼名、数量、包围盒、动作）。

    blender -b --python inspect_donor.py -- --glb 行修.glb
"""

from __future__ import annotations

import os
import sys

import bpy
from mathutils import Vector


def main() -> None:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    path = argv[0]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(path))

    arms = [o for o in bpy.context.scene.objects if o.type == "ARMATURE"]
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    print("[donor] 骨架对象:", [(a.name, len(a.data.bones)) for a in arms])
    print("[donor] 网格:", [(m.name, len(m.data.vertices)) for m in meshes])
    print("[donor] 动作:", [a.name for a in bpy.data.actions])

    if arms:
        arm = arms[0]
        names = [b.name for b in arm.data.bones]
        print("[donor] 骨骼名:", names)
        lo = Vector((1e9, 1e9, 1e9))
        hi = Vector((-1e9, -1e9, -1e9))
        for m in meshes:
            for c in m.bound_box:
                w = m.matrix_world @ Vector(c)
                lo = Vector((min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z)))
                hi = Vector((max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z)))
        print(f"[donor] 包围盒 Z {lo.z:.3f}~{hi.z:.3f} 高度 {hi.z - lo.z:.3f}")


if __name__ == "__main__":
    main()

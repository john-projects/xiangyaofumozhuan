# -*- coding: utf-8 -*-
"""check_rig.py —— 检查 blend 里的蒙皮状态：顶点组数量、修改器、权重分布。"""

from __future__ import annotations

import os
import sys

import bpy


def main() -> None:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    path = os.path.abspath(argv[0])
    bpy.ops.wm.open_mainfile(filepath=path)

    for ob in bpy.context.scene.objects:
        print(f"[check] {ob.name} type={ob.type}")
        if ob.type == "MESH":
            print(f"[check]   verts={len(ob.data.vertices)} 顶点组={len(ob.vertex_groups)} "
                  f"修改器={[m.type for m in ob.modifiers]}")
            print(f"[check]   父级={ob.parent.name if ob.parent else None}")
            counts = {}
            for v in ob.data.vertices[:2000]:
                for g in v.groups:
                    name = ob.vertex_groups[g.group].name
                    counts[name] = counts.get(name, 0) + 1
            top = sorted(counts.items(), key=lambda kv: -kv[1])[:8]
            print(f"[check]   前 2000 顶点的权重分布: {top}")
        if ob.type == "ARMATURE":
            print(f"[check]   骨骼={[b.name for b in ob.data.bones]}")


if __name__ == "__main__":
    main()

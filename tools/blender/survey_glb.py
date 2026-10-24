import glob
import json
import os
import struct

for p in sorted(glob.glob(r"assets\models\players\*.glb")):
    with open(p, "rb") as f:
        _magic, _ver, _length = struct.unpack("<III", f.read(12))
        clen, _ctype = struct.unpack("<II", f.read(8))
        js = json.loads(f.read(clen).decode("utf-8"))
    meshes = js.get("meshes", [])
    nverts = 0
    for m in meshes:
        for pr in m.get("primitives", []):
            nverts += js["accessors"][pr["attributes"]["POSITION"]]["count"]
    size = os.path.getsize(p) / 1024 / 1024
    print(f"{os.path.basename(p):18s} nodes={len(js.get('nodes', [])):3d} "
          f"meshes={len(meshes)} verts={nverts:7d} "
          f"skins={len(js.get('skins', []))} anims={len(js.get('animations', []))} "
          f"{size:.1f}MB")

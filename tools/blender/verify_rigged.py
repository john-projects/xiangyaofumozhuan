import glob
import json
import os
import struct


def info(p):
    with open(p, "rb") as f:
        _m, _v, _l = struct.unpack("<III", f.read(12))
        clen, _c = struct.unpack("<II", f.read(8))
        js = json.loads(f.read(clen).decode("utf-8"))
    skins = js.get("skins", [])
    anims = [a.get("name") for a in js.get("animations", [])]
    return skins, anims


paths = sorted(glob.glob(r"C:\Users\yong\AppData\Local\Temp\rig_out2\*.glb"))
paths += [r"C:\Users\yong\AppData\Local\Temp\rig_out\陆孤鸣.glb"]
for p in paths:
    skins, anims = info(p)
    size = os.path.getsize(p) / 1024 / 1024
    joints = len(skins[0]["joints"]) if skins else 0
    print(f"{os.path.basename(p):30s} skins={len(skins)} joints={joints} "
          f"anims={anims} {size:.1f}MB")

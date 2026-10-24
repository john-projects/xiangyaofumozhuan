#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stamp.py —— 图片"印章/克隆"工具：把一块区域复制/缩放/翻转后盖到另一块区域。

用来修 AI 图里不合理的部分：文字糊成一团、物件重复、边缘断裂——
找一块"本来就正常"的纹理，盖到坏的地方，边缘做羽化融合。

单次：
    python tools/img/stamp.py --src in.png --out out.png \
        --from 100,400,180,470 --to 120,520 --feather 6

批量（推荐，方便反复调）：
    python tools/img/stamp.py --src in.png --out out.png --ops ops.json

ops.json 里每个操作：
    {"from": [x0, y0, x1, y1],     # 采样区域
     "to": [x, y],                 # 目标左上角（或 "to_center": [x, y]）
     "scale": 1.0,                 # 缩放采样块（>1 放大）
     "flip": false,                # 水平翻转
     "rotate": 0,                  # 旋转角度
     "feather": 6,                 # 边缘羽化像素
     "opacity": 1.0}               # 不透明度
"""

from __future__ import annotations

import argparse
import json
import os

from PIL import Image, ImageDraw, ImageFilter


def build_mask(size: tuple[int, int], feather: int) -> Image.Image:
    """整块不透明、边缘羽化的蒙版。"""
    w, h = size
    mask = Image.new("L", (w, h), 255)
    if feather > 0:
        # 先把四周往里缩，再模糊，得到柔边
        inner = Image.new("L", (w, h), 0)
        d = ImageDraw.Draw(inner)
        d.rectangle([feather, feather, w - feather, h - feather], fill=255)
        mask = inner.filter(ImageFilter.GaussianBlur(max(0.5, feather * 0.6)))
    return mask


def apply_op(base: Image.Image, op: dict) -> Image.Image:
    x0, y0, x1, y1 = [int(v) for v in op["from"]]
    src = base.crop((x0, y0, x1, y1)).convert("RGBA")

    scale = float(op.get("scale", 1.0))
    if abs(scale - 1.0) > 1e-6:
        src = src.resize((max(1, int(src.width * scale)), max(1, int(src.height * scale))),
                         Image.LANCZOS)
    if op.get("flip"):
        src = src.transpose(Image.FLIP_LEFT_RIGHT)
    rot = float(op.get("rotate", 0))
    if abs(rot) > 1e-6:
        src = src.rotate(rot, expand=True, resample=Image.BICUBIC)

    if "to_center" in op:
        cx, cy = [int(v) for v in op["to_center"]]
        tx, ty = cx - src.width // 2, cy - src.height // 2
    else:
        tx, ty = [int(v) for v in op["to"]]

    feather = int(op.get("feather", 6))
    mask = build_mask(src.size, feather)
    if float(op.get("opacity", 1.0)) < 1.0:
        mask = mask.point(lambda v: int(v * float(op["opacity"])))

    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    layer.paste(src, (tx, ty), src)
    # 只在这个矩形里应用羽化蒙版
    full_mask = Image.new("L", base.size, 0)
    full_mask.paste(mask, (tx, ty))
    layer.putalpha(full_mask)
    return Image.alpha_composite(base.convert("RGBA"), layer)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ops", default="")
    ap.add_argument("--from", dest="src_box", default="")
    ap.add_argument("--to", default="")
    ap.add_argument("--feather", type=int, default=6)
    args = ap.parse_args()

    img = Image.open(args.src).convert("RGBA")

    if args.ops:
        with open(args.ops, encoding="utf-8-sig") as f:
            ops = json.load(f)
        for i, op in enumerate(ops):
            img = apply_op(img, op)
            print(f"[stamp] {i + 1}/{len(ops)} ok")
    else:
        if not args.src_box or not args.to:
            raise SystemExit("要么给 --ops，要么同时给 --from 和 --to")
        box = [int(v) for v in args.src_box.split(",")]
        to = [int(v) for v in args.to.split(",")]
        img = apply_op(img, {"from": box, "to": to, "feather": args.feather})

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    img.save(args.out)
    print(f"[stamp] 写出 {args.out}  {img.size}")


if __name__ == "__main__":
    main()

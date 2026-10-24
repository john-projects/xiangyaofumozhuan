#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fix_map.py —— 修 AI 地图：补路 + 局部印章修补。

做三件事：
    1) paint_path：拿一块现有的石板纹理，沿折线"铺"出新路（自动羽化边，无硬接缝）
    2) stamp：印章克隆（复用 tools/img/stamp.py 的逻辑）
    3) 输出成品 + 前后对比图

用法：
    python tools/img/fix_map.py --src map.png --out fixed.png
"""

from __future__ import annotations

import argparse
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ── 采样哪块石板纹理当"路面" ────────────────────────────────────────────────
ROAD_TEX_BOX = (742, 664, 782, 704)     # 桥边那条路的石板（尺度和周围一致）
ROAD_WIDTH = 24                          # 路面宽度（像素）
ROAD_FEATHER = 10                        # 边缘羽化


def tiled_texture(tex: Image.Image, size: tuple[int, int], seed: int = 0) -> Image.Image:
    """把小块纹理镜像平铺成任意大小，避免明显重复。"""
    W, H = size
    tw, th = tex.size
    out = Image.new("RGB", (W, H))
    rng = np.random.default_rng(seed)
    y = 0
    row = 0
    while y < H:
        x = 0
        col = 0
        while x < W:
            tile = tex
            if (row + col) % 2 == 1:
                tile = tile.transpose(Image.FLIP_LEFT_RIGHT)
            if rng.random() < 0.35:
                tile = tile.transpose(Image.FLIP_TOP_BOTTOM)
            out.paste(tile, (x, y))
            x += tw
            col += 1
        y += th
        row += 1
    return out


def paint_path(img: Image.Image, pts: list[tuple[int, int]], width: int = ROAD_WIDTH,
               feather: int = ROAD_FEATHER, tex_box=ROAD_TEX_BOX,
               brightness: float = 1.0, seed: int = 3) -> Image.Image:
    """沿折线铺一条石板路。"""
    tex = img.crop(tex_box).convert("RGB")
    W, H = img.size

    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    for i in range(len(pts) - 1):
        d.line([pts[i], pts[i + 1]], fill=255, width=width, joint="curve")
    # 端点补圆，避免尖头
    r = width // 2
    for (x, y) in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(feather))

    tiled = tiled_texture(tex, (W, H), seed)
    if abs(brightness - 1.0) > 1e-6:
        arr = np.asarray(tiled, dtype=np.float32) * brightness
        tiled = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))

    return Image.composite(tiled, img.convert("RGB"), mask)


def erase_text(img: Image.Image, box, radius: int = 6, opacity: float = 0.9) -> Image.Image:
    """把一块区域"磨平"：中值模糊 + 少量噪声。

    用来抹掉 AI 画出来的乱码文字，同时保留石头的色调和颗粒，比整块克隆自然。
    """
    x0, y0, x1, y1 = [int(v) for v in box]
    patch = img.crop((x0, y0, x1, y1))
    flat = patch.filter(ImageFilter.MedianFilter(size=radius))
    arr = np.asarray(flat, dtype=np.float32)
    noise = np.random.default_rng(7).normal(0, 2.2, arr.shape[:2])[..., None]
    flat = Image.fromarray(np.clip(arr + noise, 0, 255).astype(np.uint8))
    out = img.copy()
    out.paste(Image.blend(patch, flat, opacity), (x0, y0))
    return out


def stamp(img: Image.Image, from_box, to, scale=1.0, flip=False, rotate=0.0,
          feather=6, opacity=1.0) -> Image.Image:
    """印章克隆（和 stamp.py 同一套逻辑）。"""
    x0, y0, x1, y1 = [int(v) for v in from_box]
    src = img.crop((x0, y0, x1, y1)).convert("RGBA")
    if abs(scale - 1.0) > 1e-6:
        src = src.resize((max(1, int(src.width * scale)), max(1, int(src.height * scale))),
                         Image.LANCZOS)
    if flip:
        src = src.transpose(Image.FLIP_LEFT_RIGHT)
    if abs(rotate) > 1e-6:
        src = src.rotate(rotate, expand=True, resample=Image.BICUBIC)

    mask = Image.new("L", src.size, 0)
    d = ImageDraw.Draw(mask)
    f = max(1, feather)
    d.rectangle([f, f, src.width - f, src.height - f], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(max(0.5, f * 0.6)))
    if opacity < 1.0:
        mask = mask.point(lambda v: int(v * opacity))

    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    layer.paste(src, (int(to[0]), int(to[1])), src)
    full = Image.new("L", img.size, 0)
    full.paste(mask, (int(to[0]), int(to[1])))
    layer.putalpha(full)
    return Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")


# ── 具体要补的路 ────────────────────────────────────────────────────────────
ROADS = [
    # 底部小桥：左端 → 接到广场石阶下来的那条路
    dict(pts=[(742, 700), (768, 716), (790, 726)], width=26, brightness=0.99, seed=11),
    # 底部小桥：右端 → 接到右侧横穿的那条路
    dict(pts=[(930, 728), (972, 714), (1010, 700)], width=26, brightness=1.0, seed=12),
    # 右下：横路 → 右岸平台（码头那条路）
    dict(pts=[(1010, 700), (1064, 676), (1108, 648)], width=28, brightness=1.0, seed=13),
]

# ── 局部印章修补 ────────────────────────────────────────────────────────────
STAMPS = [
    # 石碑乱码：用碑身左侧的石面反复盖，最后大羽化收边
    dict(**{"from": [111, 498, 140, 572]}, to=(133, 512), feather=4, opacity=1.0),
    dict(**{"from": [113, 502, 142, 576]}, to=(135, 516), feather=9, opacity=0.75),
    dict(**{"from": [110, 494, 139, 568]}, to=(131, 508), feather=12, opacity=0.55),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--compare", default="")
    args = ap.parse_args()

    img = Image.open(args.src).convert("RGB")
    before = img.copy()

    # ① 石碑乱码：先整体磨平（保留石头质感），再用印章补几处
    img = erase_text(img, (128, 506, 173, 583), radius=7, opacity=0.92)
    print("[fix] 石碑文字已磨平")

    for i, road in enumerate(ROADS):
        img = paint_path(img, road["pts"], width=road.get("width", ROAD_WIDTH),
                         brightness=road.get("brightness", 1.0),
                         seed=road.get("seed", i))
        print(f"[fix] 铺路 {i + 1}/{len(ROADS)}")

    for s in STAMPS:
        img = stamp(img, s["from"], s["to"], scale=s.get("scale", 1.0),
                    flip=s.get("flip", False), rotate=s.get("rotate", 0.0),
                    feather=s.get("feather", 6), opacity=s.get("opacity", 1.0))
    print(f"[fix] 印章 {len(STAMPS)} 处")

    img.save(args.out)
    print(f"[fix] 输出 {args.out} {img.size}")

    if args.compare:
        w, h = before.size
        canvas = Image.new("RGB", (w * 2 + 20, h), (20, 22, 24))
        canvas.paste(before, (0, 0))
        canvas.paste(img, (w + 20, 0))
        canvas.save(args.compare)
        print(f"[fix] 对比图 {args.compare}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""白底转透明：地图素材去背景（只删"和边缘连通"的白色，物件内部的白色保留）。

用法：
    python tools/img/white_to_alpha.py --src in.png --out out.png [--threshold 12]
"""

from __future__ import annotations

import argparse
from collections import deque

import numpy as np
from PIL import Image, ImageFilter


def remove_white_background(im: Image.Image, threshold: int = 12,
                            feather: float = 0.8) -> Image.Image:
    rgb = np.asarray(im.convert("RGB"), dtype=np.int16)
    h, w = rgb.shape[:2]

    # "白" = 三通道都接近 255
    white = (rgb.min(axis=2) >= 255 - threshold)

    # 只从边界往里泛洪，避免吃掉物件内部的白色（白墙、白幡）
    visited = np.zeros(h * w, dtype=bool)
    flat = white.reshape(-1)
    dq = deque()

    def push(x: int, y: int) -> None:
        i = y * w + x
        if flat[i] and not visited[i]:
            visited[i] = True
            dq.append(i)

    for x in range(w):
        push(x, 0)
        push(x, h - 1)
    for y in range(h):
        push(0, y)
        push(w - 1, y)

    while dq:
        i = dq.popleft()
        y, x = divmod(i, w)
        if x > 0:
            push(x - 1, y)
        if x < w - 1:
            push(x + 1, y)
        if y > 0:
            push(x, y - 1)
        if y < h - 1:
            push(x, y + 1)

    outside = visited.reshape(h, w)
    alpha = np.where(outside, 0, 255).astype(np.uint8)
    a_img = Image.fromarray(alpha, mode="L").filter(ImageFilter.GaussianBlur(feather))
    out = im.convert("RGBA")
    out.putalpha(a_img)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--threshold", type=int, default=12)
    args = ap.parse_args()

    im = Image.open(args.src)
    out = remove_white_background(im, args.threshold)
    out.save(args.out, optimize=True)
    print(f"[alpha] {args.src} -> {args.out} {out.size}")


if __name__ == "__main__":
    main()

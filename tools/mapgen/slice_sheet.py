#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""slice_sheet.py —— 把一张"素材图鉴"自动切成一个个透明 PNG。

为什么需要：AI 出的素材图鉴是一整张大图，图集里几十个物件贴在一起。
手工抠图既慢又不准；这里用**连通域**切：alpha 透明处当背景，剩下的连通块就是一个物件。

用法：
    python slice_sheet.py --input sheet.png --out out/raw --min-area 800
    python slice_sheet.py --input sheet.png --out out/raw --index out/index.png

输出：
    out/raw/slice_000.png ...   每个物件一张 RGBA
    out/raw/slices.json         每张的 bbox / 面积
    out/index.png               带编号的缩略总览（用来认东西、改名）
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict

import numpy as np
from PIL import Image, ImageDraw, ImageFont


# ── 连通域：按"行内游程 + 并查集"标号（不依赖 scipy/cv2）──────────────────
class DSU:
    def __init__(self, n: int):
        self.p = list(range(n))

    def find(self, x: int) -> int:
        p = self.p
        while p[x] != x:
            p[x] = p[p[x]]
            x = p[x]
        return x

    def union(self, a: int, b: int) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[max(ra, rb)] = min(ra, rb)


def label_runs(mask: np.ndarray) -> tuple[np.ndarray, int]:
    """返回 (labels, count)。labels 里 0 = 背景，1..count = 连通块。"""
    h, w = mask.shape
    labels = np.zeros((h, w), dtype=np.int32)
    dsu = DSU(1)
    next_label = 1
    prev_runs: list[tuple[int, int, int]] = []   # (start, end, label)

    for y in range(h):
        row = mask[y]
        if not row.any():
            prev_runs = []
            continue
        # 找这一行的所有游程
        idx = np.flatnonzero(np.diff(np.r_[False, row, False]))
        runs = []
        for i in range(0, len(idx), 2):
            runs.append((int(idx[i]), int(idx[i + 1])))

        cur_runs: list[tuple[int, int, int]] = []
        used_prev = set()
        for (s, e) in runs:
            # 和上一行有重叠的游程合并
            same = []
            for j, (ps, pe, pl) in enumerate(prev_runs):
                if ps < e and pe > s:
                    same.append((j, pl))
            if not same:
                lab = next_label
                next_label += 1
                dsu.p.append(lab)
            else:
                lab = min(pl for _, pl in same)
                for j, pl in same:
                    dsu.union(lab, pl)
                    used_prev.add(j)
            cur_runs.append((s, e, lab))
            labels[y, s:e] = lab
        prev_runs = cur_runs

    # 把并查集的根写回 labels
    flat = labels.reshape(-1)
    uniq = np.unique(flat)
    mapping = {}
    nxt = 1
    for u in uniq:
        if u == 0:
            continue
        r = dsu.find(int(u))
        if r not in mapping:
            mapping[r] = nxt
            nxt += 1
        flat[flat == u] = mapping[r]
    return labels, nxt - 1


def _flood_foreground(arr: np.ndarray, delta: float) -> np.ndarray:
    """从四条边做"局部颜色连续"的洪水填充，返回前景掩膜（True=物件）。

    背景是带纹理/渐变的米白，全局颜色阈值切不干净；但相邻像素颜色变化很小，
    所以"从边缘往外走、只走颜色跳变小的邻居"能把背景吃光，物件边缘挡住洪水。
    """
    from collections import deque
    h, w = arr.shape[:2]
    flat = arr.reshape(-1, 3)
    visited = np.zeros(h * w, dtype=bool)
    dq = deque()
    for x in range(w):
        for y in (0, h - 1):
            i = y * w + x
            if not visited[i]:
                visited[i] = True
                dq.append(i)
    for y in range(h):
        for x in (0, w - 1):
            i = y * w + x
            if not visited[i]:
                visited[i] = True
                dq.append(i)
    while dq:
        idx = dq.popleft()
        cy, cx = divmod(idx, w)
        base = flat[idx]
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            ny, nx = cy + dy, cx + dx
            if ny < 0 or ny >= h or nx < 0 or nx >= w:
                continue
            nidx = ny * w + nx
            if visited[nidx]:
                continue
            c = flat[nidx]
            if (abs(int(c[0]) - int(base[0])) <= delta
                    and abs(int(c[1]) - int(base[1])) <= delta
                    and abs(int(c[2]) - int(base[2])) <= delta):
                visited[nidx] = True
                dq.append(nidx)
    return (~visited).reshape(h, w)


def merge_close_boxes(components: list[dict], gap: int) -> list[dict]:
    """把包围盒重叠（或间距 <= gap）的连通块并成一个物件。

    ⚠ 必须用并查集一次性合并，不能"边遍历边链式合并"：
    图鉴里的碎片密集，链式合并会把整张图连成一个巨大的块。
    """
    n = len(components)
    if n <= 1:
        return components
    parent = list(range(n))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    # 只和"附近的"比较：先按 y 排序，滑动窗口内两两比较，避免 O(n²)
    # ⚠ 判据是"小框有 80% 被大框包住"才算同一个物件（碎片/装饰挂在主体上），
    #   不能只看包围盒相交 —— 图鉴里相邻物件的框天然会交叠，那样会把整张图连成一块。
    order = sorted(range(n), key=lambda i: components[i]["box"][1])
    for oi, i in enumerate(order):
        ax0, ay0, ax1, ay1 = components[i]["box"]
        for j in order[oi + 1:]:
            bx0, by0, bx1, by1 = components[j]["box"]
            if by0 > ay1 + gap:
                break
            ix = min(ax1, bx1) - max(ax0, bx0)
            iy = min(ay1, by1) - max(ay0, by0)
            if ix <= 0 or iy <= 0:
                continue
            inter = ix * iy
            small = min((ax1 - ax0) * (ay1 - ay0), (bx1 - bx0) * (by1 - by0))
            if inter > 0.8 * small:
                union(i, j)

    groups: dict[int, dict] = {}
    for i, c in enumerate(components):
        r = find(i)
        if r not in groups:
            groups[r] = {"box": c["box"], "area": c["area"], "ids": list(c["ids"])}
        else:
            g = groups[r]
            g["box"] = (min(g["box"][0], c["box"][0]), min(g["box"][1], c["box"][1]),
                        max(g["box"][2], c["box"][2]), max(g["box"][3], c["box"][3]))
            g["area"] += c["area"]
            g["ids"].extend(c["ids"])
    return list(groups.values())


def build_index(crops: list[tuple[int, Image.Image]], out_path: str, cols: int = 10):
    cell = 150
    rows = (len(crops) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows * (cell + 18)), (245, 246, 248))
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.load_default()
    except Exception:
        font = None
    for i, (idx, im) in enumerate(crops):
        cx = (i % cols) * cell
        cy = (i // cols) * (cell + 18)
        w, h = im.size
        scale = min((cell - 12) / max(1, w), (cell - 12) / max(1, h))
        thumb = im.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.LANCZOS)
        sheet.paste(thumb, (cx + (cell - thumb.width) // 2, cy + (cell - thumb.height) // 2),
                    thumb)
        d.text((cx + 6, cy + cell + 2), f"#{idx:03d}", fill=(30, 30, 30), font=font)
    sheet.save(out_path)


def main():
    ap = argparse.ArgumentParser(description="把素材图鉴切成透明 PNG")
    ap.add_argument("--input", required=True)
    ap.add_argument("--out", required=True, help="输出目录（会建 raw/）")
    ap.add_argument("--min-area", type=int, default=600, help="小于这个像素数的连通块丢掉")
    ap.add_argument("--bg-tol", type=float, default=8.0,
                    help="背景判定阈值：sat 模式=饱和度上限(×4)，grad 模式=梯度上限")
    ap.add_argument("--mode", default="sat", choices=["sat", "grad", "flood", "alpha"],
                    help="alpha=用现成的透明通道（无背景图鉴首选）；flood=边缘洪水填充；"
                         "sat=低饱和当背景；grad=局部平滑当背景")
    ap.add_argument("--alpha-threshold", type=int, default=120,
                    help="alpha 模式下，alpha 大于它算物件（背景常残留 0~60 的半透明）")
    ap.add_argument("--gap", type=int, default=0, help="包围盒间距小于它的连通块合并")
    ap.add_argument("--pad", type=int, default=2, help="裁切外留白")
    ap.add_argument("--index", default="", help="带编号的缩略图输出路径")
    ap.add_argument("--boxes", default="",
                    help="手工框 JSON：[{name, box:[x0,y0,x1,y1]}]，用于切不开的贴身物件")
    args = ap.parse_args()

    im = Image.open(args.input).convert("RGB")
    im_src = Image.open(args.input).convert("RGBA")
    arr = np.asarray(im).astype(np.int16)
    h, w = arr.shape[:2]

    # ① 背景判定
    #    alpha 模式：图本身就是"无背景"版，直接用透明通道（背景常残留 0~60 的半透明，
    #    所以用阈值 120 而不是 >0；输出保留原始软边，不重算 alpha）。
    #    flood（默认）：从画布边缘做"局部颜色连续"的洪水填充，最稳；
    #    sat：低饱和 + 高亮度当背景；grad：局部梯度低当背景。
    from PIL import ImageFilter
    if args.mode == "alpha":
        alpha_ch = np.asarray(im_src, dtype=np.uint8)[..., 3]
        fg = alpha_ch > args.alpha_threshold
        outside = ~fg
        im_rgba = im_src
        print(f"[stat] alpha_pixels fg={fg.mean() * 100:.1f}% thr={args.alpha_threshold}")
    elif args.mode == "flood":
        # 从画布边缘做"局部颜色连续"的洪水填充：只走到颜色变化很小的相邻像素。
        # 底色是纯白/米白/带纹理渐变都能一路吃干净；物件边缘颜色跳变大 → 洪水进不去。
        from collections import deque
        # ⚠ 必须是**一维**布尔数组：下面用的是 y*w+x 的扁平下标，
        #   写成二维会变成"按行索引"，直接 IndexError。
        visited = np.zeros(h * w, dtype=bool)
        dq = deque()
        for x in range(w):
            for y in (0, h - 1):
                idx = y * w + x
                if not visited[idx]:
                    visited[idx] = True
                    dq.append(idx)
        for y in range(h):
            for x in (0, w - 1):
                idx = y * w + x
                if not visited[idx]:
                    visited[idx] = True
                    dq.append(idx)
        delta = args.bg_tol * 3.0
        flat = arr.reshape(-1, 3)
        while dq:
            idx = dq.popleft()
            cy, cx = divmod(idx, w)
            base = flat[idx]
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                ny, nx = cy + dy, cx + dx
                if ny < 0 or ny >= h or nx < 0 or nx >= w:
                    continue
                nidx = ny * w + nx
                if visited[nidx]:
                    continue
                c = flat[nidx]
                if (abs(int(c[0]) - int(base[0])) <= delta
                        and abs(int(c[1]) - int(base[1])) <= delta
                        and abs(int(c[2]) - int(base[2])) <= delta):
                    visited[nidx] = True
                    dq.append(nidx)
        outside = visited.reshape(h, w)      # 一维 → 二维，后面要按图裁切
        fg = ~outside
        print(f"[stat] flood_outside={outside.mean() * 100:.1f}% fg={fg.mean() * 100:.1f}%")
    else:
        gray = np.asarray(im.convert("L"), dtype=np.float32)
        gx = np.zeros_like(gray)
        gy = np.zeros_like(gray)
        gx[:, 1:-1] = gray[:, 2:] - gray[:, :-2]
        gy[1:-1, :] = gray[2:, :] - gray[:-2, :]
        mag_smooth = np.asarray(
            Image.fromarray(np.clip(np.hypot(gx, gy), 0, 255).astype(np.uint8), mode="L")
            .filter(ImageFilter.BoxBlur(2)), dtype=np.float32)
        if args.mode == "grad":
            bg_like = mag_smooth < args.bg_tol
        else:
            hsv = np.asarray(im.convert("HSV"), dtype=np.int16)
            sat = hsv[..., 1].astype(np.float32)
            val = hsv[..., 2].astype(np.float32)
            bg_like = (sat < args.bg_tol * 4.0) & (val > 200.0)
        print(f"[stat] smooth_bg={bg_like.mean() * 100:.1f}% tol={args.bg_tol}")
        bg_labels, bg_count = label_runs(bg_like)
        border_labels = set(bg_labels[0, :].tolist()) | set(bg_labels[-1, :].tolist()) \
            | set(bg_labels[:, 0].tolist()) | set(bg_labels[:, -1].tolist())
        border_labels.discard(0)
        outside = np.isin(bg_labels, list(border_labels))
        fg = ~outside
        print(f"[stat] outside={outside.mean() * 100:.1f}% fg={fg.mean() * 100:.1f}%")

    # ③ RGBA：alpha 模式直接用原图（保留软边）；其它模式按前景掩膜重算并羽化
    if args.mode != "alpha":
        alpha_img = Image.fromarray((fg * 255).astype(np.uint8), mode="L") \
            .filter(ImageFilter.GaussianBlur(0.6))
        im_rgba = im.convert("RGBA")
        im_rgba.putalpha(alpha_img)

    labels, count = label_runs(fg)
    print(f"[stat] raw_components={count}")

    comps = []
    for lab in range(1, count + 1):
        ys, xs = np.where(labels == lab)
        if xs.size < args.min_area:
            continue
        comps.append({
            "box": (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1),
            "area": int(xs.size),
            "ids": [lab],
        })
    comps = merge_close_boxes(comps, args.gap)
    comps.sort(key=lambda c: (c["box"][1] // 120, c["box"][0]))
    print(f"[stat] merged={len(comps)}")

    raw = os.path.join(args.out, "raw")
    os.makedirs(raw, exist_ok=True)
    meta = []
    crops = []
    for i, c in enumerate(comps):
        x0, y0, x1, y1 = c["box"]
        x0 = max(0, x0 - args.pad); y0 = max(0, y0 - args.pad)
        x1 = min(im.width, x1 + args.pad); y1 = min(im.height, y1 + args.pad)
        crop = im_rgba.crop((x0, y0, x1, y1))
        name = f"slice_{i:03d}.png"
        crop.save(os.path.join(raw, name))
        meta.append({"file": name, "box": [x0, y0, x1, y1], "area": c["area"],
                     "w": crop.width, "h": crop.height})
        crops.append((i, crop))

    with open(os.path.join(raw, "slices.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    # ④ 手工框（可选）：图里有互相贴住的物件（房子压着树、码头压着船），
    #    连通域切不开，就按 --boxes 给的矩形直接裁。
    #    alpha **在裁剪区域内重新做一次洪水填充**（种子 = 该区域的四条边），
    #    这样被别的物件围住的背景也能清掉，不会留下灰块。
    if args.boxes:
        import json as _json
        with open(args.boxes, encoding="utf-8-sig") as f:
            boxes = _json.load(f)
        named_dir = os.path.join(args.out, "named")
        os.makedirs(named_dir, exist_ok=True)
        for item in boxes:
            x0, y0, x1, y1 = item["box"]
            x0 = max(0, int(x0)); y0 = max(0, int(y0))
            x1 = min(im.width, int(x1)); y1 = min(im.height, int(y1))
            rgb = im.crop((x0, y0, x1, y1))
            crop = rgb.convert("RGBA")
            mask = _flood_foreground(np.asarray(rgb).astype(np.int16), args.bg_tol * 3.0)
            a_img = Image.fromarray((mask * 255).astype(np.uint8), mode="L") \
                .filter(ImageFilter.GaussianBlur(0.6))
            crop.putalpha(a_img)
            crop.save(os.path.join(named_dir, f"{item['name']}.png"))
        print(f"[stat] manual={len(boxes)} -> {named_dir}")

    index_path = args.index or os.path.join(args.out, "index.png")
    build_index(crops, index_path)
    print(f"完成：{len(meta)} 张 → {raw}")
    print(f"编号总览 → {index_path}")


if __name__ == "__main__":
    main()

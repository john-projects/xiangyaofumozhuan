# -*- coding: utf-8 -*-
"""gen_terrain.py —— 生成一张 "7000×7000、有起伏的草地 + 一条河" 的 Blender 场景。

用法（命令行，无界面）：
    blender.exe -b --python gen_terrain.py -- --out out\terrain.blend --preview out\preview.png

产出：
    · Ground   —— 7000×7000 的起伏草地（带顶点色：高处偏黄绿、低处偏深绿）
    · River    —— 沿样条铺设的水面
    · RiverBed —— 河床（被压低的地面自然形成，材质偏沙色）
    · 相机（正交 30°）+ 太阳光 + 世界环境，直接能渲 2.5D 预览

说明：
    · 1 单位 = 1 米，7000×7000 = 7km²，相当于一个"区域"而不是一个村；
    · 起伏用 fbm 叠加，河流把地形往下压出河床，河岸做了平滑过渡；
    · 想改河道就改 RIVER_POINTS（归一化坐标，0~1）。
"""

from __future__ import annotations

import argparse
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Vector, noise

# 河道控制点（归一化 0~1，x 向右、y 向上/北），会插值成平滑曲线
RIVER_POINTS = [
    (0.06, 0.86), (0.22, 0.72), (0.38, 0.62), (0.52, 0.48),
    (0.64, 0.40), (0.78, 0.30), (0.94, 0.18),
]


def parse_args() -> dict:
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = {"out": "terrain.blend", "preview": "", "size": "7000",
            "grid": "512", "river_width": "210", "zoom": "1.5", "look_x": "0", "look_y": "0"}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--out", "--preview", "--size", "--grid", "--river-width",
                 "--zoom", "--look-x", "--look-y"):
            opts[a[2:].replace("-", "_")] = argv[i + 1]
            i += 1
        i += 1
    return opts


def log(msg: str) -> None:
    print(f"[terrain] {msg}", flush=True)


def catmull_rom(points: list[tuple[float, float]], samples_per_seg: int = 40):
    """把控制点插值成平滑折线（Catmull-Rom）。"""
    pts = [points[0]] + points + [points[-1]]
    out = []
    for i in range(len(pts) - 3):
        p0, p1, p2, p3 = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
        for s in range(samples_per_seg):
            t = s / samples_per_seg
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t
                       + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                       + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t
                       + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                       + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((x, y))
    out.append(points[-1])
    return out


def fbm(x: np.ndarray, y: np.ndarray, octaves: int = 5) -> np.ndarray:
    x = np.asarray(x, dtype=float).ravel()
    y = np.asarray(y, dtype=float).ravel()
    """分形噪声：多层噪声叠加，得到自然的起伏。"""
    total = np.zeros_like(x)
    amp, freq, norm = 1.0, 1.0, 0.0
    for i in range(octaves):
        total += amp * np.array([noise.noise(Vector((xx * freq, yy * freq, i * 13.7)))
                                 for xx, yy in zip(x, y)])
        norm += amp
        amp *= 0.5
        freq *= 2.05
    return total / norm


def make_material(name: str, color, roughness=0.9, use_attr=False):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = roughness
    if use_attr:
        attr = nt.nodes.new("ShaderNodeVertexColor")
        attr.layer_name = "Col"
        attr.location = (-500, 100)
        nt.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
    else:
        bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    return mat


def build_terrain(size: float, grid: int, river_w: float):
    half = size * 0.5
    # 归一化网格坐标 → 世界坐标
    lin = np.linspace(0.0, 1.0, grid)
    gx, gy = np.meshgrid(lin, lin)
    wx = (gx - 0.5) * size
    wy = (gy - 0.5) * size

    # ① 基础起伏：fbm + 一道整体缓坡
    h = fbm(wx * 0.0016, wy * 0.0016, octaves=5) * 52.0
    h += fbm(wx * 0.006, wy * 0.006, octaves=4) * 16.0
    h += fbm(wx * 0.02, wy * 0.02, octaves=3) * 3.5    # 近处的小起伏
    h += (1.0 - gy.ravel()) * 28.0    # 北高南低
    h = h.reshape(gx.shape)

    # ② 河道：算每个顶点到河道折线的最近距离
    path = catmull_rom(RIVER_POINTS, 30)
    px = np.array([(p[0] - 0.5) * size for p in path])
    py = np.array([(p[1] - 0.5) * size for p in path])
    pts = np.stack([wx.ravel(), wy.ravel()], axis=1)
    best = np.full(pts.shape[0], np.inf)
    for i in range(len(px) - 1):
        a = np.array([px[i], py[i]])
        b = np.array([px[i + 1], py[i + 1]])
        ab = b - a
        t = np.clip(((pts - a) @ ab) / max(1e-9, ab @ ab), 0.0, 1.0)
        proj = a + t[:, None] * ab
        d = np.linalg.norm(pts - proj, axis=1)
        best = np.minimum(best, d)
    dist = best.reshape(gx.shape)

    # ③ 河床：河心压到 -8，河岸 70 米内平滑过渡
    bank = river_w * 0.5
    carve = np.clip((bank + 260.0 - dist) / 260.0, 0.0, 1.0)
    carve = carve * carve * (3 - 2 * carve)          # smoothstep
    h = h * (1.0 - carve) + (-10.0) * carve
    # 河岸再压一点，避免岸壁太陡
    h -= np.clip((bank + 220.0 - dist) / 220.0, 0.0, 1.0) * 3.0

    # ④ 建网格
    verts = np.stack([wx.ravel(), wy.ravel(), h.ravel()], axis=1)
    faces = []
    for j in range(grid - 1):
        for i in range(grid - 1):
            a = j * grid + i
            faces.append((a, a + 1, a + grid + 1, a + grid))

    mesh = bpy.data.meshes.new("GroundMesh")
    mesh.from_pydata(verts.tolist(), [], faces)
    mesh.update()
    obj = bpy.data.objects.new("Ground", mesh)
    bpy.context.scene.collection.objects.link(obj)

    # ⑤ 顶点色：高处偏黄绿、河床偏沙色
    colors = []
    river_bed = (1.0 - np.clip(dist / (bank + 60.0), 0.0, 1.0)).ravel()
    for k in range(verts.shape[0]):
        hh = float(verts[k, 2])
        t = np.clip((hh + 8.0) / 34.0, 0.0, 1.0)
        grass = np.array([0.20 + 0.10 * t, 0.32 + 0.10 * t, 0.13 + 0.04 * t])
        sand = np.array([0.52, 0.46, 0.33])
        c = grass * (1.0 - river_bed[k] * 0.85) + sand * (river_bed[k] * 0.85)
        colors.append((float(c[0]), float(c[1]), float(c[2]), 1.0))
    attr = mesh.color_attributes.new(name="Col", type="FLOAT_COLOR", domain="POINT")
    attr.data.foreach_set("color", np.array(colors, dtype=np.float32).ravel())
    obj.data.materials.append(make_material("GrassMat", (0.3, 0.45, 0.25), 0.95, use_attr=True))
    log(f"地面：{grid}×{grid} 顶点，高度 {h.min():.1f} ~ {h.max():.1f} 米")

    # ⑥ 水面：沿河道铺一条带子
    wverts, wfaces = [], []
    half_w = river_w * 0.5
    for i in range(len(px) - 1):
        dx, dy = px[i + 1] - px[i], py[i + 1] - py[i]
        ln = max(1e-6, math.hypot(dx, dy))
        nx, ny = -dy / ln, dx / ln
        wverts.append((px[i] + nx * half_w, py[i] + ny * half_w, -2.0))
        wverts.append((px[i] - nx * half_w, py[i] - ny * half_w, -2.0))
    for i in range(len(px) - 2):
        a = i * 2
        wfaces.append((a, a + 1, a + 3, a + 2))
    wmesh = bpy.data.meshes.new("RiverMesh")
    wmesh.from_pydata(wverts, [], wfaces)
    wmesh.update()
    water = bpy.data.objects.new("River", wmesh)
    bpy.context.scene.collection.objects.link(water)
    water.data.materials.append(make_material("WaterMat", (0.16, 0.42, 0.52), 0.08))
    log(f"河流：{len(wverts)} 个顶点，宽 {river_w} 米")
    return obj


def setup_scene(size: float, zoom: float = 1.5, look=(0.0, 0.0)):
    scene = bpy.context.scene
    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.52, 0.62, 0.74, 1.0)
    bg.inputs[1].default_value = 0.45
    scene.view_settings.view_transform = "Filmic"
    scene.view_settings.look = "Medium High Contrast"

    sun_data = bpy.data.lights.new("Sun", type="SUN")
    sun_data.energy = 2.2
    sun_data.angle = math.radians(1.5)
    sun = bpy.data.objects.new("Sun", sun_data)
    scene.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(52), 0.0, math.radians(-38))

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    # ⚠ 默认 clip_end=100：正交相机离场景 8000 多米时地面会被裁掉，只剩世界底色
    cam_data.clip_start = 1.0
    cam_data.clip_end = size * 3.0
    # 45° 旋转后正方形的投影宽 ≈ size×√2，留点余量
    cam_data.ortho_scale = size * zoom
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    # 2.5D：俯角 30°、偏航 45°
    cam.rotation_euler = (math.radians(60.0), 0.0, math.radians(45.0))
    # 相机朝自身 -Z 看，位置要放在这个方向的反方向
    d = Vector(cam.rotation_euler.to_matrix() @ Vector((0, 0, -1)))
    # look 是归一化 0~1（原点在左下角），换成以场景中心为原点的世界坐标
    target = Vector(((look[0] - 0.5) * size, (look[1] - 0.5) * size, 0.0))
    cam.location = target - d * (size * 1.2)
    scene.camera = cam


def render_preview(path: str, samples: int = 24):
    scene = bpy.context.scene
    # ⚠ EEVEE 在 -b 无界面模式下拿不到 GPU 上下文，渲出来只有世界底色；预览改用 Cycles(CPU)
    scene.render.engine = "CYCLES"
    scene.cycles.samples = samples
    scene.cycles.use_denoising = False
    log(f"相机位置 {tuple(round(v) for v in scene.camera.location)}，"
        f"ortho {scene.camera.data.ortho_scale}")
    if hasattr(scene, "eevee"):
        try:
            scene.eevee.taa_render_samples = samples
        except AttributeError:
            pass
    scene.render.resolution_x = 1920
    scene.render.resolution_y = 960
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    log(f"预览已渲：{path}")


def main():
    opts = parse_args()
    size = float(opts["size"])
    grid = int(opts["grid"])
    river_w = float(opts["river_width"])
    out = os.path.abspath(opts["out"])
    preview = os.path.abspath(opts["preview"]) if opts["preview"] else ""

    bpy.ops.wm.read_factory_settings(use_empty=True)
    build_terrain(size, grid, river_w)
    setup_scene(size, float(opts['zoom']), (float(opts['look_x']), float(opts['look_y'])))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=out)
    log(f"场景已保存：{out}")
    if preview:
        render_preview(preview)


if __name__ == "__main__":
    main()

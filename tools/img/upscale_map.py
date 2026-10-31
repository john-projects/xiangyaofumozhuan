"""Geometry-preserving 4x map test using the installed Real-ESRGAN runtime."""
import argparse
import hashlib
import json
import time
from pathlib import Path

import cv2
import numpy as np
import torch
from PIL import Image, ImageDraw
from basicsr.archs.rrdbnet_arch import RRDBNet
from realesrgan import RealESRGANer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    source = Image.open(args.source).convert('RGBA')
    pixels = np.array(source)
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
                    num_block=6, num_grow_ch=32, scale=4)
    runner = RealESRGANer(scale=4, model_path=str(args.model), model=model,
                          tile=192, tile_pad=16, pre_pad=0, half=False,
                          device=torch.device('cuda' if torch.cuda.is_available() else 'cpu'))
    start = time.monotonic()
    rgb, _ = runner.enhance(pixels[:, :, :3][:, :, ::-1].copy(), outscale=4)
    # Alpha follows deterministic interpolation; never hallucinate terrain edges.
    size = (source.width * 4, source.height * 4)
    alpha = np.array(source.getchannel('A').resize(size, Image.Resampling.BICUBIC))
    result = Image.fromarray(np.dstack((rgb[:, :, ::-1], alpha)), 'RGBA')
    result.save(args.output)
    # Compare identical coordinates and pixel scale, against ordinary magnification.
    boxes = [(600, 270, 856, 462), (810, 620, 1066, 812), (360, 180, 616, 372)]
    comparison = Image.new('RGB', (2048, len(boxes) * 810), '#cdd2d8')
    draw = ImageDraw.Draw(comparison)
    for row, box in enumerate(boxes):
        top = row * 810
        left = source.crop(box).resize((1024, 768), Image.Resampling.BILINEAR)
        right = result.crop(tuple(v * 4 for v in box))
        comparison.paste(left, (0, top + 30), left)
        comparison.paste(right, (1024, top + 30), right)
        draw.text((16, top + 8), 'Original - ordinary 4x enlargement', fill='black')
        draw.text((1040, top + 8), 'Real-ESRGAN anime 6B - 4x super resolution', fill='black')
    comparison.save(args.output.parent / 'detail_comparison.png')
    result.thumbnail((1448, 1086), Image.Resampling.LANCZOS)
    result.save(args.output.parent / 'preview.png')
    report = dict(source=str(args.source), output=str(args.output),
                  source_size=source.size, output_size=size, scale=4,
                  model='RealESRGAN_x4plus_anime_6B', seconds=round(time.monotonic()-start, 2),
                  alpha='bicubic interpolation of original alpha; no changed layout',
                  model_sha256=hashlib.sha256(args.model.read_bytes()).hexdigest())
    (args.output.parent / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()

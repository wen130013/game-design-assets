#!/usr/bin/env python3
"""
[工具] 把成品地图图（map_political.png）切成瓦片（tile），供分块渲染。
每个瓦片 ≤1024×1024（手机纹理安全），边缘瓦片用海色补齐。
输出：assets/image/tiles/map_TX_TY.png
用法：python3 gen_tiles.py
"""
import os
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, 'assets', 'image', 'map_political.png')
OUT_DIR = os.path.join(ROOT, 'assets', 'image', 'tiles')
TILE = 1024
SEA = (156, 183, 212)  # 海色，补齐用

# 边缘出血：每块瓦片向外多带 PAD 源像素（与 MapRenderer.TILE_PAD 必须一致），
# 消除缩小时瓦片接缝处的横竖细线。
PAD = 4


def paste_tile_padded(img, x0, y0, size, out_path, fill):
    """切出 [x0,x0+size)² 并外扩 PAD 像素出血边，保存为 (size+2*PAD)²。越界处填 fill。"""
    w, h = img.size
    canvas = Image.new('RGB', (size + PAD * 2, size + PAD * 2), fill)
    sx0, sy0 = x0 - PAD, y0 - PAD
    cx0, cy0 = max(sx0, 0), max(sy0, 0)
    cx1, cy1 = min(sx0 + size + PAD * 2, w), min(sy0 + size + PAD * 2, h)
    if cx0 < cx1 and cy0 < cy1:
        canvas.paste(img.crop((cx0, cy0, cx1, cy1)), (cx0 - sx0, cy0 - sy0))
    canvas.save(out_path, optimize=True)


def main():
    im = Image.open(SRC).convert('RGB')
    w, h = im.size
    print(f'[Tiles] 成品图 {w}x{h}, 瓦片 {TILE}x{TILE}')
    os.makedirs(OUT_DIR, exist_ok=True)

    n = 0
    for ty in range(0, h, TILE):
        for tx in range(0, w, TILE):
            name = os.path.join(OUT_DIR, f'map_{tx // TILE}_{ty // TILE}.png')
            paste_tile_padded(im, tx, ty, TILE, name, SEA)
            n += 1

    print(f'[Tiles] 已生成 {n} 张瓦片（出血 {PAD}px）→ {OUT_DIR}')


if __name__ == '__main__':
    main()

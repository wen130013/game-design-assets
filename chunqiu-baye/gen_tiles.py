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


def main():
    im = Image.open(SRC).convert('RGB')
    w, h = im.size
    print(f'[Tiles] 成品图 {w}x{h}, 瓦片 {TILE}x{TILE}')
    os.makedirs(OUT_DIR, exist_ok=True)

    n = 0
    for ty in range(0, h, TILE):
        for tx in range(0, w, TILE):
            box = (tx, ty, min(tx + TILE, w), min(ty + TILE, h))
            tile = im.crop(box)
            # 补齐到 TILE×TILE
            if tile.size != (TILE, TILE):
                full = Image.new('RGB', (TILE, TILE), SEA)
                full.paste(tile, (0, 0))
                tile = full
            name = os.path.join(OUT_DIR, f'map_{tx // TILE}_{ty // TILE}.png')
            tile.save(name, optimize=True)
            n += 1

    print(f'[Tiles] 已生成 {n} 张瓦片 → {OUT_DIR}')


if __name__ == '__main__':
    main()

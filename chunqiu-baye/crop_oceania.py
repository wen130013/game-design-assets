#!/usr/bin/env python3
"""
[工具] 从 world_map_base.png 挖掉大洋洲（澳大利亚等），保留欧亚非。
原理：右下角独立大陆（大洋洲）是连通块，挖掉后填海色。
输出：assets/image/eurasia_africa_base.png
用法：python3 crop_oceania.py
"""
import os
from collections import deque

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, 'assets', 'image', 'world_map_base.png')
OUT = os.path.join(ROOT, 'assets', 'image', 'eurasia_africa_base.png')
SEA = (156, 183, 212)


def main():
    im = Image.open(SRC).convert('RGB')
    arr = np.array(im)
    h, w = arr.shape[:2]
    sea = (abs(arr[:, :, 0].astype(int) - 156) < 12) \
        & (abs(arr[:, :, 1].astype(int) - 183) < 12) \
        & (abs(arr[:, :, 2].astype(int) - 212) < 12)
    land = ~sea
    print(f'[Crop] 底图 {w}x{h}')

    # 只分析右下半区（x>6500, y>4000）找大洋洲连通块
    visited = np.zeros((h, w), dtype=bool)
    oceania = set()
    for y in range(4200, h):
        for x in range(6500, w):
            if land[y, x] and not visited[y, x]:
                q = deque([(y, x)])
                visited[y, x] = True
                cells = []
                while q:
                    cy, cx = q.popleft()
                    cells.append((cy, cx))
                    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < h and 0 <= nx < w and not visited[ny, nx] and land[ny, nx]:
                            visited[ny, nx] = True
                            q.append((ny, nx))
                if len(cells) > 2000:
                    ys = [c[0] for c in cells]
                    xs = [c[1] for c in cells]
                    print(f'[Crop] 右下半区连通块: {len(cells)}px, y[{min(ys)},{max(ys)}] x[{min(xs)},{max(xs)}]')
                    # 大洋洲 = 位于右下角的大块（y 范围偏下 + 独立）
                    if min(ys) > 4500:
                        for c in cells:
                            oceania.add(c)

    print(f'[Crop] 大洋洲像素: {len(oceania)}')

    # 挖掉：填海色
    for y, x in oceania:
        arr[y, x] = SEA

    out = Image.fromarray(arr, 'RGB')
    out.save(OUT, optimize=True)
    print(f'[Crop] 已保存 {OUT}')


if __name__ == '__main__':
    main()

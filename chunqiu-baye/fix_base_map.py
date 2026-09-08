#!/usr/bin/env python3
"""
[工具] 修复欧亚非底图：只挖左上角北极/格陵兰独立小岛。
从 eurasia_africa_base.png（已无大洋洲）读取，覆盖写回。
不碰海南岛（天然独立）、台湾等其他区域。
用法：python3 fix_base_map.py
"""
import os
from collections import deque

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, 'assets', 'image', 'eurasia_africa_base.png')
SEA = (156, 183, 212)


def main():
    im = Image.open(SRC).convert('RGB')
    arr = np.array(im)
    h, w = arr.shape[:2]
    sea = (abs(arr[:, :, 0].astype(int) - 156) < 12) \
        & (abs(arr[:, :, 1].astype(int) - 183) < 12) \
        & (abs(arr[:, :, 2].astype(int) - 212) < 12)
    land = ~sea
    print(f'[Fix] 底图 {w}x{h}')

    # 只扫描左上角 x<1200, y<700（北极/格陵兰岛区域）
    label = np.zeros((h, w), dtype=np.int32)
    cid = 0
    removed = 0
    for y in range(0, 700):
        for x in range(0, 1200):
            if land[y, x] and label[y, x] == 0:
                cid += 1
                q = deque([(y, x)])
                label[y, x] = cid
                cells = []
                while q:
                    cy, cx = q.popleft()
                    cells.append((cy, cx))
                    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < h and 0 <= nx < w and land[ny, nx] and label[ny, nx] == 0:
                            label[ny, nx] = cid
                            q.append((ny, nx))
                if len(cells) > 3000:
                    for cy, cx in cells:
                        arr[cy, cx] = SEA
                        land[cy, cx] = False
                    removed += len(cells)
                    ys = [c[0] for c in cells]
                    xs = [c[1] for c in cells]
                    print(f'[Fix] 挖掉北极岛: {len(cells)}px, y[{min(ys)},{max(ys)}] x[{min(xs)},{max(xs)}]')
    print(f'[Fix] 北极/格陵兰岛共挖掉 {removed}px')

    Image.fromarray(arr, 'RGB').save(SRC, optimize=True)
    print(f'[Fix] 已保存 {SRC}')


if __name__ == '__main__':
    main()

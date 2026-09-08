#!/usr/bin/env python3
"""
[工具] 生成世界成品地图图（map_political.png）。
世界 213 区域先用高区分度颜色显示（HSV 色相均匀分布）；
边界线/海岸线检测与 gen_final_map.py 相同（4 邻）。
时代剧本就绪后，由时代归属表覆盖区域颜色。
依赖：pip install pillow numpy
"""
import os
import colorsys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC_BITMAP = os.path.join(ROOT, 'assets', 'image', 'world_province_id.png')
OUT_MAP = os.path.join(ROOT, 'assets', 'image', 'map_political.png')

SEA = (156, 183, 212)      # 海色
BORDER = (35, 35, 42)      # 边界线色（深灰）
COAST = (120, 150, 180)    # 海岸线色


def palette_for(n):
    """生成 n 个高区分度颜色（HSV 色相均匀分布）"""
    colors = [None] * (n + 1)
    for i in range(1, n + 1):
        hue = (i * 0.618033988749895) % 1.0   # 黄金角分布，避免相邻同色
        r, g, b = colorsys.hsv_to_rgb(hue, 0.62, 0.92)
        colors[i] = (int(r * 255), int(g * 255), int(b * 255))
    return colors


def main():
    src = Image.open(SRC_BITMAP).convert('RGB')
    w, h = src.size
    print(f'[WorldFinal] 位图 {w}x{h}')
    arr = np.array(src)
    ids = arr[:, :, 1].astype(np.int32) * 256 + arr[:, :, 2].astype(np.int32)

    n_regions = int(ids.max())
    colors = palette_for(n_regions)
    print(f'[WorldFinal] 区域数 {n_regions}')

    # 填色：海=SEA，区域=调色板
    color_arr = np.zeros((h, w, 3), dtype=np.uint8)
    color_arr[:] = SEA
    for i in range(1, n_regions + 1):
        mask = ids == i
        if mask.any():
            color_arr[mask] = colors[i]

    # 边界检测（右邻/下邻）
    kR = np.roll(ids, -1, axis=1)
    kR[:, -1] = -1
    diffR = (ids != kR) & (ids >= 0) & (kR >= 0)
    kD = np.roll(ids, -1, axis=0)
    kD[-1, :] = -1
    diffD = (ids != kD) & (ids >= 0) & (kD >= 0)
    border = diffR | diffD

    is_sea = ids == 0
    coast = (border & diffR & ((is_sea & (kR > 0)) | ((~is_sea) & (kR == 0)))) \
          | (border & diffD & ((is_sea & (kD > 0)) | ((~is_sea) & (kD == 0))))
    land_border = border & (~coast)

    color_arr[coast] = COAST
    color_arr[land_border] = BORDER

    Image.fromarray(color_arr, 'RGB').save(OUT_MAP, optimize=True)
    print(f'[WorldFinal] 已写 {OUT_MAP}')
    print(f'[WorldFinal] 边界 {int(land_border.sum())}px, 海岸 {int(coast.sum())}px')


if __name__ == '__main__':
    main()

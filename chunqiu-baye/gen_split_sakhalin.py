#!/usr/bin/env python3
"""
[工具] 把库页岛与外东北分离（挖开鞑靼海峡）。
只修改 province_id.png 中连接库页岛与大陆的"陆地桥"像素为海洋(id=0)，
其余位置不动。库页岛保留区 = 位图东北角 (x>=3895, y<=75)。
用法：python3 gen_split_sakhalin.py
"""
import os
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, 'assets', 'image', 'province_id.png')

# 库页岛保留区（东北角）：x>=3895 且 y<=75 的陆地视为库页岛
SAK_X0 = 3895
SAK_Y1 = 75


def main():
    im = Image.open(SRC).convert('RGB')
    arr = np.array(im)
    h, w = arr.shape[:2]
    ids = arr[:, :, 1].astype(np.int32) * 256 + arr[:, :, 2].astype(np.int32)
    land = ids > 0
    orig_land = land.sum()

    def ascii_view(y0, y1, x0, x1, land_arr):
        for y in range(y0, y1, 2):
            row = ''.join('#' if land_arr[y, x] else '.' for x in range(x0, x1, 2))
            print(f'  y={y:3d} {row}')

    print('[Split] 处理前东北角地形:')
    ascii_view(40, 80, 3700, 4096, land)

    # 迭代挖桥：库页岛保留区内、与区外陆地(大陆)4邻相邻的像素 → 挖成海
    in_sak = np.zeros((h, w), bool)
    in_sak[:, SAK_X0:] = land[:, SAK_X0:]
    in_sak[SAK_Y1+1:, :] = False  # y > SAK_Y1 不算库页岛

    carved = 0
    changed = True
    guard = 0
    while changed and guard < 1000:
        changed = False
        guard += 1
        # 找出库页岛保留区中与"区外陆地"相邻的像素（4邻）
        outer_land = land & (~in_sak)
        # 对每个库页岛像素，检查4邻是否有 outer_land
        cand = in_sak & land
        ys, xs = np.where(cand)
        for y, x in zip(ys, xs):
            y0 = max(0, y-1); y1 = min(h, y+2)
            x0 = max(0, x-1); x1 = min(w, x+2)
            nb = outer_land[y0:y1, x0:x1]
            if nb.any():
                # 挖掉
                land[y, x] = False
                in_sak[y, x] = False
                carved += 1
                changed = True

    print(f'[Split] 挖掉的连接像素: {carved}')

    # 南侧海峡加宽：库页岛南端与大陆之间原本只有 1px 海（y=75），
    # 拉远时会被采样成"焊接"。把 y[73,78] x[3870,4096] 强制挖成海，
    # 使海峡有约 6px 宽（库页岛南端收回 2px、大陆北缘后退 3px，视觉无伤）。
    south = np.zeros((h, w), bool)
    south[73:79, 3870:4096] = True
    carve_south = south & land
    n_south = int(carve_south.sum())
    land[carve_south] = False
    print(f'[Split] 南侧海峡加宽挖掉: {n_south} 像素')

    # 西侧海峡带清理：x[3840,3896] y[40,78] 内的残余碎块全部挖成海，
    # 保证海峡干净连贯（库页岛主体 x>=3897 不受影响）。
    strait = np.zeros((h, w), bool)
    strait[40:79, 3840:3897] = True
    carve_strait = strait & land
    n_str = int(carve_strait.sum())
    land[carve_strait] = False
    print(f'[Split] 西侧海峡碎块清理: {n_str} 像素')

    # 验证：重新检查库页岛保留区是否与大陆分离
    # 从库页岛主体做 BFS，看能否到达大陆(区外陆地)
    def bfs_reachable(start_land, target_land):
        visited = start_land.copy()
        stack = list(zip(*np.where(start_land)))
        while stack:
            y, x = stack.pop()
            for dy, dx in ((1,0),(-1,0),(0,1),(0,-1)):
                ny, nx = y+dy, x+dx
                if 0 <= ny < h and 0 <= nx < w and not visited[ny, nx] and land[ny, nx]:
                    if target_land[ny, nx]:
                        return True
                    visited[ny, nx] = True
                    stack.append((ny, nx))
        return False

    sak_now = np.zeros((h, w), bool)
    sak_now[:, SAK_X0:] = land[:, SAK_X0:]
    sak_now[SAK_Y1+1:, :] = False
    outer = land & (~sak_now)
    connected = bfs_reachable(sak_now, outer)
    print(f'[Split] 分离后库页岛与大陆是否仍连通: {connected}')

    print('[Split] 处理后东北角地形:')
    ascii_view(40, 80, 3700, 4096, land)

    if connected:
        print('[Split] ❌ 仍连通，需要扩大挖桥范围')
        return

    # 写回位图：把 land 为 False 但 ids>0 的像素改为海(id=0, RGB(0,0,0))
    new_ids = np.where(land, ids, 0)
    arr[:, :, 1] = (new_ids >> 8) & 0xFF
    arr[:, :, 2] = new_ids & 0xFF
    arr[:, :, 0] = 0  # R 恒 0

    Image.fromarray(arr, 'RGB').save(SRC, optimize=True)
    print(f'[Split] ✅ 已保存 {SRC}')
    print(f'[Split] 陆地像素 {orig_land} → {land.sum()}（减少 {orig_land - land.sum()}）')


if __name__ == '__main__':
    main()

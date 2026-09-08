#!/usr/bin/env python3
"""
[工具] 生成成品政治地图位图（map_political.png，4096×2603）。
把"省 ID 位图 → 显示色 → 边界线/海岸线"全部烘焙成一张 RGB 成品图：
  * 每个像素 = 最终显示色（sRGB），大地图用 NanoVG 直接贴图显示
  * 边界检测与 ParadoxMap shader 一致：同势力不画内线，海陆交界画海岸
  * 成品图 = 位图逐像素生成 → 与点击检测（位图查 ID）完全同源，无错位
  * 颜色 = 小地图同款色板（scripts/map/MapRenderer.lua 的 FACTION_GEO_COLORS），
    确保大地图与小地图显示完全一致
数据源：
  * assets/image/province_id.png  省 ID 位图（R=0, G=id>>8, B=id&0xFF；id=0 海洋）
  * scripts/data/GeneratedFactions.lua  势力归属（省→势力）
  * scripts/map/MapRenderer.lua  FACTION_GEO_COLORS（小地图同款色板）
依赖：pip install pillow numpy
"""
import os
import re

import numpy as np
from PIL import Image

SEA = (156, 183, 212)      # 海色（与 shader SEA_COLOR 一致）
LAND = (210, 196, 158)     # 无主陆地默认色（羊皮纸米色）
BORDER = (35, 35, 42)      # 势力边界线色（深灰）
COAST = (120, 150, 180)    # 海岸线色（比海色略深）

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC_BITMAP = os.path.join(ROOT, 'assets', 'image', 'province_id.png')
OUT_MAP = os.path.join(ROOT, 'assets', 'image', 'map_political.png')


def parse_factions():
    """返回 (pid_to_fid, fid_to_color)：
       pid_to_fid: 省 id → 势力 id
       fid_to_color: 势力 id → 势力色 (r,g,b)（从小地图同款色板 FACTION_GEO_COLORS 提取）"""
    pid_to_fid = {}
    fac_path = os.path.join(ROOT, 'scripts', 'data', 'GeneratedFactions.lua')
    with open(fac_path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            m = re.match(r'\{id=(\d+),', line)
            if not m or 'provinces={' not in line:
                continue
            fid = int(m.group(1))
            pm = re.search(r'provinces=\{([\d,]+)\}', line)
            if not pm:
                continue
            for pid_s in pm.group(1).split(','):
                if pid_s:
                    pid_to_fid[int(pid_s)] = fid

    # 小地图同款色板：scripts/map/MapRenderer.lua 的 FACTION_GEO_COLORS
    fid_to_color = {}
    mr_path = os.path.join(ROOT, 'scripts', 'map', 'MapRenderer.lua')
    with open(mr_path, encoding='utf-8') as f:
        in_geo = False
        for line in f:
            if 'FACTION_GEO_COLORS' in line:
                in_geo = True
                continue
            if in_geo:
                if '}' in line and '=' not in line:
                    break
                cm = re.match(r'\s*\[(\d+)\]\s*=\s*\{\s*(\d+),\s*(\d+),\s*(\d+)\}', line)
                if cm:
                    fid_to_color[int(cm.group(1))] = (int(cm.group(2)), int(cm.group(3)), int(cm.group(4)))
    print(f"[FinalMap] FACTION_GEO_COLORS 势力色板 {len(fid_to_color)} 个")
    return pid_to_fid, fid_to_color


def main():
    pid_to_fid, fid_to_color = parse_factions()
    print(f"[FinalMap] 势力覆盖省份 {len(pid_to_fid)} 个")

    src = Image.open(SRC_BITMAP).convert('RGB')
    w, h = src.size
    print(f"[FinalMap] 位图 {w}x{h}")
    arr = np.array(src)  # HxWx3

    # ---- 1. 解码省 ID：G*256 + B ----
    ids = arr[:, :, 1].astype(np.int32) * 256 + arr[:, :, 2].astype(np.int32)

    # ---- 2. 势力键查找表（与 shader 一致）：海洋=0；有主=势力id；无主=256+id ----
    pid_arr = np.array(list(pid_to_fid.keys()), dtype=np.int32)
    fid_arr = np.array(list(pid_to_fid.values()), dtype=np.int32)
    lookup = np.zeros(65536, dtype=np.int32)   # 省 id → 势力 id（无主=0）
    if len(pid_arr):
        lookup[pid_arr] = fid_arr

    owned = lookup[ids]                        # 每像素的势力 id（无主/海洋=0）
    keys = np.where(ids == 0, 0,
                    np.where(owned > 0, owned, 256 + ids))

    # ---- 3. 填色：海洋=SEA；有主=小地图色板色；无主陆地=LAND ----
    color_arr = np.zeros((h, w, 3), dtype=np.uint8)
    color_arr[:] = LAND                        # 默认无主陆地色
    color_arr[ids == 0] = SEA                  # 海洋
    clookup = np.zeros((65536, 3), dtype=np.uint8)
    for fid, c in fid_to_color.items():
        clookup[fid] = c
    is_owned = owned > 0
    color_arr[is_owned] = clookup[owned[is_owned]]

    # ---- 4. 边界检测：比较右邻/下邻的势力键（覆盖所有相邻对） ----
    kR = np.roll(keys, -1, axis=1)
    kR[:, -1] = -1                             # 最右列无右邻
    diffR = (keys != kR) & (keys >= 0) & (kR >= 0)
    kD = np.roll(keys, -1, axis=0)
    kD[-1, :] = -1                             # 最下行无下邻
    diffD = (keys != kD) & (keys >= 0) & (kD >= 0)

    border_mask = diffR | diffD                # 任一方向势力键不同 = 边界
    # 海陆交界（一侧海洋一侧陆地）→ 海岸线；其余 → 势力边界线
    is_sea = keys == 0
    coast_mask = (border_mask & diffR & ((is_sea & (kR > 0)) | ((~is_sea) & (kR == 0)))) \
               | (border_mask & diffD & ((is_sea & (kD > 0)) | ((~is_sea) & (kD == 0))))
    land_border = border_mask & (~coast_mask)

    color_arr[coast_mask] = COAST
    color_arr[land_border] = BORDER

    # ---- 5. 输出 ----
    out = Image.fromarray(color_arr, 'RGB')
    out.save(OUT_MAP, optimize=True)
    n_sea = int((ids == 0).sum())
    n_land = int((ids > 0).sum())
    n_border = int(land_border.sum())
    n_coast = int(coast_mask.sum())
    print(f"[FinalMap] 已写 {OUT_MAP}: {w}x{h}")
    print(f"[FinalMap] 海洋 {n_sea}px, 陆地 {n_land}px, 边界 {n_border}px, 海岸 {n_coast}px")


if __name__ == '__main__':
    main()

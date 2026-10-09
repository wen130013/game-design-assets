#!/usr/bin/env python3
"""
[工具] 势力版图生成：地图瓦片按势力归属着色（历史时代3 / EU4 开局观感）。
规则：
  * 海 → 海色；外围沙漠省 → 沙漠色
  * 可玩区有主省 → 所属势力颜色（GeneratedFactions.color）
  * 可玩区无主省 → 浅灰（无主荒地）
  * 边界：不同"势力组"相邻画深灰线；沙漠省间不画；海陆交界画海岸线
产出：覆盖 assets/image/eu4/map_political.png + 瓦片（地图包 BITMAP_PATH 不变）
依赖：pip install pillow numpy
"""
import glob
import os
import re

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
ASSET_DIR = os.path.join(ROOT, "assets", "image", "eu4")
TILE_DIR = os.path.join(ASSET_DIR, "tiles")
DATA_DIR = os.path.join(ROOT, "scripts", "data", "mappacks", "eu4")

SEA = (156, 183, 212)
DESERT = (200, 162, 98)
UNOWNED = (210, 196, 158)       # 无主荒地（米色）
BORDER = (52, 50, 44)           # 省/势力边界线
COAST = (118, 148, 178)         # 海岸线


def load_factions():
    """GeneratedFactions: {fid: {name, color, provinces:set}}"""
    factions = {}
    txt = open(os.path.join(ROOT, "scripts", "data", "GeneratedFactions.lua"), encoding="utf-8").read()
    for m in re.finditer(
        r"\{id=(\d+),name=\"([^\"]*)\",.*?color=\{(\d+),(\d+),(\d+),\d+\},provinces=\{([^}]*)\}",
        txt,
    ):
        fid = int(m.group(1))
        provs = {int(x) for x in m.group(6).split(",") if x}
        factions[fid] = {
            "name": m.group(2),
            "color": (int(m.group(3)), int(m.group(4)), int(m.group(5))),
            "provinces": provs,
        }
    return factions


def load_wasteland():
    """省份数据中的沙漠标记: set(pid)"""
    waste = set()
    for f in glob.glob(os.path.join(DATA_DIR, "Provinces_*.lua")):
        for line in open(f, encoding="utf-8").read().split("\n"):
            m = re.match(r"\{id=(\d+).*?isWasteland=true", line)
            if m:
                waste.add(int(m.group(1)))
    return waste


# 边缘出血：每块瓦片向外多带 PAD 源像素（与 MapRenderer.TILE_PAD 必须一致），
# 消除缩小时瓦片接缝处的横竖细线。
PAD = 4


def paste_tile_padded(img, x0, y0, size, out_path, fill):
    """切出 [x0,x0+size)² 并外扩 PAD 像素出血边，保存为 (size+2*PAD)²。越界处填 fill。"""
    w, h = img.size
    canvas = Image.new("RGB", (size + PAD * 2, size + PAD * 2), fill)
    sx0, sy0 = x0 - PAD, y0 - PAD
    cx0, cy0 = max(sx0, 0), max(sy0, 0)
    cx1, cy1 = min(sx0 + size + PAD * 2, w), min(sy0 + size + PAD * 2, h)
    if cx0 < cx1 and cy0 < cy1:
        canvas.paste(img.crop((cx0, cy0, cx1, cy1)), (cx0 - sx0, cy0 - sy0))
    canvas.save(out_path, optimize=True)



def main():
    factions = load_factions()
    waste = load_wasteland()
    owned = {}
    for fid, f in factions.items():
        for pid in f["provinces"]:
            owned[pid] = fid
    print(f"[Political] 势力 {len(factions)} 个, 有主省 {len(owned)}, 沙漠省 {len(waste)}")

    ids_img = np.array(Image.open(os.path.join(ASSET_DIR, "province_id.png")))
    ids = ids_img[:, :, 1].astype(np.int32) * 256 + ids_img[:, :, 2].astype(np.int32)
    H, W = ids.shape

    # 每个省的"势力组键":海=-1, 沙漠=0, 有主=fid, 无主=-2
    group = np.zeros(ids.max() + 1, dtype=np.int32)
    for pid in range(1, ids.max() + 1):
        if pid in waste:
            group[pid] = 0
        elif pid in owned:
            group[pid] = owned[pid]
        else:
            group[pid] = -2

    # 着色
    color = np.zeros((ids.max() + 1, 3), dtype=np.uint8)
    color[0] = SEA
    for pid in range(1, ids.max() + 1):
        if group[pid] == 0:
            color[pid] = DESERT
        elif group[pid] == -2:
            color[pid] = UNOWNED
        else:
            color[pid] = factions[group[pid]]["color"]

    color_arr = color[ids]
    is_sea = ids == 0

    # 省界检测（2026-09-01：改为"省 ID 级"边界，画每个省之间的界线）
    #   海=-1，沙漠省统一键 0（沙漠省间不画），其余=省 ID（省与省之间均画界）
    gb = np.full(ids.max() + 1, -1, dtype=np.int32)
    for pid in range(1, ids.max() + 1):
        gb[pid] = 0 if pid in waste else pid
    gb_px = np.full((H, W), -1, dtype=np.int32)
    gb_px[~is_sea] = gb[ids[~is_sea]]

    # 边界检测（右/下邻）
    kR = np.roll(gb_px, -1, axis=1)
    kR[:, -1] = -1
    diffR = (gb_px != kR) & (gb_px >= 0) & (kR >= 0)
    kD = np.roll(gb_px, -1, axis=0)
    kD[-1, :] = -1
    diffD = (gb_px != kD) & (gb_px >= 0) & (kD >= 0)

    # 2026-09-13（F0 症状②）：边界改成"跨边界对称 2px"——一对像素两侧各画 1px。
    #
    # 为什么：diffR/diffD 标记的是这一对里**低索引**的那一颗（左/上），所以原来的
    # 1px 黑带中心在 (i+0.5)，而真实边界（像素角）在 i+1 → 系统性偏 0.5px。
    # 运行时的矢量省界环正是按"像素角"生成的（gen_province_rings.py），
    # 于是金色的国境描边永远压在黑带旁边（放大后肉眼可见）。
    # 两侧各画 1px 后黑带中心 == 真实边界 == 矢量线，天然对齐、不再需要偏移 hack。
    #
    # ⚠️ 只能沿边界方向扩展：竖边界往右补一颗、横边界往下补一颗；
    #    若不分方向地"向右+向下"扩张，会把横边界的每一颗都向右糊一格 → 线变粗一圈。
    def _shift_right(m):
        out = np.roll(m, 1, axis=1)
        out[:, 0] = False
        return out

    def _shift_down(m):
        out = np.roll(m, 1, axis=0)
        out[0, :] = False
        return out

    border = diffR | _shift_right(diffR) | diffD | _shift_down(diffD)

    # 海岸线：**当前是死代码**（保留原样，不在本次改动范围）。
    # gb_px 里海洋 = -1，而 diffR/diffD 要求两侧都 >= 0，所以这里的条件永远不成立
    # → 底图实际没有画海岸线，海陆交界只是纯色切换。若以后要加海岸线，
    # 需要单独按 is_sea 与陆地 id 比较来取边界（并同样是"跨边界对称"）。
    coast = (border & diffR & ((is_sea & (kR > 0)) | ((~is_sea) & (kR == -1)))) \
          | (border & diffD & ((is_sea & (kD > 0)) | ((~is_sea) & (kD == -1))))
    land_border = border & (~coast)
    color_arr[coast] = COAST
    color_arr[land_border] = BORDER

    out = os.path.join(ASSET_DIR, "map_political.png")
    Image.fromarray(color_arr, "RGB").save(out, optimize=True)
    print(f"[Political] 已写势力版图 {out}")

    # 瓦片（带边缘出血 PAD，消除缩小时接缝；文件名 map_TX_TY.png）
    os.makedirs(TILE_DIR, exist_ok=True)
    TILE = 1024
    out_img = Image.fromarray(color_arr)
    n = 0
    for ty in range(0, H, TILE):
        for tx in range(0, W, TILE):
            name = os.path.join(TILE_DIR, f"map_{tx // TILE}_{ty // TILE}.png")
            paste_tile_padded(out_img, tx, ty, TILE, name, SEA)
            n += 1
    print(f"[Political] 瓦片 {n} 张（出血 {PAD}px）→ {TILE_DIR}")


if __name__ == "__main__":
    main()

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
    border = diffR | diffD
    coast = (border & diffR & ((is_sea & (kR > 0)) | ((~is_sea) & (kR == -1)))) \
          | (border & diffD & ((is_sea & (kD > 0)) | ((~is_sea) & (kD == -1))))
    land_border = border & (~coast)
    color_arr[coast] = COAST
    color_arr[land_border] = BORDER

    out = os.path.join(ASSET_DIR, "map_political.png")
    Image.fromarray(color_arr, "RGB").save(out, optimize=True)
    print(f"[Political] 已写势力版图 {out}")

    # 瓦片
    os.makedirs(TILE_DIR, exist_ok=True)
    TILE = 1024
    n = 0
    for ty in range(0, H, TILE):
        for tx in range(0, W, TILE):
            box = (tx, ty, min(tx + TILE, W), min(ty + TILE, H))
            tile = Image.fromarray(color_arr).crop(box)
            if tile.size != (TILE, TILE):
                full = Image.new("RGB", (TILE, TILE), SEA)
                full.paste(tile, (0, 0))
                tile = full
            name = os.path.join(TILE_DIR, f"map_{tx // TILE}_{ty // TILE}.png")
            tile.save(name, optimize=True)
            n += 1
    print(f"[Political] 瓦片 {n} 张 → {TILE_DIR}")


if __name__ == "__main__":
    main()

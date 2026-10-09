#!/usr/bin/env python3
"""边界图集生成器（2026-09-15）
从省 ID 位图提取"省与省（或省与海）相接处"的边界像素 → 染成金色 → 拼成一张图集。

运行时用法：点击一个国家 → 筛出"一侧属于该国"的边 → 把图集对应区域贴到世界坐标上
→ 实现"像素级、零露边、缩放免疫"的国境线高亮（学 CK3 的"共享边"）。

输出：
  assets/image/<pack>/border_atlas.png      图集（透明底；亮金芯 + 深金描边）
  scripts/data/mappacks/<pack>/Borders.lua  省对表（含图集区域 + 世界坐标）

用法：
  python3 gen_border_atlas.py              # 默认 eu4
  BPACK=world python3 gen_border_atlas.py  # 其他包
"""
import os
import re
import glob
from collections import defaultdict

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
PACK = os.environ.get("BPACK", "eu4")
BASE = os.path.join(ROOT, "assets", "image", PACK)
IDP = os.path.join(BASE, "province_id.png")
OUT_ATLAS = os.path.join(BASE, "border_atlas.png")
OUT_LUA = os.path.join(ROOT, "scripts", "data", "mappacks", PACK, "Borders.lua")

MARGIN = 2          # 贴图四周留白（放深金外扩 + 抗锯齿）
SHELF_W = 2048      # 图集每行最大宽度
GOLD = (255, 215, 0)
DARK = (148, 106, 10)

# ---------- 1. 可玩省列表 ----------
playable = set()
for f in glob.glob(os.path.join(ROOT, "scripts", "data", "mappacks", PACK, "Provinces_*.lua")):
    for line in open(f, encoding="utf-8", errors="ignore"):
        m = re.match(r'\{id=(\d+)', line.strip())
        if m and "isWasteland=true" not in line:
            playable.add(int(m.group(1)))
print(f"[{PACK}] 可玩省 {len(playable)} 个")

id_im = Image.open(IDP).convert("RGB")
W, H = id_im.size
print(f"[{PACK}] ID 图 {W}x{H}")

# ---------- 2. 提取边像素（只保留"至少一侧是可玩省"的边） ----------
edges = defaultdict(list)          # (min,max) -> [(x, y), ...]
prev_row = None
CHUNK = 512
for y0 in range(0, H, CHUNK):
    y1 = min(y0 + CHUNK, H)
    arr = np.asarray(id_im.crop((0, y0, W, y1)), dtype=np.uint16)
    ids = arr[..., 1].astype(np.int32) * 256 + arr[..., 2].astype(np.int32)
    sub = np.isin(ids, list(playable))

    # 垂直边：像素 (x,y) 与右邻不同 —— 黑线画在左像素上
    dV = ids[:, :-1] != ids[:, 1:]
    subR = np.roll(sub, -1, axis=1)[:, :-1]   # 右邻可玩性（裁到同宽对齐）
    mV = dV & (sub[:, :-1] | subR)
    ys, xs = np.where(mV)
    for x, y in zip(xs.tolist(), ys.tolist()):
        a = int(ids[y, x]); b = int(ids[y, x + 1])
        k = (a, b) if a <= b else (b, a)
        edges[k].append((x, y0 + y))

    # 水平边：像素 (x,y) 与下邻不同 —— 黑线画在上像素上
    if y1 - y0 > 1:
        dH = ids[:-1, :] != ids[1:, :]
        subD = np.roll(sub, -1, axis=0)[:-1, :]   # 下邻可玩性（裁到同高对齐）
        mH = dH & (sub[:-1, :] | subD)
        ys2, xs2 = np.where(mH)
        for x, y in zip(xs2.tolist(), ys2.tolist()):
            a = int(ids[y, x]); b = int(ids[y + 1, x])
            k = (a, b) if a <= b else (b, a)
            edges[k].append((x, y0 + y))

    # 跨块的水平边（上一块最后一行 vs 本块第一行）
    if prev_row is not None:
        dT = ids[0, :] != prev_row
        subT = sub[0, :] | np.isin(prev_row, list(playable))
        mT = dT & subT
        xs3 = np.where(mT)[0]
        for x in xs3.tolist():
            a = int(prev_row[x]); b = int(ids[0, x])
            k = (a, b) if a <= b else (b, a)
            edges[k].append((x, y0))
    prev_row = ids[-1, :].copy()
    print(f"  处理到 y={y1}/{H}，省对 {len(edges)}，边像素 {sum(len(v) for v in edges.values())}")

total_px = sum(len(v) for v in edges.values())
print(f"[{PACK}] 省对 {len(edges)} 组，边像素共 {total_px}")


# ---------- 3. 每组生成小贴图（亮金芯 + 深金外扩） ----------
def dilate(m):
    o = m.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            o = o | np.roll(np.roll(m, -dy, 0), -dx, 1)
    return o


tiles = []   # (key, tile_rgba, wx, wy)  wx/wy = 贴图左上角的"世界(逻辑)坐标"
for key, pix in edges.items():
    xs = [p[0] for p in pix]
    ys = [p[1] for p in pix]
    bx0 = max(min(xs) - MARGIN, 0)
    by0 = max(min(ys) - MARGIN, 0)
    bx1 = min(max(xs) + MARGIN, W - 1)
    by1 = min(max(ys) + MARGIN, H - 1)
    tw = bx1 - bx0 + 1
    th = by1 - by0 + 1
    mask = np.zeros((th, tw), dtype=bool)
    for x, y in pix:
        mask[y - by0, x - bx0] = True
    outer = dilate(mask)
    tile = np.zeros((th, tw, 4), dtype=np.uint8)
    tile[..., 0][outer] = DARK[0]; tile[..., 1][outer] = DARK[1]; tile[..., 2][outer] = DARK[2]
    tile[..., 3][outer] = 235
    tile[..., 0][mask] = GOLD[0]; tile[..., 1][mask] = GOLD[1]; tile[..., 2][mask] = GOLD[2]
    tile[..., 3][mask] = 240
    tiles.append((key, tile, bx0, by0))
    del mask, outer

print(f"[{PACK}] 生成贴图 {len(tiles)} 张")


# ---------- 4. 拼图集（货架排布，大图优先） ----------
tiles.sort(key=lambda t: -(t[1].shape[0] * t[1].shape[1]))
placements = []
cx, cy, row_h = 0, 0, 0
for key, tile, wx, wy in tiles:
    th, tw = tile.shape[0], tile.shape[1]
    if cx + tw > SHELF_W:
        cx = 0
        cy += row_h
        row_h = 0
    placements.append((key, tile, wx, wy, cx, cy))
    cx += tw
    row_h = max(row_h, th)
atlas_h = cy + row_h
atlas = np.zeros((atlas_h, SHELF_W, 4), dtype=np.uint8)
for key, tile, wx, wy, ax, ay in placements:
    atlas[ay:ay + tile.shape[0], ax:ax + tile.shape[1]] = tile
Image.fromarray(atlas).save(OUT_ATLAS, optimize=True)
sz = os.path.getsize(OUT_ATLAS)
print(f"[{PACK}] 图集 {SHELF_W}x{atlas_h} → {OUT_ATLAS} ({sz // 1024} KB)")


# ---------- 5. 写数据表 ----------
lines = []
lines.append("-- 由 gen_border_atlas.py 生成（勿手改）——点击国家时贴其边界的图集区域")
lines.append("-- 每条: { a, b, ax, ay, wx, wy, w, h }")
lines.append("--   a/b  = 两侧省 id（b==0 表示海）；ax/ay = 图集左上角；wx/wy = 世界(逻辑)坐标左上角")
lines.append("return {")
lines.append(f'  image = "image/{PACK}/border_atlas.png",')
lines.append(f'  atlasW = {SHELF_W}, atlasH = {atlas_h},')
lines.append("  edges = {")
for key, tile, wx, wy, ax, ay in placements:
    th, tw = tile.shape[0], tile.shape[1]
    lines.append(f"    {{{key[0]}, {key[1]}, {ax}, {ay}, {wx}, {wy}, {tw}, {th}}},")
lines.append("  },")
lines.append("}")
with open(OUT_LUA, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
print(f"[{PACK}] 数据表 → {OUT_LUA} ({os.path.getsize(OUT_LUA) // 1024} KB)")


# ---------- 6. 验证图：把"齐国"的所有边贴回底图（自检用） ----------
QI = [1062, 1111, 1137, 1194]
pol = np.asarray(Image.open(os.path.join(BASE, "map_political.png")).convert("RGB")).copy()
qi_set = set(QI)
out = pol.copy()
xs_all, ys_all = [], []
for key, tile, wx, wy, ax, ay in placements:
    a, b = key
    ina = a in qi_set
    inb = b in qi_set
    if ina != inb:
        th, tw = tile.shape[0], tile.shape[1]
        region = out[wy:wy + th, wx:wx + tw]
        alpha = tile[..., 3:4].astype(np.float32) / 255.0
        blended = region.astype(np.float32) * (1 - alpha) + tile[..., :3].astype(np.float32) * alpha
        out[wy:wy + th, wx:wx + tw] = blended.astype(np.uint8)
        xs_all.extend([wx, wx + tw])
        ys_all.extend([wy, wy + th])
if xs_all:
    x0, y0 = max(min(xs_all) - 40, 0), max(min(ys_all) - 40, 0)
    x1, y1 = min(max(xs_all) + 40, W), min(max(ys_all) + 40, H)
    Image.fromarray(out[y0:y1, x0:x1]).save(os.path.join(ROOT, "work_tmp", "shots", "atlas_verify_qi.png"))
    print(f"[{PACK}] 验证图（齐国边界贴回）→ work_tmp/shots/atlas_verify_qi.png ({(x1-x0)}x{(y1-y0)})")
print("完成")

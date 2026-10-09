#!/usr/bin/env python3
"""
[工具] 生成"无主底图"瓦片（剧本编辑器专用）：
  把 map_political.png 中所有可玩(非 isWasteland)省的像素染成无主羊皮纸色，
  沙漠/海/暗色边界线保留 → 编辑器不再显示任何旧国家颜色。
输出：assets/image/eu4/neutral_tiles/map_TX_TY.png（与 gen_tiles.py 同切法）
用法：python3 gen_neutral_tiles.py
"""
import argparse
import os
import re
import glob
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))

# 2026-09-15 参数化（和 gen_eu4_map.py 同一套思路）：一份脚本给两个包用
#   python3 gen_neutral_tiles.py                        → eu4（行为不变）
#   python3 gen_neutral_tiles.py --pack world --no-tiles → world（只出整图，不切瓦片）
PACK_ID = 'eu4'
GEN_TILES = True
SRC_ID = None
SRC_POL = None
OUT_DIR = None
TILE = 1024


def configure(pack_id, gen_tiles):
    global PACK_ID, GEN_TILES, SRC_ID, SRC_POL, OUT_DIR
    PACK_ID = pack_id
    GEN_TILES = gen_tiles
    base = os.path.join(ROOT, 'assets', 'image', pack_id)
    SRC_ID = os.path.join(base, 'province_id.png')
    SRC_POL = os.path.join(base, 'map_political.png')
    OUT_DIR = os.path.join(base, 'neutral_tiles')
    print(f'[{PACK_ID}] 无主底图：源 {base}')
UNOWNED = (210, 196, 158)          # 无主羊皮纸色（与 MapRenderer UNOWNED_RGB 一致）
SEA = (156, 183, 212)              # 海色（补齐/边缘）
DARK_SUM = 250                     # 低于此亮度和视为边界/暗线，不染色（各势力色 R+G+B 均 > 300）

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


def parse_wasteland():
    """解析**当前包**的省数据:省id -> 是否 isWasteland"""
    wasteland = {}
    for f in sorted(glob.glob(os.path.join(ROOT, 'scripts', 'data', 'mappacks', PACK_ID, 'Provinces_*.lua'))):
        with open(f, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if not line.startswith('{'):
                    continue
                m = re.match(r'\{id=(\d+)', line)
                if m:
                    pid = int(m.group(1))
                    wasteland[pid] = ('isWasteland=true' in line)
    return wasteland


def main():
    wasteland = parse_wasteland()
    print(f'[Neutral] 省数 {len(wasteland)}, 沙漠省 {sum(wasteland.values())}')

    idim = Image.open(SRC_ID).convert('RGB')
    pol = Image.open(SRC_POL).convert('RGB')
    assert idim.size == pol.size, f'尺寸不一致 {idim.size} vs {pol.size}'
    w, h = pol.size

    idar = np.asarray(idim, dtype=np.int32)
    parr = np.asarray(pol, dtype=np.int32)

    # 位图像素 RGB = (R=0, G=id>>8, B=id&0xFF)
    id_map = idar[..., 1] * 256 + idar[..., 2]
    lut = np.zeros(6000, dtype=bool)
    for pid, ws in wasteland.items():
        if not ws:
            lut[pid] = True
    free = lut[np.clip(id_map, 0, 5999)]          # True = 可玩省像素

    # 暗色(省界/岸线/文字)保留；亮色块(旧国家色)染成无主羊皮纸
    lum = parr[..., 0].astype(np.int32) + parr[..., 1].astype(np.int32) + parr[..., 2].astype(np.int32)
    apply = free & (lum >= DARK_SUM)
    npx = int(apply.sum())
    parr[apply, 0] = UNOWNED[0]
    parr[apply, 1] = UNOWNED[1]
    parr[apply, 2] = UNOWNED[2]
    print(f'[Neutral] 染色像素 {npx} ({npx / (w * h) * 100:.1f}%)')

    out = Image.fromarray(parr.astype(np.uint8), 'RGB')
    base = os.path.join(ROOT, 'assets', 'image', PACK_ID)

    # ---- 整图（运行时真正用到的）：无主整图 + 两个半分辨率图 ----
    #   为什么要在这里一起出：make_whole_images.py 是把**瓦片**拼回整图的，
    #   而整图才是主线（瓦片只是回退）。直接从内存里的 out 出整图更直接，也不依赖瓦片。
    whole_neutral = os.path.join(base, 'map_neutral.png')
    out.save(whole_neutral, optimize=True)
    print(f'[Neutral] 无主整图 → {whole_neutral} {out.size} {os.path.getsize(whole_neutral)//1024}KB')

    out.resize((w // 2, h // 2), Image.LANCZOS).save(
        os.path.join(base, 'map_neutral_half.png'), optimize=True)
    pol = Image.open(SRC_POL).convert('RGB')
    pol.resize((w // 2, h // 2), Image.LANCZOS).save(
        os.path.join(base, 'map_political_half.png'), optimize=True)
    print(f'[Neutral] 半分辨率图（无主 + 政治）已写，尺寸 {w // 2}×{h // 2}')

    # ---- 瓦片（回退路径；主线用整图，不需要）----
    if GEN_TILES:
        os.makedirs(OUT_DIR, exist_ok=True)
        n = 0
        for ty in range(0, h, TILE):
            for tx in range(0, w, TILE):
                paste_tile_padded(out, tx, ty, TILE,
                                  os.path.join(OUT_DIR, f'map_{tx // TILE}_{ty // TILE}.png'), SEA)
                n += 1
        print(f'[Neutral] 已生成 {n} 张瓦片（出血 {PAD}px）→ {OUT_DIR}')
    else:
        print(f'[{PACK_ID}] 跳过无主瓦片（--no-tiles）')


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description='无主底图生成器（整图 + 半图，可选瓦片）')
    ap.add_argument('--pack', default='eu4', help='包 id，默认 eu4')
    ap.add_argument('--no-tiles', action='store_true', help='不切瓦片（只出整图）')
    a = ap.parse_args()
    configure(a.pack, not a.no_tiles)
    main()

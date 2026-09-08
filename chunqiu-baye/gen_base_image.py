#!/usr/bin/env python3
"""[工具] 生成底图 PNG：从 province_id.png（位图唯一事实源）转色放大。
省像素 → 陆地色，海洋像素 → 海色。与运行时省多边形完全同源 → 底图边缘
与省填色/边界线像素级重合（消除"底图与省错位"产生的视觉缝隙）。
依赖：pip install numpy pillow opencv-python
输出：assets/image/world_map_base.png（10800×6864，最近邻 2 倍上采样）"""
import json
import numpy as np
from PIL import Image

SRC_BITMAP = 'assets/image/province_id.png'
OUT = 'assets/image/world_map_base.png'
LOGICAL_W, LOGICAL_H = 10800, 6864
SEA_COLOR = (156, 183, 212)
LAND_COLOR = (210, 196, 158)

def main():
    with open('data_work/world_provinces.json', encoding='utf-8') as f:
        data = json.load(f)
    land_ids = {p['id'] for p in data if not p.get('isOcean')}

    img = Image.open(SRC_BITMAP).convert('RGB')
    px = np.asarray(img).astype(np.int32)      # (H, W, 3)
    ids = (px[:, :, 1] << 8) | px[:, :, 2]     # R=0, G=id>>8, B=id&0xFF

    land = np.isin(ids, list(land_ids))
    out = np.zeros((ids.shape[0], ids.shape[1], 3), dtype=np.uint8)
    out[land] = LAND_COLOR
    out[~land] = SEA_COLOR

    # 最近邻 2 倍上采样 → 10800×6864
    out = np.repeat(np.repeat(out, 2, axis=0), 2, axis=1)
    img_out = Image.fromarray(out, 'RGB')
    img_out.save(OUT, optimize=True)
    print('已保存:', OUT)

    pv = img_out.resize((1400, int(LOGICAL_H / LOGICAL_W * 1400)), Image.LANCZOS)
    pv.save('world_map_preview.png', optimize=True)
    print('预览已保存')

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
[工具] 生成初始 LUT 纹理（省 ID → 显示色）4096×1 RGB PNG。

LUT 是 P 社 shader 方案的核心数据：shader 采样省 ID 位图得省 ID，
再查 LUT 得到该省的显示颜色。运行时势力色变化 = 更新 LUT 纹理。

用法:
  python3 gen_lut.py                    # 全部默认陆地色 + 海色
  python3 gen_lut.py --factions f.json  # 按势力映射上色

--factions 文件格式（为 mod 作者准备的接口）:
  {
    "factions": [
      {"name": "齐国", "color": "#d9534f", "province_ids": [1, 2, 3]},
      {"name": "晋国", "color": "#5cb85c", "province_ids": [4, 5]}
    ],
    "default_color": "#d2c49e",
    "sea_color": "#9cb8d4"
  }

依赖: pip install numpy pillow
"""
import argparse
import json
import numpy as np
from PIL import Image

LUT_W = 4096
SRC_JSON = 'data_work/world_provinces.json'
OUT_LUT = 'assets/image/province_lut.png'

DEFAULT_LAND = (210, 196, 158)   # 浅土色（与底图 LAND_COLOR 一致）
DEFAULT_SEA = (156, 183, 212)    # 海色（与底图 SEA_COLOR 一致）


def hex_to_rgb(s):
    s = s.lstrip('#')
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def main():
    ap = argparse.ArgumentParser(description='Generate province LUT texture')
    ap.add_argument('--factions', type=str, default=None,
                    help='optional factions JSON (see header comment)')
    ap.add_argument('--out', type=str, default=OUT_LUT)
    args = ap.parse_args()

    with open(SRC_JSON, encoding='utf-8') as f:
        data = json.load(f)

    # 默认：陆地省用默认色，海洋用海色
    land_color = DEFAULT_LAND
    sea_color = DEFAULT_SEA
    color_of = {}   # 省 id → (r,g,b)
    for p in data:
        if p.get('isOcean'):
            continue
        color_of[p['id']] = land_color

    # 势力映射覆盖
    if args.factions:
        with open(args.factions, encoding='utf-8') as f:
            fc = json.load(f)
        if 'default_color' in fc:
            land_color = hex_to_rgb(fc['default_color'])
            for pid in color_of:
                color_of[pid] = land_color
        if 'sea_color' in fc:
            sea_color = hex_to_rgb(fc['sea_color'])
        for f in fc.get('factions', []):
            col = hex_to_rgb(f.get('color', '#888888'))
            for pid in f.get('province_ids', []):
                color_of[pid] = col
        print(f'  势力映射: {len(fc.get("factions", []))} 个势力')

    # 生成 LUT：index = 省 ID（0 = 海洋）
    px = np.zeros((1, LUT_W, 3), dtype=np.uint8)
    px[0, 0] = sea_color
    for pid, col in color_of.items():
        if 0 < pid < LUT_W:
            px[0, pid] = col
        else:
            print(f'  [警告] 省 id={pid} 超出 LUT 范围({LUT_W})，跳过')

    img = Image.fromarray(px, 'RGB')
    img.save(args.out, optimize=True)
    print(f'已保存: {args.out} ({LUT_W}x1, {len(color_of)} 省上色)')


if __name__ == '__main__':
    main()

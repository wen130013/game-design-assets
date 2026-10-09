#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_flag_assets.py — 把 AI 纯白旗拆成"可染色素材"（2026-09-17）

用户口径：
  * 军队用「牙旗（狼牙 3 齿）」、战斗/战争用「大纛」
  * 颜色 + 国名要能按势力换 → 旗面必须能单独染色

做法（两层，运行时叠）：
  1. 整面旗（白）  → <name>.png        运行时用固定深棕染色（杆/穗/杆头）
  2. 旗面（白）    → <name>_cloth.png  运行时用势力色染色，盖在第 1 层上
  3. flags.json    → 记录旗面在整图中的相对位置/大小 + 写字中心点

输出：assets/image/flags/
"""

import json
import os
from PIL import Image, ImageDraw

OUT = "/workspace/assets/image/flags"

# name, 源文件, 旗面范围(原图坐标 x0,y0,x1,y1)
#   牙旗：量测得旗面 y 117..363、x 58..451，其中 x<82 是旗杆 → 左边界取 82 避开杆
#   大纛：量测得旗面 y 112..540、x 142..375（上方 91..110 是横木，不纳入）
ITEMS = [
    ("army", "assets/image/形制03a_牙旗大齿_20260917102229.png", (82, 115, 453, 366)),
    ("war",  "assets/image/形制09_大纛_20260917101720.png",       (142, 112, 375, 540)),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    meta = {}

    for name, src, (cx0, cy0, cx1, cy1) in ITEMS:
        im = Image.open(src).convert("RGBA")
        bb = im.getbbox()                      # 裁掉透明边
        full = im.crop(bb)
        fx0, fy0 = bb[0], bb[1]

        # 旗面：把范围外的整张图清空，只留旗面
        cloth = Image.new("RGBA", im.size, (0, 0, 0, 0))
        cloth.paste(im.crop((cx0, cy0, cx1, cy1)), (cx0, cy0))

        # 再裁到旗面的紧致包围盒（便于定位）
        cbb = cloth.getbbox()
        cloth_c = cloth.crop(cbb)

        full.save(f"{OUT}/{name}_flag.png")
        cloth_c.save(f"{OUT}/{name}_cloth.png")

        meta[name] = {
            "size": [full.width, full.height],                       # 整旗尺寸(px)
            "cloth": [cbb[0] - fx0, cbb[1] - fy0,                    # 旗面相对整旗的偏移
                      cbb[2] - cbb[0], cbb[3] - cbb[1]],             # 旗面尺寸
        }
        print(name, "整旗", full.size, "旗面", cloth_c.size, "偏移",
              (cbb[0] - fx0, cbb[1] - fy0))

    with open(f"{OUT}/flags.json", "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    # 自检图：绿框=旗面, 红框=整旗
    sheet = Image.new("RGB", (2 * 300 + 60, 460), (34, 38, 48))
    d = ImageDraw.Draw(sheet)
    for i, (name, _src, _box) in enumerate(ITEMS):
        f = Image.open(f"{OUT}/{name}_flag.png").convert("RGBA")
        f.thumbnail((280, 420))
        x = 30 + i * 320
        sheet.paste(f, (x, 20), f)
        m = meta[name]
        sx, sy = f.width / m["size"][0], f.height / m["size"][1]
        d.rectangle([x + m["cloth"][0] * sx, 20 + m["cloth"][1] * sy,
                     x + (m["cloth"][0] + m["cloth"][2]) * sx,
                     20 + (m["cloth"][1] + m["cloth"][3]) * sy],
                    outline=(80, 230, 120), width=2)
        d.text((x, 445), name, fill=(230, 220, 180))
    sheet.save("/workspace/work_tmp/shots/flag_layers.png")
    print("自检图: work_tmp/shots/flag_layers.png")


if __name__ == "__main__":
    main()

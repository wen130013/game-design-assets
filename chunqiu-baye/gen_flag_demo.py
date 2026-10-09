#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_flag_demo.py — 白旗上色 + 写字演示（2026-09-17）

做法（就是以后进游戏要用的那套）：
  1. 加载纯白旗面素材
  2. 找出「旗面」区域（从种子点 flood fill 近白像素，再做闭运算填掉杂质）
  3. 把旗面区域**乘上势力色**（保留明暗，只换色）
  4. 在旗面重心写国名（描边 + 填色）

输出：assets/image/旗_上色演示.png
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

WHITES = [
    ("assets/image/白旗_幡式_20260917101019.png",   "幡式",   (170, 300), (150, 105, 150), "燕"),
    ("assets/image/白旗_牙旗式_20260917101056.png", "牙旗式", (300, 220), (140,  40,  34), "漢"),
    ("assets/image/白旗_纛_20260917101020.png",     "纛",     (220, 320), ( 46,  92, 138), "蒙"),
    ("assets/image/白旗_西方_20260917101020.png",   "西方式", (300, 200), ( 34,  60, 110), "ROMA"),
]

F_CN = ImageFont.truetype("/workspace/assets/Fonts/LXGWWenKai-Regular.ttf", 170)
F_LA = ImageFont.truetype("/workspace/assets/Fonts/MiSans-Regular.ttf", 64)
F_CAP = ImageFont.truetype("/workspace/assets/Fonts/MiSans-Regular.ttf", 24)
OUT = "/workspace/assets/image/旗_上色演示.png"


def face_mask(img, seed, tol=46):
    """从种子点 flood fill 出旗面区域 → 闭运算填掉内部杂质"""
    work = img.convert("RGB").copy()
    m = Image.new("L", img.size, 0)
    ImageDraw.floodfill(work, seed, (0, 255, 0), thresh=tol)
    px, mp = work.load(), m.load()
    for y in range(img.height):
        for x in range(img.width):
            if px[x, y] == (0, 255, 0):
                mp[x, y] = 255
    return m.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.MinFilter(9))


def tint(img, mask, color):
    """按掩码把旗面乘上颜色（保明暗、换色相）"""
    out = img.copy()
    op, mp = out.load(), mask.load()
    cr, cg, cb = color
    for y in range(img.height):
        for x in range(img.width):
            if mp[x, y] > 128:
                r, g, b, a = op[x, y]
                op[x, y] = (int(r * cr / 255), int(g * cg / 255), int(b * cb / 255), a)
    return out


def main():
    tiles = []
    for path, label, seed, color, name in WHITES:
        img = Image.open(path).convert("RGBA")
        m = face_mask(img, seed)
        tinted = tint(img, m, color)

        # 旗面重心 → 写字位置
        xs = ys = n = 0
        mp = m.load()
        for y in range(0, img.height, 2):
            for x in range(0, img.width, 2):
                if mp[x, y] > 128:
                    xs += x; ys += y; n += 1
        cx, cy = (xs / n, ys / n) if n else (img.width / 2, img.height / 2)

        d = ImageDraw.Draw(tinted)
        font = F_LA if name.isascii() else F_CN
        tw = d.textlength(name, font=font)
        tx, ty = cx - tw / 2, cy - font.size * 0.56
        for dx, dy in ((-3, 0), (3, 0), (0, -3), (0, 3)):
            d.text((tx + dx, ty + dy), name, font=font, fill=(26, 20, 14))
        d.text((tx, ty), name, font=font, fill=(245, 240, 230))
        tiles.append((img, tinted, label, name))

    cw, ch = 380, 660
    sheet = Image.new("RGB", (cw * 4 + 40, ch * 2 + 130), (24, 28, 36))
    d = ImageDraw.Draw(sheet)
    d.text((24, 18), "白旗素材 → 上色 + 写字（同一张素材，颜色和名字都能换）",
           font=ImageFont.truetype("/workspace/assets/Fonts/MiSans-Regular.ttf", 28), fill=(240, 220, 150))
    d.text((24, ch + 96), "↑ 白旗原图（素材）    ↓ 上色＋写字后", font=F_CAP, fill=(160, 170, 185))

    for i, (white, tinted, label, name) in enumerate(tiles):
        x = 20 + i * cw + (cw - 340) // 2
        w = white.copy(); w.thumbnail((330, 560))
        t = tinted.copy(); t.thumbnail((330, 560))
        sheet.paste(w, (x, 66), w)
        sheet.paste(t, (x, 66 + ch), t)
        d.text((20 + i * cw + cw // 2 - 20, 60 + ch * 2), f"{label} · {name}", font=F_CAP,
               fill=(210, 200, 170), anchor="mm")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    sheet.save(OUT)
    print("已生成", OUT, sheet.size)


if __name__ == "__main__":
    main()

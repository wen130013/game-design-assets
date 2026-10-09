#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_flag_samples.py — 旗帜样张 v2（2026-09-17）

用户口径（v2 修正）：
  * 杆、形制**固定**，只有**旗面**不同：一个色块 + 一个名字
  * 古代中式**不是**欧式那种"杆在最外侧"：
      - 幡/幢：杆在旗面**正中间**，布从顶横木往下垂，**底下垂一排穗子**
      - 牙旗：杆在左，布**向右飘**成弧，上下沿垂穗
  * "垂下来的那堆" = 穗子（像过年福字底下的挂钱），**不是**贴在布底边的小锯齿
  * 静态即可（不进游戏，只看效果）

输出：assets/image/flag_samples2.png
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os, math

FONT = "/workspace/assets/Fonts/MiSans-Regular.ttf"
KAI  = "/workspace/assets/Fonts/LXGWWenKai-Regular.ttf"
OUT  = "/workspace/assets/image/flag_samples2.png"

F_TITLE = ImageFont.truetype(FONT, 30)
F_SUB   = ImageFont.truetype(FONT, 20)
F_NAME  = ImageFont.truetype(FONT, 21)
F_CN    = ImageFont.truetype(KAI, 92)
F_CN_S  = ImageFont.truetype(KAI, 62)
F_LATIN = ImageFont.truetype(FONT, 38)

WOOD   = (58, 46, 34)
GOLD   = (205, 176, 104)
GOLD_D = (140, 112, 58)
BORDER = (30, 24, 18)


def shade(c, k):
    return tuple(max(0, min(255, int(v * k))) for v in c)


def vgrad(size, top, bottom):
    w, h = size
    img = Image.new("RGB", size)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def paste_grad(img, pts, color):
    """按多边形裁切，填竖直渐变（布面感）"""
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    x0, y0 = int(min(xs)), int(min(ys))
    w = max(1, int(max(xs) - x0)); h = max(1, int(max(ys) - y0))
    grad = vgrad((w, h), shade(color, 1.14), shade(color, 0.74))
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).polygon([(x - x0, y - y0) for x, y in pts], fill=255)
    img.paste(grad, (x0, y0), mask)


def drop_shadow(img, pts, blur=6, alpha=95):
    sh = Image.new("L", img.size, 0)
    ImageDraw.Draw(sh).polygon([(x + 5, y + 6) for x, y in pts], fill=alpha)
    img.paste(Image.new("RGB", img.size, (0, 0, 0)), (0, 0), sh.filter(ImageFilter.GaussianBlur(blur)))


def draw_pole(d, x, y0, y1, w=9):
    d.rounded_rectangle([x, y0, x + w, y1], radius=w // 2, fill=WOOD)
    d.line([(x + w - 3, y0 + 5), (x + w - 3, y1 - 5)], fill=shade(WOOD, 2.0), width=2)


def finial_spear(d, cx, y):
    d.polygon([(cx, y - 30), (cx - 9, y + 4), (cx + 9, y + 4)], fill=GOLD)
    d.polygon([(cx, y - 30), (cx - 4, y + 4), (cx + 4, y + 4)], fill=shade(GOLD, 1.15))
    d.rectangle([cx - 6, y + 4, cx + 6, y + 11], fill=GOLD_D)


def finial_trident(d, cx, y):
    d.line([(cx, y + 16), (cx, y - 16)], fill=GOLD, width=5)
    for dx in (-13, 0, 13):
        d.line([(cx + dx, y + 2), (cx + dx, y - 22)], fill=GOLD, width=5)
        d.polygon([(cx + dx, y - 32), (cx + dx - 5, y - 20), (cx + dx + 5, y - 20)], fill=GOLD)


def finial_orb(d, cx, y):
    d.line([(cx, y + 14), (cx, y - 10)], fill=GOLD, width=5)
    d.ellipse([cx - 9, y - 27, cx + 9, y - 9], fill=GOLD)


def tassels(d, x0, x1, y, n=6, length=40, color=GOLD_D, knob=True, drop=0.0):
    """往下垂的穗子（过年挂钱那种）：细带 + 末端小坠。drop = 整体下垂幅度（弧）"""
    span = x1 - x0
    for i in range(n):
        t = (i + 0.5) / n
        x = x0 + t * span
        bend = drop * math.sin(t * math.pi)          # 中间更垂
        d.line([(x, y), (x, y + length + bend)], fill=color, width=3)
        if knob:
            d.ellipse([x - 3, y + length + bend, x + 3, y + length + bend + 7], fill=shade(color, 1.25))


def draw_glyph(d, box, glyph, font, color=(255, 252, 245)):
    x0, y0, x1, y1 = box
    tw = d.textlength(glyph, font=font)
    tx = x0 + ((x1 - x0) - tw) / 2
    ty = y0 + ((y1 - y0) - font.size) / 2 - 4
    for dx, dy in ((-2, 0), (2, 0), (0, -2), (0, 2)):
        d.text((tx + dx, ty + dy), glyph, font=font, fill=BORDER)
    d.text((tx, ty), glyph, font=font, fill=color)


# ---------------- 幡式：杆在正中，布左右对称，底下垂穗 ----------------
def flag_fan(color, name, glyph, glyph_font):
    W, H = 300, 420
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pcx = W // 2 - 4                      # 杆的中轴
    draw_pole(d, pcx - 4, 40, H - 24)
    finial_spear(d, pcx, 40)

    x0, x1 = pcx - 78, pcx + 78           # 布宽 156，左右对称
    y0, y1 = 84, 300
    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    drop_shadow(img, pts)
    paste_grad(img, pts, color)           # 布盖住中段的杆
    d.line(pts + [pts[0]], fill=BORDER, width=3, joint="curve")
    d.rectangle([x0 + 5, y0 + 5, x1 - 5, y1 - 5], outline=GOLD, width=1)

    # 顶部横木（盖在布上沿，比布略宽）
    d.rounded_rectangle([x0 - 14, y0 - 10, x1 + 14, y0 + 1], radius=4, fill=GOLD_D)
    d.line([(x0 - 14, y0 - 7), (x1 + 14, y0 - 7)], fill=GOLD, width=2)

    draw_glyph(d, (x0, y0, x1, y1 - 26), glyph, glyph_font)
    tassels(d, x0 + 10, x1 - 10, y1 - 2, n=6, length=38, drop=6)

    return img


# ---------------- 牙旗式：杆在左，布向右飘成弧，上下沿垂穗 ----------------
def flag_ya(color, name, glyph, glyph_font):
    W, H = 300, 420
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    px = 40
    draw_pole(d, px, 52, H - 24)
    finial_spear(d, px + 4, 52)

    x0 = px + 9
    y0, y1 = 104, 236
    x1 = 272
    cy = (y0 + y1) / 2
    # 布向右飘：上沿微拱、右端燕尾分两尾
    pts = [(x0, y0), (x1 - 44, y0 - 6), (x1 - 6, cy - 20), (x1 - 30, cy),
           (x1 - 6, cy + 20), (x1 - 44, y1 + 6), (x0, y1)]
    drop_shadow(img, pts)
    paste_grad(img, pts, color)
    d.line(pts + [pts[0]], fill=BORDER, width=3, joint="curve")

    # 上下沿的短穗（上沿短、下沿长，像城头旗）
    tassels(d, x0 + 26, x1 - 52, y0 - 4, n=4, length=20, drop=4)
    tassels(d, x0 + 12, x1 - 56, y1 + 2, n=5, length=40, drop=8)

    draw_glyph(d, (x0 + 6, y0, x1 - 58, y1), glyph, glyph_font)
    return img


# ---------------- 纛：杆顶三叉，长马尾流苏往右垂 ----------------
def flag_dao(color, name, glyph, glyph_font):
    W, H = 300, 420
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    px = 92
    draw_pole(d, px, 46, H - 24)
    finial_trident(d, px + 4, 54)

    # 长流苏：从横木往右下垂（马尾感）
    d.line([(px + 4, 96), (px + 128, 96)], fill=GOLD_D, width=6)
    strands = [0.10, 0.24, 0.38, 0.52, 0.66, 0.80]
    for i, t in enumerate(strands):
        sx = px + 6 + t * 122
        L = 132 + i * 22
        pts_curve = []
        for k in range(19):
            u = k / 18
            cx = sx + 44 * u * u
            cyy = 98 + L * u
            pts_curve.append((cx, cyy))
        d.line(pts_curve, fill=(234, 230, 220), width=5, joint="curve")
        d.ellipse([pts_curve[-1][0] - 3, pts_curve[-1][1] - 2,
                   pts_curve[-1][0] + 4, pts_curve[-1][1] + 6], fill=(214, 208, 196))

    # 小旗面（色块 + 名字）
    x0, x1 = px + 14, px + 132
    y0, y1 = 214, 322
    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    drop_shadow(img, pts)
    paste_grad(img, pts, color)
    d.line(pts + [pts[0]], fill=BORDER, width=3, joint="curve")
    d.rectangle([x0 + 5, y0 + 5, x1 - 5, y1 - 5], outline=GOLD, width=1)
    draw_glyph(d, (x0, y0, x1, y1), glyph, glyph_font)

    return img


# ---------------- 西方式：横布 + 燕尾 + 圆球顶（沿用） ----------------
def flag_eu(color, name, glyph, glyph_font):
    W, H = 300, 420
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    px = 34
    draw_pole(d, px, 60, H - 24)
    finial_orb(d, px + 4, 68)
    x0, y0 = px + 9, 108
    x1, y1 = x0 + 232, 258
    cy = (y0 + y1) / 2
    pts = [(x0, y0), (x1 - 36, y0), (x1 - 8, cy), (x1 - 36, y1), (x0, y1)]
    drop_shadow(img, pts)
    paste_grad(img, pts, color)
    d.line(pts + [pts[0]], fill=BORDER, width=3, joint="curve")
    draw_glyph(d, (x0, y0, x1 - 20, y1), glyph, glyph_font)
    return img


def main():
    RED   = (146, 38, 32)
    PUR   = (150, 105, 150)
    BLUE  = (46, 92, 138)
    NAVY  = (34, 60, 110)
    CRIM  = (120, 30, 44)

    items = [
        ("幡式（杆在正中）",   flag_fan, PUR,  "幡式 · 燕",    "燕", F_CN),
        ("幡式（杆在正中）",   flag_fan, RED,  "幡式 · 汉",    "漢", F_CN),
        ("牙旗式（杆在左·布右飘）", flag_ya, RED, "牙旗 · 汉",  "漢", F_CN),
        ("牙旗式（杆在左·布右飘）", flag_ya, PUR, "牙旗 · 燕",  "燕", F_CN),
        ("纛（游牧）",         flag_dao, BLUE, "纛 · 蒙古",    "蒙", F_CN_S),
        ("西方式（横幅·燕尾）", flag_eu,  CRIM, "西方式 · ROMA", "ROMA", F_LATIN),
    ]

    cols, rows = 3, 2
    cw, ch = 340, 470
    sheet = Image.new("RGB", (cols * cw + 40, rows * ch + 200), (22, 26, 34))
    d = ImageDraw.Draw(sheet)
    d.text((30, 24), "旗帜样张 v2（杆与形制固定 · 只有旗面颜色和名字不同）", font=F_TITLE, fill=(240, 220, 150))
    d.text((30, 70), "上排：幡式（杆在正中·布对称·底下垂穗） / 下排：牙旗（布向右飘）· 纛 · 西方式",
           font=F_SUB, fill=(190, 200, 215))

    for i, (cat, fn, color, name, glyph, gfont) in enumerate(items):
        r, c = divmod(i, cols)
        f = fn(color, name, glyph, gfont)
        cx = 30 + c * cw + cw / 2
        # 说明写在旗子上方，避免和旗内名字标签撞在一起
        d.text((cx, 116 + r * ch), name, font=F_NAME, fill=(236, 232, 226), anchor="mm")
        d.text((cx, 142 + r * ch), cat, font=F_SUB, fill=(150, 160, 175), anchor="mm")
        x = 30 + c * cw + (cw - f.width) // 2
        y = 156 + r * ch
        sheet.paste(f, (x, y), f)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    sheet.save(OUT)
    print("已生成", OUT, sheet.size)


if __name__ == "__main__":
    main()

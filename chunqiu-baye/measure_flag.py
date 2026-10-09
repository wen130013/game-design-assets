#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""量旗面精确边界（供 gen_flag_assets.py 定框）"""
from PIL import Image
import numpy as np


def widest_run(row):
    idx = np.where(row)[0]
    if len(idx) == 0:
        return (0, 0, 0)
    best = (0, 0, 0)
    start = prev = idx[0]
    for x in idx[1:]:
        if x != prev + 1:
            if prev - start + 1 > best[0]:
                best = (prev - start + 1, start, prev)
            start = x
        prev = x
    if prev - start + 1 > best[0]:
        best = (prev - start + 1, start, prev)
    return best


for tag, f in [("牙旗", "assets/image/形制03a_牙旗大齿_20260917102229.png"),
               ("大纛", "assets/image/形制09_大纛_20260917101720.png")]:
    a = np.array(Image.open(f).convert("RGBA"))[:, :, 3] > 128
    rows = [(y,) + widest_run(a[y]) for y in range(a.shape[0])]
    wide = [r for r in rows if r[1] > 120]
    print(tag, "宽行 y:", wide[0][0], "..", wide[-1][0],
          " x:", min(r[2] for r in wide), "..", max(r[3] for r in wide))
    for y in (wide[0][0], wide[0][0] + 3, wide[-1][0] - 3, wide[-1][0]):
        print("   ", [r for r in rows if r[0] == y][0])

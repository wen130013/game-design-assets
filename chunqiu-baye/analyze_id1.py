#!/usr/bin/env python3
"""验证 id=1 的 cv2.findContours 输出点数。"""
import cv2
import numpy as np
from PIL import Image

ids = np.array(Image.open("/workspace/assets/image/eu4/province_id.png"))
ids = ids[:, :, 1].astype(np.int32) * 256 + ids[:, :, 2].astype(np.int32)

mask = ids == 1
# 局部裁剪(模拟生成脚本)
y0, y1 = 4, 347
x0, x1 = 3493, 4352
lm = mask[y0:y1, x0:x1]
print(f"局部 mask: {lm.shape}, 像素 {lm.sum()}")

m = lm.astype(np.uint8)
cnts, hier = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
print(f"轮廓数量: {len(cnts)}")
if cnts:
    sizes = [len(c) for c in cnts]
    print(f"各轮廓点数: {sorted(sizes, reverse=True)[:5]}")
    areas = [cv2.contourArea(c) for c in cnts]
    print(f"各轮廓面积: {sorted(areas, reverse=True)[:5]}")
    big = max(cnts, key=cv2.contourArea)
    print(f"最大轮廓点: {len(big)}, 面积 {cv2.contourArea(big)}")
    # 检查最大轮廓的坐标范围
    xs = big[:, 0, 0]; ys = big[:, 0, 1]
    print(f"最大轮廓 bbox: x[{xs.min()},{xs.max()}] y[{ys.min()},{ys.max()}]")

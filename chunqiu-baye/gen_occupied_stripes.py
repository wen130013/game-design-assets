#!/usr/bin/env python3
"""gen_occupied_stripes.py — 生成"被占领"斜条纹贴图（透明底、可无缝平铺）

用途：被占领的省 = 用这张条纹图（运行时按占领方颜色染色）填充省多边形。
要点：
  * 透明底（只有条纹是白的）→ 运行时 nvgImagePatternTinted 染色 = 占领方颜色
  * 无缝平铺：条纹按 (x - y) mod P 生成，P 整除贴图边长 → 上下左右接缝都对齐
  * 4 倍超采样后缩小 → 边缘平滑（避免锯齿）
输出：assets/image/pattern_occupied_stripes.png（+ .meta）
"""
import base64, os, uuid
import numpy as np
from PIL import Image

TILE = 64          # 最终贴图边长（必须是周期 P 的整数倍才能无缝）
PERIOD = 16        # 条纹周期
WIDTH = 6          # 条纹宽度
SS = 4             # 超采样倍数
OUT = 'assets/image/pattern_occupied_stripes.png'

N = TILE * SS
P = PERIOD * SS
W = WIDTH * SS
yy, xx = np.mgrid[0:N, 0:N]
d = (xx - yy) % P                      # "/" 方向的斜条纹
mask = (d < W)

img = np.zeros((N, N, 4), dtype=np.uint8)
img[mask] = (255, 255, 255, 255)
im = Image.fromarray(img, 'RGBA').resize((TILE, TILE), Image.LANCZOS)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
im.save(OUT)
print('写入 %s  %dx%d  %.1f KB' % (OUT, TILE, TILE, os.path.getsize(OUT) / 1024))

meta = OUT + '.meta'
if not os.path.exists(meta):
    u = base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip('=')
    open(meta, 'w').write('{\n  "uuid": "%s"\n}' % u)
    print('meta:', u)

# 自检：平铺无缝（左右边、上下边必须一致）
a = np.asarray(im)[:, :, 3]
print('无缝检查：左/右边列一致=%s 上/下边行一致=%s' % (
    bool((a[:, 0].max() == a[:, -1].max())), bool((a[0, :].max() == a[-1, :].max()))))
print('透明像素占比 %.0f%%（条纹占比 %.0f%%）' % (
    100 * (a < 16).mean(), 100 * (a > 200).mean()))

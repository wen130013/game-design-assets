import numpy as np
from PIL import Image

def cnt(a, c, tol):
    return int((np.abs(a - np.array(c)[None, None, :]).max(axis=2) <= tol).sum())

# 1) 默认页：地图全宽 & 无卡
im = np.asarray(Image.open("/workspace/screenshots/select_v4.png").convert("RGB"), dtype=np.int32)
right = im[10:534, 500:800]
print("默认页 右侧(500..800): 卡片底(22,19,22)=%d 海色=%d" % (
    cnt(right, (22, 19, 22), 8), cnt(right, (156, 183, 212))))
mid = im[10:534, 274:790]
print("默认页 地图区海色=%d" % cnt(mid, (156, 183, 212)))

# 2) 白盒高亮：统一亮度色
im2 = np.asarray(Image.open("/workspace/screenshots/hl_uniform.png").convert("RGB"), dtype=np.int32)
print("高亮: 统一色(131,152,66) =", cnt(im2, (131, 152, 66), 9))
print("高亮: 旧焦点色(142,157,61) =", cnt(im2, (142, 157, 61), 5))
print("高亮: 旧同国色(124,148,70) =", cnt(im2, (124, 148, 70), 5))
print("高亮: 金色描边 =", cnt(im2, (255, 215, 0), 35) + cnt(im2, (238, 208, 9), 25))

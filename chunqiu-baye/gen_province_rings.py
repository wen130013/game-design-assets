#!/usr/bin/env python3
"""gen_province_rings.py — 用「共享像素边」从判省位图重建 eu4 省界环（高精度）

为什么这样做：
  * 旧的 polygon 是【每省各自】从自己的 mask 描外轮廓（gen_eu4_map.py，容差 1.0），
    共享边被两侧各描一遍，且 lodLow 容差 8.0 → 低缩放时金边被"捋直"、离开底图黑线。
  * 本脚本把"相邻两省之间那条像素边"当作唯一几何：
      - 一条边界只算一次（去重），两侧省共用同一份坐标 → 架构上不可能有缝/重影
      - 坐标 = 像素角（整数），与底图逐像素对齐（无半像素偏移）
      - 容差（RDP ε）默认 0.6 逻辑像素 ≈ 亚像素级，肉眼贴死底图
  * 只改 polygon / holes，其它字段（id/name/center/area/neighbors/wasteland）原样保留

用法： python3 gen_province_rings.py [eps]     # 默认 0.6
"""
import re, sys, os, math, glob, time
import numpy as np
from PIL import Image
from collections import defaultdict

EPS = float(sys.argv[1]) if len(sys.argv) > 1 else 0.6
DRY = 'dry' in sys.argv          # 只统计不写盘
MAP = 'assets/image/eu4/province_id.png'
DATA_GLOB = 'scripts/data/mappacks/eu4/Provinces_*.lua'
OCEAN, OUTSIDE = 0, -1

t0 = time.time()
im = np.asarray(Image.open(MAP).convert('RGB')).astype(np.int32)
H, W, _ = im.shape
ids = im[:, :, 1] * 256 + im[:, :, 2]
print('[1] 位图 %dx%d  省份 id 1..%d' % (W, H, ids.max()))


def key(x, y):
    return int(y) * 100000 + int(x)


def unkey(k):
    return (k % 100000, k // 100000)


# ---------------------------------------------------------------- 抽像素边
segs = []          # (startKey, endKey, leftId, rightId)  left = 行进方向视觉左侧
dv = ids[:, 1:] != ids[:, :-1]                     # 竖边（角点线 x=k+1）
ys, ks = np.nonzero(dv)
for y, k in zip(ys.tolist(), ks.tolist()):
    x = k + 1
    segs.append((key(x, y), key(x, y + 1), int(ids[y, k + 1]), int(ids[y, k])))
dh = ids[1:, :] != ids[:-1, :]                     # 横边（角点线 y=k+1）
ks2, xs2 = np.nonzero(dh)
for k, x in zip(ks2.tolist(), xs2.tolist()):
    y = k + 1
    segs.append((key(x, y), key(x + 1, y), int(ids[k, x]), int(ids[k + 1, x])))
# 地图外边界（外侧 = -1，保持"国家轮廓沿地图边缘也画"的既有行为）
for y in range(H):
    segs.append((key(0, y), key(0, y + 1), int(ids[y, 0]), OUTSIDE))
    segs.append((key(W, y + 1), key(W, y), OUTSIDE, int(ids[y, W - 1])))
for x in range(W):
    segs.append((key(x, 0), key(x + 1, 0), OUTSIDE, int(ids[0, x])))
    segs.append((key(x + 1, H), key(x, H), int(ids[H - 1, x]), OUTSIDE))
print('[2] 像素边 %d 条 (%.1fs)' % (len(segs), time.time() - t0))

# ------------------------------------------------- 按 (小id, 大id) 分组，方向统一
groups = defaultdict(list)
for s, e, a, b in segs:
    lo, hi = (a, b) if a <= b else (b, a)
    if a == b:
        continue
    if a != lo:                     # 统一成「小 id 在视觉左侧」
        s, e, a, b = e, s, b, a
    groups[(lo, hi)].append((s, e))
print('[3] 边界对 %d 组' % len(groups))


# ---------------------------------------------------------------- 连接成折线
def chain(pair_segments):
    by_start = defaultdict(list)
    for i, (s, e) in enumerate(pair_segments):
        by_start[s].append(i)
    used = [False] * len(pair_segments)
    out = []
    for i0 in range(len(pair_segments)):
        if used[i0]:
            continue
        used[i0] = True
        chain_pts = [pair_segments[i0][0], pair_segments[i0][1]]
        cur = pair_segments[i0][1]
        while True:
            nxt = None
            for j in by_start.get(cur, ()):
                if not used[j] and pair_segments[j][0] == cur:
                    nxt = j
                    break
            if nxt is None:
                break
            used[nxt] = True
            cur = pair_segments[nxt][1]
            chain_pts.append(cur)
            if cur == chain_pts[0]:
                break
        out.append(chain_pts)
    return out


def rdp(pts, eps):
    """迭代版 RDP，保留首尾点"""
    if len(pts) < 3 or eps <= 0:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        ax, ay = pts[a]
        bx, by = pts[b]
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        best, bi = -1.0, -1
        for i in range(a + 1, b):
            px, py = pts[i]
            if L2 == 0:
                d = math.hypot(px - ax, py - ay)
            else:
                t = ((px - ax) * dx + (py - ay) * dy) / L2
                t = 0.0 if t < 0 else (1.0 if t > 1 else t)
                d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if d > best:
                best, bi = d, i
        if best > eps:
            keep[bi] = True
            stack.append((a, bi))
            stack.append((bi, b))
    return [p for i, p in enumerate(pts) if keep[i]]


poly_by_prov = defaultdict(list)     # pid -> [ (起点key, 终点key, [点...]) ]（点已简化，含 pair）
print('[4] 连接 + 简化（ε=%.2f）...' % EPS)
n_before = n_after = 0
for (lo, hi), pair_segments in groups.items():
    for pts in chain(pair_segments):
        n_before += len(pts)
        xy_all = [unkey(k) for k in pts]
        simple = rdp(xy_all, EPS)
        if len(simple) < 2:
            continue
        n_after += len(simple)
        s_key = key(*simple[0])
        e_key = key(*simple[-1])
        if hi > 0:
            poly_by_prov[hi].append((s_key, e_key, simple))
        if lo > 0:
            poly_by_prov[lo].append((e_key, s_key, list(reversed(simple))))
print('    顶点 %d → %d（%.0f%%）' % (n_before, n_after, 100 * n_after / max(1, n_before)))

# --------------------------------------------------- 拼成每省的闭环（含洞/多块）
def poly_area(r):
    a = 0
    for i in range(len(r)):
        x1, y1 = r[i]
        x2, y2 = r[(i + 1) % len(r)]
        a += x1 * y2 - x2 * y1
    return a / 2


def point_in_ring(px, py, ring):
    """射线法：点是否在环内"""
    inside = False
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        if (y1 > py) != (y2 > py):
            xint = x1 + (py - y1) * (x2 - x1) / (y2 - y1)
            if px < xint:
                inside = not inside
    return inside


rings_by_prov = {}
multi_part = 0
open_rings = 0
for pid, plines in poly_by_prov.items():
    by_start = defaultdict(list)
    for i, (s, e, xy) in enumerate(plines):
        by_start[s].append(i)
    used = [False] * len(plines)
    rings = []
    for i0 in range(len(plines)):
        if used[i0]:
            continue
        used[i0] = True
        ring = list(plines[i0][2])
        cur = plines[i0][1]
        guard = 0
        while cur != ring[0] and guard < len(plines) + 2:
            guard += 1
            nxt = None
            for j in by_start.get(cur, ()):
                if not used[j] and plines[j][0] == cur:
                    nxt = j
                    break
            if nxt is None:
                break
            used[nxt] = True
            cur = plines[nxt][1]
            ring.extend(plines[nxt][2][1:])
        if ring[-1] != ring[0]:
            open_rings += 1
        if len(ring) >= 4:
            rings.append(ring)
    if not rings:
        continue
    rings.sort(key=lambda r: -abs(poly_area(r)))
    outer = rings[0]
    if outer[-1] == outer[0]:
        outer = outer[:-1]
    holes, extras = [], []
    for r in rings[1:]:
        rr = r if r[-1] != r[0] else r[:-1]
        if point_in_ring(rr[0][0], rr[0][1], outer):
            holes.append(rr)
        else:
            extras.append(rr)
    if extras:
        multi_part += 1
    rings_by_prov[pid] = (outer, holes, len(extras))
print('[5] 拼环完成：%d 省；%d 省有额外分离块（不渲染，与旧数据一致）；未闭合链 %d' % (
    len(rings_by_prov), multi_part, open_rings))


# ------------------------------------------------------------------ 写回数据
tot_new_poly = tot_new_holes = tot_old = 0
files = sorted(glob.glob(DATA_GLOB))
missing = []
if DRY:
    files = []
    for pid, (outer, holes, _) in rings_by_prov.items():
        tot_new_poly += len(outer)
        tot_new_holes += sum(len(h) for h in holes)
    import re as _re
    for path in sorted(glob.glob(DATA_GLOB)):
        for line in open(path, encoding='utf-8'):
            tot_old += len(_re.findall(r'\{-?\d+,-?\d+\}', line))
    print('[6][dry] 顶点：旧 %d → 新 %d（洞 %d）' % (tot_old, tot_new_poly + tot_new_holes, tot_new_holes))
    print('   估数据量 ≈ %.2f MB（按 11.6 字节/顶点）' % ((tot_new_poly + tot_new_holes) * 11.6 / 1048576))
    print('总耗时 %.1fs' % (time.time() - t0))
    sys.exit(0)
for path in files:
    lines = open(path, encoding='utf-8').read().splitlines(keepends=True)
    out = []
    for line in lines:
        m = re.match(r'\{id=(\d+),', line)
        if not m:
            out.append(line)
            continue
        pid = int(m.group(1))
        tot_old += len(re.findall(r'\{-?\d+,-?\d+\}', line))
        if pid not in rings_by_prov:
            missing.append(pid)
            out.append(line)
            continue
        polys, holes, _ = rings_by_prov[pid]
        poly_str = '{' + ','.join('{%d,%d}' % p for p in polys) + '}'
        line = re.sub(r',polygon=\{\{.*?\}\}', ',polygon=' + poly_str, line, count=1)
        line = re.sub(r',holes=\{\{.*?\}\}', '', line, count=1)
        line = re.sub(r',lodLow=\{\{.*?\}\}', '', line, count=1)
        if holes:
            hs = '{' + ','.join('{' + ','.join('{%d,%d}' % p for p in h) + '}' for h in holes) + '}'
            line = line.replace(',polygon=' + poly_str, ',polygon=' + poly_str + ',holes=' + hs, 1)
            tot_new_holes += sum(len(h) for h in holes)
        tot_new_poly += len(polys)
        out.append(line)
    open(path, 'w', encoding='utf-8').write(''.join(out))
    print('  写入 %s (%.0fKB)' % (os.path.basename(path), os.path.getsize(path) / 1024))

size = sum(os.path.getsize(f) for f in files)
print('[6] 顶点：旧 %d → 新 %d（洞 %d）' % (tot_old, tot_new_poly + tot_new_holes, tot_new_holes))
print('    数据 %.2f MB；缺失省 %d 个' % (size / 1048576, len(missing)))
print('总耗时 %.1fs' % (time.time() - t0))

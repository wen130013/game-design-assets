#!/usr/bin/env python3
"""
[工具] 数据后处理：P社栅格位图方案（缝隙根治）。
★ 每次 world_provinces.json 数据改动后必跑，然后重新构建。

核心流程（位图 = 唯一事实源）：
  1. 合并修复：editorFilled 的 target 用 shapely 精确并集重建多边形
  2. 栅格化：修复后的多边形 → province_id.png（5400×3432，RGB 编码省 ID）
       - R=0, G=id>>8, B=id&0xFF；海洋=黑(0,0,0)
       - 面积从小到大填充（小省后画，保证小省像素完整）
  3. 拓扑一致提取：从位图提取"共享网格线段"组装每省环
       - 相邻省共享同一条像素边界 → 端点精确一致 → 架构上不可能有缝隙
       - 按"共享段/海岸段"分组做段级 RDP 简化，段端点保留
       - 同一段两侧几何相同 → 简化结果两侧一致（不会重新引入缝隙）
       - full 容差 2.0，lodLow 容差 8.0（逻辑单位）
  4. 名字位置：shapely representative_point（保证在区块内部）
  5. 邻接重建：栅格 5×5 膨胀消除间隙
依赖：pip install numpy opencv-python shapely pillow
"""
import json
import math
import numpy as np
import cv2
from collections import defaultdict
from shapely.geometry import Polygon, MultiPolygon
from shapely.ops import unary_union

SRC = 'data_work/world_provinces.json'
OUT_JSON = 'data_work/world_provinces.json'
OUT_LUA = 'scripts/data/GeneratedProvinces.lua'
OUT_BITMAP = 'assets/image/province_id.png'
PREVIEW = 'screenshots/build_preview.png'

LOGICAL_W, LOGICAL_H = 10800.0, 6864.0
# ── 位图分辨率：4096 宽（Web/手机 WebGL1 纹理上限 4096 安全值）──
# 高度按逻辑纵横比换算：round(6864 / 2.63671875) = 2603
BITMAP_W = 4096
SCALE = LOGICAL_W / BITMAP_W          # 2.63671875 逻辑单位/像素
BITMAP_H = int(round(LOGICAL_H / SCALE))   # 2603（与逻辑纵横比一致）

# 简化容差（逻辑单位）
DP_EPS_FULL = 2.0    # full：抹平 1 像素锯齿，形状几乎不变
DP_EPS_LOW  = 8.0    # lodLow：4 像素级平滑，供低缩放渲染

MIN_PIXELS = 2       # 省在位图中的最小存活像素


# ---------------------------------------------------------------
# 1) 合并修复：editorFilled 的 target 用 shapely 精确并集重建
# ---------------------------------------------------------------
def fix_merged_province(p, data):
    absorbed = [q for q in data if q.get('absorbedBy') == p['id']]
    if not absorbed:
        return
    try:
        polys = []
        for q in [p] + absorbed:
            g = Polygon(q['polygon'])
            if not g.is_valid:
                g = g.buffer(0)  # 修复自相交等无效几何
            polys.append(g)
        merged = unary_union(polys)
        if isinstance(merged, MultiPolygon):
            merged = max(merged.geoms, key=lambda g: g.area)
        p['polygon'] = [[round(float(x), 1), round(float(y), 1)]
                        for x, y in merged.exterior.coords]
        print(f'  [合并修复] id={p["id"]} {p["name"]}: {len(absorbed)} 个组成省精确并集，'
              f'多边形 {len(p["polygon"])} 顶点')
    except Exception as e:
        print(f'  [警告] 合并修复失败 id={p["id"]}: {e}')


# ---------------------------------------------------------------
# 2) 栅格化：多边形 → 省 ID 位图（面积从小到大填充）
# ---------------------------------------------------------------
def cleanup_singularities(grid):
    """消除单像素孤点（4 邻全同且与自己不同），防止环组装死端。
    四值汇合（度数>2）不在此处理：assemble_all 用最小转向续接。
    代价：单像素洞/岛被并入邻居（边界移动 ≤1 像素）。"""
    g = grid.copy()
    up = np.empty_like(g)
    down = np.empty_like(g)
    left = np.empty_like(g)
    right = np.empty_like(g)
    up[1:, :] = g[:-1, :]
    up[0, :] = g[0, :]
    down[:-1, :] = g[1:, :]
    down[-1, :] = g[-1, :]
    left[:, 1:] = g[:, :-1]
    left[:, 0] = g[:, 0]
    right[:, :-1] = g[:, 1:]
    right[:, -1] = g[:, -1]
    iso = (g != up) & (up == down) & (up == left) & (up == right)
    iso[0, :] = False
    iso[-1, :] = False
    iso[:, 0] = False
    iso[:, -1] = False
    g[iso] = up[iso]
    return g


def rasterize(data):
    print(f'[栅格化] {BITMAP_W}×{BITMAP_H}（{SCALE} 逻辑单位/像素）...')
    grid = np.zeros((BITMAP_H, BITMAP_W), dtype=np.int32)

    def shoelace(poly):
        n = len(poly)
        a = 0.0
        for i in range(n):
            x1, y1 = poly[i]
            x2, y2 = poly[(i + 1) % n]
            a += x1 * y2 - x2 * y1
        return abs(a) / 2.0

    land = [p for p in data if not p.get('isOcean') and len(p.get('polygon') or []) >= 3]
    # 面积从大到小填充（降序）：小省后画，共享边像素归属稳定、小省不被覆盖
    land_sorted = sorted(land, key=lambda p: shoelace(p['polygon']), reverse=True)
    for p in land_sorted:
        pts = np.round([[x / SCALE, y / SCALE] for x, y in p['polygon']]).astype(np.int32)
        pts[:, 0] = np.clip(pts[:, 0], 0, BITMAP_W - 1)
        pts[:, 1] = np.clip(pts[:, 1], 0, BITMAP_H - 1)
        cv2.fillPoly(grid, [pts], p['id'])

    # 奇异点消除（三国交界 T 形）
    grid = cleanup_singularities(grid)

    # 存活校验
    counts = np.bincount(grid.ravel())
    missing = [p['id'] for p in land if counts[p['id']] < MIN_PIXELS]
    if missing:
        print(f'  [警告] 位图丢失/过小省 {len(missing)} 个:',
              {m: counts[m] for m in missing})
    small = sorted(((p['id'], int(counts[p['id']])) for p in land),
                   key=lambda kv: kv[1])[:5]
    print(f'  位图省像素校验: {len(land)} 省，最小存活像素 {small}')

    # 编码省 ID → RGB（R=0, G=id>>8, B=id&0xFF）
    from PIL import Image
    px = np.zeros((BITMAP_H, BITMAP_W, 3), dtype=np.uint8)
    px[:, :, 1] = (grid >> 8) & 0xFF
    px[:, :, 2] = grid & 0xFF
    img = Image.fromarray(px, 'RGB')
    img.save(OUT_BITMAP, optimize=True)
    print(f'  已保存: {OUT_BITMAP}')
    return grid


# ---------------------------------------------------------------
# 3) 拓扑一致提取：位图 → 共享网格线段 → 每省环 → 段级 RDP
# ---------------------------------------------------------------
def norm_edge(e):
    x1, y1, x2, y2 = e
    if (x1, y1) > (x2, y2):
        return (x2, y2, x1, y1)
    return (x1, y1, x2, y2)


def rdp_iter(points, eps):
    """迭代 RDP（首尾保留）。points: list[(x,y)]"""
    n = len(points)
    if n < 3:
        return points
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        s, e = stack.pop()
        if e - s < 2:
            continue
        x1, y1 = points[s]
        x2, y2 = points[e]
        dx = x2 - x1
        dy = y2 - y1
        L = math.hypot(dx, dy)
        dmax = 0.0
        idx = -1
        for i in range(s + 1, e):
            xi, yi = points[i]
            if L < 1e-9:
                d = math.hypot(xi - x1, yi - y1)
            else:
                d = abs(dy * (xi - x1) - dx * (yi - y1)) / L
            if d > dmax:
                dmax = d
                idx = i
        if dmax > eps and idx > 0:
            keep[idx] = True
            stack.append((s, idx))
            stack.append((idx, e))
    return [points[i] for i in range(n) if keep[i]]


def close_border_rings(edges_by_prov, H, W, grid):
    """贴边省：把图像边缘作为其边界的一部分（沿边缘补边），使环闭合。
    对每条图像边缘，扫描像素找每省的连续区间，把区间两端用边缘线相连。"""
    def add_segment(pid, x1, y1, x2, y2):
        # 边缘线段（网格坐标端点），一条边
        if (x1, y1) == (x2, y2):
            return
        edges_by_prov[pid].append((x1, y1, x2, y2))

    # 上边缘 y=0（网格线 y=0），像素行 0。边缘边端点 = 区间两端像素的边界
    prev = 0
    seg_start = None
    for c in range(W):
        v = grid[0][c]
        if v != prev:
            if prev != 0 and seg_start is not None:
                add_segment(prev, seg_start, 0, c, 0)
            seg_start = c
            prev = v
    if prev != 0 and seg_start is not None:
        add_segment(prev, seg_start, 0, W, 0)
    # 下边缘 y=H-1（网格线 y=H）
    prev = 0
    seg_start = None
    for c in range(W):
        v = grid[H - 1][c]
        if v != prev:
            if prev != 0 and seg_start is not None:
                add_segment(prev, seg_start, H, c, H)
            seg_start = c
            prev = v
    if prev != 0 and seg_start is not None:
        add_segment(prev, seg_start, H, W, H)
    # 左边缘 x=0（网格线 x=0）
    prev = 0
    seg_start = None
    for r in range(H):
        v = grid[r][0]
        if v != prev:
            if prev != 0 and seg_start is not None:
                add_segment(prev, 0, seg_start, 0, r)
            seg_start = r
            prev = v
    if prev != 0 and seg_start is not None:
        add_segment(prev, 0, seg_start, 0, H)
    # 右边缘 x=W-1（网格线 x=W）
    prev = 0
    seg_start = None
    for r in range(H):
        v = grid[r][W - 1]
        if v != prev:
            if prev != 0 and seg_start is not None:
                add_segment(prev, W, seg_start, W, r)
            seg_start = r
            prev = v
    if prev != 0 and seg_start is not None:
        add_segment(prev, W, seg_start, W, H)


def extract_from_bitmap(grid):
    """从位图提取每省环（网格坐标）。返回 {pid: [(ring_pts, edge_shared_flags)]}
    ring_pts: list[(x,y)] 网格点坐标（闭合，首尾相同），每环恰一个。
    edge_shared_flags[i]: 边 ring_pts[i]→ring_pts[(i+1)%n] 是否两侧都有省。
    """
    H, W = grid.shape
    # 收集网格边
    edges_by_prov = defaultdict(list)   # pid → [(x1,y1,x2,y2)]
    shared = set()                       # 规范化网格边（两侧都有省）
    # 水平相邻 → 竖直网格边 (c+1, r)-(c+1, r+1)
    for r in range(H):
        row = grid[r]
        for c in range(W - 1):
            a, b = row[c], row[c + 1]
            if a == b:
                continue
            e = (c + 1, r, c + 1, r + 1)
            if a:
                edges_by_prov[a].append(e)
            if b:
                edges_by_prov[b].append(e)
            if a and b:
                shared.add(norm_edge(e))
    # 垂直相邻 → 水平网格边 (c, r+1)-(c+1, r+1)
    for r in range(H - 1):
        for c in range(W):
            a, b = grid[r][c], grid[r + 1][c]
            if a == b:
                continue
            e = (c, r + 1, c + 1, r + 1)
            if a:
                edges_by_prov[a].append(e)
            if b:
                edges_by_prov[b].append(e)
            if a and b:
                shared.add(norm_edge(e))
    # 贴边省：沿图像边缘补边（闭合环）
    close_border_rings(edges_by_prov, H, W, grid)

    def assemble_all(edges):
        """贪心组装全部环（网格坐标，闭合首尾相同）。
        端点度数 >2（四值汇合）时选"与前一条边最连续"的边续接。
        省像素可能含洞（环带），产生多条环。"""
        if not edges:
            return []
        adj = defaultdict(list)
        for idx, (x1, y1, x2, y2) in enumerate(edges):
            adj[(x1, y1)].append(idx)
            adj[(x2, y2)].append(idx)
        used = [False] * len(edges)
        rings = []
        while True:
            start = next((i for i in range(len(edges)) if not used[i]), None)
            if start is None:
                break
            ring = []
            idx = start
            e = edges[idx]
            used[idx] = True
            ring.append((e[0], e[1]))
            x, y = e[2], e[3]
            ring.append((x, y))
            while True:
                cand = [i for i in adj[(x, y)] if not used[i]]
                if not cand:
                    break
                if len(cand) > 1:
                    # 最小转向：选与前一条边方向最一致的未用边
                    px, py = ring[-2]
                    dx, dy = x - px, y - py
                    best_i = cand[0]
                    best_score = -1e18
                    for i in cand:
                        e2 = edges[i]
                        if (e2[0], e2[1]) == (x, y):
                            ex, ey = e2[2] - x, e2[3] - y
                        else:
                            ex, ey = e2[0] - x, e2[1] - y
                        score = dx * ex + dy * ey
                        if score > best_score:
                            best_score = score
                            best_i = i
                    i = best_i
                else:
                    i = cand[0]
                e = edges[i]
                used[i] = True
                if (e[0], e[1]) == (x, y):
                    x, y = e[2], e[3]
                else:
                    x, y = e[0], e[1]
                ring.append((x, y))
                if (x, y) == ring[0]:
                    break
            if len(ring) < 4:
                print(f'  [警告] 退化环 {len(ring)} 点')
            else:
                rings.append(ring)
        return rings

    def flags_of(ring):
        n = len(ring) - 1  # 不重复顶点数（首尾重复）
        fl = []
        for i in range(n):
            a = ring[i]
            b = ring[i + 1]
            fl.append(norm_edge((a[0], a[1], b[0], b[1])) in shared)
        return fl

    result = {}
    for pid, edges in edges_by_prov.items():
        rings = assemble_all(edges)
        result[pid] = [(r, flags_of(r)) for r in rings]
    return result


def simplify_closed_ring(ring, flags, eps):
    """闭合环简化。eps=None → 原样保留（像素网格线，零缝隙零穿出）。
    eps>0 → 段级 RDP（用于 lodLow，低缩放使用，穿出不可见）：
    - 段按"共享/海岸类型转换点"切分；共享段整体 RDP（段端点=cuts 保留，
      两侧环输入相同 → 输出一致，无缝隙）
    - 无类型转换的环（全共享/全海岸，如洞内省/岛）用直径端点切段防拉弦
    - 简化后面积 < 原面积 50% → 回退原环；简化自交 → 回退原环
    返回闭合环（首尾相同）。"""
    if eps is None:
        return ring
    n = len(ring) - 1  # 不重复顶点数
    if n <= 4:
        return ring
    pts = ring[:n]

    # 类型转换点（共享段 ↔ 海岸段 端点）
    cuts = [i for i in range(n) if flags[(i - 1) % n] != flags[i]]
    if cuts:
        keep = set(cuts)
    else:
        # 全共享/全海岸环：直径两端点切段（bbox 角点近似，避免 O(n²)）
        minx = min(p[0] for p in pts)
        maxx = max(p[0] for p in pts)
        miny = min(p[1] for p in pts)
        maxy = max(p[1] for p in pts)
        corners = [(minx, miny), (minx, maxy), (maxx, miny), (maxx, maxy)]
        cand = []
        for cx, cy in corners:
            idx = min(range(n), key=lambda i: (pts[i][0] - cx) ** 2 + (pts[i][1] - cy) ** 2)
            if idx not in cand:
                cand.append(idx)
        i0, j0 = cand[0], cand[1]
        best = -1
        for a in cand:
            for b in cand:
                d = (pts[a][0] - pts[b][0]) ** 2 + (pts[a][1] - pts[b][1]) ** 2
                if d > best:
                    best, i0, j0 = d, a, b
        if i0 > j0:
            i0, j0 = j0, i0
        keep = {i0, j0}
    if len(keep) >= n:
        return ring

    # 按 keep 点正向切段，每段独立 RDP（共享段两侧输入相同 → 输出一致）
    order = sorted(keep)
    out = []
    for k in range(len(order)):
        s = order[k]
        e = order[(k + 1) % len(order)]
        seg = []
        i = s
        while True:
            seg.append(pts[i])
            if i == e:
                break
            i = (i + 1) % n
        seg2 = rdp_iter(seg, eps) if len(seg) >= 3 else seg
        for pt in seg2:
            if out and out[-1] == pt:
                continue
            out.append(pt)
    if out and out[0] != out[-1]:
        out.append(out[0])

    # 面积保护：简化后面积显著缩水 → 回退原环
    def area(poly_pts):
        m = len(poly_pts) - 1
        a = 0.0
        for i in range(m):
            x1, y1 = poly_pts[i]
            x2, y2 = poly_pts[i + 1]
            a += x1 * y2 - x2 * y1
        return abs(a) / 2.0

    if len(out) < 5 or area(out) < 0.5 * area(ring):
        return ring
    # 有效性检查：简化在窄瓶颈处自交 → 回退原环
    try:
        test = Polygon(out)
        if not test.is_valid:
            return ring
    except Exception:
        return ring
    return out


def extract_polygons(grid, data):
    """从位图提取全部省的多边形 + lodLow（含洞）。
    返回 {id: {polygon, lodLow, holes, lodLowHoles}}（逻辑坐标）
    面积最大的环 = 外环 polygon；其余 = 洞 holes。"""
    rings = extract_from_bitmap(grid)
    print(f'  提取省: {len(rings)}/{len(data)}')

    def ring_area(ring):
        n = len(ring) - 1  # 不重复顶点数
        a = 0.0
        for i in range(n):
            x1, y1 = ring[i]
            x2, y2 = ring[i + 1]
            a += x1 * y2 - x2 * y1
        return abs(a) / 2.0

    def to_logical(ring):
        return [[round(x * SCALE, 1), round(y * SCALE, 1)] for x, y in ring]

    out = {}
    for pid, ring_list in rings.items():
        # 面积降序：主环在前，洞在后
        ring_list.sort(key=lambda rf: ring_area(rf[0]), reverse=True)
        main_ring, main_flags = ring_list[0]
        holes = [(r, f) for r, f in ring_list[1:] if ring_area(r) >= 2.0]  # 过滤噪声细环
        # full 原样（像素网格，零缝隙零穿出）；lodLow 段级 RDP（低缩放用）
        out[pid] = {
            'polygon': to_logical(simplify_closed_ring(main_ring, main_flags, None)),
            'lodLow': to_logical(simplify_closed_ring(main_ring, main_flags, DP_EPS_LOW)),
            'holes': [to_logical(simplify_closed_ring(r, f, None)) for r, f in holes],
            'lodLowHoles': [to_logical(simplify_closed_ring(r, f, DP_EPS_LOW)) for r, f in holes],
        }
    return out


# ---------------------------------------------------------------
# 4) 名字位置：shapely representative_point（保证在区块内部，考虑洞）
# ---------------------------------------------------------------
def compute_center(p):
    pts = p['polygon']
    holes = p.get('holes') or []
    try:
        poly = Polygon(pts, holes) if holes else Polygon(pts)
        rp = poly.representative_point()
        p['center'] = [round(rp.x, 1), round(rp.y, 1)]
    except Exception as e:
        print(f'  [警告] center 异常 id={p["id"]} {p["name"]} polygon={len(pts)} holes={len(holes)}: {e}')
        if not pts:
            p['center'] = [0.0, 0.0]
        else:
            p['center'] = [round(sum(pt[0] for pt in pts) / len(pts), 1),
                           round(sum(pt[1] for pt in pts) / len(pts), 1)]


def make_preview(data, out_path):
    """处理后边界预览图。"""
    try:
        from PIL import Image, ImageDraw
        sc = 0.25
        img = Image.new('RGB', (int(LOGICAL_W * sc), int(LOGICAL_H * sc)), (245, 242, 235))
        dr = ImageDraw.Draw(img)
        for p in data:
            if p.get('isOcean'):
                continue
            pts = [(x * sc, y * sc) for x, y in p['polygon']]
            if len(pts) >= 2:
                dr.line(pts, fill=(40, 160, 60), width=1)
        img.save(out_path)
        print('预览图已生成:', out_path)
    except Exception as e:
        print('[警告] 预览图生成失败:', e)


def main():
    with open(SRC, encoding='utf-8') as f:
        data = json.load(f)
    print('读取区块:', len(data))

    for i, p in enumerate(data):
        p['id'] = i + 1
        p['terrain'] = '平原'
        p['baseGold'] = 5
        p['baseFood'] = 8
        p['population'] = 5000
        p['ownerId'] = None
        p['isOcean'] = p.get('isOcean', False)
        p['editorFilled'] = p.get('editorFilled') or None
        p['suppressOceanCover'] = p.get('suppressOceanCover') or None
        p['absorbedBy'] = p.get('absorbedBy') or None

    # 0) absorbedBy 名字→id 转换
    name_to_id = {p['name']: p['id'] for p in data}
    for p in data:
        ab = p.get('absorbedBy')
        if ab and not isinstance(ab, int) and ab in name_to_id:
            p['absorbedBy'] = name_to_id[ab]

    # 0.5) 修复无效几何（buffer(0)）
    invalid_cnt = 0
    for p in data:
        try:
            g = Polygon(p['polygon'])
            if not g.is_valid:
                g = g.buffer(0)
                if isinstance(g, MultiPolygon):
                    g = max(g.geoms, key=lambda x: x.area)
                p['polygon'] = [[round(float(x), 1), round(float(y), 1)]
                                for x, y in g.exterior.coords]
                invalid_cnt += 1
        except Exception:
            pass
    if invalid_cnt:
        print(f'修复无效几何: {invalid_cnt} 个')

    # 1) 合并修复（先处理 editorFilled，因为依赖 absorbedBy 已存在）
    n_merged = sum(1 for p in data if p.get('editorFilled'))
    if n_merged:
        print(f'合并区块修复（{n_merged} 个）:')
        for p in data:
            if p.get('editorFilled') and not p.get('isOcean'):
                fix_merged_province(p, data)

    # 2) 栅格化（位图 = 唯一事实源）
    grid = rasterize(data)

    # 3) 拓扑一致提取 polygon + lodLow（替换 GADM 原始多边形）
    polys = extract_polygons(grid, data)
    applied = 0
    with_holes = 0
    for p in data:
        if p.get('isOcean'):
            continue
        got = polys.get(p['id'])
        if got:
            p['polygon'] = got['polygon']
            p['lodLow'] = got['lodLow']
            if got['holes']:
                p['holes'] = got['holes']
                p['lodLowHoles'] = got['lodLowHoles']
                with_holes += 1
            else:
                p.pop('holes', None)
                p.pop('lodLowHoles', None)
            applied += 1
        else:
            print(f'  [警告] 无多边形 id={p["id"]} {p["name"]}')
    print(f'  多边形应用: {applied} 省（{with_holes} 省带洞）')
    total_pts = sum(len(p['polygon']) for p in data if not p.get('isOcean'))
    total_low = sum(len(p.get('lodLow') or []) for p in data if not p.get('isOcean'))
    print(f'  full 总顶点: {total_pts}  lodLow 总顶点: {total_low}')

    # 3.5) 提取后最终几何兜底：buffer(0) 修复残余自交（简化/组装的微自交）
    fixed = 0
    for p in data:
        if p.get('isOcean'):
            continue
        try:
            g = Polygon(p['polygon'], p.get('holes') or [])
            if not g.is_valid:
                g = g.buffer(0)
                if isinstance(g, MultiPolygon):
                    g = max(g.geoms, key=lambda x: x.area)
                p['polygon'] = [[round(float(x), 1), round(float(y), 1)]
                                for x, y in g.exterior.coords]
                if len(g.interiors):
                    p['holes'] = [[[round(float(x), 1), round(float(y), 1)]
                                   for x, y in h.coords] for h in g.interiors]
                    p['lodLowHoles'] = p.get('lodLowHoles') or p['holes']
                else:
                    p.pop('holes', None)
                    p.pop('lodLowHoles', None)
                fixed += 1
        except Exception:
            pass
    if fixed:
        print(f'  提取后几何修复: {fixed} 省')

    # 4) 名字位置
    for p in data:
        compute_center(p)

    # 5) 邻接重建（栅格 5x5 膨胀消除间隙）
    # 面积从大到小填充：洞内小省（如莱索托）后画覆盖洞区域，邻接正确
    Wg, Hg = 4000, int(LOGICAL_H / LOGICAL_W * 4000)
    grid2 = np.zeros((Hg, Wg), dtype=np.int32)

    def shoelace(poly):
        n = len(poly)
        a = 0.0
        for i in range(n):
            x1, y1 = poly[i]
            x2, y2 = poly[(i + 1) % n]
            a += x1 * y2 - x2 * y1
        return abs(a) / 2.0

    land_provs = [p for p in data if not p.get('isOcean')]
    for p in sorted(land_provs, key=lambda q: shoelace(q['polygon']), reverse=True):
        gx = [(x / LOGICAL_W * Wg, y / LOGICAL_H * Hg) for x, y in p['polygon']]
        arr = np.array([[(x, y)] for x, y in gx], dtype=np.float32).astype(np.int32)
        cv2.fillPoly(grid2, [arr], p['id'])
    from numpy.lib.stride_tricks import sliding_window_view
    pad = np.pad(grid2, 2, mode='constant', constant_values=0)
    win = sliding_window_view(pad, (5, 5)).reshape(Hg, Wg, 25)
    grid_d = win.max(axis=2)
    adjacency = set()
    g, gd = grid2, grid_d
    r1, r2 = g[:, :-1], gd[:, 1:]
    for yy, xx in np.argwhere((r1 > 0) & (r2 > 0) & (r1 != r2)):
        adjacency.add((min(int(r1[yy, xx]), int(r2[yy, xx])), max(int(r1[yy, xx]), int(r2[yy, xx]))))
    d1, d2 = g[:-1, :], gd[1:, :]
    for yy, xx in np.argwhere((d1 > 0) & (d2 > 0) & (d1 != d2)):
        adjacency.add((min(int(d1[yy, xx]), int(d2[yy, xx])), max(int(d1[yy, xx]), int(d2[yy, xx]))))
    for idx, p in enumerate(data, start=1):
        p['neighbors'] = [n for n in range(1, len(data) + 1)
                          if (min(idx, n), max(idx, n)) in adjacency]

    nb = [len(p['neighbors']) for p in data]
    print(f'省份总数: {len(data)}  平均邻居 {sum(nb) / len(nb):.1f}  无邻居 {sum(1 for n in nb if n == 0)}')

    with open(OUT_JSON, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'))

    # 分片写出：GeneratedProvinces_N.lua（每片 ≤1.4MB）
    # ⚠️ 引擎 Lua chunk 加载限制 ~2MB，12MB 数据必须分片
    header = ['-- Auto-generated world province data (Eurasia + North Africa)',
              '-- Source: GADM global, rasterized to province_id.png (bitmap as single source of truth)',
              '-- DO NOT EDIT manually', 'return {']
    entries = []
    for p in data:
        poly = ','.join(f'{{{x},{y}}}' for x, y in p['polygon'])
        nb = ','.join(str(n) for n in p['neighbors'])
        owner = str(p['ownerId']) if p['ownerId'] is not None else 'nil'
        isOcean = 'true' if p.get('isOcean') else 'false'
        editorFilled = 'true' if p.get('editorFilled') else 'nil'
        suppressCover = 'true' if p.get('suppressOceanCover') else 'nil'
        absorbedBy = str(p['absorbedBy']) if p.get('absorbedBy') else 'nil'
        lodLow = ','.join(f'{{{x},{y}}}' for x, y in p.get('lodLow') or p['polygon'])
        holes = ''
        if p.get('holes'):
            parts = []
            for h in p['holes']:
                parts.append('{' + ','.join(f'{{{x},{y}}}' for x, y in h) + '}')
            holes = ',holes={' + ','.join(parts) + '}'
        if p.get('lodLowHoles'):
            parts = []
            for h in p['lodLowHoles']:
                parts.append('{' + ','.join(f'{{{x},{y}}}' for x, y in h) + '}')
            holes = holes + ',lodLowHoles={' + ','.join(parts) + '}'
        entry = f'{{id={p["id"]},name="{p["name"]}",center={{{p["center"][0]},{p["center"][1]}}},'
        entry += f'polygon={{{poly}}},lodLow={{{lodLow}}},'
        entry += f'terrain="{p["terrain"]}",baseGold={p["baseGold"]},'
        entry += f'baseFood={p["baseFood"]},population={p["population"]},ownerId={owner},'
        entry += f'isOcean={isOcean},editorFilled={editorFilled},suppressOceanCover={suppressCover},'
        entry += f'absorbedBy={absorbedBy},neighbors={{{nb}}}{holes}}},'
        entries.append(entry)

    import os
    # 🔴 先清理旧分片（防止旧片残留导致 Provinces.lua 循环 require 加载多余数据）
    import glob
    for old_frag in glob.glob('scripts/data/GeneratedProvinces_*.lua'):
        os.remove(old_frag)
        print('已清理旧分片:', old_frag)
    CHUNK_TARGET = 1_400_000  # 1.4MB（引擎 LoadChunk 限制 ~2MB，留余量）
    chunks = []
    cur = []
    cur_size = 0
    for entry in entries:
        cur.append(entry)
        cur_size += len(entry) + 1
        if cur_size >= CHUNK_TARGET:
            chunks.append(cur)
            cur = []
            cur_size = 0
    if cur:
        chunks.append(cur)
    for idx, chunk in enumerate(chunks):
        fn = f'scripts/data/GeneratedProvinces_{idx + 1}.lua'
        with open(fn, 'w', encoding='utf-8') as f:
            f.write('\n'.join(header + chunk + ['}']) + '\n')
        print(f'已写出: {fn} ({len(chunk)} 省, {os.path.getsize(fn) // 1024} KB)')
    # 移除旧版单文件（避免混淆）
    old = 'scripts/data/GeneratedProvinces.lua'
    if os.path.exists(old):
        os.remove(old)
        print('已移除旧单文件:', old)
    print('分片总数:', len(chunks))

    make_preview(data, PREVIEW)


if __name__ == '__main__':
    main()

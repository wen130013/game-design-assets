#!/usr/bin/env python3
"""
[工具] 按地理位置生成真实春秋势力领土（GeneratedFactions.lua 重建版）。
规则：
  * 用经纬度矩形近似各诸侯国核心区域（春秋大致格局，非精确疆界）
  * 小国矩形优先级高，大国填充剩余区域
  * 不在任何矩形内的省份 → 无主（外围/蛮荒，显示为空白米色）
颜色：沿用 scripts/map/MapRenderer.lua 的 FACTION_GEO_COLORS
用法：python3 gen_factions_geo.py [--mappack eu4|legacy]
  * eu4    默认：读 scripts/data/mappacks/eu4/Provinces_N.lua（centerLon/centerLat）
  * legacy 旧：读 GeneratedProvinces_N.lua 并按旧投影反算经纬度
"""
import os
import re

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(ROOT, 'scripts', 'data')

# ============================================================
# 势力区域表（经纬度矩形，按优先级从高到低分配）
# 每个条目: (fid, name, fullName, aiPersonality, [ (lon1, lon2, lat1, lat2), ... ])
# ============================================================
FACTION_REGIONS = [
    # ---- 周王室 ----
    (1,  "周",  "周王室",  "守成", [(110.5, 112.2, 34.0, 35.2)]),
    # ---- 郑 / 卫 / 宋 / 陈 / 蔡 / 曹（中原小国，精确区域）----
    (9,  "郑",  "郑国",  "求存", [(112.2, 114.0, 34.0, 35.2)]),
    (8,  "卫",  "卫国",  "求存", [(112.2, 115.0, 35.2, 37.0)]),
    (7,  "宋",  "宋国",  "守成", [(114.0, 117.0, 33.0, 34.8)]),
    (14, "陈",  "陈国",  "求存", [(113.5, 115.2, 32.8, 34.0)]),
    (13, "蔡",  "蔡国",  "求存", [(113.5, 115.2, 31.8, 32.8)]),
    (15, "曹",  "曹国",  "求存", [(114.5, 116.2, 34.5, 36.0)]),
    # ---- 齐鲁 ----
    (6,  "鲁",  "鲁国",  "守成", [(115.5, 118.0, 34.0, 36.0)]),
    (2,  "齐",  "齐国",  "霸者", [(116.0, 122.0, 35.8, 38.8)]),
    # ---- 晋 ----
    (3,  "晋",  "晋国",  "霸者", [(109.5, 114.5, 36.0, 39.5)]),
    # ---- 秦 ----
    (5,  "秦",  "秦国",  "掠夺", [(104.0, 109.5, 33.0, 37.0)]),
    # ---- 楚（大矩形填剩余）----
    (4,  "楚",  "楚国",  "霸者", [(108.0, 117.0, 27.0, 33.0)]),
    # ---- 吴越 ----
    (11, "吴",  "吴国",  "守成", [(118.0, 121.5, 30.0, 32.5)]),
    (12, "越",  "越国",  "守成", [(119.0, 122.5, 27.5, 30.5)]),
    # ---- 燕（北）----
    (10, "燕",  "燕国",  "守成", [(114.5, 122.0, 39.0, 42.5)]),
    # ---- 蛮族（北方草原带，按经度分段）----
    (16, "赤狄", "赤狄",  "掠夺", [(109.0, 113.5, 38.0, 40.5)]),
    (17, "白狄", "白狄",  "掠夺", [(104.0, 109.0, 38.0, 41.0)]),
    (18, "长狄", "长狄",  "掠夺", [(113.5, 117.0, 39.5, 42.0)]),
    (19, "山戎", "山戎",  "掠夺", [(113.5, 118.5, 41.5, 44.5)]),  # 燕山以北草原,避开燕
    (20, "犬戎", "犬戎",  "掠夺", [(100.0, 104.0, 34.0, 39.0)]),
    (21, "东胡", "东胡",  "掠夺", [(119.0, 123.0, 42.5, 46.5)]),
    (22, "林胡", "林胡",  "掠夺", [(104.0, 109.0, 41.0, 44.5)]),
    (23, "楼烦", "楼烦",  "掠夺", [(109.0, 114.0, 40.5, 43.5)]),
    # ---- 周边势力（可征服扩张目标，用 24-28）----
    (24, "巴",   "巴国",  "求存", [(104.0, 109.0, 28.5, 32.5)]),
    (25, "蜀",   "蜀国",  "求存", [(100.0, 105.0, 24.0, 29.0)]),
    (26, "百越", "百越",  "求存", [(103.0, 118.0, 20.0, 26.0)]),
    (27, "南蛮", "南蛮",  "求存", [(107.0, 113.0, 25.5, 28.5)]),
    (28, "义渠", "义渠",  "掠夺", [(100.0, 105.0, 34.5, 39.0)]),
]

# 小国（剩余夹缝，暂并入邻近大国；此处保留占位可在后续细化）
SMALL_STATES = {
    24: ("邢", "邢国", "求存"), 25: ("邾", "邾国", "求存"),
    26: ("莒", "莒国", "求存"), 27: ("纪", "纪国", "求存"),
    28: ("许", "许国", "求存"), 29: ("息", "息国", "求存"),
    30: ("申", "申国", "求存"), 31: ("西虢", "西虢", "求存"),
    32: ("邓", "邓国", "求存"), 33: ("随", "随国", "求存"),
    34: ("杞", "杞国", "求存"), 35: ("薛", "薛国", "求存"),
    36: ("滕", "滕国", "求存"), 37: ("黄", "黄国", "求存"),
    38: ("江", "江国", "求存"), 39: ("谭", "谭国", "求存"),
}


def load_faction_colors():
    """从 MapRenderer.lua 提取 FACTION_GEO_COLORS"""
    colors = {}
    text = open(os.path.join(ROOT, 'scripts', 'map', 'MapRenderer.lua'), encoding='utf-8').read()
    in_geo = False
    for line in text.split('\n'):
        if 'FACTION_GEO_COLORS' in line:
            in_geo = True
            continue
        if in_geo:
            if '}' in line and '=' not in line:
                break
            m = re.match(r'\s*\[(\d+)\]\s*=\s*\{\s*(\d+),\s*(\d+),\s*(\d+)\}', line)
            if m:
                colors[int(m.group(1))] = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
    return colors


def load_provinces(mappack='eu4'):
    """读省份数据：返回 [(id, name, lon, lat, cx, cy), ...]
    eu4：读地图包数据分片（带 centerLon/centerLat 字段）
    legacy：读 GeneratedProvinces_N.lua 并按旧投影反算经纬度"""
    provinces = []
    if mappack == 'eu4':
        pack_dir = os.path.join(DATA_DIR, 'mappacks', 'eu4')
        for fname in sorted(os.listdir(pack_dir)):
            if not (fname.startswith('Provinces_') and fname.endswith('.lua')):
                continue
            text = open(os.path.join(pack_dir, fname), encoding='utf-8').read()
            for m in re.finditer(
                    r'\{id=(\d+),name="([^"]*)",center=\{([\d.]+),([\d.]+)\},centerLon=([-\d.]+),centerLat=([-\d.]+)',
                    text):
                pid, name, cx, cy = int(m.group(1)), m.group(2), float(m.group(3)), float(m.group(4))
                lon, lat = float(m.group(5)), float(m.group(6))
                provinces.append((pid, name, lon, lat, cx, cy))
        if not provinces:
            print('[Geo] ⚠️ EU4 地图包数据未找到，回退 legacy 数据源')
            mappack = 'legacy'
    if mappack == 'legacy':
        for fname in sorted(os.listdir(DATA_DIR)):
            if not (fname.startswith('GeneratedProvinces_') and fname.endswith('.lua')):
                continue
            text = open(os.path.join(DATA_DIR, fname), encoding='utf-8').read()
            for m in re.finditer(r'\{id=(\d+),name="([^"]*)",center=\{([\d.]+),([\d.]+)\}', text):
                pid, name, cx, cy = int(m.group(1)), m.group(2), float(m.group(3)), float(m.group(4))
                lon = cx / 450 + 100
                lat = 47 - cy / 222.222
                provinces.append((pid, name, lon, lat, cx, cy))
    return provinces


def load_neighbors(mappack='eu4'):
    """省份邻接表：{pid: set(neighbors)}"""
    neighbors = {}
    if mappack != 'eu4':
        return neighbors
    pack_dir = os.path.join(DATA_DIR, 'mappacks', 'eu4')
    for fname in sorted(os.listdir(pack_dir)):
        if not (fname.startswith('Provinces_') and fname.endswith('.lua')):
            continue
        text = open(os.path.join(pack_dir, fname), encoding='utf-8').read()
        for m in re.finditer(r'\{id=(\d+).*?neighbors=\{(.*?)\}', text):
            pid = int(m.group(1))
            nb = {int(x) for x in m.group(2).split(',') if x.strip()}
            neighbors[pid] = nb
    return neighbors


def build_adjacency(assigned, neighbors):
    """势力邻接：返回 set of frozenset({a, b})（有共同边界线的势力对）"""
    owner = {}
    for fid, plist in assigned.items():
        for p in plist:
            owner[p[0]] = fid
    adj = set()
    for fid, plist in assigned.items():
        for p in plist:
            for nb in neighbors.get(p[0], ()):
                ofid = owner.get(nb)
                if ofid and ofid != fid:
                    adj.add(frozenset((fid, ofid)))
    return adj


def color_dist(c1, c2):
    """曼哈顿 RGB 色差"""
    return abs(c1[0] - c2[0]) + abs(c1[1] - c2[1]) + abs(c1[2] - c2[2])


def pick_far_color(colors, adjacency, fid, threshold):
    """为势力 fid 找一个与所有邻居色差尽量大的颜色（沿色相旋转候选）。
    返回 (candidate, min_dist)；candidate 为 None 表示没有邻居或保持原色。"""
    import colorsys
    neighbor_cols = set()
    for pair in adjacency:
        if fid in pair:
            nf = next(iter(pair - {fid}))
            c = colors.get(nf)
            if c:
                neighbor_cols.add(c)
    if not neighbor_cols:
        return None, None
    cur = colors[fid]
    h, s, v = colorsys.rgb_to_hsv(cur[0] / 255.0, cur[1] / 255.0, cur[2] / 255.0)
    best_c, best_min = None, -1
    for step in range(1, 18):   # 色相每步 +20°
        nh = (h + step * 20 / 360.0) % 1.0
        r, g, b = colorsys.hsv_to_rgb(nh, s, v)
        cand = (round(r * 255), round(g * 255), round(b * 255))
        mind = min(color_dist(cand, nc) for nc in neighbor_cols)
        if mind > best_min:
            best_min, best_c = mind, cand
        if mind >= threshold:
            return cand, mind
    return best_c, best_min


def fix_adjacent_colors(colors, adjacency, threshold=50):
    """相邻势力颜色色差 < threshold 时，调整其中之一（贪心，最多 6 轮）。
    返回 (调整后的 colors, changed: {fid: (old, new)})"""
    colors = dict(colors)
    changed = {}
    for _ in range(6):
        moved = False
        # 按冲突严重程度从大到小处理
        for pair in sorted(adjacency,
                           key=lambda p: -color_dist(colors.get(next(iter(p)), (0, 0, 0)),
                                                     colors.get(list(p)[1], (0, 0, 0)))):
            a, b = tuple(pair)
            ca, cb = colors.get(a), colors.get(b)
            if ca is None or cb is None:
                continue
            if color_dist(ca, cb) >= threshold:
                continue
            # 调整"与邻居冲突更严重"的一方：分别计算双方与各自邻居的最小色差
            def min_neighbor_dist(fid, c):
                best = 1e18
                for pair2 in adjacency:
                    if fid in pair2:
                        nf = next(iter(pair2 - {fid}))
                        nc = colors.get(nf)
                        if nc:
                            best = min(best, color_dist(c, nc))
                return best

            target = a if min_neighbor_dist(a, ca) < min_neighbor_dist(b, cb) else b
            cand, mind = pick_far_color(colors, adjacency, target, threshold)
            if cand and mind > color_dist(colors[target],
                                          colors[next(iter(pair - {target}))] if len(pair - {target}) else (0, 0, 0)):
                old = colors[target]
                colors[target] = cand
                changed[target] = (old, cand)
                moved = True
        if not moved:
            break
    return colors, changed


def write_back_colors(colors):
    """回写 MapRenderer.lua 的 FACTION_GEO_COLORS（保持单一数据源一致）"""
    path = os.path.join(ROOT, 'scripts', 'map', 'MapRenderer.lua')
    text = open(path, encoding='utf-8').read()
    for fid, c in colors.items():
        # 用 lambda 避免 replacement 中 \1 后跟数字被误解析为组引用
        text = re.sub(
            r'(\[\s*' + str(fid) + r'\s*\]\s*=\s*\{)\s*\d+,\s*\d+,\s*\d+(\s*\},)',
            lambda m: m.group(1) + f'{c[0]}, {c[1]}, {c[2]}' + m.group(2),
            text)
    open(path, 'w', encoding='utf-8').write(text)


def assign(provinces, regions):
    """按优先级分配省份到势力"""
    assigned = {fid: [] for fid, *_ in regions}
    unassigned = []
    for p in provinces:
        pid, name, lon, lat, cx, cy = p
        placed = False
        for fid, fname, full, personality, rects in regions:
            for (x1, x2, y1, y2) in rects:
                if x1 <= lon <= x2 and y1 <= lat <= y2:
                    assigned[fid].append(p)
                    placed = True
                    break
            if placed:
                break
        if not placed:
            unassigned.append(p)
    return assigned, unassigned


def main():
    import sys
    mappack = 'eu4'
    for i, a in enumerate(sys.argv):
        if a == '--mappack' and i + 1 < len(sys.argv):
            mappack = sys.argv[i + 1]
    colors = load_faction_colors()
    provinces = load_provinces(mappack)
    print(f'[Geo] 省份总数 {len(provinces)}（数据源: {mappack}）')

    assigned, unassigned = assign(provinces, FACTION_REGIONS)
    for fid, *_ in FACTION_REGIONS:
        print(f'  {fid:2d} 省数: {len(assigned[fid])}')
    print(f'  无主（外围）: {len(unassigned)}')

    # ---- 2026-09-01: 相邻势力颜色检查（百越/南蛮撞色问题）----
    neighbors = load_neighbors(mappack)
    adjacency = build_adjacency(assigned, neighbors)
    print(f'[Geo] 势力相邻关系 {len(adjacency)} 对')
    # 报告当前色差 < 60 的相邻势力
    for pair in sorted(adjacency):
        a, b = tuple(pair)
        ca, cb = colors.get(a), colors.get(b)
        if ca and cb and color_dist(ca, cb) < 50:
            print(f'[Geo] ⚠️ 相邻撞色: {a} {ca} vs {b} {cb} 色差={color_dist(ca, cb)}')
    colors, changed = fix_adjacent_colors(colors, adjacency, threshold=50)
    if changed:
        print('[Geo] 调整相邻势力颜色:')
        for fid, (old, new) in sorted(changed.items()):
            print(f'  {fid}: {old} -> {new}')
        write_back_colors(colors)
        print('[Geo] 已回写 MapRenderer.lua FACTION_GEO_COLORS')

    # 生成 GeneratedFactions.lua
    lines = []
    lines.append('-- ============================================================================')
    lines.append('-- GeneratedFactions.lua - 由 gen_factions_geo.py 生成（按地理位置分配）')
    lines.append('-- 春秋大致格局：15诸侯 + 蛮族；外围无主（空白区块）')
    lines.append('-- ============================================================================')
    lines.append('return {')
    lines.append('')

    for fid, fname, full, personality, rects in FACTION_REGIONS:
        plist = assigned[fid]
        if not plist:
            continue
        color = colors.get(fid, (180, 180, 180))
        # 首府：区域中心最近的省
        cx = sum((x1 + x2) / 2 for x1, x2, *_ in rects) / len(rects)
        cy = sum((y1 + y2) / 2 for *_r, y1, y2 in rects) / len(rects)
        best = plist[0]
        best_d = 1e18
        for p in plist:
            d = (p[2] - cx) ** 2 + (p[3] - cy) ** 2
            if d < best_d:
                best_d = d
                best = p
        pids = ','.join(str(p[0]) for p in plist)
        if fid <= 15:
            army, gold, food = 2500, 150, 120      # 诸侯大国
        elif fid <= 23:
            army, gold, food = 2000, 80, 70        # 北方游牧
        else:
            army, gold, food = 1500, 60, 50        # 周边蛮族（百越/巴蜀等）
        lines.append('{id=' + str(fid)
                     + ',name="' + fname + '"'
                     + ',fullName="' + full + '"'
                     + ',color={' + str(color[0]) + ',' + str(color[1]) + ',' + str(color[2]) + ',255}'
                     + ',provinces={' + pids + '}'
                     + ',capitalId=' + str(best[0])
                     + ',gold=' + str(gold)
                     + ',food=' + str(food)
                     + ',armySize=' + str(army)
                     + ',prestige=50,taxRate=2,stability=70'
                     + ',traits={"春秋"}'
                     + ',aiPersonality="' + personality + '"'
                     + ',diplomacyBonus=0,militaryPenalty=0},')
        lines.append('')

    lines.append('}')
    out = os.path.join(DATA_DIR, 'GeneratedFactions.lua')
    open(out, 'w', encoding='utf-8').write('\n'.join(lines))
    print(f'[Geo] 已写入 {out}')


if __name__ == '__main__':
    main()

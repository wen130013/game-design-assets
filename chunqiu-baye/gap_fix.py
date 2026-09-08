#!/usr/bin/env python3
"""缝隙清零工具：把相邻省份共享边缝隙并入一侧省。"""
import json, math
from shapely.geometry import Polygon, MultiPolygon
from shapely.ops import unary_union

SRC = 'data_work/world_provinces.json'

def main():
    data = json.load(open(SRC, encoding='utf-8'))
    land_idx = [i for i, p in enumerate(data)
                if not p.get('isOcean') and p.get('polygon') and len(p['polygon']) >= 3]
    land_ids = {data[i]['id'] for i in land_idx}

    def to_poly(p):
        g = Polygon(p['polygon'])
        if not g.is_valid:
            g = g.buffer(0)
        return g

    polys = {data[i]['id']: to_poly(data[i]) for i in land_idx}
    pairs = set()
    for i in land_idx:
        p = data[i]
        for nid in (p.get('neighbors') or []):
            if nid in land_ids and nid > p['id']:
                pairs.add((p['id'], nid))

    fixed = 0
    for rnd in range(4):
        changed = 0
        for aid, bid in pairs:
            if aid not in polys or bid not in polys:
                continue
            ga, gb = polys[aid], polys[bid]
            try:
                d = ga.distance(gb)
                if d > 0.3 and d < 60:
                    buf_a = ga.buffer(d + 0.8)
                    buf_b = gb.buffer(d + 0.8)
                    gap = buf_a.intersection(buf_b).difference(ga).difference(gb)
                    if gap.is_empty:
                        continue
                    new_a = unary_union([ga, gap])
                    if isinstance(new_a, MultiPolygon):
                        new_a = max(new_a.geoms, key=lambda g: g.area)
                    if new_a.area > ga.area + 1:
                        polys[aid] = new_a
                        changed += 1
                        fixed += 1
            except Exception:
                pass
        print(f'  第 {rnd+1} 轮修复 {changed} 对')
        if changed == 0:
            break

    print(f'共修复缝隙 {fixed} 处')
    for i in land_idx:
        pid = data[i]['id']
        if pid in polys:
            g = polys[pid]
            ring = [[round(float(x), 1), round(float(y), 1)] for x, y in g.exterior.coords]
            for pt in ring:
                for v in pt:
                    if not math.isfinite(v):
                        raise ValueError(f'NaN id={pid}')
            data[i]['polygon'] = ring
    json.dump(data, open(SRC, 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
    print('已写出')

if __name__ == '__main__':
    main()

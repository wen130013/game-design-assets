#!/usr/bin/env python3
"""
[一次性工具] 从 GADM 重新生成干净数据后，把旧数据的编辑标记迁移过来。
匹配键：(code, name)。只迁移编辑标记，不迁移多边形（多边形用新的干净边界）。
用法：先运行 gen_world_map.py 生成新数据，再运行本脚本。
"""
import json
import sys
from shapely.geometry import Polygon, MultiPolygon
from shapely.ops import unary_union

BACKUP = 'data_work/world_provinces_backup_20260827_2139.json'
SRC = 'data_work/world_provinces.json'
OUT = 'data_work/world_provinces.json'

def main():
    old = json.load(open(BACKUP, encoding='utf-8'))
    new = json.load(open(SRC, encoding='utf-8'))
    print(f'旧数据: {len(old)} 省, 新数据: {len(new)} 省')

    # 1) 按 (code, name) 建立旧数据索引
    old_by_key = {}
    for p in old:
        key = (p.get('code'), p.get('name'))
        old_by_key.setdefault(key, []).append(p)

    # 2) 迁移编辑标记（isOcean / suppressOceanCover / editorFilled / absorbedBy）
    migrated = 0
    unmatched = []
    for p in new:
        key = (p.get('code'), p.get('name'))
        cands = old_by_key.get(key, [])
        # 优先匹配同 name+code；如多个候选取第一个
        if cands:
            o = cands[0]
            for f in ('isOcean', 'suppressOceanCover', 'editorFilled', 'absorbedBy'):
                if o.get(f):
                    p[f] = o[f]
            migrated += 1
        else:
            unmatched.append((key, p.get('id')))
    print(f'成功匹配迁移: {migrated}, 未匹配: {len(unmatched)}')
    for k, i in unmatched[:20]:
        print(f'  未匹配: {k} (id={i})')

    # 3) 斯里兰卡：恢复"合并成 2 块"（兰卡南部/兰卡北部，按中心纬度分组）
    lka = [p for p in new if p.get('code') == 'LKA']
    if lka and not any(p.get('editorFilled') and p.get('name') in ('兰卡南部', '兰卡北部') for p in new):
        print(f'斯里兰卡合并成 2 块（{len(lka)} 个行政区）:')
        try:
            import statistics
            def py(p):
                return sum(pt[1] for pt in p['polygon']) / len(p['polygon'])
            ys = [py(p) for p in lka]
            mid = statistics.median(ys)
            groups = {'兰卡北部': [], '兰卡南部': []}
            for p in lka:
                gname = '兰卡北部' if py(p) <= mid else '兰卡南部'
                groups[gname].append(p)
            for gname, parts in groups.items():
                geoms = []
                for p in parts:
                    g = Polygon(p['polygon'])
                    if not g.is_valid:
                        g = g.buffer(0)  # 修复自相交等无效几何
                    geoms.append(g)
                merged = unary_union(geoms)
                if isinstance(merged, MultiPolygon):
                    merged = max(merged.geoms, key=lambda g: g.area)
                target = {'name': gname, 'code': 'LKA',
                          'polygon': [[round(float(x), 1), round(float(y), 1)]
                                      for x, y in merged.exterior.coords],
                          'isOcean': False, 'editorFilled': True}
                new.append(target)
                for p in parts:
                    p['isOcean'] = True
                    p['suppressOceanCover'] = True
                    p['absorbedBy'] = target['name']  # 用名字做临时键，build 时重排 id 后转 id
                print(f'  {gname}: {len(parts)} 个行政区')
        except Exception as e:
            print(f'  [警告] 斯里兰卡合并失败: {e}')

    # 4) 合并区块（editorFilled）用 shapely 精确并集重建
    n_merged = sum(1 for p in new if p.get('editorFilled') and not p.get('isOcean'))
    print(f'需要精确并集的合并区块: {n_merged}')
    for p in new:
        if not (p.get('editorFilled') and not p.get('isOcean')):
            continue
        parts = [q for q in new if q.get('absorbedBy')
                 and (q.get('absorbedBy') == p.get('id')
                      or q.get('absorbedBy') == p.get('name'))]
        try:
            polys = []
            for q in [p] + parts:
                g = Polygon(q['polygon'])
                if not g.is_valid:
                    g = g.buffer(0)
                polys.append(g)
            merged = unary_union(polys)
            if isinstance(merged, MultiPolygon):
                merged = max(merged.geoms, key=lambda g: g.area)
            p['polygon'] = [[round(float(x), 1), round(float(y), 1)]
                            for x, y in merged.exterior.coords]
            # 把 absorbedBy 从名字统一为 id（重排前临时用名字；这里先不转换）
            for q in parts:
                q['absorbedBy'] = p['id'] if isinstance(p.get('id'), int) else p['name']
            print(f'  [并集] {p["name"]}: {len(parts)} 组成省')
        except Exception as e:
            print(f'  [警告] 并集失败 {p.get("name")}: {e}')

    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(new, f, ensure_ascii=False, separators=(',', ':'))
    print('已写出:', OUT)

if __name__ == '__main__':
    main()

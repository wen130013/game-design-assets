#!/usr/bin/env python3
"""
[工具] 地图数据 <-> GeoJSON 转换（mapshaper 处理用）。
- 编辑标记（isOcean/editorFilled/suppressOceanCover/absorbedBy）放 properties 保留。
- 被吸收省（isOcean + absorbedBy）与 target 重叠，不进 mapshaper（转回时从备份恢复原多边形）。
"""
import json
import sys

def poly_area(ring):
    return abs(0.5 * sum(
        ring[i][0] * ring[(i + 1) % len(ring)][1] - ring[(i + 1) % len(ring)][0] * ring[i][1]
        for i in range(len(ring))
    ))

def to_geojson(data_path, out_path):
    data = json.load(open(data_path, encoding='utf-8'))
    features = []
    skipped = 0
    for p in data:
        if p.get('isOcean') and p.get('absorbedBy'):
            skipped += 1
            continue  # 被吸收省：与 target 重叠，跳过
        coords = [[(float(x), float(y)) for x, y in p['polygon']]]
        features.append({
            'type': 'Feature',
            'properties': {
                'name': p.get('name'),
                'code': p.get('code'),
                'isOcean': bool(p.get('isOcean')),
                'editorFilled': bool(p.get('editorFilled')),
                'suppressOceanCover': bool(p.get('suppressOceanCover')),
                'absorbedBy': p.get('absorbedBy'),
            },
            'geometry': {'type': 'Polygon', 'coordinates': coords},
        })
    fc = {'type': 'FeatureCollection', 'features': features}
    json.dump(fc, open(out_path, 'w', encoding='utf-8'), ensure_ascii=False)
    print(f'→ {out_path}: {len(features)} 个 feature（跳过被吸收省 {skipped}）')

def from_geojson(fc_path, backup_path, out_path):
    fc = json.load(open(fc_path, encoding='utf-8'))
    backup = json.load(open(backup_path, encoding='utf-8'))
    out = []
    for f in fc['features']:
        props = f['properties']
        geom = f['geometry']
        if geom['type'] == 'Polygon':
            ring = geom['coordinates'][0]
        elif geom['type'] == 'MultiPolygon':
            # coordinates = [polygon, ...]，每个 polygon = [ring, ...]；取最大外环
            rings = [p[0] for p in geom['coordinates'] if p]
            ring = max(rings, key=poly_area) if rings else None
        else:
            ring = None
        if ring is None:
            continue
        out.append({
            'name': props.get('name'),
            'code': props.get('code'),
            'polygon': [[round(float(x), 1), round(float(y), 1)] for x, y in ring],
            'isOcean': props.get('isOcean', False),
            'editorFilled': props.get('editorFilled') or None,
            'suppressOceanCover': props.get('suppressOceanCover') or None,
            'absorbedBy': props.get('absorbedBy') or None,
        })
    # 恢复被吸收省（从备份，多边形原样保留）
    restored = 0
    for p in backup:
        if p.get('isOcean') and p.get('absorbedBy'):
            out.append({
                'name': p.get('name'),
                'code': p.get('code'),
                'polygon': p['polygon'],
                'isOcean': True,
                'suppressOceanCover': True,
                'absorbedBy': p.get('absorbedBy'),
            })
            restored += 1
    json.dump(out, open(out_path, 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
    print(f'← {out_path}: {len(out)} 个（恢复被吸收省 {restored}）')

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'to':
        to_geojson(sys.argv[2], sys.argv[3])
    elif cmd == 'from':
        from_geojson(sys.argv[2], sys.argv[3], sys.argv[4])

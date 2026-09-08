#!/usr/bin/env python3
"""
[工具] 生成细粒度世界地图（等距圆柱投影）：
  * 数据源：Natural Earth 10m admin-1（全球一级行政区，4596 区域）
  * 中国区域 = 中国省级（Xinjiang/Guangdong...）
  * 每区域一个 ID，栅格化到 world_province_id.png
产出：
  * assets/image/world_province_id.png（4096×2048，R=0, G=id>>8, B=id&0xFF, 0=海）
  * scripts/data/WorldProvinces_N.lua（分片：id, name, center, polygon）
用法：python3 gen_world_map.py（依赖 pyshp）
"""
import math
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.abspath(__file__))
SHP = os.path.join(ROOT, 'data', 'world', 'ne_10m_admin_1_states_provinces.shp')
OUT_BITMAP = os.path.join(ROOT, 'assets', 'image', 'world_province_id.png')
OUT_DATA = os.path.join(ROOT, 'scripts', 'data')

# 等距圆柱投影，位图尺寸
W, H = 4096, 2048


def project(lon, lat):
    return (lon + 180.0) / 360.0 * W, (90.0 - lat) / 180.0 * H


def ring_area(ring):
    a = 0.0
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        a += x1 * y2 - x2 * y1
    return a / 2.0


def shape_to_rings(shape):
    """shapefile shape → 环列表 [(lon,lat),...]；按面积排序，最大环在前（外环）"""
    pts = shape.points
    parts = list(shape.parts) + [len(pts)]
    rings = []
    for i in range(len(parts) - 1):
        ring = [(p[0], p[1]) for p in pts[parts[i]:parts[i + 1]]]
        if len(ring) >= 3:
            rings.append(ring)
    rings.sort(key=lambda r: abs(ring_area(r)), reverse=True)
    return rings  # rings[0] 外环，其余 holes


def main():
    import shapefile
    sf = shapefile.Reader(SHP)
    n_total = len(sf)
    print(f'[World] admin-1 总区域 {n_total}')

    img = Image.new('RGB', (W, H), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    regions = []   # (id, name, center, polygon_px)
    next_id = 1

    # 收集所有区域的环（外环 + holes），两遍绘制：
    #   第一遍所有 holes 画海 0，第二遍所有外环画 id → 包含关系正确
    hole_draws = []
    outer_draws = []
    names = []
    for rec, shape in zip(sf.records(), sf.shapes()):
        name_zh = rec['name_zh'] or ''
        name = name_zh if name_zh else (rec['name'] or '')
        if not name:
            name = str(next_id)
        # 跳过南极洲
        adm0 = rec['adm0_a3'] or ''
        names.append((next_id, name, adm0))
        rings = shape_to_rings(shape)
        if not rings:
            continue
        outer = rings[0]
        holes = rings[1:]
        outer_pts = [project(lon, lat) for lon, lat in outer]
        if len(outer_pts) >= 3:
            outer_draws.append((outer_pts, next_id))
        for h in holes:
            hp = [project(lon, lat) for lon, lat in h]
            if len(hp) >= 3:
                hole_draws.append(hp)
        # center：外环顶点平均
        cx = sum(p[0] for p in outer_pts) / len(outer_pts)
        cy = sum(p[1] for p in outer_pts) / len(outer_pts)
        regions.append((next_id, name, (cx, cy), outer_pts))
        next_id += 1

    print(f'[World] 待栅格化区域 {len(regions)}')

    # 1. holes → 海
    for hp in hole_draws:
        draw.polygon(hp, fill=(0, 0, 0))
    # 2. 外环 → id 色
    for pts, rid in outer_draws:
        draw.polygon(pts, fill=(0, (rid >> 8) & 0xFF, rid & 0xFF))

    img.save(OUT_BITMAP, optimize=True)
    print(f'[World] 已保存位图 {OUT_BITMAP} ({W}x{H})')

    # 生成省份数据（Lua 分片，每片 ~350KB）
    chunk = []
    chunk_size = 0
    chunk_idx = 1
    total_size = 0

    def flush_chunk():
        nonlocal chunk, chunk_size, chunk_idx
        if not chunk:
            return
        path = os.path.join(OUT_DATA, f'WorldProvinces_{chunk_idx}.lua')
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write('return {\n')
            fh.write('\n'.join(chunk))
            fh.write('\n}\n')
        print(f'[World] 数据分片 {chunk_idx}: {len(chunk)} 区域, {os.path.getsize(path) // 1024}KB')
        chunk_idx += 1
        chunk = []
        chunk_size = 0

    for rid, name, (cx, cy), px in regions:
        pts = ','.join('{%d,%d}' % (int(round(x)), int(round(y))) for x, y in px)
        rec = '{id=%d,name="%s",center={%d,%d},polygon={%s}},' % (
            rid, name, int(round(cx)), int(round(cy)), pts)
        chunk.append(rec)
        chunk_size += len(rec)
        total_size += len(rec)
        if chunk_size > 350 * 1024:
            flush_chunk()
    flush_chunk()

    print(f'[World] 总区域 {len(regions)}, 数据约 {total_size // 1024}KB')


if __name__ == '__main__':
    main()

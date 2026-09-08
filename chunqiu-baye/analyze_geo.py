#!/usr/bin/env python3
"""分析省份中心坐标分布（经纬度网格统计），确定春秋核心区"""
import re
import os

provinces = []
for fname in sorted(os.listdir('scripts/data')):
    if not (fname.startswith('GeneratedProvinces_') and fname.endswith('.lua')):
        continue
    text = open(os.path.join('scripts/data', fname), encoding='utf-8').read()
    for m in re.finditer(r'\{id=(\d+),name="([^"]*)",center=\{([\d.]+),([\d.]+)\}', text):
        pid, name, cx, cy = int(m.group(1)), m.group(2), float(m.group(3)), float(m.group(4))
        lon = cx / 450 + 100
        lat = 47 - cy / 222.222
        provinces.append((pid, name, lon, lat))

print('总省数:', len(provinces))
# 经纬度范围
lons = [p[2] for p in provinces]
lats = [p[3] for p in provinces]
print('经度范围: %.1f - %.1f' % (min(lons), max(lons)))
print('纬度范围: %.1f - %.1f' % (min(lats), max(lats)))

# 2x2 度网格统计省数
from collections import defaultdict
grid = defaultdict(list)
for pid, name, lon, lat in provinces:
    gx = int((lon - 100) // 2)
    gy = int((lat - 20) // 2)
    grid[(gx, gy)].append((pid, name, lon, lat))

print()
print('经纬度网格省数分布 (2°×2°, x=经度100起, y=纬度20起):')
for gy in range(13, -1, -1):
    row = []
    for gx in range(0, 13):
        n = len(grid.get((gx, gy), []))
        row.append(' %3d' % n if n else '  · ')
    print('lat %2d-%2d |' % (20 + gy*2, 20 + gy*2 + 2), ' '.join(row))
print('        lon:  100   102   104   106   108   110   112   114   116   118   120   122   124')

#!/usr/bin/env python3
"""
gen_terrain.py — 生成真实地理地形数据（给两个地图包用）

数据源（均为**公有领域 / 开放**的真实地理数据，非任何游戏资产）：
  1) Natural Earth 地理区域（山脉/沙漠/平原/盆地/高原/三角洲…）
     curl -o ~/ne_tmp/ne_10m_regions.geojson \
       https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_geography_regions_polys.geojson
  2) WWF 陆地生态区（14 生物群系）GeoJSON 转换版
     curl -L -o ~/ne_tmp/eco.zip https://github.com/gentopia/ecoregions-geojson/archive/refs/heads/master.zip
     unzip -q ~/ne_tmp/eco.zip -d ~/ne_tmp/eco

判定：每个省的多边形与两类数据求交、按面积占比 + 优先级定地形（11 种）。
      大河农业区用"农田锚点"矩形修正（尼罗河/两河/印度河-恒河/关中/成都/长江中下游…）。

输出：scripts/data/TerrainReal.lua   { [packId] = { [provId] = "地形名" } }

用法：python3 gen_terrain.py
"""
import json, re, glob, os, sys
from shapely.geometry import shape, Polygon
from shapely import STRtree

ROOT = os.path.dirname(os.path.abspath(__file__))
NE_DIR = os.path.expanduser('~/ne_tmp')
OUT = os.path.join(ROOT, 'scripts', 'data', 'TerrainReal.lua')

# ---- 地形映射 ----
NE2T = {"Range/mtn":"山地","Foothills":"丘陵","Plateau":"丘陵","Desert":"沙漠","Tundra":"冻土",
        "Wetlands":"沼泽","Delta":"沼泽","Basin":"丘陵","Valley":"平原","Plain":"平原","Lowland":"平原"}
BIO2T = {1:"森林", 2:"森林", 3:"针叶林", 4:"森林", 5:"针叶林", 6:"针叶林",
         7:"草原", 8:"草原", 9:"沼泽", 10:"草原", 11:"冻土", 12:"森林", 13:"沙漠", 14:"沼泽"}

# 农田锚点（lonMin, lonMax, latMin, latMax）——大河农业区，数据源覆盖不到，人工圈定
FARM_ANCHORS = [
    (29, 33, 22, 32),      # 尼罗河谷
    (38, 49, 29, 37),      # 两河流域
    (67, 73, 24, 34),      # 印度河平原
    (72, 92, 21, 31),      # 恒河平原
    (106, 111.5, 33, 35.5),# 关中平原
    (103, 105.5, 29.5, 31.5),# 成都平原
    (110, 122, 28, 33.5),  # 长江中下游
    (105, 120, 32, 40),    # 黄河中下游
    (12, 16, 44.5, 46.5),  # 波河平原
    (16, 28, 44, 48),      # 多瑙河下游平原
]

def in_anchor(lon, lat):
    for x0, x1, y0, y1 in FARM_ANCHORS:
        if x0 <= lon <= x1 and y0 <= lat <= y1:
            return True
    return False

# ---- 拟合投影（每包各自的 像素↔经纬度 线性关系，从 center 点最小二乘） ----
def fit(provs):
    use = [p for p in provs if len(p['pts']) >= 3]
    n = len(use)
    sx = sum(p['cx'] for p in use); sl = sum(p['lon'] for p in use)
    sxl = sum(p['cx']*p['lon'] for p in use); sll = sum(p['lon']*p['lon'] for p in use)
    sy = sum(p['cy'] for p in use); st = sum(p['lat'] for p in use)
    syt = sum(p['cy']*p['lat'] for p in use); stt = sum(p['lat']*p['lat'] for p in use)
    a = (n*sxl - sx*sl)/(n*sll - sl*sl); b = (sx - a*sl)/n
    c = (n*syt - sy*st)/(n*stt - st*st); d = (sy - c*st)/n
    return a, b, c, d

PAT = re.compile(r'\{id=(\d+),name="((?:[^"\\]|\\.)*)",center=\{(\d+),(\d+)\},'
                 r'centerLon=(-?[\d.]+),centerLat=(-?[\d.]+),area=(\d+)(,isWasteland=true)?,'
                 r'polygon=\{(.*?)\},neighbors=')

def load_provs(pack):
    out = []
    for path in sorted(glob.glob(os.path.join(ROOT, 'scripts/data/mappacks/%s/Provinces_*.lua' % pack))):
        for line in open(path, encoding='utf-8'):
            m = PAT.search(line)
            if not m:
                continue
            pts = [(int(x), int(y)) for x, y in re.findall(r'\{(\d+),(\d+)\}', m.group(9))]
            out.append(dict(id=int(m.group(1)), name=m.group(2), cx=int(m.group(3)), cy=int(m.group(4)),
                            lon=float(m.group(5)), lat=float(m.group(6)), area=int(m.group(7)),
                            wasteland=bool(m.group(8)), pts=pts))
    return out

def main():
    # 数据加载
    gj = json.load(open(os.path.join(NE_DIR, 'ne_10m_regions.geojson')))
    ne = [(f['properties'].get('FEATURECLA'), f['properties'].get('FEATURECLA'), shape(f['geometry']))
          for f in gj['features'] if f['properties'].get('FEATURECLA') in NE2T]
    ne_tree = STRtree([g for _, _, g in ne])
    print('NE 地貌:', len(ne), flush=True)

    bio = []
    for fn in glob.glob(os.path.join(NE_DIR, 'eco/ecoregions-geojson-master/data/*/*/*/*.json')):
        try:
            dd = json.load(open(fn))
        except Exception:
            continue
        for f in dd.get('features', []):
            p = f.get('properties', {})
            num = p.get('BIOME_NUM')
            if num in BIO2T and f.get('geometry'):
                try:
                    bio.append((int(num), p.get('ECO_NAME'), shape(f['geometry'])))
                except Exception:
                    pass
    bio_tree = STRtree([g for _, _, g in bio])
    print('WWF 生态区:', len(bio), flush=True)

    def frac_by(poly, cands, tree, pred):
        tot = 0.0
        for i in tree.query(poly):
            fc, nm, g = cands[i]
            if pred(fc) and g.intersects(poly):
                tot += g.intersection(poly).area
        return tot/poly.area if poly.area > 0 else 0

    result = {}
    for pack in ('eu4', 'world'):
        provs = load_provs(pack)
        a, b, c, d = fit(provs)
        print('[%s] 省 %d, 投影 x=%.4f*lon+%.1f y=%.4f*lat+%.1f' % (pack, len(provs), a, b, c, d), flush=True)
        tbl = {}
        TH = 0.15
        for p in provs:
            pts = [((px-b)/a, (py-d)/c) for px, py in p['pts']]
            if len(pts) < 3:
                tbl[p['id']] = '平原'
                continue
            poly = Polygon(pts)
            if not poly.is_valid:
                poly = poly.buffer(0)
            if poly.is_empty:
                tbl[p['id']] = '平原'
                continue
            nef = lambda *fcs: frac_by(poly, ne, ne_tree, lambda fc: fc in fcs)
            bf  = lambda *nums: frac_by(poly, bio, bio_tree, lambda nm: nm in nums)
            lat = p['lat']
            if abs(lat) >= 66:
                tbl[p['id']] = '冻土'; continue
            if abs(lat) >= 55:
                tbl[p['id']] = '针叶林'; continue
            mtn   = nef("Range/mtn")
            des   = nef("Desert") + bf(13)
            wet   = nef("Wetlands", "Delta") + bf(9, 14)
            tund  = nef("Tundra") + bf(11)
            plain = nef("Plain", "Lowland", "Valley")
            basin = nef("Basin")
            hill  = nef("Plateau", "Foothills")
            jun   = bf(1)
            conif = bf(3, 5, 6)
            forest= bf(2, 4, 12)
            steppe= bf(7, 8, 10)
            if mtn >= TH:   t = '山地'
            elif des >= TH: t = '沙漠'
            elif wet >= TH: t = '沼泽'
            elif tund >= TH:t = '冻土'
            elif in_anchor(p['lon'], p['lat']):           t = '农田'   # 大河农业区锚点
            elif plain + basin >= 0.40:                   t = '农田'
            elif conif >= TH:t = '针叶林'
            elif jun >= TH and abs(lat) <= 22:            t = '丛林'
            elif forest >= TH or jun >= TH:               t = '森林'
            elif steppe >= TH:                            t = '草原'
            elif plain + basin >= TH:                     t = '平原'
            elif hill >= TH:                              t = '丘陵'
            else:                                         t = '平原'
            tbl[p['id']] = t
        result[pack] = tbl
        import collections
        print('[%s]' % pack, dict(collections.Counter(tbl.values()).most_common()), flush=True)

    # 写 Lua
    name_map = {}
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('-- 真实地理地形（Natural Earth 地貌 + WWF 生态区 + 农田锚点），由 gen_terrain.py 生成，勿手改\n')
        f.write('-- 生成日期见文件版本；数据均为公开地理数据，非游戏资产\n')
        f.write('return {\n')
        for pack in ('eu4', 'world'):
            f.write('  %s = {\n' % pack)
            items = sorted(result[pack].items())
            line = '   '
            for pid, t in items:
                piece = ' [%d]="%s",' % (pid, t)
                if len(line) + len(piece) > 110:
                    f.write(line + '\n')
                    line = '   '
                line += piece
            if line.strip():
                f.write(line + '\n')
            f.write('  },\n')
        f.write('}\n')
    print('saved', OUT, os.path.getsize(OUT), 'bytes', flush=True)

if __name__ == '__main__':
    main()

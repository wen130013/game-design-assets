#!/usr/bin/env python3
"""
[工具] 生成静态显示色 LUT（province_lut.png，4096×1，索引=省ID，RGB=颜色）。
背景：引擎 SurfaceShader 材质在首次渲染后，SetData / 替换纹理均不刷新
（GPU 采样器缓存），动态 LUT 出不来；改为 P 社式"位图即数据"——
静态 LUT 作为 pak 资源在 create 时一次性绑定，势力色随归属在构建期写死。
本脚本每次 GeneratedFactions/势力归属变化后跑一次。
用法：python3 gen_static_lut.py [--mappack eu4|legacy]
  * eu4    默认：输出 assets/image/eu4/province_lut.png（EU4 地图包）
  * legacy      ：输出 assets/image/province_lut.png（旧地图）
依赖：pip install pillow
"""
import re
import os
from PIL import Image

LUT_W = 4096
SEA = (156, 183, 212)
LAND = (210, 196, 158)

ROOT = os.path.dirname(os.path.abspath(__file__))


def parse_factions():
    """返回 {pid: (r,g,b)} 省ID→势力色，以及全部省 id 集合"""
    fac_path = os.path.join(ROOT, 'scripts', 'data', 'GeneratedFactions.lua')
    pid_color = {}
    with open(fac_path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            m = re.match(r'\{id=(\d+),', line)
            if not m or 'provinces={' not in line:
                continue
            cm = re.search(r'color=\{(\d+),(\d+),(\d+),\d+\}', line)
            pm = re.search(r'provinces=\{([\d,]+)\}', line)
            if not cm or not pm:
                continue
            color = (int(cm.group(1)), int(cm.group(2)), int(cm.group(3)))
            for pid_s in pm.group(1).split(','):
                if pid_s:
                    pid_color[int(pid_s)] = color
    return pid_color


def main():
    import sys
    mappack = 'eu4'
    for i, a in enumerate(sys.argv):
        if a == '--mappack' and i + 1 < len(sys.argv):
            mappack = sys.argv[i + 1]
    pid_color = parse_factions()
    print(f"[LUT] 势力覆盖省份 {len(pid_color)} 个")

    img = Image.new('RGB', (LUT_W, 1))
    px = img.load()
    # 索引 0 = 海色
    px[0, 0] = SEA
    land_n, fac_n = 0, 0
    for i in range(1, LUT_W):
        if i in pid_color:
            px[i, 0] = pid_color[i]
            fac_n += 1
        else:
            px[i, 0] = LAND  # 无主陆地省默认米色；海省份图 pid=0 不会来这里
            land_n += 1
    if mappack == 'eu4':
        out = os.path.join(ROOT, 'assets', 'image', 'eu4', 'province_lut.png')
    else:
        out = os.path.join(ROOT, 'assets', 'image', 'province_lut.png')
    img.save(out, optimize=True)
    print(f"[LUT] 已写 {out}: 势力色 {fac_n} 个, 默认陆地色 {land_n} 个")


if __name__ == '__main__':
    main()

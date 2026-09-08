#!/usr/bin/env python3
"""
[工具] EU4 省份 SVG → 欧亚非地图包生成器（2026-08-31 重大替换）

流程：
  1. 解析 data/eu4/eu4_provinces.svg（MapChart EU4 地图，1200×480 等距圆柱，3360 path）
  2. 裁剪欧亚非：按坐标剔除美洲 + 黑名单剔除大洋洲（保留东南亚全部）
  3. 贝塞尔细分 → PIL 栅格化到 2640×1920（SVG 660×480 区域 × 4）
  4. 缝隙填充（8 邻多数投票，2 轮）
  5. 提取省份数据：id/name/center(质心)/centerLonLat/area/polygon(简化主环)/holes
  6. 输出地图包：
       assets/image/eu4/province_id.png    省 ID 位图（R=0,G=id>>8,B=id&0xFF）
       assets/image/eu4/map_political.png  成品图（海色+底图感配色+边界/海岸）
       assets/image/eu4/province_lut.png   显示色 LUT（4096×1）
       assets/image/eu4/tiles/map_TX_TY.png  瓦片（1024px）
       scripts/data/mappacks/eu4.lua           地图包配置
       scripts/data/mappacks/eu4/Provinces_N.lua 省份数据分片
依赖：pip install pillow numpy
"""
import colorsys
import math
import os
import re

import cv2
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.abspath(__file__))
SVG_PATH = os.path.join(ROOT, 'data', 'eu4', 'eu4_provinces.svg')

# 输出目录
ASSET_DIR = os.path.join(ROOT, 'assets', 'image', 'eu4')
TILE_DIR = os.path.join(ASSET_DIR, 'tiles')
DATA_DIR = os.path.join(ROOT, 'scripts', 'data', 'mappacks', 'eu4')

# ---------------------------------------------------------------------------
# 地图包几何（欧亚非裁剪后）
# ---------------------------------------------------------------------------
# SVG 等距圆柱：x=0..1200 ↔ lon=-180..180；y 纬度范围已标定（见 LAT_NORTH）
# 欧亚非范围：x∈[540,1200]（lon∈[-18°,180°]），y∈[0,480]
CROP_X0 = 495          # 裁剪起点（美洲东界外，大西洋中；格陵兰东端 x1=490.6）
SVG_W = 1200.0
SVG_H = 480.0
SCALE = 8              # 放大倍数（2026-08-31 高清化：位图 5640×3840）
BITMAP_W = int((SVG_W - CROP_X0) * SCALE)   # 2820
BITMAP_H = int(SVG_H * SCALE)               # 1920
# 纬度标定（2026-08-31 城市点回归）：
#   MapChart EU4 经度=标准等距圆柱（1200px ↔ 360°），纬度=等距圆柱但范围
#   约 78.54°N..-42.03°S（y=0 为 78.54°N，px/度=3.981），不是 90..-90。
LAT_NORTH = 78.54       # SVG 顶边纬度（°N）
PX_PER_DEG_LAT = 3.981  # SVG 纬度像素密度（px/°）

# ---------------------------------------------------------------------------
# 春秋战国可玩区域（经纬度矩形；矩形外 = 更外围，全部沙漠化）
# 可玩 = 中原诸侯 + 南方蛮族 + 北方游牧这一圈；更外围(西伯利亚/中亚/印度/
# 中东/欧洲/非洲/东南亚海岛) = 沙漠空白，不可占领、无产出
# ---------------------------------------------------------------------------
PLAYABLE_REGION = [
    (97.0, 125.0, 19.0, 47.0),    # 中国本部 + 南方蛮族 + 蒙古东部
    (125.0, 131.0, 40.0, 47.0),   # 东北 / 朝鲜半岛
    (95.0, 97.0, 35.0, 42.0),     # 河西走廊
]

DESERT_RGB = (200, 162, 98)       # 沙漠色（与运行时 isWasteland 渲染一致）

# 可玩区省份中文名映射（EU4 英文名 → 中文，未映射的保留原名）
NAME_CN = {
    "Alchuka": "肃慎",
    "Alxa": "贺兰",
    "Anding": "泾州",
    "Andong": "辽东",
    "Anqing": "皖",
    "Badain Jaran": "流沙",
    "Baoding": "易水",
    "Bayankhongor": "大漠",
    "Bayisingtu": "大漠",
    "Beijing": "蓟",
    "Boduna": "肃慎",
    "Bozhou": "夜郎",
    "Canton": "番禺",
    "Cao Bang": "瓯雒",
    "Chahar": "代北",
    "Changbai Mountains": "不咸山",
    "Changsha": "长沙",
    "Chaochow": "百越",
    "Chengde": "山戎",
    "Chengdu": "成都",
    "Chiang Mai": "越裳",
    "Chiang Rai": "越裳",
    "Chongqing": "巴",
    "Dali": "昆明",
    "Daming": "五鹿",
    "Datong": "雁门",
    "Dazhou": "宕渠",
    "Dege": "羌",
    "Dehong": "哀牢",
    "Dong Kinh": "瓯雒",
    "Dornogovi": "大漠",
    "Dundgovi": "大漠",
    "Edala": "肃慎",
    "Ejin": "居延",
    "Ereen": "大漠",
    "Fengxiang": "雍城",
    "Fengyang": "钟离",
    "Fuyang": "胡",
    "Fuzhou": "闽越",
    "Fu’erhe": "肃慎",
    "Gaizhou": "辽东",
    "Ganggye": "貊",
    "Ganzhou": "赣",
    "Gaoligong Mountains": "哀牢",
    "Garze": "羌",
    "Girin": "肃慎",
    "Govi": "大漠",
    "Guangnan": "百越",
    "Guilin": "桂林",
    "Guiyang": "牂牁",
    "Gyeongseong": "貊",
    "Ha Tinh": "瓯雒",
    "Hai Phong": "瓯雒",
    "Haicheng": "辽东",
    "Haizhou": "郯",
    "Hangzhou": "钱塘",
    "Hanzhong": "南郑",
    "Hefei": "巢",
    "Hejian": "武垣",
    "Hengduan Mountains": "嶲",
    "Hengyang": "衡山",
    "Hetao": "河南地",
    "Hetu Ala": "肃慎",
    "Hkamti Long": "哀牢",
    "Hohhot": "云中",
    "Hsenwi": "哀牢",
    "Huaiqing": "温",
    "Huai’an": "淮阴",
    "Huangzhou": "邾",
    "Huizhou": "新安",
    "Hulan": "肃慎",
    "Huncun": "肃慎",
    "Hung Hoa": "瓯雒",
    "Ilan Hala": "肃慎",
    "Jianchang": "邛都",
    "Jianning": "闽越",
    "Jianzhou": "肃慎",
    "Jiazhou": "蜀",
    "Jinan": "泺",
    "Jingzhou": "郢",
    "Jinhua": "乌伤",
    "Jirem": "东胡",
    "Ji’an": "庐陵",
    "Josutu": "孤竹",
    "Ju Ud": "东胡",
    "Kaifeng": "启封",
    "Kalgan": "代北",
    "Kelang": "百越",
    "Kengtung": "哀牢",
    "Khara Narin Ula": "代北",
    "Kingchow": "百越",
    "Korchin": "东胡",
    "Laizhou": "莱",
    "Lampang": "越裳",
    "Lamphun": "越裳",
    "Langzhong": "阆中",
    "Lanzhou": "金城",
    "Leichow": "百越",
    "Liangzhou": "姑臧",
    "Lijiang": "昆明",
    "Limchow": "百越",
    "Lingyun": "百越",
    "Liuzhou": "百越",
    "Luang Namtha": "越裳",
    "Luang Prabang": "越裳",
    "Luoyang": "雒阳",
    "Luzhou": "江阳",
    "Lu’an": "六",
    "Macau": "百越",
    "Maolian": "肃慎",
    "Markam": "羌",
    "Mawkmai": "哀牢",
    "Mergen": "肃慎",
    "Middag": "岛夷",
    "Mong Kawng": "哀牢",
    "Mong Kung": "哀牢",
    "Mong Nai": "哀牢",
    "Mong Pai": "越裳",
    "Muang Ngoi": "越裳",
    "Namning": "百越",
    "Nan": "越裳",
    "Nanchang": "豫章",
    "Nanjing": "金陵",
    "Nanyang": "宛",
    "Ngaichow": "儋耳",
    "Ngchow": "苍梧",
    "Nghe An": "瓯雒",
    "Ningbo": "甬东",
    "Ningguo": "宛陵",
    "Ningguta": "肃慎",
    "Ningwu": "楼烦",
    "Ningxia": "朔方",
    "Ningyuan": "辽东",
    "Noyon": "大漠",
    "Ordos": "榆中",
    "Pingliang": "泾阳",
    "Pingyang": "平阳",
    "Poyang": "番",
    "Pu’er": "哀牢",
    "Qamdo": "羌",
    "Qaraqorum": "龙城",
    "Qilian": "焉支",
    "Qingzhou": "纪",
    "Quang Ninh": "瓯雒",
    "Quanzhou": "闽越",
    "Rebgong": "羌",
    "Runing": "蔡",
    "Sainshand": "大漠",
    "Sakam": "百越",
    "Sartu": "大漠",
    "Setsen": "大漠",
    "Shangqiu": "商丘",
    "Shaoxin": "会稽",
    "Shenyang": "辽东",
    "Shiuhing": "百越",
    "Shiukwan": "百越",
    "Sibsongbanna": "哀牢",
    "Sikhottabong": "越裳",
    "Song La": "瓯雒",
    "Songqu": "氐羌",
    "Suzhou": "姑苏",
    "Tachienlu": "羌",
    "Taining": "东胡",
    "Taiyuan": "晋阳",
    "Taozhou": "洮",
    "Thanh Hoa": "瓯雒",
    "Tianshui": "冀",
    "Tingzhou": "闽越",
    "Tongren": "黔中",
    "Ujimqin": "东胡",
    "Umung": "夜郎",
    "Urad": "河南地",
    "Vientiane": "越裳",
    "Waichow": "百越",
    "Wenzhou": "瓯",
    "Wuchang": "鄂",
    "Wuding": "无棣",
    "Wuling": "巫中",
    "Xiangyang": "邓",
    "Xiankhouang": "越裳",
    "Xilin Gol": "东胡",
    "Xining": "湟中",
    "Xi’an": "镐京",
    "Xuanhua": "上谷",
    "Xuzhou": "彭城",
    "Yangzhou": "邗",
    "Yanzhou": "瑕丘",
    "Yan’an": "高奴",
    "Yehe": "肃慎",
    "Yeongbyeon": "貊",
    "Yichang": "夷陵",
    "Yongping": "孤竹",
    "Yuanling": "辰阳",
    "Yukjin": "肃慎",
    "Yunnan": "滇",
    "Zhangye": "甘州",
    "Zhending": "东垣",
    "Zhenjiang": "朱方",
    "Zhenyuan": "黔中",
}


def in_playable(lon, lat):
    for (x1, x2, y1, y2) in PLAYABLE_REGION:
        if x1 <= lon <= x2 and y1 <= lat <= y2:
            return True
    return False

# ---------------------------------------------------------------------------
# 裁剪名单
# ---------------------------------------------------------------------------
# 美洲：path 中心 x < 540 全部剔除，以下岛屿虽在大西洋西部但属欧亚非，保留
KEEP_ATLANTIC = {"Reykjavik", "The_Azores", "Cabo_Verde"}

# 大洋洲：显式黑名单（新几内亚 / 澳大利亚 / 新西兰 / 太平洋群岛）
# 东南亚（苏门答腊/爪哇/婆罗洲/苏拉威西/马鲁古/菲律宾/帝汶）属亚洲，保留
DROP_OCEANIA = {
    # ---- 新几内亚 & 美拉尼西亚 ----
    "Papua", "Manokwari", "Fak-Fak", "Asmat", "Yos_Sudarso", "Aru", "Yamdena",
    "Daru", "Rabaul", "Madang", "Lae", "Kerema", "Hanuabada",
    # ---- 澳大利亚（原住民领地） ----
    "Yolngu", "Guugu_Yimithirr", "Western_Australia", "Central_Australia",
    "Wunambul", "Kurtjar", "Mingin", "Ngadjuri", "Waveroo", "Gunditjmara",
    "Wergaia", "Nukunu", "Kaurna", "Wurundjeri", "Peerapper", "Awngthim",
    "Tiwi", "Woolna", "Kurrama", "Malgana", "Nyaki-Nyaki", "Wadjuk", "Minang",
    "Baiali", "Yagalingu", "Biri", "Turrbal", "Bidjara", "Wuli-Wuli", "Gureng",
    "Badtjala", "Yiman", "Gubbi-Gubbi", "Barunggam", "Kamilaroi", "Wiradjuri",
    "Bundjalung", "Eora", "Dharug", "Gundungurra", "Tharawal", "Yuin",
    "Pyemmairrener", "Paredarerme", "Wulgurukaba", "Mangala", "Yuat",
    "Christmas_Island",
    # ---- 新西兰 ----
    "Whangarei", "Kirikiriroa", "Tauranga", "Te_Moana-a-Toi", "Ahuriri",
    "Taranaki", "Timaru", "Ata_Whenua", "Te_Tau_Ihu",
    # ---- 太平洋群岛（密克罗尼西亚/美拉尼西亚/波利尼西亚） ----
    "Vanua_Levu", "Viti_Levu", "Lau", "Vanuatu", "New_Caledonia",
    "Solomon_Islands", "Marshall_Islands", "Gilbert_Islands", "Nauru",
    "Tuvalu", "Micronesia", "Palau", "Guam", "Wake",
}

# ---------------------------------------------------------------------------
# SVG path 解析（严格按命令解析，支持 M/L/H/V/C/Q/S/T/A/Z 及隐式重复）
# ---------------------------------------------------------------------------
NUM_RE = re.compile(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')
CMD_RE = re.compile(r'[MmLlHhVvCcQqSsTtAaZz]')


TOKEN_RE = re.compile(r'[MmLlHhVvCcQqSsTtAaZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')

def tokenize_all(d):
    """返回混合 token 流：字母命令或数字字符串（一次 findall）"""
    out = []
    for t in TOKEN_RE.findall(d):
        if t[0] in 'MmLlHhVvCcQqSsTtAaZz' and len(t) == 1:
            out.append(t)
        else:
            out.append(float(t))
    return out


def parse_path(d):
    """解析 path d → 子路径列表，每个子路径为 [(x,y),...] 折线（已细分）。
    返回 [[(x,y),...], ...]（每个 M 开始一个子路径）。健壮版：参数不足时强制前进，防死循环。"""
    toks = tokenize_all(d)
    subpaths = []
    cur = None
    x, y = 0.0, 0.0          # 当前点
    sx, sy = 0.0, 0.0        # 子路径起点
    prev_cmd = 'M'
    prev_raw = 'M'            # 原始大小写(隐式重复的 abs_mode 依据)
    prev_c = (0.0, 0.0)      # 前一个 C 的第二控制点
    prev_q = (0.0, 0.0)      # 前一个 Q 的控制点

    def new_subpath():
        nonlocal cur, sx, sy
        cur = []
        subpaths.append(cur)

    def emit(p):
        cur.append(p)

    i = 0
    n_tok = len(toks)
    while i < n_tok:
        t = toks[i]
        start_i = i
        if isinstance(t, str):     # 命令字母
            cmd = t
            i += 1
            abs_mode = cmd.isupper()
            cmd_u = cmd.upper()
            # ⚠️ prev_cmd/prev_raw 在循环末尾统一更新:
            #    s/t 平滑命令需要"上一个命令"判断反射控制点,
            #    提前更新会让第一个 s/t 反射初始 prev_c=(0,0) 产生巨大控制点
        else:
            cmd_u = prev_cmd       # 隐式重复
            abs_mode = prev_raw.isupper()

        if cmd_u == 'M':
            if cur is not None and len(cur) > 1:
                pass  # 上一子路径结束
            new_subpath()
            if i + 1 < n_tok and isinstance(toks[i], float) and isinstance(toks[i + 1], float):
                nx, ny = toks[i], toks[i + 1]
                if not abs_mode:
                    nx, ny = nx + sx, ny + sy
                x, y = nx, ny
                sx, sy = x, y
                emit((x, y))
                i += 2
            elif i < n_tok and isinstance(toks[i], float):
                i += 1  # 单参数退化
            else:
                i += 1
        elif cmd_u == 'L':
            while i + 1 < n_tok and isinstance(toks[i], float) and isinstance(toks[i + 1], float):
                nx, ny = toks[i], toks[i + 1]
                if not abs_mode:
                    nx, ny = x + nx, y + ny
                emit((nx, ny))
                x, y = nx, ny
                i += 2
            if i == start_i + 1 and not isinstance(toks[i], float):
                pass
        elif cmd_u == 'H':
            while i < n_tok and isinstance(toks[i], float):
                nx = toks[i]
                if not abs_mode:
                    nx = x + nx
                emit((nx, y))
                x = nx
                i += 1
        elif cmd_u == 'V':
            while i < n_tok and isinstance(toks[i], float):
                ny = toks[i]
                if not abs_mode:
                    ny = y + ny
                emit((x, ny))
                y = ny
                i += 1
        elif cmd_u == 'C':
            while i + 5 < n_tok and all(isinstance(toks[i + k], float) for k in range(6)):
                c1 = (toks[i], toks[i + 1])
                c2 = (toks[i + 2], toks[i + 3])
                p2 = (toks[i + 4], toks[i + 5])
                if not abs_mode:
                    c1 = (x + c1[0], y + c1[1])
                    c2 = (x + c2[0], y + c2[1])
                    p2 = (x + p2[0], y + p2[1])
                for px, py in cubic_points((x, y), c1, c2, p2, 8):
                    emit((px, py))
                x, y = p2
                prev_c = c2
                i += 6
        elif cmd_u == 'S':
            while i + 3 < n_tok and all(isinstance(toks[i + k], float) for k in range(4)):
                c2 = (toks[i], toks[i + 1])
                p2 = (toks[i + 2], toks[i + 3])
                if not abs_mode:
                    c2 = (x + c2[0], y + c2[1])
                    p2 = (x + p2[0], y + p2[1])
                if prev_cmd in ('C', 'S'):
                    c1 = (2 * x - prev_c[0], 2 * y - prev_c[1])
                else:
                    c1 = (x, y)
                for px, py in cubic_points((x, y), c1, c2, p2, 8):
                    emit((px, py))
                x, y = p2
                prev_c = c2
                i += 4
        elif cmd_u == 'Q':
            while i + 3 < n_tok and all(isinstance(toks[i + k], float) for k in range(4)):
                c1 = (toks[i], toks[i + 1])
                p2 = (toks[i + 2], toks[i + 3])
                if not abs_mode:
                    c1 = (x + c1[0], y + c1[1])
                    p2 = (x + p2[0], y + p2[1])
                for px, py in quad_points((x, y), c1, p2, 8):
                    emit((px, py))
                x, y = p2
                prev_q = c1
                i += 4
        elif cmd_u == 'T':
            while i + 1 < n_tok and isinstance(toks[i], float) and isinstance(toks[i + 1], float):
                p2 = (toks[i], toks[i + 1])
                if not abs_mode:
                    p2 = (x + p2[0], y + p2[1])
                if prev_cmd in ('Q', 'T'):
                    c1 = (2 * x - prev_q[0], 2 * y - prev_q[1])
                else:
                    c1 = (x, y)
                for px, py in quad_points((x, y), c1, p2, 8):
                    emit((px, py))
                x, y = p2
                prev_q = c1
                i += 2
        elif cmd_u == 'A':
            while i + 6 < n_tok and all(isinstance(toks[i + k], float) for k in range(7)):
                rx, ry, rot, laf, sf, nx, ny = toks[i:i + 7]
                p2 = (nx, ny) if abs_mode else (x + nx, y + ny)
                for px, py in arc_points((x, y), rx, ry, rot, laf, sf, p2, 6):
                    emit((px, py))
                x, y = p2
                i += 7
        elif cmd_u == 'Z':
            if cur and len(cur) > 1:
                emit((sx, sy))   # 闭合
                if cur[0] == cur[-1]:
                    cur.pop()
            x, y = sx, sy
            i += 1
        else:
            i += 1

        # 防死循环：任何命令分支若未消费任何 token，强制前进
        if i == start_i:
            i += 1
        # 统一在此更新命令状态(s/t 分支读取的是"上一个命令")
        prev_cmd = cmd_u
        if isinstance(t, str):
            prev_raw = cmd

    return [sp for sp in subpaths if len(sp) >= 3]

def cubic_points(p0, p1, p2, p3, n):
    out = []
    for k in range(1, n + 1):
        t = k / n
        mt = 1 - t
        x = mt ** 3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t ** 3 * p3[0]
        y = mt ** 3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t ** 3 * p3[1]
        out.append((x, y))
    return out


def quad_points(p0, p1, p2, n):
    out = []
    for k in range(1, n + 1):
        t = k / n
        mt = 1 - t
        x = mt * mt * p0[0] + 2 * mt * t * p1[0] + t * t * p2[0]
        y = mt * mt * p0[1] + 2 * mt * t * p1[1] + t * t * p2[1]
        out.append((x, y))
    return out


def arc_points(p0, rx, ry, rot_deg, laf, sf, p2, seg_per_90):
    """SVG arc → 折线采样。rx/ry=0 时退化为直线。"""
    rx, ry = abs(rx), abs(ry)
    if rx < 1e-6 or ry < 1e-6:
        return [p2]
    x1, y1 = p0
    x2, y2 = p2
    if (x1, y1) == (x2, y2):
        return []
    # 椭圆弧算法（SVG 规范附录 B.2.4）
    phi = math.radians(rot_deg)
    cos_p, sin_p = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p = cos_p * dx + sin_p * dy
    y1p = -sin_p * dx + cos_p * dy
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s
    num = max(0.0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = math.sqrt(num / den) if den > 0 else 0.0
    if laf == sf:
        coef = -coef
    cxp = coef * (rx * y1p / ry)
    cyp = coef * (-ry * x1p / rx)
    cx = cos_p * cxp - sin_p * cyp + (x1 + x2) / 2
    cy = sin_p * cxp + cos_p * cyp + (y1 + y2) / 2
    # 起始/结束角
    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        norm = math.hypot(ux, uy) * math.hypot(vx, vy)
        a = math.acos(max(-1.0, min(1.0, dot / norm))) if norm > 0 else 0.0
        if ux * vy - uy * vx < 0:
            a = -a
        return a
    theta1 = angle(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sf and dtheta > 0:
        dtheta -= 2 * math.pi
    elif sf and dtheta < 0:
        dtheta += 2 * math.pi
    n_seg = max(2, int(abs(dtheta) / (math.pi / 2) * seg_per_90))
    out = []
    for k in range(1, n_seg + 1):
        t = theta1 + dtheta * k / n_seg
        ex = cx + rx * math.cos(t) * cos_p - ry * math.sin(t) * sin_p
        ey = cy + rx * math.cos(t) * sin_p + ry * math.sin(t) * cos_p
        out.append((ex, ey))
    return out


def path_center(subpaths):
    """path 的 bbox 中心（比点平均更稳）"""
    xs, ys = [], []
    for sp in subpaths:
        for x, y in sp:
            xs.append(x)
            ys.append(y)
    if not xs:
        return 0.0, 0.0
    return (min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0


def ring_area(poly):
    a = 0.0
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        a += x1 * y2 - x2 * y1
    return a / 2.0


def trace_outer_contour(mask):
    """用 cv2.findContours 提取单连通域外轮廓。
    mask: 2D bool(省份像素)。返回闭合轮廓点列表(像素坐标,首尾不重复)。"""
    m = mask.astype(np.uint8)
    cnts, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return []
    cnt = max(cnts, key=cv2.contourArea)
    pts = [(int(p[0][0]), int(p[0][1])) for p in cnt]
    if pts and pts[0] == pts[-1]:
        pts.pop()
    return pts


def simplify_poly(poly, eps=1.8):
    """Douglas-Peucker 简化折线（保留闭合形状，起终点重复）"""
    if len(poly) <= 4:
        return poly
    # 转绝对坐标
    pts = list(poly)
    closed = (pts[0] == pts[-1])
    if closed:
        pts = pts[:-1]
    n = len(pts)
    if n <= 4:
        return pts + [pts[0]]
    # 迭代 DP
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        ax, ay = pts[a]
        bx, by = pts[b]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        max_d = 0.0
        max_i = -1
        for i in range(a + 1, b):
            px, py = pts[i]
            if length < 1e-9:
                d = math.hypot(px - ax, py - ay)
            else:
                cross = abs(dx * (py - ay) - dy * (px - ax)) / length
                d = cross
            if d > max_d:
                max_d = d
                max_i = i
        if max_i > 0 and max_d > eps:
            keep[max_i] = True
            stack.append((a, max_i))
            stack.append((max_i, b))
    out = [pts[i] for i in range(n) if keep[i]]
    if len(out) < 3:
        out = pts
    out.append(out[0])   # 闭合
    return out


def simplify_poly(poly, eps=1.8):
    """Douglas-Peucker 简化折线（保留闭合形状，起终点重复）"""
    if len(poly) <= 4:
        return poly
    # 转绝对坐标
    pts = list(poly)
    closed = (pts[0] == pts[-1])
    if closed:
        pts = pts[:-1]
    n = len(pts)
    if n <= 4:
        return pts + [pts[0]]
    # 迭代 DP
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        ax, ay = pts[a]
        bx, by = pts[b]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        max_d = 0.0
        max_i = -1
        for i in range(a + 1, b):
            px, py = pts[i]
            if length < 1e-9:
                d = math.hypot(px - ax, py - ay)
            else:
                cross = abs(dx * (py - ay) - dy * (px - ax)) / length
                d = cross
            if d > max_d:
                max_d = d
                max_i = i
        if max_i > 0 and max_d > eps:
            keep[max_i] = True
            stack.append((a, max_i))
            stack.append((max_i, b))
    out = [pts[i] for i in range(n) if keep[i]]
    if len(out) < 3:
        out = pts
    out.append(out[0])   # 闭合
    return out


def svg_to_canvas(p):
    """SVG 坐标 → 画布坐标（裁剪欧亚非 + 放大）"""
    return (p[0] - CROP_X0) * SCALE, p[1] * SCALE


def canvas_to_lonlat(x, y):
    lon = (x / SCALE + CROP_X0) / SVG_W * 360.0 - 180.0
    lat = LAT_NORTH - (y / SCALE) / PX_PER_DEG_LAT
    return lon, lat


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    print('[EU4] 读取 SVG:', SVG_PATH)
    text = open(SVG_PATH, encoding='utf-8').read()
    path_matches = re.findall(r'<path\s+id="([^"]*)"([^>]*)/>', text)

    # 解析所有 path
    parsed = []
    seen_ids = set()
    for pid, attrs in path_matches:
        m = re.search(r'd="([^"]*)"', attrs)
        d = m.group(1) if m else ''
        subpaths = parse_path(d)
        if not subpaths:
            print(f'  ⚠️ {pid}: 无有效子路径')
            continue
        if pid in seen_ids:
            print(f'  ⚠️ {pid}: 重复 id')
            continue
        seen_ids.add(pid)
        cx, cy = path_center(subpaths)
        parsed.append((pid, subpaths, cx, cy))

    print(f'[EU4] path 总数 {len(parsed)}')

    # 裁剪判定
    keep = []
    drop_reason = {}
    for pid, subpaths, cx, cy in parsed:
        if cx < CROP_X0:
            if pid in KEEP_ATLANTIC:
                keep.append((pid, subpaths, cx, cy))
            else:
                drop_reason[pid] = 'america'
        elif pid in DROP_OCEANIA:
            drop_reason[pid] = 'oceania'
        else:
            keep.append((pid, subpaths, cx, cy))

    print(f'[EU4] 保留 {len(keep)} 省，剔除 {len(drop_reason)} 省'
          f'（美洲 {sum(1 for v in drop_reason.values() if v == "america")}，'
          f'大洋洲 {sum(1 for v in drop_reason.values() if v == "oceania")}）')

    # 排序：保留文件中的原始顺序（欧洲→亚洲→非洲），保持 id 稳定
    order = {pid: i for i, (pid, _, _, _) in enumerate(parsed)}
    keep.sort(key=lambda r: order[r[0]])

    # ------------------------------------------------------------------
    # 栅格化：画布 2640×1920
    # ------------------------------------------------------------------
    img = Image.new('RGB', (BITMAP_W, BITMAP_H), (0, 0, 0))
    draw = ImageDraw.Draw(img)
    id_color = {}
    for idx, (pid, subpaths, cx, cy) in enumerate(keep, start=1):
        r, g, b = 0, (idx >> 8) & 0xFF, idx & 0xFF
        id_color[pid] = (r, g, b)
        for sp in subpaths:
            pts = [svg_to_canvas(p) for p in sp]
            if len(pts) >= 3:
                draw.polygon(pts, fill=(r, g, b))
    print('[EU4] 栅格化完成，画布 %dx%d' % (BITMAP_W, BITMAP_H))

    arr = np.array(img)
    ids = arr[:, :, 1].astype(np.int32) * 256 + arr[:, :, 2].astype(np.int32)
    # 解析 R 通道（id > 65535 时高字节在 R；EU4 id < 4096，R 恒 0）
    ids = np.where(arr[:, :, 0] > 0, ids + arr[:, :, 0].astype(np.int32) * 65536, ids)

    # ------------------------------------------------------------------
    # 缝隙填充：8 邻多数投票（2 轮），填掉 path 间 1px 裂缝
    # ------------------------------------------------------------------
    def fill_gaps(ids_arr, rounds=2):
        """缝隙填充：8 邻多数投票（≥5 票），全向量化"""
        H, W = ids_arr.shape
        for _ in range(rounds):
            zero = ids_arr == 0
            # 只处理与陆地相邻的海像素（缝隙候选）
            touch = np.zeros_like(zero)
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                nb = np.roll(ids_arr, (dy, dx), (0, 1))
                touch |= (nb > 0)
            cand = zero & touch
            if not cand.any():
                break
            ys, xs = np.nonzero(cand)
            n = len(ys)
            if n == 0:
                break
            neigh = np.zeros((n, 8), dtype=np.int32)
            k = 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dy == 0 and dx == 0:
                        continue
                    ny = np.clip(ys + dy, 0, H - 1)
                    nx = np.clip(xs + dx, 0, W - 1)
                    neigh[:, k] = ids_arr[ny, nx]
                    k += 1
            # 排序后检测 ≥5 个连续相同值（向量化众数）
            s = np.sort(neigh, axis=1)
            fills = np.zeros(n, dtype=np.int32)
            for j in range(4):
                hit = (s[:, j] == s[:, j + 4])
                m = hit & (fills == 0) & (s[:, j] > 0)
                fills[m] = s[m, j]
            ids_arr[ys[fills > 0], xs[fills > 0]] = fills[fills > 0]
        return ids_arr

    ids = fill_gaps(ids)

    # ------------------------------------------------------------------
    # 省份邻接表（4 邻共享边；AI/外交/军队移动依赖）
    # ------------------------------------------------------------------
    from collections import defaultdict
    adj = defaultdict(set)
    kR = np.roll(ids, -1, axis=1)
    mR = (ids != kR) & (ids > 0) & (kR > 0)
    for y, x in zip(*np.nonzero(mR)):
        a, b = int(ids[y, x]), int(kR[y, x])
        adj[a].add(b)
        adj[b].add(a)
    kD = np.roll(ids, -1, axis=0)
    mD = (ids != kD) & (ids > 0) & (kD > 0)
    for y, x in zip(*np.nonzero(mD)):
        a, b = int(ids[y, x]), int(kD[y, x])
        adj[a].add(b)
        adj[b].add(a)
    n_edges = sum(len(v) for v in adj.values()) // 2
    print(f'[EU4] 邻接表: {len(adj)} 省, {n_edges} 条边')
    print(f'[EU4] 开始省份数据提取(质心/轮廓)...')

    # 统计每个省的有效面积
    n_prov = len(keep)
    areas = np.bincount(ids.ravel(), minlength=n_prov + 1)
    empty = [pid for idx, (pid, _, _, _) in enumerate(keep, start=1) if areas[idx] == 0]
    if empty:
        print('  ⚠️ 无像素省份:', empty[:20])

    # ------------------------------------------------------------------
    # 省份数据提取（质心 / 经纬度 / polygon / holes）
    # ------------------------------------------------------------------
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(ASSET_DIR, exist_ok=True)
    os.makedirs(TILE_DIR, exist_ok=True)

    # 质心：位图像素均值（批量 bincount，避免逐省全图扫描）
    y_coords, x_coords = np.mgrid[0:BITMAP_H, 0:BITMAP_W]
    flat = ids.ravel()
    sum_x = np.bincount(flat, weights=x_coords.ravel(), minlength=n_prov + 1)
    sum_y = np.bincount(flat, weights=y_coords.ravel(), minlength=n_prov + 1)
    # 批量每省 bbox（argsort + reduceat，一次完成）
    order = np.argsort(flat, kind="stable")
    sorted_flat = flat[order]
    bounds = np.searchsorted(sorted_flat, np.arange(n_prov + 1))
    xs_s = x_coords.ravel()[order]
    ys_s = y_coords.ravel()[order]
    # bounds[1:] 作为段起始(去掉 id=0 海段);段 j 对应 id j+1
    min_xs = np.minimum.reduceat(xs_s, bounds[1:])
    max_xs = np.maximum.reduceat(xs_s, bounds[1:])
    min_ys = np.minimum.reduceat(ys_s, bounds[1:])
    max_ys = np.maximum.reduceat(ys_s, bounds[1:])
    provs = []
    wasteland_flags = [False] * (n_prov + 1)
    chunk = []
    chunk_size = 0
    chunk_idx = 1

    def flush():
        nonlocal chunk, chunk_size, chunk_idx
        if not chunk:
            return
        path = os.path.join(DATA_DIR, f'Provinces_{chunk_idx}.lua')
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write('-- 由 gen_eu4_map.py 生成（EU4 欧亚非地图包）\n')
            fh.write('return {\n')
            fh.write('\n'.join(chunk))
            fh.write('\n}\n')
        print(f'[EU4] 数据分片 {chunk_idx}: {len(chunk)} 省, {os.path.getsize(path) // 1024}KB')
        chunk_idx += 1
        chunk = []
        chunk_size = 0

    for idx, (pid, subpaths, cx, cy) in enumerate(keep, start=1):
        if idx % 400 == 0:
            print(f'  [EU4] 轮廓 {idx}/{len(keep)}...')
        area = int(areas[idx])
        if area > 0:
            cxp = int(round(sum_x[idx] / area))
            cyp = int(round(sum_y[idx] / area))
        else:
            # 退化：用 path 中心
            cxp, cyp = svg_to_canvas((cx, cy))
            cxp, cyp = int(round(cxp)), int(round(cyp))
        lon, lat = canvas_to_lonlat(cxp, cyp)

        # polygon：从位图轮廓提取（与底图/点击完全一致,高亮描边严丝合缝贴边）
        # 局部 mask（按 bbox 裁剪,避免逐省全图比较）+ 轮廓坐标偏移回画布
        y0, y1 = int(min_ys[idx - 1]), int(max_ys[idx - 1]) + 1
        x0, x1 = int(min_xs[idx - 1]), int(max_xs[idx - 1]) + 1
        mask = ids[y0:y1, x0:x1] == idx
        contour = trace_outer_contour(mask)
        if contour:
            contour = [(px + x0, py + y0) for px, py in contour]

        if not contour:
            continue
        poly = simplify_poly(contour, eps=1.0)
        if len(poly) < 4:
            poly = contour
        lod_low = simplify_poly(contour, eps=8.0)
        if len(lod_low) < 4:
            lod_low = poly
        holes = []
        name = NAME_CN.get(pid.replace('_', ' '), pid.replace('_', ' '))
        nbrs = sorted(adj.get(idx, ()))
        is_waste = not in_playable(lon, lat)
        wasteland_flags[idx] = is_waste
        pts = ','.join('{%d,%d}' % (int(round(a)), int(round(b))) for a, b in poly)
        rec = '{id=%d,name="%s",center={%d,%d},centerLon=%.4f,centerLat=%.4f,area=%d' % (
            idx, name.replace('"', "'"), cxp, cyp,
            round(lon, 4), round(lat, 4), area)
        if is_waste:
            rec += ',isWasteland=true'
        rec += ',polygon={%s}' % pts
        if nbrs:
            rec += ',neighbors={' + ','.join(str(n) for n in nbrs) + '}'
        rec += ',lodLow={' + ','.join(
            '{%d,%d}' % (int(round(a)), int(round(b))) for a, b in lod_low) + '}'
        rec += '},'
        chunk.append(rec)
        chunk_size += len(rec)
        provs.append(rec)
        if chunk_size > 320 * 1024:
            flush()

    flush()
    print(f'[EU4] 省份数据 {len(provs)} 个，总像素 {int(areas.sum())}')

    # ------------------------------------------------------------------
    # 写 ID 位图
    # ------------------------------------------------------------------
    id_img = np.zeros((BITMAP_H, BITMAP_W, 3), dtype=np.uint8)
    id_img[:, :, 1] = (ids >> 8) & 0xFF
    id_img[:, :, 2] = ids & 0xFF
    id_img[:, :, 0] = (ids >> 16) & 0xFF
    out_id = os.path.join(ASSET_DIR, 'province_id.png')
    Image.fromarray(id_img, 'RGB').save(out_id, optimize=True)
    print(f'[EU4] 已写 ID 位图 {out_id}')

    # ------------------------------------------------------------------
    # 成品图：海色 + 底图感配色 + 边界/海岸线
    # ------------------------------------------------------------------
    SEA = (156, 183, 212)
    BORDER = (52, 50, 44)      # 边界线色（深暖灰）
    COAST = (118, 148, 178)    # 海岸线色

    def province_palette(i):
        # 低饱和大地色调（底图感），黄金角分散色相
        # 2026-08-31: 避开蓝青色相带 [0.52, 0.68]——海/湖/河都是蓝色系,
        #   省色不撞水体(用户反馈有省色与海色混淆)
        BAD_LO, BAD_HI = 0.52, 0.68
        BAD_LEN = BAD_HI - BAD_LO
        SEA_RGB = (156, 183, 212)   # 海色
        hue = (i * 0.618033988749895) % 1.0
        # 黄金角序列压缩进安全区(移除蓝青段)
        hue = hue * (1.0 - BAD_LEN)
        if hue >= BAD_LO:
            hue += BAD_LEN
        sat = 0.30 + 0.10 * ((i * 7) % 5) / 4.0
        li = 0.66 + 0.12 * ((i * 11) % 5) / 4.0
        # 最终检查:与海色 RGB 曼哈顿距离 < 55 则向暖色平移色相
        for _ in range(8):
            r, g, b = colorsys.hls_to_rgb(hue, li, sat)
            if (abs(r * 255 - SEA_RGB[0]) + abs(g * 255 - SEA_RGB[1])
                    + abs(b * 255 - SEA_RGB[2])) >= 55:
                break
            hue = (hue + 0.09) % 1.0
            if BAD_LO <= hue <= BAD_HI:
                hue = BAD_HI + 0.03 if hue < 0.6 else BAD_LO - 0.03
        return (int(r * 255), int(g * 255), int(b * 255))

    # 调色板索引填充（一次完成，避免逐省全图扫描）
    # 可玩区域外的省 = 沙漠色（底图自带沙漠,零运行时开销）
    palette = np.zeros((n_prov + 1, 3), dtype=np.uint8)
    palette[0] = SEA
    for i in range(1, n_prov + 1):
        palette[i] = DESERT_RGB if wasteland_flags[i] else province_palette(i)
    color_arr = palette[ids]
    is_sea = ids == 0
    is_waste_px = np.zeros((n_prov + 1,), dtype=bool)
    for i in range(1, n_prov + 1):
        is_waste_px[i] = wasteland_flags[i]
    # 边界检测（右/下邻）
    kR = np.roll(ids, -1, axis=1)
    kR[:, -1] = -1
    diffR = (ids != kR) & (ids >= 0) & (kR >= 0)
    kD = np.roll(ids, -1, axis=0)
    kD[-1, :] = -1
    diffD = (ids != kD) & (ids >= 0) & (kD >= 0)
    border = diffR | diffD
    # 沙漠省之间不画省界（连片荒野）
    both_waste = is_waste_px[ids] & is_waste_px[kR]
    border = border & ~both_waste
    coast = (border & diffR & ((is_sea & (kR > 0)) | ((~is_sea) & (kR == 0)))) \
          | (border & diffD & ((is_sea & (kD > 0)) | ((~is_sea) & (kD == 0))))
    land_border = border & (~coast)
    color_arr[coast] = COAST
    color_arr[land_border] = BORDER
    out_final = os.path.join(ASSET_DIR, 'map_political.png')
    Image.fromarray(color_arr, 'RGB').save(out_final, optimize=True)
    print(f'[EU4] 已写成品图 {out_final}')

    # ------------------------------------------------------------------
    # 显示色 LUT（4096×1，索引 0=海，1..N=默认陆地色）
    # ------------------------------------------------------------------
    lut = Image.new('RGB', (4096, 1))
    px = lut.load()
    px[0, 0] = SEA
    for i in range(1, 4096):
        if i <= n_prov:
            px[i, 0] = DESERT_RGB if wasteland_flags[i] else province_palette(i)
        else:
            px[i, 0] = SEA
    out_lut = os.path.join(ASSET_DIR, 'province_lut.png')
    lut.save(out_lut, optimize=True)
    print(f'[EU4] 已写 LUT {out_lut}')

    # ------------------------------------------------------------------
    # 瓦片（1024px，海色补齐）
    # ------------------------------------------------------------------
    TILE = 1024
    n = 0
    for ty in range(0, BITMAP_H, TILE):
        for tx in range(0, BITMAP_W, TILE):
            box = (tx, ty, min(tx + TILE, BITMAP_W), min(ty + TILE, BITMAP_H))
            tile = Image.fromarray(color_arr).crop(box)
            if tile.size != (TILE, TILE):
                full = Image.new('RGB', (TILE, TILE), SEA)
                full.paste(tile, (0, 0))
                tile = full
            name = os.path.join(TILE_DIR, f'map_{tx // TILE}_{ty // TILE}.png')
            tile.save(name, optimize=True)
            n += 1
    print(f'[EU4] 瓦片 {n} 张 → {TILE_DIR}')

    # ------------------------------------------------------------------
    # 地图包配置（scripts/data/mappacks/eu4.lua）
    # ------------------------------------------------------------------
    cfg = f'''-- ============================================================
-- 地图包：EU4 欧亚非（由 gen_eu4_map.py 生成，勿手改）
-- 数据源：data/eu4/eu4_provinces.svg（MapChart EU4，3360 省裁剪后 {len(provs)} 省）
-- 投影：等距圆柱 lon∈[-180,180] → x∈[0,1200] 裁剪后映射画布
--       lat∈[78.54,-42.03] → y∈[0,480]（MapChart EU4 纬度标定）
-- ============================================================
return {{
  id = "eu4",
  name = "EU4 欧亚非",
  desc = "基于欧陆风云4省份划分的欧亚非地图（{len(provs)} 省，历史粒度适中）",
  MAP_W = {int(BITMAP_W)},
  MAP_H = {int(BITMAP_H)},
  BITMAP_W = {int(BITMAP_W)},
  BITMAP_H = {int(BITMAP_H)},
  BITMAP_SCALE = 1.0,
  BITMAP_PATH = "image/eu4/map_political.png",
  PROVINCE_ID_PATH = "image/eu4/province_id.png",
  PROVINCE_LUT_PATH = "image/eu4/province_lut.png",
  TILE_PATH_PATTERN = "image/eu4/tiles/map_%d_%d.png",
  TILE_PX = 1024,
  PROVINCE_FILES = {{ "data.mappacks.eu4.Provinces_%d" }},
  INITIAL_ZOOM = {900.0 / BITMAP_W:.3f},  -- 全图视角（按 900px 视口宽估）
  MIN_ZOOM = 0.05,
  MAX_ZOOM = {SCALE * 2},   -- 高清位图支撑的大倍率
  LUT_W = 4096,
  -- 投影：lon/lat → 逻辑像素（等距圆柱，纬度 78.54°N..-42.03°S 标定）
  project = function(lon, lat)
    local x = ((lon + 180.0) / 360.0 * 1200.0 - {CROP_X0}) * {SCALE}
    local y = ({LAT_NORTH} - lat) * {PX_PER_DEG_LAT} * {SCALE}
    return x, y
  end,
}}
'''
    out_cfg = os.path.join(ROOT, 'scripts', 'data', 'mappacks', 'eu4.lua')
    with open(out_cfg, 'w', encoding='utf-8') as fh:
        fh.write(cfg)
    print(f'[EU4] 已写配置 {out_cfg}')

    # 统计
    land_px = int(areas.sum())
    print(f'[EU4] 完成：{len(provs)} 省，陆地 {land_px}px/{BITMAP_W * BITMAP_H}px'
          f'（{land_px * 100 / (BITMAP_W * BITMAP_H):.1f}%）')


if __name__ == '__main__':
    main()

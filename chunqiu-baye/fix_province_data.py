#!/usr/bin/env python3
"""
[工具] 同步多边形数据与合并后的位图：
  1. 从 GeneratedProvinces_N.lua 删除被合并的省（15 个）
  2. 清空宿主省的 holes（孔洞区域已被合并，多边形应实心）
  3. 从 GeneratedFactions.lua 的 provinces 列表移除被合并省
用法：python3 fix_province_data.py
"""
import os
import re
import shutil

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(ROOT, 'scripts', 'data')
BAK_DIR = os.path.join(ROOT, 'backup')

# 被合并省（位图已并入宿主省）→ 宿主省
MERGED = {
    505: 2648, 593: 599, 696: 678, 741: 742, 747: 748,
    749: 753, 896: 897, 1363: 1364, 1578: 2745, 1631: 1006,
    1712: 1725, 2097: 2113, 2143: 2167, 2637: 2634, 2894: 2902,
}
MERGED_IDS = set(MERGED.keys())
HOST_IDS = set(MERGED.values())

# 精确匹配省行：以 {id=N, 开头
def is_province_line(line, pid):
    return line.lstrip().startswith('{id=' + str(pid) + ',')

def main():
    # 备份
    for fname in os.listdir(DATA_DIR):
        if fname.startswith('GeneratedProvinces_') and fname.endswith('.lua'):
            shutil.copy2(os.path.join(DATA_DIR, fname), os.path.join(BAK_DIR, fname))
    shutil.copy2(os.path.join(DATA_DIR, 'GeneratedFactions.lua'),
                 os.path.join(BAK_DIR, 'GeneratedFactions.lua'))
    print('[Fix] 已备份数据文件到 backup/')

    # 1. 处理省份数据文件
    total_removed = 0
    total_holes = 0
    for fname in sorted(os.listdir(DATA_DIR)):
        if not (fname.startswith('GeneratedProvinces_') and fname.endswith('.lua')):
            continue
        path = os.path.join(DATA_DIR, fname)
        lines = open(path, encoding='utf-8').readlines()
        out = []
        for line in lines:
            # 删除被合并省行
            removed = False
            for pid in MERGED_IDS:
                if is_province_line(line, pid):
                    removed = True
                    break
            if removed:
                total_removed += 1
                continue
            # 清空宿主省 holes
            for pid in HOST_IDS:
                if is_province_line(line, pid):
                    new_line, n = re.subn(r',holes=\{\{.*?\}\}\}', '', line, flags=re.S)
                    if n:
                        total_holes += 1
                        line = new_line
                    break
            out.append(line)
        open(path, 'w', encoding='utf-8').writelines(out)
    print(f'[Fix] 已删除被合并省 {total_removed} 个')
    print(f'[Fix] 已清空宿主省 holes {total_holes} 个')

    # 2. 处理 GeneratedFactions.lua：从 provinces 列表移除被合并省
    fac_path = os.path.join(DATA_DIR, 'GeneratedFactions.lua')
    text = open(fac_path, encoding='utf-8').read()
    removed_fac = 0
    for pid in MERGED_IDS:
        # provinces={...} 中移除 pid（处理前导逗号）
        text, n = re.subn(r'\b' + str(pid) + r',', '', text)
        removed_fac += n
        # 处理列表末尾的情况（pid 后是 }）
        text, n = re.subn(r',' + str(pid) + r'\}', lambda m: '}', text)
        removed_fac += n
    open(fac_path, 'w', encoding='utf-8').writelines(text)
    print(f'[Fix] GeneratedFactions 中移除被合并省引用 {removed_fac} 处')

    # 3. 验证：数据文件中不再有被合并省
    remain = 0
    for fname in sorted(os.listdir(DATA_DIR)):
        if not (fname.startswith('GeneratedProvinces_') and fname.endswith('.lua')):
            continue
        text = open(os.path.join(DATA_DIR, fname), encoding='utf-8').read()
        for pid in MERGED_IDS:
            if re.search(r'\{id=' + str(pid) + r',', text):
                remain += 1
    print(f'[Fix] 验证：数据文件残留被合并省 {remain} 个')

if __name__ == '__main__':
    main()

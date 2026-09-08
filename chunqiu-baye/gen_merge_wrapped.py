#!/usr/bin/env python3
"""
[工具] 合并所有"被完全包裹"的区域（一个区域完整包住另一个 → 并入）。
规则：某区域（省 ID）的 4 邻全部是同一个其他省 → 该区域并入那个省。
迭代处理（合并后可能产生新的包裹关系），直到全图无包裹结构。
用法：python3 gen_merge_wrapped.py
"""
import os
import shutil
import numpy as np
from PIL import Image
from collections import defaultdict

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, 'assets', 'image', 'province_id.png')
BAK = os.path.join(ROOT, 'backup', 'province_id_before_merge.png')


def neighbor_sets(ids):
    """返回 {省ID: 4邻省ID集合}（向量化）"""
    h, w = ids.shape

    def pairs_key(a, b):
        m = (a > 0) & (b >= 0) & (a != b)
        return a[m].astype(np.int64) * 65536 + b[m]

    kr = np.unique(pairs_key(ids[:, :-1], ids[:, 1:]))
    kd = np.unique(pairs_key(ids[:-1, :], ids[1:, :]))
    allk = np.unique(np.concatenate([kr, kd]))
    adj = defaultdict(set)
    for k in allk:
        adj[int(k // 65536)].add(int(k % 65536))
    return adj


def main():
    # 备份（若尚未备份当前版本）
    if not os.path.exists(BAK):
        shutil.copy2(SRC, BAK)
        print(f'[Merge] 已备份当前位图 → {BAK}')
    else:
        print(f'[Merge] 备份已存在，跳过: {BAK}')

    im = Image.open(SRC).convert('RGB')
    arr = np.array(im)
    h, w = arr.shape[:2]
    ids = arr[:, :, 1].astype(np.int32) * 256 + arr[:, :, 2].astype(np.int32)
    print(f'[Merge] 位图 {w}x{h}')

    # 迭代合并
    round_no = 0
    total_merged = 0
    merged_log = []
    while True:
        round_no += 1
        adj = neighbor_sets(ids)
        # 找出完全被包裹的省
        targets = {}
        for pid, nset in adj.items():
            if len(nset) == 1:
                only = next(iter(nset))
                if only != 0:
                    targets[pid] = only
        if not targets:
            break
        # 执行合并（一次性替换本轮所有目标）
        merged_this = 0
        for pid, host in targets.items():
            mask = ids == pid
            n = int(mask.sum())
            if n == 0:
                continue
            ids[mask] = host
            merged_this += 1
            merged_log.append((pid, host, n))
        total_merged += merged_this
        print(f'[Merge] 第{round_no}轮合并 {merged_this} 个区域')
        if round_no > 200:
            print('[Merge] ⚠️ 迭代次数过多，中止')
            break

    print(f'[Merge] 共合并 {total_merged} 个被包裹区域')
    if merged_log:
        print('[Merge] 明细（被包裹省 → 并入省, 面积）:')
        for pid, host, n in merged_log:
            print(f'    {pid} → {host}  ({n}px)')

    # 写回位图
    arr[:, :, 1] = (ids >> 8) & 0xFF
    arr[:, :, 2] = ids & 0xFF
    arr[:, :, 0] = 0
    Image.fromarray(arr, 'RGB').save(SRC, optimize=True)
    print(f'[Merge] ✅ 已保存 {SRC}')

    # 最终验证：应无包裹结构
    adj = neighbor_sets(ids)
    remain = [pid for pid, ns in adj.items() if len(ns) == 1 and next(iter(ns)) != 0]
    print(f'[Merge] 验证：残留被包裹区域 {len(remain)} 个')
    print(f'[Merge] 剩余省数: {int((ids > 0).sum() > 0 and len(np.unique(ids[ids > 0])))}')


if __name__ == '__main__':
    main()

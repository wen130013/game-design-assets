# game-design-assets

> 游戏项目备份 / 交接仓库。
> 当前内容：**《春秋霸业》**（`chunqiu-baye/`）

---

## 仓库内容

| 文件夹 | 说明 |
|---|---|
| `chunqiu-baye/` | 《春秋霸业》完整游戏项目（UrhoX Lua，历史大战略） |

---

## 怎么用

### 接手开发

```bash
git clone https://github.com/wen130013/game-design-assets.git
cd game-design-assets/chunqiu-baye
```

然后按顺序读：

1. `README.md` — 游戏是什么、怎么跑
2. `docs/交接-下一步与思路.md` — **重点**：已知问题清单、修复建议、下一步思路
3. `CLAUDE.md` — 协作规范（改代码前先说明计划、小步验证等铁律）
4. `TODO.md` — 待办事项
5. `MAP_HANDOFF.md` — 地图方案交接

### 更新上传

```bash
cd game-design-assets
git pull
# 把改动放进 chunqiu-baye/
git add chunqiu-baye
git commit -m "更新：说明改了什么"
git push
```

---

## 注意

- **不要上传** `dist/`、`.build/`、`work_tmp/`、`screenshots/`、`.cli/`、`logs/`、`saves/`
  （`.gitignore` 已排除）
- **单文件不得超过 100MB**（GitHub 硬限制）
- `scripts/data/` 是游戏核心数据，**必须保留**（不要被 `.gitignore` 误伤）
- 地图数据源自 MapChart 的 EU4 省份划分，**上架前需评估版权**

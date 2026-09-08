# 春秋霸业(Chunqiu Baye)

历史题材国家战略游戏,基于 **UrhoX(星火编辑器)引擎 + Lua 5.4**。
玩家扮演春秋战国时期一方诸侯,在世界地图上经营城邑、发展经济/军事/政策,与 AI 诸侯国征战、外交、议和——玩法取向参考《Age of History 3》与 P 社(简化版)。

> 本目录是**完整游戏项目**(不含引擎知识库:engine-docs/examples/urhox-libs 等,接管方 Maker 环境自带)。

## ⚠️ 先读这三份文档

| 文档 | 内容 |
|---|---|
| `CLAUDE.md` | 项目约定、目录结构、文档导航(含引擎文档映射) |
| `MAP_HANDOFF.md` | **地图方案重大决定**:用 EU4 省份数据重建、废弃手绘底图。**开始任何地图任务前必读** |
| `PEACE_UI_SPEC.md` | 和谈界面重设计规格(AoH3 式左侧面板),已按此实现 |

## 运行 / 构建

- 平台:UrhoX / 星火编辑器(Maker)项目。
- 入口:`scripts/main.lua`。
- 步骤:把本文件夹作为 Maker 项目根(或把其中 `scripts/`、`assets/`、`data/` 放入工作区对应位置)→ Maker 构建 → 预览。
- 地图:瓦片与位图在 `assets/image/`;省份/势力数据在 `scripts/data/`,由 `data/` 源数据 + `gen_*.py` 管线生成(可重跑)。

## 目录结构

```
scripts/                 游戏代码
├── main.lua             入口与全局接线(单机)
├── config/              数值/经济/美术配置
├── core/                时间系统等核心
├── systems/             经济/军事/外交/AI/战争系统
├── ui/                  GameUI.lua(顶栏/省份面板/和谈/排行榜/战争列表等)
├── map/                 MapRenderer(地图瓦片渲染/点击/缩放/涂抹)
├── data/                运行时数据(Provinces/GeneratedProvinces_*/Factions)
├── save/  audio/  events/  ai/
assets/                  资源:Fonts(字体)/ audio / image(地图位图/瓦片/UI 图)
data/                    地图重建源数据:data/eu4(EU4/hoi4/vic3 svg)、data/world(Natural Earth)
gen_*.py                 地图生成/数据转换管线(gen_eu4_map.py 为主)
CLAUDE.md  MAP_HANDOFF.md  PEACE_UI_SPEC.md  docs/  世界地图预览 world_map_preview.png
```

## 当前进度

- **地图**:按 `MAP_HANDOFF.md` 决定以 EU4 省份数据重建世界地图;生成管线(`gen_*.py`)已建立并产出瓦片与省份数据(`scripts/data/GeneratedProvinces_*.lua` 等)。
- **玩法**:时间推进/暂停/速度档;经济(金/粮/税率/政策/变法);军事(征兵/调军/战争/占领);外交(宣战/求和/和谈割地·赔款·附庸·灭国/AI 求和);AI 诸侯;排行榜;本地存档。
- **UI**:手机优先布局;顶栏资源条、省份面板、外交面板、战争列表、排行榜、日志、政策/科技面板。
- **和谈 UI**:已按 `PEACE_UI_SPEC.md` 完成 AoH3 式左侧全高面板重构(propose 交互 + respond 只读双路径),对外 API 契约不变。
- **构建状态**:最近一次构建通过(LSP 0 Error)。

## 需要接管方做什么

1. 克隆本仓库后,先把 `chunqiu-baye/` 作为 Maker 项目根,跑通 build + 预览。
2. 阅读 `CLAUDE.md`(约定/文档导航)→ `MAP_HANDOFF.md`(地图交接,动地图前必读)→ `PEACE_UI_SPEC.md`(和谈 UI 规格)。
3. 核对运行效果与设计规格的差异(可用游戏内截图对照),制定后续迭代计划后动工。

# 春秋霸业（UrhoX Lua 历史策略游戏）

## ⚠️ 地图工作交接（必读）

地图方案有重大决定：**用 EU4（欧陆风云4）的省份数据重建地图，废弃当前手绘底图**。
开始任何地图相关任务前，**必须完整阅读 `MAP_HANDOFF.md`**，那里有全部上下文、决定、技术要点和版权提醒。

## 项目结构（简述）

- `scripts/`：游戏代码（入口 `main.lua`）
  - `map/MapRenderer.lua`：地图渲染（瓦片分块）/点击/缩放
  - `data/Geography.lua`：地图尺寸与位图配置
  - `data/Provinces.lua` + `data/WorldProvinces_N.lua`：省份数据
  - `systems/`：经济/军事/外交/AI/战争系统
  - `ui/GameUI.lua`：游戏 UI（顶栏/省份面板/排行榜/战争列表）
- `gen_*.py`：地图生成脚本（瓦片、成品图、数据转换）
- `assets/image/`：地图位图与瓦片
- `backup/`：备份

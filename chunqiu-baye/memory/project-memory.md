# 项目记忆（跨对话持久记忆）

> 换对话/新会话时，**先读本文件**再开始工作。
> 本文件由 AI 与用户共同维护。最后更新：2026-08-28。

---

## 1. 沟通约定（用户明确要求，必须遵守）

1. **大动作先请示**：涉及数据重建、架构改动、删除前，必须先讲清楚"做什么/改哪些/预期效果"，得到允许再动手。不要擅自做很多操作不汇报。
2. **🔴 大改先沟通**：如果实施中发现需要**大改、可能偏离当初设定**（架构、玩法、数据格式、视觉方向），**必须先停下来问用户**，说明"原计划 vs 建议的新做法/原因/影响"，用户确认后才能继续。绝不擅自"为了省事改方向"。
3. **做事前多思考、多参考别人**：动手写代码前，先想清楚方案；不确定的地方先查**别人的做法**（GitHub 搜索、web 搜索、引擎文档、示例代码），借鉴成熟方案，不要闭门造车、不要凭感觉瞎写。
4. **先讨论后动手**：用户说"先思考/只回答/不要操作"时，只讨论方案，不写代码不跑命令。
5. **用中文交流**。
6. **积分敏感**：避免无谓的构建/验证/截图轮次。
7. **诚实汇报**：不确定就说"不确定"，不夸大。出 bug 找根因，不瞎猜。
8. **🔴 本约定对"任何新对话"都有效**：本文件是持久记忆，每个新对话开始都必须先读本文件——以上约定（尤其 1/2/3）无条件适用于所有会话、所有后续操作，无论中间开了多少新对话。
9. **用户倾向 P社栅格方案解决缝隙**（见待办，已实施数据层；渲染层待按第 9 节交接说明推进）。

## 2. 项目概况

- 游戏：《春秋霸业》——中国春秋战国历史策略游戏（欧亚非世界地图，等距圆柱投影，逻辑坐标 10800×6864）
- 技术栈：UrhoX Lua（scripts/）+ Python 数据处理工具 + mapshaper（npm）
- 地图数据：GADM（中国=地级市 ADM2，其他国家=省级 ADM1），约 2905 省
- 当前模式：主菜单（MainMenu.lua）→ 开始游戏 → 地图（无玩家势力，示例随机势力 20 个上色）
- 模组化方向：本体只提供地图 + 入口，势力等玩法由模组定义（Factions.data 可空，当前加载 GeneratedFactions.lua 示例势力）

## 3. 关键配置（工具能力全清单，新对话必读）

### GitHub（研究/下载开源方案）
- **GitHub MCP 插件**：`/workspace/mcp.json` 已配置（账号 wen130013），星火编辑器重启 + 新对话后 MCP 工具自动加载。
- **令牌**：在 `mcp.json` 的 `mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN`。**不要写进聊天/文档**。取令牌（不打印值）：
  ```bash
  TOKEN=$(python3 -c "import json; print(json.load(open('mcp.json'))['mcpServers']['github']['env']['GITHUB_PERSONAL_ACCESS_TOKEN'])")
  ```
- **新对话也能用 GitHub**：bash + curl 走沙箱代理 `http://127.0.0.1:1080`：
  ```bash
  # 搜仓库
  curl -s -x http://127.0.0.1:1080 -H "Authorization: Bearer $TOKEN" \
    "https://api.github.com/search/repositories?q=KEYWORD&sort=stars&per_page=10"
  # 搜代码
  curl -s -x http://127.0.0.1:1080 -H "Authorization: Bearer $TOKEN" \
    "https://api.github.com/search/code?q=KEYWORD+in:file+language:lua"
  # 看仓库文件树
  curl -s -x http://127.0.0.1:1080 -H "Authorization: Bearer $TOKEN" \
    "https://api.github.com/repos/OWNER/REPO/git/trees/BRANCH?recursive=1"
  # 抓 raw 文件（不需要令牌）
  curl -s -x http://127.0.0.1:1080 "https://raw.githubusercontent.com/OWNER/REPO/BRANCH/PATH"
  # 查许可证
  curl -s -x http://127.0.0.1:1080 -H "Authorization: Bearer $TOKEN" \
    "https://api.github.com/repos/OWNER/REPO/license"
  ```
- **注意**：raw.githubusercontent.com 可能不走 API 配额，直接 curl 即可。

### Web 搜索/抓取（研究网页资料）
- **web_extractor MCP 工具**（mcp__sce-urhox__web_extractor）：不传 URL 时做 web 搜索，传 URL 时抓取页面内容。无需令牌。

### 引擎/验证工具
- **LSP**：`lua_lsp_client` MCP 工具（textDocument/diagnostic 查错）
- **build**：`mcp__sce-urhox__build`（构建，**每次代码改动后必须调用**；改 main.lua 后必须构建用户预览才生效）
- **run-lua-headless 技能**：跑一次性脚本（验证 API 行为、生成数据，不构建不消耗构建积分）
- **run-lua-validate 技能**：validate（跑 N 帧查 Lua 错误，`-validate-output` 放 `work_tmp/`，`.tmp/` 是 root 权限写不了）+ 截图（surfaceless 软渲染，timeout 给足）
- **run-lua-validate 用法要点**：`-graphicsheadless` 只用于 validate；截图用 `-graphicssurfaceless` + 三个 Mesa 环境变量；`-screenshot-frame` 用 ≥120；`-validate-timeout` 默认 30s 要显式调大；报告解析要过滤噪音（ShaderError/Frame time spike/audio）。
- **get_debug_feedbacks**：拉 TapTap 玩家调试反馈（本机预览错误不上报，通常拉不到）
- **generate_image / text_to_music / text_to_sound_effect 等**：素材生成工具（本项目可能用不到）

### 本地工具
- Python：shapely / cv2 / numpy / PIL（数据管线）
- mapshaper：`/home/Maker/.npm-global/bin/mapshaper`
- 沙箱网络代理：`http://127.0.0.1:1080`（curl/pip/npm 都要 `-x` 或环境变量）

### 积分敏感提示
- Python 数据管线、headless 验证脚本**不消耗构建积分**（本地跑）
- 构建（build）、截图验证**消耗积分**——能合并的验证合并做，避免无谓轮次

## 4. 地图数据管线（核心）— ★2026-08-28 改为 P社栅格位图方案（缝隙根治）

```
GADM 原始 (gis/, 90MB)
  → gen_world_map.py     生成省份 JSON（首次建图才跑）
      输出：data_work/world_provinces.json（⚠️ 已移出 scripts/，避免打进 dist）
  → build_provinces.py   ★每次数据改动必跑：
      1. 修复无效几何 + 合并修复（editorFilled → shapely 并集）
      2. 栅格化 → assets/image/province_id.png（5400×3432，2 逻辑/像素）
         像素 RGB = (0, id>>8, id&0xFF)；海洋 = 黑(0,0,0)；面积从大到小填充
      3. 奇异点清理（单像素孤点）+ 贴边省沿图像边缘补边
      4. 拓扑一致提取：共享网格线段 → 每省环（含洞 holes/lodLowHoles）
         full 原样保留（零缝隙零穿出）；lodLow 段级 RDP（容差 8）
      5. 输出分片 Lua：GeneratedProvinces_N.lua（每片 ≤1.4MB）
         ⚠️ 引擎 Lua chunk 加载限制 ~2MB，必须分片（当前 9 片）
  → gen_base_image.py    底图 world_map_base.png（从位图生成，与省多边形像素级重合）
  → 构建（MCP build）
```

- **数据源 JSON 位置**：`data_work/world_provinces.json`（+ 备份也在 data_work/，已从 scripts/ 移出）
- **编辑标记**：isOcean（删除=海洋）、editorFilled（合并 target）、suppressOceanCover、absorbedBy
- **用户明确要求**：合并**只保留不丹/尼泊尔**（migrate_edits.py 的斯里兰卡合并**不要用**！斯里兰卡 25 个行政区正常显示）

## 5. 渲染结构（scripts/map/MapRenderer.lua）

- **底图**：world_map_base.png（nvgCreateImage）
- **点击检测**：province_id.png 位图查色（P社方案）——逻辑坐标 → 位图像素 → GetPixelInt 解码省 ID
  - ⚠️ `GetPixelInt` 字节序 = **0xAABBGGRR**（A 最高位，R 最低位）：
    B = (v>>16)&0xFF, G = (v>>8)&0xFF, id = G*256 + B
- **海色覆盖层**：isOcean 删除区块显示海色
- **Pass B 填色**：⚠️ zoom<0.15 时**跳过逐省填充**（直接用底图）；zoom≥0.15 才逐省着色
- **势力边界线（B2b）**：黑色 (40,40,40) 细线 1.5/zoom；zoom<0.2 不画
- **边映射表 edgeMap**：启动时构建（含洞环），同势力内部边不画
- **洞（holes）**：tracePolygon 支持（洞环 nvgPathWinding NVG_HOLE 挖洞）
- **LOD**：_renderPoly() zoom≥0.4 用 full，否则 lodLow；_renderHoles() 对应
- **省份面板**：名称/地形/领主/人口/治安
- **顶栏**：只有标题"春秋霸业·世界地图"

## 6. 当前状态（重要）

- **缝隙根治 ✅ 已完成（2026-08-28，P社栅格位图方案）**：
  - 数据层：全量 4034 对相邻省 **0 缝隙 0 重叠**（shapely 逐对验证）
  - 位图为唯一事实源：底图/填色/边界/点击全部同源
  - full 原样保留像素网格（69 万顶点）；lodLow 段级 RDP（6 万顶点）
  - 渲染只剩 1px 抗锯齿边缘（正常现象，CK3 同样有，不随 zoom 变宽）
- **体积**：dist **25MB**（比改造前 39MB 更小）；province_id.png 417KB；world_map_base.png 318KB
- **数据**：2905 省全提取成功（33-61 省带洞，如 FreeState 环抱莱索托）
- **中国 379 省 / 欧洲 856 省** 数量保持充足
- 性能：全景底图优先后软渲染 ~488ms/帧（主要底图光栅化，真机 GPU 应流畅）

## 7. 待办（用户当前最关心）

1. **模组化系统**（远期）：内容数据化、mods/ 加载器、完整性校验（用户提过愿景：玩家可上传地图/删除内容、骑砍式 2D 战斗等）
2. **GitHub 插件**：已配置 mcp.json，重启后生效
3. 后续若改地图数据：跑 build_provinces.py → gen_base_image.py → 构建（分片自动重新生成）

## 8. 注意事项 / 坑

- **不要写 /workspace/dist/**（构建工具自动维护）
- assets 只留运行时资源（world_map_base.png + province_id.png + Fonts）
- ⚠️ **scripts/data/ 下的 JSON 会被打进 dist**——数据源 JSON/备份放 `data_work/`（Python 脚本 SRC 都指向 data_work/）
- ⚠️ **引擎 Lua chunk 加载限制 ~2MB**——大数据必须分片（Provinces.lua 循环 require GeneratedProvinces_N.lua）
- ⚠️ **GetPixelInt 字节序是 0xAABBGGRR**（不是 RRGGBBAA！）
- ⚠️ Lua 分片生成的 f-string 模板：条目以 `},` 结尾（条目间分隔）；holes 在条目内
- 字体：assets/Fonts/MiSans-Regular.ttf 实际是 Noto Sans SC（本地化）
- .tmp/ 目录是 root 权限写不了 → 用 work_tmp/
- 验证方式：LSP（lua_lsp_client）→ build → validate（headless，-validate-output 放 work_tmp/）→ 截图（surfaceless，软渲染每帧 0.5-4s，timeout 要给足）
- main.lua 的 Start() 默认 ShowMainMenu()；临时验证直进地图时改 StartGame() 后必须改回
- screenshots/ 目录可用于截图验证（mcp__mkr__Read 读不了图，用 Python 像素分析）

## 9. 🔴 交接说明（2026-08-28 晚，用户要求开启新对话后继续）

### 用户最新要求（必须遵守）
1. **下一个对话继续任务**：先给完整实施计划（改动范围/工作量/构建轮次/积分预估），**用户确认后才动手**。
2. **优先考虑模组化**：用户强调"别人也需要能直接上模组"——架构必须对 mod 作者友好（不能要求 mod 作者跑 Python 管线）。
3. **积分敏感**：避免无谓构建。

### 当前遗留问题（用户报告的真实体验）
- **Web 端（星火编辑器预览）玩一会儿后卡死**，左下角弹"修复错误"（出现过 3 个错误弹窗）。日志无记录（崩溃时来不及写）。
- 放大后：边界是像素小方块（阶梯）；沿海省边界有 1px 海色过渡带（用户称"间隙"）；领土内湖泊显示海色（GADM 数据特性，非 bug）。
- 排查已确认：原生 1000 帧逻辑 + 300 帧渲染全部 0 错误（**代码逻辑没问题，是 Web 端渲染/内存问题**）。Web 端内存大头：底图纹理 10800×6864（~296MB）+ 69 万顶点数据。

### 已完成的位图方案（复用，不要推翻数据层）
- province_id.png（5400×3432，像素 RGB=(0,id>>8,id&0xFF)）= 唯一事实源
- 分片 Lua（9 片，引擎 LoadChunk ~2MB 限制）
- 点击 = 位图查色（已实现）；底图/填色/边界从位图同源 → 数据层 0 缝隙 0 重叠（全量验证）
- **遗留问题都在渲染层**：NanoVG 矢量渲染的天花板（AA 过渡 / 折线阶梯 / CPU 填充慢）

### 研究结论（P 社 shader 方案 = 最优解，用户倾向采纳）
- P 社（EU4/CK3）渲染：**GPU 逐像素 shader**——采样省份 ID 位图(NEAREST) → 查 1D LUT（省份ID→势力色）上色 → 采样上下左右 4 邻比较画边界 → 边界混合 + hover/选中。**无矢量多边形，架构上无缝隙**；势力色变化只更新 LUT（小纹理）。
- 开源实现参考（**许可证不友好，只能参考不能抄**）：game-imperium（无许可证，src/shaders/map.frag 是完整实现）、PMRE（GPL-3.0）、Atlas-Core（AGPL-3.0）。
- 方案公开（EU4 wiki 有完整文档），算法可合法自实现。
- **套用方式**：UrhoX 用 3D quad + SurfaceShader 复刻 map.frag 逻辑（UI 仍 NanoVG 叠加）。数据层全部复用。
- **收益**：缝隙根治（shader 像素级）、省界无 1px 过渡、Web 端性能大幅提升（GPU 替代 CPU 矢量填充，很可能根治卡死）、**天然适配模组**（mod 作者画位图+CSV 定义即可，P 社 mod 模式）。
- **代价**：渲染架构重写（大工程）；边界放大仍像素阶梯（P 社固有，可后续 SDF 柔化）。
- 预估：4-6 轮构建 + 2-3 张截图验证。

### 已研究资料位置（新对话直接去抓，别重复搜索）
- game-imperium 的 map.frag / borders.glsl / common.glsl / map.vert / renderer.ts / textures.ts：
  `https://raw.githubusercontent.com/CesarAugustoAndrade/game-imperium/main/src/shaders/...`（**只参考思路，无许可证不能抄代码**）
- P 社方案文档：EU4 wiki（eu4.paradoxwikis.com/Map_modding）
- 其他候选：PMRE（einstein95/PMRE）、Atlas-Core（NeoLorenzo/Atlas-Core）
- **实施 shader 方案时**：可以继续用 GitHub + web_extractor 研究（如 UrhoX SurfaceShader 写法、UrhoX 引擎文档 engine-docs/recipes/surface-shader.md）

### 下一步（新对话开始）
1. 先给用户完整实施计划（shader 方案：3D quad + SurfaceShader + LUT + 数据小改 + 模组接口），确认后动手。
2. 验证 SurfaceShader 能力（引擎是否支持在正交 quad 上采样位图纹理 + LUT）。
3. 实施顺序建议：数据 LUT 生成 → SurfaceShader 渲染地图 → 交互（hover/选中/编辑） → UI 叠加 → Web 端性能验证。

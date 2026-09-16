# 项目记忆索引 · 春秋霸业

项目:**春秋霸业**(UrhoX Lua 历史大战略游戏,Age of History 3 / 简化 P 社玩法,手机优先)
当前版本:接管基线 v0.9.0
接管日期:2026-09-08(自 GitHub `wen130013/game-design-assets` 的 `chunqiu-baye/` 迁入)
上传方交接文档:`README.md`、`MAP_HANDOFF.md`、`PEACE_UI_SPEC.md`、`CLAUDE.md`(接管前必读)

## 项目概况
- 玩法:春秋战国诸侯经营+征战+外交+议和;时间推进/暂停/速度档;经济(金/粮/税率/政策/变法)、军事(征兵/调军/占领)、外交(宣战/求和/和谈割地·赔款·附庸·灭国/AI 求和)、AI 诸侯、排行榜、本地存档
- 地图:**EU4 省份数据重建**(废弃手绘底图)——动地图前必读 `MAP_HANDOFF.md`(含版权提醒)
- 和谈 UI:已按 `PEACE_UI_SPEC.md` 完成 AoH3 式左侧全高面板重构
- 生成管线:`gen_*.py`(gen_eu4_map.py 为主),源数据 `data/eu4`、`data/world`

## 上传方声明进度
- 构建:最近一次通过(LSP 0 Error)
- 接管方任务(README 指定):①build+预览跑通 ②读三份交接文档 ③对照规格核对运行效果→定迭代计划

## 避雷清单
- 动地图前必读 `MAP_HANDOFF.md`;EU4 数据有版权提醒,注意对外发布口径
- 只在 scripts/ 写 Lua;禁止写 dist/;改码后必须 build
- assets/ 与 data/ 不入项目 git(体积大,真身在 GitHub 中转库)
- 大动作先与用户讨论;语音转文字先复述确认
- 旧项目在 `_archive-2026-09-08/`,勿混用
- **UI 回调闭包内禁用未声明 upvalue**:在 `local root = ...` **声明之前**创建的 onClick 闭包引用 root → Lua 视为全局 nil,点击才崩(工坊验证按钮教训)。规则:按钮 onClick 只调模块方法,root 由模块 `attachRoot(root)` 注入(root 就绪后调用)
- **多会话并行工作区**:git status 中 `scripts/` 改动若非本会话所为勿覆盖;删代码前先确认其由来(曾有会话删除临时验证按钮的注释标注"上传方"实为本会话)

## 最近变更
- v0.14.3: 全量同步到 GitHub 中转库(6ee2d0c):剧本编辑器v2/选国页/设置存档/按钮羊皮纸化/交战图标/菜单重排/全部修复+31枚图标放到代码引用路径(assets/image根)
- v0.14.2: 主菜单重排=新的游戏→读取存档(接onLoadSave)→地图编辑器→模组→设置→退出;删除重复的继续游戏与工坊验证按钮
- v0.14.1: 编辑器v2.1——侧栏重构(列表定高滚动/属性独立滚动,解决改不了国家=藏在折叠区的问题);开局自动全图对焦(HandleUpdate editor钩子+fitAll)+全图按钮;荒地刷标签明确(可占领⇄沙漠荒地)
- v0.14.0: 编辑器v2=模式三态(关/划归选中/沙漠刷·isWasteland实时渲染)+关系编辑(下拉对方+滑块-100~100,双key写入scenario.relations)+列表选中opacity切换不重置镜头;删除MainMenu旧'地图编辑器'按钮(世界生成参数面板入口,功能未删可回收)
- v0.15.0: 事件引擎规格 v0.1 定稿 `docs/event-engine-spec.md`(2026-09-08,口述需求原样存档+拍板):**玩家向事件**(AI动作仅作触发源)、灭国=灭人载体(不做刺杀/处决玩法)、影响三形态(即时/延迟schedule/持续modifier)、纯文字剧情选项、事件链flag、**可视化事件编辑器**(第一版交付,仿ScenarioEditor);条件/效果白名单清单+9处钩子点(file:line)已入文档
- v0.13.4: 修复编辑器paperBtn传参顺序反(以此国开局崩溃)+函数容错;删除上传方P0临时工坊验证按钮(WorkshopProbe引用nil root必崩,其注释本就要求验证完删除)
- v0.13.3: 修复SaveManager.hasSave残缺行(上次字符串切割误伤return SaveManager.load());引入luaparser真解析器全量验证(构建工具不查Lua语法,LSP摘要不可信)
- v0.13.2: 文字竖排根治——urhox UI 行内(Row)不带宽度的 Label 默认宽度偏小,中文必换行;规范=行内文字一律显式 width(+textAlign),已修选国页全部与 SmallButton 图标标签(按字数算宽)
- v0.13.1: 修复SaveManager致命加载错误(追加代码在顶层return之后=语法错误,已移至return前);按钮文字竖排修复(UI缩放放大字号→固定宽度不足:返回/全图/列表/设置等加宽缩字)
- v0.14.0: 模组工坊设计定稿 `docs/mod-workshop-design.md`(2026-09-08 与用户讨论拍板):云端UGC·免审核·**数据型模组**(无代码执行),云变量目录榜架构(TapTap 禁自建服务器,参考《猫猫方块工坊》);已拍板:①v1 **全类型**(剧本开局差分+数值balance+事件剧情+地图包,一次到位) ②发布免责确认+作者账号溯源 ③目录按最近更新排序+游玩/收藏人数(真赞数客户端写不了别人数据,不可实现);实现路线:P0 云边界原型验证→P1 引擎侧全类型(GameConfig 覆盖层/EventManager 数据驱动实装/ModManager 本地管道)→P2 云工坊闭环
- v0.13.0: 剧本编辑器v1(ScenarioEditor.lua):国家增删/名字颜色金粮兵倾向编辑/领土涂刷划归/设无主/设都城/剧本存载/以此国开局(写save.json复用读档管线);主菜单新增入口;SaveManager加剧本读写
- v0.12.0: 设置面板补全(读取存档入口+onLoadGame回调+ESC可关);SmallButton全面羊皮纸化(墨字,去程序生成感)
- v0.11.0: 图标库31枚(水墨描金:科技20/时代5/政策5/双剑交叉);交战白色叉修复=⚔️emoji自动替换为双剑图标(SmallButton内置)
- v0.10.1: 选国地图改用MapRenderer活Widget(缩放/拖拽/点选+全图按钮+列表选择focusTerritory对焦)
- v0.10.0: 选国页重设计(CountrySelect.lua):左列表(诸侯/蛮族分组)+中世界地图(eu4/map_political+势力圆点+选中金环)+右信息卡(色徽/属性/难度星/倾向/简介);旧纯列表弃用
- v0.9.1: 主菜单按钮修复——去掉棕色底框(backgroundColor透明化,按下反馈=纸图变暗0.55)
- v0.9.0: 接管迁移完成——游戏文件就位,旧内容归档 `_archive-2026-09-08/`,记忆系统重建

## 下一步
1. **模组工坊实现(设计已定稿 `docs/mod-workshop-design.md`)**:
   - P0 原型验证云变量边界(他人 values 经排行榜附加字段可读性/单 key 大小上限/稀疏榜 GetRankList 返回自己/GetUserNickname 结构/限流/分片)——需运行时环境,开工前先与用户确认执行方式(临时验证模块+预览日志?)
   - P1 引擎侧全类型:GameConfig 覆盖层改造 → EventManager 数据驱动事件引擎实装 → ModManager(schema 白名单校验+本地 mods/ 缓存+打包器)→ 新建游戏应用模组(多包顺序覆盖)
   - P2 云工坊:发布/更新/下架、发现页、编号直达、游玩人数、收藏、应用 UI
2. 动画/表现类迭代(如涉及再议)

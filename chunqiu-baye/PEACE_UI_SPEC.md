# 和谈界面重设计规格 v1 —— 交给 DeepSeek 的实现说明

> 目标游戏:《春秋霸业》(UrhoX Lua,历史策略游戏)
> 参考蓝本:《Age of History 3》(历史时代3) 和谈面板(设计已完全文字化,见下文)。
> **⚠️ 本文档自包含:所有视觉规格都已用文字/ASCII 示意图写死,实现时不需要也不要去查看任何图片素材。**
> **本期只重构 UI 布局与呈现,游戏机制/数值公式/系统 API 一律不动。**

---

## 0. 一句话需求

把现在的「底部横栏式」和谈窗口,改成 AoH3 的「**左侧全高面板 + 右侧地图露出涂抹选省**」结构。
数据源、结算逻辑(`WarSystem`、`DiplomacySystem`、`main.lua` 回调契约)全部保持现状。

---

## 1. 现状问题(为什么要改)

现有实现在 `scripts/ui/GameUI.lua` 第 842–1540 行(`Peace Dialog` 区),问题:

1. 所有信息(可索省 chips、已选 chips、分数进度条、步进按钮、缔结按钮)挤在屏幕**底部一条横栏**里,省份一多横向滚动不可用;
2. 分数条显示的是 `成本/分数` 占比(`UI.ProgressBar`),**量纲混淆**,玩家看不出"还能要多少";
3. 割地/赔金/赔粮/附庸/灭国平铺无分组,"+500金" 连点无总额感;
4. 省份用"横向小块 chips"呈现(注释误称"历史时代3式"),与 AoH3 真实设计(纵向列表)不符。

---

## 2. 参考设计拆解(AoH3 原版设计文字描述 → 我们的适配)

AoH3 结构(自上而下):标题栏(酒红底) → 双方国名横幅 → 汇总统计行 →
「强制要求」大按钮 → 「地图模式」图标行 → 「条件」区(分数大字 + 金矿步进器 + 停战行 +
4列条款卡片网格,每卡片右上角=分数成本) → 「要求割让省份」区([建议][重置] + 省份纵向行) →
「移交附属国/解放文明」区。面板**整体可垂直滚动**,右侧地图**全程可见可交互**(涂抹选省)。

适配到本作:我们没有"政体改变/宗教/军事通行权/停战年限/附属国"机制,**卡片网格只保留真实存在的条款**;
不要为了像 AoH3 而发明新机制。

| AoH3 元素 | 本作对应 | 处理方式 |
|---|---|---|
| 分数: 77.3 🏆 | `WarSystem.getScore()` | 照抄样式(核心改进点) |
| 金矿 [-] 0 [+] | 赔金 `peaceGold` | 步进器,步长 500 |
| 4列条款卡片 | 附庸(30分)/吞并(50分) | 2列卡片网格,右上角成本角标 |
| 涂抹选择(刷子卡片) | 地图涂抹选省(已有) | 变成提示行即可,机制不变 |
| 要求割让省份行列表 | `terms.provinceList` | 纵向 checkbox 行(替换现有 chips) |
| [建议][重置] | 全选可占领/清除(已有) | 挪到省份区头部 |
| 停战/附属国/政体等 | 无 | **不做** |
| 地图模式图标行 | 无 | **不做** |
| 强制要求(超分数) | 无 | **不做**,超预算直接禁用缔结 |

---

## 3. 新布局规格

### 3.1 整体几何

- 和谈打开时:**左侧竖面板**,其余区域透明、地图可点(现有 `pointerEvents = "box-none"` 思路保留)。
- 面板:`position absolute`,`left = 12`,`top = 56`(顶栏下方),`bottom = 12`,
  **width = 420**(屏幕逻辑宽 ≥1400 时可放宽到 460),`borderRadius = 10`,
  背景 `{12, 16, 26, 242}`,1px 边框 `{150, 120, 70, 220}`(金棕色,与现有标题贴角一致)。
- 面板根为 `UI.ScrollView`(库已提供,见 `urhox-libs/UI/init.lua:108`),
  内容纵向 flex,gap = 8,`padding = 0`(各区自带 padding)。
- **删除**现有的「左上角小标签浮窗」——标题并入面板头部。
- **删除**现有底部横栏(整个 `bottom:0` 大 Panel)。

### 3.2 区域 A:标题栏

- 高 46,背景 `{64, 22, 26, 255}`(AoH3 酒红),圆角只保留左上/右上 10。
- 左:主标题 `和平条约` 16px 金色粗体;正下方副标题 11px 白 70%:
  propose 模式 = `提出条件`;respond 模式 = `对方提出条件`。
- 右:`X` 关闭按钮(28x28,点击 = 现有 `GameUI.hidePeaceDialog()`)。

### 3.3 区域 B:双方横幅 + 分数总览(propose/respond 共有)

```
┌──────────────────────────────────────┐
│ [蓝块·魏]  曹魏   ⚔   西羌 [灰块]      │
│          战争分数: 77.3 🏆            │
└──────────────────────────────────────┘
```
- 双方名:`cfg.proposerId / cfg.targetId` → `factions[id].fullName or name`。
- 小色块 24x24、圆角 4(玩家侧 `{40,80,180}`、敌侧 `{120,120,125}`,或各势力已有配色)。
- 中间 ⚔ 白色。
- 分数行居中:`战争分数: ` 13px 灰 + 数值 **16px 金色粗体** + `🏆`。
  数值 = `refs.peaceScore`(浮点,显示 1 位小数,`%.1f`)。

### 3.4 预算摘要行(propose 独有,替换现有 ProgressBar + 成本文字)

单行三列,等分:

```
│  已耗: 45   │   剩余: 32   │  已选 3 / 可索 12  │
```

- `已耗` = `GameUI.peaceDialogCost()`(整数);`剩余` = `floor(score) - cost`。
- 剩余 < 0 时:**整行数字变红 `{220,70,55}` 且剩余显示 `不足 8!`**;否则数字绿 `{90,180,95}`。
- 删除现有 `UI.ProgressBar`(量纲混淆的根源)。

### 3.5 区域 C:「条件」条款区(propose 独有)

分区标题条:高 26、背景 `{26,38,56,230}`、文字 `条 件` 13px `{200,215,240}`。

**C1 赔金步进行**(行高 34,交替底色 `{20,26,38}`/`{26,33,46}`):
```
│ 💰 战争赔款    [−]   1500 金   [+]     ≈15分 │
```
- `[−]/[+]`:28x28 小方块按钮,步长 **500**,最小 0;
  右侧灰色小字实时显示该行进贡成本 `ceil(gold/100)`。
- 行为:点击改 `refs.peaceGold` → `GameUI.refreshPeaceDialog()`。

**C2 赔粮步进行**:同 C1(`peaceFood`,标签 `粮草赔款`)。

**C3 卡片网格**(2 列,卡片高 60,gap 6):
```
┌─────────────┐ ┌─────────────┐
│ 要求附庸  30 │ │ ⚔吞并全境 50 │   ← 右上角小字=分数成本
└─────────────┘ └─────────────┘
```
- 附庸卡:点击 toggle `refs.peaceVassal`;选中态 = 边框 `{120,200,110}` + 左上 `✓`。
- 吞并卡:点击 → **走现有 `GameUI.showAnnexConfirm()` 确认弹窗**(流程不变);
  未 `allOccupied` 时**整卡置灰 50% + 不可点**(替代现有灭国按钮 disabled)。
  成本角标显示 `全部`(annexAll 绕过预算检查,见 6.2)。

### 3.6 区域 D:「要求割让省份」区(propose 独有)

分区标题条:左侧 `要求割让省份` 13px,右侧两枚小按钮(28x24):
- `全选占领` = 现有 `peaceSelectAllBtn` 语义(仅当存在已占领省时可用);
- `重置` = 现有 `peaceClearBtn` 语义(对应 AoH3「重置」,清空选择)。

**省份行列表**(替换现有两套横向 chips;每行高 32):
```
│ ✓  临夏      已占领(绿)      5分 │   ← 已选中 + 已占领
│    平凉      未占领(灰)     15分 │   ← 未选
```
- 数据:`cfg.terms.provinceList`(`{id,name,cost,occupied}`,DiplomacySystem 已排好序:占领在前、成本低在前)。
- 行点击 = `GameUI.togglePeaceProvincePick(pid)`(与地图涂抹同一入口,天然双向同步)。
- 选中态:行背景 `{70,90,45,230}` + 左侧金色 `✓`;未选中:奇偶交替底色。
- `occupied=true` 的名称右侧先放绿色小标签 `已占`;`occupied=false` 灰色 `未占`。
- 成本列右对齐:`cost.."分"`。
- 列表为空 → 居中灰字 `无可索取的省份`。
- 保留内部登记表 `refs.peaceProvRows[pid].setSelected(bool)`(涂抹高亮回写行的既有机制)。

### 3.7 区域 E:响应模式(respond,AI → 玩家求和)

隐藏 C/D 全部交互元素,替换为只读文书:
```
│ ── 对方提出 ──                      │
│ · 割让 3 省:临夏、武都、阴平          │
│ · 赔款:100 金                       │
│ ── 是否接受? ──                    │
│ [ 接 受 ](绿)   [ 拒 绝 ](红)       │
```
- 数据:`GameState.pendingPeace.terms.provinces` → `gs.provinces[pid].name` 拼接。
- 按钮接现有 `onAcceptPeace / onRejectPeace` 回调,文案 `peaceAccept/peaceReject` 原语义不变。

### 3.8 区域 F:底部缔结栏(propose 独有,钉在 ScrollView 末尾)

```
│        [   🏆 缔结条约   ]          │   高 44,绿色,横向铺满
│   条款为空时文案变为「仅缔结停战」      │
```
- `cost > score` 且非 annexAll → **禁用** + 上方红色小字 `战争分数不足(超 X 分)`。
- 点击 = 现有 `callbacks.onSubmitPeace(cfg)`,不改。
- respond 模式此栏被 3.7 的接受/拒绝替代。

---

## 4. 数据绑定与回调契约(全部不许改签名)

以下函数保持现有签名与语义,**内部渲染逻辑重写但对外零变化**——
`main.lua` 的接线(571–627、724–752 行)与 `MapRenderer` 涂抹选省**一行都不用动**:

| 函数 | 作用 | 新 UI 中谁在用 |
|---|---|---|
| `GameUI.showPeaceDialog(gs, cfg)` | 打开;cfg.mode = propose/respond | 区域 A–F 初始化 |
| `GameUI.refreshPeaceDialog(gs)` | 重算成本/分数/行勾选态 | 预算行、卡片、省份行、缔结栏 |
| `GameUI.peaceDialogCost()` | 已耗成本 | 预算行 |
| `GameUI.isPeacePickMode() / isProvincePickable(pid)` | 地图涂抹判断 | 不变 |
| `GameUI.togglePeaceProvincePick(pid, forceSelect?)` | 省 toggle | 行点击 & 地图涂抹共用 |
| `GameUI.getPeace{Selection,Gold,Food,Vassal,Annex}()` | 提交时收集 | 不变 |
| `callbacks.onPeaceSelectionChanged(ids)` | 通知地图金色高亮 | 省份集合变化时照旧调用 |
| `callbacks.onSubmitPeace(cfg)` / `onCancelPeace` / `onAcceptPeace` / `onRejectPeace` | 系统提交 | 缔结/关闭按钮 |
| `cfg.terms.provinceList` / `cfg.terms.allOccupied` | 省份数据 | 区域 D |
| `WarSystem.getScore / getProvinceCost` | 分数/单省成本 | 显示用,**不改数值** |

成本公式不变:占领省 5 分 / 未占领 15 分 / 金粮每 100=1 分 / 附庸 30 分 / 灭国绕过预算。

---

## 5. 视觉规范

- 字体沿用现有 `COLORS`(textPrimary/textSecondary/gold);分区底色见上。
- 圆角统一:面板 10、卡片/行 6、按钮 6。
- 间距:区 padding 12,元素 gap 8,行内 gap 6。
- 所有数字类文本用金色高亮,说明文字用灰,警告红 `{220,70,55}`,成功绿 `{90,180,95}`。
- 禁止改动 `createPeaceDialog` 之外的 UI 模块;`SmallButton` 等本地构造器可复用。

---

## 6. 边界与状态规则(DeepSeek 必须逐条处理)

1. **超预算**:缔结禁用 + 红字(6.2);annexAll 时缔结永不禁用、成本列不参与判断。
2. **省份列表为空**:居灰字占位,缔结仍可用(允许白和,结算逻辑本就允许空 provinces)。
3. **respond 模式**:所有 stepper/卡片/省份表工具按钮隐藏;关闭 X = 拒绝并回调 `onCancel`?——不,保持现状:respond 的 X 行为沿用现逻辑,只有「接受/拒绝」才触发回调。
4. **涂抹 ↔ 列表同步**:地图 `forceSelect` 涂抹后,`togglePeaceProvincePick` 已回写行,确保新省份行的 `setSelected` 同样被调用(保留 `refs.peaceProvRows` 机制)。
5. **ScrollView**:内容超屏高可滚;滚动区不要把地图点击吞掉(面板自身 pointerEvents auto,面板外 box-none)。
6. **打开窗口自动聚焦镜头**(`onPeaceDialogOpened`)与关闭清高亮(`onPeaceDialogClosed`)保持不变。
7. 吞并确认浮层(`refs.annexConfirmOverlay`)保留,覆盖整个屏幕(zIndex 高于面板)。

---

## 7. 实现步骤建议

1. 在 `GameUI.lua` 内重写 `createPeaceDialog()`:新布局树(区域 A–F + respond 只读块);
2. 重写 `refreshPeaceDialog()`:更新预算行/卡片选中态/省份行勾选/缔结禁用,删除 ProgressBar 相关;
3. `showPeaceDialog()`:生成省份行时同时登记 `refs.peaceProvRows`,mode 切换显示区域;
4. 自测:propose 全交互 + respond 只读两条路径;
5. 用 LSP 诊断(`lua_lsp_client`,severity=1)确认无 Error 后,**调用 UrhoX MCP `build` 工具**构建;
6. 不新增 require,不改其他文件。

## 8. 验收清单(逐条对照)

- [ ] 打开和谈:左侧全高面板,右侧地图可见可点、可涂抹选省
- [ ] 点省份行 ↔ 地图金色高亮双向同步
- [ ] 分数大字金 + 🏆;预算行三数(已耗/剩余/已选)实时刷新
- [ ] 赔金/赔粮 [−][+] 步进,成本小字跟随
- [ ] 附庸卡 toggle ✓ 态;吞并卡仅全境占领点亮,确认后走原灭国流程
- [ ] 超预算:剩余红「不足」+ 缔结禁用;annexAll 豁免
- [ ] AI 求和(respond):只读条款 + 接受/拒绝正常结算
- [ ] 结算结果与旧版完全一致(割省/金粮/附庸/灭国播报)
- [ ] LSP 无 Error、build 通过、其他 UI(顶栏/省份面板/排行榜)无回归

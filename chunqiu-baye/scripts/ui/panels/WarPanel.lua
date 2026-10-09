-- ============================================================================
-- WarPanel.lua — 地图模式 + 战斗卡片 + 战争列表 + 战争面板（2026-09-26 从 GameUI.lua 拆出）
--
-- 这块 763 行，与 GameUI 其余部分零耦合（块内所有 GameUI.xxx 都在块内定义）。
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：导出 create(ctx) / install(GameUI)，
-- ctx 注入 UI/GameUI/refs/COLORS/SmallButton/Emblem，**不 require GameUI**
-- （避免与 GameUI 形成循环依赖）。
-- ============================================================================

local M = {}

-- ── 模块级共享引用（create 时注入）──────────────────────────────
---@type any
local UI
---@type any
local GameUI
---@type table
local refs
---@type table
local COLORS
---@type function
local SmallButton
---@type any
local Emblem
---@type any
local WarSystem

local MAP_MODES = {
    { id = "political", label = "国家", desc = "国家版图", detail = "默认模式：只显示国名与国家颜色（地区划分看「地区」模式）" },
    { id = "region",    label = "地区", desc = "只看地区", detail = "只显示省名与省界，不显示国名" },
    { id = "war",       label = "战争", desc = "我方蓝·敌方红", detail = "我方领土蓝色、交战中的敌方红色、其余国家灰色（一眼看清战场）" },
    { id = "ally",      label = "盟友", desc = "盟友关系", detail = "点选国家：选中绿色、盟友蓝色、敌方红色、中立灰；只显示国名" },
    { id = "resource",  label = "资源", desc = "省份产出", detail = "省份上显示金/粮产出（放大可见）" },
    { id = "terrain",   label = "地形", desc = "地形分布", detail = "按地形上色：平原/草原/丘陵/山地/森林/沼泽/盆地/沿海（地形影响产出与防御）" },
}

-- ============================================================
-- 3.9) Map Mode Panel（右下角地图模式切换，2026-09-01）
--   2026-09-24 加**折叠**（用户："点这个三角它就收缩成一条线…箭头变成向上的"）：
--     收起 = 只留一行「模式说明 + 三角」，六颗按钮整排隐藏，面板缩成一条；
--     再点 = 展开回六颗按钮。折叠状态记在 refs.mapModeFolded。
--   ⚠️ 三角用 "▼"/"▲"（U+25BC / U+25B2）：MiSans 有这两个字形。
--      不要用 "▾"/"▴"（U+25BE / U+25B4）——字体里**没有**，会渲染成空方框。
-- ============================================================
local function toggleMapModePanel()
    local panel = refs.mapModePanel
    if not panel or not refs.mapModeBody or not refs.mapModeFoldBtn then return end
    refs.mapModeFolded = not refs.mapModeFolded
    if refs.mapModeFolded then
        refs.mapModeBody:Hide()
        refs.mapModeFoldBtn:SetText("▲")
        refs.mapModeDesc.props.maxLines = 1
    else
        refs.mapModeBody:Show()
        refs.mapModeFoldBtn:SetText("▼")
        refs.mapModeDesc.props.maxLines = 1
    end
    print("[MapMode] " .. (refs.mapModeFolded and "已收起" or "已展开"))
end

local function createMapModePanel(callbacks)
    refs.mapModeDesc = UI.Label {
        text = "",
        fontSize = 12,
        fontColor = COLORS.textSecondary,
        whiteSpace = "normal",
        maxLines = 2,
        flexGrow = 1, flexShrink = 1,
    }
    -- 折叠三角（2026-09-24）：点它收起/展开下面两排按钮
    --   外观 = **完全透明**（用户："直接让它变成完全透明"）。
    --   为什么不能只"改成和面板同色"：面板底色 bgPanel 本身是半透明的
    --   ({20,25,35,240})，按钮再铺一层同样的半透明色 → 两层叠加后更深，
    --   仍然看得见一个方块。所以必须 alpha=0。
    --   glowShadow 也要显式关掉：Button 主题默认带一层黑色内阴影（底部 3px），
    --   那层阴影同样会把这个方块勾出来。
    --   悬停给一点极淡的亮色，否则完全看不出这里可以点。
    refs.mapModeFoldBtn = UI.Label {
        text = "▼", width = 24, fontSize = 14, flexShrink = 0,
        fontColor = COLORS.textSecondary, pointerEvents = "none", textAlign = "center",
    }
    refs.mapModeHeader = UI.Button {
        id = "mapModeHeader", width = "100%", height = 48, padding = 0,
        backgroundColor = { 0, 0, 0, 0 }, hoverBackgroundColor = { 70, 86, 112, 110 },
        pressedBackgroundColor = { 52, 64, 88, 160 }, glowShadow = false,
        onClick = function() GameUI.toggleMapModePanel() end,
        children = { UI.Panel { width = "100%", height = "100%", pointerEvents = "none",
            flexDirection = "row", alignItems = "center", gap = 6,
            children = { refs.mapModeDesc, refs.mapModeFoldBtn } } },
    }
    refs.mapModeButtons = {}
    -- 3×2 两行布局（2026-09-01）：第 1 行 3 个，第 2 行 3 个
    local btnRow1 = UI.Panel { flexDirection = "row", gap = 6, children = {} }
    local btnRow2 = UI.Panel { flexDirection = "row", gap = 6, children = {} }
    for i, m in ipairs(MAP_MODES) do
        local btn = SmallButton(m.label, function()
            if callbacks.onSetMapMode then callbacks.onSetMapMode(m.id) end
        end, { id = "mapMode_" .. m.id, flexGrow = 1, flexBasis = 0, height = 52, fontSize = 13, bg = { 40, 50, 70, 220 } })
        -- 长按：临时显示该模式详细说明
        btn.props.onLongPressStart = function()
            refs.mapModeDesc.text = m.detail
        end
        btn.props.onLongPressEnd = function()
            if refs.gameState then
                GameUI.refreshMapModePanel(refs.gameState)
            end
        end
        refs.mapModeButtons[m.id] = btn
        if i <= 3 then
            btnRow1:AddChild(btn)
        else
            btnRow2:AddChild(btn)
        end
    end

    -- 可折叠的部分 = 两排按钮
    refs.mapModeBody = UI.Panel {
        flexDirection = "column", gap = 6, width = "100%",
        children = { btnRow1, btnRow2 },
    }

    refs.mapModePanel = UI.Panel {
        position = "absolute",
        bottom = 12,
        right = 12,
        width = 210,
        gap = 6,
        alignItems = "flex-start",
        backgroundColor = COLORS.bgPanel,
        borderWidth = 1,
        borderColor = COLORS.border,
        borderRadius = 8,
        padding = 8,
        pointerEvents = "auto",
        children = {
            refs.mapModeHeader,
            refs.mapModeBody,
        },
    }
    refs.mapModeFolded = false
    return refs.mapModePanel
end

-- ============================================================
-- 3.91) Battle Cards（右下角模式面板左侧的战斗卡，2026-09-01）
--   每场战斗一张卡：攻方名+兵力 ⚔ 守方名+兵力 + 绿/红进度条
--   新的战斗卡向左延伸（不遮挡模式面板）
-- ============================================================
local function createBattleCards(callbacks)
    -- 横排（2026-09-01 修正）：从右向左排列，新战斗在左
    refs.battleCards = UI.Panel {
        flexDirection = "row",
        alignItems = "flex-start",
        gap = 6,
        pointerEvents = "auto",
        children = {},
    }
    refs.battleCardPanel = UI.Panel {
        position = "absolute",
        bottom = 12,
        right = 400,   -- 战争列表（right222 宽~180）左侧，底部一行
        gap = 4,
        alignItems = "flex-end",
        pointerEvents = "auto",
        children = { refs.battleCards },
    }
    refs.battleCardPanel:Hide()
    return refs.battleCardPanel
end

--- 刷新战斗卡列表（签名变化时重建；节流防闪烁）
---@param gameState table
local function refreshBattleCards(gameState)
    if not refs.battleCardPanel then return end
    -- 节流（2026-09-01）：兵力/进度每帧变化会频繁重建导致"一抽一抽"，限制 0.25s 一次
    local now = os.clock()
    if refs.lastBattleRefresh and (now - refs.lastBattleRefresh) < 0.25 then
        return
    end
    refs.lastBattleRefresh = now

    local battles = gameState.battles or {}
    local count = 0
    for _ in pairs(battles) do count = count + 1 end
    if count == 0 then
        refs.battleCardPanel:Hide()
        refs.battleFirstSeen = {}
        return
    end
    -- 记录战斗首次出现时间（新战斗排最左）
    refs.battleFirstSeen = refs.battleFirstSeen or {}
    for pid, _ in pairs(battles) do
        if not refs.battleFirstSeen[pid] then
            refs.battleFirstSeen[pid] = now
        end
    end
    for pid, _ in pairs(refs.battleFirstSeen) do
        if not battles[pid] then
            refs.battleFirstSeen[pid] = nil
        end
    end

    local pf = gameState.playerFactionId

    -- 签名（变化才重建）
    local sig = {}
    for pid, b in pairs(battles) do
        sig[#sig + 1] = pid .. ":" .. b.att.size .. ":" .. b.def.size .. ":" .. math.floor(b.progress * 100)
    end
    table.sort(sig)
    -- ⚠️ 签名必须含"我方是谁"（2026-09-15 换视角）：
    --    换国家/看海后战斗数据可能一个字节都没变，但卡片配色与文案要跟着换视角走；
    --    不带 pf 就会命中"没变就不重建"的早退，界面停在旧视角。
    local sigStr = tostring(pf) .. "#" .. table.concat(sig, "|")
    if sigStr == (refs.lastBattleSig or "") then
        refs.battleCardPanel:Show()
        return
    end
    refs.lastBattleSig = sigStr

    -- 新战斗在前（向左排列）
    local pids = {}
    for pid, _ in pairs(battles) do pids[#pids + 1] = pid end
    table.sort(pids, function(a, b)
        return (refs.battleFirstSeen[a] or 0) > (refs.battleFirstSeen[b] or 0)
    end)

    refs.battleCards:ClearChildren()
    for i = 1, #pids do
        local pid = pids[i]
        local b = battles[pid]
        local prov = gameState.provinces[pid]
        local atkFac = gameState.factions[b.att.factionId]
        local defFac = gameState.factions[b.def.factionId]
        local atkName = atkFac and atkFac.name or "?"
        local defName = defFac and defFac.name or "?"
        -- 这场战斗里"有没有我方"？
        --   两种情况下没有：① 看海（pf=nil）② 别家互殴（pf 非 nil 但两边都不是他）。
        --   没有"我方"时不能写「我方占优/劣势」，改按**攻守**描述 + 中性金色（2026-09-15 换视角）
        local iAmAtt = pf ~= nil and b.att.factionId == pf
        local iAmDef = pf ~= nil and b.def.factionId == pf
        local green, barColor, labelText, labelColor, borderColor
        if not (iAmAtt or iAmDef) then
            local attackerAhead = b.progress >= 0
            barColor    = "#C8A250"                       -- 中性金：不代表任何一方
            labelText   = attackerAhead and "进攻方占优" or "防守方占优"
            labelColor  = COLORS.textSecondary
            borderColor = { 200, 162, 80, 255 }
        else
            -- ⚠️ 不能写成 `iAmAtt and (b.progress >= 0) or (b.progress <= 0)`：
            --    前者为 false 时会掉到后半句，把"我方进攻落后"误判成占优
            if iAmAtt then green = b.progress >= 0 else green = b.progress <= 0 end
            barColor    = green and "#3CC85A" or "#DC3C3C"
            labelText   = green and "我方占优" or "我方劣势"
            labelColor  = green and { 60, 200, 90, 255 } or { 220, 60, 60, 255 }
            borderColor = green and { 60, 200, 90, 255 } or { 220, 60, 60, 255 }
        end
        local card = UI.Panel {
            width = 170,
            height = 120,
            gap = 4,
            padding = 8,
            backgroundColor = { 15, 20, 32, 215 },
            borderRadius = 6,
            borderWidth = 1,
            borderColor = borderColor,
            children = {
                UI.Label {
                    text = string.format("%s %d vs %s %d", atkName, b.att.size, defName, b.def.size),
                    fontSize = 13,
                    fontColor = COLORS.textPrimary,
                    fontWeight = "bold",
                },
                UI.Label {
                    text = prov and ("📍 " .. prov.name) or "?",
                    fontSize = 11,
                    fontColor = COLORS.textSecondary,
                },
                UI.ProgressBar {
                    value = math.abs(b.progress),
                    max = 1,
                    height = 10,
                    width = "100%",
                    borderRadius = 4,
                    backgroundColor = { 50, 20, 20, 200 },
                    fillColor = barColor,
                    showLabel = false,
                },
                UI.Label {
                    text = labelText,
                    fontSize = 10,
                    fontColor = labelColor,
                },
            },
        }
        refs.battleCards:AddChild(card)
    end
    refs.battleCardPanel:Show()
end

--- 刷新地图模式面板（当前模式说明 + 按钮高亮）
---@param gameState table
local function refreshMapModePanel(gameState)
    if not refs.mapModePanel or not refs.mapModeButtons then return end
    local mode = gameState.mapMode or "political"
    local cur = nil
    for _, m in ipairs(MAP_MODES) do
        if m.id == mode then cur = m end
    end
    if cur then
        local extra = ""
        if mode == "ally" and gameState.allyViewFactionId then
            local vf = gameState.factions[gameState.allyViewFactionId]
            if vf then
                extra = "　视角:" .. (vf.name or "?")
            end
        end
        refs.mapModeDesc.text = "地图 · " .. cur.label .. extra
    end
    for mid, btn in pairs(refs.mapModeButtons) do
        if mid == mode then
            -- 选中：金色高亮（2026-09-16 用户："我们选择的这个就看不清了"——
            --   原来用 SPEED_BTN_ACTIVE 的深色，压在木牌底图上成了一大块黑）
            btn.props.backgroundColor = { 168, 124, 38, 240 }        -- 暗金
            btn.props.hoverBackgroundColor = { 196, 150, 52, 245 }
            btn.props.textColor = { 255, 240, 196, 255 }             -- 亮金米
            btn.props.backgroundImageOpacity = 0.55                  -- 木纹透一点
        else
            btn.props.backgroundColor = nil                          -- 未选中：走皮肤木牌本色
            btn.props.hoverBackgroundColor = nil
            btn.props.textColor = nil
            btn.props.backgroundImageOpacity = 0.94
        end
    end
end

-- ============================================================
-- 4) War List（右下角战争列表）
-- ============================================================
--- 立即刷新战争列表（宣战成功时调用，绕过节流延迟）
---@param gameState table
local function forceRefreshWarList(gameState)
    refs.lastWarRefresh = nil
    GameUI.refreshWarList(gameState)
end

--- 刷新右下战争列表（仅当战争集合变化时重建；节流防闪烁）
---@param gameState table
local function refreshWarList(gameState)
    if not refs.warList then return end
    -- 节流（2026-09-01）：分数每帧变化会频繁重建导致闪烁
    local now = os.clock()
    if refs.lastWarRefresh and (now - refs.lastWarRefresh) < 0.25 then
        return
    end
    refs.lastWarRefresh = now

    local pid = gameState.playerFactionId
    local wars = pid and WarSystem.getWarsFor(gameState, pid) or {}

    -- 排序 + 布局（2026-09-17 用户："两个战争应该左右排，最早的放最右边"）：
    --   容器是**横排**且右对齐 → 先加的靠左、后加的靠右；
    --   所以按"新→旧"顺序加 → 最新的在最左，**最早开战的落在最右**。
    table.sort(wars, function(a, b)
        local sa = a.war.startedAt or 0
        local sb = b.war.startedAt or 0
        -- 同一时刻开战（或都没记时间）→ 按 id 从大到小，让"先打的"落在后面（=最右）
        if sa == sb then return a.enemyId > b.enemyId end
        return sa > sb
    end)
    local sig = {}
    for i = 1, #wars do
        local w = wars[i]
        local myScore = math.floor(WarSystem.getScore(gameState, w.war, pid))
        local eScore = math.floor(WarSystem.getScore(gameState, w.war, w.enemyId))
        sig[i] = w.enemyId .. ":" .. myScore .. ":" .. eScore
    end
    local sigStr = table.concat(sig, ",")
    if sigStr == (refs.lastWarSig or "") then
        -- 内容没变：仅更新外层可见性
        if #wars > 0 then refs.warPanel:Show() else refs.warPanel:Hide() end
        return
    end
    refs.lastWarSig = sigStr

    -- 一行放不下时自动缩小（用户："不许换行，只允许一行；也不能超出屏幕"）
    --   每面锦旗按 0.55 倍高度占宽 → 估算能放下多高
    local avail = 600
    local flagH = 92
    if #wars > 0 then
        local per = avail / #wars
        if per < 51 then
            flagH = math.max(38, math.floor(92 * per / 51))
        end
    end

    refs.warList:ClearChildren()
    for i = 1, #wars do
        local w = wars[i]
        local enemy = gameState.factions[w.enemyId]
        local myScore = WarSystem.getScore(gameState, w.war, pid)
        local eScore  = WarSystem.getScore(gameState, w.war, w.enemyId)
        local diff = myScore - eScore
        -- 2026-09-19 用户："绿色应该是我们占优" —— 旗面数字和颜色统一按**我方视角**：
        --   显示我方战争分数（正 = 我占优/绿，负 = 我劣势/红），跟 EU4/CK3 同口径。
        --   原来显示的是**敌方分数**、颜色却按差值算 → "数字负的却标红"看着自相矛盾。
        local barColor = myScore >= 0 and COLORS.warGood or COLORS.warBad

        -- 优势色（2026-09-17 用户："绿色太淡了" → 提饱和 + 深色描边，压在旗面上也读得清）
        local pctColor = myScore >= 0 and { 110, 245, 130, 255 } or { 255, 90, 80, 255 }

        -- 点这一格 → 打开和谈面板（2026-09-17，照 CK3 点战争进和谈）
        local row = UI.Button {
            -- 宽度不写死：贴着旗子自然宽度（并排时才不会挤到左边的战斗面板）
            -- 高度写死 = 旗高：百分比用绝对定位压在旗面上，不再靠负边距（负边距会让容器
            -- 算矮 → 旗子被挤出屏幕底部，2026-09-17 踩过）
            height = flagH,
            alignItems = "center",
            padding = 0,
            backgroundColor = { 0, 0, 0, 0 },
            hoverBackgroundColor = { 255, 255, 255, 18 },
            pressedBackgroundColor = { 255, 255, 255, 30 },
            onClick = function()
                -- 2026-09-18 用户 4 步走：点战旗 → **底部展开战争面板**（含双方国旗/分数/按钮），
                --   不再直接弹居中和谈窗（那个挡地图）；和谈从面板里的「提出条款」进
                GameUI.openWarBar(gameState, w.enemyId)
            end,
            -- 无框无底（2026-09-17 用户："为什么要有这个框""长条不要有"）
            -- 只有：**敌方那面锦旗**（不带杆）+ 压在旗面上的百分比
            children = {
                Emblem.MakeCloth(enemy, "war", flagH),
                UI.Label {
                    -- 我方战争分数（2026-09-19 改：原来是敌方分数 eScore，和颜色方向对不上）
                    text = tostring(math.floor(myScore)) .. "%",
                    fontSize = math.max(11, math.floor(flagH * 0.23)),
                    fontColor = pctColor,
                    fontWeight = "bold",
                    textStroke = { width = 3, color = { 18, 14, 10, 240 } },
                    -- 负边距 → 直接压在旗子下半身（行高已写死 = flagH，不会再算矮）
                    marginTop = -math.floor(flagH * 0.28),
                },
            },
        }
        refs.warList:AddChild(row)
    end


    if #wars > 0 then refs.warPanel:Show() else refs.warPanel:Hide() end
end

local function createWarList()
    -- **永远只有一行**（2026-09-17 用户："不可以换行，只允许这一行"）：
    --   条目多到放不下时，按数量**自动缩小**（见 refreshWarList 里的 flagH 计算），
    --   所以既不会换行、也不会跑出屏幕。
    --   ⚠️ 试过 UI.ScrollView 做横向滑动：离屏渲染下内容不出现（踩过），先不用它。
    refs.warList = UI.Panel {
        flexDirection = "row",
        alignItems = "flex-end",
        gap = 8,
    }

    refs.warPanel = UI.Panel {
        position = "absolute",
        bottom = 12,
        right = 222,   -- 2026-09-01：底部一行，模式面板左侧
        gap = 6,
        alignItems = "flex-end",
        pointerEvents = "auto",
        children = { refs.warList },
    }
    refs.warPanel:Hide()
    return refs.warPanel
end

-- ============================================================
-- 4.5) War Bar（底部战争面板 · 2026-09-18 用户 4 步走之 2/3/4）
--   点右下角战旗 → **底部展开**（原来直接弹居中和谈窗，挡地图）；
--   左 = 我方旗 + 国名 + 兵力 ｜ 中 = 战争分数条 ｜ 右 = 敌方；
--   下排按钮：提出条款（进和谈）/ 收起。整条**可拖动** —— 拖到哪停哪，不挡地图。
--   （参考图里左右下角是人物立绘，我们没有立绘 → 用国旗，2026-09-18 用户拍板）
-- ============================================================

--- 建底部战争面板（只建一次，内容在 refreshWarBar 里更新）
local function createWarBar()
    refs.warBarEnemyId = nil

    -- ⚠️ 拖动能生效的前提：面板内的**非交互元素全部 pointerEvents="none"**
    --   （UI 库派发 pointermove 时**不冒泡** —— 按到子元素时面板自己收不到移动事件，
    --     结果就是"按下去有反应、拖不动"，2026-09-18 踩过）
    local NO_PTR = { pointerEvents = "none" }

    -- 左：我方旗 —— **可点**（2026-09-18 用户设计：点旗 → 参战方详情弹窗；
    --   子元素没挂 onClick 时点击会**冒泡**到旗位本身，见 Widget:OnClick）
    refs.warBarFlagBoxL = UI.Panel {
        width = 76, height = 64, alignItems = "center", justifyContent = "center",
        onClick = function() GameUI.openWarParties("me") end,
    }
    -- 损失（阵亡累计）—— 2026-09-18 用户："兵力不要显示"，改成只报战损
    refs.warBarLossL = UI.Label { text = "损失 0", fontSize = 14, fontColor = { 205, 185, 180, 235 }, pointerEvents = "none" }

    -- 右：敌方旗（同上，可点 → 只看敌方阵营）
    refs.warBarFlagBoxR = UI.Panel {
        width = 76, height = 64, alignItems = "center", justifyContent = "center",
        onClick = function() GameUI.openWarParties("enemy") end,
    }
    refs.warBarLossR = UI.Label { text = "损失 0", fontSize = 14, fontColor = { 205, 185, 180, 235 }, pointerEvents = "none" }

    -- 标题：战争名称 + 已进行时长（参考图顶部那行字）
    refs.warBarTitle = UI.Label {
        text = "战争", fontSize = 16, fontWeight = "bold",
        fontColor = { 245, 225, 175, 245 }, pointerEvents = "none",
    }

    -- 中：战争分数（文字 + 双向条）
    refs.warBarScoreTxt = UI.Label {
        text = "战争分数 0 : 0", fontSize = 18, fontWeight = "bold",
        fontColor = { 255, 226, 150, 255 }, pointerEvents = "none",
    }
    refs.warBarBar = UI.ProgressBar {
        -- 在"−100 ［条］ +100"这一行里伸缩（两端留给刻度文字，2026-09-18 用户要求）
        value = 50, max = 100, height = 16, flexGrow = 1, flexBasis = 0,
        borderRadius = 8,
        backgroundColor = { 18, 14, 10, 240 },       -- 深色凹槽（压在木纹底上像刻进去的）
        -- 渐变填充（优势蓝 / 劣势红，在 refreshWarBar 里按战况切）：
        --   "照片做的条动不了"—— 但渐变是代码画的，数值一变长度和颜色都跟着变
        fillGradient = { direction = "to-right", from = { 40, 90, 170, 255 }, to = { 120, 210, 255, 255 } },
        showLabel = false,
        pointerEvents = "none",
    }

    -- 条 + 两端刻度：**-100 在条左端、+100 在条右端**（同一行，跟参考图一致）
    local barRow = UI.Panel {
        flexDirection = "row", alignItems = "center", gap = 10,
        width = "100%", maxWidth = 720, pointerEvents = "none",
        children = {
            UI.Label { text = "-100", fontSize = 12, fontColor = { 205, 190, 165, 220 }, pointerEvents = "none" },
            refs.warBarBar,
            UI.Label { text = "+100", fontSize = 12, fontColor = { 205, 190, 165, 220 }, pointerEvents = "none" },
        },
    }

    -- 下排按钮：提出条款（进和谈面板）/ 收起
    local btnTerms = UI.Button {
        text = "提出条款", fontSize = 16, height = 46, paddingHorizontal = 28,
        backgroundColor = { 62, 50, 30, 235 }, borderRadius = 8,
        borderWidth = 1, borderColor = { 190, 150, 80, 220 },
        textColor = { 255, 226, 150, 255 },
        onClick = function()
            local gs = refs.gameState
            local eid = refs.warBarEnemyId
            if not gs or not eid then return end
            if refs.callbacks and refs.callbacks.onInteraction then
                refs.callbacks.onInteraction("peace", eid)
            end
        end,
    }
    local btnClose = UI.Button {
        text = "收起", fontSize = 15, height = 46, paddingHorizontal = 22,
        backgroundColor = { 48, 42, 44, 220 }, borderRadius = 8,
        borderWidth = 1, borderColor = { 120, 100, 100, 200 },
        textColor = { 225, 215, 205, 235 },
        onClick = function() GameUI.closeWarBar() end,
    }

    refs.warBar = UI.Panel {
        position = "absolute",
        left = 0, top = 16,               -- 打开时按屏幕算（贴底，见 openWarBar）
        width = "100%",                   -- ★ 横跨整个底边（用户："把底边全部覆盖"）
        -- ★ 扁平化（2026-09-18 用户拍板："画风就要我们这个专门的画风"）：
        --   跟主菜单按钮 / 省份面板**同一套语言** —— 深色半透明底 + 1px 金线 + 圆角。
        --   （之前的照片木纹/雕花柱虽然好看，但和全局扁平体系不搭、显得"跳"；
        --     统一靠**旗子**这种已有元素来出彩，而不是换材质）
        -- 底 = 生成的**纯背景**素材（深蓝黑 + 细金边 + 四角云纹，**不含任何文字/按钮/图标**，
        --   内容全靠代码往上叠）：这正是"静态用图、动态用代码"的分工
        backgroundImage = "image/war_panel_bg_flat.jpg",   -- 512×512 / 仅 13KB
        backgroundFit = "sliced",
        backgroundSlice = { left = 80, top = 80, right = 80, bottom = 80 },
        backgroundColor = COLORS.bgPanel,   -- 兜底底（图没加载出来时不至于透明）
        borderWidth = 0,                    -- 描边由图里的金线提供
        paddingHorizontal = 24,
        paddingVertical = 12,
        gap = 8,
        pointerEvents = "auto",
        children = {
            -- ① 顶行：左旗 ｜ 战争名 + 时长 ｜ 右旗（照参考图：信息竖着排，旗在两端）
            --   ⚠️ 这一行**不能**设 pointerEvents="none"：findWidgetAt 遇到 none 会
            --   跳过**整个子树**（含旗子）→ 旗子点不着（2026-09-18 踩过）。
            --   代价：按在顶行空白/标题上拖不动面板（标题自己仍是 none）——拖别处即可。
            UI.Panel {
                flexDirection = "row", alignItems = "center", justifyContent = "space-between",
                width = "100%",
                children = { refs.warBarFlagBoxL, refs.warBarTitle, refs.warBarFlagBoxR },
            },
            -- ② 战争分数 + 双向条（−100 / +100 分列条两端）
            UI.Panel {
                alignItems = "center", gap = 6, width = "100%", pointerEvents = "none",
                children = { refs.warBarScoreTxt, barRow },
            },
            -- ③ 双方损失（并排居中）
            UI.Panel {
                flexDirection = "row", gap = 48, justifyContent = "center",
                width = "100%", pointerEvents = "none",
                children = { refs.warBarLossL, refs.warBarLossR },
            },
            -- ④ 按钮行（居中）
            UI.Panel {
                flexDirection = "row", gap = 10, justifyContent = "center", width = "100%",
                children = { btnTerms, btnClose },
            },
        },
    }

    -- 拖动：整条都是抓手（拖到哪停哪 —— 用户："不能太占地方，要能看到地图"）
    local dragging, startX, startY, baseX, baseY = false, 0, 0, 0, 0
    refs.warBar.props.onPointerDown = function(event)
        -- 只有"按在面板本体上"才拖（按到按钮上不拖，否则点按钮时手一抖就把面板挪走）
        if event.target and event.target ~= refs.warBar then return end
        local l = refs.warBar:GetAbsoluteLayout()
        if not l then return end
        dragging = true
        startX, startY = event.x, event.y     -- UI 事件的 x/y 就是屏幕坐标（base pixel）
        baseX, baseY = l.x, l.y
    end
    refs.warBar.props.onPointerMove = function(event)
        if not dragging then return end
        refs.warBar:SetStyle({
            left = baseX + (event.x - startX),
            top  = baseY + (event.y - startY),
        })
    end
    refs.warBar.props.onPointerUp = function() dragging = false end
    refs.warBar.props.onPointerCancel = function() dragging = false end

    refs.warBar:Hide()
    return refs.warBar
end

--- 打开底部战争面板（点右下角战旗时调）
---@param gameState table
---@param enemyId number
local function openWarBar(gameState, enemyId)
    if not refs.warBar then return end
    refs.warBarEnemyId = enemyId

    -- 每次打开回到默认位：**横跨底边**（拖走是"本次会话"的事，关掉再开回到底部）
    local sh = (UI.GetHeight and UI.GetHeight()) or 600
    local m = refs.navigationMetrics
    refs.warBar:SetStyle({
        width = m and m.contentW or UI.GetWidth(),
        left = m and m.left or 0,
        top = math.max(m and m.top or 60, sh - (m and m.bottom or 0) - 200),
    })

    GameUI.refreshWarBar(gameState)
    refs.warBar:Show()
    -- Show 的这一刻 Yoga 还没量过高度 → 下一帧按**实际高度**贴底（否则底部会被切掉）
    refs.warBarAlignPending_ = true

    -- 看战争面板 = 停下来看（2026-09-18 用户："进入这个界面应该是暂停的状态"）
    local okTS, TimeSystem = pcall(require, "core.TimeSystem")
    if okTS and TimeSystem and TimeSystem.pause then
        TimeSystem.pause()
        gameState.paused = true            -- 顶层状态也标一下（顶栏暂停图标跟着亮）
    end

    print(string.format("[WarBar] 展开战争面板：敌方 id=%s（时间已暂停）", tostring(enemyId)))
end

--- 打开"参战方"详情弹窗（点战争面板两端的旗子 → 2026-09-18 用户设计）
---   side：左旗传 "me"（只看我方阵营）/ 右旗传 "enemy"（只看敌方阵营）
---@param side string|nil
local function openWarParties(side)
    local gs = refs.gameState
    local eid = refs.warBarEnemyId
    if not gs or not eid then return end
    local okWP, WarPartiesPanel = pcall(require, "ui.WarPartiesPanel")
    if not okWP or not WarPartiesPanel then
        print("[WarParties] ⚠️ 模块加载失败：" .. tostring(WarPartiesPanel))
        return
    end
    WarPartiesPanel.Open(gs, eid, refs.rootPanel, side)
end

--- 收起底部战争面板
local function closeWarBar()
    if refs.warBar then refs.warBar:Hide() end
    refs.warBarEnemyId = nil

    -- 参战方弹窗跟着关（战争面板都收了，子弹窗不该还浮着，2026-09-18）
    local okWP, WarPartiesPanel = pcall(require, "ui.WarPartiesPanel")
    if okWP and WarPartiesPanel then WarPartiesPanel.Close() end

    -- 关面板 → 时间自动恢复（2026-09-18 用户拍板：不要求玩家再点一次）
    local okTS, TimeSystem = pcall(require, "core.TimeSystem")
    if okTS and TimeSystem and TimeSystem.resume then
        TimeSystem.resume()
        if refs.gameState then refs.gameState.paused = false end
    end
end

local function isWarBarVisible()
    return refs.warBar and refs.warBar:IsVisible() or false
end

--- 刷新底部战争面板数据（每帧调，内部节流）
---@param gameState table
local function refreshWarBar(gameState)
    local eid = refs.warBarEnemyId
    if not refs.warBar or not eid or not refs.warBar:IsVisible() then return end

    -- 打开后第一次：按**实际高度**贴底（必须放在节流之前，否则要等 0.25s 才对齐）
    if refs.warBarAlignPending_ then
        local l = refs.warBar:GetAbsoluteLayout()
        if l and l.h and l.h > 10 then
            local sh = (UI.GetHeight and UI.GetHeight()) or 600
            local m = refs.navigationMetrics
            refs.warBar:SetStyle({ top = math.max(m and m.top or 56, sh - (m and m.bottom or 0) - l.h - 8) })
            refs.warBarAlignPending_ = false
        end
    end

    -- 节流：0.25s（和战争列表一致，避免每帧重建/闪烁）
    local now = os.clock()
    if refs.lastWarBarRefresh and (now - refs.lastWarBarRefresh) < 0.25 then return end
    refs.lastWarBarRefresh = now

    local WarSystem = require("systems.WarSystem")
    local pid = gameState.playerFactionId
    local war = pid and WarSystem.findWar(gameState, pid, eid) or nil
    if not war then
        GameUI.closeWarBar()      -- 战争已结束（议和/灭亡）→ 自动收起
        return
    end

    local me = gameState.factions[pid]
    local enemy = gameState.factions[eid]
    if not me or not enemy then GameUI.closeWarBar() return end

    local myScore = math.floor(WarSystem.getScore(gameState, war, pid))
    -- 只报**一个**数（我方视角的战争分）—— 用户："为什么有两个 +0"。
    --   条本身就是 -100~+100 的刻度尺，两端已经标了，不需要再列双方两个数
    refs.warBarScoreTxt:SetText(string.format("战争分数 %+d", myScore))
    -- 双向条：-100~+100 映射到 0~100，中线 = 均势
    local v = 50 + myScore * 0.5
    if v < 0 then v = 0 elseif v > 100 then v = 100 end
    refs.warBarBar:SetValue(v)
    -- 渐变填充：优势蓝 / 劣势红。这就是"条要会动"的答案 ——
    --   长度随分数、颜色随优劣，**全是代码算出来的**；照片只负责当外壳（面板底框）
    -- （⚠️ 颜色传 RGBA table 并走 SetStyle：直接写 props 不走归一化，hex 会渲染成黑条）
    refs.warBarBar:SetStyle({
        fillGradient = (myScore >= 0)
            and { direction = "to-right", from = { 40, 90, 170, 255 }, to = { 120, 210, 255, 255 } }
            or  { direction = "to-right", from = { 150, 40, 40, 255 }, to = { 255, 130, 110, 255 } },
    })

    -- 战损（累计阵亡，见 MilitarySystem 每天结算时累加到 war.aLoss/dLose）
    --   按"我方视角"取：我是 a 方就读 aLoss
    local isA = (war.aId == pid)
    local myLoss = (isA and war.aLoss or war.dLoss) or 0
    local enLoss = (isA and war.dLoss or war.aLoss) or 0
    refs.warBarLossL:SetText(string.format("%s 损失 %d", me.name or "我方", math.floor(myLoss)))
    refs.warBarLossR:SetText(string.format("%s 损失 %d", enemy.name or "敌方", math.floor(enLoss)))

    -- 标题：战争名 + 已进行时长（war.startedAt = year*12+month，宣战时记的）
    local durTxt = "—"
    if war.startedAt then
        local okTS, TimeSystem = pcall(require, "core.TimeSystem")
        if okTS and TimeSystem and TimeSystem.getTime then
            local ty, tm = TimeSystem.getTime()
            if type(ty) == "number" then
                local months = math.max(0, (ty * 12 + (tonumber(tm) or 1)) - war.startedAt)
                if months < 12 then
                    durTxt = tostring(months) .. " 个月"
                else
                    local yy = math.floor(months / 12)
                    local mm = months % 12
                    durTxt = (mm > 0) and (yy .. " 年 " .. mm .. " 个月") or (yy .. " 年")
                end
            end
        end
    end
    refs.warBarTitle:SetText(string.format("%s · %s 之战　｜　已进行 %s",
        tostring(me.name or "?"), tostring(enemy.name or "?"), durTxt))

    -- 国旗（每次刷新重挂：势力名/颜色可能变）
    -- 完整旗（带旗杆/旗穗）——2026-09-18 用户："旗子是个色块加一个字，外面得要个旗子的形制"。
    --   统一用我们已有的旗帜素材（Emblem），风格自然和全局一致
    refs.warBarFlagBoxL:ClearChildren()
    refs.warBarFlagBoxL:AddChild(Emblem.Make(me, "war", 58))
    refs.warBarFlagBoxR:ClearChildren()
    refs.warBarFlagBoxR:AddChild(Emblem.Make(enemy, "war", 58))
end

--- 把本模块的方法挂回 GameUI 主表
---@param gameUI table GameUI 主表
function M.install(gameUI)
    gameUI.toggleMapModePanel   = toggleMapModePanel
    gameUI.refreshBattleCards   = refreshBattleCards
    gameUI.refreshMapModePanel  = refreshMapModePanel
    gameUI.forceRefreshWarList  = forceRefreshWarList
    gameUI.refreshWarList       = refreshWarList
    gameUI.openWarBar           = openWarBar
    gameUI.openWarParties       = openWarParties
    gameUI.closeWarBar          = closeWarBar
    gameUI.isWarBarVisible      = isWarBarVisible
    gameUI.refreshWarBar        = refreshWarBar
end

--- 创建地图模式面板 / 战斗卡片 / 战争列表 / 战争面板
---@param ctx table 共享上下文
---@return table { mapModePanel, battleCards, warList, warBar }
function M.create(ctx)
    UI          = ctx.UI
    GameUI      = ctx.GameUI
    refs        = ctx.refs
    COLORS      = ctx.COLORS
    SmallButton = ctx.SmallButton
    Emblem      = ctx.Emblem
    WarSystem   = ctx.WarSystem
    return {
        mapModePanel = createMapModePanel(ctx.callbacks),
        battleCards  = createBattleCards(ctx.callbacks),
        warList      = createWarList(),
        warBar       = createWarBar(),
    }
end

return M

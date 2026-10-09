-- ============================================================================
-- TechPanel.lua — 科技面板（2026-09-26 从 GameUI.lua 拆出，550 行）
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：导出 create(ctx) / install(GameUI)，
-- ctx 注入 UI/GameUI/refs/COLORS，**不 require GameUI**（避免循环依赖）。
--
-- 本模块内的代码基本原样搬自 GameUI.lua，只在头部声明了同名 upvalue
-- （UI/GameUI/refs/COLORS），所以内部一行都不用改。
-- ============================================================================

local M = {}

-- ── 模块级共享引用（install 时注入）──────────────────────────────
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

local function createTechNode(name, state)
    local bg, border, textColor, sub
    if state == "researched" then
        bg, border, textColor, sub = { 30, 85, 55, 230 }, { 80, 220, 110, 255 }, { 160, 255, 180, 255 }, "已研"
    elseif state == "researchable" then
        bg, border, textColor, sub = { 95, 80, 35, 230 }, { 255, 200, 50, 255 }, COLORS.gold, "可研"
    else
        bg, border, textColor, sub = { 38, 44, 56, 230 }, { 85, 95, 110, 255 }, { 130, 140, 155, 255 }, "🔒"
    end
    return UI.Panel {
        width = 92,
        height = 56,
        borderRadius = 8,
        borderWidth = 2,
        borderColor = border,
        backgroundColor = bg,
        justifyContent = "center",
        alignItems = "center",
        children = {
            UI.Label { text = name, fontSize = 14, fontColor = textColor, fontWeight = "bold" },
            UI.Label { text = sub, fontSize = 10, fontColor = textColor },
        },
    }
end

-- ============================================================
-- 科技面板（2026-09-16 重做：6 类分页 + 卡片 + 研究进度）
--   数据 data/Techs.lua（6 类 × 10 条）；机制 systems/TechSystem.lua
--   点卡片 = 开始研究（走 callbacks.onTechStart）；点 X / 点外面关闭
-- ============================================================

--- 切分类（分类按钮点击）
local function onTechCatClick(catId)
    refs.techCurCat = catId
    GameUI.refreshTechPanel(refs.gameState)
end

--- 效果摘要文案（"金+10% 粮+5%"）——卡片上显示
local TECH_KEY_LABELS = {
    goldIncome = "金", foodIncome = "粮", popGrowth = "人口", recruit = "征兵",
    militaryPower = "战力", defensePower = "防", diploImprove = "外交", stabilityDelta = "稳定",
}
local function techEffectText(def)
    local parts = {}
    for _, e in ipairs(def.effects or {}) do
        local nm = TECH_KEY_LABELS[e.key] or e.key
        if e.op == "flat" then
            parts[#parts + 1] = nm .. "+" .. tostring(e.value)
        else
            parts[#parts + 1] = nm .. "+" .. tostring(math.floor((e.value or 0) * 100 + 0.5)) .. "%"
        end
    end
    -- 兵种解锁提示（2026-09-19 兵种系统）：这条科技会解锁哪些兵种
    do
        local Units = require("data.Units")
        for _, u in ipairs(Units.all()) do
            if u.unlock == def.id then
                parts[#parts + 1] = "解锁·" .. u.name
            end
        end
    end
    return table.concat(parts, " ")
end

-- ============================================================================
-- 科技树"连接列"（2026-09-16 用户给参考图："连线要像这个样子"——直角折线）
--   做法：夹在"左右两列卡片"之间的一个窄条；Render 时从卡片引用**实时取坐标**，
--   画 水平→竖直→水平 的折线（父卡右缘中点 → 拐点 → 子卡左缘中点）。
--   它是纯绘制层（pointerEvents = none，不挡点击）。
-- ============================================================================
local Widget = require("urhox-libs/UI/Core/Widget")
local TechLinkColumn = Widget:Extend("TechLinkColumn")

function TechLinkColumn:Init(props)
    props = props or {}
    props.width = props.width or 56   -- 列间距（2026-09-16：44→56，"拉远点"）
    props.height = props.height or "100%"
    props.pointerEvents = "none"
    Widget.Init(self, props)
    ---@type any[]
    self.leftCards_ = {}
    ---@type any[]
    self.rightCards_ = {}
    ---@type table[]
    self.pairs_ = {}     -- { {leftIdx, rightIdx}, ... }
end

--- 设置连接关系
---@param left any[] 左列卡片（按列内顺序）
---@param right any[] 右列卡片
---@param pairs table[] { {leftIdx, rightIdx}, ... }
function TechLinkColumn:SetGraph(left, right, pairs)
    self.leftCards_ = left
    self.rightCards_ = right
    self.pairs_ = pairs
end

function TechLinkColumn:Render(nvg)
    local l = self:GetAbsoluteLayout()
    local function cyOf(card)
        if not card then return nil end
        local cl = card:GetAbsoluteLayout()
        return cl.y + cl.h / 2
    end
    local x0, x1 = l.x, l.x + l.w
    local mid = l.x + l.w * 0.5
    for _, pr in ipairs(self.pairs_) do
        local fy = cyOf(self.leftCards_[pr[1]])
        local ty = cyOf(self.rightCards_[pr[2]])
        if fy and ty then
            nvgBeginPath(nvg)
            nvgMoveTo(nvg, x0 - 10, fy)
            nvgLineTo(nvg, mid, fy)
            nvgLineTo(nvg, mid, ty)
            nvgLineTo(nvg, x1 + 10, ty)
            nvgStrokeColor(nvg, nvgRGBA(198, 174, 112, 215))
            nvgStrokeWidth(nvg, 2)
            nvgStroke(nvg)
        end
    end
end

--- 单张科技卡片
---@param def table 科技定义
---@param f table|nil 玩家势力
---@param topY number|nil 纵向槽位（父子居中式布局算好后传入，绝对定位）
local function makeTechCard(def, f, topY)
    local TechSystem = require("systems.TechSystem")
    local done = f and TechSystem.isDone(f, def.id)
    local pre = TechSystem.prereqOf(def)
    local locked = (pre and f and not TechSystem.isDone(f, pre.id)) and true or false
    local r = f and TechSystem.getResearch(f)
    local researching = (r and r.id == def.id) and true or false
    local status, statusColor
    if done then
        -- 已完成：金框金字 + "✔ 已成"（2026-09-16 用户："不应该给它一个特殊标识吗"）
        status, statusColor = "✔ 已成", { 120, 220, 130, 255 }
    elseif researching then
        -- 像 HOI4 国策那样：直接告诉"还要多久"（2026-09-16 用户要求）
        status = string.format("研究中 · 还需 %d 月", math.max(0, r.monthsLeft or 0))
        statusColor = { 130, 190, 255, 255 }
    elseif locked then
        status, statusColor = "需先研究：" .. tostring(pre.name), { 210, 150, 140, 240 }
    else
        status = string.format("%d 金 · %d 月", def.cost or 0, def.months or 0)
        statusColor = COLORS.textSecondary
    end
    -- 卡片底色：完成=绿 / 锁定=暗 / 普通=蓝灰
    local bg = { 50, 60, 80, 220 }
    local line = COLORS.border
    if done then
        bg = { 38, 58, 40, 225 }
        line = { 100, 180, 110, 220 }
    elseif locked then
        bg = { 34, 36, 42, 225 }
        line = { 80, 78, 74, 200 }
    end
    return UI.Button {
        width = 200,          -- 固定宽（横向树：列内节点竖排）
        -- 固定高（2026-09-19）：父子居中式布局要按统一高度算槽位（必须与布局的 CARD_H 一致）
        height = 76,
        position = "absolute",   -- 绝对定位：纵向位置由父子居中式布局算好（topY）
        top = topY or 0,
        left = 0,
        padding = 10,
        backgroundColor = bg,
        hoverBackgroundColor = locked and bg or { 72, 86, 112, 240 },
        pressedBackgroundColor = { 40, 48, 66, 240 },
        borderWidth = 1,
        borderColor = line,
        borderRadius = 8,
        onClick = function()
            if GameUI.onTechStart then GameUI.onTechStart(def.id) end
        end,
        children = {
            UI.Panel {
                flexDirection = "column",
                gap = 4,
                width = "100%",
                pointerEvents = "none",   -- 子元素不拦点击（整卡可点）
                children = {
                    UI.Label {
                        text = def.name or "?",
                        fontSize = 14,
                        fontColor = COLORS.gold,
                        fontWeight = "bold",
                    },
                    UI.Label {
                        text = techEffectText(def),
                        fontSize = 11,
                        fontColor = { 200, 210, 225, 235 },
                        whiteSpace = "normal",
                        maxLines = 2,
                    },
                    UI.Label {
                        text = status,
                        fontSize = 11,
                        fontColor = statusColor,
                        fontWeight = "bold",
                    },
                },
            },
        },
    }
end

--- 刷新科技面板（重建当前分类的卡片 + 分类按钮高亮 + 标题进度）
---@param gameState table|nil
local function refreshTechPanel(gameState)
    local Techs = require("data.Techs")
    local TechSystem = require("systems.TechSystem")
    if not refs.techCardHolder or not gameState then return end
    local f = gameState.getPlayerFaction and gameState.getPlayerFaction() or nil

    -- 标题：**只写系统名**（2026-09-16 用户："括号里的不要有，只要有科技二字"）
    if refs.techTitle then
        refs.techTitle:SetText(Techs.NAME)
    end
    -- 分类按钮高亮（选中 = 金色，跟模式面板同款）
    for cid, btn in pairs(refs.techCatButtons or {}) do
        if cid == refs.techCurCat then
            btn.props.backgroundColor = { 168, 124, 38, 240 }
            btn.props.textColor = { 255, 240, 196, 255 }
        else
            btn.props.backgroundColor = nil
            btn.props.textColor = nil
        end
    end
    -- 横向"科技树"（2026-09-19 重做：**父子居中式**，照《历史时代3》）：
    --   列 = 层级不变；列内纵向位置不再靠 Yoga 各自居中（那样父卡与子卡群错位，
    --   连线被迫"上上下下绕"），改为后序遍历算槽位：叶子依次堆叠，**父卡落在子卡群垂直中点**。
    refs.techCardHolder:ClearChildren()
    local list = Techs.byCategory(refs.techCurCat)
    local cols, maxDepth, byId = {}, 0, {}
    for _, def in ipairs(list) do
        local d = TechSystem.depthOf(def)
        cols[d] = cols[d] or {}
        cols[d][#cols[d] + 1] = def
        byId[def.id] = def
        if d > maxDepth then maxDepth = d end
    end

    -- ① 父子索引（每个节点单父 → 整棵是森林）
    local childrenOf = {}
    for _, def in ipairs(list) do
        local pre = TechSystem.prereqOf(def)
        if pre and byId[pre.id] then
            local t = childrenOf[pre.id]
            if not t then t = {}; childrenOf[pre.id] = t end
            t[#t + 1] = def.id
        end
    end

    -- ② 后序排位：叶子依次堆叠；父卡 y = 子卡群中点（返回子树占用的纵向范围）
    --   卡片/间距都要小（2026-09-19 实测）：叶子数 × 行高 就是整棵树的高度，
    --   行高给大了（100+24）支线一多就撑成"天女散花"，一屏装不下
    local CARD_H, CARD_GAPY = 76, 8
    local nodeY, cursor = {}, 0
    local placing = {}
    local function place(id)
        if nodeY[id] then return nodeY[id], nodeY[id] + CARD_H end
        if placing[id] then return 0, 0 end          -- 环保护（正常数据无环）
        placing[id] = true
        local kids = childrenOf[id] or {}
        if #kids == 0 then
            nodeY[id] = cursor
            cursor = cursor + CARD_H + CARD_GAPY
            placing[id] = nil
            return nodeY[id], nodeY[id] + CARD_H
        end
        local minY, maxY
        for _, k in ipairs(kids) do
            local a, b = place(k)
            if not minY or a < minY then minY = a end
            if not maxY or b > maxY then maxY = b end
        end
        nodeY[id] = (minY + maxY) / 2 - CARD_H / 2
        placing[id] = nil
        return minY, maxY
    end
    for _, def in ipairs(list) do
        local pre = TechSystem.prereqOf(def)
        if not (pre and byId[pre.id]) then place(def.id) end    -- 从各个根出发
    end
    local totalH = math.max(cursor, CARD_H)

    -- 内容高度 = 真实树高（2026-09-19 用户："有些被挡住，需要可以上下滑"）：
    --   之前 holder 是 height="100%"（撑满视口）→ 内容再高也被压扁，纵向没得滚、下面几张卡被裁
    refs.techCardHolder:SetStyle({ height = totalH + 24 })

    -- ③ 逐列构建（列容器同高；卡片绝对定位到算好的槽位）
    --   列间仍夹"连接列"：父卡→子卡画直角折线（实测坐标，位置一对线自然就顺）
    local prevCards, prevDefs = nil, nil
    for d = 0, maxDepth do
        local defs = cols[d] or {}
        local cards, colKids = {}, {}
        for _, def in ipairs(defs) do
            local card = makeTechCard(def, f, nodeY[def.id] or 0)
            cards[#cards + 1] = card
            colKids[#colKids + 1] = card
        end
        ---@type Widget
        local col = UI.Panel {
            width = 200,
            height = totalH,
            children = colKids,
        }
        -- 连接列（夹在左列与本列之间；把"父→子"关系画成折线）
        if d > 0 and prevCards then
            local pairsList = {}
            for ci, def in ipairs(defs) do
                local pre = TechSystem.prereqOf(def)
                if pre then
                    for pi, pdef in ipairs(prevDefs) do
                        if pdef.id == pre.id then
                            pairsList[#pairsList + 1] = { pi, ci }
                            break
                        end
                    end
                end
            end
            if #pairsList > 0 then
                local linkCol = TechLinkColumn:new {}
                linkCol:SetGraph(prevCards, cards, pairsList)
                refs.techCardHolder:AddChild(linkCol)
            end
        end
        refs.techCardHolder:AddChild(col)
        prevCards = cards
        prevDefs = defs
    end
end

--- 科技面板（新实现：6 类分页 + 卡片 + 进度）
local function createTechPanel(callbacks)
    local Techs = require("data.Techs")
    refs.techCatButtons = {}
    refs.techCurCat = Techs.CATEGORIES[1].id

    -- 分类按钮行
    local catRow = UI.Panel { flexDirection = "row", gap = 8, children = {} }
    for _, cat in ipairs(Techs.CATEGORIES) do
        -- 只写文字：emoji 在本引擎字体里渲染成"⊠"方框（2026-09-16 实测）
        local btn = SmallButton(tostring(cat.label), function()
            GameUI.onTechCatClick(cat.id)
        end, { width = 86, height = 38, fontSize = 13 })
        refs.techCatButtons[cat.id] = btn
        catRow:AddChild(btn)
    end

    -- 标题 + 进度（左侧）；关闭（右侧）
    refs.techTitle = UI.Label {
        text = Techs.NAME, fontSize = 16, fontColor = COLORS.gold, fontWeight = "bold",
    }
    local closeBtn = SmallButton("X", function() GameUI.toggleTechPanel() end,
        { width = 30, height = 30, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    -- 卡片区（竖向滚动）
    -- 横向树：holder 是"行"（列 = 层级，从左到右）——高度撑满，列内垂直居中
    refs.techCardHolder = UI.Panel {
        flexDirection = "row",
        gap = 0,
        -- 交叉轴改**顶/左对齐**（2026-09-19）：原来 center 会让超宽内容两头各裁一半
        --   （用户截图里"畎亩法"只剩半个就是这么来的）
        alignItems = "flex-start",
        height = "100%",             -- 刷新时会被改写成真实树高（见 refreshTechPanel）
        padding = 12,
        children = {},
    }
    local scroll = UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        scrollX = true,              -- 四向可拖（2026-09-19 用户："四周那个方向滑动都行"）
        scrollY = true,
        showScrollbar = true,
        children = { refs.techCardHolder },
    }

    -- 面板体单独建：**整块从顶栏下方开始**（2026-09-19 用户："上面那个不要被挡住"）
    --   之前用 paddingTop 只让开了内容，面板**背景**仍然铺满全屏 → 顶栏还是被盖住
    refs.techPanelBody = UI.Panel {
        position = "absolute",
        left = 0, right = 0, bottom = 0,
        top = 132,                     -- 兜底值；打开时按顶栏实测高度校准（见 toggleTechPanel）
        paddingLeft = 10, paddingRight = 10, paddingBottom = 10,
        backgroundColor = COLORS.bgPanel,
        gap = 8,
        pointerEvents = "auto",
        onClick = function() end,      -- 拦点击（防冒泡关掉）
        children = {
            -- 标题 + 分类按钮**同一行**（2026-09-19 用户："不要分开，让他们在一行，省地方"）
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                width = "100%",
                gap = 10,
                children = {
                    refs.techTitle,
                    UI.ScrollView {
                        flexGrow = 1, flexBasis = 0, flexShrink = 1, height = require("ui.NavigationHUD").touchSize(48),
                        scrollX = true, scrollY = false, showScrollbar = false,
                        children = { catRow },
                    },
                    closeBtn,
                },
            },
            UI.Divider { color = COLORS.border, thickness = 1 },
            scroll,
        },
    }

    local panel = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        onClick = function() GameUI.toggleTechPanel() end,   -- 点外面关
        children = { refs.techPanelBody },
    }
    panel:Hide()
    refs.techPanel = panel
    return panel
end

--- 科技树面板（框架，2026-09-01）：【已退役 2026-09-16】
--- 横向大长页、左侧初始科技向右高阶、列间连线表示前置、点外部/X 关闭
local function createTechPanel_DEPRECATED()
    -- 演示数据（后续替换为真实科技系统）
    local eras = {
        { name = "初始", techs = { "青铜", "农耕" } },
        { name = "百工", techs = { "冶铁", "牛耕" } },
        { name = "军制", techs = { "车战", "礼乐" } },
        { name = "变革", techs = { "步卒", "井田" } },
        { name = "霸业", techs = { "铁骑", "法家" } },
    }

    -- 横向内容：时代列 + 列间连线
    ---@type Widget
    local contentRow = UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        padding = 16,
        children = {},
    }
    for ei, era in ipairs(eras) do
        ---@type Widget
        local col = UI.Panel {
            flexDirection = "column",
            alignItems = "center",
            gap = 10,
            children = {
                UI.Label {
                    text = era.name,
                    fontSize = 12,
                    fontColor = COLORS.gold,
                    fontWeight = "bold",
                },
            },
        }
        for ti, techName in ipairs(era.techs) do
            if ti > 1 then
                -- 列内节点间竖线（同阶依赖示意）
                ---@type Widget
                local vLine = UI.Divider {
                    orientation = "vertical",
                    color = { 150, 170, 200, 150 },
                    thickness = 2,
                    height = 16,
                }
                col:AddChild(vLine)
            end
            -- 框架演示状态：第1列=已研，第2列第1个=可研，其余=锁定
            local state = "locked"
            if ei == 1 then state = "researched" end
            if ei == 2 and ti == 1 then state = "researchable" end
            col:AddChild(createTechNode(techName, state))
        end
        contentRow:AddChild(col)
        if ei < #eras then
            -- 列间横线（前置连接：研究完本列解锁下一列）
            ---@type Widget
            local hLine = UI.Divider {
                orientation = "horizontal",
                color = { 150, 170, 200, 160 },
                thickness = 2,
                width = 44,
            }
            contentRow:AddChild(hLine)
        end
    end

    local closeBtn = SmallButton("X", function()
        GameUI.toggleTechPanel()
    end, { width = 30, height = 30, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    local panel = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        onClick = function()
            -- 点击遮罩外部自动关闭
            GameUI.toggleTechPanel()
        end,
        children = {
            -- 内容容器：拦截点击（避免冒泡触发遮罩关闭）
            UI.Panel {
                width = "92%",
                height = "76%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 12,
                gap = 10,
                pointerEvents = "auto",
                onClick = function() end,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            UI.Label {
                                text = "🔬 科技（左低阶 → 右高阶）",
                                fontSize = 16,
                                fontColor = COLORS.gold,
                                fontWeight = "bold",
                            },
                            closeBtn,
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        scrollX = true,
                        scrollY = false,
                        children = { contentRow },
                    },
                },
            },
        },
    }
    panel:Hide()
    refs.techPanel = panel
    return panel
end

--- 把面板方法挂回 GameUI 主表（原 GameUI.onTechCatClick / refreshTechPanel）
---@param gameUI table GameUI 主表
function M.install(gameUI)
    gameUI.onTechCatClick  = onTechCatClick
    gameUI.refreshTechPanel = refreshTechPanel
end

--- 创建科技面板
---@param ctx table 共享上下文
---@return Widget techPanel
function M.create(ctx)
    UI = ctx.UI
    GameUI = ctx.GameUI
    refs = ctx.refs
    COLORS = ctx.COLORS
    SmallButton = ctx.SmallButton
    return createTechPanel(ctx.callbacks)
end

return M

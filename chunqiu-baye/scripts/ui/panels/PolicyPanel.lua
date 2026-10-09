-- ============================================================================
-- PolicyPanel.lua — 政策/变法面板（2026-09-26 从 GameUI.lua 拆出）
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：导出 create(ctx) / install(GameUI)，
-- ctx 注入 UI/GameUI/refs/COLORS/SmallButton/PolicySystem，**不 require GameUI**。
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
local PolicySystem

--- 政策面板（2026-09-01）：
---   变法区：一次性重大改革（绿=已行 金=可实行 灰=资源不足）
---   卡槽区：3+1 卡槽，换卡消耗资源并进入 HoI4 式实施进度（进度条+剩余天数）
local function createPolicyPanel(callbacks)
    -- ============ 变法区（方案 C） ============
    refs.policyReformBtns = {}
    local reformList = UI.Panel { width = "100%", gap = 6, children = {} }
    for _, def in ipairs(PolicySystem.REFORMS) do
        -- 变法行右侧的"代价"文案（2026-09-16 用户："buff 加成和消耗我看不出来"）
        --   花费（金/名声）+ 副作用（如 稳定-1 持续 12 月）
        local costParts = {}
        if def.cost then
            if def.cost.gold then costParts[#costParts + 1] = def.cost.gold .. "金" end
            if def.cost.prestige then costParts[#costParts + 1] = def.cost.prestige .. "名声" end
        end
        if def.penalty and def.penalty.stability then
            costParts[#costParts + 1] = "稳定" .. tostring(def.penalty.stability)
                .. "×" .. tostring(def.penalty.months or 0) .. "月"
        end
        local costStr = table.concat(costParts, "　")
        local btn = UI.Button {
            id = "policyReform_" .. def.id,   -- 2026-09-16：给离屏"模拟点击"用
            width = "100%",
            height = 44,
            paddingHorizontal = 10,
            borderRadius = 6,
            backgroundColor = { 40, 50, 70, 220 },
            flexDirection = "row",
            alignItems = "center",
            gap = 8,
            onClick = function()
                if callbacks.onReformActivate then callbacks.onReformActivate(def.id) end
            end,
            children = {
                UI.Label { text = def.id, fontSize = 14, fontColor = COLORS.textPrimary, fontWeight = "bold" },
                UI.Label {
                    text = def.desc,
                    fontSize = 11,
                    fontColor = { 120, 220, 140, 255 },   -- 效果：绿
                    flexGrow = 1,
                },
                UI.Label {
                    text = costStr,
                    fontSize = 10,
                    fontColor = { 235, 150, 100, 255 },   -- 代价：橙
                },
            },
        }
        refs.policyReformBtns[def.id] = btn
        reformList:AddChild(btn)
    end
    -- "无"占位（2026-09-16 用户："变法如果还没有，就写个无"）——
    --   变法要等"臣上书主张变法"的事件解锁后才上这个列表
    refs.policyReformEmpty = UI.Label {
        text = "无",   -- 2026-09-16 用户："变法改革如果没有的话就写个无"
        fontSize = 13,
        fontColor = COLORS.textSecondary,
    }
    reformList:AddChild(refs.policyReformEmpty)

    -- ============ 政策区（**光谱轴**：税率 / 经济 / 内政 / 军事） ============
    --   2026-09-17 用户："它有中间，然后偏左偏右……而不是各个方面都有，这不太符合政策"
    --   → 一条轴 = 一排按钮（左倾→中道→右倾），点一下就把这条轴挪到那一档；
    --     轴下方实时显示**当前立场**的得失（绿=得 红=失），换档立刻变
    refs.policyAxisBtns = {}     -- [axisId][optionId] = btn
    refs.policyAxisEffect = {}   -- [axisId] = Panel（装当前立场的得失标签）
    local axisList = UI.Panel { width = "100%", gap = 14, children = {} }
    for _, axis in ipairs(PolicySystem.AXES) do
        refs.policyAxisBtns[axis.id] = {}
        ---@type Widget
        local optRow = UI.Panel {
            flexDirection = "row",
            gap = 6,
            flexGrow = 1,
            flexBasis = 0,
            children = {},
        }
        for _, opt in ipairs(axis.options) do
            local btn = UI.Button {
                id = "policyAxis_" .. axis.id .. "_" .. opt.id,   -- 离屏"模拟点击"用
                text = opt.id,                                    -- 立场名（低税/平准/尚武…）
                -- ⚠️ flexGrow 必须配 flexBasis=0：否则按钮宽度按文字长度算 → 大小不一
                flexGrow = 1,
                flexBasis = 0,
                height = 38,
                borderRadius = 6,
                backgroundColor = { 40, 50, 70, 220 },
                borderWidth = 1,
                borderColor = { 60, 70, 90, 200 },
                fontSize = 12,
                textColor = COLORS.textPrimary,
                onClick = function()
                    if callbacks.onPolicyAxis then callbacks.onPolicyAxis(axis.id, opt.id) end
                end,
            }
            refs.policyAxisBtns[axis.id][opt.id] = btn
            optRow:AddChild(btn)
        end

        ---@type Widget
        local effectRow = UI.Panel {
            flexDirection = "row",
            gap = 10,
            width = "100%",
            flexWrap = "wrap",
            children = {},
        }
        refs.policyAxisEffect[axis.id] = effectRow

        ---@type Widget
        local axisBlock = UI.Panel {
            width = "100%",
            gap = 4,
            children = {
                UI.Panel {
                    flexDirection = "row",
                    alignItems = "center",
                    gap = 8,
                    width = "100%",
                    children = {
                        UI.Label {
                            text = axis.name,
                            fontSize = 13,
                            fontColor = COLORS.gold,
                            fontWeight = "bold",
                            width = 44,   -- 定宽 → 各轴按钮左边缘对齐
                        },
                        optRow,
                    },
                },
                -- 效果行左边留出和标题同宽的缩进，看着属于这条轴
                UI.Panel {
                    flexDirection = "row",
                    width = "100%",
                    paddingLeft = 52,
                    children = { effectRow },
                },
            },
        }
        axisList:AddChild(axisBlock)
    end

    local closeBtn = SmallButton("X", function()
        GameUI.togglePolicyPanel()
    end, { width = 30, height = 30, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    -- 稳定度（2026-09-16 从国家面板挪来）：变法/政策的副作用都打这个值，
    --   放在这里才能"一边抉择一边看到代价"
    refs.policyStability = UI.Label {
        text = "0%",
        fontSize = 13,
        fontColor = COLORS.stability,
        fontWeight = "bold",
    }
    refs.policyStabilityBar = UI.ProgressBar {
        value = 0, max = 1, height = 8,   -- 值域 0~1（和省份治安条一致），调用处传 stab/100
        flexGrow = 1, flexBasis = 0,
        borderRadius = 4,
        backgroundColor = { 40, 45, 60, 200 },
        fillColor = COLORS.stabilityFill,
        showLabel = false,
    }
    ---@type Widget
    local stabilityRow = UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        gap = 8,
        width = "100%",
        children = {
            UI.Label {
                text = "稳定度",
                fontSize = 12,
                fontColor = COLORS.textSecondary,
            },
            refs.policyStability,
            refs.policyStabilityBar,
        },
    }

    local panel = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        onClick = function()
            GameUI.togglePolicyPanel()
        end,
        children = {
            UI.Panel {
                width = "92%",
                height = "80%",
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
                                text = "📜 政策",   -- 2026-09-16 用户："为什么叫它国策"
                                fontSize = 16,
                                fontColor = COLORS.gold,
                                fontWeight = "bold",
                            },
                            closeBtn,
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    stabilityRow,
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        children = {
                            UI.Panel {
                                width = "100%",
                                gap = 10,
                                children = {
                                    UI.Label {
                                        text = "◆ 变法改革（一次性）",
                                        fontSize = 13,
                                        fontColor = COLORS.gold,
                                        fontWeight = "bold",
                                    },
                                    reformList,
                                    UI.Divider { color = COLORS.border, thickness = 1 },
                                    UI.Label {
                                        text = "◆ 政策（每条轴选一个立场）",
                                        fontSize = 13,
                                        fontColor = COLORS.gold,
                                        fontWeight = "bold",
                                    },
                                    axisList,
                                },
                            },
                        },
                    },
                },
            },
        },
    }
    panel:Hide()
    refs.policyPanel = panel
    return panel
end

--- 刷新政策面板（变法显隐 / 变法状态 / 卡槽高亮 / 实施进度）
---   2026-09-16：变法由事件解锁，未解锁（unknown）的**不显示**；一条都没有时显示"无"
---@param gameState table
local function refreshPolicyPanel(gameState)
    if not refs.policyPanel or not gameState then return end
    local pid = gameState.playerFactionId
    local f = pid and gameState.factions[pid]
    if not f then return end

    -- 状态签名：本函数每帧被调，只有"可见状态真变了"才写 UI 属性（避免每帧重排）
    local parts = {}
    for _, def in ipairs(PolicySystem.REFORMS) do
        parts[#parts + 1] = PolicySystem.getReformState(f, def.id)
    end
    for _, axis in ipairs(PolicySystem.AXES) do
        parts[#parts + 1] = axis.id .. "=" .. tostring(PolicySystem.getAxisIndex(f, axis.id))
    end
    parts[#parts + 1] = tostring(math.floor(f.stability or 0))   -- 稳定度（面板顶部）
    local sig = table.concat(parts, ",")
    if refs.policySig_ == sig then return end
    refs.policySig_ = sig

    -- 稳定度（2026-09-16 从国家面板挪来）
    local stab = math.floor(f.stability or 0)
    if refs.policyStability then refs.policyStability.text = stab .. "%" end
    if refs.policyStabilityBar then refs.policyStabilityBar:SetValue(stab / 100) end

    -- 变法区：未解锁 → 隐藏；全隐藏 → 显示"无"
    local anyReform = false
    for reformId, btn in pairs(refs.policyReformBtns) do
        local state = PolicySystem.getReformState(f, reformId)
        if state == "unknown" then
            btn:Hide()
        else
            btn:Show()
            anyReform = true
        end
        if state == "done" then
            btn.props.backgroundColor = { 30, 85, 55, 230 }
            btn.props.borderWidth = 1
            btn.props.borderColor = { 80, 220, 110, 255 }
        elseif state == "active" then
            btn.props.backgroundColor = { 95, 80, 35, 230 }
            btn.props.borderWidth = 1
            btn.props.borderColor = { 255, 200, 50, 255 }
        else
            btn.props.backgroundColor = { 40, 45, 55, 220 }
            btn.props.borderWidth = 1
            btn.props.borderColor = { 80, 90, 105, 255 }
        end
    end
    if refs.policyReformEmpty then
        if anyReform then refs.policyReformEmpty:Hide() else refs.policyReformEmpty:Show() end
    end

    -- 政策轴：选中的档位金色高亮；轴下方重建"当前立场的得失"（绿=得 红=失）
    for _, axis in ipairs(PolicySystem.AXES) do
        local idx = PolicySystem.getAxisIndex(f, axis.id)
        local btnMap = refs.policyAxisBtns[axis.id] or {}
        for oi, opt in ipairs(axis.options) do
            local btn = btnMap[opt.id]
            if btn then
                if oi == idx then
                    -- 当前立场：金底 + 金边
                    btn.props.backgroundColor = { 95, 80, 35, 235 }
                    btn.props.borderWidth = 2
                    btn.props.borderColor = { 255, 200, 50, 255 }
                    btn.props.textColor = { 255, 235, 180, 255 }
                else
                    -- 未选中：偏左 / 中道 / 偏右 用**冷—中—暖**底色区分，一眼看出光谱方向
                    local lean = PolicySystem.leanOf(axis, oi)
                    if lean == "left" then
                        btn.props.backgroundColor = { 38, 52, 72, 220 }
                    elseif lean == "center" then
                        btn.props.backgroundColor = { 44, 48, 58, 220 }
                    else
                        btn.props.backgroundColor = { 62, 46, 44, 220 }
                    end
                    btn.props.borderWidth = 1
                    btn.props.borderColor = { 60, 70, 90, 200 }
                    btn.props.textColor = COLORS.textPrimary
                end
            end
        end

        local effRow = refs.policyAxisEffect[axis.id]
        local opt = axis.options[idx]
        if effRow and opt then
            effRow:ClearChildren()
            local items = PolicySystem.axisOptionText(opt)
            if #items == 0 then
                effRow:AddChild(UI.Label {
                    text = "无增减", fontSize = 10, fontColor = COLORS.textSecondary,
                })
            else
                for _, it in ipairs(items) do
                    effRow:AddChild(UI.Label {
                        text = it.text,
                        fontSize = 10,
                        fontColor = it.good and { 120, 220, 140, 255 } or { 230, 120, 110, 255 },
                    })
                end
            end
        end
    end
end

--- 把本模块的方法挂回 GameUI 主表
---@param gameUI table GameUI 主表
function M.install(gameUI)
    gameUI.refreshPolicyPanel = refreshPolicyPanel
end

--- 创建政策面板
---@param ctx table 共享上下文
---@return Widget policyPanel
function M.create(ctx)
    UI           = ctx.UI
    GameUI       = ctx.GameUI
    refs         = ctx.refs
    COLORS       = ctx.COLORS
    SmallButton  = ctx.SmallButton
    PolicySystem = ctx.PolicySystem
    return createPolicyPanel(ctx.callbacks)
end

return M

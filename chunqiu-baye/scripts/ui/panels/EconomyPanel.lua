-- ============================================================================
-- EconomyPanel.lua — 收支明细面板（2026-09-26 从 GameUI.lua 拆出）
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：导出 create(ctx) / install(GameUI)，
-- ctx 注入 UI/GameUI/refs/COLORS/SmallButton/EconomySystem，**不 require GameUI**。
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
local EconomySystem

-- ============================================================
-- 3.57) 收支明细面板（2026-09-25）
--   用户："我想写在这里，这样我可以看我现在有多少，然后哪一个会提升、哪一个会下降"
--   照 EU4 的收支面板口径 —— **按来源列，不按省列**（省份一多就爆屏；
--   玩家想知道的是"钱从哪来、花到哪去"，不是"每个省各出多少"）。
-- ============================================================
local function toggleEconomyPanel()
    if not refs.economyPanel then return end
    if refs.economyPanel:IsVisible() then
        refs.economyPanel:Hide()
    else
        GameUI.refreshEconomyPanel(refs.gameState)
        refs.economyPanel:Show()
    end
end

--- 生成一行"来源 + 金 + 粮"（正绿负红，照收支面板惯例）
---@param label string
---@param gold number
---@param food number
---@return Widget
local function econRow(label, gold, food)
    local function cell(v, suffix)
        local txt, color
        if math.abs(v) < 0.5 then
            txt, color = "—", COLORS.textSecondary
        elseif v > 0 then
            txt, color = string.format("+%d%s", math.floor(v + 0.5), suffix), { 120, 220, 140, 255 }
        else
            txt, color = string.format("%d%s", math.floor(v - 0.5), suffix), { 230, 120, 110, 255 }
        end
        return UI.Label { text = txt, fontSize = 12, fontColor = color, textAlign = "right", width = 78 }
    end
    return UI.Panel {
        flexDirection = "row", alignItems = "center", width = "100%",
        paddingHorizontal = 8, paddingVertical = 4,
        backgroundColor = { 30, 36, 50, 200 }, borderRadius = 5,
        children = {
            UI.Label { text = label, fontSize = 12, fontColor = COLORS.textPrimary, flexGrow = 1, flexShrink = 1 },
            cell(gold, ""),
            cell(food, ""),
        },
    }
end

local function createEconomyPanel()
    refs.economyList = UI.Panel { width = "100%", flexDirection = "column", gap = 3 }

    local closeBtn = UI.Button {
        text = "✕", width = 40, height = 40, fontSize = 18, flexShrink = 0,
        backgroundColor = { 40, 36, 34, 230 }, hoverBackgroundColor = { 78, 22, 26, 255 },
        borderRadius = 6, borderWidth = 1, borderColor = COLORS.border,
        onClick = function() GameUI.toggleEconomyPanel() end,
    }

    refs.economyCloseBtn = closeBtn

    refs.economyPanel = UI.Panel {
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center", alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        onClick = function() GameUI.toggleEconomyPanel() end,
        children = {
            UI.Panel {
                width = 420, height = "78%",
                backgroundColor = COLORS.bgPanel, borderRadius = 8,
                borderWidth = 1, borderColor = COLORS.border,
                padding = 12, gap = 8,
                pointerEvents = "auto",
                onClick = function() end,
                children = {
                    UI.Panel {
                        flexDirection = "row", alignItems = "center",
                        justifyContent = "space-between", width = "100%",
                        children = {
                            UI.Label { text = "每月收支", fontSize = 16, fontColor = COLORS.gold, fontWeight = "bold" },
                            closeBtn,
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    -- 表头（金 / 粮两列）
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", width = "100%",
                        paddingHorizontal = 8,
                        children = {
                            UI.Label { text = "来源", fontSize = 11, fontColor = COLORS.textSecondary, flexGrow = 1 },
                            UI.Label { text = "金", fontSize = 11, fontColor = COLORS.gold, textAlign = "right", width = 78 },
                            UI.Label { text = "粮", fontSize = 11, fontColor = COLORS.food, textAlign = "right", width = 78 },
                        },
                    },
                    UI.ScrollView {
                        width = "100%", flexGrow = 1, flexBasis = 0,
                        children = { refs.economyList },
                    },
                },
            },
        },
    }
    refs.economyPanel:Hide()
    return refs.economyPanel
end

--- 刷新收支面板：重建明细行（数据来自 EconomySystem.getBreakdown）
---@param gameState table|nil
local function refreshEconomyPanel(gameState)
    if not refs.economyPanel or not refs.economyList then return end
    gameState = gameState or refs.gameState
    if not gameState or not gameState.playerFactionId then return end

    local EconomySystem = require("systems.EconomySystem")
    local bd = EconomySystem.getBreakdown(gameState, gameState.playerFactionId)

    refs.economyList:ClearChildren()

    refs.economyList:AddChild(UI.Label {
        text = "◆ 收入", fontSize = 13, fontColor = COLORS.gold, fontWeight = "bold",
    })
    for _, it in ipairs(bd.incomeItems) do
        refs.economyList:AddChild(econRow(it.label, it.gold or 0, it.food or 0))
    end

    refs.economyList:AddChild(UI.Label {
        text = "◆ 支出", fontSize = 13, fontColor = { 230, 150, 120, 255 }, fontWeight = "bold",
    })
    for _, it in ipairs(bd.expenseItems) do
        refs.economyList:AddChild(econRow(it.label, -(it.gold or 0), -(it.food or 0)))
    end

    -- 净额（正绿负红，与上面同色口径）
    refs.economyList:AddChild(UI.Divider { color = COLORS.border, thickness = 1 })
    refs.economyList:AddChild(econRow("每月净额", bd.netGold, bd.netFood))
end

--- 把本模块的方法挂回 GameUI 主表
---@param gameUI table GameUI 主表
function M.install(gameUI)
    gameUI.toggleEconomyPanel  = toggleEconomyPanel
    gameUI.refreshEconomyPanel = refreshEconomyPanel
end

--- 创建收支明细面板
---@param ctx table 共享上下文
---@return Widget economyPanel
function M.create(ctx)
    UI            = ctx.UI
    GameUI        = ctx.GameUI
    refs          = ctx.refs
    COLORS        = ctx.COLORS
    SmallButton   = ctx.SmallButton
    EconomySystem = ctx.EconomySystem
    return createEconomyPanel()
end

return M

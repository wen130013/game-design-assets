-- ============================================================================
-- LogPanel.lua — 日志面板（2026-09-26 从 GameUI.lua 拆出）
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：导出 create(ctx) / install(GameUI)，
-- ctx 注入 UI/GameUI/refs/COLORS/SmallButton，**不 require GameUI**。
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

-- ============================================================
-- 5) Log Panel（日志）
-- ============================================================
local function showLog(gameState)
    if not refs.logOverlay then return end
    refs.logList:ClearChildren()
    local msgs = gameState.messages or {}
    for i = #msgs, 1, -1 do
        local m = msgs[i]
        local color = COLORS.textSecondary
        if m.type == "war" or m.type == "warning" then
            color = COLORS.relEnemy
        elseif m.type == "system" then
            color = COLORS.gold
        elseif m.type == "military" then
            color = COLORS.army
        end
        refs.logList:AddChild(UI.Label {
            text = m.text or "",
            fontSize = 11,
            fontColor = color,
            whiteSpace = "normal",
            maxLines = 3,
        })
    end
    refs.logOverlay:Show()
end

local function hideLog()
    if refs.logOverlay then refs.logOverlay:Hide() end
end

local function toggleLog()
    if refs.logOverlay and refs.logOverlay:IsVisible() then
        GameUI.hideLog()
    else
        GameUI.showLog(refs.gameState)
    end
end

local function createLogPanel()
    refs.logList = UI.Panel { width = "100%", gap = 4 }

    local closeBtn = SmallButton("X", function()
        GameUI.hideLog()
    end, { width = 28, height = 28, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    refs.logOverlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 340,
                height = "70%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 14,
                gap = 10,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            UI.Label {
                                text = "📜 大事记",
                                fontSize = 18,
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
                        children = { refs.logList },
                    },
                },
            },
        },
    }
    refs.logOverlay:Hide()
    return refs.logOverlay
end

--- 把本模块的方法挂回 GameUI 主表
---@param gameUI table GameUI 主表
function M.install(gameUI)
    gameUI.showLog   = showLog
    gameUI.hideLog   = hideLog
    gameUI.toggleLog = toggleLog
end

--- 创建日志面板
---@param ctx table 共享上下文
---@return Widget logOverlay
function M.create(ctx)
    UI          = ctx.UI
    GameUI      = ctx.GameUI
    refs        = ctx.refs
    COLORS      = ctx.COLORS
    SmallButton = ctx.SmallButton
    return createLogPanel()
end

return M

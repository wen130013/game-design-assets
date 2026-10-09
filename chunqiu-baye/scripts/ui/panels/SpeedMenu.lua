-- ============================================================================
-- SpeedMenu.lua — 时间流速选择弹窗（2026-09-26 从 GameUI.lua 拆出）
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：导出 create(ctx)，
-- ctx 注入 UI/GameUI/refs/COLORS/callbacks，**不 require GameUI**（避免循环依赖）。
-- ============================================================================

local M = {}

function M.create(ctx)
    local UI       = ctx.UI
    local GameUI   = ctx.GameUI
    local refs     = ctx.refs
    local COLORS   = ctx.COLORS
    local callbacks = ctx.callbacks or {}

    -- 7 档（2026-09-19 用户："不如多弄几个档"）—— 说明文字写"现实几秒 = 游戏几天"更直观
    local SPEED_INFO = {
        { label = "极慢", desc = "4 秒 1 天" },
        { label = "慢",   desc = "2 秒 1 天" },
        { label = "常",   desc = "1 秒 1 天" },
        { label = "快",   desc = "1 秒 2 天" },
        { label = "很快", desc = "1 秒 5 天" },
        { label = "极快", desc = "1 秒 10 天" },
        { label = "飞速", desc = "1 秒 20 天" },
    }
    refs.speedMenuButtons = {}
    local list = UI.Panel { width = "100%", gap = 6 }
    for i, info in ipairs(SPEED_INFO) do
        local btn = UI.Button {
            height = 46,                 -- 7 档后加高一点，点着不挤
            fontSize = 15,
            text = info.label .. "　" .. info.desc,
            textColor = COLORS.textPrimary,
            backgroundColor = { 40, 50, 70, 220 },
            hoverBackgroundColor = { 60, 75, 100, 240 },
            pressedBackgroundColor = { 50, 60, 80, 240 },
            borderRadius = 6,
            onClick = function()
                if callbacks.onSetSpeed then callbacks.onSetSpeed(i) end
                GameUI.toggleSpeedMenu()
            end,
        }
        refs.speedMenuButtons[i] = btn
        list:AddChild(btn)
    end

    refs.speedMenu = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        -- 点框外 = 保持当前速度、直接关闭（2026-09-19 用户口径，和别的弹窗一致）
        onClick = function()
            GameUI.toggleSpeedMenu()
        end,
        children = {
            UI.Panel {
                id = "speedPanelBox", width = "96%", maxWidth = 600, height = "96%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 16,
                gap = 12,
                pointerEvents = "auto",
                onClick = function() end,   -- 拦点击：点面板本体不关
                children = {
                    UI.Panel {
                        width = "100%", flexDirection = "row", alignItems = "center", justifyContent = "space-between",
                        children = {
                            UI.Label { text = "时间流速", fontSize = 16, fontColor = COLORS.gold, fontWeight = "bold" },
                            ctx.SmallButton("X", function() GameUI.toggleSpeedMenu() end, { id = "speedCloseBtn" }),
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0, scrollY = true, children = { list } },
                },
            },
        },
    }
    refs.speedMenu:Hide()
    return refs.speedMenu
end
return M

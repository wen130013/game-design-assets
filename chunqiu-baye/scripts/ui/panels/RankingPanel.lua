-- ============================================================================
-- RankingPanel.lua — 天下国力榜（2026-09-26 从 GameUI.lua 拆出）
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：面板导出 create(ctx)，
-- ctx 由 GameUI 注入 UI/GameUI/refs/COLORS/SmallButton，**面板不 require GameUI**
-- （否则与 GameUI 形成循环依赖 → Lua 拿到半成品模块 → 运行时 nil）。
-- ============================================================================

local M = {}

--- 创建「天下国力榜」弹窗
---@param ctx table 共享上下文
---@return Widget rankOverlay
function M.create(ctx)
    local UI         = ctx.UI
    local GameUI     = ctx.GameUI
    local refs       = ctx.refs
    local COLORS     = ctx.COLORS
    local SmallButton = ctx.SmallButton

    refs.rankDim = "territory"
    refs.rankList = UI.Panel { width = "100%", gap = 2 }

    local dimButtons = {
        { label = "领土", dim = "territory" },
        { label = "经济", dim = "economy" },
        { label = "军力", dim = "military" },
        { label = "名声", dim = "prestige" },
    }
    local dimRow = UI.Panel {
        flexDirection = "row",
        gap = 6,
        children = {},
    }
    for _, d in ipairs(dimButtons) do
        dimRow:AddChild(SmallButton(d.label, function()
            refs.rankDim = d.dim
            GameUI.showRanking(refs.gameState)
        end, { height = 30, fontSize = 12, bg = { 55, 65, 90, 230 } }))
    end

    local closeBtn = SmallButton("X", function()
        GameUI.hideRanking()
    end, { width = 28, height = 28, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    refs.rankOverlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 320,
                maxHeight = "80%",
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
                                text = "📊 天下国力榜",
                                fontSize = 18,
                                fontColor = COLORS.gold,
                                fontWeight = "bold",
                            },
                            closeBtn,
                        },
                    },
                    dimRow,
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        maxHeight = 420,
                        children = { refs.rankList },
                    },
                },
            },
        },
    }
    refs.rankOverlay:Hide()
    return refs.rankOverlay
end

return M

-- ============================================================================
-- NoticePanel.lua — 通知详情弹窗（2026-09-26 从 GameUI.lua 拆出）
--
-- 【拆分模式说明 · 后续所有面板都照这个来】
--   GameUI.lua 原本 6700 行，所有面板挤在一起。拆分的核心约束是：
--   所有面板共享 `refs` 表 / `COLORS` 常量 / `SmallButton` 工具，
--   且面板回调里直接调 `GameUI.xxx`。
--
--   如果面板文件各自 `require("ui.GameUI")` → **循环依赖**
--   （GameUI require 面板，面板 require GameUI），Lua 拿到半成品模块 → 运行时 nil。
--
--   所以统一用**依赖注入**：面板导出 `M.create(ctx)`，
--   ctx 由 GameUI 在初始化时组装传入，面板**不 require GameUI**。
--
--   ctx 里有什么（按需取用）：
--     ctx.UI            —— urhox-libs/UI 模块
--     ctx.GameUI        —— GameUI 主表（调 GameUI.hideXxx / refreshXxx 等）
--     ctx.refs          —— 共享控件引用表（本面板的控件挂到这里）
--     ctx.COLORS        —— 颜色常量
--     ctx.SmallButton   —— 小按钮工厂
--     ctx.gameState     —— 当前游戏状态（可能为 nil）
-- ============================================================================

local M = {}

--- 创建通知详情弹窗（含全屏遮罩）
---@param ctx table 共享上下文（见文件头说明）
---@return Widget 居中外壳（noticePanelBox）
function M.create(ctx)
    local UI       = ctx.UI
    local GameUI   = ctx.GameUI
    local refs     = ctx.refs
    local COLORS   = ctx.COLORS

    refs.noticeBody = UI.Label {
        text = "",
        fontSize = 16,          -- 2026-09-16 用户："太小了"→ 放大
        fontColor = COLORS.textPrimary,
        whiteSpace = "normal",
        maxLines = 10,
    }
    local closeBtn = ctx.SmallButton("X", function() GameUI.hideNoticeDialog() end, { id = "noticeCloseBtn" })
    refs.noticePanel = UI.Panel {
        -- 尺寸交给外层"居中容器"（noticePanelBox）；这里只定宽
        width = "84%",
        maxWidth = 560,         -- 2026-09-16 用户："太小了"→ 放大
        backgroundColor = { 13, 18, 28, 245 },
        borderRadius = 10,
        borderWidth = 1,
        borderColor = { 170, 130, 70, 235 },
        padding = 18,
        gap = 12,
        pointerEvents = "auto",
        children = {
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                width = "100%",
                children = {
                    UI.Label {
                        text = "通知",
                        fontSize = 20,
                        fontFamily = "gufeng",
                        fontWeight = "bold",
                        fontColor = { 255, 215, 120, 255 },
                    },
                    closeBtn,
                },
            },
            UI.Divider { color = { 120, 100, 66, 180 }, thickness = 1 },
            refs.noticeBody,
        },
    }
    refs.noticePanel:Hide()

    -- 全屏"居中容器"（2026-09-16 用户："它应该在最中间"）——弹窗水平垂直都居中
    refs.noticePanelBox = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        pointerEvents = "box-none",
        children = { refs.noticePanel },
    }
    refs.noticePanelBox:Hide()

    refs.noticeShade = UI.Button {
        text = "",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 0 },
        hoverBackgroundColor = { 0, 0, 0, 0 },
        pressedBackgroundColor = { 0, 0, 0, 0 },
        onClick = function() GameUI.hideNoticeDialog() end,
    }
    refs.noticeShade:Hide()
    return refs.noticePanelBox
end

return M

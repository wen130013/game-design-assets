-- ============================================================================
-- Panels.lua — 内置的"声明式面板"（"插座"第七块 · 2026-09-13）
--
-- 这个文件本身就是**模组写面板的样板**：全是数据，没有一行布局代码。
-- 渲染由 ui/UIBuilder.lua 干，动作走 UIPanelHost（游戏注册的动作 或 ui_action 钩子）。
--
-- 格式说明见 ui/UIDesc.lua 文件头。
-- ============================================================================

local UIDesc = require("ui.UIDesc")

-- ---------------------------------------------------------------------------
-- 国势总览：资源 + 自定义取值 + 进度 + 按钮 + 省份列表
--   —— 把"资源注册表 / 修正器管道 / 文化系统"的东西一次性摆出来
-- ---------------------------------------------------------------------------
UIDesc.register {
    id = "realm_overview",
    title = "国势总览",
    width = "76%",
    desc = "示例面板：资源绑定 + 自定义取值 + 省份列表 + 游戏动作",
    body = {
        type = "column", gap = 10, width = "100%",
        children = {
            -- 一行资源（绑定资源注册表，自动刷新）
            {
                type = "row", gap = 14, width = "100%", align = "center",
                children = {
                    { type = "resource", id = "gold" },
                    { type = "resource", id = "food" },
                    { type = "resource", id = "prestige" },
                },
            },
            { type = "divider" },

            -- 自定义取值（bind 是一段函数，想显示什么就显示什么）
            {
                type = "value", fontSize = 15, color = { 232, 226, 210, 255 },
                bind = function(gs, f)
                    if not f then return "（观战中）" end
                    local n = #(f.provinces or {})
                    local s = require("systems.CultureSystem").summary(gs, f)
                    return string.format("本文化：%s ｜ 省份：%d ｜ 异文化省份：%d ｜ 稳定度：%d",
                        tostring(s.ownerCulture), n, s.foreign, math.floor(f.stability or 0))
                end,
            },

            -- 稳定度进度条（-100 ~ 100）
            {
                type = "row", gap = 8, align = "center", width = "100%",
                children = {
                    { type = "label", text = "稳定度", fontSize = 13, color = { 158, 162, 178, 235 } },
                    {
                        type = "progress", max = 200, height = 12, flexGrow = 1,
                        color = { 226, 192, 120, 255 },
                        -- 进度条从 -100 起算：加 100 再显示
                        bind = function(gs, f)
                            return math.max(0, math.min(200, (f and f.stability or 0) + 100))
                        end,
                    },
                },
            },
            { type = "divider" },

            -- 游戏动作（这些动作由 main.lua 注册；模组可以用自己的 action 走钩子）
            { type = "label", text = "政令", fontSize = 14, color = { 226, 192, 120, 255 } },
            {
                type = "row", gap = 8, width = "100%",
                children = {
                    { type = "button", text = "加速", action = "speed_up", style = "secondary" },
                    { type = "button", text = "减速", action = "speed_down", style = "secondary" },
                    { type = "button", text = "暂停/继续", action = "toggle_pause", style = "primary" },
                    { type = "button", text = "政策", action = "open_policy", style = "secondary" },
                },
            },
            { type = "divider" },

            -- 列表：势力省份（点一下把镜头拉过去）
            { type = "label", text = "领土（点击定位）", fontSize = 14, color = { 226, 192, 120, 255 } },
            {
                type = "scroll", maxHeight = 150, flexGrow = 1,
                children = {
                    {
                        type = "list", columns = 3, gap = 6,
                        itemTemplate = { type = "button", height = 36, fontSize = 13, action = "focus_province" },
                        bind = function(gs, f)
                            local out = {}
                            for _, pid in ipairs(f and f.provinces or {}) do
                                local prov = gs.provinces[pid]
                                if prov then
                                    out[#out + 1] = { text = tostring(prov.name), arg = pid }
                                end
                            end
                            return out
                        end,
                    },
                },
            },
        },
    },
}

return true

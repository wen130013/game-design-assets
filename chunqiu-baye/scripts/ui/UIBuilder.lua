-- ============================================================================
-- UIBuilder.lua — 声明式 UI：**渲染器**（"插座"第七块 · 2026-09-13）
--
-- 把 UIDesc 里的"面板描述"翻译成 urhox-libs/UI 控件树，并给出**刷新函数**：
--   local widget, refresh = UIBuilder.build(desc, ctx)   -- ctx = { gameState, faction, onAction }
--   refresh()                                            -- 重算绑定值（资源/进度/自定义文本/列表）
--
-- 设计要点：
--   * 只读：不碰现有面板，纯新增能力
--   * 描述是数据（Lua 表），可以包含函数（bind/visibleIf）—— 因为模组数据本来就是 Lua
--   * 配色与游戏一致（深靛底 + 金棕描边 + 骨白字），新面板不会"跑风格"
--   * 刷新分两级：值绑定（resource/value/progress/toggle）走 refresh；
--     结构（visibleIf/list）只在**重建**时算，避免每帧重建控件树
-- ============================================================================

local UI = require("urhox-libs/UI")
local Resources = require("data.Resources")

local UIBuilder = {}

-- 与弹窗/模组面板同一套色（改这里 = 改所有声明式面板）
local PAL = {
    bg        = { 18, 22, 34, 250 },
    rowBg     = { 30, 36, 50, 220 },
    border    = { 120, 100, 66, 200 },
    gold      = { 226, 192, 120, 255 },
    goldInk   = { 34, 26, 14, 255 },
    text      = { 232, 226, 210, 255 },
    dim       = { 158, 162, 178, 235 },
    btnBg     = { 40, 48, 66, 220 },
    btnHover  = { 56, 66, 88, 240 },
    btnPress  = { 32, 38, 52, 240 },
    danger    = { 166, 42, 34, 255 },
    dangerHov = { 190, 58, 46, 255 },
}
UIBuilder.PALETTE = PAL

--- 面板壳（标题栏 + 内容区）的默认尺寸/配色，宿主也用
UIBuilder.SHELL = {
    bg = PAL.bg, border = PAL.border, radius = 12,
}

-- ---------------------------------------------------------------------------
-- 小工具
-- ---------------------------------------------------------------------------
--- 对齐名 → Yoga 值
local function align(v)
    if v == "start" then return "flex-start" end
    if v == "end" then return "flex-end" end
    if v == "between" then return "space-between" end
    if v == "around" then return "space-around" end
    return v
end

--- 安全取绑定值（bind 出错只跳过这一项，不炸面板）
local function safeCall(fn, ctx, fallback)
    if type(fn) ~= "function" then return fallback end
    local ok, v = pcall(fn, ctx.gameState, ctx.faction, ctx)
    if not ok then
        print("[UIBuilder] ⚠️ 绑定函数出错（已跳过）：" .. tostring(v))
        return fallback
    end
    return v
end

-- ---------------------------------------------------------------------------
-- 节点 → 控件
-- ---------------------------------------------------------------------------
---@param node table 节点描述
---@param ctx table { gameState, faction, onAction, panelId }
---@param refs fun()[] 收集"刷新函数"
---@return any|nil widget
local function buildNode(node, ctx, refs)
    if type(node) ~= "table" then return nil end
    -- 条件显示
    if node.visibleIf ~= nil then
        local vis = node.visibleIf
        if type(vis) == "function" then
            vis = safeCall(vis, ctx, true)
        end
        if not vis then return nil end
    end

    local t = node.type or "column"
    local common = {
        width = node.width, height = node.height,
        flexGrow = node.flexGrow, flexShrink = node.flexShrink,
        gap = node.gap,
        padding = node.padding,
        paddingHorizontal = node.paddingX, paddingVertical = node.paddingY,
        backgroundColor = node.bg,
        borderWidth = node.border, borderColor = node.borderColor,
        borderRadius = node.radius,
        id = node.id,
    }

    -- ---------- 容器 ----------
    if t == "column" or t == "row" then
        common.flexDirection = (t == "row") and "row" or "column"
        common.alignItems = align(node.align or "stretch")
        common.justifyContent = align(node.justify)
        local kids = {}
        for _, child in ipairs(node.children or {}) do
            local w = buildNode(child, ctx, refs)
            if w then kids[#kids + 1] = w end
        end
        common.children = kids
        return UI.Panel(common)
    end

    if t == "scroll" then
        common.flexDirection = "column"
        common.gap = node.gap or 6
        common.flexGrow = node.flexGrow or 1
        common.flexBasis = 0
        common.maxHeight = node.maxHeight
        local kids = {}
        for _, child in ipairs(node.children or {}) do
            local w = buildNode(child, ctx, refs)
            if w then kids[#kids + 1] = w end
        end
        -- ⚠️ children **直接给 ScrollView**，不要再套一层 Panel：
        --    套一层会让内容宽度算成 0 → 里面什么都不显示（模组面板验证过的写法）
        return UI.ScrollView {
            width = node.width or "100%",
            height = node.height,
            maxHeight = node.maxHeight,
            flexGrow = node.flexGrow or 1,
            flexBasis = 0,
            minHeight = node.minHeight or 80,
            children = kids,
        }
    end

    if t == "grid" then
        local cols = math.max(1, node.columns or 2)
        local cells = node.children or {}
        local rows = {}
        local cur
        for i, child in ipairs(cells) do
            if (i - 1) % cols == 0 then
                cur = { type = "row", gap = node.gap or 6, width = "100%",
                        children = {} }
                rows[#rows + 1] = cur
            end
            local w = buildNode(child, ctx, refs)
            if w then
                cur.children[#cur.children + 1] = UI.Panel {
                    flexGrow = 1, flexShrink = 1, children = { w },
                }
            end
        end
        local kids = {}
        for _, r in ipairs(rows) do kids[#kids + 1] = buildNode(r, ctx, refs) end
        common.flexDirection = common.flexDirection or "column"
        common.children = kids
        return UI.Panel(common)
    end

    -- ---------- 叶子 ----------
    if t == "label" then
        return UI.Label {
            text = tostring(node.text or ""),
            fontSize = node.fontSize or 14,
            fontFamily = node.fontFamily, fontWeight = node.fontWeight,
            fontColor = node.color or PAL.text,
            textAlign = node.textAlign,
            maxLines = node.maxLines, whiteSpace = node.whiteSpace,
            width = node.width, flexGrow = node.flexGrow,
        }
    end

    if t == "button" then
        local style = node.style or "secondary"
        local bg, hov, press, fg
        if style == "primary" then
            bg, hov, press, fg = PAL.gold, { 240, 210, 150, 255 }, { 198, 164, 96, 255 }, PAL.goldInk
        elseif style == "danger" then
            bg, hov, press, fg = PAL.danger, PAL.dangerHov, { 138, 34, 26, 255 }, { 250, 240, 222, 255 }
        elseif style == "ghost" then
            bg, hov, press, fg = { 0, 0, 0, 0 }, PAL.btnHover, PAL.btnPress, PAL.dim
        else
            bg, hov, press, fg = PAL.btnBg, PAL.btnHover, PAL.btnPress, PAL.text
        end
        local disabled = false
        if node.disabledIf ~= nil then
            disabled = safeCall(node.disabledIf, ctx, false) and true or false
        end
        local btn
        btn = UI.Button {
            text = tostring(node.text or ""),
            width = node.width, height = node.height or 44,
            fontSize = node.fontSize or 15,
            fontFamily = node.fontFamily or "gufeng", fontWeight = "bold",
            textColor = disabled and PAL.dim or fg,
            backgroundColor = disabled and { 30, 36, 50, 160 } or bg,
            hoverBackgroundColor = disabled and { 30, 36, 50, 160 } or hov,
            pressedBackgroundColor = disabled and { 30, 36, 50, 160 } or press,
            borderWidth = 1,
            borderColor = node.borderColor or PAL.border,
            borderRadius = node.radius or 8,
            id = node.id,
            onClick = function()
                if disabled then return end
                if ctx.onAction then
                    ctx.onAction(node.action, node.actionArg, node.id)
                end
            end,
        }
        return btn
    end

    if t == "divider" then
        return UI.Divider {
            color = node.color or { 120, 100, 66, 160 },
            thickness = node.thickness or 1,
            inset = node.inset, label = node.label,
            width = node.width,
        }
    end

    if t == "spacer" then
        return UI.Panel { flexGrow = node.flexGrow or 1, width = node.width, height = node.height }
    end

    if t == "resource" then
        local rid = node.id
        local def = Resources.getDef(rid)
        local color = node.color or (def and def.color) or PAL.text
        local name = node.label or (def and def.name) or rid
        local valueLabel
        valueLabel = UI.Label {
            text = "-", fontSize = node.fontSize or 14, fontWeight = "bold",
            fontColor = color,
        }
        local row = UI.Panel {
            flexDirection = "row", alignItems = "center", gap = 4, width = node.width,
            children = (node.showLabel == false) and { valueLabel } or {
                UI.Label { text = name, fontSize = node.fontSize or 14, fontColor = color, fontWeight = "bold" },
                valueLabel,
            },
        }
        refs[#refs + 1] = function()
            local v = Resources.get(ctx.faction, rid)
            valueLabel:SetText(v ~= nil and tostring(math.floor(v)) or "-")
        end
        return row
    end

    if t == "value" then
        local lbl = UI.Label {
            text = "", fontSize = node.fontSize or 14,
            fontColor = node.color or PAL.text,
            textAlign = node.textAlign, maxLines = node.maxLines,
            width = node.width, flexGrow = node.flexGrow,
        }
        refs[#refs + 1] = function()
            lbl:SetText(tostring(safeCall(node.bind, ctx, "") or ""))
        end
        return lbl
    end

    if t == "progress" then
        local bar = UI.ProgressBar {
            value = 0, max = node.max or 1,
            height = node.height or 12,
            fillColor = node.color or PAL.gold,
            width = node.width,                      -- 别写死 100%：会压住同一行的标签
            flexGrow = node.flexGrow or 1,
        }
        refs[#refs + 1] = function()
            bar:SetValue(tonumber(safeCall(node.bind, ctx, 0)) or 0)
        end
        return bar
    end

    if t == "toggle" then
        local tg = UI.Toggle {
            value = safeCall(node.bind, ctx, false) and true or false,
            label = node.label,
            onChange = function(_, value)
                if ctx.onAction then ctx.onAction(node.action, value, node.id) end
            end,
        }
        refs[#refs + 1] = function()
            local want = safeCall(node.bind, ctx, false) and true or false
            if tg.props.value ~= want then tg:SetValue(want) end
        end
        return tg
    end

    if t == "image" then
        return UI.Panel {
            width = node.width or 64, height = node.height or 64,
            backgroundImage = node.path,
            backgroundFit = node.fit or "contain",
            imageTint = node.tint,
        }
    end

    if t == "list" then
        local holder = UI.Panel {
            flexDirection = "column", gap = node.gap or 6, width = node.width or "100%",
        }
        local cols = math.max(1, node.columns or 1)
        local lastSig = nil
        local function rebuild()
            local items = safeCall(node.bind, ctx, nil)
            if type(items) ~= "table" then return end
            -- 数据签名（项数 + 每项文字）：没变就不重建 ——
            -- 否则每 0.1 秒重建一次列表，白费性能、还会打断正在进行的点击
            local sig = {}
            for i, it in ipairs(items) do
                sig[i] = (type(it) == "table" and tostring(it.text) or tostring(it))
            end
            local sigStr = table.concat(sig, "|")
            if sigStr == lastSig then return end
            lastSig = sigStr

            holder:ClearChildren()
            local rowPanel, colCount
            for i, item in ipairs(items) do
                -- 允许 item 直接是字符串（省事写法）
                if type(item) == "string" then item = { text = item } end
                local tpl = {}
                for k, v in pairs(node.itemTemplate or { type = "button" }) do tpl[k] = v end
                tpl.text = item.text or tpl.text
                tpl.action = item.action or tpl.action
                tpl.actionArg = item.arg or tpl.actionArg
                tpl.disabledIf = item.disabled and function() return true end or tpl.disabledIf
                local w = buildNode(tpl, ctx, refs)
                if w then
                    if cols > 1 then
                        if (i - 1) % cols == 0 then
                            rowPanel = UI.Panel { flexDirection = "row", gap = node.gap or 6, width = "100%",
                                children = {} }
                            holder:AddChild(rowPanel)
                            colCount = 0
                        end
                        colCount = colCount + 1
                        rowPanel:AddChild(UI.Panel { flexGrow = 1, flexShrink = 1, children = { w } })
                    else
                        holder:AddChild(w)
                    end
                end
            end
        end
        rebuild()
        -- 列表内容随数据变（价格/可选项），刷新时重建
        refs[#refs + 1] = rebuild
        return holder
    end

    print("[UIBuilder] ⚠️ 未知节点类型：" .. tostring(t))
    return nil
end

-- ---------------------------------------------------------------------------
-- 对外：建面板内容
-- ---------------------------------------------------------------------------
--- 按描述建控件树
---@param desc table 面板描述（UIDesc 注册的那种）
---@param ctx table { gameState, faction, onAction, panelId }
---@return any widget 内容控件
---@return fun() refresh 刷新函数（重算所有绑定值）
function UIBuilder.build(desc, ctx)
    ctx = ctx or {}
    ctx.panelId = desc.id
    ---@type fun()[]
    local refs = {}
    local widget = buildNode(desc.body, ctx, refs)
    widget = widget or UI.Panel { width = "100%", height = 40 }
    local function refresh()
        for i = 1, #refs do
            local ok, err = pcall(refs[i])
            if not ok then
                print("[UIBuilder] ⚠️ 刷新出错（已跳过）：" .. tostring(err))
            end
        end
    end
    refresh()
    return widget, refresh
end

return UIBuilder

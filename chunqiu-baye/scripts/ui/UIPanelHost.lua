-- ============================================================================
-- UIPanelHost.lua — 声明式 UI：**宿主**（"插座"第七块 · 2026-09-13）
--
-- 职责：把 UIDesc 里注册的"面板描述"挂到界面上（覆盖层 + 标题栏 + 关闭钮），
--       并提供动作派发（按钮点了之后干什么）。
--
-- 用法（游戏侧）：
--   UIPanelHost.attach(uiRoot)                 -- 建 UI 时挂一次
--   UIPanelHost.registerAction("speed_up", fn) -- 注册"游戏能做的事"
--   UIPanelHost.open("my_panel")               -- 打开某块声明式面板
--   UIPanelHost.refresh()                      -- 每帧（或每几帧）调一次，刷新绑定值
--
-- 动作派发顺序：
--   1. 内置：close_panel / open_panel
--   2. UIPanelHost.actions 里注册的（游戏/模组注册）
--   3. 都没有 → Hooks.fire("ui_action", { action, arg, panelId, widgetId, gameState })
--      → 模组只要挂一个 ui_action 钩子，就能给自己面板的按钮写逻辑
-- ============================================================================

local UI = require("urhox-libs/UI")
local UIDesc = require("ui.UIDesc")
local UIBuilder = require("ui.UIBuilder")
local Hooks = require("systems.Hooks")
local GameState = require("core.GameState")

local UIPanelHost = {}

local PAL = UIBuilder.PALETTE

--- 游戏/模组注册的动作：name → function(arg, ctx)
---@type table<string, function>
UIPanelHost.actions = {}

UIPanelHost.root_ = nil
UIPanelHost.overlay_ = nil
UIPanelHost.titleLabel_ = nil
UIPanelHost.bodyHolder_ = nil
UIPanelHost.currentId_ = nil
UIPanelHost.refreshFn_ = nil
UIPanelHost.lastRefresh_ = 0
UIPanelHost.REFRESH_INTERVAL = 0.1     -- 刷新间隔（秒）：10 次/秒足够，不折腾

-- ---------------------------------------------------------------------------
-- 动作
-- ---------------------------------------------------------------------------
--- 注册一个动作（游戏侧；模组也可以调，但更推荐挂 ui_action 钩子）
---@param name string
---@param fn fun(arg: any, ctx: table)
function UIPanelHost.registerAction(name, fn)
    UIPanelHost.actions[name] = fn
end

--- 派发一个动作
---@param action string|nil
---@param arg any
---@param widgetId string|nil
function UIPanelHost.dispatch(action, arg, widgetId)
    if not action or action == "" then return end
    local panelId = UIPanelHost.currentId_

    -- 内置动作
    if action == "close_panel" then
        UIPanelHost.close()
        return
    end
    if action == "open_panel" then
        UIPanelHost.open(tostring(arg))
        return
    end

    -- 游戏/模组注册的动作
    local fn = UIPanelHost.actions[action]
    if fn then
        local ok, err = pcall(fn, arg, { panelId = panelId, widgetId = widgetId, gameState = GameState })
        if not ok then
            print(string.format("[UIPanelHost] ⚠️ 动作 '%s' 出错：%s", action, tostring(err)))
        end
        return
    end

    -- 兜底：交给脚本钩子（模组在这里接）
    Hooks.fire("ui_action", {
        action = action, arg = arg, panelId = panelId,
        widgetId = widgetId, gameState = GameState,
    })
end

-- ---------------------------------------------------------------------------
-- 宿主覆盖层
-- ---------------------------------------------------------------------------
--- 在当前 UI 根节点里挂一个（隐藏的）面板宿主
---@param root any UI 根控件（GameUI 的 root / 主菜单的 root 都行）
---@return any overlay
function UIPanelHost.attach(root)
    UIPanelHost.root_ = root
    if UIPanelHost.overlay_ then return UIPanelHost.overlay_ end

    UIPanelHost.titleLabel_ = UI.Label {
        text = "", fontSize = 20, fontFamily = "gufeng", fontWeight = "bold",
        fontColor = PAL.gold,
    }
    UIPanelHost.bodyHolder_ = UI.Panel {
        flexDirection = "column", gap = 10, width = "100%",
        flexGrow = 1, flexBasis = 0,
    }

    local closeBtn = UI.Button {
        text = "X", width = 40, height = 40, fontSize = 20,
        fontFamily = "gufeng", fontWeight = "bold",
        textColor = { 250, 240, 222, 255 },
        backgroundColor = { 166, 42, 34, 255 },
        hoverBackgroundColor = { 190, 58, 46, 255 },
        pressedBackgroundColor = { 138, 34, 26, 255 },
        borderWidth = 2, borderColor = { 120, 26, 20, 255 }, borderRadius = 10,
        onClick = function() UIPanelHost.close() end,
    }

    local panel = UI.Panel {
        position = "absolute", top = "6%", left = "14%",
        width = "72%", maxWidth = 560, maxHeight = "88%",
        backgroundColor = PAL.bg, borderWidth = 1, borderColor = PAL.border,
        borderRadius = 12, padding = 14, gap = 10,
        pointerEvents = "auto",
        children = {
            UI.Panel {
                flexDirection = "row", alignItems = "center", width = "100%",
                children = { UIPanelHost.titleLabel_, UI.Panel { flexGrow = 1 }, closeBtn },
            },
            UI.Divider { color = { 110, 82, 50, 160 }, thickness = 1 },
            UIPanelHost.bodyHolder_,
        },
    }

    -- 背板：挡住地图点击；点背板 = 关闭
    local backdrop = UI.Button {
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        text = "", backgroundColor = { 0, 0, 0, 140 },
        hoverBackgroundColor = { 0, 0, 0, 140 },
        pressedBackgroundColor = { 0, 0, 0, 140 },
        borderRadius = 0, borderWidth = 0,
        onClick = function() UIPanelHost.close() end,
    }

    UIPanelHost.overlay_ = UI.Panel {
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        pointerEvents = "auto",
        children = { backdrop, panel },
    }
    UIPanelHost.overlay_:Hide()

    -- 挂进根节点（保持"最后加 = 最上层"）
    if root and root.AddChild then root:AddChild(UIPanelHost.overlay_) end
    return UIPanelHost.overlay_
end

--- 打开一块声明式面板
---@param id string 面板 id（UIDesc.register 注册的）
---@return boolean ok
function UIPanelHost.open(id)
    local desc = UIDesc.get(id)
    if not desc then
        print("[UIPanelHost] ⚠️ 没有这块面板：" .. tostring(id))
        return false
    end
    if not UIPanelHost.bodyHolder_ then
        print("[UIPanelHost] ⚠️ 还没 attach，先 UIPanelHost.attach(uiRoot)")
        return false
    end

    UIPanelHost.titleLabel_:SetText(tostring(desc.title or id))
    UIPanelHost.bodyHolder_:ClearChildren()

    local ctx = {
        gameState = GameState,
        faction = GameState.getPlayerFaction and GameState.getPlayerFaction() or nil,
        onAction = UIPanelHost.dispatch,
        panelId = id,
    }
    local body, refresh = UIBuilder.build(desc, ctx)
    UIPanelHost.refreshFn_ = refresh
    UIPanelHost.bodyHolder_:AddChild(body)
    UIPanelHost.currentId_ = id
    UIPanelHost.overlay_:Show()
    UIPanelHost.refresh()
    print("[UIPanelHost] 打开面板：" .. id)
    return true
end

function UIPanelHost.close()
    if UIPanelHost.overlay_ then UIPanelHost.overlay_:Hide() end
    if UIPanelHost.bodyHolder_ then UIPanelHost.bodyHolder_:ClearChildren() end
    UIPanelHost.currentId_ = nil
    UIPanelHost.refreshFn_ = nil
end

---@return boolean
function UIPanelHost.isOpen()
    return UIPanelHost.overlay_ ~= nil and UIPanelHost.overlay_:IsVisible() or false
end

---@return string|nil
function UIPanelHost.current()
    return UIPanelHost.currentId_
end

--- 刷新绑定值（游戏侧每帧调；内部按 REFRESH_INTERVAL 限流）
---@param force boolean|nil
function UIPanelHost.refresh(force)
    if not UIPanelHost.refreshFn_ then return end
    local now = os.clock()
    if not force and (now - UIPanelHost.lastRefresh_) < UIPanelHost.REFRESH_INTERVAL then return end
    UIPanelHost.lastRefresh_ = now
    UIPanelHost.refreshFn_()
end

return UIPanelHost

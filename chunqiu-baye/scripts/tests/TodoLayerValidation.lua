-- 验收：待办/消息摘要必须在**最底层**——任何面板都能盖住它（用户 2026-10-05 口径）。
-- 跑法：UrhoXRuntime tests/TodoLayerValidation.lua -tapcode_dir=/workspace ...
local UI = require("urhox-libs/UI")
local GameUI = require("ui.GameUI")
local GameState = require("core.GameState")
local EventSystem = require("systems.EventSystem")
require("main")
local gameStart = Start

local step, frames = 0, 0

local function widget(id)
    local w = UI.GetRoot():FindById(id)
    assert(w, "找不到控件：" .. id)
    return w
end

local function describe(w)
    if not w then return "nil" end
    local id = w.id or "(无id)"
    return tostring(w.className) .. "#" .. tostring(id)
end

function HandleTodoLayerValidation()
    frames = frames + 1
    -- 预热：等游戏状态真正就绪（否则 GameState.factions 还是空的）
    if step == 0 then
        local fid = GameState.playerFactionId
        if not (fid and GameState.factions and GameState.factions[fid]) then return end
    end
    if frames % 12 ~= 0 then return end
    step = step + 1
    local ok, err = pcall(function()
        if step == 1 then
            -- 造一条待办 + 两条消息 → 待办/消息摘要按钮出现
            local f = GameState.factions[GameState.playerFactionId]
            EventSystem.forcePending("harvest_good", f.id, f)
            GameState.addMessage("层级验收消息", "system", true)
            GameUI.updatePendingEvent(EventSystem.getPendingList(), false)
        elseif step == 2 then
            local btn = widget("eventSummaryBtn")
            assert(btn:IsVisible(), "待办按钮不可见")
            local lay = btn:GetAbsoluteLayout()
            print(string.format("[LayerTest] 待办按钮 布局=(%.1f,%.1f %.1fx%.1f)",
                lay.x, lay.y, lay.w, lay.h))

            -- ① 无面板时：点待办中心 → 命中的必须是待办自己
            local scale = UI.GetScale()
            local cx, cy = (lay.x + lay.w / 2) * scale, (lay.y + lay.h / 2) * scale
            local hitOpen = UI.FindWidgetAt(cx, cy)
            print("[LayerTest] 无面板时命中: " .. describe(hitOpen))
            assert(hitOpen == btn, "无面板时待办点不到（被 " .. describe(hitOpen) .. " 挡住）")

            -- ② 打开省份面板（无主省 → 走 provActionHint 分支，不需要额外数据）
            local pid
            for id, p in pairs(GameState.provinces or {}) do
                if not p.ownerId and not p.isWasteland then pid = id break end
            end
            assert(pid, "找不到可用的无主省份")
            GameUI.showProvincePanel(pid, GameState.provinces[pid])
            print("[LayerTest] 已打开省份面板 id=" .. tostring(pid))
        elseif step == 3 then
            local btn = widget("eventSummaryBtn")
            local panel = GameUI.refs.provincePanel
            assert(panel:IsVisible(), "省份面板未打开")
            assert(btn:IsVisible(), "省份面板打开后待办按钮消失了（应该仍在，只是被盖住）")

            local lay = btn:GetAbsoluteLayout()
            local scale = UI.GetScale()
            local cx, cy = (lay.x + lay.w / 2) * scale, (lay.y + lay.h / 2) * scale
            local hit = UI.FindWidgetAt(cx, cy)
            print("[LayerTest] 面板打开后，待办中心命中: " .. describe(hit))
            assert(hit ~= btn, "待办仍在上层（应该被省份面板盖住）")

            -- 命中的应该是省份面板自身或其子控件
            local owner = hit
            local found = false
            while owner do
                if owner == panel then found = true break end
                owner = owner.parent
            end
            assert(found, "待办中心命中的不是省份面板，而是 " .. describe(hit))

            -- ③ 面板关闭后，待办必须重新可点
            GameUI.hideProvincePanel()
        elseif step == 4 then
            local btn = widget("eventSummaryBtn")
            assert(not GameUI.refs.provincePanel:IsVisible(), "省份面板未关闭")
            local lay = btn:GetAbsoluteLayout()
            local scale = UI.GetScale()
            local cx, cy = (lay.x + lay.w / 2) * scale, (lay.y + lay.h / 2) * scale
            local hit = UI.FindWidgetAt(cx, cy)
            print("[LayerTest] 关闭面板后命中: " .. describe(hit))
            assert(hit == btn, "关闭面板后待办点不到（被 " .. describe(hit) .. " 挡住）")

            print("[LayerTest] PASS：待办在最底层——无面板可点、面板打开被盖、关闭后恢复可点")
            step = -100000
            engine:Exit()
        end
    end)
    if not ok then
        print("[LayerTest] FAIL：" .. tostring(err))
        engine:Exit()
    end
end

function Start()
    gameStart()
    SubscribeToEvent("Update", "HandleTodoLayerValidation")
end

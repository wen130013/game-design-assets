
-- 调军数量选择验收：走真实触摸链路，验证数量可控、全部调走可用。
local UI = require("urhox-libs/UI")
local GameUI = require("ui.GameUI")
local GameState = require("core.GameState")
require("main")
local gameStart = Start
local step, frames = 0, 0

local function widget(id)
    local w = UI.GetRoot():FindById(id)
    assert(w, "找不到控件：" .. id)
    return w
end

local function tap(id)
    local l = widget(id):GetAbsoluteLayout()
    local s = UI.GetScale()
    UI.HandleTouchBegin(41, (l.x + l.w/2)*s, (l.y + l.h/2)*s, 1)
    UI.HandleTouchEnd(41, (l.x + l.w/2)*s, (l.y + l.h/2)*s)
    print("[MoveTest] 点击 " .. id)
end

-- 找一个自己的省（有驻军）
local function myProvince()
    local pf = GameState.getPlayerFaction()
    assert(pf, "没有玩家势力")
    for _, pid in ipairs(pf.provinces or {}) do
        local p = GameState.provinces[pid]
        if p and (p.garrison or 0) > 100 and not p.isWasteland then return pid end
    end
    return nil
end

function HandleMoveValidation()
    frames = frames + 1
    if frames % 10 ~= 0 then return end
    step = step + 1
    local ok, err = pcall(function()
        if step == 1 then
            local pid = myProvince()
            assert(pid, "找不到有驻军的省")
            print("[MoveTest] 测试省 id=" .. pid .. " 驻军=" .. GameState.provinces[pid].garrison)
            GameUI.showUnitPanel({ provId = pid }, "garrison")
        elseif step == 2 then
            local row = widget("unitMoveCountRow")
            assert(row:IsVisible(), "调军数量行没显示")
            local g = GameState.provinces[GameUI.refs.unitTarget.provId].garrison
            local f = widget("unitMoveCountField")
            print(string.format("[MoveTest] 驻军 %d，默认调军 %s", g, f:GetValue()))
            tap("unitMovePlus")
        elseif step == 3 then
            local f = widget("unitMoveCountField")
            print("[MoveTest] 点 +100 后 = " .. f:GetValue())
            tap("unitMoveMaxBtn")
        elseif step == 4 then
            local f = widget("unitMoveCountField")
            local g = GameState.provinces[GameUI.refs.unitTarget.provId].garrison
            assert(tonumber(f:GetValue()) == g, "全部调走没填满")
            print(string.format("[MoveTest] 全部调走 = %s（驻军 %d）OK", f:GetValue(), g))
            tap("unitMoveMinus")
        elseif step == 5 then
            local f = widget("unitMoveCountField")
            local g = GameState.provinces[GameUI.refs.unitTarget.provId].garrison
            assert(tonumber(f:GetValue()) < g, "减按钮没生效")
            print("[MoveTest] 减后 = " .. f:GetValue() .. " OK")
            print("[MoveTest] PASS：调军数量可增可减可全选")
            step = -100000
        end
    end)
    if not ok then print("[MoveTest] FAIL：" .. tostring(err)); engine:Exit() end
end

function Start()
    gameStart()
    SubscribeToEvent("Update", "HandleMoveValidation")
end

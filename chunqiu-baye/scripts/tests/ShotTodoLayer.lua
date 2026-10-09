-- 出图：待办 + 省份面板同时出现，验证待办被盖住（用户 2026-10-05 口径）
local GameUI = require("ui.GameUI")
local GameState = require("core.GameState")
local EventSystem = require("systems.EventSystem")
require("main")
local gameStart = Start

local step, frames, done = 0, 0, false

function HandleShotTodoLayer()
    frames = frames + 1
    if done then return end
    if step == 0 then
        local fid = GameState.playerFactionId
        if not (fid and GameState.factions and GameState.factions[fid]) then return end
        step = 1
    elseif step == 1 and frames % 12 == 0 then
        local f = GameState.factions[GameState.playerFactionId]
        EventSystem.forcePending("harvest_good", f.id, f)
        GameState.addMessage("层级验收消息", "system", true)
        GameUI.updatePendingEvent(EventSystem.getPendingList(), false)
        step = 2
    elseif step == 2 and frames % 12 == 0 then
        local pid
        for id, p in pairs(GameState.provinces or {}) do
            if not p.ownerId and not p.isWasteland then pid = id break end
        end
        if pid then
            GameUI.showProvincePanel(pid, GameState.provinces[pid])
            print("[ShotTodoLayer] 省份面板已开 id=" .. tostring(pid) .. "，帧=" .. frames)
            done = true
        end
    end
end

function Start()
    gameStart()
    SubscribeToEvent("Update", "HandleShotTodoLayer")
end

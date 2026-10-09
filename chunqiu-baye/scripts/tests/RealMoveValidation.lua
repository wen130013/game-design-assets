
-- 真实调军流程验收（不依赖地图点击）：
--   验证「设数量 -> 进调军模式 -> 数量不丢 -> 按该数量派兵」这条链路。
local UI = require("urhox-libs/UI")
local GameUI = require("ui.GameUI")
local GameState = require("core.GameState")
local MilitarySystem = require("systems.MilitarySystem")
require("main")
local gameStart = Start
local step, frames = 0, 0
local fromId, toId, before

local function widget(id) return UI.GetRoot():FindById(id) end

local function myProv()
    local pf = GameState.getPlayerFaction()
    for _, pid in ipairs(pf.provinces or {}) do
        local p = GameState.provinces[pid]
        if p and (p.garrison or 0) > 100 and not p.isWasteland then return pid end
    end
end

local function neighborOf(pid)
    for _, n in ipairs(GameState.provinces[pid].neighbors or {}) do
        local np = GameState.provinces[n]
        if np and not np.isWasteland then return n end
    end
end

function HandleMove()
    frames = frames + 1
    if frames % 10 ~= 0 then return end
    step = step + 1
    local ok, err = pcall(function()
        if step == 1 then
            fromId = myProv(); toId = neighborOf(fromId)
            before = GameState.provinces[fromId].garrison
            print(string.format("[Real] 出发省 %s 驻军 %d", GameState.provinces[fromId].name, before))
            GameUI.showUnitPanel({ provId = fromId }, "garrison")
        elseif step == 2 then
            GameUI.setMoveCountMax()
            local v = tonumber(widget("unitMoveCountField"):GetValue())
            print("[Real] 设定调军数量 = " .. tostring(v))
            assert(v == before, "全选没生效")
            GameUI.startArmyMove(fromId)   -- 这一步会关面板（原来就是这里丢的数量）
        elseif step == 3 then
            local w = GameUI.moveWanted()
            print("[Real] 进调军模式后 moveWanted = " .. tostring(w) .. "（应为 " .. before .. "）")
            assert(w == before, "★ 数量丢失 —— 这就是用户报的 bug")
            -- 按该数量真的派兵（和 main.lua 里的分支同样的写法）
            local pid = GameState.playerFactionId
            local ok2 = MilitarySystem.orderMove(GameState, pid, fromId, toId, w)
            print("[Real] orderMove 结果 = " .. tostring(ok2))
        elseif step == 4 then
            local after = GameState.provinces[fromId].garrison or 0
            local moved = before - after
            print(string.format("[Real] 调军后：%d -> %d（派出 %d）", before, after, moved))
            assert(moved == before, "只派了 " .. moved .. "，应派 " .. before)
            print("[Real] PASS：全部调走真的生效，原省清零")
            step = -100000
        end
    end)
    if not ok then print("[Real] FAIL：" .. tostring(err)); engine:Exit() end
end

function Start()
    gameStart()
    SubscribeToEvent("Update", "HandleMove")
end

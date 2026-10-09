
-- 只打开军队面板并停住，供截图查看外观。
local UI = require("urhox-libs/UI")
local GameUI = require("ui.GameUI")
local GameState = require("core.GameState")
require("main")
local gameStart = Start
local done = false

function HandleShot()
    if done then return end
    local pf = GameState.getPlayerFaction()
    if not pf then return end
    for _, pid in ipairs(pf.provinces or {}) do
        local p = GameState.provinces[pid]
        if p and (p.garrison or 0) > 100 and not p.isWasteland then
            GameUI.showUnitPanel({ provId = pid }, "garrison")
            print("[ShotMove] 打开军队面板 省=" .. pid .. " 驻军=" .. p.garrison)
            done = true
            return
        end
    end
end

function Start()
    gameStart()
    SubscribeToEvent("Update", "HandleShot")
end

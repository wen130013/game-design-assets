-- 量：小屏(landscape 手机)下军队详情面板是否超出可用高度
local GameUI = require("ui.GameUI")
local GameState = require("core.GameState")
local NavigationHUD = require("ui.NavigationHUD")
require("main")
local gameStart = Start

local step, frames = 0, 0

function HandleShotUnitPanelFit()
    frames = frames + 1
    if frames > 400 then engine:Exit() return end   -- 兜底：测完就退，别挂着
    if step == 0 then
        local fid = GameState.playerFactionId
        if not (fid and GameState.factions and GameState.factions[fid]) then return end
        step = 1
    elseif step == 1 and frames % 12 == 0 then
        -- 找一个玩家自己的、有驻军的省份
        local target
        for id, p in pairs(GameState.provinces or {}) do
            if p.ownerId == GameState.playerFactionId and (p.garrison or 0) > 0 then target = id break end
        end
        if not target then
            for id, p in pairs(GameState.provinces or {}) do
                if p.ownerId == GameState.playerFactionId then target = id break end
            end
        end
        if not target then print("[Fit] 找不到目标省"); step = -1 return end
        GameUI.showUnitPanel({ provId = target }, "garrison")
        print("[Fit] 打开驻军面板 provId=" .. tostring(target))
        step = 2
    elseif step == 2 and frames % 12 == 0 then
        local m = NavigationHUD.metrics()
        local panel = GameUI.refs.unitPanel
        local box = GameUI.refs.unitPanelBox
        local pl = panel:GetAbsoluteLayout()
        local bl = box:GetAbsoluteLayout()
        local sw = graphics:GetWidth()
        local sh = graphics:GetHeight()
        -- 同单位比较：GetAbsoluteLayout 与 metrics 都是 UI 空间
        local f = m.factor
        print(string.format("[Fit] 屏幕 %dx%d dpr=%.2f factor=%.3f narrow=%s", sw, sh, graphics:GetDPR(), f, tostring(m.narrow)))
        print(string.format("[Fit] metrics: top=%.1f contentH=%.1f | box y=%.1f h=%.1f",
            m.top, m.contentH, bl.y, bl.h))
        print(string.format("[Fit] 顶栏底=%.1f 面板顶=%.1f 面板底=%.1f 可用底=%.1f",
            m.top, bl.y, bl.y + bl.h, m.top + m.contentH))
        print(string.format("[Fit] 顶进顶栏=%.1f  超出可用底=%.1f  （都要 <=0 才算正常）",
            m.top - bl.y, (bl.y + bl.h) - (m.top + m.contentH)))
        print(string.format("[Fit] 面板高=%.1f  可用高=%.1f  是否被 maxHeight 夹住=%s",
            bl.h, m.contentH, tostring(bl.h <= m.contentH + 1)))
        local tb = GameUI.refs.topBar
        if tb then
            local t = tb:GetAbsoluteLayout()
            print(string.format("[Fit] 顶栏实测 y=%.1f h=%.1f 底=%.1f （m.top=%.1f 差=%.1f）",
                t.y, t.h, t.y + t.h, m.top, (t.y + t.h) - m.top))
        end
        local title = GameUI.refs.unitTitleLabel
        if title then
            local tl = title:GetAbsoluteLayout()
            print(string.format("[Fit] 标题顶=%.1f h=%.1f （需 >= 顶栏底 %.1f）", tl.y, tl.h, m.top))
        end
        step = -1   -- 不退出，让截图能拍到面板
    end
end

function Start()
    gameStart()
    SubscribeToEvent("Update", "HandleShotUnitPanelFit")
end

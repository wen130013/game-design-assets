-- 验收顶栏：① 设置按钮在名声右侧且隔开 ② 时间组紧凑 ③ 极端年份不溢出
local UI = require("urhox-libs/UI")   -- ⚠️ 必须显式 require：全局 UI 是引擎的，没有 MeasureTextFit
local GameUI = require("ui.GameUI")
local GameState = require("core.GameState")
local NavigationHUD = require("ui.NavigationHUD")
require("main")
local gameStart = Start

local step, frames = 0, 0

local function lay(w) local l = w:GetAbsoluteLayout() return l.x, l.y, l.w, l.h end

function HandleShotTopBarFit()
    frames = frames + 1
    if frames > 400 then engine:Exit() return end
    if step == 0 then
        local fid = GameState.playerFactionId
        if not (fid and GameState.factions and GameState.factions[fid]) then return end
        step = 1
    elseif step == 1 and frames % 12 == 0 then
        local r = GameUI.refs
        local lastStat
        for _, st in pairs(r.topStats or {}) do
            local x = lay(st.panel)
            if not lastStat or x > lastStat.x then lastStat = { x = x, w = select(3, lay(st.panel)), id = st } end
        end
        local nx, ny, nw, nh = lay(r.topBarSettingsBtn)
        local tx, ty, tw, th = lay(r.hudTimeGroup)
        local dx, dy, dw, dh = lay(r.topDate)
        print(string.format("[TopFit] 屏 %dx%d f=%.3f", graphics:GetWidth(), graphics:GetHeight(), NavigationHUD.metrics().factor))
        if lastStat then
            local gap = nx - (lastStat.x + lastStat.w)
            print(string.format("[TopFit] 最后一个资源 x=%.1f w=%.1f → 设置按钮 x=%.1f w=%.1f  间距=%.1f",
                lastStat.x, lastStat.w, nx, nw, gap))
        end
        print(string.format("[TopFit] 设置按钮 (%.1f,%.1f %.1fx%.1f) 时间组 (%.1f,%.1f %.1fx%.1f)",
            nx, ny, nw, nh, tx, ty, tw, th))
        print(string.format("[TopFit] 时间组总宽=%.1f（暂停26+日期%.1f+速度48）", tw, dw))
        step = 2
    elseif step == 2 and frames % 12 == 0 then
        -- 极端年份：直接塞长文本，看自适应是否生效
        local r = GameUI.refs
        for _, t in ipairs({ "前770年 春 2月 10日", "前770年 12月 30日", "前7700年 12月 30日" }) do
            r.topDate:SetText(t)
            local ok, err = pcall(function() NavigationHUD.fitDateText(r) end)
            if not ok then print("[TopFit] fitDateText 报错: " .. tostring(err)) end
            local _, _, dw, _ = lay(r.topDate)
            local fs = r.topDate.props and r.topDate.props.fontSize or -1
            local res = UI.MeasureTextFit(t, { fontSize = fs, fontFace = "gufeng", width = 1e9, height = 1e9 })
            local fit = res and res.width or -1
            print(string.format("[TopFit] 文本 %-20s 字号=%.1f 文本宽=%.1f 框宽=%.1f 余量=%.1f %s",
                t, fs, fit, dw, dw - fit, (fit <= dw - 8) and "OK" or "贴边!"))
        end
        -- 恢复真实日期，供截图
        r.topDate:SetText("前770年 春 2月 10日")
        NavigationHUD.fitDateText(r)
        step = 3
    end
end

function Start()
    gameStart()
    SubscribeToEvent("Update", "HandleShotTopBarFit")
end

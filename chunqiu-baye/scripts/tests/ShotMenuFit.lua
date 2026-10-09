-- 量：主菜单内容总高 vs 屏幕高（标题被切 = 内容超高）
local UI = require("urhox-libs/UI")
local MainMenu = require("ui.MainMenu")
require("main")
local gameStart = Start

local frames = 0
function HandleShotMenuFit()
    frames = frames + 1
    if frames > 300 then engine:Exit() return end
    if frames % 12 ~= 0 then return end
    local root = UI.GetRoot()
    if not root then return end
    local sw, sh = graphics:GetWidth(), graphics:GetHeight()
    print(string.format("[MenuFit] 屏幕 %dx%d  scale=%.3f", sw, sh, UI.GetScale()))
    -- 找标题 Label（文本=逐鹿九州）
    local found
    local function walk(w, depth)
        if found then return end
        if w.props and w.props.text == "逐鹿九州" then found = w return end
        for _, c in ipairs(w.children or {}) do walk(c, depth + 1) end
    end
    walk(root, 0)
    if found then
        local l = found:GetAbsoluteLayout()
        print(string.format("[MenuFit] 标题 y=%.1f h=%.1f → 顶=%.1f 底=%.1f （顶<0 就是被切）",
            l.y, l.h, l.y, l.y + l.h))
    else
        print("[MenuFit] 未找到标题")
    end
    -- 菜单内容容器（root 的第二个子节点）
    local content = root.children and root.children[2]
    if content then
        local c = content:GetAbsoluteLayout()
        print(string.format("[MenuFit] 内容容器 y=%.1f h=%.1f → 底=%.1f", c.y, c.h, c.y + c.h))
    end
    if frames >= 150 then engine:Exit() end   -- 留够帧数让截图拍到
end

-- 模拟"有存档"：用户截图里有「读取存档」按钮（多一个 = 内容超高）
--   main.lua 用 SaveManager.hasSave() 决定是否显示 → 在这里打成 true
function Start()
    local SaveManager = require("save.SaveManager")
    SaveManager.hasSave = function() return true end
    print("[MenuFit] 已模拟 hasSave=true（会出现「读取存档」按钮）")
    gameStart()
    SubscribeToEvent("Update", "HandleShotMenuFit")
end

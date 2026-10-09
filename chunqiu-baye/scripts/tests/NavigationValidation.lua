-- 国旗菜单 / 整行地图折叠 / 肖像 / 消息簿的原生触摸验收，不写玩家存档。
local UI = require("urhox-libs/UI")
local GameUI = require("ui.GameUI")
local GameState = require("core.GameState")
local CharacterSystem = require("systems.CharacterSystem")
local NavigationHUD = require("ui.NavigationHUD")
local SaveManager = require("save.SaveManager")
local TimeSystem = require("core.TimeSystem")
local EventSystem = require("systems.EventSystem")
require("main")
local gameStart = Start
local step, frames = 0, 0

local function widget(id)
    local w = UI.GetRoot():FindById(id)
    assert(w, "找不到控件：" .. id)
    return w
end

local function tap(id, leftEdge)
    local l = widget(id):GetAbsoluteLayout()
    local scale = UI.GetScale()
    local x, y = (l.x + (leftEdge and 8 or l.w / 2)) * scale, (l.y + l.h / 2) * scale
    UI.HandleTouchBegin(41, x, y, 1)
    UI.HandleTouchEnd(41, x, y)
    print("[NavTest] 手指点击 " .. id)
end

local function target(id)
    local l = widget(id):GetAbsoluteLayout()
    local ratio = UI.GetScale() / graphics:GetDPR()
    local minimumHeight = id == "mapModeHeader" and 43.5 or 47.5
    assert(l.w * ratio >= 47.5 and l.h * ratio >= minimumHeight, id .. " 点击区太小")
    local m = NavigationHUD.metrics()
    assert(l.x >= m.safe.left - 1 and l.x + l.w <= m.width - m.safe.right + 1, id .. " 横向越界")
    assert(l.y >= m.safe.top - 1 and l.y + l.h <= m.height - m.safe.bottom + 1, id .. " 纵向越界")
    print(string.format("[NavTest] %s 触控区 %.1fx%.1f", id, l.w * ratio, l.h * ratio))
end

local function timeFeedback()
    local group = widget("hudTimeGroup")
    local ratio = UI.GetScale()
    local function move(id)
        local l = widget(id):GetAbsoluteLayout()
        local x, y = (l.x + l.w / 2) * ratio, (l.y + l.h / 2) * ratio
        UI.HandleMouseMove(x, y)
        assert(group.state.hovered, "悬停未点亮整个时间区：" .. id)
        return x, y
    end
    move("hudPauseBtn"); move("topDateBtn")
    local x, y = move("topSpeedBtn")
    UI.HandleTouchBegin(42, x, y, 1)
    assert(group.state.pressed, "点速度未点亮整个时间区")
    UI.HandleTouchCancel(42)
    assert(not group.state.pressed, "取消触摸后时间区仍按下")
    local paused = GameState.paused
    tap("topSpeedBtn")
    assert(GameState.paused == paused, "速度点击误触暂停")
    assert(GameUI.refs.speedMenu:IsVisible(), "速度菜单未开")
    GameUI.toggleSpeedMenu()
    tap("topDateBtn")
    assert(GameState.paused ~= paused, "日期点击未切换暂停")
    tap("hudPauseBtn")
    assert(GameState.paused == paused, "暂停图标没有共用日期操作")
    UI.HandleMouseMove(0, UI.GetScreenHeight() / 2)
    assert(not group.state.hovered, "移出后仍高亮")
    print("[NavTest] 时间整体悬停、按下、取消、速度独立点击通过")
end

function HandleNavigationValidation()
    frames = frames + 1
    if frames % 12 ~= 0 then return end
    step = step + 1
    local ok, err = pcall(function()
        if step == 1 then
            assert(not widget("mainNavigation"):IsVisible(), "菜单不应常驻")
            local m = NavigationHUD.metrics()
            assert(m.bottom == m.safe.bottom, "底部仍预留导航条")
            timeFeedback()
            local r = GameUI.refs
            local flag = r.topFlagSlot:GetAbsoluteLayout()
            local arrow = r.flagMenuIndicator:GetAbsoluteLayout()
            assert(arrow.y >= flag.y + flag.h - 1, "箭头不在国旗下方")
            assert(math.abs((arrow.x + arrow.w / 2) - (flag.x + flag.w / 2)) < 2, "国旗箭头未居中")
            target("flagMenuBtn"); tap("flagMenuBtn")
        elseif step == 2 then
            assert(widget("mainNavigation"):IsVisible(), "点旗未开菜单")
            for _, id in ipairs({ "topSelfBtn", "topCourtBtn", "topPolicyBtn", "topDiplomacyBtn", "topArmyBtn", "topTechBtn" }) do target(id) end
            tap("topSelfBtn")
        elseif step == 3 then
            assert(not widget("mainNavigation"):IsVisible(), "选择功能后菜单未收起")
            target("selfCloseBtn"); target("selfChangePortraitBtn"); tap("selfChangePortraitBtn")
        elseif step == 4 then
            target("portraitChoice_scholar"); tap("portraitChoice_scholar")
        elseif step == 5 then
            local f = GameState.factions[GameState.playerFactionId]
            local c = CharacterSystem.getById(GameState, f.leaderId)
            assert(c.portraitKey == "scholar", "更换未写人物")
            assert(widget("navPortraitImage").props.backgroundImage == NavigationHUD.PORTRAITS[2].path, "小肖像未同步")
            local saved = cjson.decode(cjson.encode(SaveManager.collect(GameState, TimeSystem.getState()))).factions[tostring(f.id)]
            local found = false
            for _, char in ipairs(saved.characters) do if char.id == c.id then found = char.portraitKey == "scholar" end end
            assert(found, "存档丢失肖像")
            tap("selfCloseBtn"); tap("flagMenuBtn")
        elseif step == 6 then tap("topCourtBtn")
        elseif step == 7 then
            local r, m = GameUI.refs, NavigationHUD.metrics()
            local box = r.courtPanel:FindById("courtPanelBox"):GetAbsoluteLayout()
            assert(box.y >= m.top - 1, "朝廷盖住顶栏")
            assert(box.w > m.contentW * 0.95, "朝廷仍锁在窄框")
            tap("flagMenuBtn")
        elseif step == 8 then tap("topDiplomacyBtn")
        elseif step == 9 then assert(GameUI.isDiplomacyVisible(), "外交未开"); tap("flagMenuBtn")
        elseif step == 10 then tap("topArmyBtn")
        elseif step == 11 then
            assert(not GameUI.isDiplomacyVisible(), "外交未互斥关")
            GameUI.hideArmyPanel()
            target("mapModeHeader"); tap("mapModeHeader", true)
        elseif step == 12 then
            assert(GameUI.refs.mapModeFolded, "标题左端点击未收起")
            local folded = GameUI.refs.mapModePanel:GetAbsoluteLayout()
            local ratio = UI.GetScale() / graphics:GetDPR()
            assert(folded.h * ratio < 55, "收起仍是大空框")
            tap("mapModeHeader", true)
        elseif step == 13 then
            assert(not GameUI.refs.mapModeFolded, "整行点击未展开")
            for _, id in ipairs({ "political", "region", "war", "ally", "resource", "terrain" }) do target("mapMode_" .. id) end
            local f = GameState.factions[GameState.playerFactionId]
            EventSystem.forcePending("harvest_good", f.id, f)
            GameState.addMessage("验收消息", "system", true)
            GameState.addMessage("验收消息", "system", true)
            GameUI.updatePendingEvent(EventSystem.getPendingList(), false)
        elseif step == 14 then
            print("[NavTest] 待办数 " .. #(GameUI.pendingList_ or {}) .. "，汇总可见 " .. tostring(widget("eventSummaryBtn"):IsVisible()))
            target("eventSummaryBtn"); tap("eventSummaryBtn")
        elseif step == 15 then
            target("inboxCloseBtn"); tap("pendingEvent_1")
        elseif step == 16 then
            target("eventCloseBtn"); assert(GameUI.isEventDialogVisible(), "待办不能打开")
            tap("eventCloseBtn")
        elseif step == 17 then tap("noticeSummaryBtn")
        elseif step == 18 then target("inboxMarkAllBtn"); tap("inboxMarkAllBtn")
        elseif step == 19 then
            for _, msg in ipairs(GameState.messages) do if msg.notify then assert(msg.read, "已读未清") end end
            assert(#(GameUI.pendingList_ or {}) > 0, "清消息错误丢弃待办")
            tap("inboxCloseBtn")
        elseif step == 20 then
            print("[NavTest] PASS：国旗菜单、原六入口、左对齐、肖像存档、整行折叠、六模式触控、消息已读不丢待办")
            step = -100000
        end
    end)
    if not ok then print("[NavTest] FAIL：" .. tostring(err)); engine:Exit() end
end

function Start()
    gameStart()
    SubscribeToEvent("Update", "HandleNavigationValidation")
end

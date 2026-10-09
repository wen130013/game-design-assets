-- 待办必须处理，消息只是告知：主地图只留汇总入口和短暂一条提示。
local UI = require("urhox-libs/UI")
local NavigationHUD = require("ui.NavigationHUD")
local M = {}
local C = { bg = { 27, 25, 23, 252 }, line = { 136, 108, 64, 230 },
    gold = { 232, 205, 144, 255 }, text = { 234, 228, 214, 255 }, muted = { 174, 166, 148, 255 } }

local function clock()
    return time and time.elapsedTime or os.clock()
end

local function button(id, text, fn, width)
    return UI.Button { id = id, text = text, width = width, height = NavigationHUD.touchSize(48), fontSize = 12,
        fontFamily = "gufeng", textColor = C.gold, paddingHorizontal = 10,
        backgroundColor = { 53, 43, 28, 245 }, hoverBackgroundColor = { 73, 58, 34, 250 },
        pressedBackgroundColor = { 100, 77, 42, 255 }, borderWidth = 1, borderColor = C.line,
        borderRadius = 6, glowShadow = false, onClick = fn }
end

local function groupsOf(messages)
    local groups, byKey = {}, {}
    for i = #(messages or {}), 1, -1 do
        local msg = messages[i]
        if msg.notify and not msg.read then
            local key = tostring(msg.type) .. ":" .. tostring(msg.text)
            local g = byKey[key]
            if not g then
                g = { text = msg.text, latest = msg, messages = {} }
                byKey[key] = g
                groups[#groups + 1] = g
            end
            g.messages[#g.messages + 1] = msg
        end
    end
    return groups
end

function M.create(ctx)
    local refs, gameUI = ctx.refs, ctx.GameUI
    refs.messageCenterTab = "events"
    refs.messageCenterRows = UI.Panel { width = "100%", gap = 8 }
    refs.eventSummary = button("eventSummaryBtn", "待办 0", function() gameUI.showMessageCenter("events") end)
    refs.noticeSummary = button("noticeSummaryBtn", "消息 0", function() gameUI.showMessageCenter("notices") end)
    -- ⚠️ 本容器不再挂到 eventNoticeBar（那层在 root 第 19 位 → 会压住省份面板）。
    --    改由 GameUI 把它插到 root 的**最底层**，任何面板/按钮都能盖住它（用户 2026-10-05 口径）。
    refs.messageSummaries = UI.Panel { id = "messageSummaries", position = "absolute", top = 0, left = 0,
        height = NavigationHUD.touchSize(48), flexDirection = "row", gap = 8, pointerEvents = "box-none", children = { refs.eventSummary, refs.noticeSummary } }
    refs.eventSummary:Hide()
    refs.noticeSummary:Hide()
    refs.noticeToast = button("noticeToast", "", function()
        if refs.noticeToastMessage then gameUI.showNoticeDialog(refs.noticeToastMessage) end
        refs.noticeToast:Hide()
    end)
    refs.noticeToast:SetStyle({ position = "absolute", top = 0, right = 0, width = 300, fontSize = 11 })
    refs.noticeToast:Hide()
    refs.messageCenterEventTab = button("inboxEventsTab", "待办", function()
        refs.messageCenterTab = "events"; refs.messageCenterSignature = nil; M.refresh(refs, gameUI)
    end)
    refs.messageCenterNoticeTab = button("inboxNoticesTab", "消息", function()
        refs.messageCenterTab = "notices"; refs.messageCenterSignature = nil; M.refresh(refs, gameUI)
    end)
    refs.messageMarkAll = button("inboxMarkAllBtn", "全部已读", function()
        for _, msg in ipairs(refs.gameState.messages or {}) do if msg.notify then msg.read = true end end
        refs.messageCenterSignature = nil; M.refresh(refs, gameUI)
    end)
    refs.messageCenterClose = button("inboxCloseBtn", "关闭", function() gameUI.hideMessageCenter() end)
    refs.messageCenterBox = UI.Panel {
        id = "messageCenterBox", width = 460, height = "100%", padding = 12, gap = 8,
        backgroundColor = C.bg, borderRadius = 8, borderWidth = 1, borderColor = C.line,
        pointerEvents = "auto", onClick = function() end,
        children = {
            UI.Panel { width = "100%", flexDirection = "row", alignItems = "center", justifyContent = "space-between",
                children = { UI.Label { text = "国事簿", fontSize = 18, fontFamily = "gufeng", fontColor = C.gold }, refs.messageCenterClose } },
            UI.Panel { width = "100%", flexDirection = "row", gap = 8,
                children = { refs.messageCenterEventTab, refs.messageCenterNoticeTab, refs.messageMarkAll } },
            UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0, scrollY = true, children = { refs.messageCenterRows } },
        },
    }
    refs.messageCenterOverlay = UI.Panel {
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0, padding = 6,
        pointerEvents = "auto", alignItems = "flex-start", onClick = function() gameUI.hideMessageCenter() end,
        children = { refs.messageCenterBox },
    }
    refs.messageCenterOverlay:Hide()
    -- 待办/消息摘要（messageSummaries）不在这里 —— 见上方注释，它由 GameUI 放到 root 最底层
    refs.eventNoticeBar = UI.Panel { position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        pointerEvents = "box-none", children = { refs.noticeToast, refs.messageCenterOverlay } }

    gameUI.showMessageCenter = function(tab)
        gameUI.openNavigation("inbox")
        refs.messageCenterTab = tab or "events"
        refs.messageCenterSignature = nil
        M.refresh(refs, gameUI)
        refs.messageCenterOverlay:Show()
    end
    gameUI.hideMessageCenter = function() refs.messageCenterOverlay:Hide() end
    gameUI.refreshNoticeBar = function() M.refresh(refs, gameUI) end
    gameUI.updatePendingEvent = function(list, autoPopup)
        gameUI.pendingList_ = list or {}
        M.refresh(refs, gameUI)
        local pending = gameUI.pendingList_[1]
        if pending then
            local eid = pending.def and (pending.def.id or pending.def.title)
            if autoPopup and not gameUI.isEventDialogVisible() and gameUI.autoPoppedId_ ~= eid then
                gameUI.autoPoppedId_ = eid
                gameUI.openEventByIndex(1)
            end
        else
            gameUI.autoPoppedId_ = nil
            if gameUI.isEventDialogVisible() then gameUI.hideEventDialog() end
        end
    end
    return refs.eventNoticeBar
end

function M.refresh(refs, gameUI)
    if not refs.messageCenterRows then return end
    if not refs.messageCenterSignature and refs.navigationMetrics then
        M.layout(refs, refs.navigationMetrics)
    end
    local pending = gameUI.pendingList_ or {}
    local messages = refs.gameState and refs.gameState.messages or {}
    local groups = groupsOf(messages)
    local unread = 0
    for _, g in ipairs(groups) do unread = unread + #g.messages end
    refs.eventSummary:SetText("待办 " .. tostring(#pending))
    refs.noticeSummary:SetText("消息 " .. tostring(unread))
    refs.eventSummary:SetVisible(#pending > 0)
    refs.noticeSummary:SetVisible(unread > 0)
    local busy = refs.navigation and refs.navigation:IsVisible()
    for _, name in ipairs({ "selfPanel", "courtPanel", "diploOverlay", "policyPanel", "techPanel", "armyPanel", "settingsOverlay", "speedMenu", "economyPanel" }) do
        if refs[name] and refs[name]:IsVisible() then busy = true end
    end
    refs.messageSummaries:SetVisible(not busy and not refs.messageCenterOverlay:IsVisible())
    -- 新消息只短暂提示；超时不标已读，之后仍可从消息簿查看。
    local latest
    for i = #messages, 1, -1 do if messages[i].notify then latest = messages[i]; break end end
    if latest and latest ~= refs.lastToastMessage then
        refs.lastToastMessage, refs.noticeToastMessage = latest, latest
        refs.noticeToastUntil = clock() + 5
        refs.noticeToast:SetText(tostring(latest.text):gsub("（[^）]*）", ""))
    end
    refs.noticeToast:SetVisible(latest ~= nil and not latest.read and not busy
        and not refs.messageCenterOverlay:IsVisible() and clock() < (refs.noticeToastUntil or 0))
    local signature = refs.messageCenterTab .. ":" .. #pending .. ":" .. unread
    for _, p in ipairs(pending) do signature = signature .. ":" .. tostring(p) .. ":" .. tostring(p.def and p.def.id) end
    for _, g in ipairs(groups) do signature = signature .. ":" .. tostring(g.latest) .. ":" .. tostring(g.text) .. ":" .. #g.messages end
    if refs.messageCenterSignature == signature then return end
    refs.messageCenterSignature = signature
    refs.messageMarkAll:SetVisible(refs.messageCenterTab == "notices" and unread > 0)
    refs.messageCenterRows:ClearChildren()
    if refs.messageCenterTab == "events" then
        for i, p in ipairs(pending) do
            local idx = i
            refs.messageCenterRows:AddChild(button("pendingEvent_" .. i, tostring(p.def and p.def.title or "待办"), function()
                gameUI.hideMessageCenter(); gameUI.openEventByIndex(idx)
            end, "100%"))
        end
        if #pending == 0 then refs.messageCenterRows:AddChild(UI.Label { text = "暂无需要决策的国事", fontSize = 13, fontColor = C.muted }) end
    else
        for i, g in ipairs(groups) do
            refs.messageCenterRows:AddChild(button("inboxMessage_" .. i,
                tostring(g.text) .. (#g.messages > 1 and (" ×" .. #g.messages) or ""), function()
                    for _, msg in ipairs(g.messages) do msg.read = true end
                    gameUI.showNoticeDialog(g.latest); refs.messageCenterSignature = nil
                end, "100%"))
        end
        if unread == 0 then refs.messageCenterRows:AddChild(UI.Label { text = "暂无未读消息，历史记录保留在大事记", fontSize = 13, fontColor = C.muted }) end
    end
    for _, row in ipairs(refs.messageCenterRows.children) do
        if row.className == "Button" then row:SetStyle({ width = "100%", height = NavigationHUD.touchSize(56), fontSize = 12 * (refs.navigationMetrics and refs.navigationMetrics.factor or 1) }) end
    end
end

function M.layout(refs, m)
    local f = m.factor
    refs.eventNoticeBar:SetStyle({ top = m.top, left = m.left, right = m.right, bottom = m.bottom })
    -- ⚠️ 待办摘要现在直挂 root（最底层）→ 坐标要自己加安全区偏移，
    --    否则会贴在 (6,6) 压住国旗按钮（2026-10-05 加 root 时踩过）
    refs.messageSummaries:SetStyle({ top = m.top + 6 * f, left = m.left + 6 * f, gap = 8 * f, height = 48 * f })
    refs.eventSummary:SetStyle({ width = 88 * f, height = 48 * f, fontSize = 11 * f })
    refs.noticeSummary:SetStyle({ width = 88 * f, height = 48 * f, fontSize = 11 * f })
    if m.narrow then
        refs.noticeToast:SetStyle({ top = 60 * f, right = 6 * f, width = m.contentW - 12 * f, height = 48 * f, fontSize = 11 * f })
    else
        refs.noticeToast:SetStyle({ top = 6 * f, right = 6 * f, width = math.min(320 * f, m.contentW * 0.46), height = 48 * f, fontSize = 11 * f })
    end
    refs.messageCenterOverlay:SetStyle({ padding = 6 * f })
    refs.messageCenterBox:SetStyle({ width = m.contentW - 12 * f, padding = 12 * f })
    local tabWidth = math.min(92 * f, (math.min(500 * f, m.contentW - 12 * f) - 44 * f) / 3)
    for _, btn in ipairs({ refs.messageCenterEventTab, refs.messageCenterNoticeTab, refs.messageMarkAll }) do
        btn:SetStyle({ width = tabWidth, height = 48 * f, fontSize = 11 * f })
    end
    refs.messageCenterClose:SetStyle({ width = 72 * f, height = 48 * f, fontSize = 12 * f })
end

return M

-- 国旗打开临时政务菜单；不再为底栏或侧栏永久占用地图空间。
-- 触控区按 DPR / UI 缩放换算，保持手机上至少 48 个逻辑像素。
local UI = require("urhox-libs/UI")
local CharacterSystem = require("systems.CharacterSystem")
local Resources = require("data.Resources")

local M = {}
local C = {
    surface = { 27, 25, 23, 252 }, idle = { 37, 34, 30, 255 },
    active = { 78, 61, 34, 255 }, pressed = { 95, 74, 40, 255 },
    line = { 121, 101, 65, 200 }, gold = { 230, 199, 137, 255 },
    text = { 240, 232, 211, 255 }, muted = { 174, 165, 146, 255 },
}

M.PORTRAITS = {
    { key = "emperor", name = "帝王", path = "image/full_emperor_20260930061735.png" },
    { key = "scholar", name = "文士", path = "image/full_scholar_20260930061741.png" },
    { key = "wenwu", name = "文武", path = "image/full_wenwu_20260930061736.png" },
}

function M.portraitOf(character)
    for _, p in ipairs(M.PORTRAITS) do
        if character and character.portraitKey == p.key then return p end
    end
    return M.PORTRAITS[1]
end

function M.portraitWidget(id, fullBody)
    return UI.Panel {
        id = id, overflow = "hidden", pointerEvents = "none", borderRadius = 6,
        backgroundColor = { 52, 47, 37, 255 },
        children = { UI.Panel {
            id = id .. "Image", position = "absolute",
            left = fullBody and 0 or -34, top = fullBody and 0 or -3,
            width = fullBody and "100%" or 104, height = fullBody and "100%" or 185,
            backgroundImage = M.PORTRAITS[1].path, backgroundFit = "contain", pointerEvents = "none",
        } },
    }
end

function M.touchSize(cssPixels)
    return math.ceil(cssPixels * graphics:GetDPR() / math.max(0.01, UI.GetScale()))
end

function M.metrics()
    local w, h = UI.GetWidth(), UI.GetHeight()
    local f = math.max(1, graphics:GetDPR()) / math.max(0.01, UI.GetScale())
    local safe = UI.GetSafeAreaInsets()
    local narrow = (w - safe.left - safe.right) / f < 580
    local top = safe.top + (narrow and 100 or 52) * f
    return {
        width = w, height = h, factor = f, safe = safe, narrow = narrow,
        top = top, left = safe.left, right = safe.right, bottom = safe.bottom,
        contentW = w - safe.left - safe.right, contentH = h - top - safe.bottom, gutter = 8 * f,
    }
end

local function button(id, text, fn)
    return UI.Button {
        id = id, text = text, height = 48, padding = 0, fontSize = 12, fontFamily = "gufeng",
        textColor = C.text, backgroundColor = C.idle, hoverBackgroundColor = C.active,
        pressedBackgroundColor = C.pressed, borderRadius = 6, borderWidth = 1, borderColor = C.line,
        glowShadow = false, flexShrink = 0, onClick = fn,
    }
end

function M.create(refs, callbacks, openPanel)
    refs.navButtons, refs.navLabels, refs.navDecorations, refs.topStats = {}, {}, {}, {}
    refs.topFlagFactionId = nil
    refs.topFlagSlot = UI.Panel { width = 40, height = 40, pointerEvents = "none",
        justifyContent = "center", alignItems = "center" }
    refs.topNation = UI.Label { text = "观战", fontFamily = "gufeng", fontSize = 12, fontColor = C.gold }
    refs.flagMenuIndicator = UI.Label { text = "▼", fontSize = 8, fontColor = C.gold }
    refs.flagMenuBtn = button("flagMenuBtn", "", function() callbacks.onMenuToggle() end)
    refs.flagMenuBtn:SetStyle({ width = 60, backgroundColor = C.surface, borderWidth = 0 })
    refs.flagMenuBtn:AddChild(UI.Panel { pointerEvents = "none", width = "100%", height = "100%",
        flexDirection = "column", alignItems = "center", justifyContent = "center",
        children = { refs.topFlagSlot, refs.topNation, refs.flagMenuIndicator } })

    local icons = {
        pop = "image/icon_pol_编户齐民.png", gold = "image/icon_tech_度量衡.png",
        food = "image/icon_tech_井田农耕.png", army = "image/icon_war_双剑交叉.png",
        prestige = "image/icon_era_春秋礼乐.png",
    }
    refs.hudResources = UI.Panel { flexDirection = "row", alignItems = "center", gap = 6 }
    for _, d in ipairs(Resources.list()) do
        if d.show then
            local color = { d.color[1] or 200, d.color[2] or 200, d.color[3] or 200, d.color[4] or 255 }
            local value = UI.Label { text = "0", fontSize = 12, fontColor = color, maxLines = 1, whiteSpace = "nowrap" }
            local name = UI.Label { text = d.name, fontSize = 8, fontColor = C.muted, maxLines = 1 }
            local icon = UI.Panel { width = 22, height = 26, backgroundImage = icons[d.id], backgroundFit = "contain", pointerEvents = "none" }
            local item = button("hudResource_" .. d.id, "", function() openPanel("economy") end)
            item:SetStyle({ width = 84, borderWidth = 0, backgroundColor = { 0, 0, 0, 0 }, borderRadius = 0 })
            item:AddChild(UI.Panel { pointerEvents = "none", width = "100%", height = "100%",
                flexDirection = "row", alignItems = "center", justifyContent = "center", gap = 4,
                children = { icon, UI.Panel { pointerEvents = "none", children = { name, value } } } })
            refs.topStats[d.id] = { panel = item, value = value, name = name, icon = icon }
            refs.hudResources:AddChild(item)
        end
    end
    refs.hudResourceScroll = UI.ScrollView { height = 48, flexGrow = 1, flexBasis = 0, flexShrink = 1,
        scrollX = true, scrollY = false, showScrollbar = false, children = { refs.hudResources } }
    refs.pauseIcon = UI.Label { text = "Ⅱ", fontFamily = "sans", fontSize = 19, fontColor = C.gold }
    refs.pauseBtn = UI.Panel { id = "hudPauseBtn", width = 32, height = 48, pointerEvents = "none",
        alignItems = "center", justifyContent = "center", children = { refs.pauseIcon } }
    refs.topDate = UI.Label { id = "topDateBtn", text = "历日", width = 150, height = 48,
        fontSize = 11, fontFamily = "gufeng", fontColor = C.text, textAlign = "center", verticalAlign = "middle",
        pointerEvents = "none", maxLines = 1 }
    refs.speedBar = UI.Label { id = "topSpeedBtn", text = "速度 3/7", width = 66, height = 48,
        fontSize = 10, fontFamily = "gufeng", fontColor = C.text, textAlign = "center", verticalAlign = "middle",
        pointerEvents = "auto", onClick = function() openPanel("speed") end,
        onPointerCancel = function(event) refs.hudTimeGroup:OnPointerCancel(event) end }
    -- 暂停、历日和速度共享同一背景与反馈；速度点击不冒泡到暂停操作。
    refs.hudTimeGroup = UI.Button {
        id = "hudTimeGroup", height = 48, padding = 0, flexDirection = "row", alignItems = "center", flexShrink = 0,
        backgroundColor = C.surface, hoverBackgroundColor = C.active, pressedBackgroundColor = C.pressed,
        borderLeftWidth = 1, borderLeftColor = C.line, borderRadius = 6, glowShadow = false,
        onClick = function() if callbacks.onPauseToggle then callbacks.onPauseToggle() end end,
        children = { refs.pauseBtn, refs.topDate, refs.speedBar },
    }
    -- 顶栏「设置」入口（2026-10-05 用户："这个设置请放在名声的右边但是要距离它远一点"）：
    --   资源区是 flexGrow=1 → 名声靠左、按钮靠右，中间自然留白 = 离名声远。
    --   留白也保证名声数字将来变大（50 → 50万）时不会顶到按钮。
    refs.topBarSettingsBtn = button("topSettingsBtn", "设置", function() openPanel("settings") end)
    refs.topBarSettingsBtn:SetStyle({ flexShrink = 0 })
    refs.topBar = UI.Panel {
        id = "navigationTopBar", position = "absolute", top = 0, left = 0, right = 0, height = 56,
        flexDirection = "row", alignItems = "center", gap = 6, paddingHorizontal = 8,
        backgroundGradient = { direction = "to-bottom", from = { 44, 37, 28, 255 }, to = C.surface },
        borderBottomWidth = 1, borderBottomColor = C.line,
        children = { refs.flagMenuBtn, refs.hudResourceScroll, refs.topBarSettingsBtn, refs.hudTimeGroup },
    }

    refs.navPortrait = M.portraitWidget("navPortrait", false)
    refs.navRulerName = UI.Label { text = "君主", fontSize = 12, fontFamily = "gufeng", fontColor = C.gold, maxLines = 1 }
    local definitions = {
        { key = "self", label = "君主", id = "topSelfBtn" },
        { key = "court", label = "朝廷", id = "topCourtBtn", icon = "image/icon_tech_中央集权.png" },
        { key = "policy", label = "政策", id = "topPolicyBtn", icon = "image/icon_pol_编户齐民.png" },
        { key = "diplomacy", label = "外交", id = "topDiplomacyBtn", icon = "image/icon_pol_合纵连横.png" },
        { key = "army", label = "军队", id = "topArmyBtn", icon = "image/icon_war_双剑交叉.png" },
        { key = "tech", label = "研究", id = "topTechBtn", icon = "image/icon_tech_礼乐教化.png" },
    }
    refs.navRow = UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 8 }
    for _, d in ipairs(definitions) do
        local label = UI.Label { text = d.label, fontSize = 13, fontFamily = "gufeng", fontColor = C.text, maxLines = 1 }
        local icon = UI.Panel { width = 32, height = 32, backgroundImage = d.icon, backgroundFit = "contain", pointerEvents = "none" }
        refs.navLabels[d.key], refs.navDecorations[d.key] = label, icon
        local btn = button(d.id, "", function() openPanel(d.key) end)
        btn:AddChild(UI.Panel { pointerEvents = "none", width = "100%", height = "100%", paddingHorizontal = 8,
            flexDirection = "row", alignItems = "center", gap = 8,
            children = d.key == "self" and { refs.navPortrait, refs.navRulerName } or { icon, label } })
        refs.navButtons[d.key] = btn
        refs.navRow:AddChild(btn)
    end
    for _, e in ipairs(require("ui.UISlots").list("topbar.extra")) do
        refs.navRow:AddChild(button("slotbtn_" .. tostring(e.id), tostring(e.label), function()
            callbacks.onMenuClose()
            if e.panel then require("ui.UIPanelHost").open(e.panel)
            elseif type(e.onOpen) == "function" then e.onOpen() end
        end))
    end
    -- ⚠️ 菜单里的「设置」已删（2026-10-05 用户："点国旗不是会出现这个界面吗这里边就不要设置"）：
    --   顶栏最右已有设置入口（refs.topBarSettingsBtn），菜单里再来一个是重复。
    --   顺带解决一个隐患：两个按钮原来都叫 id="topSettingsBtn"，FindById 会命中错的那个。
    refs.navCloseBtn = button("navCloseBtn", "收起", function() callbacks.onMenuClose() end)
    refs.navMenuTitle = UI.Label { text = "政务", fontSize = 16, fontFamily = "gufeng", fontColor = C.gold, flexShrink = 1 }
    refs.navMenuBody = UI.Panel { width = "100%", gap = 10, children = { refs.navRow,
        UI.Panel { id = "navFooter", width = "100%", flexDirection = "row", gap = 8, children = { refs.navCloseBtn } } } }
    refs.navMenuBox = UI.Panel {
        id = "navMenuBox", width = 304, height = 300, padding = 12, gap = 8,
        backgroundColor = C.surface, borderWidth = 1, borderColor = C.line, borderRadius = 8,
        pointerEvents = "auto", onClick = function() end,
        children = { refs.navMenuTitle,
            UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0, scrollY = true, children = { refs.navMenuBody } } },
    }
    refs.navigation = UI.Panel {
        id = "mainNavigation", position = "absolute", top = 56, left = 0, right = 0, bottom = 0,
        alignItems = "flex-start", padding = 8, pointerEvents = "auto", backgroundColor = { 0, 0, 0, 0 },
        onClick = function() callbacks.onMenuClose() end, children = { refs.navMenuBox },
    }
    refs.navigation:Hide()
    print("[Navigation] 国旗菜单已创建，收起时不占地图面积")
    return refs.topBar, refs.navigation
end

function M.layout(refs)
    local m = M.metrics()
    local f, safe = m.factor, m.safe
    local signature = table.concat({ m.width, m.height, f, safe.left, safe.top, safe.right, safe.bottom }, ":")
    if refs.navigationLayoutSignature == signature then return m, false end
    refs.navigationLayoutSignature, refs.navigationMetrics = signature, m
    refs.topBar:SetStyle({ height = m.top, paddingTop = safe.top, paddingLeft = safe.left + 6 * f, paddingRight = safe.right + 6 * f, gap = 6 * f })
    refs.flagMenuBtn:SetStyle({ width = 60 * f, height = 48 * f, position = m.narrow and "absolute" or "relative",
        left = m.narrow and (safe.left + 6 * f) or 0, top = m.narrow and safe.top or 0 })
    refs.topFlagSlot:SetStyle({ width = 40 * f, height = 34 * f })
    refs.topNation:SetFontSize(11 * f)
    refs.flagMenuIndicator:SetStyle({ width = 24 * f, height = 10 * f, fontSize = 7 * f, textAlign = "center" })
    refs.hudResourceScroll:SetStyle({ position = m.narrow and "absolute" or "relative",
        left = m.narrow and (safe.left + 6 * f) or 0, top = m.narrow and (safe.top + 50 * f) or 0,
        width = m.narrow and (m.contentW - 12 * f) or "auto", height = 48 * f })
    local statW = m.narrow and math.max(48, math.min(70, (m.contentW / f - 30) / 5))
        or ((m.contentW / f < 800) and 72 or 84)
    refs.hudResources:SetStyle({ gap = 4 * f })
    for _, st in pairs(refs.topStats) do
        st.panel:SetStyle({ width = statW * f, height = 48 * f })
        st.icon:SetStyle({ width = (m.narrow and 12 or 20) * f, height = 24 * f })
        st.value:SetStyle({ fontSize = (m.narrow and 10 or 11) * f, width = (statW - (m.narrow and 18 or 26)) * f, maxLines = 1, whiteSpace = "nowrap" })
        st.name:SetFontSize(8 * f)
    end
    refs.hudTimeGroup:SetStyle({ position = m.narrow and "absolute" or "relative", height = 48 * f,
        left = m.narrow and (safe.left + 66 * f) or 0, top = m.narrow and safe.top or 0,
        paddingLeft = 0 })
    -- 时间组紧凑化（2026-10-05 用户："他们能够更紧凑一点吗但是要保证哪怕过很久这个也不会超出多少
    --   要不要把字变得小然后并且变得紧凑"）：暂停 32→26、日期 150→118、速度 66→48，字各降 1 号。
    --   纪元变大时由 updateTopBarDateFit()（NavigationHUD）按实测宽度缩字号，不溢出。
    refs.pauseBtn:SetStyle({ width = 26 * f, height = 48 * f })
    refs.pauseIcon:SetFontSize(15 * f)
    refs.topDate:SetStyle({ width = (m.narrow and math.max(78, math.min(100, m.contentW / f - 210)) or 118) * f,
        height = 48 * f, fontSize = (m.narrow and 8 or 9) * f })
    refs.speedBar:SetStyle({ width = 46 * f, height = 48 * f, fontSize = 8 * f })
    if refs.topBarSettingsBtn then refs.topBarSettingsBtn:SetStyle({ width = 56 * f, height = 48 * f, fontSize = 12 * f }) end
    refs.navigation:SetStyle({ top = m.top, left = m.left, right = m.right, bottom = m.bottom, padding = 6 * f })
    local boxW = m.contentW - 12 * f
    refs.navMenuBox:SetStyle({ width = boxW, height = m.contentH - 12 * f, padding = 12 * f, gap = 8 * f })
    refs.navMenuTitle:SetFontSize(16 * f)
    refs.navRow:SetStyle({ gap = 8 * f })
    local footer = refs.navMenuBox:FindById("navFooter")
    if footer then footer:SetHeight(48 * f) end
    local columns = m.narrow and 2 or 3
    for _, btn in ipairs(refs.navRow.children) do btn:SetStyle({ width = (boxW - (28 + (columns - 1) * 8) * f) / columns, height = 48 * f }) end
    -- 设置按钮已删，只剩「收起」→ 占满整行（原来是两个各占一半）
    refs.navCloseBtn:SetStyle({ width = boxW - 24 * f, height = 48 * f, fontSize = 12 * f })
    for key in pairs(refs.navButtons) do
        refs.navLabels[key]:SetFontSize(13 * f)
        refs.navDecorations[key]:SetStyle({ width = 32 * f, height = 32 * f })
    end
    refs.navPortrait:SetStyle({ width = 36 * f, height = 42 * f })
    local image = refs.navPortrait:FindById("navPortraitImage")
    if image then image:SetStyle({ left = -34 * f, top = -3 * f, width = 104 * f, height = 185 * f }) end
    refs.navRulerName:SetFontSize(12 * f)
    print(string.format("[Navigation] 视口 %.0fx%.0f，国旗菜单收起时底部预留为 0", m.width / f, m.height / f))
    return m, true
end

-- 日期文本自适应：可用宽度不够时缩字号（下限 7），保证"过很久"（前770年 → 前7700年）
-- 也不会溢出被截断（2026-10-05 用户："要保证哪怕过很久这个也不会超出多少"）。
-- ⚠️ 不能全局开 UI.defaultAutoFitText —— 那会影响所有文字（它默认只在 i18n 时开）。
function M.fitDateText(refs)
    local lbl = refs.topDate
    if not lbl then return end
    local text = lbl:GetText() or ""
    if text == "" then return end
    local box = lbl:GetAbsoluteLayout()
    if not box or box.w <= 0 then return end
    local f = (refs.navigationMetrics and refs.navigationMetrics.factor) or 1
    local family = "gufeng"
    -- ⚠️ 从**布局当前字号**起算，只缩不放（写死 11 会把布局设的 10 号顶回去）
    local size = (lbl.props and lbl.props.fontSize) or 9 * f
    while size > 7 * f do
        -- 留 18px 安全边距：MeasureTextFit 的估算比实际渲染偏小（2026-10-05 实测仍贴边）
        local r = UI.MeasureTextFit(text, { fontSize = size, fontFace = family, width = 1e9, height = 1e9 })
        if not (r and r.width) or r.width <= box.w - 18 * f then break end
        size = size - 1 * f
    end
    lbl:SetFontSize(size)
end

function M.updatePortrait(refs, gs)
    local pf = gs.playerFactionId and gs.factions[gs.playerFactionId]
    if pf then CharacterSystem.ensureInit(gs) end
    local character = pf and CharacterSystem.getById(gs, pf.leaderId)
    local p = M.portraitOf(character)
    local signature = tostring(gs.playerFactionId) .. ":" .. tostring(pf and pf.leaderId) .. ":" .. p.key
    if refs.navPortraitSignature ~= signature then
        refs.navPortraitSignature = signature
        for _, id in ipairs({ "navPortraitImage", "selfPortraitImage" }) do
            local image = refs.rootPanel:FindById(id)
            if image then image:SetStyle({ backgroundImage = p.path }) end
        end
        refs.navRulerName:SetText(pf and "君主" or "观战")
        refs.navMenuTitle:SetText(pf and ((pf.fullName or pf.name or "") .. " · 政务") or "观战 · 菜单")
        refs.navButtons.self:SetDisabled(not pf or not character)
        refs.navPortrait:SetVisible(pf ~= nil)
    end
end

function M.updateActive(refs)
    local panels = { self = refs.selfPanel, court = refs.courtPanel, diplomacy = refs.diploOverlay,
        policy = refs.policyPanel, army = refs.armyPanel, tech = refs.techPanel }
    local active = ""
    for key, panel in pairs(panels) do if panel and panel:IsVisible() then active = key end end
    if refs.navigationActive == active then return end
    refs.navigationActive = active
    for key, btn in pairs(refs.navButtons) do
        btn:SetStyle({ backgroundColor = key == active and C.active or C.idle, borderColor = key == active and C.gold or C.line })
    end
end

return M

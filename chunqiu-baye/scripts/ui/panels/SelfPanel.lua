-- 君主个人面板：固定大关闭入口、可滚动内容、三套现有肖像选择。
local UI = require("urhox-libs/UI")
local NavigationHUD = require("ui.NavigationHUD")
local CharacterSystem = require("systems.CharacterSystem")
local M = {}

function M.create(ctx)
    local refs, gameUI = ctx.refs, ctx.GameUI
    refs.selfNationName = UI.Label { text = "君主", fontSize = 18, fontFamily = "gufeng", fontColor = { 230, 199, 137, 255 }, flexShrink = 1 }
    refs.selfLeaderLine = UI.Label { text = "", fontSize = 15, fontColor = { 240, 232, 211, 255 }, whiteSpace = "normal", maxLines = 2 }
    refs.selfAttrLine = UI.Label { text = "", fontSize = 13, fontColor = { 209, 198, 177, 255 }, whiteSpace = "normal", maxLines = 4 }
    refs.selfTraitLine = UI.Label { text = "", fontSize = 12, fontColor = { 185, 174, 154, 255 }, whiteSpace = "normal", maxLines = 4 }
    refs.selfPortrait = NavigationHUD.portraitWidget("selfPortrait", true)
    refs.selfPortraitChoices = UI.Panel { width = "100%", flexDirection = "row", gap = 8, flexWrap = "wrap" }
    refs.selfPortraitChoices:Hide()
    refs.selfPortraitChoiceButtons = {}
    for _, p in ipairs(NavigationHUD.PORTRAITS) do
        local image = UI.Panel { width = "100%", height = 80,
            backgroundImage = p.path, backgroundFit = "contain", pointerEvents = "none" }
        local title = UI.Label { text = p.name, fontSize = 12, fontColor = { 235, 215, 175, 255 }, textAlign = "center" }
        local button = UI.Button {
            id = "portraitChoice_" .. p.key, width = 90, height = 116, padding = 6,
            backgroundColor = { 44, 38, 30, 255 }, pressedBackgroundColor = { 97, 75, 43, 255 },
            borderWidth = 1, borderColor = { 144, 116, 69, 220 }, borderRadius = 6,
            children = { UI.Panel { pointerEvents = "none", width = "100%", height = "100%",
                justifyContent = "center", alignItems = "center", gap = 4, children = { image, title } } },
            onClick = function()
                local gs = refs.gameState
                local pf = gs and gs.playerFactionId and gs.factions[gs.playerFactionId]
                local character = pf and CharacterSystem.getById(gs, pf.leaderId)
                if not character then return end
                character.portraitKey = p.key
                refs.selfPortraitChoices:Hide()
                refs.selfPortraitRow:Show()
                refs.selfScroll:ScrollToTop()
                refs.selfPortraitChangeBtn:SetText("更换肖像")
                NavigationHUD.updatePortrait(refs, gs)
                print("[Portrait] " .. tostring(character.name) .. " 已选择 " .. p.name .. "；随人物存档保存")
            end,
        }
        refs.selfPortraitChoiceButtons[p.key] = { button = button, image = image, title = title }
        refs.selfPortraitChoices:AddChild(button)
    end
    refs.selfPortraitChangeBtn = UI.Button {
        id = "selfChangePortraitBtn", text = "更换肖像", height = 48, width = 140,
        fontSize = 12, textColor = { 239, 220, 184, 255 },
        backgroundColor = { 68, 53, 33, 255 }, pressedBackgroundColor = { 100, 77, 40, 255 },
        borderWidth = 1, borderColor = { 144, 116, 69, 220 }, borderRadius = 6,
        onClick = function()
            local show = not refs.selfPortraitChoices:IsVisible()
            refs.selfPortraitChoices:SetVisible(show)
            refs.selfPortraitRow:SetVisible(not show)
            refs.selfScroll:ScrollToTop()
            refs.selfPortraitChangeBtn:SetText(show and "返回资料" or "更换肖像")
        end,
    }
    refs.selfCloseBtn = ctx.SmallButton("X", function() gameUI.hideSelfPanel() end, { id = "selfCloseBtn" })
    refs.selfInfo = UI.Panel { flexGrow = 1, flexBasis = 0, flexShrink = 1, gap = 10,
        children = { refs.selfLeaderLine, refs.selfAttrLine, refs.selfTraitLine } }
    refs.selfPortraitRow = UI.Panel { flexDirection = "row", width = "100%", gap = 16,
        children = { refs.selfPortrait, refs.selfInfo } }
    refs.selfScroll = UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0, scrollY = true,
        children = { UI.Panel { width = "100%", gap = 12,
            children = { refs.selfPortraitRow, refs.selfPortraitChoices } } } }
    refs.selfPanelBox = UI.Panel {
        width = "92%", maxWidth = 600, height = "96%", padding = 12, gap = 8,
        backgroundColor = { 29, 27, 24, 255 }, borderWidth = 1, borderColor = { 121, 101, 65, 230 }, borderRadius = 8,
        pointerEvents = "auto", onClick = function() end,
        children = {
            UI.Panel { width = "100%", flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                children = { refs.selfNationName, refs.selfPortraitChangeBtn, refs.selfCloseBtn } },
            UI.Divider { color = { 121, 101, 65, 180 }, thickness = 1 },
            refs.selfScroll,
        },
    }
    refs.selfPanel = UI.Panel {
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center", alignItems = "center", backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto", onClick = function() gameUI.hideSelfPanel() end,
        children = { refs.selfPanelBox },
    }
    refs.selfPanel:Hide()
    return refs.selfPanel
end

function M.layout(refs, m)
    local f = m.factor
    refs.selfPanelBox:SetStyle({ maxWidth = m.contentW - 12 * f, padding = 12 * f, gap = 8 * f })
    refs.selfPortrait:SetStyle({ width = 94 * f, height = 166 * f, flexShrink = 0 })
    refs.selfPortraitRow:SetStyle({ gap = 16 * f })
    refs.selfCloseBtn:SetStyle({ width = 72 * f, height = 48 * f, fontSize = 12 * f })
    refs.selfPortraitChangeBtn:SetStyle({ width = 144 * f, height = 48 * f, fontSize = 12 * f })
    refs.selfLeaderLine:SetFontSize(13 * f)
    refs.selfAttrLine:SetFontSize(11 * f)
    refs.selfTraitLine:SetFontSize(10 * f)
    for _, choice in pairs(refs.selfPortraitChoiceButtons) do
        choice.button:SetStyle({ width = 90 * f, height = 116 * f })
        choice.image:SetHeight(80 * f)
        choice.title:SetFontSize(11 * f)
    end
end

return M

-- ============================================================================
-- CountrySelect.lua - 选择国家界面（古风卷轴风 · 手机横屏优先）
-- 布局：左=国家列表（诸侯/蛮族分组）  中=可缩放世界地图（活 Widget）  右=国家信息卡
-- 用法：
--   local CountrySelect = require("ui.CountrySelect")
--   CountrySelect.show({
--       onStart = function(factionId) ... end,   -- 点击"开局"
--       onBack  = function() ... end,            -- 点击"返回"
--   })
-- 说明：
--   * 地图 = map.MapRenderer 的 MapWidget：滚轮/双指缩放、拖拽平移、点击省份选国
--   * 选中态一律用「叠层 + opacity 切换」（库内已验证的可靠通路）
--   * 信息卡文字用 Label:SetText 更新
-- ============================================================================

local UI          = require("urhox-libs/UI")
local Factions    = require("data.Factions")
local Geography   = require("data.Geography")
local MapPack     = require("data.MapPack")
local MapRenderer = require("map.MapRenderer")

local CountrySelect = {}

-- ---------------------------------------------------------------------------
-- 分组与评估工具
-- ---------------------------------------------------------------------------

--- 蛮族名特征（按字匹配）
local TRIBAL_KEYS = { "狄", "戎", "胡", "蛮", "夷", "濮" }

local function isTribal(name)
    if type(name) ~= "string" then return false end
    for _, k in ipairs(TRIBAL_KEYS) do
        if name:find(k, 1, true) then return true end
    end
    return false
end

--- 难度星级（按省份数粗估 1~5）
local function starCount(f)
    local n = #(f.provinces or {})
    if n >= 10 then return 5 end
    if n >= 7 then return 4 end
    if n >= 4 then return 3 end
    if n >= 2 then return 2 end
    return 1
end

local function starText(n)
    return string.rep("★", n) .. string.rep("☆", 5 - n)
end

--- 性格倾向 → 一句话简介
local PERSONA_DESC = {
    ["霸者"] = "志在争霸，逐鹿中原之上选。",
    ["守成"] = "稳守基业，徐图进取。",
    ["求存"] = "夹缝求存，事强而安。",
    ["掠夺"] = "化外劲旅，铁蹄四处。",
}

local function personaDesc(f)
    return PERSONA_DESC[f.aiPersonality or ""] or "乱世诸侯，前景未知。"
end

-- ---------------------------------------------------------------------------
-- 主入口
-- ---------------------------------------------------------------------------
---@param opts table { onStart=function(factionId), onBack=function() }
function CountrySelect.show(opts)
    opts = opts or {}

    -- 数据准备（仅列有领地的势力；诸侯/蛮族分组，组内按领土排序）
    local lords, tribes = {}, {}
    for _, f in ipairs(Factions.data or {}) do
        if f.provinces and #f.provinces > 0 then
            if isTribal(f.name) then
                tribes[#tribes + 1] = f
            else
                lords[#lords + 1] = f
            end
        end
    end
    table.sort(lords,  function(a, b) return #a.provinces > #b.provinces end)
    table.sort(tribes, function(a, b) return #a.provinces > #b.provinces end)

    -- 布局常量
    local PAD, HEADER_H, GAP = 12, 44, 10
    local LEFT_W, RIGHT_W = 268, 264

    -- 选中态引用
    local selected = nil
    local selHighlights = {}   -- [factionId] 列表高亮叠层
    local emblemPanels = {}    -- [factionId] 信息卡色徽
    local mapWidget = nil      -- 中栏活地图（稍后创建）

    -- 信息卡文字引用（upvalue，select 时 SetText 更新）
    local infoNameLabel, infoFullLabel
    local infoProvLabel, infoArmyLabel, infoGoldLabel, infoFoodLabel
    local infoPersonaLabel, infoStarsLabel, infoDescLabel

    local function updateInfo(f)
        infoNameLabel:SetText(f.name or ("#" .. tostring(f.id)))
        infoFullLabel:SetText(f.fullName or "")
        infoProvLabel:SetText(tostring(#(f.provinces or {})))
        infoArmyLabel:SetText(string.format("%d", f.armySize or 0))
        infoGoldLabel:SetText(string.format("%d", f.gold or 0))
        infoFoodLabel:SetText(string.format("%d", f.food or 0))
        infoPersonaLabel:SetText(f.aiPersonality or "未知")
        infoStarsLabel:SetText(starText(starCount(f)))
        infoDescLabel:SetText(personaDesc(f))
    end

    local function select(f)
        if selected and f.id == selected.id then return end
        if selected then
            local h = selHighlights[selected.id]
            if h then h:SetStyle({ opacity = 0 }) end
            local e = emblemPanels[selected.id]
            if e then e:SetStyle({ opacity = 0 }) end
        end
        selected = f
        local h = selHighlights[f.id]
        if h then h:SetStyle({ opacity = 1 }) end
        local e = emblemPanels[f.id]
        if e then e:SetStyle({ opacity = 1 }) end
        updateInfo(f)
        -- 镜头对焦该国全境（自动中心+适配缩放；未布局完成时静默失败=保持全图）
        if mapWidget and f.provinces and #f.provinces > 0 then
            mapWidget:focusTerritory(f.provinces)
        end
    end

    -- -------------------------------------------------------------------------
    -- 左栏：国家列表
    -- -------------------------------------------------------------------------
    local function groupHeader(text)
        return UI.Panel {
            width = "100%", height = 26, alignItems = "center", paddingLeft = 4,
            children = {
                UI.Label { text = text, fontSize = 13, fontFamily = "gufeng",
                           fontWeight = "bold", fontColor = { 214, 182, 120, 255 } },
            },
        }
    end

    local function buildItem(f)
        local hl = UI.Panel {
            position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
            backgroundColor = { 226, 192, 120, 110 }, borderRadius = 8, opacity = 0,
        }
        selHighlights[f.id] = hl
        return UI.Button {
            width = "100%", height = 42, marginBottom = 4,
            backgroundColor = { 0, 0, 0, 0 },
            hoverBackgroundColor = { 236, 214, 160, 36 },
            pressedBackgroundColor = { 0, 0, 0, 0 },
            borderRadius = 8,
            onClick = function() select(f) end,
            children = {
                hl,
                UI.Panel {
                    flexDirection = "row", alignItems = "center", gap = 8,
                    width = "100%", paddingLeft = 8, paddingRight = 8,
                    children = {
                        UI.Panel { width = 18, height = 18, borderRadius = 9,
                                   backgroundColor = f.color or { 150, 150, 150, 255 } },
                        UI.Label { text = f.name or "?", fontSize = 13, width = 88,
                                   fontFamily = "gufeng",
                                   fontWeight = "bold", fontColor = { 242, 228, 196, 255 } },
                        UI.Panel { flexGrow = 1 },
                        UI.Label { text = string.format("省%d·兵%d", #(f.provinces or {}), f.armySize or 0),
                                   fontSize = 10, width = 104, textAlign = "right",
                                   fontColor = { 214, 200, 170, 215 } },
                    },
                },
            },
        }
    end

    local listChildren = {}
    listChildren[#listChildren + 1] = groupHeader("诸侯列国")
    for _, f in ipairs(lords) do listChildren[#listChildren + 1] = buildItem(f) end
    if #tribes > 0 then
        listChildren[#listChildren + 1] = groupHeader("蛮族部族")
        for _, f in ipairs(tribes) do listChildren[#listChildren + 1] = buildItem(f) end
    end

    -- -------------------------------------------------------------------------
    -- 中栏：活地图 Widget（缩放/拖拽/点选） + 悬浮控件
    -- -------------------------------------------------------------------------
    mapWidget = MapRenderer.create(nil)   -- 选国阶段尚无 GameState，内部已做空值保护
    mapWidget.onProvinceClick = function(provId)
        if not provId then return end
        local fid = Factions.getFactionByProvince(provId)
        local f = fid and Factions.getById(fid)
        if f then select(f) end
    end

    local mapOverlay = {
        -- 操作提示（左下）
        UI.Panel {
            position = "absolute", left = 8, bottom = 8,
            backgroundColor = { 10, 10, 14, 170 }, borderRadius = 6,
            paddingLeft = 8, paddingRight = 8, paddingTop = 4, paddingBottom = 4,
            children = {
                UI.Label { text = "滚轮/双指缩放 · 拖动平移 · 点击国家", fontSize = 10, width = 240,
                           fontColor = { 235, 225, 200, 175 } },
            },
        },
        -- 全图按钮（右上）
        UI.Button {
            position = "absolute", right = 8, top = 8, width = 92, height = 28,
            backgroundColor = { 15, 15, 20, 200 },
            hoverBackgroundColor = { 40, 40, 48, 220 },
            borderRadius = 6,
            onClick = function()
                if mapWidget then
                    mapWidget.camX = Geography.MAP_W * 0.5
                    mapWidget.camY = Geography.MAP_H * 0.5
                    mapWidget.zoom = MapPack.INITIAL_ZOOM or 0.2
                    mapWidget.targetZoom = mapWidget.zoom
                end
            end,
            children = {
                UI.Panel { width = "100%", height = "100%", justifyContent = "center",
                           alignItems = "center",
                           children = { UI.Label { text = "全图", fontSize = 12, width = 56,
                                textAlign = "center",
                                fontFamily = "gufeng", fontColor = { 235, 220, 185, 235 } } } },
            },
        },
    }

    -- 地图面板：Widget 在下，悬浮控件在上
    local mapPanel = UI.Panel {
        flexGrow = 1, borderRadius = 10,
        children = { mapWidget },
    }
    for _, w in ipairs(mapOverlay) do
        mapPanel:AddChild(w)
    end

    -- -------------------------------------------------------------------------
    -- 右栏：国家信息卡（羊皮纸）
    -- -------------------------------------------------------------------------
    local function emblemStack()
        local base = UI.Panel {
            width = 46, height = 46,
            backgroundColor = { 236, 220, 180, 70 }, borderRadius = 23,
        }
        for _, f in ipairs(Factions.data or {}) do
            if f.provinces and #f.provinces > 0 then
                local first = "?"
                if type(f.name) == "string" and #f.name > 0 then
                    first = f.name:sub(1, 1)
                end
                local ep = UI.Panel {
                    position = "absolute", left = 0, top = 0, width = 46, height = 46,
                    borderRadius = 23, backgroundColor = f.color or { 150, 150, 150, 255 },
                    opacity = 0,
                    justifyContent = "center", alignItems = "center",
                    children = {
                        UI.Label { text = first, fontSize = 22, fontFamily = "gufeng",
                                   fontWeight = "bold", fontColor = { 30, 22, 12, 255 } },
                    },
                }
                emblemPanels[f.id] = ep
                base:AddChild(ep)
            end
        end
        return base
    end

    local function statRow(labelText, valueWidget)
        return UI.Panel {
            flexDirection = "row", alignItems = "center", width = "100%", gap = 8,
            children = {
                UI.Label { text = labelText, fontSize = 12, fontColor = { 96, 74, 46, 240 }, width = 52 },
                valueWidget,
            },
        }
    end

    local function newStatValue()
        return UI.Label { text = "-", fontSize = 15, fontWeight = "bold", fontColor = { 40, 26, 14, 255 } }
    end

    infoProvLabel  = newStatValue()
    infoArmyLabel  = newStatValue()
    infoGoldLabel  = newStatValue()
    infoFoodLabel  = newStatValue()

    infoNameLabel    = UI.Label { text = "-", fontSize = 24, fontFamily = "gufeng",
                                  fontWeight = "bold", fontColor = { 40, 26, 14, 255 } }
    infoFullLabel    = UI.Label { text = "-", fontSize = 12, fontColor = { 96, 74, 46, 235 } }
    infoPersonaLabel = UI.Label { text = "-", fontSize = 13, fontWeight = "bold",
                                  fontColor = { 150, 90, 30, 255 } }
    infoStarsLabel   = UI.Label { text = "-", fontSize = 15, fontColor = { 178, 60, 45, 255 } }
    infoDescLabel    = UI.Label { text = "-", fontSize = 12, fontColor = { 96, 74, 46, 235 } }

    local infoCard = UI.Panel {
        width = RIGHT_W,
        backgroundImage = "image/panel_parchment_20260901161208.png",
        backgroundFit = "fill",
        borderRadius = 10,
        padding = 14,
        flexDirection = "column",
        alignItems = "center",
        gap = 6,
        children = {
            emblemStack(),
            infoNameLabel,
            infoFullLabel,
            UI.Panel { width = "100%", height = 1, backgroundColor = { 120, 95, 60, 80 } },
            statRow("省 份", infoProvLabel),
            statRow("兵 员", infoArmyLabel),
            statRow("金 ", infoGoldLabel),
            statRow("粮 ", infoFoodLabel),
            statRow("倾 向", infoPersonaLabel),
            statRow("难 度", infoStarsLabel),
            infoDescLabel,
            UI.Panel { flexGrow = 1 },
            UI.Button {
                width = "100%", height = 46,
                backgroundColor = { 0, 0, 0, 0 },
                hoverBackgroundColor = { 0, 0, 0, 0 },
                pressedBackgroundColor = { 0, 0, 0, 0 },
                backgroundImage = "image/btn_scroll_normal.png",
                backgroundFit = "fill",
                pressedBackgroundImageOpacity = 0.55,
                onClick = function()
                    if selected and opts.onStart then opts.onStart(selected.id) end
                end,
                children = {
                    UI.Panel {
                        flexDirection = "row", justifyContent = "center", alignItems = "center",
                        width = "100%", height = "100%",
                        children = {
                            UI.Label { text = "开　局", fontSize = 20, fontFamily = "gufeng",
                                       fontWeight = "bold", fontColor = { 56, 36, 18, 255 } },
                        },
                    },
                },
            },
        },
    }

    -- -------------------------------------------------------------------------
    -- 组装
    -- -------------------------------------------------------------------------
    local root = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 16, 14, 11, 255 },
        padding = PAD,
        flexDirection = "column",
        children = {
            -- 顶栏
            UI.Panel {
                width = "100%", height = HEADER_H, flexDirection = "row",
                alignItems = "center", marginBottom = 4,
                children = {
                    UI.Button {
                        width = 112, height = 32,
                        backgroundColor = { 238, 220, 180, 26 },
                        hoverBackgroundColor = { 238, 220, 180, 52 },
                        borderRadius = 8,
                        onClick = function()
                            if opts.onBack then opts.onBack() end
                        end,
                        children = {
                            UI.Panel { width = "100%", height = "100%", justifyContent = "center",
                                       alignItems = "center",
                                       children = { UI.Label { text = "‹返回", fontSize = 13, width = 84,
                                            textAlign = "center",
                                            fontFamily = "gufeng", fontColor = { 238, 222, 190, 235 } } } },
                        },
                    },
                    UI.Panel { width = 12 },
                    UI.Panel { flexGrow = 1, alignItems = "center", children = {
                        UI.Label { text = "选择你的国家", fontSize = 22, fontFamily = "gufeng",
                                   fontWeight = "bold", fontColor = { 240, 210, 120, 255 } },
                    } },
                    UI.Panel { width = 88 },
                },
            },
            -- 三栏主体
            UI.Panel {
                width = "100%", flexGrow = 1, flexBasis = 0,
                flexDirection = "row", gap = GAP,
                children = {
                    -- 左：列表
                    UI.Panel {
                        width = LEFT_W, backgroundColor = { 238, 220, 180, 16 },
                        borderRadius = 10, padding = 8,
                        children = {
                            UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0,
                                            children = listChildren },
                        },
                    },
                    -- 中：活地图（Widget 在下，悬浮控件在上）
                    mapPanel,
                    -- 右：信息卡
                    infoCard,
                },
            },
        },
    }

    -- 默认选中：诸侯首位（领土最大）
    local first = lords[1] or tribes[1]
    if first then select(first) end

    UI.SetRoot(root)
end

return CountrySelect

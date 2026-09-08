-- ============================================================================
-- GameUI.lua — 春秋霸业 游戏 UI 覆盖层（手机版 v2）
--
-- 布局（手机优先，2026-08-29 定稿；2026-08-31 时间区改为大筐+中文档名，排行/日志按钮暂移除）：
--   顶部    ：资源条（国家名、金/粟/兵力/威望/稳定度、时间大筐、速度档、设置）
--   右侧    ：省份面板（信息 + 操作按钮：征兵/调军/宣战）
--   右下角  ：战争列表（每场战争一条：敌方名 + 战争分数条，绿=优 红=劣）
--   弹窗    ：排行榜、外交、日志（半透明遮罩 + 居中窗口）
--   消息    ：不再常驻屏幕（解决挡地图问题），全部进日志面板
-- ============================================================================

local UI = require("urhox-libs/UI")
local WarSystem = require("systems.WarSystem")
local GameConfig = require("config.GameConfig")
local PolicySystem = require("systems.PolicySystem")
local MusicManager = require("audio.MusicManager")

local GameUI = {}

-- ============================================================
-- Style Constants
-- ============================================================
local COLORS = {
    bgDark          = { 20, 25, 35, 230 },
    bgPanel         = { 20, 25, 35, 240 },
    border          = { 60, 70, 90, 200 },
    textPrimary     = { 255, 255, 255, 255 },
    textSecondary   = { 180, 190, 210, 200 },
    gold            = { 255, 200, 50, 255 },
    food            = { 120, 200, 80, 255 },
    army            = { 200, 100, 100, 255 },
    prestige        = { 220, 180, 255, 255 },
    stability       = { 80, 160, 220, 255 },
    btnDefault      = { 45, 55, 75, 230 },
    btnHover        = { 60, 75, 100, 240 },
    btnDanger       = { 160, 50, 50, 230 },
    btnDangerHover  = { 190, 60, 60, 240 },
    btnSuccess      = { 50, 130, 70, 230 },
    btnSuccessHover = { 60, 155, 80, 240 },
    relEnemy        = { 200, 60, 60, 255 },
    relNeutral      = { 200, 180, 60, 255 },
    relFriendly     = { 60, 180, 80, 255 },
    stabilityFill   = { 80, 160, 220, 255 },
    transparent     = { 0, 0, 0, 0 },
    msgBg           = { 15, 18, 28, 180 },
    warGood         = { 60, 200, 90, 255 },
    warBad          = { 220, 60, 60, 255 },
}

-- 速度档位按钮配色：普通态亮蓝灰+浅边框（与顶栏深底拉开对比）/ 当前档位金色高亮
local SPEED_BTN_NORMAL = {
    bg      = { 74, 94, 124, 255 },
    hover   = { 96, 118, 152, 255 },
    pressed = { 56, 72, 98, 255 },
    border  = { 150, 170, 200, 180 },
}
local SPEED_BTN_ACTIVE = {
    bg       = { 255, 200, 50, 255 },
    hover    = { 255, 215, 90, 255 },
    pressed  = { 230, 180, 40, 255 },
    textColor = { 30, 25, 10, 255 },
}

local SEASON_ICONS = {
    ["春"] = "🌸",
    ["夏"] = "☀️",
    ["秋"] = "🍂",
    ["冬"] = "❄️",
}

-- ============================================================
-- Internal widget references (populated in create)
-- ============================================================
local refs = {}

-- ============================================================
-- Helper: small styled button (手机触控 ≥ 36px)
-- ============================================================
local function SmallButton(label, onClick, opts)
    opts = opts or {}
    -- ⚔️ emoji 在部分设备回退成白色叉：自动替换为双剑交叉图标
    local icon = opts.icon
    if label:find("⚔") then
        icon = icon or "image/icon_war_双剑交叉.png"
        label = label:gsub("⚔️", ""):gsub("⚔", "")
        label = label:gsub("^%s+", ""):gsub("%s+$", "")
    end
    local bg = opts.bg or COLORS.btnDefault
    local hoverBg = opts.hoverBg or COLORS.btnHover
    -- 羊皮纸质感：默认墨字（纸底上白字不可读）
    local textColor = opts.textColor or { 56, 36, 18, 255 }
    local w = opts.width or nil
    local fontSize = opts.fontSize or 13
    if icon then
        return UI.Button {
            fontSize = fontSize,
            backgroundColor = bg,
            hoverBackgroundColor = hoverBg,
            pressedBackgroundColor = hoverBg,
            backgroundImage = "image/panel_parchment_20260901161208.png",
            backgroundFit = "fill",
            hoverBackgroundImageOpacity = 0.82,
            pressedBackgroundImageOpacity = 0.72,
            borderRadius = 6,
            borderWidth = opts.borderWidth,
            borderColor = opts.borderColor,
            height = opts.height or 36,
            width = w,
            flexGrow = opts.flexGrow,
            onClick = onClick,
            children = {
                UI.Panel {
                    flexDirection = "row", alignItems = "center", justifyContent = "center",
                    width = "100%", height = "100%", gap = 5,
                    children = {
                        UI.Panel {
                            width = opts.iconSize or 18, height = opts.iconSize or 18,
                            backgroundImage = icon, backgroundFit = "contain",
                        },
                        UI.Label { text = label, fontSize = fontSize, fontColor = textColor,
                                   fontWeight = "bold",
                                   width = ((utf8 and utf8.len(label)) or #label) * (fontSize + 2) + 12 },
                    },
                },
            },
        }
    end
    return UI.Button {
        text = label,
        fontSize = fontSize,
        textColor = textColor,
        backgroundColor = bg,
        hoverBackgroundColor = hoverBg,
        pressedBackgroundColor = hoverBg,
        backgroundImage = "image/panel_parchment_20260901161208.png",
        backgroundFit = "fill",
        hoverBackgroundImageOpacity = 0.82,
        pressedBackgroundImageOpacity = 0.72,
        borderRadius = 6,
        borderWidth = opts.borderWidth,
        borderColor = opts.borderColor,
        height = opts.height or 36,
        width = w,
        flexGrow = opts.flexGrow,
        paddingHorizontal = opts.paddingH or 12,
        onClick = onClick,
    }
end

-- ============================================================
-- Helper: 数字格式化（万/亿缩写，防止大数字撑爆顶栏）
-- ============================================================
---@param v number
---@return string
local function fmtNum(v)
    v = math.floor(v or 0)
    if v >= 100000000 then return string.format("%.1f亿", v / 100000000) end
    if v >= 10000 then return string.format("%.1f万", v / 10000) end
    return tostring(v)
end

-- ============================================================
-- Helper: 资源项（完整文字标签 + 数值）
-- ============================================================
local function StatItem(label, value, color, fontSize)
    return UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        gap = 2,
        children = {
            UI.Label {
                text = label,
                fontSize = fontSize or 11,
                fontColor = color or COLORS.textPrimary,
                fontWeight = "bold",
            },
            UI.Label {
                text = tostring(value),
                fontSize = fontSize or 11,
                fontColor = color or COLORS.textPrimary,
                fontWeight = "bold",
            },
        },
    }
end

-- ============================================================
-- 1) Top Bar（顶部资源条 + 功能按钮）
-- ============================================================
local function createTopBar(gameState, callbacks)
    -- 国名按钮：点击打开国家面板（君主 / 税率 / 稳定度）
    refs.topNation = UI.Button {
        text = "---",
        fontSize = 14,
        textColor = COLORS.gold,
        fontWeight = "bold",
        backgroundColor = { 0, 0, 0, 0 },
        hoverBackgroundColor = { 60, 75, 100, 160 },
        pressedBackgroundColor = { 50, 60, 80, 180 },
        paddingHorizontal = 6,
        height = 30,
        onClick = function()
            if callbacks.onToggleNationPanel then callbacks.onToggleNationPanel() end
        end,
    }
    refs.topGold = StatItem("金钱", 0, COLORS.gold)
    refs.topFood = StatItem("粮草", 0, COLORS.food)
    refs.topArmy = StatItem("兵力", 0, COLORS.army)
    refs.topPrestige = StatItem("威望", 0, COLORS.prestige)
    -- 时间显示"大筐"（CK3 式）：整块是按钮，点击 = 暂停/继续
    refs.topDate = UI.Button {
        text = "",
        fontSize = 11,
        textColor = COLORS.textPrimary,
        fontWeight = "bold",
        backgroundColor = { 66, 84, 112, 255 },
        hoverBackgroundColor = { 88, 108, 140, 255 },
        pressedBackgroundColor = { 52, 66, 92, 255 },
        borderWidth = 1,
        borderColor = { 150, 170, 200, 180 },
        paddingHorizontal = 6,
        height = 30,
        borderRadius = 6,
        flexShrink = 0,   -- 禁止被父容器压缩，保证完整展示
        onClick = function()
            if callbacks.onPauseToggle then callbacks.onPauseToggle() end
        end,
    }

    -- 时间流速大长条：显示"时间流速:当前档"，点击弹出 5 档汉字菜单（2026-09-01）
    -- 五档对应 TimeSystem 速度：1=1/4速(慢) 2=1/2速(缓) 3=1速(常) 4=2速(快) 5=5速(极)
    refs.speedBar = UI.Button {
        text = "时间流速:常",
        fontSize = 11,
        textColor = COLORS.textPrimary,
        fontWeight = "bold",
        backgroundColor = { 66, 84, 112, 255 },
        hoverBackgroundColor = { 88, 108, 140, 255 },
        pressedBackgroundColor = { 52, 66, 92, 255 },
        borderWidth = 1,
        borderColor = { 150, 170, 200, 180 },
        paddingHorizontal = 8,
        height = 30,
        borderRadius = 6,
        flexShrink = 0,
        onClick = function()
            GameUI.toggleSpeedMenu()
        end,
    }

    -- 治理入口按钮：外交/政策/科技（2026-09-01；官员在国名治理界面内）
    local diploBtn = SmallButton("外交", function()
        if callbacks.onDiplomacyToggle then callbacks.onDiplomacyToggle() end
    end, { width = 42, height = 30, fontSize = 11, bg = { 40, 50, 70, 220 } })
    local policyBtn = SmallButton("政策", function()
        if callbacks.onPolicyToggle then callbacks.onPolicyToggle() end
    end, { width = 42, height = 30, fontSize = 11, bg = { 40, 50, 70, 220 } })
    local techBtn = SmallButton("科技", function()
        if callbacks.onTechToggle then callbacks.onTechToggle() end
    end, { width = 42, height = 30, fontSize = 11, bg = { 40, 50, 70, 220 } })
    local gearBtn = SmallButton("设置", function()
        GameUI.toggleSettings()
    end, { width = 62, height = 30, fontSize = 12 })

    local topBar = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0,
        height = 44,
        flexDirection = "row",
        alignItems = "center",
        justifyContent = "space-between",
        paddingHorizontal = 8,
        gap = 8,
        backgroundColor = { 15, 20, 30, 200 },
        children = {
            -- 左侧：国家名
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                gap = 6,
                children = {
                    refs.topNation,
                },
            },
            -- 右侧：治理入口 + 资源属性 + 时间大筐 + 时间流速 + 设置
            -- （2026-09-01 外交/政策/科技移到最左，金钱等资源随之右移）
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                gap = 8,
                children = {
                    diploBtn,
                    policyBtn,
                    techBtn,
                    refs.topGold,
                    refs.topFood,
                    refs.topArmy,
                    refs.topPrestige,
                    refs.topDate,
                    refs.speedBar,
                    gearBtn,
                },
            },
        },
    }
    return topBar
end

-- ============================================================
-- 2) Province Info Panel（右侧：信息 + 操作）
-- ============================================================
local function createProvincePanel(gameState, callbacks)
    refs.provName = UI.Label {
        text = "---",
        fontSize = 16,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }
    refs.provTerrain = UI.Label {
        text = "地形: ---",
        fontSize = 12,
        fontColor = COLORS.textSecondary,
    }
    refs.provOwner = UI.Label {
        text = "领主: 无主",
        fontSize = 13,
        fontColor = COLORS.textPrimary,
    }
    refs.provPopulation = UI.Label {
        text = "人口: 0",
        fontSize = 12,
        fontColor = COLORS.textSecondary,
    }
    refs.provGarrison = UI.Label {
        text = "驻军: 0",
        fontSize = 12,
        fontColor = COLORS.army,
        fontWeight = "bold",
    }
    refs.provStabilityLabel = UI.Label {
        text = "治安: 0%",
        fontSize = 12,
        fontColor = COLORS.textSecondary,
    }
    refs.provStabilityBar = UI.ProgressBar {
        value = 0,
        max = 1,
        height = 8,
        width = "100%",
        borderRadius = 4,
        backgroundColor = { 40, 45, 60, 200 },
        fillColor = "#50A0DC",
        showLabel = false,
    }

    -- 操作按钮（动态显示/隐藏）
    refs.btnRecruit = SmallButton("⚔️ 征兵", function()
        local pid = refs.selectedProvinceId
        if pid and callbacks.onRecruit then
            callbacks.onRecruit(pid)
        end
    end, { height = 40, bg = COLORS.btnSuccess, hoverBg = COLORS.btnSuccessHover })
    refs.btnMoveArmy = SmallButton("🚩 调军", function()
        local pid = refs.selectedProvinceId
        if pid and callbacks.onMoveArmy then
            callbacks.onMoveArmy(pid)
        end
    end, { height = 40 })
    refs.btnDeclareWar = SmallButton("⚔️ 宣战", function()
        if refs.selectedOwnerId and callbacks.onDeclareWar then
            callbacks.onDeclareWar(refs.selectedOwnerId)
        end
    end, { height = 40, bg = COLORS.btnDanger, hoverBg = COLORS.btnDangerHover })
    -- 沙漠化/恢复（历史时代3 式：化为不可占领的沙漠废土）
    refs.btnWasteland = SmallButton("🏜️ 化为沙漠", function()
        local gs = refs.gameState
        local pid = refs.selectedProvinceId
        if gs and pid then
            local p = gs.getProvince(pid)
            gs.setWasteland(pid, not (p and p.isWasteland))
            GameUI.showProvincePanel(pid, gs.getProvince(pid))
        end
    end, { height = 40 })
    refs.provActionHint = UI.Label {
        text = "",
        fontSize = 11,
        fontColor = COLORS.textSecondary,
    }

    local closeBtn = SmallButton("X", function()
        GameUI.hideProvincePanel()
    end, { width = 28, height = 28, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    local headerRow = UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        justifyContent = "space-between",
        width = "100%",
        children = {
            refs.provName,
            closeBtn,
        },
    }

    -- 操作行容器（内容动态更新）
    refs.provActions = UI.Panel {
        width = "100%",
        flexDirection = "row",
        gap = 6,
        children = {},
    }

    refs.provincePanel = UI.Panel {
        position = "absolute",
        top = 52,
        right = 6,
        width = 230,
        backgroundColor = COLORS.bgPanel,
        borderRadius = 8,
        borderWidth = 1,
        borderColor = COLORS.border,
        padding = 12,
        gap = 6,
        pointerEvents = "auto",
        children = {
            headerRow,
            refs.provTerrain,
            UI.Divider { color = COLORS.border, thickness = 1, spacing = 4 },
            refs.provOwner,
            refs.provPopulation,
            refs.provGarrison,
            UI.Divider { color = COLORS.border, thickness = 1, spacing = 4 },
            refs.provStabilityLabel,
            refs.provStabilityBar,
            refs.provActions,
            refs.provActionHint,
        },
    }
    refs.provincePanel:Hide()

    return refs.provincePanel
end

-- ============================================================
-- 3) Ranking Panel（排行榜）
-- ============================================================
--- 计算排行榜数据
---@param gameState table
---@param dim string "territory" | "economy" | "military" | "prestige"
---@return table[] sortedFactions {id, name, color, value, isPlayer}
local function buildRanking(gameState, dim)
    local list = {}
    for fid, f in pairs(gameState.factions) do
        if f.alive ~= false and f.provinces and #f.provinces > 0 then
            local value = 0
            if dim == "territory" then
                value = #f.provinces
            elseif dim == "economy" then
                value = (f.gold or 0) + (f.food or 0) * 0.5
            elseif dim == "military" then
                value = f.armySize or 0
            elseif dim == "prestige" then
                value = f.prestige or 0
            end
            list[#list + 1] = {
                id = fid,
                name = f.name or ("势力#" .. fid),
                color = f.color or { 150, 150, 150, 255 },
                value = value,
                isPlayer = (fid == gameState.playerFactionId),
            }
        end
    end
    table.sort(list, function(a, b) return a.value > b.value end)
    return list
end

--- 显示排行榜
---@param gameState table
function GameUI.showRanking(gameState)
    if not refs.rankOverlay then return end
    local dim = refs.rankDim or "territory"
    local list = buildRanking(gameState, dim)

    refs.rankList:ClearChildren()
    for i = 1, math.min(20, #list) do
        local entry = list[i]
        local row = UI.Panel {
            width = "100%",
            flexDirection = "row",
            alignItems = "center",
            gap = 8,
            padding = 4,
            backgroundColor = entry.isPlayer and { 90, 75, 30, 180 } or nil,
            borderRadius = 4,
            children = {
                UI.Label {
                    text = tostring(i),
                    fontSize = 13,
                    width = 22,
                    fontColor = entry.isPlayer and COLORS.gold or COLORS.textSecondary,
                    fontWeight = "bold",
                },
                UI.Panel {
                    width = 10, height = 10,
                    borderRadius = 5,
                    backgroundColor = entry.color,
                },
                UI.Label {
                    text = entry.name,
                    fontSize = 13,
                    flexGrow = 1,
                    fontColor = entry.isPlayer and COLORS.gold or COLORS.textPrimary,
                    fontWeight = entry.isPlayer and "bold" or "normal",
                },
                UI.Label {
                    text = tostring(math.floor(entry.value)),
                    fontSize = 13,
                    fontColor = COLORS.textSecondary,
                },
            },
        }
        refs.rankList:AddChild(row)
    end

    refs.rankOverlay:Show()
end

function GameUI.hideRanking()
    if refs.rankOverlay then refs.rankOverlay:Hide() end
end

function GameUI.toggleRanking()
    if refs.rankOverlay and refs.rankOverlay:IsVisible() then
        GameUI.hideRanking()
    else
        GameUI.showRanking(refs.gameState)
    end
end

local function createRankingPanel()
    refs.rankDim = "territory"
    refs.rankList = UI.Panel { width = "100%", gap = 2 }

    local dimButtons = {
        { label = "领土", dim = "territory" },
        { label = "经济", dim = "economy" },
        { label = "军力", dim = "military" },
        { label = "威望", dim = "prestige" },
    }
    local dimRow = UI.Panel {
        flexDirection = "row",
        gap = 6,
        children = {},
    }
    for _, d in ipairs(dimButtons) do
        dimRow:AddChild(SmallButton(d.label, function()
            refs.rankDim = d.dim
            GameUI.showRanking(refs.gameState)
        end, { height = 30, fontSize = 12, bg = { 55, 65, 90, 230 } }))
    end

    local closeBtn = SmallButton("X", function()
        GameUI.hideRanking()
    end, { width = 28, height = 28, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    refs.rankOverlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 320,
                maxHeight = "80%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 14,
                gap = 10,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            UI.Label {
                                text = "📊 天下国力榜",
                                fontSize = 18,
                                fontColor = COLORS.gold,
                                fontWeight = "bold",
                            },
                            closeBtn,
                        },
                    },
                    dimRow,
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        maxHeight = 420,
                        children = { refs.rankList },
                    },
                },
            },
        },
    }
    refs.rankOverlay:Hide()
    return refs.rankOverlay
end

-- ============================================================
-- 3.6) Speed Menu（时间流速选择弹窗，2026-09-01）
-- ============================================================
function GameUI.toggleSpeedMenu()
    if refs.speedMenu and refs.speedMenu:IsVisible() then
        refs.speedMenu:Hide()
    else
        refs.speedMenu:Show()
    end
end

local function createSpeedMenu(callbacks)
    local SPEED_INFO = {
        { label = "慢", desc = "1/4速" },
        { label = "缓", desc = "1/2速" },
        { label = "常", desc = "1速（1秒1天）" },
        { label = "快", desc = "2速" },
        { label = "极", desc = "5速" },
    }
    refs.speedMenuButtons = {}
    local list = UI.Panel { width = "100%", gap = 6 }
    for i, info in ipairs(SPEED_INFO) do
        local btn = UI.Button {
            height = 42,
            fontSize = 14,
            text = info.label .. "　" .. info.desc,
            textColor = COLORS.textPrimary,
            backgroundColor = { 40, 50, 70, 220 },
            hoverBackgroundColor = { 60, 75, 100, 240 },
            pressedBackgroundColor = { 50, 60, 80, 240 },
            borderRadius = 6,
            onClick = function()
                if callbacks.onSetSpeed then callbacks.onSetSpeed(i) end
                GameUI.toggleSpeedMenu()
            end,
        }
        refs.speedMenuButtons[i] = btn
        list:AddChild(btn)
    end

    refs.speedMenu = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 260,
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 14,
                gap = 10,
                children = {
                    UI.Label {
                        text = "⏱ 时间流速",
                        fontSize = 16,
                        fontColor = COLORS.gold,
                        fontWeight = "bold",
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    list,
                },
            },
        },
    }
    refs.speedMenu:Hide()
    return refs.speedMenu
end

-- ============================================================
-- 3.5) Nation Panel（国家面板：君主 / 税率 / 稳定度）
-- ============================================================
function GameUI.showNationPanel()
    if refs.nationPanel then refs.nationPanel:Show() end
end

function GameUI.hideNationPanel()
    if refs.nationPanel then refs.nationPanel:Hide() end
end

function GameUI.toggleNationPanel()
    if refs.nationPanel and refs.nationPanel:IsVisible() then
        GameUI.hideNationPanel()
    else
        GameUI.showNationPanel()
    end
end

local function createNationPanel(callbacks)
    refs.nationName = UI.Label {
        text = "---",
        fontSize = 18,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }
    refs.nationLeader = UI.Label {
        text = "",
        fontSize = 13,
        fontColor = COLORS.textPrimary,
        fontWeight = "bold",
    }
    refs.nationAbility = UI.Label {
        text = "",
        fontSize = 13,
        fontColor = COLORS.textSecondary,
    }
    refs.nationStability = UI.Label {
        text = "",
        fontSize = 13,
        fontColor = COLORS.stability,
    }

    -- 税率档位按钮（GameConfig.Economy.TAX_RATES，当前档金色高亮）
    refs.taxButtons = {}
    local taxRow = UI.Panel {
        width = "100%",
        flexDirection = "row",
        gap = 6,
        children = {},
    }
    for i, t in ipairs(GameConfig.Economy.TAX_RATES or {}) do
        local btn = SmallButton(t.name or ("档" .. i), function()
            if callbacks.onSetTaxLevel then callbacks.onSetTaxLevel(i) end
        end, {
            fontSize = 12,
            height = 34,
            flexGrow = 1,
            bg = SPEED_BTN_NORMAL.bg,
            hoverBg = SPEED_BTN_NORMAL.hover,
        })
        refs.taxButtons[i] = btn
        taxRow:AddChild(btn)
    end
    refs.taxHint = UI.Label {
        text = "",
        fontSize = 11,
        fontColor = COLORS.textSecondary,
        whiteSpace = "normal",
        maxLines = 2,
    }

    local closeBtn = SmallButton("X", function()
        GameUI.hideNationPanel()
    end, { width = 28, height = 28, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    -- 国事页签内容（君主 / 税率 / 稳定度）
    refs.nationTabState = UI.Panel {
        width = "100%",
        gap = 10,
        children = {
            refs.nationLeader,
            refs.nationAbility,
            UI.Divider { color = COLORS.border, thickness = 1 },
            UI.Label {
                text = "税率",
                fontSize = 12,
                fontColor = COLORS.textSecondary,
            },
            taxRow,
            refs.taxHint,
            UI.Divider { color = COLORS.border, thickness = 1 },
            refs.nationStability,
        },
    }

    -- 官员页签内容（框架占位，2026-09-01）
    refs.nationTabOfficials = UI.Panel {
        width = "100%",
        gap = 10,
        children = {
            UI.Label {
                text = "官员系统开发中…\n\n即将推出：\n相国（经济+）/ 司马（战力+）/\n行人（外交+）/ 司徒（人口增长+）",
                fontSize = 13,
                fontColor = COLORS.textSecondary,
                whiteSpace = "normal",
                maxLines = 8,
            },
        },
    }
    refs.nationTabOfficials:Hide()

    -- 页签切换
    ---@param tab string "state"|"officials"
    local function showNationTab(tab)
        local showState = (tab == "state")
        refs.nationTabState:SetVisible(showState)
        refs.nationTabOfficials:SetVisible(not showState)
        -- 高亮当前页签
        local tabs = {
            { refs.nationTabStateBtn, showState },
            { refs.nationTabOfficialsBtn, not showState },
        }
        for _, b in ipairs(tabs) do
            local btn, active = b[1], b[2]
            if btn then
                if active then
                    btn.props.backgroundColor = SPEED_BTN_ACTIVE.bg
                    btn.props.hoverBackgroundColor = SPEED_BTN_ACTIVE.hover
                    btn.props.textColor = SPEED_BTN_ACTIVE.textColor
                else
                    btn.props.backgroundColor = SPEED_BTN_NORMAL.bg
                    btn.props.hoverBackgroundColor = SPEED_BTN_NORMAL.hover
                    btn.props.textColor = nil
                end
            end
        end
    end

    -- 页签按钮（2026-09-01）：国事 / 官员（官员系统框架占位）
    local tabStateBtn = SmallButton("国事", function()
        showNationTab("state")
    end, { fontSize = 12, height = 30, flexGrow = 1, bg = SPEED_BTN_NORMAL.bg, hoverBg = SPEED_BTN_NORMAL.hover })
    local tabOfficialsBtn = SmallButton("官员", function()
        showNationTab("officials")
    end, { fontSize = 12, height = 30, flexGrow = 1, bg = SPEED_BTN_NORMAL.bg, hoverBg = SPEED_BTN_NORMAL.hover })
    refs.nationTabStateBtn = tabStateBtn
    refs.nationTabOfficialsBtn = tabOfficialsBtn
    showNationTab("state")

    refs.nationPanel = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 300,
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 16,
                gap = 10,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            refs.nationName,
                            closeBtn,
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.Panel {
                        flexDirection = "row",
                        gap = 6,
                        children = {
                            tabStateBtn,
                            tabOfficialsBtn,
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    refs.nationTabState,
                    refs.nationTabOfficials,
                },
            },
        },
    }
    refs.nationPanel:Hide()
    return refs.nationPanel
end

-- ============================================================
-- 3.75) Peace Dialog（和平条约窗口：选省/赔款/附庸/吞并，2026-09-03 AoH3 式左侧全高面板）
-- ============================================================

-- 和平面板配色（PEACE_UI_SPEC.md 视觉规范）
local PEACE_HEADER_BG    = { 64, 22, 26, 255 }     -- 标题栏酒红
local PEACE_PANEL_BG     = { 12, 16, 26, 242 }     -- 面板背景
local PEACE_GOLD_BORDER  = { 150, 120, 70, 220 }   -- 金棕边框
local PEACE_SECTION_BG   = { 26, 38, 56, 230 }     -- 分区标题底
local PEACE_SECTION_TEXT = { 200, 215, 240, 255 }  -- 分区标题字
local PEACE_ROW_A        = { 20, 26, 38, 230 }     -- 行交替底色 A
local PEACE_ROW_B        = { 26, 33, 46, 230 }     -- 行交替底色 B
local PEACE_SEL_BG       = { 70, 90, 45, 230 }     -- 选中行底
local PEACE_SEL_BORDER   = { 120, 200, 110, 255 }  -- 选中边框/勾
local PEACE_PLAYER_BLUE  = { 40, 80, 180, 255 }    -- 玩家侧色块
local PEACE_ENEMY_GRAY   = { 120, 120, 125, 255 }  -- 敌侧色块
local PEACE_OK_GREEN     = { 90, 180, 95, 255 }    -- 预算充足
local PEACE_WARN_RED     = { 220, 70, 55, 255 }    -- 预算不足/警告
local PEACE_TAG_OCCUPIED = { 90, 210, 110, 255 }   -- 已占小标签

--- 计算当前条约成本（战争分数预算）
---@return number
function GameUI.peaceDialogCost()
    local gs = refs.gameState
    local cfg = refs.peaceCfg
    if not gs or not cfg then return 0 end
    local cost = 0
    for pid, _ in pairs(refs.peaceSelection or {}) do
        cost = cost + WarSystem.getProvinceCost(gs, pid, cfg.proposerId)
    end
    cost = cost + math.ceil((refs.peaceGold or 0) / 100) + math.ceil((refs.peaceFood or 0) / 100)
    if refs.peaceVassal then cost = cost + 30 end
    if refs.peaceAnnex then cost = cost + 50 end
    return cost
end

--- 刷新和平条约面板（预算行 / 步进器 / 卡片 / 省份行 / 缔结栏，AoH3 式左侧面板）
---@param gameState table
function GameUI.refreshPeaceDialog(gameState)
    if not refs.peaceDialog or not refs.peaceDialog:IsVisible() then return end
    local cfg = refs.peaceCfg
    local cost = GameUI.peaceDialogCost()
    local score = math.floor(refs.peaceScore or 0)
    local annex = refs.peaceAnnex == true
    local over = not annex and cost > score

    -- 选中省计数
    local selCount = 0
    for _ in pairs(refs.peaceSelection or {}) do selCount = selCount + 1 end
    local pickCount = 0
    for _ in pairs(refs.peacePickableIds or {}) do pickCount = pickCount + 1 end

    -- 区域 B：战争分数（propose/respond 通用，金色大字 + 🏆）
    if refs.peaceScoreValue then
        refs.peaceScoreValue.text = string.format("%.1f 🏆", refs.peaceScore or 0)
    end

    -- 预算摘要行（propose 独有）：已耗 / 剩余 / 已选
    if refs.budgetUsedVal then
        if over then
            refs.budgetUsedVal.text = tostring(cost)
            refs.budgetUsedVal.props.fontColor = PEACE_WARN_RED
            refs.budgetLeftVal.text = "不足 " .. (cost - score) .. "!"
            refs.budgetLeftVal.props.fontColor = PEACE_WARN_RED
        else
            refs.budgetUsedVal.text = tostring(cost)
            refs.budgetUsedVal.props.fontColor = PEACE_OK_GREEN
            refs.budgetLeftVal.text = tostring(score - cost)
            refs.budgetLeftVal.props.fontColor = PEACE_OK_GREEN
        end
        refs.budgetPickVal.text = tostring(selCount) .. " / " .. tostring(pickCount)
    end

    -- 区域 C1/C2 步进器：步长边界 + 实时成本小字
    if refs.peaceGoldMinus then
        local gold = refs.peaceGold or 0
        local food = refs.peaceFood or 0
        refs.peaceGoldValueLabel.text = gold .. " 金"
        refs.peaceGoldCostLabel.text = "≈" .. math.ceil(gold / 100) .. "分"
        refs.peaceGoldMinus:SetDisabled(gold <= 0)
        refs.peaceGoldMinus:SetOpacity(gold > 0 and 1 or 0.4)
        refs.peaceFoodValueLabel.text = food .. " 粮"
        refs.peaceFoodCostLabel.text = "≈" .. math.ceil(food / 100) .. "分"
        refs.peaceFoodMinus:SetDisabled(food <= 0)
        refs.peaceFoodMinus:SetOpacity(food > 0 and 1 or 0.4)
    end

    -- 区域 C3 附庸卡 toggle 态
    if refs.peaceVassalCard then
        local on = refs.peaceVassal == true
        refs.peaceVassalIcon.text = on and "✓ " or ""
        refs.peaceVassalCard.props.borderColor = on and PEACE_SEL_BORDER or { 80, 90, 115, 200 }
        refs.peaceVassalCard.props.backgroundColor = on and { 45, 70, 45, 235 } or { 20, 26, 38, 220 }
    end

    -- 区域 C3 吞并卡可用性（仅对方全境被占领时可点；annexAll 绕过预算）
    if refs.peaceAnnexCard then
        local allOcc = cfg and cfg.terms and cfg.terms.allOccupied == true
        refs.peaceAnnexCard:SetDisabled(not allOcc)
        refs.peaceAnnexCard:SetOpacity(allOcc and 1 or 0.5)
    end

    -- 区域 D 工具按钮：全选占领 / 重置
    if refs.peaceSelectAllBtn then
        local proposerId = cfg and cfg.proposerId or nil
        local hasOccupied = false
        if proposerId then
            for pid in pairs(refs.peacePickableIds or {}) do
                local prov = gameState and gameState.provinces[pid]
                if prov and prov.occupiedBy == proposerId then
                    hasOccupied = true
                    break
                end
            end
        end
        refs.peaceSelectAllBtn:SetDisabled(not hasOccupied or annex)
        refs.peaceClearBtn:SetDisabled(selCount == 0 or annex)
    end

    -- 区域 F 缔结栏：文案 / 禁用 / 超支红字（annexAll 永不禁用）
    if refs.peaceSubmitBtn then
        local hasTerms = selCount > 0
            or (refs.peaceGold or 0) > 0
            or (refs.peaceFood or 0) > 0
            or refs.peaceVassal == true
        refs.peaceSubmitBtn:SetText(hasTerms and "🏆 缔结条约" or "仅缔结停战")
        local blocked = not annex and over
        refs.peaceSubmitBtn:SetDisabled(blocked)
        if refs.peaceOverLabel then
            if blocked then
                refs.peaceOverLabel.text = "战争分数不足(超 " .. (cost - score) .. " 分)"
                refs.peaceOverLabel:Show()
            else
                refs.peaceOverLabel.text = ""
                refs.peaceOverLabel:Hide()
            end
        end
    end

    -- 同步地图金色高亮（选择集合变化时）
    if refs.callbacks and refs.callbacks.onPeaceSelectionChanged then
        local ids = {}
        for pid in pairs(refs.peaceSelection or {}) do
            ids[#ids + 1] = pid
        end
        refs.callbacks.onPeaceSelectionChanged(ids)
    end
end

--- 和谈选省模式：propose 会话打开时，点击地图敌省即可加入/移出割让清单
---@return boolean
function GameUI.isPeacePickMode()
    return refs.peaceDialog ~= nil and refs.peaceDialog:IsVisible()
        and refs.peaceCfg ~= nil and refs.peaceCfg.mode == "propose"
end

--- 某省是否在可索取集合内（和平条约涂抹起点判断用）
---@param provinceId number
---@return boolean
function GameUI.isProvincePickable(provinceId)
    if not GameUI.isPeacePickMode() then return false end
    return refs.peacePickableIds and refs.peacePickableIds[provinceId] == true
end

--- 和谈模式下的省份点选：可选项内 toggle；返回是否被消费
---@param provinceId number
---@param forceSelect boolean|nil  true=涂抹（只加选不取消）
---@return boolean
function GameUI.togglePeaceProvincePick(provinceId, forceSelect)
    if not GameUI.isPeacePickMode() then return false end
    if not refs.peacePickableIds or not refs.peacePickableIds[provinceId] then
        return true   -- 模式内点击其他省份：消费掉但不选择
    end
    local sel = refs.peaceSelection or {}
    if forceSelect then
        sel[provinceId] = true
    elseif sel[provinceId] then
        sel[provinceId] = nil
    else
        sel[provinceId] = true
    end
    refs.peaceSelection = sel
    -- 同步左栏清单勾选态
    for _, row in pairs(refs.peaceProvRows or {}) do
        if row.pid == provinceId and row.setSelected then
            row.setSelected(sel[provinceId] == true)
        end
    end
    GameUI.refreshPeaceDialog(refs.gameState)
    return true
end

--- 条约窗口选择状态读取（main.lua 提交时收集）
---@return table selection  pid -> true
function GameUI.getPeaceSelection()
    return refs.peaceSelection or {}
end
---@return number
function GameUI.getPeaceGold()
    return refs.peaceGold or 0
end
---@return number
function GameUI.getPeaceFood()
    return refs.peaceFood or 0
end
---@return boolean
function GameUI.getPeaceVassal()
    return refs.peaceVassal == true
end
---@return boolean
function GameUI.getPeaceAnnex()
    return refs.peaceAnnex == true
end

--- 创建省索取行（AoH3 纵向行：✓ + 省名 + 已占/未占标签 + 分数成本，点击 toggle）
---@param gs table
---@param item table {id, name, cost, occupied}
---@param index number 行序（1 起，奇偶交替底色）
---@return Widget
local function createProvinceRow(gs, item, index)
    local row = { pid = item.id }
    local baseBg = (index % 2 == 1) and PEACE_ROW_A or PEACE_ROW_B

    -- 左侧勾选位（未选中时留白占位）
    local iconLabel = UI.Label {
        text = "",
        fontSize = 12,
        width = 14,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }
    local nameLabel = UI.Label {
        text = item.name,
        fontSize = 12,
        fontColor = COLORS.textPrimary,
        fontWeight = "bold",
    }
    local tagLabel = UI.Label {
        text = item.occupied and "已占" or "未占",
        fontSize = 10,
        fontColor = item.occupied and PEACE_TAG_OCCUPIED or COLORS.textSecondary,
    }
    local costLabel = UI.Label {
        text = item.cost .. "分",
        fontSize = 11,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }

    local btn = UI.Button {
        height = 32,
        borderRadius = 6,
        backgroundColor = baseBg,
        hoverBackgroundColor = { 255, 255, 255, 18 },
        pressedBackgroundColor = { 255, 255, 255, 30 },
        flexDirection = "row",
        alignItems = "center",
        gap = 6,
        paddingHorizontal = 8,
        onClick = function()
            GameUI.togglePeaceProvincePick(item.id)
        end,
        children = {
            iconLabel,
            nameLabel,
            tagLabel,
            UI.Panel { flexGrow = 1 },
            costLabel,
        },
    }

    -- 地图涂抹高亮回写行的既有机制（forceSelect 时由 toggle 调用）
    function row.setSelected(selected)
        btn.props.backgroundColor = selected and PEACE_SEL_BG or baseBg
        iconLabel.text = selected and "✓" or ""
    end

    return btn, row
end


function GameUI.showPeaceDialog(gameState, cfg)
    if not refs.peaceDialog then return end
    refs.peaceCfg = cfg or {}
    local gs = gameState
    local mode = cfg.mode   -- "propose" | "respond"

    local p = cfg.proposerId
    local t = cfg.targetId
    local fromF = gs.factions[p]
    local toF = gs.factions[t]
    local fromName = fromF and (fromF.fullName or fromF.name) or "?"
    local toName   = toF and (toF.fullName or toF.name) or "?"

    -- 区域 A：副标题按模式区分（主标题固定“和平条约”）
    refs.peaceSubTitle.text = (mode == "respond") and "对方提出条件" or "提出条件"

    -- 区域 B：双方横幅（玩家蓝块 / AI 灰块）
    local playerFid = gs.playerFactionId
    refs.peaceSideAName.text = fromName
    refs.peaceSideBName.text = toName
    refs.peaceColorBlockA.props.backgroundColor = (p == playerFid) and PEACE_PLAYER_BLUE or PEACE_ENEMY_GRAY
    refs.peaceColorBlockB.props.backgroundColor = (t == playerFid) and PEACE_PLAYER_BLUE or PEACE_ENEMY_GRAY

    -- 战争分数（照旧：以提出方视角读取）
    local score = 0
    local war = WarSystem.findWar(gs, p, t)
    if war then
        score = WarSystem.getScore(gs, war, p)
    end
    refs.peaceScore = score

    -- 重置选择状态
    refs.peaceSelection = {}
    refs.peaceGold = 0
    refs.peaceFood = 0
    refs.peaceVassal = false
    refs.peaceAnnex = false

    if mode == "propose" then
        -- 只显示 propose 交互区（预算行/条件/省份/缔结栏）
        refs.peaceProposeBox:Show()
        refs.peaceRespondBox:Hide()

        -- 构建省索取行（纵向；空列表居中灰字占位）
        refs.peaceProvRows = {}
        refs.peacePickableIds = {}
        refs.peaceProvList:ClearChildren()
        local terms = cfg.terms or {}
        local list = terms.provinceList or {}
        if #list == 0 then
            refs.peaceProvEmpty:Show()
        else
            refs.peaceProvEmpty:Hide()
            for i, item in ipairs(list) do
                refs.peacePickableIds[item.id] = true
                local widget, row = createProvinceRow(gs, item, i)
                refs.peaceProvRows[item.id] = row
                refs.peaceProvList:AddChild(widget)
            end
        end
    else
        -- respond：只显示只读文书（隐藏 propose 全部交互）
        refs.peaceProposeBox:Hide()
        refs.peaceRespondBox:Show()

        -- 重建只读条款文书（只列非空条款）
        refs.peaceRespondList:ClearChildren()
        local terms = cfg.terms or {}
        local provNames = {}
        for _, pid in ipairs(terms.provinces or {}) do
            local prov = gs.provinces[pid]
            if prov and prov.name then
                provNames[#provNames + 1] = prov.name
            end
        end
        local goldAmt = terms.gold or 0
        local foodAmt = terms.food or 0
        if #provNames > 0 then
            refs.peaceRespondList:AddChild(UI.Label {
                text = "· 割让 " .. #provNames .. " 省：" .. table.concat(provNames, "、"),
                fontSize = 12,
                fontColor = COLORS.textPrimary,
                whiteSpace = "normal",
            })
        end
        if goldAmt > 0 then
            refs.peaceRespondList:AddChild(UI.Label {
                text = "· 赔款：" .. goldAmt .. " 金",
                fontSize = 12,
                fontColor = COLORS.textPrimary,
            })
        end
        if foodAmt > 0 then
            refs.peaceRespondList:AddChild(UI.Label {
                text = "· 赔粮：" .. foodAmt .. " 粮",
                fontSize = 12,
                fontColor = COLORS.textPrimary,
            })
        end
        if #provNames == 0 and goldAmt <= 0 and foodAmt <= 0 then
            refs.peaceRespondList:AddChild(UI.Label {
                text = "对方请求仅缔结停战",
                fontSize = 12,
                fontColor = COLORS.textSecondary,
            })
        end
    end

    -- 镜头自动聚焦到被索取方领土（P 社风）+ 开启地图涂抹选省
    if refs.callbacks and refs.callbacks.onPeaceDialogOpened then
        refs.callbacks.onPeaceDialogOpened(cfg, gs)
    end

    GameUI.refreshPeaceDialog(gs)
    refs.peaceDialog:Show()
end

function GameUI.hidePeaceDialog()
    if refs.peaceDialog then refs.peaceDialog:Hide() end
    refs.peaceCfg = nil
    refs.peaceAnnex = false
    -- 关闭地图涂抹选省模式 + 清空高亮
    if refs.callbacks then
        if refs.callbacks.onPeaceDialogClosed then
            refs.callbacks.onPeaceDialogClosed()
        end
        if refs.callbacks.onPeaceSelectionChanged then
            refs.callbacks.onPeaceSelectionChanged({})
        end
    end
end

function GameUI.isPeaceDialogVisible()
    return refs.peaceDialog and refs.peaceDialog:IsVisible() or false
end

local function createPeaceDialog(callbacks)
    -- 面板宽度：规格 420（逻辑宽 ≥1400 放宽 460）；小屏自动收窄保右侧地图可见
    local physW = graphics:GetWidth()
    local dpr = graphics:GetDPR()
    local logicalW = physW / (dpr and dpr > 0 and dpr or 1)
    local baseW = (logicalW >= 1400) and 460 or 420
    local panelW = math.max(280, math.min(baseW, logicalW - 24))

    -- ============ 区域 A：标题栏（酒红，左上/右上圆角 10） ============
    refs.peaceTitleText = UI.Label {
        text = "和平条约",
        fontSize = 16,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }
    refs.peaceSubTitle = UI.Label {
        text = "提出条件",
        fontSize = 11,
        fontColor = { 255, 255, 255, 178 },
    }
    local closeBtn = SmallButton("✕", function()
        GameUI.hidePeaceDialog()   -- respond 模式 X 沿用现状：仅关闭
    end, { width = 28, height = 28, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    -- ============ 区域 B：双方横幅（色块+国名）+ 战争分数 ============
    refs.peaceColorBlockA = UI.Panel {
        width = 24, height = 24, borderRadius = 4,
        backgroundColor = PEACE_PLAYER_BLUE,
    }
    refs.peaceSideAName = UI.Label { text = "", fontSize = 13, fontColor = COLORS.textPrimary, fontWeight = "bold" }
    refs.peaceSideBName = UI.Label { text = "", fontSize = 13, fontColor = COLORS.textPrimary, fontWeight = "bold" }
    refs.peaceColorBlockB = UI.Panel {
        width = 24, height = 24, borderRadius = 4,
        backgroundColor = PEACE_ENEMY_GRAY,
    }
    refs.peaceScoreValue = UI.Label {
        text = "0.0 🏆",
        fontSize = 16,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }

    -- ============ 分区标题条（区域 C/D 共用） ============
    local function SectionTitle(text)
        return UI.Panel {
            height = 26,
            borderRadius = 6,
            paddingHorizontal = 10,
            backgroundColor = PEACE_SECTION_BG,
            justifyContent = "center",
            children = {
                UI.Label { text = text, fontSize = 13, fontColor = PEACE_SECTION_TEXT, fontWeight = "bold" },
            },
        }
    end

    -- ============ 预算摘要行（已耗/剩余/已选 三列等分） ============
    local function BudgetStat(cap, val)
        return UI.Panel {
            flexGrow = 1,
            flexDirection = "row",
            alignItems = "center",
            justifyContent = "center",
            gap = 4,
            children = {
                UI.Label { text = cap, fontSize = 11, fontColor = COLORS.textSecondary },
                val,
            },
        }
    end
    refs.budgetUsedVal = UI.Label { text = "0", fontSize = 13, fontColor = PEACE_OK_GREEN, fontWeight = "bold" }
    refs.budgetLeftVal = UI.Label { text = "0", fontSize = 13, fontColor = PEACE_OK_GREEN, fontWeight = "bold" }
    refs.budgetPickVal = UI.Label { text = "0 / 0", fontSize = 13, fontColor = COLORS.gold, fontWeight = "bold" }
    local budgetRow = UI.Panel {
        flexDirection = "row",
        gap = 4,
        width = "100%",
        children = {
            BudgetStat("已耗", refs.budgetUsedVal),
            BudgetStat("剩余", refs.budgetLeftVal),
            BudgetStat("已选", refs.budgetPickVal),
        },
    }

    -- ============ 步进器行（赔金/赔粮，步长 500，最小 0） ============
    local function Stepper(opts)
        local minus = SmallButton("-", opts.onMinus, { width = 28, height = 28, paddingH = 0, fontSize = 15 })
        local plus  = SmallButton("+", opts.onPlus,  { width = 28, height = 28, paddingH = 0, fontSize = 15 })
        local valueLabel = UI.Label { text = "", fontSize = 13, fontColor = COLORS.gold, fontWeight = "bold" }
        local costLabel = UI.Label { text = "", fontSize = 10, fontColor = COLORS.textSecondary }
        local rowPanel = UI.Panel {
            height = 34,
            borderRadius = 6,
            paddingHorizontal = 8,
            backgroundColor = opts.bg,
            flexDirection = "row",
            alignItems = "center",
            gap = 6,
            width = "100%",
            children = {
                UI.Label { text = opts.title, fontSize = 12, fontColor = COLORS.textPrimary, flexGrow = 1 },
                minus,
                valueLabel,
                plus,
                costLabel,
            },
        }
        return rowPanel, minus, valueLabel, plus, costLabel
    end
    local goldRow, goldMinus, goldValueLabel, goldPlus, goldCostLabel =
        Stepper({
            bg = PEACE_ROW_A,
            title = "💰 战争赔款",
            onMinus = function()
                refs.peaceGold = math.max(0, (refs.peaceGold or 0) - 500)
                GameUI.refreshPeaceDialog(refs.gameState)
            end,
            onPlus = function()
                refs.peaceGold = (refs.peaceGold or 0) + 500
                GameUI.refreshPeaceDialog(refs.gameState)
            end,
        })
    refs.peaceGoldRow, refs.peaceGoldMinus, refs.peaceGoldValueLabel, refs.peaceGoldPlus, refs.peaceGoldCostLabel =
        goldRow, goldMinus, goldValueLabel, goldPlus, goldCostLabel
    local foodRow, foodMinus, foodValueLabel, foodPlus, foodCostLabel =
        Stepper({
            bg = PEACE_ROW_B,
            title = "粮草赔款",
            onMinus = function()
                refs.peaceFood = math.max(0, (refs.peaceFood or 0) - 500)
                GameUI.refreshPeaceDialog(refs.gameState)
            end,
            onPlus = function()
                refs.peaceFood = (refs.peaceFood or 0) + 500
                GameUI.refreshPeaceDialog(refs.gameState)
            end,
        })
    refs.peaceFoodRow, refs.peaceFoodMinus, refs.peaceFoodValueLabel, refs.peaceFoodPlus, refs.peaceFoodCostLabel =
        foodRow, foodMinus, foodValueLabel, foodPlus, foodCostLabel

    -- ============ 条款卡片：附庸 30 分（toggle）/ 吞并全境（确认后走灭国流程） ============
    refs.peaceVassalIcon = UI.Label { text = "", fontSize = 13, fontColor = PEACE_SEL_BORDER, fontWeight = "bold", width = 18 }
    local vassalTitle = UI.Label { text = "要求附庸", fontSize = 13, fontColor = COLORS.textPrimary, fontWeight = "bold" }
    local vassalCost = UI.Label { text = "30分", fontSize = 11, fontColor = COLORS.gold, fontWeight = "bold" }
    refs.peaceVassalCard = UI.Button {
        height = 60,
        flexGrow = 1,
        borderRadius = 6,
        borderWidth = 1,
        borderColor = { 80, 90, 115, 200 },
        backgroundColor = { 20, 26, 38, 220 },
        hoverBackgroundColor = { 255, 255, 255, 18 },
        pressedBackgroundColor = { 255, 255, 255, 30 },
        flexDirection = "row",
        alignItems = "center",
        gap = 4,
        paddingHorizontal = 10,
        onClick = function()
            refs.peaceVassal = not (refs.peaceVassal == true)
            GameUI.refreshPeaceDialog(refs.gameState)
        end,
        children = { refs.peaceVassalIcon, vassalTitle, UI.Panel { flexGrow = 1 }, vassalCost },
    }
    local annexTitle = UI.Panel {
        flexDirection = "row", alignItems = "center", gap = 5,
        children = {
            UI.Panel { width = 14, height = 14, backgroundImage = "image/icon_war_双剑交叉.png", backgroundFit = "contain" },
            UI.Label { text = "吞并全境", fontSize = 13, fontColor = COLORS.textPrimary, fontWeight = "bold" },
        },
    }
    local annexCost = UI.Label { text = "全部", fontSize = 11, fontColor = COLORS.gold, fontWeight = "bold" }
    refs.peaceAnnexCard = UI.Button {
        height = 60,
        flexGrow = 1,
        borderRadius = 6,
        borderWidth = 1,
        borderColor = { 80, 90, 115, 200 },
        backgroundColor = { 20, 26, 38, 220 },
        hoverBackgroundColor = { 255, 255, 255, 18 },
        pressedBackgroundColor = { 255, 255, 255, 30 },
        flexDirection = "row",
        alignItems = "center",
        gap = 4,
        paddingHorizontal = 10,
        onClick = function()
            GameUI.showAnnexConfirm()   -- 走既有灭国确认流程
        end,
        children = { annexTitle, UI.Panel { flexGrow = 1 }, annexCost },
    }
    local cardsRow = UI.Panel {
        flexDirection = "row",
        gap = 6,
        width = "100%",
        children = { refs.peaceVassalCard, refs.peaceAnnexCard },
    }

    -- ============ 区域 D：要求割让省份（标题 + 全选/重置 + 纵向行列表） ============
    refs.peaceSelectAllBtn = SmallButton("全选占领", function()
        local gs = refs.gameState
        local cfg = refs.peaceCfg
        if not gs or not cfg then return end
        local sel = refs.peaceSelection or {}
        for pid in pairs(refs.peacePickableIds or {}) do
            local prov = gs.provinces[pid]
            if prov and prov.occupiedBy == cfg.proposerId then
                sel[pid] = true
            end
        end
        refs.peaceSelection = sel
        GameUI.refreshPeaceDialog(gs)
    end, { height = 24, fontSize = 11, paddingH = 8 })
    refs.peaceClearBtn = SmallButton("重置", function()
        refs.peaceSelection = {}
        GameUI.refreshPeaceDialog(refs.gameState)
    end, { height = 24, fontSize = 11, paddingH = 8 })
    local provSectionHeader = UI.Panel {
        height = 30,
        borderRadius = 6,
        paddingHorizontal = 10,
        backgroundColor = PEACE_SECTION_BG,
        flexDirection = "row",
        alignItems = "center",
        gap = 6,
        width = "100%",
        children = {
            UI.Label { text = "要求割让省份", fontSize = 13, fontColor = PEACE_SECTION_TEXT, fontWeight = "bold", flexGrow = 1 },
            refs.peaceSelectAllBtn,
            refs.peaceClearBtn,
        },
    }
    refs.peaceProvList = UI.Panel { flexDirection = "column", gap = 4, width = "100%", children = {} }
    refs.peaceProvEmpty = UI.Label {
        text = "无可索取的省份",
        fontSize = 12,
        fontColor = COLORS.textSecondary,
        width = "100%",
        textAlign = "center",
        padding = 8,
    }
    refs.peaceProvEmpty:Hide()

    -- ============ 区域 F：缔结栏（钉在滚动末尾；超预算禁用+红字） ============
    refs.peaceOverLabel = UI.Label {
        text = "",
        fontSize = 11,
        fontColor = PEACE_WARN_RED,
        textAlign = "center",
    }
    refs.peaceOverLabel:Hide()
    refs.peaceSubmitBtn = SmallButton("🏆 缔结条约", function()
        local cfg = refs.peaceCfg
        if not cfg or cfg.mode ~= "propose" then return end
        if callbacks.onSubmitPeace then callbacks.onSubmitPeace(cfg) end
    end, { height = 44, fontSize = 14, bg = COLORS.btnSuccess, hoverBg = COLORS.btnSuccessHover })

    -- ============ propose 交互区（预算/条件/省份/缔结） ============
    refs.peaceProposeBox = UI.Panel {
        flexDirection = "column",
        gap = 8,
        padding = 12,
        width = "100%",
        children = {
            budgetRow,
            SectionTitle("条 件"),
            goldRow,
            foodRow,
            cardsRow,
            provSectionHeader,
            refs.peaceProvList,
            refs.peaceProvEmpty,
            UI.Panel {
                flexDirection = "column",
                gap = 4,
                width = "100%",
                children = { refs.peaceOverLabel, refs.peaceSubmitBtn },
            },
        },
    }

    -- ============ respond 区：只读文书 + 接受/拒绝 ============
    refs.peaceRespondList = UI.Panel { flexDirection = "column", gap = 6, width = "100%", children = {} }
    refs.peaceAccept = SmallButton("接受", function()
        if callbacks.onAcceptPeace then callbacks.onAcceptPeace() end
    end, { height = 44, fontSize = 14, bg = COLORS.btnSuccess, hoverBg = COLORS.btnSuccessHover, flexGrow = 1 })
    refs.peaceReject = SmallButton("拒绝", function()
        if callbacks.onRejectPeace then callbacks.onRejectPeace() end
    end, { height = 44, fontSize = 14, bg = COLORS.btnDanger, hoverBg = COLORS.btnDangerHover, flexGrow = 1 })
    refs.peaceRespondBox = UI.Panel {
        flexDirection = "column",
        gap = 10,
        padding = 12,
        width = "100%",
        children = {
            UI.Label { text = "── 对方提出 ──", fontSize = 12, fontColor = COLORS.textSecondary, textAlign = "center", width = "100%" },
            refs.peaceRespondList,
            UI.Divider { color = { 150, 120, 70, 160 }, thickness = 1 },
            UI.Label { text = "── 是否接受？──", fontSize = 12, fontColor = COLORS.textSecondary, textAlign = "center", width = "100%" },
            UI.Panel {
                flexDirection = "row",
                gap = 8,
                width = "100%",
                children = { refs.peaceAccept, refs.peaceReject },
            },
        },
    }
    refs.peaceRespondBox:Hide()

    -- ============ 灭国确认层（专门胜利结算流程的确认环节，覆盖全屏） ============
    refs.annexConfirmTitle = UI.Label {
        text = "确认灭亡",
        fontSize = 20,
        fontColor = { 255, 120, 100, 255 },
        fontWeight = "bold",
    }
    refs.annexConfirmBody = UI.Label {
        text = "",
        fontSize = 14,
        fontColor = COLORS.textPrimary,
        whiteSpace = "normal",
        maxLines = 4,
    }
    local annexConfirmYes = SmallButton("确认灭亡", function()
        -- 确认 → 标记吞并全部 → 提交条约（走 submitPeace 的 annexAll 分支，系统自动播报灭亡）
        refs.peaceAnnex = true
        local cfg = refs.peaceCfg
        if cfg and cfg.mode == "propose" and callbacks.onSubmitPeace then
            callbacks.onSubmitPeace(cfg)
        end
    end, { height = 44, fontSize = 14, bg = COLORS.btnDanger, hoverBg = COLORS.btnDangerHover, flexGrow = 1 })
    local annexConfirmNo = SmallButton("取消", function()
        GameUI.hideAnnexConfirm()
    end, { height = 44, fontSize = 14, flexGrow = 1 })
    refs.annexConfirmOverlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 150 },
        alignItems = "center",
        justifyContent = "center",
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 380,
                backgroundColor = { 18, 22, 34, 245 },
                borderRadius = 12,
                borderWidth = 1,
                borderColor = { 200, 100, 90, 220 },
                padding = 20,
                gap = 12,
                children = {
                    refs.annexConfirmTitle,
                    UI.Divider { color = { 200, 100, 90, 140 }, thickness = 1 },
                    refs.annexConfirmBody,
                    UI.Panel {
                        flexDirection = "row",
                        gap = 8,
                        width = "100%",
                        children = { annexConfirmYes, annexConfirmNo },
                    },
                },
            },
        },
    }
    refs.annexConfirmOverlay:Hide()

    -- ============ 和平条约：左侧全高面板（区域 A–F），其余区域透明可点地图 ============
    refs.peaceDialog = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 0 },
        pointerEvents = "box-none",
        children = {
            -- 左侧滚动面板（宽 420/460，小屏自动收窄；内容超高可纵向滚动）
            UI.ScrollView {
                position = "absolute",
                top = 56, left = 12, bottom = 12,
                width = panelW,
                backgroundColor = PEACE_PANEL_BG,
                borderRadius = 10,
                borderWidth = 1,
                borderColor = PEACE_GOLD_BORDER,
                flexDirection = "column",
                gap = 8,
                showScrollbar = false,
                children = {
                    -- 区域 A：标题栏
                    UI.Panel {
                        height = 46,
                        width = "100%",
                        borderRadiusTopLeft = 10,
                        borderRadiusTopRight = 10,
                        backgroundColor = PEACE_HEADER_BG,
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 8,
                        paddingHorizontal = 12,
                        children = {
                            UI.Panel {
                                flexGrow = 1,
                                flexDirection = "column",
                                gap = 2,
                                children = { refs.peaceTitleText, refs.peaceSubTitle },
                            },
                            closeBtn,
                        },
                    },
                    -- 区域 B：双方横幅 + 战争分数
                    UI.Panel {
                        width = "100%",
                        flexDirection = "column",
                        gap = 8,
                        paddingHorizontal = 12,
                        paddingTop = 4,
                        children = {
                            UI.Panel {
                                flexDirection = "row",
                                alignItems = "center",
                                justifyContent = "center",
                                gap = 8,
                                width = "100%",
                                children = {
                                    UI.Panel {
                                        flexDirection = "row",
                                        alignItems = "center",
                                        gap = 5,
                                        children = { refs.peaceColorBlockA, refs.peaceSideAName },
                                    },
                                    UI.Panel { width = 14, height = 14, backgroundImage = "image/icon_war_双剑交叉.png", backgroundFit = "contain" },
                                    UI.Panel {
                                        flexDirection = "row",
                                        alignItems = "center",
                                        gap = 5,
                                        children = { refs.peaceSideBName, refs.peaceColorBlockB },
                                    },
                                },
                            },
                            UI.Panel {
                                flexDirection = "row",
                                alignItems = "center",
                                justifyContent = "center",
                                gap = 6,
                                width = "100%",
                                children = {
                                    UI.Label { text = "战争分数：", fontSize = 13, fontColor = COLORS.textSecondary },
                                    refs.peaceScoreValue,
                                },
                            },
                        },
                    },
                    refs.peaceProposeBox,
                    refs.peaceRespondBox,
                },
            },
            -- 灭国确认层（全屏遮罩，zIndex 高于面板）
            refs.annexConfirmOverlay,
        },
    }
    refs.peaceDialog:Hide()
    return refs.peaceDialog
end

-- ============================================================
-- 3.75.1) 灭国确认层（专门胜利结算流程）
-- ============================================================

--- 打开灭国确认：显示国名 / 省数 / 战争分数，让玩家明确这是决定性胜利
function GameUI.showAnnexConfirm()
    local overlay = refs.annexConfirmOverlay
    if not overlay then return end
    local gs = refs.gameState
    local cfg = refs.peaceCfg
    local t = cfg and cfg.targetId
    local f = gs and gs.factions[t]
    local name = f and (f.fullName or f.name) or "该诸侯"
    local provCount = f and #(f.provinces or {}) or 0
    local score = refs.peaceScore or 0
    refs.annexConfirmBody.text = string.format(
        "你正要对 %s 发起灭亡之战——\n将吞并其全部 %d 座城邑（战争分数 %d，可覆盖）。\n\n此役后将再无 %s，史书会记录这一天。",
        name, provCount, math.floor(score), name)
    overlay:Show()
end

--- 关闭灭国确认层
function GameUI.hideAnnexConfirm()
    if refs.annexConfirmOverlay then refs.annexConfirmOverlay:Hide() end
end

-- ============================================================
-- 3.7) War Alert（大战略战争警报：左侧紧凑浮层）
-- ============================================================

function GameUI.showWarAlert(alert)
    if not refs.warAlertPanel then return end
    refs.warAlert = alert
    local isLost = alert.kind == "province_lost"
    local isStarted = alert.kind == "battle_started"
    refs.warAlertTitle:SetText(isLost and "领地失守" or (isStarted and "战争警报" or "战斗报告"))
    refs.warAlertTitle:SetFontColor(isLost and { 255, 130, 100, 255 } or { 255, 215, 120, 255 })
    refs.warAlertBody:SetText(alert.text or "新的战争事件需要你的处理")
    refs.warAlertLocation:SetText("事发地：" .. (alert.provinceName or "未知省份"))
    refs.warAlertPanel:Show()
end

function GameUI.hideWarAlert()
    if refs.warAlertPanel then refs.warAlertPanel:Hide() end
    refs.warAlert = nil
end

function GameUI.isWarAlertVisible()
    return refs.warAlertPanel and refs.warAlertPanel:IsVisible() or false
end

function GameUI.getWarAlert()
    return refs.warAlert
end

local function createWarAlertPanel(callbacks)
    refs.warAlertTitle = UI.Label {
        text = "战争警报",
        fontSize = 19,
        fontColor = { 255, 215, 120, 255 },
        fontWeight = "bold",
    }
    refs.warAlertBody = UI.Label {
        text = "",
        fontSize = 15,
        fontColor = COLORS.textPrimary,
        whiteSpace = "normal",
        maxLines = 2,
    }
    refs.warAlertLocation = UI.Label {
        text = "",
        fontSize = 14,
        fontColor = { 190, 200, 215, 230 },
    }

    local focusBtn = UI.Button {
        text = "查看战场",
        height = 48,
        flexGrow = 1,
        fontSize = 15,
        textColor = { 255, 220, 145, 255 },
        backgroundColor = { 92, 64, 38, 235 },
        hoverBackgroundColor = { 92, 64, 38, 235 },
        pressedBackgroundColor = { 68, 46, 28, 245 },
        borderWidth = 1,
        borderColor = { 180, 130, 65, 220 },
        borderRadius = 6,
        onClick = function()
            local alert = refs.warAlert
            if callbacks.onWarAlertFocus and alert then
                callbacks.onWarAlertFocus(alert)
            end
            GameUI.hideWarAlert()
        end,
    }
    local resumeBtn = UI.Button {
        text = "继续时间",
        height = 48,
        flexGrow = 1,
        fontSize = 15,
        textColor = { 180, 255, 190, 255 },
        backgroundColor = { 42, 92, 58, 235 },
        hoverBackgroundColor = { 42, 92, 58, 235 },
        pressedBackgroundColor = { 32, 70, 44, 245 },
        borderWidth = 1,
        borderColor = { 90, 180, 105, 220 },
        borderRadius = 6,
        onClick = function()
            GameUI.hideWarAlert()
            if callbacks.onWarAlertResume then callbacks.onWarAlertResume() end
        end,
    }
    local holdBtn = UI.Button {
        text = "保持暂停",
        height = 48,
        flexGrow = 1,
        fontSize = 15,
        textColor = { 225, 225, 235, 255 },
        backgroundColor = { 50, 58, 76, 235 },
        hoverBackgroundColor = { 50, 58, 76, 235 },
        pressedBackgroundColor = { 38, 44, 60, 245 },
        borderWidth = 1,
        borderColor = { 110, 125, 150, 220 },
        borderRadius = 6,
        onClick = function()
            GameUI.hideWarAlert()
        end,
    }

    refs.warAlertPanel = UI.Panel {
        position = "absolute",
        top = 56,
        left = 12,
        width = "92%",
        maxWidth = 420,
        backgroundColor = { 13, 18, 28, 225 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = { 170, 105, 55, 230 },
        padding = 12,
        gap = 8,
        pointerEvents = "auto",
        children = {
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                width = "100%",
                children = {
                    refs.warAlertTitle,
                    UI.Label {
                        text = "时间已暂停",
                        fontSize = 13,
                        fontColor = { 255, 185, 95, 255 },
                    },
                },
            },
            UI.Divider { color = { 120, 85, 55, 180 }, thickness = 1 },
            refs.warAlertBody,
            refs.warAlertLocation,
            UI.Panel {
                flexDirection = "row",
                gap = 6,
                width = "100%",
                children = { focusBtn, resumeBtn, holdBtn },
            },
        },
    }
    refs.warAlertPanel:Hide()
    return refs.warAlertPanel
end

-- ============================================================
-- 3.8) Policy / Tech Panels（框架占位，2026-09-01）
function GameUI.togglePolicyPanel()
    if refs.policyPanel and refs.policyPanel:IsVisible() then
        refs.policyPanel:Hide()
    else
        refs.policyPanel:Show()
    end
end

function GameUI.toggleTechPanel()
    if refs.techPanel and refs.techPanel:IsVisible() then
        refs.techPanel:Hide()
    else
        refs.techPanel:Show()
    end
end

--- 政策面板（2026-09-01）：
---   变法区：一次性重大改革（绿=已行 金=可实行 灰=资源不足）
---   卡槽区：3+1 卡槽，换卡消耗资源并进入 HoI4 式实施进度（进度条+剩余天数）
local function createPolicyPanel(callbacks)
    -- ============ 变法区（方案 C） ============
    refs.policyReformBtns = {}
    local reformList = UI.Panel { width = "100%", gap = 6, children = {} }
    for _, def in ipairs(PolicySystem.REFORMS) do
        local btn = UI.Button {
            width = "100%",
            height = 44,
            paddingHorizontal = 10,
            borderRadius = 6,
            backgroundColor = { 40, 50, 70, 220 },
            flexDirection = "row",
            alignItems = "center",
            gap = 8,
            onClick = function()
                if callbacks.onReformActivate then callbacks.onReformActivate(def.id) end
            end,
            children = {
                UI.Label { text = def.id, fontSize = 14, fontColor = COLORS.textPrimary, fontWeight = "bold" },
                UI.Label {
                    text = def.desc,
                    fontSize = 11,
                    fontColor = COLORS.textSecondary,
                    flexGrow = 1,
                },
            },
        }
        refs.policyReformBtns[def.id] = btn
        reformList:AddChild(btn)
    end

    -- ============ 卡槽区（方案 A，3+1） ============
    refs.policySlotCards = {}   -- [slot][cardId] = btn
    refs.policySlotProg = {}    -- [slot] = { bar, text }
    local slotList = UI.Panel { width = "100%", gap = 12, children = {} }
    local ALL_SLOTS = { "economy", "military", "domestic", "wildcard" }
    for _, slot in ipairs(ALL_SLOTS) do
        local slotName = PolicySystem.SLOT_NAMES[slot]

        -- 实施进度条（HoI4 式：只有正在实施的槽显示）
        ---@type Widget
        local bar = UI.ProgressBar {
            value = 0,
            max = 1,
            height = 8,
            width = "100%",
            borderRadius = 4,
            backgroundColor = { 40, 45, 60, 200 },
            fillColor = "#50A0DC",
            showLabel = false,
        }
        bar:Hide()
        ---@type Widget
        local barText = UI.Label {
            text = "",
            fontSize = 11,
            fontColor = COLORS.textSecondary,
        }
        barText:Hide()

        -- 卡按钮行
        ---@type Widget
        local cardRow = UI.Panel {
            flexDirection = "row",
            gap = 6,
            width = "100%",
            children = {},
        }
        refs.policySlotCards[slot] = {}
        ---@type table[]
        local cardDefs = PolicySystem.CARDS[slot] or {}
        if slot == "wildcard" then
            -- 通配槽：收集所有分类的卡
            cardDefs = {}
            for _, cards in pairs(PolicySystem.CARDS) do
                for _, c in ipairs(cards) do
                    cardDefs[#cardDefs + 1] = c
                end
            end
        end
        for _, card in ipairs(cardDefs) do
            local btn = UI.Button {
                flexGrow = 1,
                height = 58,
                borderRadius = 6,
                backgroundColor = { 40, 50, 70, 220 },
                flexDirection = "column",
                alignItems = "center",
                justifyContent = "center",
                paddingHorizontal = 4,
                onClick = function()
                    if callbacks.onPolicyStart then callbacks.onPolicyStart(slot, card.id) end
                end,
                children = {
                    UI.Label {
                        text = card.id,
                        fontSize = 13,
                        fontColor = COLORS.textPrimary,
                        fontWeight = "bold",
                    },
                    UI.Label {
                        text = card.desc .. "  " .. card.cost .. "金 " .. card.days .. "天",
                        fontSize = 9,
                        fontColor = COLORS.textSecondary,
                    },
                },
            }
            refs.policySlotCards[slot][card.id] = btn
            cardRow:AddChild(btn)
        end

        ---@type Widget
        local slotBlock = UI.Panel {
            width = "100%",
            gap = 6,
            children = {
                UI.Label {
                    text = "◆ " .. slotName .. "槽",
                    fontSize = 13,
                    fontColor = COLORS.gold,
                    fontWeight = "bold",
                },
                bar,
                barText,
                cardRow,
            },
        }
        refs.policySlotProg[slot] = { bar = bar, text = barText }
        slotList:AddChild(slotBlock)
    end

    local closeBtn = SmallButton("X", function()
        GameUI.togglePolicyPanel()
    end, { width = 30, height = 30, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    local panel = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        onClick = function()
            GameUI.togglePolicyPanel()
        end,
        children = {
            UI.Panel {
                width = "92%",
                height = "80%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 12,
                gap = 10,
                pointerEvents = "auto",
                onClick = function() end,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            UI.Label {
                                text = "📜 国策",
                                fontSize = 16,
                                fontColor = COLORS.gold,
                                fontWeight = "bold",
                            },
                            closeBtn,
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        children = {
                            UI.Panel {
                                width = "100%",
                                gap = 10,
                                children = {
                                    UI.Label {
                                        text = "◆ 变法改革（一次性）",
                                        fontSize = 13,
                                        fontColor = COLORS.gold,
                                        fontWeight = "bold",
                                    },
                                    reformList,
                                    UI.Divider { color = COLORS.border, thickness = 1 },
                                    UI.Label {
                                        text = "◆ 政策卡槽（实施完成后生效）",
                                        fontSize = 13,
                                        fontColor = COLORS.gold,
                                        fontWeight = "bold",
                                    },
                                    slotList,
                                },
                            },
                        },
                    },
                },
            },
        },
    }
    panel:Hide()
    refs.policyPanel = panel
    return panel
end

--- 刷新政策面板（变法状态 / 卡槽高亮 / 实施进度）
---@param gameState table
function GameUI.refreshPolicyPanel(gameState)
    if not refs.policyPanel or not refs.policyPanel:IsVisible() then return end
    local pid = gameState.playerFactionId
    local f = pid and gameState.factions[pid]
    if not f then return end

    -- 变法按钮状态
    for reformId, btn in pairs(refs.policyReformBtns) do
        local state = PolicySystem.getReformState(f, reformId)
        if state == "done" then
            btn.props.backgroundColor = { 30, 85, 55, 230 }
            btn.props.borderWidth = 1
            btn.props.borderColor = { 80, 220, 110, 255 }
        elseif state == "active" then
            btn.props.backgroundColor = { 95, 80, 35, 230 }
            btn.props.borderWidth = 1
            btn.props.borderColor = { 255, 200, 50, 255 }
        else
            btn.props.backgroundColor = { 40, 45, 55, 220 }
            btn.props.borderWidth = 1
            btn.props.borderColor = { 80, 90, 105, 255 }
        end
    end

    -- 卡槽：当前生效卡金色高亮
    for slot, cards in pairs(refs.policySlotCards) do
        local activeCardId = PolicySystem.getActiveCard(f, slot)
        for cardId, btn in pairs(cards) do
            if cardId == activeCardId then
                btn.props.backgroundColor = { 95, 80, 35, 230 }
                btn.props.borderWidth = 2
                btn.props.borderColor = { 255, 200, 50, 255 }
            else
                btn.props.backgroundColor = { 40, 50, 70, 220 }
                btn.props.borderWidth = 1
                btn.props.borderColor = { 60, 70, 90, 200 }
            end
        end
    end

    -- 实施进度（HoI4 式：进度条 + 剩余天数）
    local prog = f.policyProgress
    for slot, cfg in pairs(refs.policySlotProg) do
        local show = prog and prog.slot == slot
        if show then
            local ratio = 1.0 - (prog.daysLeft / math.max(1, prog.totalDays))
            cfg.bar:SetValue(ratio)
            cfg.bar:Show()
            cfg.text.text = "实施中：" .. prog.cardId
                .. "　还需 " .. prog.daysLeft .. " 天"
            cfg.text:Show()
        else
            cfg.bar:Hide()
            cfg.text:Hide()
        end
    end
end

--- 科技节点（框架演示用）：按状态着色
---@param name string
---@param state string "researched"|"researchable"|"locked"
---@return Widget node
local function createTechNode(name, state)
    local bg, border, textColor, sub
    if state == "researched" then
        bg, border, textColor, sub = { 30, 85, 55, 230 }, { 80, 220, 110, 255 }, { 160, 255, 180, 255 }, "已研"
    elseif state == "researchable" then
        bg, border, textColor, sub = { 95, 80, 35, 230 }, { 255, 200, 50, 255 }, COLORS.gold, "可研"
    else
        bg, border, textColor, sub = { 38, 44, 56, 230 }, { 85, 95, 110, 255 }, { 130, 140, 155, 255 }, "🔒"
    end
    return UI.Panel {
        width = 92,
        height = 56,
        borderRadius = 8,
        borderWidth = 2,
        borderColor = border,
        backgroundColor = bg,
        justifyContent = "center",
        alignItems = "center",
        children = {
            UI.Label { text = name, fontSize = 14, fontColor = textColor, fontWeight = "bold" },
            UI.Label { text = sub, fontSize = 10, fontColor = textColor },
        },
    }
end

--- 科技树面板（框架，2026-09-01）：
--- 横向大长页、左侧初始科技向右高阶、列间连线表示前置、点外部/X 关闭
local function createTechPanel()
    -- 演示数据（后续替换为真实科技系统）
    local eras = {
        { name = "初始", techs = { "青铜", "农耕" } },
        { name = "百工", techs = { "冶铁", "牛耕" } },
        { name = "军制", techs = { "车战", "礼乐" } },
        { name = "变革", techs = { "步卒", "井田" } },
        { name = "霸业", techs = { "铁骑", "法家" } },
    }

    -- 横向内容：时代列 + 列间连线
    ---@type Widget
    local contentRow = UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        padding = 16,
        children = {},
    }
    for ei, era in ipairs(eras) do
        ---@type Widget
        local col = UI.Panel {
            flexDirection = "column",
            alignItems = "center",
            gap = 10,
            children = {
                UI.Label {
                    text = era.name,
                    fontSize = 12,
                    fontColor = COLORS.gold,
                    fontWeight = "bold",
                },
            },
        }
        for ti, techName in ipairs(era.techs) do
            if ti > 1 then
                -- 列内节点间竖线（同阶依赖示意）
                ---@type Widget
                local vLine = UI.Divider {
                    orientation = "vertical",
                    color = { 150, 170, 200, 150 },
                    thickness = 2,
                    height = 16,
                }
                col:AddChild(vLine)
            end
            -- 框架演示状态：第1列=已研，第2列第1个=可研，其余=锁定
            local state = "locked"
            if ei == 1 then state = "researched" end
            if ei == 2 and ti == 1 then state = "researchable" end
            col:AddChild(createTechNode(techName, state))
        end
        contentRow:AddChild(col)
        if ei < #eras then
            -- 列间横线（前置连接：研究完本列解锁下一列）
            ---@type Widget
            local hLine = UI.Divider {
                orientation = "horizontal",
                color = { 150, 170, 200, 160 },
                thickness = 2,
                width = 44,
            }
            contentRow:AddChild(hLine)
        end
    end

    local closeBtn = SmallButton("X", function()
        GameUI.toggleTechPanel()
    end, { width = 30, height = 30, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    local panel = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        onClick = function()
            -- 点击遮罩外部自动关闭
            GameUI.toggleTechPanel()
        end,
        children = {
            -- 内容容器：拦截点击（避免冒泡触发遮罩关闭）
            UI.Panel {
                width = "92%",
                height = "76%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 12,
                gap = 10,
                pointerEvents = "auto",
                onClick = function() end,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            UI.Label {
                                text = "🔬 科技（左低阶 → 右高阶）",
                                fontSize = 16,
                                fontColor = COLORS.gold,
                                fontWeight = "bold",
                            },
                            closeBtn,
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        scrollX = true,
                        scrollY = false,
                        children = { contentRow },
                    },
                },
            },
        },
    }
    panel:Hide()
    refs.techPanel = panel
    return panel
end

-- 地图模式定义（2026-09-01；布局 3×2 两行）
local MAP_MODES = {
    { id = "political", label = "国家", desc = "国家版图", detail = "默认模式：只显示国名与国家颜色（地区划分看「地区」模式）" },
    { id = "region",    label = "地区", desc = "只看地区", detail = "只显示省名与省界，不显示国名" },
    { id = "war",       label = "战争", desc = "参战国红", detail = "所有正在交战的国家领土红色高亮，只显示国名" },
    { id = "ally",      label = "盟友", desc = "盟友关系", detail = "点选国家：选中绿色、盟友蓝色、敌方红色、中立灰；只显示国名" },
    { id = "resource",  label = "资源", desc = "省份产出", detail = "省份上显示金/粮产出（放大可见）" },
    { id = "culture",   label = "文化", desc = "文化分布", detail = "文化模式开发中…" },
}

-- ============================================================
-- 3.9) Map Mode Panel（右下角地图模式切换，2026-09-01）
-- ============================================================
function GameUI.toggleMapModePanel()
    -- 常驻面板，无 toggle；此函数保留占位
end

local function createMapModePanel(callbacks)
    refs.mapModeDesc = UI.Label {
        text = "",
        fontSize = 12,
        fontColor = COLORS.textSecondary,
        whiteSpace = "normal",
        maxLines = 2,
    }
    refs.mapModeButtons = {}
    -- 3×2 两行布局（2026-09-01）：第 1 行 3 个，第 2 行 3 个
    local btnRow1 = UI.Panel { flexDirection = "row", gap = 6, children = {} }
    local btnRow2 = UI.Panel { flexDirection = "row", gap = 6, children = {} }
    for i, m in ipairs(MAP_MODES) do
        local btn = SmallButton(m.label, function()
            if callbacks.onSetMapMode then callbacks.onSetMapMode(m.id) end
        end, { width = 54, height = 38, fontSize = 13, bg = { 40, 50, 70, 220 } })
        -- 长按：临时显示该模式详细说明
        btn.props.onLongPressStart = function()
            refs.mapModeDesc.text = m.detail
        end
        btn.props.onLongPressEnd = function()
            if refs.gameState then
                GameUI.refreshMapModePanel(refs.gameState)
            end
        end
        refs.mapModeButtons[m.id] = btn
        if i <= 3 then
            btnRow1:AddChild(btn)
        else
            btnRow2:AddChild(btn)
        end
    end

    refs.mapModePanel = UI.Panel {
        position = "absolute",
        bottom = 12,
        right = 12,
        width = 210,
        gap = 6,
        alignItems = "flex-start",
        backgroundColor = COLORS.bgPanel,
        borderWidth = 1,
        borderColor = COLORS.border,
        borderRadius = 8,
        padding = 8,
        pointerEvents = "auto",
        children = {
            refs.mapModeDesc,
            btnRow1,
            btnRow2,
        },
    }
    return refs.mapModePanel
end

-- ============================================================
-- 3.91) Battle Cards（右下角模式面板左侧的战斗卡，2026-09-01）
--   每场战斗一张卡：攻方名+兵力 ⚔ 守方名+兵力 + 绿/红进度条
--   新的战斗卡向左延伸（不遮挡模式面板）
-- ============================================================
local function createBattleCards(callbacks)
    -- 横排（2026-09-01 修正）：从右向左排列，新战斗在左
    refs.battleCards = UI.Panel {
        flexDirection = "row",
        alignItems = "flex-start",
        gap = 6,
        pointerEvents = "auto",
        children = {},
    }
    refs.battleCardPanel = UI.Panel {
        position = "absolute",
        bottom = 12,
        right = 400,   -- 战争列表（right222 宽~180）左侧，底部一行
        gap = 4,
        alignItems = "flex-end",
        pointerEvents = "auto",
        children = { refs.battleCards },
    }
    refs.battleCardPanel:Hide()
    return refs.battleCardPanel
end

--- 刷新战斗卡列表（签名变化时重建；节流防闪烁）
---@param gameState table
function GameUI.refreshBattleCards(gameState)
    if not refs.battleCardPanel then return end
    -- 节流（2026-09-01）：兵力/进度每帧变化会频繁重建导致"一抽一抽"，限制 0.25s 一次
    local now = os.clock()
    if refs.lastBattleRefresh and (now - refs.lastBattleRefresh) < 0.25 then
        return
    end
    refs.lastBattleRefresh = now

    local battles = gameState.battles or {}
    local count = 0
    for _ in pairs(battles) do count = count + 1 end
    if count == 0 then
        refs.battleCardPanel:Hide()
        refs.battleFirstSeen = {}
        return
    end
    -- 记录战斗首次出现时间（新战斗排最左）
    refs.battleFirstSeen = refs.battleFirstSeen or {}
    for pid, _ in pairs(battles) do
        if not refs.battleFirstSeen[pid] then
            refs.battleFirstSeen[pid] = now
        end
    end
    for pid, _ in pairs(refs.battleFirstSeen) do
        if not battles[pid] then
            refs.battleFirstSeen[pid] = nil
        end
    end

    -- 签名（变化才重建）
    local sig = {}
    for pid, b in pairs(battles) do
        sig[#sig + 1] = pid .. ":" .. b.att.size .. ":" .. b.def.size .. ":" .. math.floor(b.progress * 100)
    end
    table.sort(sig)
    local sigStr = table.concat(sig, "|")
    if sigStr == (refs.lastBattleSig or "") then
        refs.battleCardPanel:Show()
        return
    end
    refs.lastBattleSig = sigStr

    -- 新战斗在前（向左排列）
    local pids = {}
    for pid, _ in pairs(battles) do pids[#pids + 1] = pid end
    table.sort(pids, function(a, b)
        return (refs.battleFirstSeen[a] or 0) > (refs.battleFirstSeen[b] or 0)
    end)

    refs.battleCards:ClearChildren()
    local pf = gameState.playerFactionId
    for i = 1, #pids do
        local pid = pids[i]
        local b = battles[pid]
        local prov = gameState.provinces[pid]
        local atkFac = gameState.factions[b.att.factionId]
        local defFac = gameState.factions[b.def.factionId]
        local atkName = atkFac and atkFac.name or "?"
        local defName = defFac and defFac.name or "?"
        local green = true
        if pf then
            if b.att.factionId == pf then
                green = b.progress >= 0
            elseif b.def.factionId == pf then
                green = b.progress <= 0
            end
        end
        local card = UI.Panel {
            width = 170,
            height = 120,
            gap = 4,
            padding = 8,
            backgroundColor = { 15, 20, 32, 215 },
            borderRadius = 6,
            borderWidth = 1,
            borderColor = green and { 60, 200, 90, 255 } or { 220, 60, 60, 255 },
            children = {
                UI.Label {
                    text = string.format("%s %d vs %s %d", atkName, b.att.size, defName, b.def.size),
                    fontSize = 13,
                    fontColor = COLORS.textPrimary,
                    fontWeight = "bold",
                },
                UI.Label {
                    text = prov and ("📍 " .. prov.name) or "?",
                    fontSize = 11,
                    fontColor = COLORS.textSecondary,
                },
                UI.ProgressBar {
                    value = math.abs(b.progress),
                    max = 1,
                    height = 10,
                    width = "100%",
                    borderRadius = 4,
                    backgroundColor = { 50, 20, 20, 200 },
                    fillColor = green and "#3CC85A" or "#DC3C3C",
                    showLabel = false,
                },
                UI.Label {
                    text = green and "我方占优" or "我方劣势",
                    fontSize = 10,
                    fontColor = green and { 60, 200, 90, 255 } or { 220, 60, 60, 255 },
                },
            },
        }
        refs.battleCards:AddChild(card)
    end
    refs.battleCardPanel:Show()
end

--- 刷新地图模式面板（当前模式说明 + 按钮高亮）
---@param gameState table
function GameUI.refreshMapModePanel(gameState)
    if not refs.mapModePanel or not refs.mapModeButtons then return end
    local mode = gameState.mapMode or "political"
    local cur = nil
    for _, m in ipairs(MAP_MODES) do
        if m.id == mode then cur = m end
    end
    if cur then
        local extra = ""
        if mode == "ally" and gameState.allyViewFactionId then
            local vf = gameState.factions[gameState.allyViewFactionId]
            if vf then
                extra = "　视角:" .. (vf.name or "?")
            end
        end
        refs.mapModeDesc.text = "模式:" .. cur.label .. " " .. cur.desc .. extra
    end
    for mid, btn in pairs(refs.mapModeButtons) do
        if mid == mode then
            btn.props.backgroundColor = SPEED_BTN_ACTIVE.bg
            btn.props.hoverBackgroundColor = SPEED_BTN_ACTIVE.hover
            btn.props.textColor = SPEED_BTN_ACTIVE.textColor
        else
            btn.props.backgroundColor = { 40, 50, 70, 220 }
            btn.props.hoverBackgroundColor = { 60, 75, 100, 240 }
            btn.props.textColor = nil
        end
    end
end

-- ============================================================
-- 4) War List（右下角战争列表）
-- ============================================================
--- 立即刷新战争列表（宣战成功时调用，绕过节流延迟）
---@param gameState table
function GameUI.forceRefreshWarList(gameState)
    refs.lastWarRefresh = nil
    GameUI.refreshWarList(gameState)
end

--- 刷新右下战争列表（仅当战争集合变化时重建；节流防闪烁）
---@param gameState table
function GameUI.refreshWarList(gameState)
    if not refs.warList then return end
    -- 节流（2026-09-01）：分数每帧变化会频繁重建导致闪烁
    local now = os.clock()
    if refs.lastWarRefresh and (now - refs.lastWarRefresh) < 0.25 then
        return
    end
    refs.lastWarRefresh = now

    local pid = gameState.playerFactionId
    local wars = pid and WarSystem.getWarsFor(gameState, pid) or {}

    -- 构建签名：变化时才重建
    table.sort(wars, function(a, b) return a.enemyId < b.enemyId end)
    local sig = {}
    for i = 1, #wars do
        local w = wars[i]
        local myScore = math.floor(WarSystem.getScore(gameState, w.war, pid))
        local eScore = math.floor(WarSystem.getScore(gameState, w.war, w.enemyId))
        sig[i] = w.enemyId .. ":" .. myScore .. ":" .. eScore
    end
    local sigStr = table.concat(sig, ",")
    if sigStr == (refs.lastWarSig or "") then
        -- 内容没变：仅更新外层可见性
        if #wars > 0 then refs.warPanel:Show() else refs.warPanel:Hide() end
        return
    end
    refs.lastWarSig = sigStr

    refs.warList:ClearChildren()
    for i = 1, #wars do
        local w = wars[i]
        local enemy = gameState.factions[w.enemyId]
        -- 显示"谁打谁"（aId vs dId，2026-09-01）
        local aFaction = gameState.factions[w.war.aId]
        local dFaction = gameState.factions[w.war.dId]
        local aName = aFaction and aFaction.name or ("势力#" .. w.war.aId)
        local dName = dFaction and dFaction.name or ("势力#" .. w.war.dId)
        local myScore = WarSystem.getScore(gameState, w.war, pid)
        local eScore  = WarSystem.getScore(gameState, w.war, w.enemyId)
        local diff = myScore - eScore
        local absDiff = math.abs(diff)
        local barColor = diff >= 0 and COLORS.warGood or COLORS.warBad
        -- 优势条（2026-09-01）：中间白线=均势(0)
        --   我占优 → 绿色条从中间向左涨（涨到头=100%）
        --   我劣势 → 红色条从中间向右涨（领土被占满=100%）
        local greenPct = diff > 0 and math.min(50, absDiff / 2) or 0
        local redPct = diff < 0 and math.min(50, absDiff / 2) or 0

        local row = UI.Panel {
            width = 170,
            gap = 4,
            padding = 6,
            backgroundColor = { 15, 20, 32, 215 },
            borderRadius = 6,
            borderWidth = 1,
            borderColor = barColor,
            children = {
                UI.Label {
                    text = aName .. " vs " .. dName,
                    fontSize = 12,
                    fontColor = COLORS.textPrimary,
                    fontWeight = "bold",
                },
                -- 中间开始：左绿(我优) / 白线 / 右红(我劣)
                UI.Panel {
                    width = "100%",
                    height = 10,
                    flexDirection = "row",
                    alignItems = "center",
                    borderRadius = 4,
                    backgroundColor = { 40, 30, 30, 200 },
                    children = {
                        UI.Panel {
                            width = tostring(math.floor(greenPct)) .. "%",
                            height = 10,
                            backgroundColor = { 60, 200, 90, 235 },
                            borderRadius = 4,
                        },
                        UI.Panel {
                            width = 2,
                            height = 10,
                            backgroundColor = { 255, 255, 255, 180 },
                        },
                        UI.Panel {
                            width = tostring(math.floor(redPct)) .. "%",
                            height = 10,
                            backgroundColor = { 220, 60, 60, 235 },
                            borderRadius = 4,
                        },
                    },
                },
                UI.Label {
                    text = tostring(math.floor(absDiff)) .. "%",
                    fontSize = 11,
                    fontColor = barColor,
                    fontWeight = "bold",
                },
            },
        }
        refs.warList:AddChild(row)
    end

    if #wars > 0 then refs.warPanel:Show() else refs.warPanel:Hide() end
end

local function createWarList()
    refs.warList = UI.Panel { gap = 6, alignItems = "flex-end" }

    refs.warPanel = UI.Panel {
        position = "absolute",
        bottom = 12,
        right = 222,   -- 2026-09-01：底部一行，模式面板左侧
        gap = 6,
        alignItems = "flex-end",
        pointerEvents = "auto",
        children = { refs.warList },
    }
    refs.warPanel:Hide()
    return refs.warPanel
end

-- ============================================================
-- 5) Log Panel（日志）
-- ============================================================
function GameUI.showLog(gameState)
    if not refs.logOverlay then return end
    refs.logList:ClearChildren()
    local msgs = gameState.messages or {}
    for i = #msgs, 1, -1 do
        local m = msgs[i]
        local color = COLORS.textSecondary
        if m.type == "war" or m.type == "warning" then
            color = COLORS.relEnemy
        elseif m.type == "system" then
            color = COLORS.gold
        elseif m.type == "military" then
            color = COLORS.army
        end
        refs.logList:AddChild(UI.Label {
            text = m.text or "",
            fontSize = 11,
            fontColor = color,
            whiteSpace = "normal",
            maxLines = 3,
        })
    end
    refs.logOverlay:Show()
end

function GameUI.hideLog()
    if refs.logOverlay then refs.logOverlay:Hide() end
end

function GameUI.toggleLog()
    if refs.logOverlay and refs.logOverlay:IsVisible() then
        GameUI.hideLog()
    else
        GameUI.showLog(refs.gameState)
    end
end

local function createLogPanel()
    refs.logList = UI.Panel { width = "100%", gap = 4 }

    local closeBtn = SmallButton("X", function()
        GameUI.hideLog()
    end, { width = 28, height = 28, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    refs.logOverlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 340,
                height = "70%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 14,
                gap = 10,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            UI.Label {
                                text = "📜 大事记",
                                fontSize = 18,
                                fontColor = COLORS.gold,
                                fontWeight = "bold",
                            },
                            closeBtn,
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        children = { refs.logList },
                    },
                },
            },
        },
    }
    refs.logOverlay:Hide()
    return refs.logOverlay
end

-- ============================================================
-- 6) Settings Panel（设置菜单：保存 / 音乐 / 返回主菜单）
-- ============================================================
function GameUI.showSettings()
    if not refs.settingsOverlay then return end
    GameUI.refreshSettings()
    refs.settingsOverlay:Show()
end

function GameUI.hideSettings()
    if refs.settingsOverlay then refs.settingsOverlay:Hide() end
end

function GameUI.toggleSettings()
    if refs.settingsOverlay and refs.settingsOverlay:IsVisible() then
        GameUI.hideSettings()
    else
        GameUI.showSettings()
    end
end

--- 设置面板是否可见
function GameUI.isSettingsVisible()
    return refs.settingsOverlay ~= nil and refs.settingsOverlay:IsVisible()
end

--- 刷新设置面板（进入时同步音乐开关/音量/当前曲目状态）
function GameUI.refreshSettings()
    if not refs.settingsOverlay then return end
    -- 音乐开关
    if refs.settingsMusicBtn then
        local on = MusicManager.getEnabled()
        refs.settingsMusicBtn:SetText(on and "音乐：开" or "音乐：关")
    end
    -- 音量滑块
    if refs.musicVolumeSlider then
        refs.musicVolumeSlider:SetValue(MusicManager.getVolume())
        if refs.musicVolumeLabel then
            refs.musicVolumeLabel.text = "音量：" .. math.floor(MusicManager.getVolume() * 100) .. "%"
        end
    end
    -- 当前曲目
    if refs.musicCurrentLabel then
        refs.musicCurrentLabel.text = "正在播放：" .. (MusicManager.getCurrentName() or "无")
    end
end

local function createSettingsPanel(callbacks)
    refs.musicOn = MusicManager.getEnabled()
    -- 与主菜单设置弹窗统一：羊皮纸风格 + 手机触控尺寸
    refs.settingsMusicBtn = UI.Button {
        text = refs.musicOn and "音乐：开" or "音乐：关",
        width = "100%",
        height = 52,
        fontSize = 17,
        fontFamily = "gufeng",
        fontWeight = "bold",
        textColor = { 64, 42, 20, 255 },
        backgroundColor = { 255, 250, 236, 120 },
        hoverBackgroundColor = { 255, 244, 210, 190 },
        pressedBackgroundColor = { 214, 190, 148, 200 },
        borderColor = { 110, 82, 50, 200 },
        borderWidth = 1,
        borderRadius = 8,
        onClick = function(self)
            refs.musicOn = not refs.musicOn
            refs.settingsMusicBtn:SetText(refs.musicOn and "音乐：开" or "音乐：关")
            MusicManager.setEnabled(refs.musicOn)
            if callbacks.onToggleMusic then
                callbacks.onToggleMusic(refs.musicOn)
            end
        end,
    }

    -- 当前曲目显示
    refs.musicCurrentLabel = UI.Label {
        text = "正在播放：" .. (MusicManager.getCurrentName() or "无"),
        fontSize = 15,
        fontColor = { 90, 64, 38, 255 },
    }

    -- 曲目下拉选择（无缝切换）
    local musicOptions = {}
    local trackList = MusicManager.getTrackList()
    local curId = MusicManager.getCurrentId()
    for _, t in ipairs(trackList) do
        musicOptions[#musicOptions + 1] = { value = t.id, label = t.name }
    end
    if #musicOptions == 0 then
        musicOptions[1] = { value = "none", label = "（无可用曲目）" }
    end
    refs.musicDropdown = UI.Dropdown {
        options = musicOptions,
        value = curId,
        placeholder = "选择音乐",
        height = 46,
        triggerBgColor = { 72, 56, 38, 235 },
        width = "100%",
        onChange = function(self, value, option)
            MusicManager.play(value)
            if refs.musicCurrentLabel then
                refs.musicCurrentLabel.text = "正在播放：" .. (MusicManager.getCurrentName() or "无")
            end
        end,
    }

    -- 音量滑块（0~1）
    refs.musicVolumeLabel = UI.Label {
        text = "音量：" .. math.floor(MusicManager.getVolume() * 100) .. "%",
        fontSize = 15,
        fontColor = { 90, 64, 38, 255 },
    }
    refs.musicVolumeSlider = UI.Slider {
        min = 0,
        max = 1,
        step = 0.01,
        value = MusicManager.getVolume(),
        height = 40,
        trackHeight = 8,
        thumbSize = 26,
        trackBgColor = { 92, 70, 46, 200 },
        trackFillColor = { 172, 128, 62, 255 },
        thumbColor = { 122, 84, 40, 255 },
        onChange = function(self, value)
            MusicManager.setVolume(value)
            if refs.musicVolumeLabel then
                refs.musicVolumeLabel.text = "音量：" .. math.floor(value * 100) .. "%"
            end
        end,
    }

    local function paperActionBtn(label, color, onClick)
        return UI.Button {
            text = label,
            width = "100%",
            height = 52,
            fontSize = 17,
            fontFamily = "gufeng",
            fontWeight = "bold",
            textColor = color,
            backgroundColor = { 255, 250, 236, 120 },
            hoverBackgroundColor = { 255, 244, 210, 190 },
            pressedBackgroundColor = { 214, 190, 148, 200 },
            borderColor = { 110, 82, 50, 200 },
            borderWidth = 1,
            borderRadius = 8,
            onClick = onClick,
        }
    end

    local closeBtn = UI.Button {
        text = "X",
        width = 46,
        height = 46,
        fontSize = 24,
        textColor = { 250, 240, 222, 255 },
        fontWeight = "bold",
        fontFamily = "gufeng",
        backgroundColor = { 166, 42, 34, 255 },      -- 印章式：朱红印底
        hoverBackgroundColor = { 190, 58, 46, 255 },
        pressedBackgroundColor = { 138, 34, 26, 255 },
        borderRadius = 10,
        borderWidth = 2,
        borderColor = { 120, 26, 20, 255 },
        onClick = function()
            GameUI.hideSettings()
        end,
    }

    refs.settingsOverlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 170 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 440,
                backgroundImage = "image/panel_parchment_20260901161208.png",
                backgroundFit = "fill",
                paddingTop = 66,                      -- 下移避开纸顶深色卷边
                paddingBottom = 44,
                paddingHorizontal = 38,
                gap = 14,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            -- 题签：浅色衬底小纸条，压在深色褶皱上也清晰
                            UI.Panel {
                                backgroundColor = { 250, 240, 214, 215 },
                                borderRadius = 8,
                                borderWidth = 1,
                                borderColor = { 150, 118, 76, 200 },
                                paddingHorizontal = 16,
                                paddingVertical = 6,
                                children = {
                                    UI.Label {
                                        text = "设置",
                                        fontSize = 24,
                                        fontFamily = "gufeng",
                                        fontColor = { 64, 42, 20, 255 },
                                        fontWeight = "bold",
                                    },
                                },
                            },
                            closeBtn,
                        },
                    },
                    UI.Divider { color = { 110, 82, 50, 160 }, thickness = 1 },
                    paperActionBtn("保存游戏", { 64, 42, 20, 255 }, function()
                        if callbacks.onSave then callbacks.onSave() end
                    end),
                    paperActionBtn("读取存档", { 64, 42, 20, 255 }, function()
                        if callbacks.onLoadGame then callbacks.onLoadGame() end
                    end),
                    -- ===== 音乐区 =====
                    UI.Label {
                        text = "音　乐",
                        fontSize = 18,
                        fontFamily = "gufeng",
                        fontColor = { 64, 42, 20, 255 },
                        fontWeight = "bold",
                    },
                    refs.settingsMusicBtn,
                    refs.musicCurrentLabel,
                    refs.musicDropdown,
                    refs.musicVolumeLabel,
                    refs.musicVolumeSlider,
                    UI.Divider { color = { 110, 82, 50, 160 }, thickness = 1 },
                    paperActionBtn("返回主菜单", { 146, 58, 40, 255 }, function()
                        if callbacks.onExitToMenu then callbacks.onExitToMenu() end
                    end),
                },
            },
        },
    }
    refs.settingsOverlay:Hide()
    return refs.settingsOverlay
end

-- ============================================================
-- 7) Diplomacy Panel（外交，保留）
-- ============================================================
local function createRelationBar(value)
    local normalized = (value + 100) / 200
    local barColor
    if value < -30 then
        barColor = COLORS.relEnemy
    elseif value > 30 then
        barColor = COLORS.relFriendly
    else
        barColor = COLORS.relNeutral
    end

    return UI.Panel {
        width = "100%",
        height = 8,
        borderRadius = 4,
        backgroundColor = { 40, 45, 60, 200 },
        children = {
            UI.Panel {
                width = tostring(math.max(2, math.floor(normalized * 100))) .. "%",
                height = "100%",
                borderRadius = 4,
                backgroundColor = barColor,
            },
        },
    }
end

local function createFactionRow(faction, relation, callbacks)
    local relValue = relation or 0
    local relColor
    if relValue < -30 then
        relColor = COLORS.relEnemy
    elseif relValue > 30 then
        relColor = COLORS.relFriendly
    else
        relColor = COLORS.relNeutral
    end

    local statusText = ""
    if faction.atWar then
        statusText = " [交战]"
    end

    return UI.Panel {
        width = "100%",
        padding = 8,
        gap = 6,
        backgroundColor = { 30, 35, 50, 200 },
        borderRadius = 4,
        borderWidth = 1,
        borderColor = { 50, 55, 70, 150 },
        children = {
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                width = "100%",
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 6,
                        children = {
                            UI.Panel {
                                width = 10, height = 10,
                                borderRadius = 5,
                                backgroundColor = faction.color or { 150, 150, 150, 255 },
                            },
                            UI.Label {
                                text = (faction.name or "???") .. statusText,
                                fontSize = 13,
                                fontColor = COLORS.textPrimary,
                                fontWeight = "bold",
                            },
                        },
                    },
                    UI.Label {
                        text = tostring(relValue),
                        fontSize = 12,
                        fontColor = relColor,
                        fontWeight = "bold",
                    },
                },
            },
            createRelationBar(relValue),
            UI.Panel {
                flexDirection = "row",
                gap = 6,
                marginTop = 2,
                children = {
                    SmallButton("改善关系", function()
                        if callbacks.onImproveRelation then
                            callbacks.onImproveRelation(faction.id)
                        end
                    end, { fontSize = 11, height = 32 }),
                    SmallButton("宣战", function()
                        if callbacks.onDeclareWar then
                            callbacks.onDeclareWar(faction.id)
                        end
                    end, { fontSize = 11, height = 32, bg = COLORS.btnDanger, hoverBg = COLORS.btnDangerHover }),
                    SmallButton("求和", function()
                        if callbacks.onProposePeace then
                            callbacks.onProposePeace(faction.id)
                        end
                    end, { fontSize = 11, height = 32 }),
                },
            },
        },
    }
end

local function createDiplomacyPanel(gameState, callbacks)
    refs.diploFactionList = UI.Panel {
        width = "100%",
        gap = 8,
    }

    local closeDiploBtn = SmallButton("X", function()
        GameUI.hideDiplomacy()
    end, { width = 28, height = 28, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    local headerRow = UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        justifyContent = "space-between",
        width = "100%",
        children = {
            UI.Label {
                text = "外交关系",
                fontSize = 18,
                fontColor = COLORS.gold,
                fontWeight = "bold",
            },
            closeDiploBtn,
        },
    }

    refs.diploOverlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 340,
                maxHeight = "80%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 16,
                gap = 12,
                children = {
                    headerRow,
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        maxHeight = 420,
                        children = {
                            refs.diploFactionList,
                        },
                    },
                },
            },
        },
    }
    refs.diploOverlay:Hide()

    return refs.diploOverlay
end

-- ============================================================
-- 7) Zoom Controls（已移除：手机用双指捏合缩放，2026-08-29）
-- ============================================================

-- ============================================================
-- Public API
-- ============================================================

--- Create the full game UI overlay.
function GameUI.create(gameState, callbacks)
    callbacks = callbacks or {}
    refs = {}
    refs.callbacks = callbacks
    refs.gameState = gameState
    refs.selectedProvinceId = nil
    refs.selectedOwnerId = nil
    refs.lastWarSig = ""

    local topBar = createTopBar(gameState, callbacks)
    local provincePanel = createProvincePanel(gameState, callbacks)
    local rankingPanel = createRankingPanel()
    local speedMenu = createSpeedMenu(callbacks)
    local nationPanel = createNationPanel(callbacks)
    local warPanel = createWarList()
    local mapModePanel = createMapModePanel(callbacks)
    local battleCardPanel = createBattleCards(callbacks)
    local warAlertPanel = createWarAlertPanel(callbacks)
    local logPanel = createLogPanel()
    local peaceDialog = createPeaceDialog(callbacks)
    local policyPanel = createPolicyPanel()
    local techPanel = createTechPanel()
    local settingsPanel = createSettingsPanel(callbacks)
    local diplomacyPanel = createDiplomacyPanel(gameState, callbacks)

    local root = UI.Panel {
        position = "absolute",
        top = 0,
        left = 0,
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            topBar,
            provincePanel,
            rankingPanel,
            speedMenu,
            nationPanel,
            warPanel,
            mapModePanel,
            battleCardPanel,
            warAlertPanel,
            logPanel,
            peaceDialog,
            policyPanel,
            techPanel,
            settingsPanel,
            diplomacyPanel,
        },
    }

    refs.rootPanel = root

    -- Initial update
    GameUI.update(gameState)

    return root
end

--- Update all UI labels and values from current game state.
function GameUI.update(gameState, timeSystem)
    if not refs.rootPanel then return end

    -- 顶栏：国家名 + 资源
    local pid = gameState.playerFactionId
    local pf = pid and gameState.factions[pid] or nil
    if pf then
        refs.topNation:SetText(pf.name or "?")
        refs.topGold.children[2].text = fmtNum(pf.gold)
        refs.topFood.children[2].text = fmtNum(pf.food)
        refs.topArmy.children[2].text = fmtNum(pf.armySize)
        refs.topPrestige.children[2].text = fmtNum(pf.prestige)
    else
        refs.topNation:SetText("观战")
        refs.topGold.children[2].text = "-"
        refs.topFood.children[2].text = "-"
        refs.topArmy.children[2].text = "-"
        refs.topPrestige.children[2].text = "-"
    end
    -- 时间大筐（合并暂停/开始）："⏸ 春 -770年 1月 15日" / 暂停时 "▶ …"，点击切换
    if timeSystem and timeSystem.getShortDate then
        local icon = gameState.paused and "▶" or "⏸"
        refs.topDate:SetText(icon .. " " .. timeSystem.getShortDate())
    end

    -- 时间流速长条文本 + 弹出菜单当前档高亮
    local SPEED_LABELS = { "慢", "缓", "常", "快", "极" }
    local curSpeed = gameState.speed or 0
    if refs.speedBar then
        refs.speedBar:SetText("时间流速:" .. (SPEED_LABELS[curSpeed] or "-"))
    end
    for i = 1, 5 do
        local btn = refs.speedMenuButtons[i]
        if btn then
            if i == curSpeed then
                btn.props.backgroundColor  = SPEED_BTN_ACTIVE.bg
                btn.props.hoverBackgroundColor = SPEED_BTN_ACTIVE.hover
                btn.props.pressedBackgroundColor = SPEED_BTN_ACTIVE.pressed
                btn.props.textColor = SPEED_BTN_ACTIVE.textColor
            else
                btn.props.backgroundColor  = { 40, 50, 70, 220 }
                btn.props.hoverBackgroundColor = { 60, 75, 100, 240 }
                btn.props.pressedBackgroundColor = { 50, 60, 80, 240 }
                btn.props.textColor = nil
            end
        end
    end

    -- 国家面板（君主 / 税率 / 稳定度）
    if refs.nationPanel and refs.nationPanel:IsVisible() and pf then
        refs.nationName.text = pf.fullName or pf.name or "?"
        local leader = pf.leader
        if leader then
            refs.nationLeader.text = "君主：" .. leader.name .. "（" .. tostring(leader.age) .. "岁）"
            refs.nationAbility.text = string.format("文治 %d    武功 %d    外交 %d",
                leader.admin, leader.military, leader.diplo)
        else
            refs.nationLeader.text = "君主：无"
            refs.nationAbility.text = ""
        end
        refs.nationStability.text = "稳定度：" .. math.floor(pf.stability or 0) .. "%"

        -- 税率档位高亮
        local tl = pf.taxLevel or GameConfig.Economy.DEFAULT_TAX or 2
        for i = 1, #refs.taxButtons do
            local btn = refs.taxButtons[i]
            if btn then
                if i == tl then
                    btn.props.backgroundColor = SPEED_BTN_ACTIVE.bg
                    btn.props.hoverBackgroundColor = SPEED_BTN_ACTIVE.hover
                    btn.props.pressedBackgroundColor = SPEED_BTN_ACTIVE.pressed
                    btn.props.textColor = SPEED_BTN_ACTIVE.textColor
                else
                    btn.props.backgroundColor = SPEED_BTN_NORMAL.bg
                    btn.props.hoverBackgroundColor = SPEED_BTN_NORMAL.hover
                    btn.props.pressedBackgroundColor = SPEED_BTN_NORMAL.pressed
                    btn.props.textColor = nil
                end
            end
        end
        local entry = GameConfig.Economy.TAX_RATES[tl]
        if entry then
            local stabTxt = entry.stability > 0 and ("+" .. entry.stability) or tostring(entry.stability)
            local growthTxt = entry.growth > 0
                and ("+" .. math.floor(entry.growth * 100))
                or tostring(math.floor(entry.growth * 100))
            refs.taxHint.text = string.format(
                "收入x%.1f | 稳定%s/月 | 人口增长%s%%/月",
                entry.rate, stabTxt, growthTxt)
        end
    end

    -- 省份面板
    if refs.provincePanel:IsVisible() and refs.selectedProvinceId then
        local prov = gameState.provinces and gameState.provinces[refs.selectedProvinceId]
        if prov then
            refs.provName.text = prov.name or "---"
            refs.provTerrain.text = "地形: " .. (prov.terrain or "---")

            local ownerName = nil
            if prov.ownerId then
                local ownerFaction = gameState.factions and gameState.factions[prov.ownerId]
                if ownerFaction then ownerName = ownerFaction.name end
            end
            refs.provOwner.text = ownerName and ("领主: " .. ownerName) or "领主: 无主"
            refs.provPopulation.text = "人口: " .. tostring(prov.population or 0)
            refs.provGarrison.text = "驻军: " .. tostring(prov.garrison or 0)

            local stability = prov.stability or 0
            refs.provStabilityLabel.text = "治安: " .. tostring(math.floor(stability)) .. "%"
            refs.provStabilityBar:SetValue(stability / 100)
        end
    end

    -- 战争列表
    GameUI.refreshWarList(gameState)

    -- 政策面板（变法状态 / 卡槽高亮 / 实施进度）
    GameUI.refreshPolicyPanel(gameState)

    -- 地图模式面板（当前模式说明 + 按钮高亮）
    GameUI.refreshMapModePanel(gameState)

    -- 战斗卡（模式面板左侧）
    GameUI.refreshBattleCards(gameState)
end

--- Show the province info panel for a given province.
function GameUI.showProvincePanel(provinceId, provinceData)
    if not refs.provincePanel then return end
    refs.selectedProvinceId = provinceId
    refs.selectedOwnerId = provinceData and provinceData.ownerId or nil

    -- 操作行：根据省归属动态决定
    refs.provActions:ClearChildren()
    refs.provActionHint.text = ""

    if provinceData then
        refs.provName.text = provinceData.name or "---"
        refs.provTerrain.text = "地形: " .. (provinceData.terrain or "---")

        local ownerName = nil
        if provinceData.ownerId then
            local gs = refs.gameState
            local faction = gs and gs.factions and gs.factions[provinceData.ownerId]
            if faction then ownerName = faction.name end
        end
        refs.provOwner.text = ownerName and ("领主: " .. ownerName) or "领主: 无主"
        refs.provPopulation.text = "人口: " .. tostring(provinceData.population or 0)
        refs.provGarrison.text = "驻军: " .. tostring(provinceData.garrison or 0)

        local stability = provinceData.stability or 0
        refs.provStabilityLabel.text = "治安: " .. tostring(math.floor(stability)) .. "%"
        refs.provStabilityBar:SetValue(stability / 100)

        local pid = refs.gameState.playerFactionId
        local ownerId = provinceData.ownerId

        if provinceData.isWasteland then
            -- 沙漠废土：显示沙漠信息 + 恢复按钮（仅玩家可恢复）
            refs.provTerrain.text = "地形: 沙漠"
            refs.provOwner.text = "领主: 无主"
            refs.provActionHint.text = "沙漠之地：不可占领、无产出、不能驻军"
            if pid then
                refs.btnWasteland.text = "🏜️ 恢复土地"
                refs.provActions:AddChild(refs.btnWasteland)
            end
        elseif pid and ownerId == pid then
            -- 己方省：征兵 / 调军 / 化为沙漠
            refs.provActions:AddChild(refs.btnRecruit)
            refs.provActions:AddChild(refs.btnMoveArmy)
            refs.btnWasteland.text = "🏜️ 化为沙漠"
            refs.provActions:AddChild(refs.btnWasteland)
            if (provinceData.garrison or 0) < 1 then
                refs.provActionHint.text = "驻军为 0，可先征兵"
            end
        elseif ownerId then
            -- 敌方省：宣战按钮
            refs.provActions:AddChild(refs.btnDeclareWar)
            refs.provActionHint.text = "攻占敌国领土需先宣战"
        else
            -- 无主之地
            refs.provActionHint.text = "无主之地：可派军前往占领"
        end
    end

    refs.provincePanel:Show()
end

function GameUI.hideProvincePanel()
    if refs.provincePanel then
        refs.provincePanel:Hide()
        refs.selectedProvinceId = nil
        refs.selectedOwnerId = nil
    end
end

--- Show the diplomacy overlay panel.
function GameUI.showDiplomacy(gameState)
    if not refs.diploOverlay then return end

    refs.diploFactionList:ClearChildren()

    local factions = gameState.factions or {}
    local relations = gameState.relations or {}
    local playerFactionId = gameState.playerFactionId

    for _, faction in pairs(factions) do
        if faction.alive ~= false and faction.id ~= playerFactionId then
            local relRecord = relations[playerFactionId] and relations[playerFactionId][faction.id]
            local relValue = relRecord and relRecord.value or 0
            faction.atWar = relRecord and relRecord.atWar or false
            local row = createFactionRow(faction, relValue, refs.callbacks)
            refs.diploFactionList:AddChild(row)
        end
    end

    refs.diploOverlay:Show()
end

function GameUI.hideDiplomacy()
    if refs.diploOverlay then
        refs.diploOverlay:Hide()
    end
end

function GameUI.toggleDiplomacy(gameState)
    if refs.diploOverlay and refs.diploOverlay:IsVisible() then
        GameUI.hideDiplomacy()
    else
        GameUI.showDiplomacy(gameState)
    end
end

function GameUI.isDiplomacyVisible()
    return refs.diploOverlay and refs.diploOverlay:IsVisible() or false
end

function GameUI.isProvincePanelVisible()
    return refs.provincePanel and refs.provincePanel:IsVisible() or false
end

return GameUI

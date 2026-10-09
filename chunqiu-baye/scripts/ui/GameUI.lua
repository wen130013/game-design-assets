-- ============================================================================
-- GameUI.lua — 春秋霸业 游戏 UI 覆盖层（手机版 v2）
--
-- 布局（手机优先，2026-08-29 定稿；2026-08-31 时间区改为大筐+中文档名，排行/日志按钮暂移除）：
--   顶部    ：资源条（国家名、金/粟/兵力/名声、时间大筐、速度档、设置）
--   右侧    ：省份面板（信息 + 操作按钮：征兵/调军/宣战）
--   右下角  ：战争列表（每场战争一条：敌方名 + 战争分数条，绿=优 红=劣）
--   弹窗    ：排行榜、外交、日志（半透明遮罩 + 居中窗口）
--   消息    ：不再常驻屏幕（解决挡地图问题），全部进日志面板
-- ============================================================================

local UI = require("urhox-libs/UI")
local WarSystem = require("systems.WarSystem")
local GameConfig = require("config.GameConfig")
local PolicySystem = require("systems.PolicySystem")
local EconomySystem = require("systems.EconomySystem")
local MusicManager = require("audio.MusicManager")
local Emblem = require("ui.Emblem")
local NavigationHUD = require("ui.NavigationHUD")

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
    population      = { 120, 205, 195, 255 },   -- 人口（青绿，与粮草绿/威望紫区分）
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
-- 页签（朝廷的「官员/后宫」这种）用的是木牌底图，只能靠**字色**区分选中：
--   选中 = 金色字，未选中 = 灰字（2026-09-16）
local TAB_TEXT_ACTIVE = { 255, 205, 90, 255 }
local TAB_TEXT_IDLE   = { 158, 152, 140, 255 }

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
-- Helper: styled button（手机触控区按实际缩放保持 ≥48px）
-- ============================================================
local function SmallButton(label, onClick, opts)
    opts = opts or {}
    if label == "X" or label == "×" or label == "✕" then
        local f = graphics:GetDPR() / math.max(0.01, UI.GetScale())
        return UI.Button {
            id = opts.id, text = "关闭", width = 72 * f, height = 48 * f,
            fontSize = 12 * f, flexShrink = 0, padding = 0,
            textColor = { 238, 223, 192, 255 },
            backgroundColor = { 50, 43, 34, 255 },
            hoverBackgroundColor = { 78, 63, 42, 255 },
            pressedBackgroundColor = { 99, 75, 42, 255 },
            borderRadius = 6, borderWidth = 1, borderColor = { 144, 116, 69, 220 },
            onClick = onClick,
        }
    end
    local touch = NavigationHUD.touchSize(48)
    opts.height = math.max(opts.height or 36, touch)
    if type(opts.width) == "number" then opts.width = math.max(opts.width, touch) end
    -- ⚔️ emoji 在部分设备回退成白色叉：换成双剑交叉图标（路径在 GameConfig.Icons，可改）
    local icon = opts.icon
    if label:find("⚔") then
        local ic = GameConfig.Icons and GameConfig.Icons.battle
        ---@type string|nil
        local icPath = nil
        if type(ic) == "table" then
            icPath = ic.path
        elseif type(ic) == "string" then
            icPath = ic
        end
        icon = icon or icPath or "image/icon_war_双剑交叉.png"
        label = label:gsub("⚔️", ""):gsub("⚔", "")
        label = label:gsub("^%s+", ""):gsub("%s+$", "")
    end
    -- 其他没有对应图标的 emoji（🚩 / 🏜️ 等）在部分设备回退成"☒"方框 → 一律剥掉，只留文字
    --   （2026-09-17 用户截图："调军/化为沙漠 的图标是空框"）
    label = label:gsub("🚩", ""):gsub("🏜️", ""):gsub("🏜", "")
    label = label:gsub("^%s+", ""):gsub("%s+$", "")
    local bg = opts.bg or COLORS.btnDefault
    local hoverBg = opts.hoverBg or COLORS.btnHover
    -- 皮肤（2026-09-16 用户："按钮太丑，风格得和我们相符"）：
    --   统一用全游戏的"金漆木牌"九宫格底图（这里原来铺的是羊皮纸，小按钮上很土）
    local UISkin = require("ui.UISkin")
    local skinImg = UISkin.BUTTON_IMAGE
    local skinSlice = UISkin.BUTTON_SLICE
    local textColor = opts.textColor or UISkin.button("normal").textColor
    local w = opts.width or nil
    local fontSize = opts.fontSize or 13
    if icon then
        return UI.Button {
            id = opts.id,   -- 可选：给离屏测试用 UI.FindById 点它
            fontSize = fontSize,
            backgroundColor = bg,
            hoverBackgroundColor = hoverBg,
            pressedBackgroundColor = hoverBg,
            backgroundImage = skinImg,
            backgroundSlice = skinSlice,
            hoverBackgroundImageOpacity = 1.0,
            pressedBackgroundImageOpacity = 0.72,
            borderRadius = 6,
            borderWidth = opts.borderWidth,
            borderColor = opts.borderColor,
            height = opts.height or 36,
            width = w,
            flexGrow = opts.flexGrow,
            flexBasis = opts.flexBasis,
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
        id = opts.id,   -- 可选：给离屏测试用 UI.FindById 点它
        text = label,
        fontSize = fontSize,
        textColor = textColor,
        backgroundColor = bg,
        hoverBackgroundColor = hoverBg,
        pressedBackgroundColor = hoverBg,
        backgroundImage = skinImg,
        backgroundSlice = skinSlice,
        hoverBackgroundImageOpacity = 1.0,
        pressedBackgroundImageOpacity = 0.72,
        borderRadius = 6,
        borderWidth = opts.borderWidth,
        borderColor = opts.borderColor,
        height = opts.height or 36,
        width = w,
        flexGrow = opts.flexGrow,
        flexBasis = opts.flexBasis,
        paddingHorizontal = opts.paddingH or 12,
        onClick = onClick,
    }
end

--- 国交行动按钮网格（外交面板 / 省份面板**共用** → 两处外观必然一致）
---   2026-09-16 用户："这些按钮的颜色为什么不同，而且它们的排列也有问题"
---   → ① 底色**统一**（不再按 kind 分红/绿/灰）
---     ② 按固定列数排成整齐网格；最后一行不足时用**同宽透明占位**补齐，保证列对齐
---@param acts table[] Interactions.ACTIONS 之类
---@param perRow number 每行几个
---@param idPrefix string 按钮 id 前缀（离屏测试用 UI.FindById 点它）
---@param onClick fun(act:table)
---@return Widget 一个纵向容器
local function buildActGrid(acts, perRow, idPrefix, onClick)
    local rows = {}
    ---@type Widget|nil
    local row = nil
    local count = 0
    for _, act in ipairs(acts) do
        if count % perRow == 0 then
            row = UI.Panel { flexDirection = "row", gap = 6, width = "100%", children = {} }
            rows[#rows + 1] = row
        end
        ---@type Widget
        local btn = SmallButton(act.name, function() onClick(act) end, {
            id = idPrefix .. act.id,
            fontSize = 11, height = 32, paddingH = 6,
            flexGrow = 1, flexBasis = 0,
        })
        row:AddChild(btn)
        count = count + 1
    end
    -- 补齐最后一行（占位块与按钮同宽 → 列对齐，看着才齐整）
    if perRow > 0 then
        while count % perRow ~= 0 do
            row:AddChild(UI.Panel { flexGrow = 1, flexBasis = 0 })
            count = count + 1
        end
    end
    return UI.Panel {
        width = "100%",
        flexDirection = "column",
        gap = 6,
        children = rows,
    }
end

-- 2026-09-16 删：createFactionRow / createRelationBar ——
--   用户："这些国家为什么还在" → 外交面板不再逐个列国家（操作走行动栏 + 地图点国家）

-- ============================================================
-- Helper: 数字格式化（万/亿缩写，防止大数字撑爆顶栏）
-- ============================================================
---@param v number
---@return string
local function fmtNum(v)
    v = math.floor(v or 0)
    -- 阈值分段的目的：**任何量级都塞得进定宽数值格**（STAT_VALUE_W = 42）
    --   最宽的串是「999.9万」「99999亿」≈41px；不会出现「1000.0万」这种 6 字符的爆宽串
    if v >= 1e12 then return string.format("%.0f亿", v / 1e8) end
    if v >= 1e8 then return string.format("%.1f亿", v / 1e8) end
    if v >= 1e7 then return string.format("%.2f亿", v / 1e8) end
    if v >= 1e4 then return string.format("%.1f万", v / 1e4) end
    return tostring(v)
end

-- ============================================================
-- Helper: 资源项（完整文字标签 + 数值）
-- ============================================================
--- 数值格的**固定宽度**（2026-09-16 用户："这几个属性的增加会让按钮往左移动，给它腾出地方"）
---   数字变长（150 → 1200 → 2.2万）时，如果宽度是自适应的，整个右半栏会被顶得来回移动；
---   给数值留一块定宽的地方，顶栏就钉死了。
local STAT_VALUE_W = 42

local function StatItem(label, value, color, fontSize, onClick)
    return UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        gap = 2,
        -- 点资源格 = 打开收支明细（2026-09-25，照 EU4：点顶栏资源看收支）
        pointerEvents = onClick and "auto" or nil,
        onClick = onClick,
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
                width = STAT_VALUE_W,   -- 定宽：数字变长不再顶动右边的按钮
                flexShrink = 0,
            },
        },
    }
end

-- ============================================================
-- 1) Top Bar（顶部资源条 + 功能按钮）
-- ============================================================
local function createTopBar(gameState, callbacks)
    local navigationCallbacks = {
        onPauseToggle = callbacks.onPauseToggle,
        onMenuToggle = function() GameUI.toggleNavigationMenu() end,
        onMenuClose = function() GameUI.hideNavigationMenu() end,
    }
    return NavigationHUD.create(refs, navigationCallbacks, function(key) GameUI.openNavigation(key) end)
end


-- ============================================================
-- 2) Province Info Panel（右侧：信息 + 操作）
-- ============================================================
local function createProvincePanel(gameState, callbacks)
    refs.provName = UI.Label {
        id = "provName",          -- 给离屏 SHOT_TAP 验证"面板标题=省名"用
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
    -- 「治安」行已删（2026-09-21 用户："这个治安有什么用，我觉得去掉它更好"）：
    --   province.stability 全项目**没有任何系统读**（只有被占领时被写成 30）→ 死数据，不留
    -- 换成**该省月产出**（同一次讨论拍板）：金/粮每月给多少，数据取 EconomySystem.getProvinceIncome
    refs.provIncome = UI.Label {
        text = "月产: ---",
        fontSize = 12,
        fontColor = { 226, 196, 120, 255 },
    }

    -- 操作按钮（动态显示/隐藏）
    -- 「⚔️ 征兵」已删（2026-09-21 用户："我们可以从军队这召唤士兵，所以说这里那个什么征兵没用啦"）：
    --   顶栏「军队」面板调的就是同一个 MilitarySystem.recruit，还能选数量/兵种/看成本 → 重复
    -- 「🚩 调军」按钮也已删（2026-09-23 用户："点击一个区块…左上角这个界面（应该）没有调军这个按钮"）：
    --   军队操作统一走**左下角的军队面板**（点自己的省自动弹，或点地图上的军队旗标），
    --   这里再放一个调军按钮属于重复入口。
    refs.btnMoveArmy = nil
    -- 2026-09-16 删：原来单独的「宣战」按钮 → 并入下面的"国交行动"栏（不然两个宣战）
    -- 2026-09-17 删：「化为沙漠 / 恢复土地」按钮 —— 用户："我为什么要把自己的国家变成沙漠？
    --   这应该是不存在的，取消掉这个"。底层 GameState.setWasteland 保留（编辑器/剧本仍可用）。
    refs.provActionHint = UI.Label {
        text = "",
        fontSize = 11,
        fontColor = COLORS.textSecondary,
        whiteSpace = "normal",   -- 窄面板：长提示要能折行，别被切掉
        maxLines = 2,
    }

    local closeBtn = SmallButton("X", function()
        GameUI.hideProvincePanel()
        -- 地图上的省份高亮一起熄灭（2026-09-23 用户："关闭详情（点叉号）…为什么这个区块还是发亮"）
        if GameUI.onClearMapHighlight then GameUI.onClearMapHighlight() end
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
        flexWrap = "wrap",     -- 2026-09-17：面板宽 230，三个按钮一行放不下 → 自动换行（原来被裁掉）
        gap = 6,
        children = {},
    }

    -- 国交行动区（2026-09-16）：点**别国**省份时出现的一整排动作
    --   用户："点击别人的国家都会出现我和对方交流的，不管是什么暗杀对方的首领、
    --   或者间谍之类的，而不只是现在的宣战" → 内容先摆出来（未实现的点了给提示）
    refs.provInteractTitle = UI.Label {
        text = "◆ " .. (require("data.Interactions").LABEL or "国交行动"),
        fontSize = 12,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }
    refs.provInteractRows = UI.Panel {
        width = "100%",
        flexDirection = "column",
        gap = 5,
        children = {},
    }
    refs.provInteract = UI.Panel {
        width = "100%",
        flexDirection = "column",
        gap = 6,
        children = { refs.provInteractTitle, refs.provInteractRows },
    }
    refs.provInteract:Hide()

    -- 行动按钮：**建一次就够**（目标国读 refs.selectedOwnerId，随选中省份变）
    --   用和外交面板同一个网格函数 → 两处颜色/排列必然一致（2026-09-16）
    do
        local Interactions = require("data.Interactions")
        refs.provInteractRows:AddChild(buildActGrid(
            Interactions.ACTIONS, 2, "provAct_",
            function(act)
                local target = refs.selectedOwnerId
                if not target then return end
                if callbacks.onInteraction then callbacks.onInteraction(act.id, target) end
            end))
    end

    refs.provincePanel = UI.Panel {
        position = "absolute",
        -- 左上角（2026-09-21 用户："这个不要在右上角，在左上角"）：原来是 right = 6；
        --   2026-10-05 起：待办摘要已下沉到 root 最底层 → 本面板必然盖住它（不用再靠 eventNoticeBar 顺序）
        top = 52,
        left = 6,
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
            refs.provIncome,
            refs.provActions,
            refs.provInteract,     -- 国交行动按钮（仅"别国省份"时显示）
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

--- 天下国力榜（2026-09-26 拆到 ui/panels/RankingPanel.lua）
local RankingPanel = require("ui.panels.RankingPanel")
local function createRankingPanel()
    return RankingPanel.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton, gameState = refs.gameState,
    })
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

--- 时间流速弹窗（2026-09-26 拆到 ui/panels/SpeedMenu.lua）
local SpeedMenu = require("ui.panels.SpeedMenu")
local function createSpeedMenu(callbacks)
    return SpeedMenu.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton, callbacks = callbacks,
    })
end

-- ============================================================
-- 3.55) 征召军队弹窗（2026-09-19 用户：研究右边加「军队」按钮）
--   数量：输入框 +「−/＋」按钮（任意数量，默认 100）
--   地区：点「选地区」→ 收起弹窗、到地图上点自己的省 → 自动弹回
--   资源不够：按能负担的数量生成（用户："要生成 100 个、资源不够就生成 80 个"）
-- ============================================================
refs.armyPickMode = false

--- 点 (x,y) 是否落在浮层面板上 —— 地图点击据此屏蔽"穿透"
---   （2026-09-19 用户："我点那个上面不会透过这个框直接点到后边的领土"）
---   坐标系：UI 事件坐标（base pixel），与 GetAbsoluteLayout 同系
---@param x number
---@param y number
---@return boolean
function GameUI.isPointOverPanel(x, y)
    local function hitPanel(w)
        if not w or not w:IsVisible() then return false end
        local l = w:GetAbsoluteLayout()
        if not l then return false end
        return x >= l.x and x <= l.x + l.w and y >= l.y and y <= l.y + l.h
    end
    -- ⚠️ 征召面板判的是**黑框本体** armyPanelBox，不是外壳 refs.armyPanel：
    --   外壳是 top/bottom=0 的全屏容器 → 拿它判 = 面板一开着**整块屏幕**都算"面板上"，
    --   地图点击全被吞（2026-09-21 用户："我点一个区块却没反应"）。
    --   外壳只用来问"开着没"（子节点的 IsVisible 不跟父级联动）
    if refs.armyPanel and refs.armyPanel:IsVisible() and hitPanel(refs.armyPanelBox) then return true end
    -- 左下角驻军/行军面板同理：点「调军 / 征募 / 解散」不能穿透去选省
    if refs.unitPanel and refs.unitPanel:IsVisible() and hitPanel(refs.unitPanelBox) then return true end
    if hitPanel(refs.topBar) or hitPanel(refs.navigation) then return true end
    if refs.techPanel and refs.techPanel:IsVisible() and hitPanel(refs.techPanelBody) then return true end
    return hitPanel(refs.warBar)
end

--- 征召军队面板（2026-09-26 拆到 ui/panels/ArmyPanel.lua）
local ArmyPanel = require("ui.panels.ArmyPanel")
ArmyPanel.install(GameUI)

local function createArmyPanel()
    return ArmyPanel.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton,
    })
end

-- ============================================================================
-- 3.56) 军队详情面板（2026-09-23 用户："点击军队 → 弹出界面"）
--   形态 A：**行军中**（点地图上的军队旗标）→ 兵力 / 士气 / 行程 + [急行军][停止]
--   形态 B：**驻军**（点自己的省）→ 兵力 / 归属 / 地形 + [移动][征募][解散]
--   · 位置：**左下角贴边**（用户："不能挡视野""他左边有这么大的地方"），
--     不遮右下角的模式按钮；
--   · 外层 box-none + 内层 auto：点面板外照样能点地图（与征召面板同款规矩）；
--   · 按钮高 52px（手机手指友好）；兵力用大字号（用户："兵力不够明显"）。
-- ============================================================================
local function createUnitPanel()
    local MIL = require("systems.MilitarySystem")

    --- 统一按钮工厂（大尺寸、金边，风格与全局一致）
    local function mkBtn(text, w, fn, bg)
        return UI.Button {
            text = text, width = w, height = 52, fontSize = 15,
            backgroundColor = bg or { 46, 58, 78, 235 },
            hoverBackgroundColor = { 64, 80, 105, 245 },
            pressedBackgroundColor = { 34, 44, 60, 255 },
            borderRadius = 8, borderWidth = 1, borderColor = { 96, 84, 68, 180 },
            onClick = fn,
        }
    end

    --- 按钮 + 说明小字（2026-09-23 用户："按钮要有说明"，参考「世界征服者」的按钮排）
    ---   按钮占满可用宽度（flexGrow），下面一行 11px 灰字说明这个按钮干什么
    local function mkBtnCol(text, desc, fn, bg)
        return UI.Panel {
            flexGrow = 1, flexDirection = "column", gap = 3,
            children = {
                UI.Button {
                    text = text, width = "100%", height = 46, fontSize = 15,
                    backgroundColor = bg or { 46, 58, 78, 235 },
                    hoverBackgroundColor = { 64, 80, 105, 245 },
                    pressedBackgroundColor = { 34, 44, 60, 255 },
                    borderRadius = 8, borderWidth = 1, borderColor = { 96, 84, 68, 180 },
                    onClick = fn,
                },
                UI.Label {
                    text = desc, fontSize = 11, fontColor = { 148, 143, 133, 255 },
                    textAlign = "center", width = "100%",
                },
            },
        }
    end

    refs.unitTitleLabel  = UI.Label { text = "", fontSize = 16, fontColor = { 214, 172, 96, 255 }, fontWeight = "bold" }
    refs.unitTroopsLabel = UI.Label { text = "0", fontSize = 18, fontWeight = "bold", fontColor = { 235, 240, 250, 255 } }
    refs.unitMoraleLabel = UI.Label { text = "—", fontSize = 14, fontColor = { 210, 215, 225, 255 } }
    refs.unitRouteLabel  = UI.Label { text = "", fontSize = 13, fontColor = { 170, 165, 150, 255 } }
    -- 将军行（2026-09-23）：显示驻军统帅 + 统兵上限；点「任将」换人
    --   有将军的驻军才会月度自动补员（用户拍板），所以这行也是"会不会自己补兵"的提示
    refs.unitCommanderLabel = UI.Label { text = "", fontSize = 13, fontColor = { 214, 172, 96, 235 } }

    -- 兵种明细（2026-09-24 用户："我需要弄显示这里它的兵种才对，因为可能会有很多个兵种"）：
    --   一支军队可以有多个兵种，所以按**行**列出每个兵种 + 人数，而不是一行"兵种：轻步兵"。
    --   行在创建时按兵种表全建好，刷新时只改文字/显隐（UI 库不支持重建 children 重排）。
    refs.unitMixTitle = UI.Label { text = "兵种构成", fontSize = 12, fontColor = { 150, 160, 175, 255 } }
    refs.unitMixRows = {}
    refs.unitMixList = UI.Panel {
        width = "100%", flexDirection = "column", gap = 3,
        children = (function()
            local Units = require("data.Units")
            local rows = {}
            for _, u in ipairs(Units.all()) do
                -- 每行：兵种名（左） + 人数（右）
                local nameLbl = UI.Label {
                    text = u.name, fontSize = 13, fontColor = { 226, 220, 205, 255 },
                }
                local cntLbl = UI.Label {
                    text = "0", fontSize = 13, fontColor = { 235, 240, 250, 255 }, fontWeight = "bold",
                }
                local row = UI.Panel {
                    flexDirection = "row", alignItems = "center", width = "100%",
                    paddingHorizontal = 8, paddingVertical = 3,
                    backgroundColor = { 30, 38, 53, 200 }, borderRadius = 5,
                    children = {
                        nameLbl,
                        UI.Panel { flexGrow = 1 },
                        cntLbl,
                    },
                }
                refs.unitMixRows[u.id] = { row = row, name = nameLbl, count = cntLbl }
                rows[#rows + 1] = row
            end
            return rows
        end)(),
    }
    refs.unitHintLabel   = UI.Label { text = "", fontSize = 12, fontColor = { 150, 150, 150, 255 } }

    -- 交战中（2026-09-26 用户："交战中也可以看到他们的士气"）：
    --   点战斗行 → 显示**双方对照**：攻方（旗+兵力+士气） vs 守方（旗+兵力+士气）。
    --   只读 —— 交战中不给操作按钮（指挥靠调兵，不靠这里）。
    --   ⚠️ 标签必须先建好再引用（表构造器里只能写 `名字 = 值`）。
    refs.unitBattleAttName   = UI.Label { text = "", fontSize = 13, fontWeight = "bold",
                                          fontColor = { 235, 180, 170, 255 } }
    refs.unitBattleAttSize   = UI.Label { text = "0", fontSize = 15, fontWeight = "bold",
                                          fontColor = { 235, 240, 250, 255 } }
    refs.unitBattleAttMorale = UI.Label { text = "", fontSize = 12,
                                          fontColor = { 200, 170, 170, 255 } }
    refs.unitBattleDefName   = UI.Label { text = "", fontSize = 13, fontWeight = "bold",
                                          fontColor = { 180, 200, 235, 255 } }
    refs.unitBattleDefSize   = UI.Label { text = "0", fontSize = 15, fontWeight = "bold",
                                          fontColor = { 235, 240, 250, 255 } }
    refs.unitBattleDefMorale = UI.Label { text = "", fontSize = 12,
                                          fontColor = { 170, 185, 210, 255 } }
    refs.unitBattleRow = UI.Panel {
        width = "100%", flexDirection = "row", alignItems = "center", gap = 6,
        paddingHorizontal = 8, paddingVertical = 8,
        backgroundColor = { 44, 30, 34, 220 }, borderRadius = 8,
        children = {
            -- 攻方
            UI.Panel {
                flexGrow = 1, flexShrink = 1, flexDirection = "column", gap = 2,
                children = {
                    refs.unitBattleAttName,
                    UI.Panel {
                        flexDirection = "row", alignItems = "baseline", gap = 4,
                        children = {
                            refs.unitBattleAttSize,
                            refs.unitBattleAttMorale,
                        },
                    },
                },
            },
            UI.Label { text = "⚔", fontSize = 16, fontColor = { 214, 172, 96, 255 }, flexShrink = 0 },
            -- 守方
            UI.Panel {
                flexGrow = 1, flexShrink = 1, flexDirection = "column", gap = 2,
                alignItems = "flex-end",
                children = {
                    refs.unitBattleDefName,
                    UI.Panel {
                        flexDirection = "row", alignItems = "baseline", gap = 4,
                        children = {
                            refs.unitBattleDefMorale,
                            refs.unitBattleDefSize,
                        },
                    },
                },
            },
        },
    }
    refs.unitCloseBtn    = UI.Button {
        -- ⚠️ 用 "×"（U+00D7）而不是 "✕"（U+2715）：MiSans 里没有 U+2715，
        --   渲染成一个方框豆腐块（2026-09-24 用户截图反馈）。同文件征召面板的关闭键
        --   一直用的就是 "×"，能正常显示。
        text = "×", width = 46, height = 46, fontSize = 22,
        -- flexShrink = 0：标题行是 row 容器，默认 flexShrink=1 会把按钮**压成竖条**
        --   （2026-09-23 用户："这个叉号为什么是长方形"）→ 固定尺寸不让它被压缩
        flexShrink = 0,
        backgroundColor = { 40, 36, 34, 230 }, hoverBackgroundColor = { 78, 22, 26, 255 },
        borderRadius = 6, borderWidth = 1, borderColor = { 96, 84, 68, 180 },
        onClick = function()
            GameUI.hideUnitPanel()
            -- 军队旗的沿形金光一起熄灭（2026-09-23）
            if GameUI.onClearMapHighlight then GameUI.onClearMapHighlight() end
        end,
    }

    -- 形态 A 按钮：急行军 / 停止（等宽两列，各带一行说明）
    refs.unitArmyBtns = UI.Panel {
        flexDirection = "row", gap = 10, width = "100%",
        children = {
            mkBtnCol("急行军", "加速，伤士气", function()
                local t = refs.unitTarget
                if not t then return end
                local ok, msg = MIL.forcedMarch(t)
                if refs.unitHintLabel and msg then refs.unitHintLabel:SetText(msg) end
                GameUI.refreshUnitPanel(refs.gameState)
            end, { 96, 66, 40, 235 }),
            mkBtnCol("停 止", "就地驻防", function()
                local t = refs.unitTarget
                if not t then return end
                local total = t.totalHours or 1
                local prog = total > 0 and ((t.progress or 0) / total) or 0
                local pid = prog >= 0.5 and (t.to or t.toProvinceId) or (t.from or t.fromProvinceId)
                if MIL.stopArmy(refs.gameState, t) then
                    -- 停下来 = 就地驻防 → 面板切换成驻军形态（继续展示，不闪断）
                    GameUI.showUnitPanel({ provId = pid }, "garrison")
                end
            end),
        },
    }

    -- 形态 B 按钮：调军 / 任将 / 解散（等宽，各带一行说明）
    --   为什么没有「征募」：顶部「军队」页就是征兵入口（2026-09-23 用户："征募…上边有军队
    --     所以说就不需要这个了"）。
    --   为什么没有「分兵」：我们的军队模型 = **省里的驻军数字**（不是 CK3 那种可自由移动的
    --     独立军团）。"派一部分兵出去、留一部分守家"这件事本身就是「调军」在做。
    --     真要拆成两支**独立军团**，得先把军队对象化（后续大改）。
    --   为什么没有「合并」：同理 —— 同一格里永远只有一个驻军数字，没有"多支可合并"。
    -- 调军数量（2026-10-04 用户："仿照他们去弄" —— 照征兵面板的做法：
    --   可手打 + 两侧 ± 按钮；原来固定派一半，玩家没法选）
    refs.unitMoveCountField = UI.TextField {
        id = "unitMoveCountField",
        value = "100",
        height = 46, width = 100, flexGrow = 1, flexShrink = 1, fontSize = 16,
        onChange = function() GameUI.refreshUnitPanel(refs.gameState) end,
    }
    refs.unitMoveCountRow = UI.Panel {
        id = "unitMoveCountRow",
        width = "100%", padding = 10, gap = 8,
        backgroundColor = { 30, 38, 53, 235 }, borderRadius = 7,
        children = {
            UI.Label { text = "调军数量", fontSize = 13, fontColor = COLORS.gold },
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 8, width = "100%",
                children = {
                    UI.Button {
                        id = "unitMoveMinus", text = "−100", width = 74, height = 46, fontSize = 14, flexShrink = 0,
                        backgroundColor = { 46, 58, 78, 235 },
                        hoverBackgroundColor = { 66, 82, 108, 245 },
                        pressedBackgroundColor = { 38, 48, 66, 250 },
                        borderRadius = 6,
                        onClick = function() GameUI.bumpMoveCount(-100) end,
                    },
                    refs.unitMoveCountField,
                    UI.Button {
                        id = "unitMovePlus", text = "+100", width = 74, height = 46, fontSize = 14, flexShrink = 0,
                        backgroundColor = { 46, 58, 78, 235 },
                        hoverBackgroundColor = { 66, 82, 108, 245 },
                        pressedBackgroundColor = { 38, 48, 66, 250 },
                        borderRadius = 6,
                        onClick = function() GameUI.bumpMoveCount(100) end,
                    },
                },
            },
            UI.Label {
                id = "unitMoveMaxBtn", text = "全部调走", fontSize = 12,
                fontColor = { 235, 180, 120, 255 },
                pointerEvents = "auto",
                onClick = function() GameUI.setMoveCountMax() end,
            },
        },
    }

    refs.unitGarrisonBtns = UI.Panel {
        flexDirection = "row", gap = 8, width = "100%",
        children = {
            mkBtnCol("调 军", "点地图选目标省", function()
                local t = refs.unitTarget
                if t and GameUI.startArmyMove then GameUI.startArmyMove(t.provId) end
            end),
            mkBtnCol("任 将", "指派统帅", function()
                local t = refs.unitTarget
                if t and GameUI.showCommanderPick then GameUI.showCommanderPick(t.provId) end
            end),
            mkBtnCol("解 散", "遣散这些兵", function()
                local t, gs = refs.unitTarget, refs.gameState
                if not t or not gs or not gs.playerFactionId then return end
                local n = MIL.disbandGarrison(gs, gs.playerFactionId, t.provId)
                if n <= 0 then
                    refs.unitHintLabel:SetText("这里不是你的省，或没有可遣散的兵")
                else
                    refs.unitHintLabel:SetText(string.format("已遣散 %d 兵", n))
                    GameUI.refreshUnitPanel(gs)
                end
            end, { 96, 40, 40, 235 }),
        },
    }

    refs.unitPanelBox = UI.Panel {
                -- 贴左贴底（2026-09-23 用户："这个下边儿和左边儿怎么都没有贴满"）：
                --   去掉 marginLeft / marginBottom，左边和下边完全贴住屏幕边缘；
                --   只留左上的圆角，避免贴着屏幕边还露出圆角缺口。
                width = 360,
                -- ⚠️ 高度上限由 syncNavigationLayout 按屏高写（2026-10-05 用户：横屏小屏
                --   "都抄边了" —— 面板原来没上限，内容一撑就顶穿顶栏，标题被切）。
                --   这里给个保守默认，真正生效值在布局时算。
                maxHeight = 480,
                -- ⚠️ 必须**完全不透明**（2026-09-24 用户截图反馈：面板里透出地图上的
                --   省份标签「巴 180」，看着像 UI 里多了两个莫名的方框）。
                --   原来是 245/255，剩下的 4% 透明度足够让背后的地图标签显形。
                backgroundColor = { 26, 24, 22, 255 },
                borderRadiusTopRight = 10,
                borderWidth = 1, borderColor = { 96, 84, 68, 220 },
                padding = 14, gap = 8,
                pointerEvents = "auto",
                onClick = function() end,        -- 点面板本体不关
                children = {
                    -- 标题行
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", width = "100%",
                        children = {
                            refs.unitTitleLabel,
                            UI.Panel { flexGrow = 1 },
                            refs.unitCloseBtn,
                        },
                    },
                    -- 兵力 + 士气**压成一行**（2026-09-23 用户："还有能不能把它们放在一个行"）
                    --   兵力数字从 30 号降到 22 号（用户："这个数字太大了"），仍是最醒目的一项
                    UI.Panel {
                        flexDirection = "row", alignItems = "flex-end", gap = 10, width = "100%",
                        paddingVertical = 6, paddingHorizontal = 10,
                        backgroundColor = { 30, 44, 66, 225 }, borderRadius = 8,
                        children = {
                            UI.Label { text = "兵力", fontSize = 12, fontColor = { 150, 160, 175, 255 } },
                            refs.unitTroopsLabel,
                            UI.Panel { flexGrow = 1 },
                            UI.Label { text = "士气", fontSize = 12, fontColor = { 150, 160, 175, 255 } },
                            refs.unitMoraleLabel,
                        },
                    },
                    refs.unitRouteLabel,
                    refs.unitCommanderLabel,
                    refs.unitBattleRow,     -- 交战中：双方对照（默认隐藏）
                    refs.unitHintLabel,
                    -- 兵种构成（2026-09-24）：兵种可能很多，给一个**可滚动**的明细区，
                    --   最多占 150px 高，超出就滚 —— 否则兵种一多会把下面的按钮顶出屏幕
                    refs.unitMixTitle,
                    UI.ScrollView {
                        -- flexShrink=1：屏矮时**这个区先让位**（它是唯一可压缩的），
                        --   否则面板被 maxHeight 夹住后，多出来的部分会把标题挤出可视区
                        width = "100%", maxHeight = 150, flexShrink = 1,
                        scrollY = true, scrollX = false, showScrollbar = true,
                        children = { refs.unitMixList },
                    },
                    UI.Divider { color = { 96, 84, 68, 150 }, thickness = 1 },
                    refs.unitMoveCountRow,   -- 调军数量（仅驻军形态显示）
                    refs.unitArmyBtns,
                    refs.unitGarrisonBtns,
                },
    }
    refs.unitPanel = UI.Panel {
        position = "absolute", left = 0, bottom = 0,
        pointerEvents = "box-none",          -- 面板外穿透，不挡地图点击
        children = { refs.unitPanelBox },
    }
    refs.unitPanel:Hide()
    return refs.unitPanel
end

--- 调军数量：读输入框（空/非法 → 取当前驻军；上限 = 驻军数）
---   2026-10-04 修：进调军模式时会 hideUnitPanel（它清掉 unitTarget），
---   所以这里优先用进入时**记下的** cap（refs.moveCap_），没有才回退到面板。
---@return number
function GameUI.moveWanted()
    local cap = refs.moveCap_
    if not cap or cap < 1 then
        local t = refs.unitTarget
        local gs = refs.gameState
        local prov = t and gs and gs.provinces and gs.provinces[t.provId] or nil
        cap = prov and (prov.garrison or 0) or 0
    end
    if cap < 1 then return 0 end
    local raw = refs.unitMoveCountField and refs.unitMoveCountField:GetValue() or ""
    local n = tonumber(raw) or cap
    if n < 1 then n = 1 end
    if n > cap then n = cap end
    return math.floor(n)
end

--- 进入调军模式时记下"这次能调多少"（面板随后会被关掉，状态不能靠它）
---@param cap number
function GameUI.beginArmyMoveCount(cap)
    refs.moveCap_ = math.max(0, math.floor(cap or 0))
    -- 输入框里的值若超出新上限，夹回去
    if refs.unitMoveCountField then
        local cur = tonumber(refs.unitMoveCountField:GetValue()) or 0
        if cur < 1 or cur > refs.moveCap_ then
            refs.unitMoveCountField:SetValue(tostring(math.max(1, math.floor(refs.moveCap_ * 0.5))))
        end
    end
end

--- 加减调军数量（照征兵面板的 bump）
---@param delta number
function GameUI.bumpMoveCount(delta)
    local n = GameUI.moveWanted() + delta
    local t = refs.unitTarget
    local gs = refs.gameState
    local prov = t and gs and gs.provinces and gs.provinces[t.provId] or nil
    local cap = prov and (prov.garrison or 0) or 0
    if n < 1 then n = 1 end
    if n > cap then n = cap end
    if refs.unitMoveCountField then refs.unitMoveCountField:SetValue(tostring(n)) end
    GameUI.refreshUnitPanel(gs)
end

--- 一键全部调走（2026-10-04：仿照 CK3 可自由分兵，允许不留守军）
function GameUI.setMoveCountMax()
    local t = refs.unitTarget
    local gs = refs.gameState
    local prov = t and gs and gs.provinces and gs.provinces[t.provId] or nil
    local cap = prov and (prov.garrison or 0) or 0
    if refs.unitMoveCountField then refs.unitMoveCountField:SetValue(tostring(cap)) end
    GameUI.refreshUnitPanel(gs)
end

--- 打开军队面板
---@param target table 行军军队对象（army）或 { provId = n }（驻军）或战斗对象（battle）
---@param mode string "army"（行军）| "garrison"（驻军）| "battle"（交战，2026-09-26）
function GameUI.showUnitPanel(target, mode)
    if not refs.unitPanel or not target then return end
    refs.unitTarget = target
    refs.unitMode = mode or "army"
    -- 是不是**自己的**军队（2026-09-24 用户："为什么点击敌人的军队会出现和我们一样的操作"）
    --   别人的军队/驻军：只看信息（将军、兵种、兵力），**不给任何操作按钮**
    --   （AoH3 也是这么做的：点敌国军队只弹详情）
    local gs = refs.gameState
    local pfId = gs and gs.playerFactionId
    local ownerId
    if refs.unitMode == "battle" then
        -- 交战中：任一方是自己 → 算"自己的仗"（但交战形态本来就不给按钮，只读）
        local att = target.att and target.att.factionId
        local def = target.def and target.def.factionId
        ownerId = (att == pfId and att) or (def == pfId and def) or att
    elseif refs.unitMode == "garrison" then
        local p = gs and gs.provinces and gs.provinces[target.provId]
        ownerId = p and (p.occupiedBy or p.ownerId)
    else
        ownerId = target.factionId
    end
    refs.unitIsOwn = (pfId ~= nil and ownerId == pfId)
    if refs.unitArmyBtns then
        if refs.unitMode == "army" and refs.unitIsOwn then refs.unitArmyBtns:Show() else refs.unitArmyBtns:Hide() end
    end
    if refs.unitGarrisonBtns then
        if refs.unitMode == "garrison" and refs.unitIsOwn then refs.unitGarrisonBtns:Show() else refs.unitGarrisonBtns:Hide() end
    end
    refs.unitPanel:Show()
    GameUI.refreshUnitPanel(refs.gameState)
end

--- 关闭军队面板
function GameUI.hideUnitPanel()
    if refs.unitPanel then refs.unitPanel:Hide() end
    refs.unitTarget = nil
    refs.unitMode = nil
end

--- 填充"兵种构成"明细（2026-09-24）
---   一支军队可以有多个兵种 → 按行列出「兵种名 + 人数」，只显示**有人的**兵种。
---   行是创建时全建好的，这里只改文字 + 显隐（UI 库不支持重建 children 重排）。
---@param detail table<string, number> 兵种id → 人数
---@param total number 总兵力（用于显示占比）
local function fillUnitMix(detail, total)
    if not refs.unitMixRows then return end
    local Units = require("data.Units")
    local shown = 0
    for _, u in ipairs(Units.all()) do
        local cell = refs.unitMixRows[u.id]
        if cell then
            local n = math.floor((detail and detail[u.id]) or 0)
            if n > 0 then
                local pct = (total and total > 0) and math.floor(n / total * 100 + 0.5) or 0
                cell.name:SetText(u.name)
                cell.count:SetText(string.format("%d（%d%%）", n, pct))
                cell.row:Show()
                shown = shown + 1
            else
                cell.row:Hide()
            end
        end
    end
    -- 一个兵种都没有（兵力 0）→ 给一行提示，别让这块空着
    if shown == 0 and refs.unitMixTitle then
        refs.unitMixTitle:SetText("兵种构成（无兵力）")
    elseif refs.unitMixTitle then
        refs.unitMixTitle:SetText("兵种构成")
    end
end

--- 刷新军队面板（行军进度/兵力会随时间变 → 由 Update 定时调）
---@param gs table|nil
function GameUI.refreshUnitPanel(gs)
    if not refs.unitPanel or not refs.unitPanel:IsVisible() then return end
    local t = refs.unitTarget
    if not t then return end
    gs = gs or refs.gameState
    if not gs then return end

    local UnitsM = require("data.Units")

    local function nameOf(pid)
        local p = gs.provinces and pid and gs.provinces[pid]
        return (p and p.name) or tostring(pid or "?")
    end

    if refs.unitBattleRow then
        if refs.unitMode == "battle" then refs.unitBattleRow:Show() else refs.unitBattleRow:Hide() end
    end
    -- 调军数量行默认藏起来：只有"自己的驻军"分支会重新打开（2026-10-04）
    if refs.unitMoveCountRow then refs.unitMoveCountRow:Hide() end
    -- 兵种构成区只在"行军/驻军"形态显示（交战形态已在上面单独隐藏）
    if refs.unitMode ~= "battle" then
        if refs.unitMixTitle then refs.unitMixTitle:Show() end
        if refs.unitMixList then refs.unitMixList:Show() end
    end

    if refs.unitMode == "battle" then
        -- 交战中（2026-09-26）：双方对照 —— 旗色 + 兵力 + **各自的士气**
        local b = t
        local att, def = b.att or {}, b.def or {}
        local attFac = gs.factions and gs.factions[att.factionId]
        local defFac = gs.factions and gs.factions[def.factionId]
        local attName = (attFac and attFac.name) or "?"
        local defName = (defFac and defFac.name) or "?"
        -- 省名：由调用方（onBattleClick）挂在 target.provId 上；没有就按对象身份反查
        local bpid = t.provId
        if not bpid and gs.battles then
            for pid2, b2 in pairs(gs.battles) do
                if b2 == t then bpid = pid2; break end
            end
        end
        refs.unitTitleLabel:SetText("交战中 · " .. nameOf(bpid))
        refs.unitBattleAttName:SetText("⚔ " .. attName)
        refs.unitBattleDefName:SetText(defName .. " ⚔")
        refs.unitBattleAttSize:SetText(string.format("%d", math.floor(att.size or 0)))
        refs.unitBattleDefSize:SetText(string.format("%d", math.floor(def.size or 0)))
        -- 士气：低于溃逃线（20）标红，提醒"快崩了"
        local function moraleTxt(m)
            m = math.floor(m or 0)
            return string.format("士气 %d", m)
        end
        refs.unitBattleAttMorale:SetText(moraleTxt(att.morale))
        refs.unitBattleDefMorale:SetText(moraleTxt(def.morale))
        local rout = require("config.GameConfig").Military.ROUT_MORALE or 20
        refs.unitBattleAttMorale.props.fontColor =
            ((att.morale or 0) <= rout + 10) and { 255, 130, 120, 255 } or { 200, 170, 170, 255 }
        refs.unitBattleDefMorale.props.fontColor =
            ((def.morale or 0) <= rout + 10) and { 255, 130, 120, 255 } or { 170, 185, 210, 255 }
        -- 顶部"兵力"栏在交战形态下不重复显示（双方数字已在对照行里）
        refs.unitTroopsLabel:SetText("—")
        refs.unitMoraleLabel:SetText("—")
        refs.unitRouteLabel:SetText("")
        refs.unitCommanderLabel:SetText("")
        refs.unitHintLabel:SetText("士气 ≤ " .. tostring(rout) .. " 时该方溃退")
        -- 交战形态不显示"兵种构成"（那是驻军面板的东西；这里双方数字已在对照行）
        if refs.unitMixTitle then refs.unitMixTitle:Hide() end
        if refs.unitMixList then refs.unitMixList:Hide() end
    elseif refs.unitMode == "army" then
        local fromId = t.from or t.fromProvinceId
        local toId   = t.to or t.toProvinceId
        local total  = t.totalHours or 72
        local prog   = math.min(1, math.max(0, (t.progress or 0) / (total > 0 and total or 1)))
        local leftDays = math.max(0, (total - (t.progress or 0)) / 24)
        local f = gs.factions and gs.factions[t.factionId]
        refs.unitTitleLabel:SetText((f and f.name or "?") .. "军 · 行军中")
        refs.unitTroopsLabel:SetText(string.format("%d", math.floor(t.size or 0)))
        refs.unitMoraleLabel:SetText(string.format("%d / 100", math.floor(t.morale or 0)))
        refs.unitRouteLabel:SetText(string.format("%s → %s", nameOf(fromId), nameOf(toId)))
        refs.unitHintLabel:SetText(string.format("还需 %.1f 天（%.0f%%）%s",
            leftDays, prog * 100, t.forced and "　·　急行军中" or ""))
        -- 行军部队的兵种构成（部队自带 unitMix；老存档没有 → 按势力主力兵种兜底）
        local size = math.floor(t.size or 0)
        local mix = UnitsM.normalizeMix(t.unitMix, UnitsM.mainOf(f).id)
        local detail = {}
        for id, r in pairs(mix) do detail[id] = math.floor(size * r) end
        fillUnitMix(detail, size)
    else
        local p = gs.provinces and t.provId and gs.provinces[t.provId]
        if not p then return end
        local MIL2 = require("systems.MilitarySystem")
        local controllerId = MIL2.controller(p)
        local f = gs.factions and gs.factions[controllerId]
        -- 占领状态可能在面板打开后变化，操作权跟随当前驻军，不跟随领土名义主人。
        refs.unitIsOwn = gs.playerFactionId ~= nil and controllerId == gs.playerFactionId
            and not (gs.battles and gs.battles[p.id])
        if refs.unitGarrisonBtns then refs.unitGarrisonBtns:SetVisible(refs.unitIsOwn) end
        refs.unitTitleLabel:SetText((p.name or "?") .. " · 驻军")
        -- 兵力显示"当前 / 统兵上限"（2026-09-23 用户："数字太大"+要有上限可看）
        --   有将军 → 上限 = 将军军事属性 × 500（补员目标）；没将军 → 不显示上限
        local cap = f and MIL2.commanderCapacity(gs, f, p.id) or nil
        if cap then
            refs.unitTroopsLabel:SetText(string.format("%d / %d", math.floor(p.garrison or 0), cap))
        else
            refs.unitTroopsLabel:SetText(string.format("%d", math.floor(p.garrison or 0)))
        end
        refs.unitMoraleLabel:SetText(string.format("%d / 100", math.floor(p.morale or 100)))
        -- 归属 / 地形（兵种改由下面的「兵种构成」明细负责，2026-09-24）
        refs.unitRouteLabel:SetText(string.format("归属：%s　　地形：%s",
            (f and f.name) or "无主", p.terrain or "平原"))
        -- 兵种构成明细（真实比例，不再是"势力主力兵种"一行字）
        fillUnitMix(UnitsM.detailOf(p, f), math.floor(p.garrison or 0))
        -- 将军行：有 → "统帅：姓名（军事 4 · 每月自动补员）"；没有 → 提示不会自动补员
        if refs.unitCommanderLabel then
            local cmd = f and MIL2.getProvinceCommander(gs, f.id, p.id) or nil
            if cmd then
                refs.unitCommanderLabel:SetText(string.format("统帅：%s（军事 %d%s）",
                    tostring(cmd.name), cmd.military or 3,
                    refs.unitIsOwn and MIL2.canRecruitIn(gs, f.id, p.id)
                        and " · 每月自动补员" or ""))
            elseif refs.unitIsOwn then
                refs.unitCommanderLabel:SetText("统帅：未指派（不自动补员）")
            else
                refs.unitCommanderLabel:SetText("统帅：未知")
            end
        end
        -- 提示语取消（2026-09-23 用户："在自家省份内可征募补员解散会永久损失这些兵，这些取消"）
        --   别人的军队：给一行说明"只能看不能操作"（2026-09-24）
        refs.unitHintLabel:SetText(refs.unitIsOwn and "" or "别国军队 · 只能查看")
        -- 调军数量行：只在"自己的驻军"时显示（2026-10-04）
        --   别人的省不能调军；行军/交战形态也没有"调军"这个动作
        if refs.unitMoveCountRow then
            local show = refs.unitIsOwn and true or false
            refs.unitMoveCountRow:SetVisible(show)
            if show and refs.unitMoveCountField then
                local cap = math.floor(p.garrison or 0)
                local cur = tonumber(refs.unitMoveCountField:GetValue()) or 0
                -- 驻军变了（补员/战斗）时把默认值跟到"一半"，但不覆盖玩家已填的合法值
                if cur < 1 or cur > cap then
                    refs.unitMoveCountField:SetValue(tostring(math.max(1, math.floor(cap * 0.5))))
                end
            end
        end
    end
end

-- ============================================================
-- 3.5) 自身 / 朝廷（2026-09-16 用户拍板拆分）
--   顶栏左上角 = **国名（纯名字）** + 「自身」「朝廷」两个入口：
--     * 自身 = 君主个人（五维 / 年龄 / 特质）
--     * 朝廷 = 左「官员」（三公六部学官，可任命）+ 右「后宫」
--   旧的国家面板（国事/官员两页签）已被这两个面板取代
-- ============================================================
function GameUI.showSelfPanel()
    if refs.selfPanel then refs.selfPanel:Show() end
end

function GameUI.hideSelfPanel()
    if refs.selfPanel then refs.selfPanel:Hide() end
end

function GameUI.toggleSelfPanel()
    if refs.selfPanel and refs.selfPanel:IsVisible() then
        GameUI.hideSelfPanel()
    else
        GameUI.hideCourtPanel()
        GameUI.showSelfPanel()
    end
end

function GameUI.showCourtPanel()
    if refs.courtPanel then refs.courtPanel:Show() end
end

function GameUI.hideCourtPanel()
    if refs.courtPanel then refs.courtPanel:Hide() end
    if refs.courtPickPanel then refs.courtPickPanel:Hide() end
end

function GameUI.toggleCourtPanel()
    if refs.courtPanel and refs.courtPanel:IsVisible() then
        GameUI.hideCourtPanel()
    else
        GameUI.hideSelfPanel()
        GameUI.showCourtPanel()
    end
end

-- ------------------------------------------------------------
-- 自身面板：君主个人（名字 / 年龄 / 五维 / 特质）
-- ------------------------------------------------------------
--- 朝廷面板（2026-09-26 拆到 ui/panels/CourtPanel.lua，422 行）
---   ⚠️ openCourtPick / showCommanderPick / refreshCourtPanel 原在这块里挂 GameUI，
---   搬走后 install() 挂回，否则 GameUI.refreshCourtPanel 会变 nil。
local CourtPanel = require("ui.panels.CourtPanel")
CourtPanel.install(GameUI)

--- 属性名：原是本文件内的局部函数，随朝廷块搬到了 CourtPanel。
---   GameUI.update 里还要用（政治/军事行），所以从模块取回来。
local attrNameOf = CourtPanel.attrNameOf

-- ⚠️ 不用缓存：GameUI.create 每次开局都会调（重开游戏 = 新的一棵树），
--   缓存会复用已销毁的旧控件。这里各建各的（CourtPanel 内部把两个面板
--   分别挂到 refs.selfPanel / refs.courtPanel，重建会覆盖，不会泄漏）。
-- ⚠️ CourtPanel.create 一次建出**两个**面板（自身 + 朝廷），
--   所以这里缓存当次的返回值给两个工厂共用，避免建两遍（重复建会白造一棵树）。
--   缓存只活一次 GameUI.create（见末尾清空），重开游戏不会复用旧控件。
local courtBuilt_
local function courtBuild(callbacks)
    if not courtBuilt_ then
        courtBuilt_ = { CourtPanel.create({
            UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
            SmallButton = SmallButton, callbacks = callbacks,
            TAB_TEXT_ACTIVE = TAB_TEXT_ACTIVE, TAB_TEXT_IDLE = TAB_TEXT_IDLE,
        }) }
    end
    return courtBuilt_[1], courtBuilt_[2]
end

local function createSelfPanel(callbacks)
    return (courtBuild(callbacks))
end

local function createCourtPanel(callbacks)
    local _, cp = courtBuild(callbacks)
    return cp
end

-- ============================================================
-- 3.75) Peace Dialog（和平条约窗口：选省/赔款/附庸/吞并，2026-09-03 AoH3 式左侧全高面板）
-- ============================================================

--- 和平条约 + 灭国确认（2026-09-26 拆到 ui/panels/PeaceDialog.lua，977 行）
---   这块与 GameUI 其余部分零耦合，整块搬走；方法由 install() 挂回主表。
local PeaceDialog = require("ui.panels.PeaceDialog")
PeaceDialog.install(GameUI)

local function createPeaceDialog(callbacks)
    return PeaceDialog.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton, callbacks = callbacks,
        WarSystem = WarSystem,
    })
end

-- ============================================================
-- 3.7) War Alert —— 🗑 已删除（2026-09-18）
--   用户："删掉「战争警报」的暂停 + 弹红框，改右上角普通通知"
--   现在：战斗开始/结束只走 GameState.addMessage(..., "war", true) →
--   顶栏下**右侧通知条**（createEventNoticeBar 的 noticeBar）；时间不再被战斗打断，
--   玩家想议和时点右下角的**战旗**（战争列表）进和谈。
-- ============================================================

-- ============================================================
-- 3.9) 事件弹窗（EventSystem 的界面层 · 2026-09-13）
--   事件三层：数据 data/Events.lua → 逻辑 systems/EventSystem.lua → 这里显示
--   选项按钮**按事件动态生成**（每条事件 1~4 个）
--   选择结果通过 GameUI.onEventChoose(index) 回给 main.lua（那里接 EventSystem.choose）
-- ============================================================

--- 显示一条事件（pending = { def = 事件定义表, factionId }）
---@param pending table|nil
function GameUI.showEventDialog(pending)
    if not refs.eventPanel or not pending or not pending.def then return end
    local def = pending.def
    refs.eventTitle:SetText(def.title or "事件")
    refs.eventBody:SetText(def.text or "")
    refs.eventChoiceHolder:ClearChildren()
    for i, choice in ipairs(def.choices or {}) do
        refs.eventChoiceHolder:AddChild(UI.Button {
            id = "eventChoice_" .. i,
            text = tostring(choice.text or ("选项" .. i)),
            width = "100%",
            height = NavigationHUD.touchSize(56),
            fontSize = 15,
            fontFamily = "gufeng",
            fontWeight = "bold",
            textColor = { 240, 228, 205, 255 },
            backgroundColor = { 54, 62, 84, 240 },
            hoverBackgroundColor = { 76, 88, 118, 245 },
            pressedBackgroundColor = { 42, 48, 66, 245 },
            borderWidth = 1,
            borderColor = { 150, 120, 70, 220 },
            borderRadius = 8,
            onClick = function()
                if GameUI.onEventChoose then GameUI.onEventChoose(i) end
            end,
        })
    end
    refs.eventPanel:Show()
    if refs.eventShade then refs.eventShade:Show() end
end

function GameUI.hideEventDialog()
    if refs.eventPanel then refs.eventPanel:Hide() end
    if refs.eventShade then refs.eventShade:Hide() end
end

function GameUI.isEventDialogVisible()
    return refs.eventPanel and refs.eventPanel:IsVisible() or false
end

--- 事件弹窗（居中偏上；2026-09-16 起：**时间不暂停**；"重要事件自动弹出"开关控制是否自动展开；
---   右上角 X = 关掉框但**不放弃事件**——顶栏下小条常驻，随时点回来处理）
local function createEventPanel()
    refs.eventTitle = UI.Label {
        text = "",
        fontSize = 20,
        fontFamily = "gufeng",
        fontWeight = "bold",
        fontColor = { 255, 215, 120, 255 },
    }
    local eventCloseBtn = SmallButton("X", function() GameUI.hideEventDialog() end, { id = "eventCloseBtn" })
    refs.eventBody = UI.Label {
        text = "",
        fontSize = 15,
        fontColor = COLORS.textPrimary,
        whiteSpace = "normal",
        maxLines = 4,
    }
    refs.eventChoiceHolder = UI.Panel {
        flexDirection = "column",
        gap = 6,
        width = "100%",
    }

    refs.eventPanel = UI.Panel {
        position = "absolute",
        top = "14%",
        left = "18%",
        width = "60%",
        maxWidth = 380,   -- 2026-09-16 缩小（用户："太占地方"）
        backgroundColor = { 13, 18, 28, 245 },
        borderRadius = 10,
        borderWidth = 1,
        borderColor = { 170, 130, 70, 235 },
        padding = 14,
        gap = 10,
        pointerEvents = "auto",
        children = {
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                width = "100%",
                children = { refs.eventTitle, eventCloseBtn },
            },
            UI.Divider { color = { 120, 100, 66, 180 }, thickness = 1 },
            UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0,
                children = { UI.Panel { width = "100%", gap = 10, children = { refs.eventBody, refs.eventChoiceHolder } } } },
        },
    }
    refs.eventPanel:Hide()

    -- 全屏透明遮罩（2026-09-16 用户要"点外面就关"）：
    --   点弹窗外任何地方 = 关闭。弹窗本体在遮罩**上层**，点弹窗里不会误关。
    refs.eventShade = UI.Button {
        text = "",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 0 },
        hoverBackgroundColor = { 0, 0, 0, 0 },
        pressedBackgroundColor = { 0, 0, 0, 0 },
        onClick = function() GameUI.hideEventDialog() end,
    }
    refs.eventShade:Hide()
    return refs.eventPanel
end

-- ============================================================
-- 3.9.1) 顶栏下"事件 / 通知条"（2026-09-16 用户拍板方案）
--   左：待处理事件小条（金框）——点开才弹框；是否自动展开由设置开关决定
--   右：最近通知小条（读 GameState.messages 尾部）——点开进日志
--   🔴 时间不暂停（用户明确"时间不能暂停"）——世界照跑，小条挂着直到做出选择
-- ============================================================

--- 点"待处理"小条 → 展开事件弹框
function GameUI.onEventBarClick()
    local pending = GameUI.pendingEvent_
    if pending then GameUI.showEventDialog(pending) end
end

--- 点某一条"待处理"小条 → 打开对应事件
---@param idx number 队列里的第几条（1 起）
function GameUI.openEventByIndex(idx)
    local p = (GameUI.pendingList_ or {})[idx]
    if p then
        -- UI 队列已按当前国家过滤，不能把过滤后的下标拿去结算全局队列。
        for i, globalPending in ipairs(require("systems.EventSystem").getPendingList()) do
            if globalPending == p then GameUI.openEventIndex_ = i; break end
        end
        GameUI.showEventDialog(p)
    end
end

--- 「重要事件自动弹出」开关
---   "重要"的定义 = **有选项需要玩家拍板的事件**；纯通知永远不会自动弹
function GameUI.setEventAutoPopup(v)
    GameUI.eventAutoPopup_ = v and true or false
    if refs.settingsAutoPopupBtn then
        refs.settingsAutoPopupBtn:SetText(
            GameUI.eventAutoPopup_ and "重要事件自动弹出：开" or "重要事件自动弹出：关")
    end
end

function GameUI.isEventAutoPopup()
    -- 默认**关**（2026-09-16 用户实测反馈："为什么他又弹出来啦…太占地方"）：
    --   事件来了只挂左上金条，玩家点开才弹框；想要"自动弹"的去设置里开
    if GameUI.eventAutoPopup_ == nil then GameUI.eventAutoPopup_ = false end
    GameUI.refs = refs   -- 供外部（和谈面板等）挂载到根面板
return GameUI.eventAutoPopup_
end

-- ============================================================
-- 战争迷雾开关（2026-09-24）
--   状态存在 GameState.fogOfWar（随存档走），这里只是 UI 侧读写 + 刷新按钮文字。
-- ============================================================

--- 战争迷雾是否开启
---@return boolean
function GameUI.isFogOfWar()
    local gs = refs.gameState
    return (gs and gs.fogOfWar) == true
end

--- 开关战争迷雾：立刻让可见性缓存失效 + 重绘地图 + 刷新按钮文字
---@param on boolean
function GameUI.setFogOfWar(on)
    local gs = refs.gameState
    if not gs then return end
    gs.fogOfWar = on and true or false
    gs.fogCache_ = nil            -- 缓存立刻失效，下一帧按新设置重算
    if refs.settingsFogBtn then
        refs.settingsFogBtn:SetText(gs.fogOfWar and "战争迷雾：开" or "战争迷雾：关")
    end
    print(string.format("[Fog] 战争迷雾切换为：%s", gs.fogOfWar and "开" or "关"))
end

--- 打开日志面板（点通知行时用；优先走 callbacks）
local function openLogPanel()
    if refs.callbacks and refs.callbacks.onLogToggle then
        refs.callbacks.onLogToggle()
    elseif GameUI.showLog then
        GameUI.showLog(refs.gameState)
    end
end

-- ===== 通知详情弹窗（2026-09-16）=====
--- 点通知条 → 弹详情（点 X / 点外面关闭）；**看过后标记已读，从条上消失**
---@param msg table|string|nil 消息对象（优先，可标记已读）或纯文本
function GameUI.showNoticeDialog(msg)
    if not refs.noticePanel then return end
    local text = type(msg) == "table" and msg.text or msg
    refs.noticeBody:SetText(tostring(text or ""))
    if type(msg) == "table" then
        msg.read = true          -- 已读 → 从通知条上消失（2026-09-16 用户要求）
        refs.noticeSig_ = nil    -- 强制下帧重建通知列表
    end
    refs.noticeShade:Show()
    -- ⚠️ 子元素（noticePanel）创建时是 Hide 的：父容器 Show 不会自动带出来，两个都要显式 Show
    if refs.noticePanel then refs.noticePanel:Show() end
    if refs.noticePanelBox then refs.noticePanelBox:Show() end
end

function GameUI.hideNoticeDialog()
    if refs.noticePanel then refs.noticePanel:Hide() end
    if refs.noticePanelBox then refs.noticePanelBox:Hide() end
    if refs.noticeShade then refs.noticeShade:Hide() end
end

--- 通知详情弹窗（2026-09-26 拆到 ui/panels/NoticePanel.lua）
---   拆分模式：面板导出 create(ctx)，ctx 注入 UI/GameUI/refs/COLORS，
---   避免面板文件 require GameUI 造成循环依赖。详见该文件头部说明。
local NoticePanel = require("ui.panels.NoticePanel")
local function createNoticePanel()
    return NoticePanel.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton, gameState = refs.gameState,
    })
end

--- 顶栏下"事件/通知区"（左 = 待处理事件列表；右 = 最近通知列表）
local function createEventNoticeBar()
    return require("ui.MessageCenter").create({ refs = refs, GameUI = GameUI })
end

-- ============================================================
-- 3.8) Policy / Tech Panels（框架占位，2026-09-01）
-- ⚠️ 刷新函数只有一份，定义在 createPolicyPanel 之后（见下方 GameUI.refreshPolicyPanel）
--    2026-09-16 教训：本文件曾同时存在两份同名定义，后者覆盖前者 → 隐藏逻辑永不生效

--- 政策面板是否开着（main 每帧据此刷新变法区）
function GameUI.isPolicyPanelOpen()
    return refs.policyPanel ~= nil and refs.policyPanel:IsVisible() == true
end

function GameUI.togglePolicyPanel()
    if not refs.policyPanel then return end   -- UI 还没装配好（Start 早期调用）
    if refs.policyPanel:IsVisible() then
        refs.policyPanel:Hide()
    else
        -- 打开时刷新变法列表（"有人提出"后才显示）
        if GameUI.refreshPolicyPanel then GameUI.refreshPolicyPanel(refs.gameState) end
        refs.policyPanel:Show()
    end
end

function GameUI.toggleTechPanel()
    if refs.techPanel and refs.techPanel:IsVisible() then
        refs.techPanel:Hide()
    else
        -- 打开时刷新（研究进度/完成状态可能在别处变了）
        if GameUI.refreshTechPanel then GameUI.refreshTechPanel(refs.gameState) end
        -- 按**顶栏实测底边**校准面板起点（2026-09-19 用户："上面那个不要被挡住"）：
        --   不同设备顶栏高度不同，别硬编码；布局这时已经算好，能拿到真实坐标
        if refs.techPanelBody then
            refs.techPanelBody:SetStyle({ top = 0, left = 0, right = 0, bottom = 0 })
        end
        refs.techPanel:Show()
    end
end

--- 政策/变法面板（2026-09-26 拆到 ui/panels/PolicyPanel.lua）
local PolicyPanel = require("ui.panels.PolicyPanel")
PolicyPanel.install(GameUI)

local function createPolicyPanel(callbacks)
    return PolicyPanel.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton, callbacks = callbacks,
        PolicySystem = PolicySystem,
    })
end

--- 收支明细面板（2026-09-26 拆到 ui/panels/EconomyPanel.lua）
local EconomyPanel = require("ui.panels.EconomyPanel")
EconomyPanel.install(GameUI)

local function createEconomyPanel()
    return EconomyPanel.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton, EconomySystem = EconomySystem,
    })
end

--- 科技面板（2026-09-26 拆到 ui/panels/TechPanel.lua，550 行）
---   ⚠️ onTechCatClick / refreshTechPanel 原本定义在这块里、挂在 GameUI 上，
---   搬走后必须 install 回主表，否则 GameUI.refreshTechPanel 会变成 nil。
local TechPanel = require("ui.panels.TechPanel")
TechPanel.install(GameUI)

local function createTechPanel(callbacks)
    return TechPanel.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton, callbacks = callbacks,
    })
end

-- 地图模式定义（2026-09-01；布局 3×2 两行）
--- 地图模式 / 战斗卡片 / 战争列表 / 战争面板（2026-09-26 拆到 ui/panels/WarPanel.lua，763 行）
local WarPanel = require("ui.panels.WarPanel")
WarPanel.install(GameUI)

-- 这四个面板由 WarPanel.create 一次建出（它们共享同一棵子树的构建时机）。
--   ⚠️ 统一在 buildWarPanels 里建，避免"某个工厂先被调、callbacks 传成 nil"。
local warBuilt_
local function buildWarPanels(callbacks)
    warBuilt_ = WarPanel.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton, Emblem = Emblem, callbacks = callbacks,
        WarSystem = WarSystem,
    })
    return warBuilt_
end

local function createMapModePanel(_) return warBuilt_ and warBuilt_.mapModePanel end
local function createBattleCards(_) return warBuilt_ and warBuilt_.battleCards end
local function createWarList()      return warBuilt_ and warBuilt_.warList end
local function createWarBar()       return warBuilt_ and warBuilt_.warBar end

--- 日志面板（2026-09-26 拆到 ui/panels/LogPanel.lua）
local LogPanel = require("ui.panels.LogPanel")
LogPanel.install(GameUI)

local function createLogPanel()
    return LogPanel.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton,
    })
end

--- 设置面板（2026-09-26 拆到 ui/panels/SettingsPanel.lua）
local SettingsPanel = require("ui.panels.SettingsPanel")
SettingsPanel.install(GameUI)

local function createSettingsPanel(callbacks)
    return SettingsPanel.create({
        UI = UI, GameUI = GameUI, refs = refs, COLORS = COLORS,
        SmallButton = SmallButton, callbacks = callbacks,
        MusicManager = MusicManager,
    })
end

-- ============================================================
-- 7) Diplomacy Panel（外交，保留）
-- ============================================================
local function createDiplomacyPanel(gameState, callbacks)
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

    -- 国交行动栏（2026-09-16 · 用户："不用一个一个点，点出宣战之后会自动弹跳到外边，
    --   然后点任何的国家就是立刻宣战，还可以涂抹"）
    --   点这里任一行动 → 面板自动关 → 地图进入该行动模式
    refs.diploActionRow = buildActGrid(
        require("data.Interactions").ACTIONS, 4, "diploAct_",
        function(act)
            if callbacks.onStartActMode then callbacks.onStartActMode(act.id) end
        end)

    local actionBlock = UI.Panel {
        width = "100%",
        flexDirection = "column",
        gap = 6,
        children = {
            UI.Label {
                text = "◆ " .. (require("data.Interactions").LABEL or "国交行动"),
                fontSize = 12,
                fontColor = COLORS.gold,
                fontWeight = "bold",
            },
            UI.Label {
                text = "点一个 → 面板自动关，回地图点或涂抹国家",
                fontSize = 10,
                fontColor = COLORS.textSecondary,
            },
            refs.diploActionRow,
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
                id = "diplomacyPanelBox", width = "96%", maxWidth = 600,
                height = "96%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 16,
                gap = 12,
                children = {
                    headerRow,
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0,
                        scrollY = true, children = { actionBlock } },
                },
            },
        },
    }
    refs.diploOverlay:Hide()

    return refs.diploOverlay
end

-- ============================================================
-- 6.5) 国交行动横幅（2026-09-16）
--   外交面板点了某个行动 → 面板自动关掉 → 顶栏下面挂这条横幅，
--   提示"现在点/涂抹地图上的国家就会执行这个行动"（用户："它会自动弹跳到外边"）
-- ============================================================
local function createActBanner(callbacks)
    refs.actBannerText = UI.Label {
        text = "",
        fontSize = 13,
        fontColor = COLORS.gold,
        fontWeight = "bold",
        whiteSpace = "normal",
        maxLines = 2,
    }
    refs.actBannerHint = UI.Label {
        text = "",
        fontSize = 11,
        fontColor = COLORS.textSecondary,
    }
    local cancelBtn = SmallButton("取消", function()
        if callbacks.onExitActMode then callbacks.onExitActMode() end
    end, { height = 32, fontSize = 12, paddingH = 10, bg = COLORS.btnDanger, hoverBg = COLORS.btnDangerHover })

    ---@type Widget
    local banner = UI.Panel {
        position = "absolute",
        top = 58, left = 0, right = 0,
        alignItems = "center",
        pointerEvents = "box-none",
        children = {
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                gap = 10,
                paddingHorizontal = 14,
                paddingVertical = 8,
                backgroundColor = { 25, 30, 44, 240 },
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.gold,
                pointerEvents = "auto",
                children = {
                    UI.Panel {
                        width = 4, height = 30,
                        borderRadius = 2,
                        backgroundColor = COLORS.btnDanger,
                    },
                    UI.Panel {
                        flexDirection = "column",
                        gap = 1,
                        children = { refs.actBannerText, refs.actBannerHint },
                    },
                    cancelBtn,
                },
            },
        },
    }
    banner:Hide()
    return banner
end

--- 进入国交行动模式时显示（main.lua 调）
---@param actionName string
---@param actionDesc string
---@param paintable boolean
function GameUI.showActBanner(actionName, actionDesc, paintable)
    if not refs.actBanner then return end
    refs.actModeName_ = actionName
    refs.actBannerText.text = "「" .. actionName .. "」" .. (actionDesc or "")
    refs.actBannerHint.text = paintable
        and "点击或涂抹地图上的国家即可执行 · 右键 / ESC 取消"
        or "点击地图上的国家即可执行 · 右键 / ESC 取消"
    refs.actBanner:Show()
end

function GameUI.hideActBanner()
    refs.actModeName_ = nil
    if refs.actBanner then refs.actBanner:Hide() end
end

--- 是否处于国交行动模式（main 的地图回调据此判断）
function GameUI.isActMode()
    return refs.actModeName_ ~= nil
end

-- ============================================================
-- 7) Zoom Controls（已移除：手机用双指捏合缩放，2026-08-29）
-- ============================================================

-- ============================================================
-- Public API
-- ============================================================

function GameUI.hideNavigationMenu()
    if refs.navigation then refs.navigation:Hide() end
    if refs.flagMenuIndicator then refs.flagMenuIndicator:SetText("▼") end
end

function GameUI.toggleNavigationMenu()
    if not refs.navigation then return end
    if refs.navigation:IsVisible() then
        GameUI.hideNavigationMenu()
    else
        GameUI.hideSelfPanel()
        GameUI.hideCourtPanel()
        GameUI.hideDiplomacy()
        GameUI.hideArmyPanel()
        for _, name in ipairs({ "policyPanel", "techPanel", "settingsOverlay", "speedMenu", "economyPanel", "logOverlay" }) do
            if refs[name] then refs[name]:Hide() end
        end
        if GameUI.hideMessageCenter then GameUI.hideMessageCenter() end
        local callbacks = refs.callbacks or {}
        if GameUI.isActMode() and callbacks.onExitActMode then callbacks.onExitActMode() end
        if GameUI.isWarBarVisible and GameUI.isWarBarVisible() then GameUI.closeWarBar() end
        refs.navigation:Show()
        refs.flagMenuIndicator:SetText("▲")
        if refs.eventBarBox then refs.eventBarBox:Hide() end
    end
end

-- 主入口互斥；调用旧关闭接口，保留征召选省等状态清理。
function GameUI.openNavigation(key)
    GameUI.hideNavigationMenu()
    if GameUI.hideMessageCenter then GameUI.hideMessageCenter() end
    local panels = { self = refs.selfPanel, court = refs.courtPanel, diplomacy = refs.diploOverlay,
        policy = refs.policyPanel, tech = refs.techPanel, army = refs.armyPanel,
        settings = refs.settingsOverlay, speed = refs.speedMenu, economy = refs.economyPanel }
    local current = panels[key]
    local wasOpen = current and current:IsVisible()
    local callbacks = refs.callbacks or {}
    if GameUI.isActMode() and callbacks.onExitActMode then callbacks.onExitActMode() end
    if GameUI.isWarBarVisible and GameUI.isWarBarVisible() then GameUI.closeWarBar() end
    GameUI.hideSelfPanel()
    GameUI.hideCourtPanel()
    GameUI.hideDiplomacy()
    GameUI.hideArmyPanel()
    for _, name in ipairs({ "policy", "tech", "settings", "speed", "economy" }) do
        if panels[name] then panels[name]:Hide() end
    end
    if refs.courtDetailPanel then refs.courtDetailPanel:Hide() end
    if refs.provincePanel then refs.provincePanel:Hide() end
    if refs.unitPanel then refs.unitPanel:Hide() end
    if not wasOpen then
        local cb = refs.callbacks or {}
        if key == "self" then GameUI.showSelfPanel()
        elseif key == "court" then GameUI.showCourtPanel()
        elseif key == "diplomacy" then
            if cb.onDiplomacyToggle then cb.onDiplomacyToggle() else GameUI.showDiplomacy(refs.gameState) end
        elseif key == "policy" then GameUI.togglePolicyPanel()
        elseif key == "tech" then GameUI.toggleTechPanel()
        elseif key == "army" then GameUI.showArmyPanel()
        elseif key == "settings" then GameUI.toggleSettings()
        elseif key == "speed" then GameUI.toggleSpeedMenu()
        elseif key == "economy" then GameUI.toggleEconomyPanel() end
    end
    NavigationHUD.updateActive(refs)
    print("[Navigation] " .. key .. (wasOpen and " 已收起" or " 已打开"))
end

function GameUI.fitTouchTargets(widget)
    if not widget then return end
    local f = graphics:GetDPR() / math.max(0.01, UI.GetScale())
    if widget.className == "Button" or widget.className == "TextField" then
        local p = widget.props
        widget:SetStyle({ minWidth = 48 * f, minHeight = 48 * f,
            height = math.max(tonumber(p.height) or 0, 48 * f) })
        if p.text == "关闭" then widget:SetStyle({ width = 72 * f, fontSize = 12 * f }) end
    end
    for _, child in ipairs(widget.children or {}) do GameUI.fitTouchTargets(child) end
end

-- 普通面板限定在 HUD 中间；不抬高导航到真正模态层之上。
local function syncNavigationLayout()
    local m, changed = NavigationHUD.layout(refs)
    if not changed then return end
    local function bound(panel)
        if panel then panel:SetStyle({ top = m.top, left = m.left, right = m.right, bottom = m.bottom }) end
    end
    for _, panel in ipairs({ refs.selfPanel, refs.courtPanel, refs.diploOverlay, refs.policyPanel,
        refs.techPanel, refs.speedMenu, refs.economyPanel, refs.settingsOverlay, refs.logOverlay }) do bound(panel) end
    bound(refs.eventShade)
    bound(refs.noticeShade)
    bound(refs.noticePanelBox)
    if refs.noticePanel then refs.noticePanel:SetStyle({ width = "98%", maxWidth = m.contentW - 12 * m.factor }) end
    if refs.techPanelBody then refs.techPanelBody:SetStyle({ top = 0, left = 0, right = 0, bottom = 0 }) end
    if refs.armyPanel then refs.armyPanel:SetStyle({ paddingTop = m.top, paddingLeft = m.left,
        paddingRight = m.right, paddingBottom = m.bottom }) end
    if refs.unitPanel then refs.unitPanel:SetStyle({ left = m.left, bottom = m.bottom }) end
    -- 军队详情面板高度上限（2026-10-05 用户：手机端"都抄边了"）。
    --   ⚠️ 必须按顶栏**实测底边**算，不能写死 m.top —— 手机端 UI 变窄时顶栏资源行会
    --   换行变高（见上方省份面板同款校准），写死就会让面板顶进顶栏。
    --   面板贴底，超出的高度交给兵种滚动区（flexShrink）吸收。
    if refs.unitPanelBox then
        local topBarBottom = m.top
        local probe = refs.topDate or refs.topNation
        if probe then
            local lay = probe:GetAbsoluteLayout()
            if lay and lay.y and lay.h and lay.h > 0 then topBarBottom = lay.y + lay.h end
        end
        local panelBottom = m.height - m.bottom
        local cap = panelBottom - topBarBottom - m.gutter
        if cap > 200 then refs.unitPanelBox:SetStyle({ maxHeight = cap }) end
    end
    if refs.provincePanel then refs.provincePanel:SetStyle({ top = m.top + m.gutter, left = m.left + m.gutter }) end
    if refs.mapModePanel then refs.mapModePanel:SetStyle({ bottom = m.bottom + m.gutter, right = m.right + m.gutter }) end
    local f = m.factor
    local contentWidth = m.contentW - 12 * f
    for _, panel in ipairs({ refs.selfPanel, refs.courtPanel, refs.diploOverlay, refs.policyPanel,
        refs.speedMenu, refs.economyPanel, refs.settingsOverlay, refs.logOverlay }) do
        panel:SetStyle({ alignItems = "flex-start", justifyContent = "flex-start", padding = 6 * f })
        local box = panel.children and panel.children[1]
        if box then box:SetStyle({ width = contentWidth, height = "100%", maxWidth = contentWidth }) end
    end
    if refs.policyPanel then
        local box = refs.policyPanel.children[1]
        if box then box:SetStyle({ width = contentWidth, maxWidth = contentWidth }) end
    end
    if refs.mapModePanel then
        refs.mapModePanel:SetStyle({ width = math.min(216 * f, m.contentW - 12 * f), padding = 4 * f, gap = 4 * f })
        refs.mapModeHeader:SetHeight(44 * f)
        refs.mapModeDesc:SetStyle({ fontSize = 10 * f, whiteSpace = "nowrap", maxLines = 1, height = 20 * f, verticalAlign = "middle" })
        refs.mapModeFoldBtn:SetStyle({ fontSize = 10 * f, width = 18 * f, height = 20 * f, verticalAlign = "middle" })
        refs.mapModeBody:SetStyle({ gap = 6 * f })
        for _, row in ipairs(refs.mapModeBody.children) do row:SetStyle({ width = "100%", gap = 6 * f }) end
        for _, btn in pairs(refs.mapModeButtons) do btn:SetStyle({ width = "auto", flexGrow = 1, flexBasis = 0, height = 48 * f, fontSize = 11 * f, paddingHorizontal = 0 }) end
    end
    for _, panel in ipairs({ refs.selfPanel, refs.courtPanel, refs.diploOverlay, refs.policyPanel,
        refs.techPanel, refs.speedMenu, refs.economyPanel, refs.settingsOverlay, refs.armyPanel, refs.unitPanel }) do GameUI.fitTouchTargets(panel) end
    local courtBox = refs.courtPanel and refs.courtPanel:FindById("courtPanelBox")
    if courtBox then courtBox:SetStyle({ maxWidth = contentWidth, padding = 10 * f, gap = 6 * f }) end
    for _, name in ipairs({ "courtTabRulerBtn", "courtTabOfficeBtn", "courtTabConsortBtn", "courtTabGeneralBtn", "courtTabTalentBtn" }) do
        if refs[name] then refs[name]:SetStyle({ height = 48 * f, minWidth = 56 * f, fontSize = 11 * f }) end
    end
    for _, name in ipairs({ "armyCloseBtn", "unitCloseBtn", "settingsCloseBtn", "economyCloseBtn" }) do
        if refs[name] then refs[name]:SetStyle({ width = 72 * f, height = 48 * f, fontSize = 12 * f, text = "关闭", flexShrink = 0 }) end
    end
    if refs.warBar then
        refs.warBar:SetStyle({ width = m.contentW, left = m.left })
        refs.warBarAlignPending_ = true
    end
    for _, boxId in ipairs({ "courtPickBox", "courtDetailBox", "speedPanelBox", "diplomacyPanelBox" }) do
        local box = refs.rootPanel:FindById(boxId)
        if box then box:SetStyle({ width = contentWidth, maxWidth = contentWidth, padding = 10 * f }) end
    end
    for _, button in pairs(refs.techCatButtons or {}) do
        button:SetStyle({ height = 48 * f, width = 78 * f, fontSize = 11 * f })
    end
    for _, button in ipairs(refs.speedMenuButtons or {}) do button:SetHeight(48 * f) end
    if refs.selfPanelBox then require("ui.panels.SelfPanel").layout(refs, m) end
    if refs.battleCardPanel then refs.battleCardPanel:SetStyle({ bottom = m.bottom + m.gutter }) end
    if refs.warPanel then refs.warPanel:SetStyle({ bottom = m.bottom + m.gutter, right = m.right + 268 * f }) end
    if refs.battleCardPanel then refs.battleCardPanel:SetStyle({ right = m.right + (m.narrow and 8 or 430) * f,
        bottom = m.bottom + (m.narrow and 212 or 8) * f }) end
    if m.narrow and refs.warPanel then refs.warPanel:SetStyle({ right = m.right + 8 * f, bottom = m.bottom + 316 * f }) end
    if refs.eventPanel then refs.eventPanel:SetStyle({ top = m.top + 6 * f, left = m.left + 6 * f,
        width = contentWidth, maxWidth = contentWidth, height = m.contentH - 12 * f }) end
    if refs.eventNoticeBar then require("ui.MessageCenter").layout(refs, m) end
    if refs.actBanner then refs.actBanner:SetStyle({ top = m.top + m.gutter, left = m.left }) end
end

--- Create the full game UI overlay.
function GameUI.create(gameState, callbacks)
    callbacks = callbacks or {}
    refs = {}
    refs.callbacks = callbacks
    refs.gameState = gameState
    refs.selectedProvinceId = nil
    refs.selectedOwnerId = nil
    refs.lastWarSig = ""

    local topBar, navigation = createTopBar(gameState, callbacks)
    refs.topBar = topBar
    local provincePanel = createProvincePanel(gameState, callbacks)
    local rankingPanel = createRankingPanel()
    local speedMenu = createSpeedMenu(callbacks)
    local armyPanel = createArmyPanel()               -- 征召军队（2026-09-19 用户：研究右边「军队」）
    local unitPanel = createUnitPanel()               -- 军队详情（2026-09-23 用户：点击军队弹出）
    local selfPanel = createSelfPanel(callbacks)      -- 自身（君主）
    local courtPanel = createCourtPanel(callbacks)    -- 朝廷（左官员 / 右后宫）
    -- 战争相关的四个面板由 WarPanel 一次建出（见 buildWarPanels 注释）
    buildWarPanels(callbacks)
    local warPanel = createWarList()
    local warBar = createWarBar()                 -- 底部战争面板（点战旗展开）
    local mapModePanel = createMapModePanel(callbacks)
    local battleCardPanel = createBattleCards(callbacks)
    local eventPanel = createEventPanel()          -- 同时建好 refs.eventShade（点外面=关）
    local eventNoticeBar = createEventNoticeBar()
    local noticePanel = createNoticePanel()        -- 通知详情弹窗（同时建好 refs.noticeShade）
    local logPanel = createLogPanel()
    local peaceDialog = createPeaceDialog(callbacks)
    local policyPanel = createPolicyPanel(callbacks)   -- ⚠️ 必须传 callbacks（2026-09-16 修崩溃：漏传导致 onClick 里 callbacks=nil）
    local economyPanel = createEconomyPanel()         -- 收支明细（2026-09-25）
    local techPanel = createTechPanel()
    local settingsPanel = createSettingsPanel(callbacks)
    local diplomacyPanel = createDiplomacyPanel(gameState, callbacks)
    refs.actBanner = createActBanner(callbacks)   -- 国交行动模式横幅（点/涂抹国家执行）

    local root = UI.Panel {
        position = "absolute",
        top = 0,
        left = 0,
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            -- ⚠️ 待办/消息摘要放**最底层**（用户 2026-10-05："只要能够把它看起来是遮住的，
            --    都是能够在它上面"）。渲染顺序 = 添加顺序 → 排第一 = 谁都能盖住它。
            refs.messageSummaries,
            provincePanel,
            mapModePanel,
            battleCardPanel,
            warPanel,
            unitPanel,
            topBar,
            refs.actBanner,
            rankingPanel,
            logPanel,
            speedMenu,
            selfPanel,
            courtPanel,
            policyPanel,
            economyPanel,
            techPanel,
            settingsPanel,
            diplomacyPanel,
            armyPanel,
            eventNoticeBar,
            navigation,
            refs.eventShade,
            eventPanel,
            refs.noticeShade,
            noticePanel,
            peaceDialog,
            warBar,
        },
    }

    refs.rootPanel = root

    -- 清掉"一次建两个面板"的当次缓存（2026-09-26）：否则重开游戏会复用上一局的
    -- 旧控件（已从树上摘掉），新局的朝廷/自身面板会是死的。
    courtBuilt_ = nil
    warBuilt_ = nil

    -- Initial update
    GameUI.update(gameState)

    return root
end

--- Update all UI labels and values from current game state.
function GameUI.update(gameState, timeSystem)
    if not refs.rootPanel then return end
    syncNavigationLayout()
    NavigationHUD.updatePortrait(refs, gameState)
    NavigationHUD.updateActive(refs)

    -- 征召面板可见时定期刷新（2026-09-19 用户："这个数值为什么对不上"）：
    --   面板原来只在打开/操作时刷新 → 钱粮一直在涨，面板却停在旧值
    --   （顶栏 3131 / 面板 2043 就是这么来的）。0.4 秒一次，开销可忽略。
    if refs.armyPanel and refs.armyPanel:IsVisible() then
        local t = os.clock()
        if not refs.armyPanelRefreshAt or (t - refs.armyPanelRefreshAt) > 0.4 then
            refs.armyPanelRefreshAt = t
            GameUI.refreshArmyPanel(gameState)
        end
    end

    -- 军队详情面板可见时同样定期刷新（2026-09-23）：行军进度一直在走，
    --   不刷新的话"还需 X 天"会停在开面板那一刻
    if refs.unitPanel and refs.unitPanel:IsVisible() then
        local t2 = os.clock()
        if not refs.unitPanelRefreshAt or (t2 - refs.unitPanelRefreshAt) > 0.25 then
            refs.unitPanelRefreshAt = t2
            GameUI.refreshUnitPanel(gameState)
        end
    end

    -- 顶栏：国家名 + 资源
    local pid = gameState.playerFactionId
    local pf = pid and gameState.factions[pid] or nil
    if pf then
        -- 国名文字**隐藏**（旗面上的字就是国名 · 2026-09-17）；只在观战时才用文字
        refs.topNation:Hide()
        refs.topFlagSlot:Show()
        if refs.topFlagSlot and refs.topFlagFactionId ~= pid then
            refs.topFlagFactionId = pid
            refs.topFlagSlot:ClearChildren()
            ---@type Widget
            local flagW = Emblem.MakeCloth(pf, "army", 34)   -- 锦旗式：不带杆
            refs.topFlagSlot:AddChild(flagW)
        end
        -- 总人口：人口只按月变化，1 秒算一次足够（避免每帧遍历省份）
        local now = os.clock()
        if not refs.popCacheT_ or (now - refs.popCacheT_) > 1.0 then
            refs.popCacheT_ = now
            refs.popCacheV_ = EconomySystem.getFactionPopulation(gameState, pid)
        end
        -- 资源格：按注册表取数（绑定型取字段、注册型取 faction.resources；
        -- "人口"是只读型 → 用上面 1 秒一次的总人口缓存）
        local Resources = require("data.Resources")
        for id, st in pairs(refs.topStats or {}) do
            if id == "pop" then
                st.value.text = fmtNum(refs.popCacheV_ or 0)
            else
                st.value.text = fmtNum(Resources.get(pf, id) or 0)
            end
        end
    else
        -- 观战：没有国家 → 收起旗，用文字提示
        refs.topNation:Show()
        refs.topNation:SetText("观战")
        refs.topFlagSlot:Hide()
        refs.topFlagFactionId = nil
        if refs.topFlagSlot then refs.topFlagSlot:ClearChildren() end
        for _, st in pairs(refs.topStats or {}) do
            st.value.text = "-"
        end
    end
    -- 时间大筐（合并暂停/开始）："⏸ 春 -770年 1月 15日" / 暂停时 "▶ …"，点击切换
    if timeSystem and timeSystem.getShortDate then
        refs.topDate:SetText(timeSystem.getShortDate())
        -- 日期变长（纪元推进）时自动缩字号，保证不溢出（2026-10-05）
        require("ui.NavigationHUD").fitDateText(refs)
        if refs.pauseIcon then refs.pauseIcon:SetText(gameState.paused and "▶" or "Ⅱ") end
    end

    -- 时间流速长条文本 + 弹出菜单当前档高亮
    --   档数从 GameConfig 读（2026-09-19：扩到 7 档后不再写死 5）
    local GameConfig = require("config.GameConfig")
    local speedCount = #((GameConfig.Time and GameConfig.Time.SPEEDS) or {})
    local curSpeed = gameState.speed or 0
    if refs.speedBar then
        -- AoH3 式："速度 3/7"（2026-09-16 用户："像历史时代3一样…显示几分之几"）
        refs.speedBar:SetText("速度 " .. tostring(curSpeed) .. "/" .. tostring(speedCount))
    end
    for i = 1, speedCount do
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

    -- 自身面板（君主：名字/年龄/五维/特质 · 2026-09-16 从旧国家面板拆出来）
    if refs.selfPanel and refs.selfPanel:IsVisible() and pf then
        refs.selfNationName.text = pf.fullName or pf.name or "?"
        local CharacterSystem = require("systems.CharacterSystem")
        CharacterSystem.ensureInit(gameState)
        local leader = pf.leader
        local leaderChar = CharacterSystem.getById(gameState, pf.leaderId)
        if leader then
            refs.selfLeaderLine.text = string.format("君主：%s（%d 岁）", leader.name, leader.age or 0)
            local c = leaderChar
            local function v(attrId, fallback)
                local val = (c and c[attrId]) or fallback or 3
                return string.format("%s %d", attrNameOf(attrId), val)
            end
            refs.selfAttrLine.text = table.concat({
                v("diplomacy", leader.diplo),
                v("military", leader.military),
                v("management", leader.admin),
                v("intrigue"),
                v("learning"),
            }, "    ")
            local traits = (c and c.traits) or leader.traits
            refs.selfTraitLine.text = (traits and #traits > 0)
                and ("特质：" .. table.concat(traits, "、"))
                or "特质：——"
        else
            refs.selfLeaderLine.text = "君主：无"
            refs.selfAttrLine.text = ""
            refs.selfTraitLine.text = ""
        end
    end

    -- 朝廷面板（左官员 / 右后宫）
    if refs.courtPanel and refs.courtPanel:IsVisible() and pf then
        -- 人事变动不频繁：1 秒重建一次行即可（避免每帧 ClearChildren 造成布局抖动）
        local now2 = os.clock()
        if not refs.courtCacheT_ or (now2 - refs.courtCacheT_) > 1.0 then
            refs.courtCacheT_ = now2
            GameUI.refreshCourtPanel(gameState)
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
            -- 驻军 / 补给容量（2026-09-19 照 CK3）：超编时标红提示会饿死
            do
                local MilitarySystem = require("systems.MilitarySystem")
                local g = prov.garrison or 0
                local cap = MilitarySystem.supplyCapacity(prov)
                if g > cap then
                    refs.provGarrison.text = string.format("驻军: %d / %d（超编，每月逃散）", g, cap)
                    refs.provGarrison.props.fontColor = { 235, 120, 90, 255 }
                else
                    refs.provGarrison.text = string.format("驻军: %d / %d", g, cap)
                    refs.provGarrison.props.fontColor = COLORS.army
                end
            end

            -- 该省月产出（2026-09-21：替代已删的"治安"行）
            do
                local TimeSystem = require("core.TimeSystem")
                local gold, food = EconomySystem.getProvinceIncome(prov, TimeSystem.getSeason())
                refs.provIncome.text = string.format("月产: %d 金 · %d 粮",
                    math.floor((gold or 0) + 0.5), math.floor((food or 0) + 0.5))
            end
        end
    end

    -- 战争列表
    GameUI.refreshWarList(gameState)

    -- 底部战争面板（打开时刷新双方分数/兵力）
    GameUI.refreshWarBar(gameState)
    if GameUI.isPeaceDialogVisible() then GameUI.refreshPeaceDialog(gameState, true) end

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

        -- 该省月产出（2026-09-21：替代已删的"治安"行）
        do
            local TimeSystem = require("core.TimeSystem")
            local gold, food = EconomySystem.getProvinceIncome(provinceData, TimeSystem.getSeason())
            refs.provIncome.text = string.format("月产: %d 金 · %d 粮",
                math.floor((gold or 0) + 0.5), math.floor((food or 0) + 0.5))
        end

        local pid = refs.gameState.playerFactionId
        local ownerId = provinceData.ownerId

        if provinceData.isWasteland then
            -- 沙漠废土：显示沙漠信息 + 恢复按钮（仅玩家可恢复）
            refs.provTerrain.text = "地形: 沙漠"
            refs.provOwner.text = "领主: 无主"
            refs.provInteract:Hide()
            refs.provActionHint.text = "沙漠之地：不可占领、无产出、不能驻军"
        elseif pid and ownerId == pid then
            -- 己方省：调军（征兵已删 —— 2026-09-21 用户：走顶栏「军队」）
            refs.provInteract:Hide()
            -- （2026-09-23）调军按钮已删：军队操作走左下角的军队面板，见 refs.btnMoveArmy 处注释
            if (provinceData.garrison or 0) < 1 then
                refs.provActionHint.text = "无驻军 · 顶栏「军队」可征召"
            end
        elseif ownerId then
            -- 别国省：一整排国交行动（2026-09-16 用户："不只是现在的宣战"）
            refs.provInteract:Show()
            local owner = refs.gameState.getFaction and refs.gameState.getFaction(ownerId)
            refs.provActionHint.text = "对 " .. ((owner and owner.name) or "?") .. "：点行动即生效"
        else
            -- 无主之地
            refs.provInteract:Hide()
            refs.provActionHint.text = "无主之地：可派军前往占领"
        end
    end

    -- 顶部按顶栏**实测底边**校准（2026-09-21）：顶栏 minHeight 54 + flexWrap —— 窄屏换行会变高，
    --   写死 top=52 会压住换行后的资源行（和征召面板 syncArmyPanelTop 同一套做法）
    do
        local probe = refs.topDate or refs.topNation
        if probe then
            local lay = probe:GetAbsoluteLayout()
            if lay and lay.y and lay.h and lay.h > 0 then
                refs.provincePanel:SetStyle({ top = math.floor(lay.y + lay.h + 4) })
            end
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
---   2026-09-16：不再逐个列国家（用户："这些国家为什么还在"）——
---   面板 = 「国交行动」栏 + 一句操作提示；对谁动手由"回地图点/涂抹哪个国家"决定
function GameUI.showDiplomacy(gameState)
    if not refs.diploOverlay then return end
    if GameUI.hideMessageCenter then GameUI.hideMessageCenter() end
    GameUI.hideNavigationMenu()
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

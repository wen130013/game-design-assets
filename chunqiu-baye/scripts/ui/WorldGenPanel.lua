-- ============================================================================
-- WorldGenPanel.lua — 世界生成面板（编辑器内入口：随机生成国家并划分领土）
-- 参数：地图包 / 尺寸(预留) / 省数量(预留) / 势力数量 / 随机种子
-- 用法：WorldGenPanel.show({ root = ... , onApply = function(params) ... end })
--   params = { pack, size, provinces, factions, seed, factionCount }
--   面板只负责收集参数；"生成"由调用方执行（编辑器里 = 随机建国 + 划分领土）
-- ============================================================================

local UI = require("urhox-libs/UI")
local MapPack = require("data.MapPack")

local WorldGenPanel = {}

--- 当前打开的面板（防重入）
local current = nil

local PANEL_BG  = { 18, 22, 34, 245 }
local BORDER    = { 150, 120, 70, 220 }
local ROW_BG    = { 40, 44, 58, 225 }
local GOLD      = { 255, 200, 50, 255 }
local TEXT      = { 235, 232, 225, 255 }
local TEXT_DIM  = { 170, 178, 195, 210 }

local SIZE_OPTS = { "小", "中", "大" }
local PROV_OPTS = { "少", "中", "多" }
local FACTION_OPTS = { "少", "中", "多" }
local FACTION_COUNTS = { 6, 12, 24 }

--- 打开世界生成面板
---@param opts table { root=Widget, onApply=function(params) }
function WorldGenPanel.show(opts)
    if current then return end
    opts = opts or {}
    local root = opts.root
    if not root then return end

    -- 参数（暂存于面板；点"生成新世界"时回调）
    local params = {
        pack      = MapPack.activeId,
        size      = 3,   -- 小/中/大（预留：当前地图为既定图，暂不参与生成）
        provinces = 2,   -- 少/中/多（预留）
        factions  = 2,   -- 少/中/多
        seed      = tostring(math.random(1000, 9999)),
    }
    params.factionCount = FACTION_COUNTS[params.factions]

    -- 地图包候选
    local packIds, packLabels = {}, {}
    for id, p in pairs(MapPack.registry) do
        packIds[#packIds + 1] = id
        packLabels[#packLabels + 1] = tostring(p.LABEL or p.name or id)
    end
    table.sort(packIds)
    local packIdx = 1
    for i, id in ipairs(packIds) do
        if id == params.pack then packIdx = i end
    end
    params.pack = packIds[packIdx] or params.pack

    local function close()
        if current and current.parent then
            current.parent:RemoveChild(current)
        end
        current = nil
    end

    -- 通用 "标签 标值 << >>" 行
    local function cycleRow(labelText, list, getIdx, setIdx)
        local valueLabel = UI.Label {
            text = list[getIdx()], fontSize = 13, width = 96, textAlign = "center",
            fontWeight = "bold", fontColor = GOLD,
        }
        local function refresh()
            valueLabel:SetText(list[getIdx()])
        end
        local function step(d)
            local n = #list
            setIdx(((getIdx() - 1 + d) % n) + 1)
            refresh()
        end
        local function arrow(txt, d)
            return UI.Button {
                text = txt, width = 34, height = 30, fontSize = 13,
                textColor = TEXT, backgroundColor = { 62, 66, 84, 230 },
                hoverBackgroundColor = { 84, 90, 112, 240 },
                borderRadius = 6,
                onClick = function() step(d) end,
            }
        end
        return UI.Panel {
            width = "100%", height = 38, flexDirection = "row", alignItems = "center", gap = 6,
            children = {
                UI.Label { text = labelText, fontSize = 12, flexGrow = 1, fontColor = TEXT_DIM },
                arrow("<<", -1),
                valueLabel,
                arrow(">>", 1),
            },
        }
    end

    -- 地图包行
    local function packRow()
        local valueLabel = UI.Label {
            text = packLabels[packIdx], fontSize = 13, width = 120, textAlign = "center",
            fontWeight = "bold", fontColor = GOLD,
        }
        local function refresh()
            valueLabel:SetText(packLabels[packIdx])
            params.pack = packIds[packIdx]
        end
        local function step(d)
            local n = #packIds
            packIdx = ((packIdx - 1 + d) % n) + 1
            refresh()
        end
        local function arrow(txt, d)
            return UI.Button {
                text = txt, width = 34, height = 30, fontSize = 13,
                textColor = TEXT, backgroundColor = { 62, 66, 84, 230 },
                hoverBackgroundColor = { 84, 90, 112, 240 },
                borderRadius = 6,
                onClick = function() step(d) end,
            }
        end
        return UI.Panel {
            width = "100%", height = 38, flexDirection = "row", alignItems = "center", gap = 6,
            children = {
                UI.Label { text = "地图包", fontSize = 12, flexGrow = 1, fontColor = TEXT_DIM },
                arrow("<<", -1),
                valueLabel,
                arrow(">>", 1),
            },
        }
    end

    -- 行：势力数量（显示 档位 + 具体国数）
    local factionRow = cycleRow("势力数量", FACTION_OPTS,
        function() return params.factions end,
        function(v) params.factions = v; params.factionCount = FACTION_COUNTS[v] end)

    -- 行：种子（输入框 + 随机按钮）
    local seedField = UI.TextField {
        width = 120, height = 32, value = params.seed,
        onChange = function(self, value)
            params.seed = value
        end,
    }
    local seedRow = UI.Panel {
        width = "100%", height = 38, flexDirection = "row", alignItems = "center", gap = 6,
        children = {
            UI.Label { text = "随机种子", fontSize = 12, flexGrow = 1, fontColor = TEXT_DIM },
            seedField,
            UI.Button {
                text = "随机", width = 56, height = 30, fontSize = 12,
                textColor = TEXT, backgroundColor = { 62, 66, 84, 230 },
                hoverBackgroundColor = { 84, 90, 112, 240 },
                borderRadius = 6,
                onClick = function()
                    params.seed = tostring(math.random(1000, 9999))
                    seedField:SetText(params.seed)
                end,
            },
        },
    }

    local genBtn = UI.Button {
        text = "生成新世界", width = "100%", height = 44, fontSize = 15,
        fontFamily = "gufeng", fontWeight = "bold", textColor = { 250, 234, 214, 255 },
        backgroundColor = { 146, 58, 40, 230 },
        hoverBackgroundColor = { 176, 70, 48, 240 },
        pressedBackgroundColor = { 120, 44, 32, 240 },
        borderRadius = 8,
        onClick = function()
            local p = {
                pack = params.pack,
                size = params.size,
                provinces = params.provinces,
                factions = params.factions,
                factionCount = params.factionCount,
                seed = tonumber(params.seed) or params.seed,
            }
            close()
            if opts.onApply then opts.onApply(p) end
        end,
    }

    local closeBtn = UI.Button {
        text = "×", width = 30, height = 30, fontSize = 16,
        textColor = TEXT, backgroundColor = { 0, 0, 0, 0 },
        hoverBackgroundColor = { 90, 50, 45, 200 },
        borderRadius = 6,
        onClick = function() close() end,
    }

    local panel = UI.Panel {
        width = 430,
        backgroundColor = PANEL_BG,
        borderRadius = 12, borderWidth = 1, borderColor = BORDER,
        padding = 14, gap = 8,
        children = {
            UI.Panel {
                flexDirection = "row", alignItems = "center", width = "100%",
                children = {
                    UI.Label { text = "世界生成", fontSize = 20, flexGrow = 1,
                               fontFamily = "gufeng", fontWeight = "bold", fontColor = GOLD },
                    closeBtn,
                },
            },
            UI.Divider { color = { 110, 82, 50, 160 }, thickness = 1 },
            packRow(),
            cycleRow("尺寸", SIZE_OPTS,
                function() return params.size end,
                function(v) params.size = v end),
            cycleRow("省数量", PROV_OPTS,
                function() return params.provinces end,
                function(v) params.provinces = v end),
            factionRow,
            seedRow,
            UI.Label {
                text = "「生成新世界」会清空当前剧本：按邻接关系随机建国并划分全部领土（之后仍可手动编辑）。",
                fontSize = 10, width = "100%", whiteSpace = "normal", fontColor = TEXT_DIM,
            },
            genBtn,
        },
    }

    local overlay = UI.Panel {
        id = "worldGenOverlay",
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 150 },
        alignItems = "center", justifyContent = "center",
        pointerEvents = "auto",
        children = { panel },
    }
    root:AddChild(overlay)
    current = overlay
end

return WorldGenPanel

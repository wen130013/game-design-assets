-- ============================================================================
-- WarPartiesPanel — 参战方详情弹窗（2026-09-18 用户口径 · 第二版）
--
--   入口：底部战争面板两端的旗子 —— **点哪边只看哪边**：
--       点左旗 → 我方阵营（将来含盟友）；点右旗 → 敌方阵营。
--   版式：屏幕正中间、**宽框**；其余画面变暗遮住；挂在 parent 最后 = 最上层。
--   表格：一行表头（兵力 / 投入总数 / 阵亡 / 击杀），每国一行、数字对齐，
--         **不用点开**，全部一眼看完（"横平竖直"）。
--
--   数据：war.stats = { [国ID] = { lost, killed, side = "a"|"d" } }
--         （MilitarySystem 每天结算时记账；side 决定它归左旗还是右旗）
--         + faction.armySize（现有兵力）
--   注：目前战争是双边 → 每侧只有主国一行；将来联盟参战，同侧多国自动排下来。
-- ============================================================================

local UI = require("urhox-libs/UI")
local Emblem = require("ui.Emblem")
local WarSystem = require("systems.WarSystem")

local WarPartiesPanel = {}

---@type table|nil
local panel_ = nil

-- 表格列（顺序 = 从左到右；列宽固定，数字才会"横平竖直"对齐）
local COLS = {
    { label = "兵力",     width = 92 },
    { label = "投入总数", width = 104 },
    { label = "阵亡",     width = 92 },
    { label = "击杀",     width = 92 },
}
local NAME_W = 190        -- 最左：旗 + 国名 一列的宽度

--- 关闭弹窗
function WarPartiesPanel.Close()
    if panel_ then
        panel_:Hide()
        panel_ = nil
    end
end

--- 是否正在显示
---@return boolean
function WarPartiesPanel.IsOpen()
    return panel_ ~= nil and panel_:IsVisible() or false
end

--- 打开参战方弹窗（只看一侧）
---@param gameState table
---@param enemyId number 战争对手 id（用来定位那场战争）
---@param parent Widget|nil 挂到哪个容器（一般传 GameUI 的 rootPanel）
---@param side string|nil "me"=左旗（我方阵营） / "enemy"=右旗（敌方阵营），默认 "me"
function WarPartiesPanel.Open(gameState, enemyId, parent, side)
    local pid = gameState.playerFactionId
    local war = WarSystem.findWar(gameState, pid, enemyId)
    if not war then return end
    if panel_ then
        panel_:Hide()
        panel_ = nil
    end

    -- 我方站战争哪一边 → 推出现在要看哪一边
    local mySide = (war.aId == pid) and "a" or "d"
    local wantSide
    if side == "enemy" then
        wantSide = (mySide == "a") and "d" or "a"
    else
        wantSide = mySide
    end

    -- 本阵营国家：主国 + 同侧的其它国家（将来联盟参战时自动多行）
    local ids, seen = {}, {}
    local function addId(id)
        if id and not seen[id] and gameState.factions[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    addId((wantSide == "a") and war.aId or war.dId)
    for fid, st in pairs(war.stats or {}) do
        if st.side == wantSide then addId(fid) end
    end

    --- 数值格（固定列宽 + 居中 = 表格对齐）
    local function numCell(width, text, color)
        return UI.Panel {
            width = width, alignItems = "center", pointerEvents = "none",
            children = {
                UI.Label { text = text, fontSize = 15, fontWeight = "bold",
                    fontColor = color, pointerEvents = "none" },
            },
        }
    end

    --- 表头格（同列宽同位置）
    local function headCell(width, text)
        return UI.Panel {
            width = width, alignItems = "center", pointerEvents = "none",
            children = {
                UI.Label { text = text, fontSize = 13, fontColor = { 185, 175, 150, 235 },
                    pointerEvents = "none" },
            },
        }
    end

    -- 表头行
    local headCells = { UI.Panel { width = NAME_W, pointerEvents = "none" } }
    for _, c in ipairs(COLS) do
        headCells[#headCells + 1] = headCell(c.width, c.label)
    end

    local rows = {
        UI.Panel {
            flexDirection = "row", width = "100%", alignItems = "center",
            paddingBottom = 6, pointerEvents = "none",
            children = headCells,
        },
    }

    -- 每个国家一行（旗 + 国名 ｜ 兵力 投入总数 阵亡 击杀）
    for _, fid in ipairs(ids) do
        local f = gameState.factions[fid]
        local st = (war.stats or {})[fid] or {}
        local now = math.floor(f.armySize or 0)
        local lost = math.floor(st.lost or 0)
        local killed = math.floor(st.killed or 0)
        local total = now + lost          -- 投入总数 = 现有 + 阵亡

        rows[#rows + 1] = UI.Panel {
            flexDirection = "row", width = "100%", alignItems = "center",
            paddingVertical = 7, paddingHorizontal = 8,
            backgroundColor = { 30, 34, 44, 230 },
            borderRadius = 6, borderWidth = 1, borderColor = { 70, 66, 58, 160 },
            pointerEvents = "none",
            children = {
                -- 最左：旗 + 国名
                UI.Panel {
                    width = NAME_W, flexDirection = "row", alignItems = "center", gap = 10,
                    pointerEvents = "none",
                    children = {
                        Emblem.MakeCloth(f, "war", 30),
                        UI.Label { text = f.name or "?", fontSize = 15, fontWeight = "bold",
                            fontColor = { 240, 225, 190, 245 }, pointerEvents = "none" },
                    },
                },
                numCell(COLS[1].width, tostring(now),    { 150, 220, 160, 245 }),
                numCell(COLS[2].width, tostring(total),  { 235, 225, 195, 240 }),
                numCell(COLS[3].width, tostring(lost),   { 235, 140, 130, 245 }),
                numCell(COLS[4].width, tostring(killed), { 235, 200, 120, 245 }),
            },
        }
    end

    local me = gameState.factions[war.aId]
    local them = gameState.factions[war.dId]
    local sideName = (side == "enemy") and "敌方" or "我方"
    local title = string.format("参战方 · %s　　%s · %s 之战", sideName,
        (me and me.name) or "?", (them and them.name) or "?")

    local overlay = UI.Panel {
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 130 },          -- 遮罩：其余画面变暗
        justifyContent = "center", alignItems = "center",   -- 居中
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 760, gap = 10, padding = 16,      -- ★ 宽框（用户："框放得更大"）
                backgroundColor = { 20, 24, 34, 245 },
                borderRadius = 10, borderWidth = 1, borderColor = { 170, 130, 70, 220 },
                children = {
                    -- 标题行 + 右上角关闭
                    UI.Panel {
                        width = "100%", flexDirection = "row", alignItems = "center", gap = 10,
                        children = {
                            UI.Label {
                                text = title, fontSize = 17, fontWeight = "bold",
                                fontColor = { 240, 220, 150, 255 }, flexGrow = 1,
                            },
                            UI.Button {
                                text = "X", fontSize = 15, width = 34, height = 30,
                                backgroundColor = { 70, 42, 42, 235 }, borderRadius = 6,
                                textColor = { 235, 215, 205, 240 },
                                onClick = function() WarPartiesPanel.Close() end,
                            },
                        },
                    },
                    -- 表格（表头 + 各国行）
                    UI.Panel { width = "100%", gap = 6, children = rows },
                },
            },
        },
    }

    if parent then parent:AddChild(overlay) end
    panel_ = overlay
    print(string.format("[WarParties] 打开参战方弹窗：side=%s（%d 国，战争 %s vs %s）",
        tostring(side), #ids, tostring(war.aId), tostring(war.dId)))
end

return WarPartiesPanel

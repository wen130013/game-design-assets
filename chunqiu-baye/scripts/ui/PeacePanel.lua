-- ============================================================================
-- PeacePanel — 和谈面板（2026-09-17 · 照 EU4 / CK3 的版式与规则重做）
--
-- 版式（CK3）：顶部战争分数条；左边"我要的"条款清单（每项标点数）；右边对方
--   接受度 + 理由明细（EU4 的"每个分 +1 理由、每点成本 −1 理由"）；底部三按钮
--   「认输 / 无条件停战 / 提出条款」。
--
-- 定价：赔款 / 要粮草 = 按对方国库比例折算的固定点数；解散军队 = 30；割地已由
--   "占领即吞并"实现，所以不再单列。
-- 接受：理由合计 ≥ 0 才签得成（战争分越高能提的越多）。
-- ============================================================================

local UI = require("urhox-libs/UI")
local Emblem = require("ui.Emblem")
local WarSystem = require("systems.WarSystem")

local PeacePanel = {}

---@type table|nil
local panel_ = nil
---@type table<string, boolean>
local picked_ = {}

-- 条款定义：id / 名字 / 点数 / 说明
local TERMS = {
    { id = "gold",   name = "赔款",       cost = 25, desc = "取对方国库三成（封顶 300）" },
    { id = "food",   name = "索要粮草",   cost = 20, desc = "取对方粮草三成（封顶 300）" },
    { id = "disband", name = "解散对方军队", cost = 30, desc = "对方兵力减半" },
    -- 占位（点了不生效，等对应系统接上）
    { id = "vassal", name = "附庸",       cost = 60, desc = "让对方成为我的附属国（待接）", stub = true },
    { id = "tech",   name = "索要科技",   cost = 35, desc = "对方越先进越贵（待接）", stub = true },
    { id = "kill",   name = "处死对方官员", cost = 10, desc = "指定一个人（待接）", stub = true },
}

local function selectedCost()
    local c = 0
    for _, t in ipairs(TERMS) do
        if picked_[t.id] and not t.stub then c = c + t.cost end
    end
    return c
end

function PeacePanel.Close()
    if panel_ then
        panel_:Hide()
        panel_ = nil
    end
end

--- 打开和谈面板
---@param gameState table
---@param enemyId number
---@param parent Widget|nil 挂到哪个容器（一般传 GameUI 的 rootPanel）
---@param onDone function|nil 签约/停战后回调（刷新战争列表）
function PeacePanel.Open(gameState, enemyId, parent, onDone)
    local pid = gameState.playerFactionId
    local war = WarSystem.findWar(gameState, pid, enemyId)
    if not war then return end
    local me = gameState.factions[pid]
    local enemy = gameState.factions[enemyId]
    if not me or not enemy then return end

    picked_ = {}
    local myScore = math.floor(WarSystem.getScore(gameState, war, pid))
    local eScore = math.floor(WarSystem.getScore(gameState, war, enemyId))

    local overlay, body
    local function rebuild()
        if body then body:ClearChildren() end
        local cost = selectedCost()
        -- EU4 式理由：每个战争分 +1，每点条款成本 −1
        local reasons = myScore - cost
        local ok = reasons >= 0 and cost > 0

        local rows = {}
        for _, t in ipairs(TERMS) do
            local on = picked_[t.id] == true
            rows[#rows + 1] = UI.Button {
                text = string.format("%s  %s   %d 点%s", on and "[X]" or "[  ]", t.name, t.cost,
                    t.stub and "（待接）" or ""),
                fontSize = 13,
                width = "100%",
                textColor = on and { 255, 226, 150, 255 } or { 216, 210, 196, 235 },
                backgroundColor = on and { 62, 50, 30, 235 } or { 34, 38, 48, 225 },
                borderWidth = 1,
                borderColor = on and { 190, 150, 80, 220 } or { 90, 84, 72, 170 },
                borderRadius = 6,
                paddingHorizontal = 8,
                onClick = function()
                    if t.stub then
                        if gameState.addMessage then
                            gameState.addMessage("「" .. t.name .. "」还没接上，先占位", "system", true)
                        end
                    else
                        picked_[t.id] = not on
                        rebuild()
                    end
                end,
            }
        end

        body:AddChild(UI.Panel {
            width = "100%", flexDirection = "row", gap = 12, alignItems = "flex-start",
            children = {
                -- 左：条款清单
                UI.Panel { flexGrow = 1, flexBasis = 0, gap = 5, children = rows },
                -- 右：对方 + 接受度 + 理由
                UI.Panel {
                    width = 200, gap = 6, alignItems = "center",
                    children = {
                        Emblem.MakeCloth(enemy, "war", 64),
                        UI.Label { text = "接受度", fontSize = 12, fontColor = { 200, 195, 180, 235 } },
                        UI.Label {
                            text = (cost == 0) and "未选择" or (ok and "同意" or "拒绝"),
                            fontSize = 18, fontWeight = "bold",
                            fontColor = (cost == 0) and { 200, 195, 180, 235 }
                                or (ok and { 110, 245, 130, 255 } or { 255, 90, 80, 255 }),
                        },
                        UI.Label {
                            text = string.format("战争分 +%d\n条款成本 −%d\n合计 %+d",
                                myScore, cost, reasons),
                            fontSize = 12, fontColor = { 205, 200, 186, 235 },
                            whiteSpace = "normal", textAlign = "center",
                        },
                    },
                },
            },
        })

        -- 底部：三按钮（CK3 版式）
        body:AddChild(UI.Panel {
            width = "100%", flexDirection = "row", gap = 10, justifyContent = "center",
            children = {
                UI.Button {
                    text = "认输", fontSize = 15, height = 44, width = 120,
                    backgroundColor = { 84, 42, 42, 235 }, borderRadius = 6,
                    onClick = function()
                        local pay = math.min(300, math.floor((enemy.gold or 0) * 0.3))
                        enemy.gold = (enemy.gold or 0) - pay
                        me.gold = (me.gold or 0) + pay
                        WarSystem.endWar(gameState, war)
                        if gameState.addMessage then
                            gameState.addMessage(string.format("向 %s 认输，赔款 %d 金", enemy.name, pay), "war", true)
                        end
                        PeacePanel.Close()
                        if onDone then onDone() end
                    end,
                },
                UI.Button {
                    text = "无条件停战", fontSize = 15, height = 44, width = 140,
                    backgroundColor = { 50, 58, 76, 235 }, borderRadius = 6,
                    onClick = function()
                        WarSystem.endWar(gameState, war)
                        if gameState.addMessage then
                            gameState.addMessage("与 " .. enemy.name .. " 无条件停战", "diplomacy", true)
                        end
                        PeacePanel.Close()
                        if onDone then onDone() end
                    end,
                },
                UI.Button {
                    text = "提出条款", fontSize = 15, height = 44, width = 140,
                    backgroundColor = ok and { 60, 96, 58, 235 } or { 60, 60, 64, 200 },
                    borderRadius = 6,
                    onClick = function()
                        if not ok then
                            if gameState.addMessage then
                                gameState.addMessage("对方不同意：战争分不够抵条款", "war", true)
                            end
                            return
                        end
                        -- 生效：赔款 / 粮草 / 解散军队
                        if picked_["gold"] then
                            local v = math.min(300, math.floor((enemy.gold or 0) * 0.3))
                            enemy.gold = (enemy.gold or 0) - v
                            me.gold = (me.gold or 0) + v
                        end
                        if picked_["food"] then
                            local v = math.min(300, math.floor((enemy.food or 0) * 0.3))
                            enemy.food = (enemy.food or 0) - v
                            me.food = (me.food or 0) + v
                        end
                        if picked_["disband"] then
                            enemy.armySize = math.floor((enemy.armySize or 0) * 0.5)
                        end
                        WarSystem.endWar(gameState, war)
                        if gameState.addMessage then
                            gameState.addMessage("与 " .. enemy.name .. " 达成和约（用 " .. cost .. " 点战争分）",
                                "diplomacy", true)
                        end
                        PeacePanel.Close()
                        if onDone then onDone() end
                    end,
                },
            },
        })
    end

    overlay = UI.Panel {
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 120 },
        justifyContent = "center", alignItems = "center",
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 620, gap = 10, padding = 14,
                backgroundColor = { 20, 24, 34, 245 },
                borderRadius = 10, borderWidth = 1, borderColor = { 170, 130, 70, 220 },
                children = {
                    -- 标题行 + **右上角关闭**（2026-09-18 用户："这个关闭放到右上角"；
                    --   原来挂在下面那行提示的右边，位置不显眼也不合惯例）
                    UI.Panel {
                        width = "100%", flexDirection = "row", alignItems = "center", gap = 10,
                        children = {
                            UI.Label {
                                text = string.format("对 %s 的和谈　　战争分数 %d%%", enemy.name, myScore),
                                fontSize = 18, fontWeight = "bold", fontColor = { 240, 220, 150, 255 },
                                flexGrow = 1,          -- 标题占满，把 X 顶到最右
                            },
                            UI.Button {
                                text = "X", fontSize = 15, width = 34, height = 30,
                                backgroundColor = { 70, 42, 42, 235 }, borderRadius = 6,
                                textColor = { 235, 215, 205, 240 },
                                onClick = function() PeacePanel.Close() end,
                            },
                        },
                    },
                    UI.ProgressBar {
                        value = myScore, max = 100, height = 12, width = "100%",
                        fillColor = { 110, 200, 120, 255 },
                    },
                    UI.Label { text = "接受度看右边的理由：战争分越高、要价越少，越容易签",
                        fontSize = 12, fontColor = { 190, 185, 170, 220 } },
                    UI.Panel { width = "100%" },   -- body 占位
                },
            },
        },
    }
    -- body = 上面那个占位 Panel
    local card = overlay.children[1]
    body = card.children[4]

    rebuild()
    if parent then parent:AddChild(overlay) end
    panel_ = overlay
end

return PeacePanel

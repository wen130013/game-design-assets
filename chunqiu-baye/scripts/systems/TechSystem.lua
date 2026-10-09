-- ============================================================================
-- 春秋霸业 - 科技系统（2026-09-16 初版 · 用户拍板"开始弄科技"）
--   数据：data/Techs.lua（6 类 × 10 条 · 纯正面 · 普通版无触类旁通）
--   机制：同时研究**一项** → 每月推进 1 个月 → 走满 → 完成 → 落效果
--   效果：走**修正器管道**（函数式规则 —— 按 ctx.faction 判断"该势力是否研究过"，
--          所以同一个键上可以叠 60 条科技规则而互不串台）
-- ============================================================================

local Techs = require("data.Techs")
local Modifiers = require("systems.Modifiers")
local Resources = require("data.Resources")

local TechSystem = {}

--- 每月推进的月数（以后可加"研究速度"加成）
TechSystem.MONTHS_PER_TICK = 1
--- AI 每月开新研究的概率（没在研时）
TechSystem.AI_START_CHANCE = 0.25
--- 开始研究要花金钱 = def.cost（在 data/Techs.lua 每条上）

-- ---------------------------------------------------------------------------
-- 管道注册：给每条科技的每个效果挂一条"函数式规则"
--   没研究该科技的势力 → 返回中性值（mul 0 / scale 1 / flat 0）
--   幂等：可重复调用（先按 source 前缀清旧、再重注册）——新游戏/读档后调一次
-- ---------------------------------------------------------------------------
function TechSystem.ensureRegistered()
    local rules = Modifiers.rules_ or {}
    for i = #rules, 1, -1 do
        local r = rules[i]
        if type(r.source) == "string" and r.source:find("^tech:") then
            table.remove(rules, i)
        end
    end
    local count = 0
    for _, def in ipairs(Techs.all()) do
        for ei, e in ipairs(def.effects or {}) do
            local tid = def.id
            local val = e.value
            local op = e.op or "mul"
            Modifiers.rule {
                scope = "faction", key = e.key, op = op,
                source = "tech:" .. tid .. ":" .. ei,
                value = function(_, ctx)
                    local f = ctx and ctx.faction
                    if f and f.techs and f.techs[tid] then
                        return val
                    end
                    return (op == "scale") and 1.0 or 0
                end,
            }
            count = count + 1
        end
    end
    print(string.format("[Tech] 管道注册完成：%d 条科技规则", count))
end

-- ---------------------------------------------------------------------------
-- 查询
-- ---------------------------------------------------------------------------
---@param f table 势力
---@param id string
---@return boolean
function TechSystem.isDone(f, id)
    return (f and f.techs and f.techs[id]) == true
end

--- 在研状态（nil = 没在研）
---@return table|nil { id, monthsLeft, total }
function TechSystem.getResearch(f)
    return f and f.research or nil
end

--- 前置（**树形**：读 data/Techs.lua 的 PREREQ 表——**认真排的科技演进关系**，
---   不是按表顺序凑的；2026-09-16 用户："你确定他们的先后关系是这个样子吗"）
---@param def table 科技定义
---@return table|nil 前置科技定义（nil = 无前置/根）
function TechSystem.prereqOf(def)
    local preId = Techs.prereqIdOf(def.id)
    return preId and Techs.get(preId) or nil
end

--- 层级（depth）：根 = 0，之后逐级 +1 —— 面板按这个分"列"（文明6 式横向树）
---@param def table
---@return number
function TechSystem.depthOf(def)
    local depth = 0
    local cur = def
    local guard = 0
    while cur and guard < 30 do
        guard = guard + 1
        local pre = TechSystem.prereqOf(cur)
        if not pre then break end
        depth = depth + 1
        cur = pre
    end
    return depth
end

--- 已研究数量
---@return number done, number total
function TechSystem.progress(f)
    local done = 0
    for _, def in ipairs(Techs.all()) do
        if TechSystem.isDone(f, def.id) then done = done + 1 end
    end
    return done, #Techs.list_
end

--- 能否开始研究
---@return boolean ok
---@return string|nil err
function TechSystem.canStart(gameState, f, id)
    local def = Techs.get(id)
    if not def then return false, "没有这项科技" end
    if TechSystem.isDone(f, id) then return false, "已研究完成" end
    local pre = TechSystem.prereqOf(def)
    if pre and not TechSystem.isDone(f, pre.id) then
        return false, "需先研究「" .. tostring(pre.name) .. "」"
    end
    if f.research then
        local cur = Techs.get(f.research.id)
        return false, "正在研究「" .. tostring(cur and cur.name or "?") .. "」"
    end
    local gold = Resources.get(f, "gold")
    if gold < (def.cost or 0) then
        return false, "金钱不足（需 " .. tostring(def.cost) .. "）"
    end
    return true, nil
end

--- 开始研究（扣钱 + 记在研）
---@return boolean ok
---@return string|nil err
function TechSystem.startTech(gameState, f, id)
    local ok, err = TechSystem.canStart(gameState, f, id)
    if not ok then return false, err end
    local def = Techs.get(id)
    Resources.add(f, "gold", -(def.cost or 0))
    f.research = { id = id, monthsLeft = def.months or 6, total = def.months or 6 }
    if gameState.addMessage and f.id == gameState.playerFactionId then
        gameState.addMessage("开始研究「" .. def.name .. "」（" .. tostring(def.months or 6) .. " 个月）",
            "system", false)
    end
    return true
end

--- 完成一项（落效果）
function TechSystem.complete(gameState, f, id)
    local def = Techs.get(id)
    if not def then return end
    f.techs = f.techs or {}
    f.techs[id] = true
    f.research = nil
    if gameState.addMessage and f.id == gameState.playerFactionId then
        gameState.addMessage("研究完成：「" .. def.name .. "」", "system", true)
    end
    print(string.format("[Tech] %s 研究完成「%s」", tostring(f.name), def.name))
end

-- ---------------------------------------------------------------------------
-- 每月推进
--   玩家：有在研 → 推进度；没在研 → 不动（等玩家选）
--   AI：没在研 → 按概率随机开一条（模仿玩家节奏，不刷屏）
-- ---------------------------------------------------------------------------
---@param gameState table
function TechSystem.monthlyTick(gameState)
    TechSystem.ensureRegistered()   -- 幂等（防 Modifiers.reset 之后失效）
    for _, f in pairs(gameState.factions or {}) do
        if f.alive ~= false then
            local r = f.research
            if r then
                r.monthsLeft = (r.monthsLeft or 0) - TechSystem.MONTHS_PER_TICK
                if r.monthsLeft <= 0 then
                    TechSystem.complete(gameState, f, r.id)
                end
            elseif f.id ~= gameState.playerFactionId and math.random() < TechSystem.AI_START_CHANCE then
                -- AI 随机挑一条"没研究过且负担得起"的
                local pool = {}
                for _, def in ipairs(Techs.all()) do
                    if not TechSystem.isDone(f, def.id)
                       and Resources.get(f, "gold") >= (def.cost or 0) then
                        pool[#pool + 1] = def
                    end
                end
                if #pool > 0 then
                    TechSystem.startTech(gameState, f, pool[math.random(#pool)].id)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 读档后重放（把"已研究"的科技效果重新挂满管道 —— 规则是运行时的，存档只存 f.techs）
-- ---------------------------------------------------------------------------
function TechSystem.reapplyAll(gameState)
    TechSystem.ensureRegistered()
    for _, f in pairs(gameState.factions or {}) do
        f.techs = f.techs or {}
    end
    print("[Tech] 读档重放完成（各势力已研究科技从存档恢复）")
end

return TechSystem

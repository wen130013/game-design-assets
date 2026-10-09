-- ============================================================================
-- EventSystem.lua — 事件系统（"插座"第四块的逻辑层 · 2026-09-13）
--
-- 干三件事：
--   1. 每月抽一次事件（按权重 + 条件；同一条 once 事件只发生一次）
--   2. 玩家选完 → 应用效果（**只走插座**：Resources / Modifiers / Hooks）
--   3. 临时修正（"征兵 +15%，持续 24 个月"）到期自动撤销
--
-- 边界（重要）：
--   * 本文件**不碰 UI**：抽到事件只放进 pending 队列，谁（GameUI）来显示都行
--   * 效果不直接改游戏内部状态，一律走 Resources.add / Modifiers.rule / Hooks.fire
--     → 模组后加的资源、加成，事件同样能用
--   * 只对**玩家势力**抽事件（AI 暂时不弹窗；以后要做 AI 事件再扩展）
-- ============================================================================

local Events = require("data.Events")
local Resources = require("data.Resources")
local Modifiers = require("systems.Modifiers")
local Hooks = require("systems.Hooks")
local TimeSystem = require("core.TimeSystem")
local Names = require("data.Names")

local EventSystem = {}

-- 事件会不会触发：每月一次，概率按"每月触发率"控制
--   2026-09-16 用户："事件太频繁了" → 0.35 → 0.12（约 8 个月一次）
EventSystem.MONTHLY_CHANCE = 0.12

---@type table[] 待玩家处理的事件**队列**（2026-09-16 起支持同时多个）
---   每项 = { def = 事件定义表, factionId = number }
EventSystem.pendingList_ = {}
---@type table<string, boolean> 已经发生过的一次性事件
EventSystem.firedOnce_ = {}

--- 初始化（新游戏 / 读档都要清一遍）
function EventSystem.reset()
    EventSystem.pendingList_ = {}
    EventSystem.firedOnce_ = {}
    -- 规则是运行时对象，不跨局；同国 id 的上一局修正也必须清掉。
    for i = #Modifiers.rules_, 1, -1 do
        local r = Modifiers.rules_[i]
        if type(r.source) == "string" and r.source:find("^event:") then
            table.remove(Modifiers.rules_, i)
        end
    end
end

-- ---------------------------------------------------------------------------
-- 每月：抽事件 + 到期修正
-- ---------------------------------------------------------------------------
---@param gameState table
function EventSystem.processMonthly(gameState)
    EventSystem.tickTempModifiers(gameState)

    -- 已有没处理完的事件 → 先不抽新的（不堆弹窗）
    if #EventSystem.pendingList_ > 0 then return end

    local fid = gameState and gameState.playerFactionId
    local f = fid and gameState.factions and gameState.factions[fid]
    if not f or f.alive == false then return end

    if math.random() > EventSystem.MONTHLY_CHANCE then return end

    local def = EventSystem.pick(gameState, f)
    if def then
        EventSystem.pendingList_[#EventSystem.pendingList_ + 1] = { def = def, factionId = fid }
        print(string.format("[Event] 触发事件「%s」（%s）", def.title, def.id))
        -- 也给脚本钩子一个口子（模组可以对"出了事件"做反应）
        Hooks.fire("event_fired", { gameState = gameState, eventId = def.id, factionId = fid })
    end
end

-- ---------------------------------------------------------------------------
-- 生成时填占位符（2026-09-16）
--   有些事件的内容不能写死：提议人得**随机取一个**（用户："并不是用一些固定的名字，
--   而是随便来一个，而且他可能是什么官职也可能不是"），"变法之议"还得随机挑一条
--   玩家**还没听过**的变法。占位符写在 data/Events.lua 的 text / choices 里：
--     {who} {name} {title} —— 随机提议人（含身份）
--     {reform} {desc}      —— draft="reform" 时随机挑中的变法
-- ---------------------------------------------------------------------------

--- 取玩家"还没听过"的变法池（draft="reform" 的事件据此）
---@param f table|nil
---@return table[]
function EventSystem.unknownReforms(f)
    local PolicySystem = require("systems.PolicySystem")
    local pool = {}
    if not f then return pool end
    for _, r in ipairs(PolicySystem.REFORMS) do
        if not PolicySystem.isReformKnown(f, r.id) then pool[#pool + 1] = r end
    end
    return pool
end

--- 这条事件现在能不能生成（抽池子时先问一遍，免得抽中了却没内容）
---@param def table
---@param f table|nil
---@return boolean
function EventSystem.canDraft(def, f)
    if def.draft == "reform" then
        return #EventSystem.unknownReforms(f) > 0
    end
    return true
end

--- 把定义表"实例化"：填掉占位符，返回一份**拷贝**（不改原表 —— 原表是所有存档共用的）
---@param def table
---@param f table|nil 玩家势力
---@return table|nil nil = 内容挑不出来（如变法已全部知道），跳过这条
function EventSystem.materialize(def, f)
    local hasPlaceholder = (type(def.text) == "string" and def.text:find("{", 1, true))
        or def.draft ~= nil or def.speaker ~= nil
    if not hasPlaceholder then return def end   -- 静态事件：原样返回，零开销

    local subs = {}
    if def.speaker == "random" then
        local p = Names.randomPerson()
        subs.who, subs.name, subs.title = p.who, p.name, p.title
    else
        subs.who, subs.name, subs.title = "", "", ""
    end
    if def.draft == "reform" then
        local pool = EventSystem.unknownReforms(f)
        if #pool == 0 then return nil end
        local r = pool[math.random(#pool)]
        subs.reform, subs.desc = r.id, (r.desc or "")
    else
        subs.reform, subs.desc = "", ""
    end

    local function sub(s)
        if type(s) ~= "string" then return s end
        return (s:gsub("{(%a+)}", function(k) return subs[k] or ("{" .. k .. "}") end))
    end
    ---@param src table
    ---@return table
    local function shallow(src)
        local t = {}
        for k, v in pairs(src) do t[k] = v end
        return t
    end

    local d = shallow(def)
    d.text = sub(def.text)
    if def.choices then
        local cs = {}
        for i, c in ipairs(def.choices) do
            local c2 = shallow(c)
            c2.text = sub(c.text)
            if c.effects then
                local es = {}
                for j, e in ipairs(c.effects) do
                    local e2 = shallow(e)
                    e2.reform = sub(e2.reform)
                    e2.msg = sub(e2.msg)
                    es[j] = e2
                end
                c2.effects = es
            end
            cs[i] = c2
        end
        d.choices = cs
    end
    d.speakerName = subs.who   -- 给 UI/存档留个"谁提的"（空串 = 无提议人）
    return d
end

--- 按权重抽一条可用事件
---@param gameState table
---@param f table 玩家势力
---@return table|nil
function EventSystem.pick(gameState, f)
    local ts = TimeSystem.getState and TimeSystem.getState() or nil
    local year = (gameState.time and gameState.time.year) or (ts and ts.year) or nil
    local pool, total = {}, 0
    for _, def in ipairs(Events.defs) do
        local ok = true
        if def.once and EventSystem.firedOnce_[def.id] then ok = false end
        if ok and def.minYear and year and year < def.minYear then ok = false end
        if ok and def.maxYear and year and year > def.maxYear then ok = false end
        if ok and def.cond then
            local good, res = pcall(def.cond, gameState, f)
            ok = good and res and true or false
        end
        -- 内容能不能生成（如"变法之议"要还有没听过的变法）—— 挑不出就整条跳过
        if ok and not EventSystem.canDraft(def, f) then ok = false end
        if ok and (def.weight or 0) > 0 then
            pool[#pool + 1] = def
            total = total + def.weight
        end
    end
    if total <= 0 then return nil end

    local r = math.random() * total
    for _, def in ipairs(pool) do
        r = r - def.weight
        if r <= 0 then return EventSystem.materialize(def, f) end
    end
    return EventSystem.materialize(pool[#pool], f)
end

-- ---------------------------------------------------------------------------
-- 玩家选择 → 应用效果
-- ---------------------------------------------------------------------------
---@param gameState table
---@param choiceIndex number 第几个选项（1 起）
---@return boolean ok
---@return string|nil err
---@param eventIndex number|nil 第几个待处理事件（默认队首；多事件时由 UI 指定，2026-09-16）
function EventSystem.choose(gameState, choiceIndex, eventIndex)
    local ei = eventIndex or 1
    local p = EventSystem.pendingList_[ei]
    if not p then return false, "当前没有待处理的事件" end
    local def = p.def
    local choice = def.choices and def.choices[choiceIndex]
    if not choice then return false, "选项不存在" end

    local f = gameState.factions[p.factionId]
    if f then
        EventSystem.applyEffects(gameState, f, choice.effects)
    end
    if def.once then EventSystem.firedOnce_[def.id] = true end

    gameState.events = gameState.events or {}
    gameState.events[#gameState.events + 1] = {
        type = "event_choice", eventId = def.id, choice = choiceIndex, factionId = p.factionId,
    }

    table.remove(EventSystem.pendingList_, ei)
    return true
end

--- 应用一组效果（走插座）
---@param gameState table
---@param f table 势力
---@param effects table[]|nil
function EventSystem.applyEffects(gameState, f, effects)
    for _, e in ipairs(effects or {}) do
        if e.res and e.add then
            Resources.add(f, e.res, e.add)
        elseif e.mod then
            EventSystem.addTempModifier(gameState, f, e.mod)
        elseif e.reform then
            -- 2026-09-16：事件**解锁一个变法**（"臣上书主张变法" → 玩家"准" → 列入变法案）
            require("systems.PolicySystem").unlockReform(gameState, f.id, e.reform)
        elseif e.hook then
            Hooks.fire(e.hook, { gameState = gameState, faction = f, factionId = f.id })
        end
        if e.msg and gameState.addMessage then
            gameState.addMessage(e.msg, "system")
        end
    end
end

-- ---------------------------------------------------------------------------
-- 临时修正（"持续 N 个月"的加成/减益）
--   source 只用于去重/撤销；国家筛选必须在 value(gameState, ctx) 内完成。
-- ---------------------------------------------------------------------------
---@param f table 势力
---@param rec table { source, key, op, value }
local function registerTempModifier(f, rec)
    local fid, value = f.id, rec.value
    local op = rec.op or "mul"
    Modifiers.rule{
        scope = "faction", key = rec.key, op = op, source = rec.source,
        value = function(_, ctx)
            local faction = ctx and ctx.faction
            if faction and faction.id == fid then
                -- 新局复用同国 id 时旧闭包可能仍在管道里；没有有效记录就不生效。
                for _, active in ipairs(faction.tempModifiers or {}) do
                    if active.source == rec.source and (active.monthsLeft or 0) > 0 then
                        return value
                    end
                end
            end
            return op == "scale" and 1.0 or 0
        end,
    }
end

---@param gameState table
---@param f table 势力
---@param m table { key, op, value, months }
function EventSystem.addTempModifier(gameState, f, m)
    local months = m.months or 12
    local source = string.format("event:%s:%d", tostring(m.key), f.id)
    f.tempModifiers = f.tempModifiers or {}
    -- 同一来源只保留一条（重复触发就续期），同时更新重建规则所用的数值。
    for _, rec in ipairs(f.tempModifiers) do
        if rec.source == source then
            rec.monthsLeft = months
            rec.key, rec.op, rec.value = m.key, m.op or "mul", m.value
            registerTempModifier(f, rec)
            return
        end
    end
    local rec = { source = source, monthsLeft = months,
        key = m.key, op = m.op or "mul", value = m.value }
    f.tempModifiers[#f.tempModifiers + 1] = rec
    registerTempModifier(f, rec)
    print(string.format("[Event] 临时修正 %s（%s %s，持续 %d 个月）",
        tostring(m.key), tostring(m.op or "mul"), tostring(m.value), months))
end

--- 每月递减；到期的从管道里撤掉
---@param gameState table
function EventSystem.tickTempModifiers(gameState)
    for _, f in pairs(gameState.factions or {}) do
        local list = f.tempModifiers
        if list then
            for i = #list, 1, -1 do
                local rec = list[i]
                rec.monthsLeft = (rec.monthsLeft or 0) - 1
                if rec.monthsLeft <= 0 then
                    Modifiers.unrule(rec.source)
                    table.remove(list, i)
                    print(string.format("[Event] 临时修正到期撤销：%s", tostring(rec.key)))
                else
                    -- 管道清空/旧运行时数字规则：从仍有效的记录重建，不重置剩余月数。
                    registerTempModifier(f, rec)
                end
            end
        end
    end
end

--- 当前待处理事件（取队首；多事件 UI 请用 getPendingList）
---@return table|nil { def = 事件定义表, factionId = number }
function EventSystem.getPending()
    return EventSystem.pendingList_[1]
end

--- 全部待处理事件（2026-09-16：支持多个同时挂着，UI 逐条显示）
---@return table[] 每项 { def = 事件定义表, factionId = number }
function EventSystem.getPendingList()
    return EventSystem.pendingList_
end

--- 直接塞一条待处理事件（不掷骰子）
--- 用途：沙盒/上帝面板"立刻触发某事件"；以及离屏测试钩子 SHOT_EVENT
---@param defId string 事件 id（见 data/Events.lua）
---@param factionId number|nil 默认玩家势力
---@param f table|nil 该势力对象（带占位符的事件要用它挑内容，如"变法之议"）
---@return boolean ok
function EventSystem.forcePending(defId, factionId, f)
    local def = Events.get(defId)
    if not def then return false end
    local inst = EventSystem.materialize(def, f)
    if not inst then return false end   -- 内容挑不出来（如变法已全部知道）
    EventSystem.pendingList_[#EventSystem.pendingList_ + 1] = { def = inst, factionId = factionId or nil }
    return true
end

--- 关掉队首事件（不选 = 当没发生；给"直接关闭"用）
function EventSystem.dismiss()
    table.remove(EventSystem.pendingList_, 1)
end

--- 全部关掉
function EventSystem.dismissAll()
    EventSystem.pendingList_ = {}
end

return EventSystem

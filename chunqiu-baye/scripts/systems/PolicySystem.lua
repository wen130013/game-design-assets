-- ============================================================================
-- 春秋霸业 - 政策系统
-- systems/PolicySystem.lua
--
-- 政策 = 文明6式卡槽 + 历史时代3/钢铁雄心4式实施进度 + 变法改革
--
--   A. 政策卡槽（3+1）：
--      economy/military/domestic 三槽 + wildcard 通配槽（可放任意类）
--      换卡需花费资源，进入"实施期"（HoI4 国策式进度条 + 剩余天数），
--      实施完成后生效替换旧卡
--   B. 变法改革（一次性大决策）：
--      永久效果 + 持续数月的稳定副作用（各变法持续时间不同）
--
-- 数据挂在 faction 上：
--   f.policies        = { economy=cardId, military=cardId, domestic=cardId, wildcard=cardId|nil }
--   f.policyProgress  = { slot, cardId, daysLeft, totalDays }  （nil=无实施中）
--   f.reforms         = { "商鞅变法", ... }                     已实行的变法
--   f.reformEffects   = { {id, monthsLeft, stability}, ... }    进行中的副作用
-- ============================================================================

local PolicySystem = {}

-- =========================================================================
-- 政策卡定义
-- =========================================================================
--- 每张卡：id/desc/效果字段/cost(金)/days(实施天数)
--- 效果字段：gold food military defense popGrowth stability diplo recruit
PolicySystem.CARDS = {
    economy = {
        { id = "重农", desc = "粮草产出 +15%",      food = 0.15, cost = 30, days = 90 },
        { id = "重商", desc = "金钱收入 +15%",      gold = 0.15, cost = 40, days = 90 },
        { id = "轻徭", desc = "人口增长 +20%",      popGrowth = 0.20, cost = 30, days = 60 },
    },
    military = {
        { id = "尚武", desc = "战斗力 +10%",        military = 0.10, cost = 40, days = 90 },
        { id = "强军", desc = "征兵上限 +20%",      recruit = 0.20,  cost = 30, days = 60 },
        { id = "固守", desc = "防御 +15%",          defense = 0.15,  cost = 30, days = 60 },
    },
    domestic = {
        { id = "仁政", desc = "稳定 +1/月",         stability = 1,   cost = 30, days = 60 },
        { id = "严法", desc = "战力 +8%，稳定 -1/月", military = 0.08, stability = -1, cost = 40, days = 90 },
        { id = "礼乐", desc = "外交改善 +1",        diplo = 1,       cost = 30, days = 60 },
    },
}

--- 槽位名（中文，UI 用）
PolicySystem.SLOT_NAMES = {
    economy   = "经济",
    military  = "军事",
    domestic  = "内政",
    wildcard  = "通配",
}

-- =========================================================================
-- 变法改革定义
-- =========================================================================
--- 每个变法：id/desc/效果字段/cost{gold,prestige}/penalty{months,stability}
PolicySystem.REFORMS = {
    {
        id = "商鞅变法", desc = "金钱 +20%，稳定长期受损",
        gold = 0.20,
        cost = { gold = 200, prestige = 50 },
        penalty = { months = 24, stability = -2 },
    },
    {
        id = "李悝变法", desc = "粮草 +25%，人口增长 +10%",
        food = 0.25, popGrowth = 0.10,
        cost = { gold = 150, prestige = 40 },
        penalty = { months = 12, stability = -1 },
    },
    {
        id = "胡服骑射", desc = "战力 +15%，征兵上限 +15%",
        military = 0.15, recruit = 0.15,
        cost = { gold = 150, prestige = 50 },
        penalty = { months = 12, stability = -1 },
    },
    {
        id = "废井田", desc = "金钱 +10%，粮草 +10%",
        gold = 0.10, food = 0.10,
        cost = { gold = 120 },
        penalty = { months = 8, stability = -1 },
    },
}

-- =========================================================================
-- 内部工具
-- =========================================================================

--- 势力是否已研究过某变法
---@param faction table
---@param reformId string
---@return boolean
local function hasReform(faction, reformId)
    if not faction.reforms then return false end
    for _, id in ipairs(faction.reforms) do
        if id == reformId then return true end
    end
    return false
end

--- 取势力当前生效的槽位卡表（含通配槽）
---@param faction table
---@return table cards {slot=cardTable}
local function activeCards(faction)
    local result = {}
    local policies = faction.policies or {}
    for slot, cardId in pairs(policies) do
        if cardId then
            local card = PolicySystem.findCard(slot, cardId)
            if card then
                result[slot] = card
            end
        end
    end
    return result
end

--- 取势力已实行的变法表
---@param faction table
---@return table reforms
local function activeReforms(faction)
    local result = {}
    local reforms = faction.reforms or {}
    for _, rid in ipairs(reforms) do
        for _, def in ipairs(PolicySystem.REFORMS) do
            if def.id == rid then
                result[#result + 1] = def
                break
            end
        end
    end
    return result
end

-- =========================================================================
-- 查询
-- =========================================================================

--- 按槽位和卡 id 查找政策卡定义
---@param slot string
---@param cardId string
---@return table|nil card
function PolicySystem.findCard(slot, cardId)
    local list = PolicySystem.CARDS[slot]
    if not list then
        -- 通配槽：从所有槽查找
        for _, cards in pairs(PolicySystem.CARDS) do
            for _, c in ipairs(cards) do
                if c.id == cardId then return c end
            end
        end
        return nil
    end
    for _, c in ipairs(list) do
        if c.id == cardId then return c end
    end
    return nil
end

--- 该槽位是否允许这张卡
---@param slot string
---@param cardId string
---@return boolean
function PolicySystem.cardAllowed(slot, cardId)
    if slot == "wildcard" then
        return PolicySystem.findCard(nil, cardId) ~= nil
    end
    local list = PolicySystem.CARDS[slot]
    if not list then return false end
    for _, c in ipairs(list) do
        if c.id == cardId then return true end
    end
    return false
end

--- 某槽位当前生效卡
---@param faction table
---@param slot string
---@return string|nil cardId
function PolicySystem.getActiveCard(faction, slot)
    local policies = faction.policies or {}
    return policies[slot]
end

--- 某势力实施中的政策进度
---@param faction table
---@return table|nil progress {slot, cardId, daysLeft, totalDays}
function PolicySystem.getProgress(faction)
    return faction.policyProgress or nil
end

--- 是否正在实施政策（任一场）
---@param faction table
---@return boolean
function PolicySystem.isImplementing(faction)
    return faction.policyProgress ~= nil
end

--- 能否开始实施该卡（资源是否足够）
---@param faction table
---@param card table
---@return boolean ok
---@return string|nil reason
function PolicySystem.canAfford(faction, card)
    local cost = card.cost or 0
    if (faction.gold or 0) < cost then
        return false, "金钱不足（需要 " .. cost .. "）"
    end
    return true
end

-- =========================================================================
-- 效果修正（供 Economy/Military/Diplomacy 挂钩）
-- =========================================================================

--- 金钱收入倍率修正（政策卡 + 变法）
---@param faction table
---@return number multiplier
function PolicySystem.getGoldModifier(faction)
    local mod = 1.0
    for _, card in pairs(activeCards(faction)) do
        if card.gold then mod = mod + card.gold end
    end
    for _, def in ipairs(activeReforms(faction)) do
        if def.gold then mod = mod + def.gold end
    end
    return mod
end

--- 粮草收入倍率修正
---@param faction table
---@return number multiplier
function PolicySystem.getFoodModifier(faction)
    local mod = 1.0
    for _, card in pairs(activeCards(faction)) do
        if card.food then mod = mod + card.food end
    end
    for _, def in ipairs(activeReforms(faction)) do
        if def.food then mod = mod + def.food end
    end
    return mod
end

--- 战斗力倍率修正（进攻）
---@param faction table
---@return number multiplier
function PolicySystem.getMilitaryModifier(faction)
    local mod = 1.0
    for _, card in pairs(activeCards(faction)) do
        if card.military then mod = mod + card.military end
    end
    for _, def in ipairs(activeReforms(faction)) do
        if def.military then mod = mod + def.military end
    end
    return mod
end

--- 防御倍率修正
---@param faction table
---@return number multiplier
function PolicySystem.getDefenseModifier(faction)
    local mod = 1.0
    for _, card in pairs(activeCards(faction)) do
        if card.defense then mod = mod + card.defense end
    end
    return mod
end

--- 人口增长加法修正
---@param faction table
---@return number additive
function PolicySystem.getPopGrowthModifier(faction)
    local mod = 0
    for _, card in pairs(activeCards(faction)) do
        if card.popGrowth then mod = mod + card.popGrowth end
    end
    for _, def in ipairs(activeReforms(faction)) do
        if def.popGrowth then mod = mod + def.popGrowth end
    end
    return mod
end

--- 征兵上限倍率修正
---@param faction table
---@return number multiplier
function PolicySystem.getRecruitModifier(faction)
    local mod = 1.0
    for _, card in pairs(activeCards(faction)) do
        if card.recruit then mod = mod + card.recruit end
    end
    for _, def in ipairs(activeReforms(faction)) do
        if def.recruit then mod = mod + def.recruit end
    end
    return mod
end

--- 每月稳定度修正（政策卡，不含变法副作用——副作用单独走 processMonthly）
---@param faction table
---@return number delta
function PolicySystem.getStabilityDelta(faction)
    local delta = 0
    for _, card in pairs(activeCards(faction)) do
        if card.stability then delta = delta + card.stability end
    end
    return delta
end

--- 外交修正（改善关系速度）
---@param faction table
---@return number delta
function PolicySystem.getDiploModifier(faction)
    local delta = 0
    for _, card in pairs(activeCards(faction)) do
        if card.diplo then delta = delta + card.diplo end
    end
    return delta
end

-- =========================================================================
-- 行动
-- =========================================================================

--- 开始实施一张政策卡（花费资源，进入进度期）
---@param gameState table
---@param factionId number
---@param slot string
---@param cardId string
---@return boolean ok
---@return string|nil reason
function PolicySystem.startPolicy(gameState, factionId, slot, cardId)
    local f = gameState.factions[factionId]
    if not f then return false, "势力不存在" end
    if f.alive == false then return false, "势力已灭亡" end

    local card = PolicySystem.findCard(slot, cardId)
    if not card then return false, "未知政策" end
    if not PolicySystem.cardAllowed(slot, cardId) then
        return false, "该卡不能放入此槽位"
    end

    -- 同槽已有实施中的进度（任一场实施中不允许开新）
    if f.policyProgress then
        return false, "已有政策实施中，请等待完成"
    end

    -- 资源校验
    local ok, reason = PolicySystem.canAfford(f, card)
    if not ok then return false, reason end

    -- 扣除资源
    f.gold = (f.gold or 0) - card.cost

    -- 设置实施进度（HoI4 国策式）
    f.policyProgress = {
        slot     = slot,
        cardId   = cardId,
        daysLeft = card.days,
        totalDays = card.days,
    }

    if gameState.addMessage then
        gameState.addMessage(
            "开始实施国策「" .. cardId .. "」，约 " .. card.days .. " 天完成", "system")
    end
    return true, nil
end

--- 每日推进实施进度（main.lua OnNewDay 调用）
---@param gameState table
function PolicySystem.processDaily(gameState)
    for fid, f in pairs(gameState.factions) do
        local prog = f.policyProgress
        if prog then
            prog.daysLeft = prog.daysLeft - 1
            if prog.daysLeft <= 0 then
                -- 完成：应用政策到槽位
                f.policies = f.policies or {}
                f.policies[prog.slot] = prog.cardId
                f.policyProgress = nil
                if gameState.addMessage then
                    gameState.addMessage(
                        "国策「" .. prog.cardId .. "」实施完成，开始生效", "system")
                end
            end
        end
    end
end

--- 激活变法（一次性大决策，永久效果 + 持续副作用）
---@param gameState table
---@param factionId number
---@param reformId string
---@return boolean ok
---@return string|nil reason
function PolicySystem.activateReform(gameState, factionId, reformId)
    local f = gameState.factions[factionId]
    if not f then return false, "势力不存在" end

    -- 找变法定义
    local def = nil
    for _, r in ipairs(PolicySystem.REFORMS) do
        if r.id == reformId then
            def = r
            break
        end
    end
    if not def then return false, "未知变法" end

    if hasReform(f, reformId) then
        return false, "该变法已实行"
    end

    -- 资源校验（金/威望）
    local cost = def.cost or {}
    if (f.gold or 0) < (cost.gold or 0) then
        return false, "金钱不足（需要 " .. (cost.gold or 0) .. "）"
    end
    if (f.prestige or 0) < (cost.prestige or 0) then
        return false, "威望不足（需要 " .. (cost.prestige or 0) .. "）"
    end

    -- 扣除资源
    f.gold = (f.gold or 0) - (cost.gold or 0)
    f.prestige = (f.prestige or 0) - (cost.prestige or 0)

    -- 记录变法
    f.reforms = f.reforms or {}
    f.reforms[#f.reforms + 1] = reformId

    -- 添加持续副作用（各变法持续时间不同）
    local penalty = def.penalty
    if penalty and penalty.months and penalty.stability then
        f.reformEffects = f.reformEffects or {}
        f.reformEffects[#f.reformEffects + 1] = {
            id          = reformId,
            monthsLeft  = penalty.months,
            stability   = penalty.stability,
        }
    end

    if gameState.addMessage then
        local msg = "实行变法「" .. reformId .. "」！"
        if penalty and penalty.months then
            msg = msg .. "（旧贵族不满，未来 " .. penalty.months
                .. " 个月稳定每月 " .. penalty.stability .. "）"
        end
        gameState.addMessage(msg, "system")
    end
    return true, nil
end

--- 每月处理：变法副作用扣稳定并倒计时（main.lua OnNewMonth 调用）
---@param gameState table
function PolicySystem.processMonthly(gameState)
    for fid, f in pairs(gameState.factions) do
        local effects = f.reformEffects
        if effects and #effects > 0 then
            local remaining = {}
            for _, e in ipairs(effects) do
                f.stability = math.max(-100, math.min(100,
                    (f.stability or 0) + e.stability))
                e.monthsLeft = e.monthsLeft - 1
                if e.monthsLeft > 0 then
                    remaining[#remaining + 1] = e
                end
            end
            f.reformEffects = remaining
        end
    end
end

--- 获取某势力变法实行状态（UI 用）
---@param faction table
---@param reformId string
---@return string "done"|"active"|"locked"
function PolicySystem.getReformState(faction, reformId)
    if hasReform(faction, reformId) then
        return "done"
    end
    -- 能否负担
    for _, r in ipairs(PolicySystem.REFORMS) do
        if r.id == reformId then
            local cost = r.cost or {}
            if (faction.gold or 0) >= (cost.gold or 0)
                and (faction.prestige or 0) >= (cost.prestige or 0) then
                return "active"
            end
            return "locked"
        end
    end
    return "locked"
end

return PolicySystem

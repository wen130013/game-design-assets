-- ============================================================================
-- 春秋霸业 - 外交系统
-- DiplomacySystem.lua
--
-- 负责：宣战/求和/改善关系/月度外交处理
-- AI 决策逻辑已移至 ai/AIManager.lua
-- 依赖：config.GameConfig, data.Factions, data.Provinces
-- ============================================================================

local GameConfig = require("config.GameConfig")
local Factions   = require("data.Factions")
local Provinces  = require("data.Provinces")
local WarSystem  = require("systems.WarSystem")
local LeaderSystem = require("systems.LeaderSystem")
local PolicySystem = require("systems.PolicySystem")
local MilitarySystem = require("systems.MilitarySystem")

local DiplomacySystem = {}

-- =========================================================================
-- 常量快捷引用
-- =========================================================================
local DIP  = GameConfig.Diplomacy
local AI   = GameConfig.AI

-- =========================================================================
-- 辅助工具
-- =========================================================================

--- 将关系值限制在 [MIN_RELATION, MAX_RELATION] 之间
---@param value number
---@return number
local function clampRelation(value)
    if value < DIP.MIN_RELATION then return DIP.MIN_RELATION end
    if value > DIP.MAX_RELATION then return DIP.MAX_RELATION end
    return value
end

--- 安全获取两国关系记录，若不存在则创建默认记录。
--- 使用与 GameState 相同的嵌套数字键结构: relations[lo][hi]
--- 为保持对称性，relations[hi][lo] 共享同一记录对象。
---@param gameState table
---@param id1 number
---@param id2 number
---@return table relation {value, atWar, peaceCooldown, improvingFrom}
local function getRelation(gameState, id1, id2)
    if not gameState.relations then
        gameState.relations = {}
    end
    local lo = math.min(id1, id2)
    local hi = math.max(id1, id2)

    -- Ensure the nested table for lo exists
    if not gameState.relations[lo] then
        gameState.relations[lo] = {}
    end

    local rel = gameState.relations[lo][hi]
    if not rel then
        -- Create a new record with all required fields
        rel = {
            value         = 0,
            atWar         = false,
            peaceCooldown = 0,
            improvingFrom = nil,  -- 哪方在花钱改善关系（nil=无）
        }
        gameState.relations[lo][hi] = rel
        -- Also install symmetrically so GameState.getRelation(hi, lo) sees it
        if not gameState.relations[hi] then
            gameState.relations[hi] = {}
        end
        gameState.relations[hi][lo] = rel
    end
    -- Note: improvingFrom may be nil on records created by GameState.init();
    -- this is fine since nil is the expected default ("no one improving").

    return rel
end

--- 向游戏日志追加一条消息（同步写入消息系统，玩家可在日志面板看到）
---@param gameState table
---@param msg string
local function addLog(gameState, msg)
    if not gameState.log then
        gameState.log = {}
    end
    local entry = {
        month = gameState.month or 0,
        year  = gameState.year or 0,
        text  = msg,
    }
    gameState.log[#gameState.log + 1] = entry
    if gameState.addMessage then
        gameState.addMessage(msg, "diplomacy")
    end
end

--- 获取势力名称（容错）
---@param factionId number
---@return string
local function factionName(factionId)
    local f = Factions.getById(factionId)
    return f and f.fullName or ("势力#" .. tostring(factionId))
end

--- 判断势力是否存活：拥有至少一个省份
---@param gameState table
---@param factionId number
---@return boolean
local function isFactionAlive(gameState, factionId)
    local f = gameState.factions[factionId]
    if not f then return false end
    if f.alive == false then return false end

    -- 如果 gameState 中有动态省份数据就用它，否则用 faction 自身的 provinces
    if gameState.factionProvinces and gameState.factionProvinces[factionId] then
        return #gameState.factionProvinces[factionId] > 0
    end
    return f.provinces and #f.provinces > 0
end

--- 计算势力的综合军事实力
--- 军力 = 兵力 + 人口/10 + 省份数 * 1000
---@param gameState table
---@param factionId number
---@return number strength
local function calcStrength(gameState, factionId)
    local f = gameState.factions[factionId]
    if not f then return 0 end

    local armySize = f.armySize or 0
    local population = 0
    local provinceCount = 0

    -- 使用动态省份数据（若存在），否则用 faction 自身的 provinces
    local provList = f.provinces
    if gameState.factionProvinces and gameState.factionProvinces[factionId] then
        provList = gameState.factionProvinces[factionId]
    end

    for _, pid in ipairs(provList) do
        local prov = Provinces.byId[pid]
        if prov then
            population = population + (prov.population or 0)
        end
        provinceCount = provinceCount + 1
    end

    return armySize + population / 10 + provinceCount * 1000
end

--- 获取势力的所有邻国ID列表（不重复）
---@param gameState table
---@param factionId number
---@return table neighborFactionIds
local function getNeighborFactions(gameState, factionId)
    local f = gameState.factions[factionId]
    if not f then return {} end

    local provList = f.provinces
    if gameState.factionProvinces and gameState.factionProvinces[factionId] then
        provList = gameState.factionProvinces[factionId]
    end

    local seen = {}
    local result = {}
    for _, pid in ipairs(provList) do
        local prov = Provinces.byId[pid]
        if prov and prov.neighbors then
            for _, nid in ipairs(prov.neighbors) do
                -- Use runtime province ownership from gameState when available
                local ownerFid
                if gameState.provinces and gameState.provinces[nid] then
                    ownerFid = gameState.provinces[nid].ownerId
                else
                    ownerFid = Factions.getFactionByProvince(nid)
                end
                if ownerFid and ownerFid ~= factionId and not seen[ownerFid] then
                    seen[ownerFid] = true
                    result[#result + 1] = ownerFid
                end
            end
        end
    end
    return result
end

-- =========================================================================
-- 公共 API
-- =========================================================================

--- 获取所有存活势力的 ID 列表
---@param gameState table
---@return table aliveIds
function DiplomacySystem.getAliveFactions(gameState)
    local alive = {}
    for fid, f in pairs(gameState.factions) do
        if isFactionAlive(gameState, fid) then
            alive[#alive + 1] = fid
        end
    end
    table.sort(alive)
    return alive
end

--- 检查是否可以宣战
--- 条件：未处于战争状态、无和平冷却、双方都存活
---@param gameState table
---@param f1 number attackerId
---@param f2 number defenderId
---@return boolean canWar
---@return string|nil reason
function DiplomacySystem.canDeclareWar(gameState, f1, f2)
    if f1 == f2 then
        return false, "不能对自己宣战"
    end
    if not isFactionAlive(gameState, f1) then
        return false, factionName(f1) .. "已灭亡"
    end
    if not isFactionAlive(gameState, f2) then
        return false, factionName(f2) .. "已灭亡"
    end

    local rel = getRelation(gameState, f1, f2)
    if rel.atWar then
        return false, "双方已处于战争状态"
    end
    if rel.peaceCooldown and rel.peaceCooldown > 0 then
        return false, "和平冷却中（剩余" .. rel.peaceCooldown .. "个月）"
    end
    -- 附庸关系不可宣战（2026-09-01）
    local f1f = gameState.factions[f1]
    local f2f = gameState.factions[f2]
    if (f1f and f1f.vassalOf == f2) or (f2f and f2f.vassalOf == f1) then
        return false, "附庸关系不可宣战"
    end
    return true, nil
end

--- 宣战
---@param gameState table
---@param attackerId number
---@param defenderId number
---@return boolean success
---@return string|nil reason
function DiplomacySystem.declareWar(gameState, attackerId, defenderId)
    local canWar, reason = DiplomacySystem.canDeclareWar(gameState, attackerId, defenderId)
    if not canWar then
        return false, reason
    end

    local rel = getRelation(gameState, attackerId, defenderId)
    rel.atWar = true
    rel.value = clampRelation(rel.value + DIP.WAR_RELATION_DROP)

    -- 宣战方损失威望
    local attacker = gameState.factions[attackerId]
    if attacker then
        attacker.prestige = (attacker.prestige or 0) + DIP.WAR_DECLARE_PRESTIGE
    end

    -- 创建战争记录（战争分数制）
    WarSystem.startWar(gameState, attackerId, defenderId)

    addLog(gameState,
        factionName(attackerId) .. "向" .. factionName(defenderId) .. "宣战！"
        .. "（关系降至" .. rel.value .. "，威望" .. DIP.WAR_DECLARE_PRESTIGE .. "）")

    return true, nil
end

--- 结算和平条约（内部，2026-09-01）：
---   割让省 / 赔款(金/粮) / 附庸 / 一键吞并 + 停战 + 冷却
---@param gameState table
---@param proposerId number 索取方（获得领土/赔款的一方）
---@param targetId number 被索取方（付出方）
---@param terms table { provinces={pid,...}, gold, food, vassal, annexAll, payer, receiver }
local function settlePeace(gameState, proposerId, targetId, terms)
    local rel = getRelation(gameState, proposerId, targetId)
    rel.atWar = false
    rel.peaceCooldown = DIP.PEACE_COOLDOWN_MONTHS

    WarSystem.endWar(gameState, WarSystem.findWar(gameState, proposerId, targetId))
    terms = terms or {}

    -- 附庸：被索取方成为索取方附庸（存活但称臣，被占省归还）
    if terms.vassal then
        local tf = gameState.factions[targetId]
        if tf then
            tf.vassalOf = proposerId
        end
        for _, prov in pairs(gameState.provinces) do
            if prov.occupiedBy == proposerId then
                prov.occupiedBy = nil
            end
        end
    end

    -- 一键吞并全部：索取方获得被索取方所有省，随后触发灭国检测与"已灭亡"播报
    if terms.annexAll then
        local tf = gameState.factions[targetId]
        if tf then
            local list = tf.provinces or {}
            for i = #list, 1, -1 do
                local pid = list[i]
                MilitarySystem.occupy(gameState, proposerId, pid)
                local prov = gameState.provinces[pid]
                if prov then prov.occupiedBy = nil end
            end
            if gameState and gameState.checkElimination then
                gameState.checkElimination(targetId)
            end
        end
    end

    -- 割让省（逐个正式转移所有权并清除占领标记）
    for _, pid in ipairs(terms.provinces or {}) do
        local prov = gameState.provinces[pid]
        if prov then
            if prov.ownerId == targetId then
                MilitarySystem.occupy(gameState, proposerId, pid)
            end
            prov.occupiedBy = nil
        end
    end

    -- 赔款（金/粮）
    if (terms.gold or 0) > 0 then
        local payer = gameState.factions[targetId]
        local receiver = gameState.factions[proposerId]
        if payer and receiver then
            local actual = math.min(payer.gold or 0, terms.gold)
            payer.gold = (payer.gold or 0) - actual
            receiver.gold = (receiver.gold or 0) + actual
        end
    end
    if (terms.food or 0) > 0 then
        local payer = gameState.factions[targetId]
        local receiver = gameState.factions[proposerId]
        if payer and receiver then
            local actual = math.min(payer.food or 0, terms.food)
            payer.food = (payer.food or 0) - actual
            receiver.food = (receiver.food or 0) + actual
        end
    end

    -- 清除玩家相关的挂起条约
    if gameState.pendingPeace then
        gameState.pendingPeace = nil
    end
end

--- 求和（AI 通用入口 / 玩家经由 preparePeaceOffer+submitPeace 流程）
---
--- 2026-09-01 改造：条约含割让省/赔款/附庸/吞并
---   * 被求和方是玩家 → 写入 pendingPeace 挂起，等玩家决定
---   * AI 之间 → 概率判定，接受则自动结算（割让被占省 + 赔款）
---@param gameState table
---@param proposerId number
---@param targetId number
---@return boolean accepted
---@return any reason  string 或 terms 表（接受时）
function DiplomacySystem.proposePeace(gameState, proposerId, targetId)
    local rel = getRelation(gameState, proposerId, targetId)

    if not rel.atWar then
        return false, "双方并未处于战争状态"
    end
    if rel.peaceCooldown and rel.peaceCooldown > 0 then
        return false, "和平冷却中（剩余" .. rel.peaceCooldown .. "个月）"
    end

    -- 被求和方是玩家：挂起，弹出条约窗口等玩家决定
    if targetId == gameState.playerFactionId then
        if gameState.pendingPeace then
            return false, "已有求和待回应"
        end
        -- AI 求和条款：AI 割让被玩家占领的 AI 省 + AI 赔款 100 金
        local provList = {}
        for pid, prov in pairs(gameState.provinces) do
            if prov.occupiedBy == targetId and prov._initOwner == proposerId then
                provList[#provList + 1] = pid
            end
        end
        gameState.pendingPeace = {
            proposerId = proposerId,
            targetId   = targetId,
            terms = {
                provinces = provList,
                gold = 100, food = 0, vassal = false, annexAll = false,
            },
        }
        return false, "等待玩家回应"
    end

    -- AI 之间：概率判定 + 自动结算（求和方割让被其占领的对方省 + 赔款 80 金）
    local chance = WarSystem.getPeaceAcceptChance(gameState, proposerId, targetId)
    if math.random() >= chance then
        addLog(gameState, factionName(proposerId) .. "求和被拒")
        return false, "拒绝议和"
    end
    local provList = {}
    for pid, prov in pairs(gameState.provinces) do
        if prov.occupiedBy == proposerId and prov._initOwner == targetId then
            provList[#provList + 1] = pid
        end
    end
    local terms = {
        provinces = provList, gold = 80, food = 0, vassal = false, annexAll = false,
    }
    settlePeace(gameState, targetId, proposerId, terms)   -- target 为索取方（收回领土），proposer 为让步方
    addLog(gameState, factionName(proposerId) .. "与" .. factionName(targetId) .. "议和成功")
    return true, terms
end

--- 生成求和条款（玩家求和入口，供条约窗口展示）
--- 返回对方全部可索取省列表（含成本/占领状态）+ 全境标记
---@param gameState table
---@param proposerId number
---@param targetId number
---@return boolean ok
---@return any result  terms 表 或 string 错误原因
function DiplomacySystem.preparePeaceOffer(gameState, proposerId, targetId)
    local rel = getRelation(gameState, proposerId, targetId)
    if not rel.atWar then
        return false, "双方并未处于战争状态"
    end
    if rel.peaceCooldown and rel.peaceCooldown > 0 then
        return false, "和平冷却中（剩余" .. rel.peaceCooldown .. "个月）"
    end
    local provinceList = {}
    for pid, prov in pairs(gameState.provinces) do
        if prov._initOwner == targetId and not prov.isWasteland and not prov.isOcean then
            provinceList[#provinceList + 1] = {
                id = pid,
                name = prov.name or "?",
                cost = WarSystem.getProvinceCost(gameState, pid, proposerId),
                occupied = (prov.occupiedBy == proposerId),
            }
        end
    end
    table.sort(provinceList, function(a, b)
        if a.occupied ~= b.occupied then return a.occupied end
        return a.cost < b.cost
    end)
    local allOccupied = true
    for _, p in ipairs(provinceList) do
        if not p.occupied then
            allOccupied = false
            break
        end
    end
    local terms = {
        targetId = targetId,
        provinceList = provinceList,
        allOccupied = allOccupied,
        provinces = {},
        gold = 0, food = 0, vassal = false, annexAll = false,
    }
    return true, terms
end

--- 玩家提交求和条约（条约窗口"缔结"后调用）
--- 校验战争分数预算 → 概率判定 → 结算
---@param gameState table
---@param proposerId number
---@param targetId number
---@param terms table
---@return boolean accepted
---@return string reason
function DiplomacySystem.submitPeace(gameState, proposerId, targetId, terms)
    local rel = getRelation(gameState, proposerId, targetId)
    if not rel.atWar then
        return false, "双方并未处于战争状态"
    end

    -- 战争分数预算（灭国=吞并全部：已要求全境占领，成本检查放行——决定性胜利）
    if not terms.annexAll then
        local cost = 0
        for _, pid in ipairs(terms.provinces or {}) do
            cost = cost + WarSystem.getProvinceCost(gameState, pid, proposerId)
        end
        cost = cost + math.ceil((terms.gold or 0) / 100) + math.ceil((terms.food or 0) / 100)
        if terms.vassal then cost = cost + 30 end

        local score = 0
        local war = WarSystem.findWar(gameState, proposerId, targetId)
        if war then
            score = WarSystem.getScore(gameState, war, proposerId)
        end
        if cost > score then
            return false, "战争分数不足（需要 " .. cost .. "，当前 " .. math.floor(score) .. "）"
        end
    end

    -- 灭国（吞并全部）为决定性胜利：对方全境已被占领，无力拒绝，直接接受
    if terms.annexAll then
        settlePeace(gameState, proposerId, targetId, terms)
        addLog(gameState, factionName(targetId) .. "国祚已绝，疆土尽归" .. factionName(proposerId))
        return true, factionName(targetId) .. "已灭亡！疆土尽归" .. factionName(proposerId)
    end

    local chance = WarSystem.getPeaceAcceptChance(gameState, proposerId, targetId)
    if math.random() >= chance then
        addLog(gameState, factionName(targetId) .. "拒绝了你的议和")
        return false, factionName(targetId) .. "拒绝议和"
    end

    settlePeace(gameState, proposerId, targetId, terms)
    addLog(gameState, factionName(proposerId) .. "与" .. factionName(targetId) .. "议和成功")
    return true, "议和成功！"
end

--- 玩家回应 AI 的求和（条约窗口"接受/拒绝"）
---@param gameState table
---@param accept boolean
---@return boolean ok
---@return string reason
function DiplomacySystem.respondPendingPeace(gameState, accept)
    local pending = gameState.pendingPeace
    if not pending then
        return false, "当前没有待回应的求和"
    end

    local proposerId = pending.proposerId   -- AI 求和方（让步方）
    local targetId   = pending.targetId     -- 玩家（被求和方/索取方）
    local terms      = pending.terms

    gameState.pendingPeace = nil

    if accept then
        settlePeace(gameState, targetId, proposerId, terms)   -- 玩家获得割让与赔款
        addLog(gameState, "你接受了" .. factionName(proposerId) .. "的求和")
        return true, "已接受和约"
    end

    addLog(gameState, "你拒绝了" .. factionName(proposerId) .. "的求和")
    return true, "已拒绝"
end

function DiplomacySystem.improveRelation(gameState, factionId, targetId)
    if factionId == targetId then
        return false, "不能改善与自己的关系"
    end

    local faction = gameState.factions[factionId]
    if not faction then
        return false, "势力不存在"
    end

    if (faction.gold or 0) < DIP.IMPROVE_COST then
        return false, "金币不足（需要" .. DIP.IMPROVE_COST .. "）"
    end

    local rel = getRelation(gameState, factionId, targetId)
    if rel.atWar then
        return false, "战争期间无法改善关系"
    end
    if rel.value >= DIP.MAX_RELATION then
        return false, "关系已达到上限"
    end

    -- 扣除金币
    faction.gold = faction.gold - DIP.IMPROVE_COST

    -- 提升关系（君主外交 + 政策/变法修正）
    local diploMod = LeaderSystem.getDiploModifier(faction)
        + PolicySystem.getDiploModifier(faction)
    rel.value = clampRelation(rel.value + DIP.IMPROVE_PER_MONTH + diploMod)
    rel.improvingFrom = factionId

    addLog(gameState,
        factionName(factionId) .. "花费" .. DIP.IMPROVE_COST .. "金改善与"
        .. factionName(targetId) .. "的关系（+" .. DIP.IMPROVE_PER_MONTH
        .. "，当前" .. rel.value .. "）")

    return true, nil
end

--- 月度外交处理：更新冷却、自然关系漂移
---@param gameState table
function DiplomacySystem.processMonthlyDiplomacy(gameState)
    if not gameState.relations then return end

    -- Track which relation records we've already processed (since
    -- relations[a][b] and relations[b][a] may share the same object).
    local visited = {}

    for fid1, row in pairs(gameState.relations) do
        if type(row) == "table" then
            for fid2, rel in pairs(row) do
                if type(rel) == "table" then
                    -- Canonical key: process each pair only once
                    local lo = math.min(fid1, fid2)
                    local hi = math.max(fid1, fid2)
                    local canonKey = lo * 10000 + hi
                    if not visited[canonKey] then
                        visited[canonKey] = true

                        -- 1. 减少和平冷却
                        if rel.peaceCooldown and rel.peaceCooldown > 0 then
                            rel.peaceCooldown = rel.peaceCooldown - 1
                        end

                        -- 2. 自然关系漂移：缓慢向 0 回归
                        if not rel.atWar then
                            if rel.value > 0 then
                                rel.value = clampRelation(rel.value - 1)
                            elseif rel.value < 0 then
                                rel.value = clampRelation(rel.value + 1)
                            end
                        else
                            -- 战争期间关系持续恶化（每月 -1）
                            rel.value = clampRelation(rel.value - 1)
                        end

                        -- 3. 清除过期的改善关系标记
                        if rel.improvingFrom then
                            local f = gameState.factions[rel.improvingFrom]
                            if not f or (f.gold or 0) < DIP.IMPROVE_COST then
                                rel.improvingFrom = nil
                            end
                        end
                    end
                end
            end
        end
    end
end

-- =========================================================================
-- 查询接口（供 UI / 其他系统使用）
-- =========================================================================

--- 获取两国关系值
---@param gameState table
---@param f1 number
---@param f2 number
---@return number relationValue
function DiplomacySystem.getRelationValue(gameState, f1, f2)
    local rel = getRelation(gameState, f1, f2)
    return rel.value
end

--- 获取两国是否处于战争状态
---@param gameState table
---@param f1 number
---@param f2 number
---@return boolean atWar
function DiplomacySystem.isAtWar(gameState, f1, f2)
    local rel = getRelation(gameState, f1, f2)
    return rel.atWar
end

--- 获取两国的完整关系记录
---@param gameState table
---@param f1 number
---@param f2 number
---@return table relation {value, atWar, peaceCooldown, improvingFrom}
function DiplomacySystem.getRelationRecord(gameState, f1, f2)
    return getRelation(gameState, f1, f2)
end

--- 获取某势力正在交战的所有敌国ID列表
---@param gameState table
---@param factionId number
---@return table enemyIds
function DiplomacySystem.getEnemies(gameState, factionId)
    local enemies = {}
    for fid, _ in pairs(gameState.factions) do
        if fid ~= factionId and isFactionAlive(gameState, fid) then
            local rel = getRelation(gameState, factionId, fid)
            if rel.atWar then
                enemies[#enemies + 1] = fid
            end
        end
    end
    return enemies
end

--- 获取势力的军事实力评分（供UI显示）
---@param gameState table
---@param factionId number
---@return number strength
function DiplomacySystem.getStrength(gameState, factionId)
    return calcStrength(gameState, factionId)
end

return DiplomacySystem

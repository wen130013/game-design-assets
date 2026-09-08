-- ============================================================================
-- 春秋霸业 - 战争系统（战争分数 / 投降 / 割地赔款）
-- WarSystem.lua
--
-- 管理"进行中的战争"记录与战争分数：
--   * 宣战时在 gameState.wars 创建记录（记录双方初始省份数）
--   * 战争分数 = 已占领对方初始省的比例（0~100）
--   * 求和时按战争分数决定接受概率与割地/赔款结果
-- 参照 Age of History 3 / CK3 的战争分数机制。
-- ============================================================================

local WarSystem = {}

-- =========================================================================
-- 常量
-- =========================================================================
local BASE_PEACE_CHANCE = 0.5   -- 无优势时的基础求和接受概率
local SCORE_FACTOR      = 0.6   -- 分数每高对方 10 分，接受概率增加 6%
local WAR_SCORE_CAP     = 100

-- =========================================================================
-- 内部工具
-- =========================================================================

--- 生成战争唯一键
---@param f1 number
---@param f2 number
---@return string
local function warKey(f1, f2)
    return math.min(f1, f2) .. "_" .. math.max(f1, f2)
end

--- 计算一个势力当前拥有的省份数
---@param gameState table
---@param factionId number
---@return number
local function provinceCount(gameState, factionId)
    if gameState.factionProvinces and gameState.factionProvinces[factionId] then
        return #gameState.factionProvinces[factionId]
    end
    local f = gameState.factions[factionId]
    return f and #f.provinces or 0
end

--- 取势力名称（容错）
---@param gameState table
---@param factionId number
---@return string
local function factionName(gameState, factionId)
    local f = gameState.factions[factionId]
    return f and (f.fullName or f.name) or ("势力#" .. tostring(factionId))
end

-- =========================================================================
-- 公共 API
-- =========================================================================

--- 宣战时创建战争记录
---@param gameState table
---@param attackerId number
---@param defenderId number
function WarSystem.startWar(gameState, attackerId, defenderId)
    gameState.wars = gameState.wars or {}
    local key = warKey(attackerId, defenderId)
    gameState.wars[key] = {
        aId        = attackerId,
        dId        = defenderId,
        aProvinces = provinceCount(gameState, attackerId),   -- 宣战时的初始省份数
        dProvinces = provinceCount(gameState, defenderId),
    }
    return gameState.wars[key]
end

--- 找到两方之间的战争记录（若存在）
---@param gameState table
---@param f1 number
---@param f2 number
---@return table|nil
function WarSystem.findWar(gameState, f1, f2)
    if not gameState.wars then return nil end
    return gameState.wars[warKey(f1, f2)]
end

--- 获取某势力参与的所有战争列表
---@param gameState table
---@param factionId number
---@return table[] wars {war, myId, enemyId}
function WarSystem.getWarsFor(gameState, factionId)
    local result = {}
    if not gameState.wars then return result end
    for _, war in pairs(gameState.wars) do
        local myId, enemyId
        if war.aId == factionId then
            myId, enemyId = war.aId, war.dId
        elseif war.dId == factionId then
            myId, enemyId = war.dId, war.aId
        else
            goto continue
        end
        result[#result + 1] = {
            war    = war,
            myId   = myId,
            enemyId = enemyId,
        }
        ::continue::
    end
    return result
end

--- 计算一场战争中一方的战争分数（0~100）
--- 分数 = 已占领对方初始省的比例（2026-09-01：基于 occupiedBy 标记）
---@param gameState table
---@param war table
---@param factionId number 想要哪一方的分数
---@return number score
function WarSystem.getScore(gameState, war, factionId)
    local isA = (war.aId == factionId)
    local enemyId = isA and war.dId or war.aId
    local enemyTotal = isA and war.dProvinces or war.aProvinces
    if enemyTotal <= 0 then return WAR_SCORE_CAP end
    -- 我方占领的"敌方初始省"数量
    local gained = 0
    for pid, prov in pairs(gameState.provinces) do
        if prov.occupiedBy == factionId and prov._initOwner == enemyId then
            gained = gained + 1
        end
    end
    return math.min(WAR_SCORE_CAP, gained / enemyTotal * WAR_SCORE_CAP)
end

--- 某省在和平条约中的战争分数成本（2026-09-01）
---   * 已被索取方占领的省：便宜（5 分）
---   * 未被占领的省：贵（15 分，需强取）
---@param gameState table
---@param provinceId number
---@param claimantId number 索取方
---@return number cost
function WarSystem.getProvinceCost(gameState, provinceId, claimantId)
    local prov = gameState.provinces[provinceId]
    if not prov or prov.isWasteland or prov.isOcean then return 0 end
    if prov.occupiedBy == claimantId then
        return 5
    end
    return 15
end

--- 生成和平条约条款（2026-08-31）
---
--- 机制说明：本游戏"占领即吞并"（occupy 直接转移所有权），
--- 所以领土战果已是现状；条约只包含**赔款**：
---   * 求和方占优（分数更高）→ 被求和方向求和方赔款
---   * 求和方劣势               → 求和方向被求和方赔款
--- 赔款额 = (10 + 分数差 * 1.5) * 10，封顶 5000
---@param gameState table
---@param proposerId number 求和方
---@param targetId number 被求和方
---@return table|nil terms {gold, payer, receiver}
function WarSystem.buildTerms(gameState, proposerId, targetId)
    local war = WarSystem.findWar(gameState, proposerId, targetId)
    if not war then return nil end

    local myScore   = WarSystem.getScore(gameState, war, proposerId)
    local enemyScore = WarSystem.getScore(gameState, war, targetId)
    local diff = myScore - enemyScore

    local amount = math.floor((10 + math.abs(diff) * 1.5) * 10)
    amount = math.max(0, math.min(5000, amount))

    if diff >= 0 then
        return { gold = amount, payer = targetId, receiver = proposerId }
    end
    return { gold = amount, payer = proposerId, receiver = targetId }
end

--- 计算被求和方接受和议的概率（0.1~0.95）
---@param gameState table
---@param proposerId number 求和方
---@param targetId number 被求和方
---@return number chance
function WarSystem.getPeaceAcceptChance(gameState, proposerId, targetId)
    local war = WarSystem.findWar(gameState, proposerId, targetId)
    if not war then return 0 end

    local myScore   = WarSystem.getScore(gameState, war, proposerId)
    local enemyScore = WarSystem.getScore(gameState, war, targetId)

    -- 接受概率 = 基础 50% + 分数差修正
    -- proposer 分数越高（正在赢），target 越愿意接受
    local diff = myScore - enemyScore
    local chance = BASE_PEACE_CHANCE + diff * SCORE_FACTOR
    return math.max(0.1, math.min(0.95, chance))
end

--- 求和判定（AI 与 AI 之间的快速路径）
--- 依据战争分数判定接受与否；接受时返回条款供结算
---@param gameState table
---@param proposerId number 求和方
---@param targetId number 被求和方
---@return boolean accepted
---@return table|string result  terms 表（接受）或拒绝原因（拒绝）
function WarSystem.proposePeace(gameState, proposerId, targetId)
    local war = WarSystem.findWar(gameState, proposerId, targetId)
    if not war then return false, "双方并未处于战争状态" end

    local myScore   = WarSystem.getScore(gameState, war, proposerId)
    local enemyScore = WarSystem.getScore(gameState, war, targetId)
    local chance = WarSystem.getPeaceAcceptChance(gameState, proposerId, targetId)

    local accepted = math.random() < chance
    if not accepted then
        return false, factionName(gameState, targetId) .. "拒绝议和（战争分数 " ..
            math.floor(myScore) .. " : " .. math.floor(enemyScore) .. "）"
    end

    -- 议和成功：生成条款并结束战争
    local terms = WarSystem.buildTerms(gameState, proposerId, targetId)
    if not terms then
        return false, "无法生成条款"
    end
    WarSystem.endWar(gameState, war)
    return true, terms
end

--- 结束战争（删除战争记录）
--- 防御：战争记录可能已被调用链上游删除（如 WarSystem.proposePeace 内部
--- 已 endWar，DiplomacySystem.settlePeace 再次查找时 war 为 nil）
---@param gameState table
---@param war table|nil
function WarSystem.endWar(gameState, war)
    if not gameState.wars then return end
    if not war then return end
    gameState.wars[warKey(war.aId, war.dId)] = nil
end

--- 获取战争列表（供 UI 展示）
---@param gameState table
---@return table[] wars
function WarSystem.getWars(gameState)
    local result = {}
    if not gameState.wars then return result end
    for _, war in pairs(gameState.wars) do
        result[#result + 1] = war
    end
    return result
end

return WarSystem

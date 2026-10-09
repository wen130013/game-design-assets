-- 战争分数：每场战争独立记录领土、首都与兵力快照。
-- 借鉴公开规则的规模权重和贡献上限，公式由本项目独立实现。
local WarSystem = {}
local BASE_PEACE_CHANCE = 0.5
local SCORE_FACTOR = 0.006   -- 分差每 10 分，接受概率增加 6%
local WAR_SCORE_CAP = 100
local PROV_SCORE, CAPITAL_SCORE, BATTLE_CAP = 60, 20, 20

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

--- 当前有效领土，连续数组便于存档，不采用整局初始归属。
---@param gameState table
---@param factionId number
---@return number[]
local function provinceIds(gameState, factionId)
    local ids = {}
    for pid, p in pairs(gameState.provinces or {}) do
        if p.ownerId == factionId and not p.isOcean and not p.isWasteland then
            ids[#ids + 1] = pid
        end
    end
    table.sort(ids)
    return ids
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
    -- 开战时刻（year*12+month）—— 战争列表按它排序：**越早开战的越靠右**（2026-09-17 用户口径）
    local startedAt = nil
    local ok, TimeSystem = pcall(require, "core.TimeSystem")
    if ok and TimeSystem and TimeSystem.getTime then
        local y, m = TimeSystem.getTime()
        if type(y) == "number" then
            startedAt = y * 12 + (tonumber(m) or 1)
        end
    end
    local aIds, dIds = provinceIds(gameState, attackerId), provinceIds(gameState, defenderId)
    local a, d = gameState.factions[attackerId], gameState.factions[defenderId]
    local Ledger = require("systems.MilitaryLedger")
    local _, aArmy = Ledger.snapshot(gameState, a)
    local _, dArmy = Ledger.snapshot(gameState, d)
    gameState.wars[key] = {
        aId = attackerId, dId = defenderId,
        aProvinces = #aIds, dProvinces = #dIds,
        aProvinceIds = aIds, dProvinceIds = dIds,
        aCapitalId = a and a.capitalId, dCapitalId = d and d.capitalId,
        aArmy = aArmy, dArmy = dArmy,
        startedAt = startedAt,
    }
    print(string.format("[War] 宣战 %s 对 %s，快照省数%d/%d，兵力%.0f/%.0f",
        tostring(attackerId), tostring(defenderId), #aIds, #dIds, aArmy, dArmy))
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

--- 势力首都省 id（容错：没这个字段就返回 nil）
---@param gameState table
---@param factionId number
---@return number|nil
local function capitalOf(gameState, factionId)
    local f = gameState.factions[factionId]
    return f and f.capitalId or nil
end

--- 计算一场战争中一方的战争分数（−100 ~ +100）
---
--- 构成（2026-09-18 用户口径："占领/战斗/目标 加分，丢省/战败/失都 减分"）：
---   * 领土（实时）：占领对方省 + / 丢自己的省 −（按宣战时初始省数归一，合计 ±PROV_SCORE）
---   * 目标（实时）：占领对方首都 +CAPITAL_SCORE / 自己失都 −CAPITAL_SCORE
---   * 战斗（累积）：按败方参战规模占其开战兵力比例计分，净贡献夹±20。
---   * 全境控制且本土未失：决定性±100，无需刷小仗补差额。
---@param gameState table
---@param war table
---@param factionId number 想要哪一方的分数
---@return number score
function WarSystem.getScore(gameState, war, factionId)
    if not war or (factionId ~= war.aId and factionId ~= war.dId) then return 0 end
    local isA = war.aId == factionId
    local enemyId = isA and war.dId or war.aId
    -- 老存档没有历史快照，只按当前正式领土回退；不伪造整局初始归属。
    local myIds = (isA and war.aProvinceIds or war.dProvinceIds) or provinceIds(gameState, factionId)
    local enemyIds = (isA and war.dProvinceIds or war.aProvinceIds) or provinceIds(gameState, enemyId)
    local function occupied(ids, by)
        local n = 0
        for _, pid in ipairs(ids) do
            local p = gameState.provinces[pid]
            if p and (p.occupiedBy or p.ownerId) == by then n = n + 1 end
        end
        return n
    end
    local gained, lost = occupied(enemyIds, factionId), occupied(myIds, enemyId)
    -- 全境控制即决定性胜负，无需靠四场小仗补满剩下的20分。
    if #enemyIds > 0 and gained == #enemyIds and lost == 0 then return WAR_SCORE_CAP end
    if #myIds > 0 and lost == #myIds and gained == 0 then return -WAR_SCORE_CAP end
    local up = #enemyIds > 0 and gained / #enemyIds * PROV_SCORE or 0
    local down = #myIds > 0 and lost / #myIds * PROV_SCORE or 0
    local myCap = (isA and war.aCapitalId or war.dCapitalId) or capitalOf(gameState, factionId)
    local enemyCap = (isA and war.dCapitalId or war.aCapitalId) or capitalOf(gameState, enemyId)
    local myP, enemyP = myCap and gameState.provinces[myCap], enemyCap and gameState.provinces[enemyCap]
    local capitalScore = (enemyP and (enemyP.occupiedBy or enemyP.ownerId) == factionId and CAPITAL_SCORE or 0)
        - (myP and (myP.occupiedBy or myP.ownerId) == enemyId and CAPITAL_SCORE or 0)
    local battleScore = math.max(-BATTLE_CAP, math.min(BATTLE_CAP, war.aBattle or -(war.dBattle or 0)))
    local signedBattle = isA and battleScore or -battleScore
    return math.max(-WAR_SCORE_CAP, math.min(WAR_SCORE_CAP, up - down + capitalScore + signedBattle))
end

--- 一场胜仗按败方参战人数/其宣战时兵力加分，主力战最多20，小仗不再固定5分。
--- 旧调用/旧战斗缺少规模时不猜历史，计0分；占领分仍照常实时计算。
---@param gameState table
---@param winnerId number|nil
---@param loserId number|nil
---@param loserInitialSize number|nil
---@return number points
function WarSystem.recordBattle(gameState, winnerId, loserId, loserInitialSize)
    if not winnerId or not loserId then return 0 end
    local war = WarSystem.findWar(gameState, winnerId, loserId)
    if not war then return 0 end
    local armyAtStart = loserId == war.aId and war.aArmy or war.dArmy
    if not armyAtStart or armyAtStart <= 0 then
        local f = gameState.factions[loserId]
        armyAtStart = f and f.armySize or 0
    end
    local participants = math.max(0, loserInitialSize or 0)
    local denominator = math.max(1, armyAtStart or 0, participants)
    local points = BATTLE_CAP * participants / denominator
    local old = war.aBattle or -(war.dBattle or 0)
    local signed = winnerId == war.aId and points or -points
    war.aBattle = math.max(-BATTLE_CAP, math.min(BATTLE_CAP, old + signed))
    war.dBattle = -war.aBattle
    return points
end

--- 日伤亡、追击和无退路全歼共用统计，战报不再漏记战后损失。
---@param gameState table
---@param attackerId number
---@param defenderId number
---@param attLoss number
---@param defLoss number
function WarSystem.recordCasualties(gameState, attackerId, defenderId, attLoss, defLoss)
    local war = WarSystem.findWar(gameState, attackerId, defenderId)
    if not war then return end
    local aLost, dLost = math.max(0, attLoss or 0), math.max(0, defLoss or 0)
    local attIsA = attackerId == war.aId
    war.aLoss = (war.aLoss or 0) + (attIsA and aLost or dLost)
    war.dLoss = (war.dLoss or 0) + (attIsA and dLost or aLost)
    war.stats = war.stats or {}
    local function add(fid, side, lost, killed)
        local record = war.stats[fid] or { lost = 0, killed = 0 }
        record.side = side
        record.lost = (record.lost or 0) + lost
        record.killed = (record.killed or 0) + killed
        war.stats[fid] = record
    end
    add(attackerId, attIsA and "a" or "d", aLost, dLost)
    add(defenderId, attIsA and "d" or "a", dLost, aLost)
end

--- 割地成本与该省的占领收益使用同一规模口径，避免大国占一省却永远不够5分。
--- 已占：取5分和该省领土收益一半的较小值；未占：三倍，强取仍更贵。
---@param gameState table
---@param provinceId number
---@param claimantId number
---@return number cost
function WarSystem.getProvinceCost(gameState, provinceId, claimantId)
    local prov = gameState.provinces[provinceId]
    if not prov or prov.isWasteland or prov.isOcean then return 0 end
    local total = #provinceIds(gameState, prov.ownerId)
    local war = prov.ownerId and WarSystem.findWar(gameState, claimantId, prov.ownerId)
    if war then
        local ids = prov.ownerId == war.aId and war.aProvinceIds or war.dProvinceIds
        if ids and #ids > 0 then total = #ids end
    end
    local occupiedCost = math.min(5, PROV_SCORE / math.max(1, total) * 0.5)
    return occupiedCost * (prov.occupiedBy == claimantId and 1 or 3)
end

--- 生成和平条约条款（2026-08-31；2026-09-25 修注释）
---
--- ⚠️ 旧注释写的是"本游戏占领即吞并（occupy 直接转移所有权）"——**那是 bug 不是设计**。
---   2026-09-25 已修正：打下来只是**军事占领**（occupiedBy），和约里才正式割让。
---   条约内容 = **赔款** + 割让已占省（后者在 DiplomacySystem.settlePeace 里处理）：
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
    local claimant = gameState.factions[proposerId]
    local conceder = gameState.factions[targetId]
    if myScore >= 99.999 then return 1 end
    if myScore >= 50 and claimant and conceder and (claimant.armySize or 0) > 0
        and (conceder.armySize or 0) <= (claimant.armySize or 0) * 0.35 then return 1 end
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
    -- 仅返回判定和条款；关系、军队、领土必须由外交结算一次性收尾。
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

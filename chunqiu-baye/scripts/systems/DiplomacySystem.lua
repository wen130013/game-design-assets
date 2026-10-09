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
local PeaceSettlement = require("systems.PeaceSettlement")
local LeaderSystem = require("systems.LeaderSystem")
local PolicySystem = require("systems.PolicySystem")
local Hooks      = require("systems.Hooks")
local MilitarySystem = require("systems.MilitarySystem")
local Modifiers  = require("systems.Modifiers")

local DiplomacySystem = {}

-- ---------------------------------------------------------------------------
-- 修正器管道登记（2026-09-14 · 洞 4）：**改善关系的加成**
--   原来是 `LeaderSystem.getDiploModifier(fac) + PolicySystem.getDiploModifier(fac)`
--   硬写在函数里 → 模组挂 diploImprove **不会生效**。
--   注意这里是**加法**（不是倍率）→ 用 op="flat"，调用方从 0 起算。
-- ---------------------------------------------------------------------------
Modifiers.rule{
    scope = "faction", key = "diploImprove", op = "flat", source = "leader:diplo",
    value = function(_, ctx) return LeaderSystem.getDiploModifier(ctx.faction) end,
}
Modifiers.rule{
    scope = "faction", key = "diploImprove", op = "flat", source = "policy:diplo",
    value = function(_, ctx) return PolicySystem.getDiploModifier(ctx.faction) end,
}

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
---@param notify boolean|nil true = 上通知条（2026-09-16：只报**涉及玩家**的外交大事）
local function addLog(gameState, msg, notify)
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
        gameState.addMessage(msg, "diplomacy", notify)
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
--- 军力 = 兵力 + 人口/100 + 省份数 * 100（2026-09-17 重新配平，见下方注释）
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

    -- 国力评估（AI 拿它比强弱决定打不打）
    --   2026-09-17 重新配平：兵力总量 ÷5 之后，原来 `省数×1000`、`人口/10` 两项
    --   会比军队本身还大 10 倍 → AI 只看地盘不看兵。现在三项量级相当，**军队仍是主项**。
    return armySize + population / 100 + provinceCount * 100
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
    -- GameState.init 的两向记录可独立；双方出兵/和约判断必须看到相同战争状态。
    local rows = gameState.relations
    local forward = rows[attackerId] and rows[attackerId][defenderId]
    local reverse = rows[defenderId] and rows[defenderId][attackerId]
    if forward then forward.atWar = true end
    if reverse then reverse.atWar = true end
    rel.value = clampRelation(rel.value + DIP.WAR_RELATION_DROP)

    -- 宣战方损失名声
    local attacker = gameState.factions[attackerId]
    if attacker then
        attacker.prestige = (attacker.prestige or 0) + DIP.WAR_DECLARE_PRESTIGE
    end

    -- 创建战争记录前丢弃这双方旧和约的延期归还，不能撤掉新战争的占领军。
    PeaceSettlement.discardReturns(gameState, attackerId, defenderId)
    -- 创建战争记录（战争分数制）
    WarSystem.startWar(gameState, attackerId, defenderId)

    -- 宣战即出兵（2026-09-17 用户："既然交战这些军队就应该立刻出发"）：
    -- 双方立刻向相邻的敌省开拔；否则两军原地干耗 → 战争分永远是 0。
    local MilitarySystem = require("systems.MilitarySystem")
    local aSent = MilitarySystem.launchOffensive(gameState, attackerId)
    local dSent = MilitarySystem.launchOffensive(gameState, defenderId)
    addLog(gameState, string.format("出兵：%s %d 支、%s %d 支",
        factionName(attackerId), aSent, factionName(defenderId), dSent), false)

    -- notify：只报"**别人打你**"（2026-09-16 用户："你对别人做一件事就不要通知"）
    addLog(gameState,
        factionName(attackerId) .. "向" .. factionName(defenderId) .. "宣战！"
        .. "（关系降至" .. rel.value .. "，名声" .. DIP.WAR_DECLARE_PRESTIGE .. "）",
        defenderId == gameState.playerFactionId)

    -- 脚本钩子（2026-09-13）：宣战成功（放在最后，此时战争记录/关系/名声都已落地）
    Hooks.fire("war_declared", {
        gameState = gameState,
        attackerId = attackerId,
        defenderId = defenderId,
    })

    return true, nil
end

--- 结算使用统一双边收尾模块；所有部队按真实归属回营，不影响第三国战场。
---@param gameState table
---@param claimantId number
---@param concederId number
---@param terms table
---@param expectedStartedAt number|nil
---@return boolean ok
---@return string reason
local function settlePeace(gameState, claimantId, concederId, terms, expectedStartedAt)
    return PeaceSettlement.settle(gameState, claimantId, concederId, terms, MilitarySystem, expectedStartedAt)
end

--- AI 求和是让步：target 索取，proposer 支付赔款并割让当前被 target 占领的本省。
---@param gameState table
---@param proposerId number
---@param targetId number
---@return boolean accepted
---@return any reason
function DiplomacySystem.proposePeace(gameState, proposerId, targetId)
    local provList = {}
    for pid, prov in pairs(gameState.provinces or {}) do
        if prov.ownerId == proposerId and prov.occupiedBy == targetId
            and PeaceSettlement.canClaimProvince(gameState, pid, targetId, proposerId) then
            provList[#provList + 1] = pid
        end
    end
    local terms = {
        provinces = provList, gold = targetId == gameState.playerFactionId and 100 or 80,
        food = 0, vassal = false, annexAll = false,
    }
    local valid, result = PeaceSettlement.validate(gameState, targetId, proposerId, terms)
    if not valid then return false, result end
    terms = result.terms
    if targetId == gameState.playerFactionId then
        if gameState.pendingPeace then return false, "已有求和待回应" end
        gameState.pendingPeace = {
            proposerId = proposerId, targetId = targetId,
            warStartedAt = result.war.startedAt, terms = terms,
        }
        return false, "等待玩家回应"
    end
    local chance = WarSystem.getPeaceAcceptChance(gameState, targetId, proposerId)
    if math.random() >= chance then
        addLog(gameState, factionName(proposerId) .. "求和被拒")
        return false, "拒绝议和"
    end
    local ok, reason = settlePeace(gameState, targetId, proposerId, terms, result.war.startedAt)
    if not ok then return false, reason end
    addLog(gameState, factionName(proposerId) .. "与" .. factionName(targetId) .. "议和成功")
    return true, terms
end

--- 玩家提出条款：可选当前归 target 的有效省，不能索取第三国控制/战斗中的省。
---@param gameState table
---@param proposerId number
---@param targetId number
---@return boolean ok
---@return any result
function DiplomacySystem.preparePeaceOffer(gameState, proposerId, targetId)
    local ok, result = PeaceSettlement.validate(gameState, proposerId, targetId, {})
    if not ok then return false, result end
    local provinceList = {}
    for _, pid in ipairs(result.targetProvinceIds) do
        if PeaceSettlement.canClaimProvince(gameState, pid, proposerId, targetId) then
            local prov = gameState.provinces[pid]
            provinceList[#provinceList + 1] = {
                id = pid, name = prov.name or "?",
                cost = WarSystem.getProvinceCost(gameState, pid, proposerId),
                occupied = prov.occupiedBy == proposerId,
            }
        end
    end
    table.sort(provinceList, function(a, b)
        if a.occupied ~= b.occupied then return a.occupied end
        if a.cost ~= b.cost then return a.cost < b.cost end
        return a.id < b.id
    end)
    local terms = result.terms
    terms.targetId = targetId
    terms.provinceList = provinceList
    terms.allOccupied = result.allOccupied
    -- main/UI 原传 cfg.terms，不重建；保留此标记用于提交时重新验证战争。
    terms.startedAt = result.war.startedAt
    return true, terms
end

--- 玩家提交：先后台合法性/全境复验，再按真实分数预算，最后判定接受与收尾。
---@param gameState table
---@param proposerId number
---@param targetId number
---@param terms table
---@return boolean accepted
---@return string reason
function DiplomacySystem.submitPeace(gameState, proposerId, targetId, terms)
    local ok, result = PeaceSettlement.validate(gameState, proposerId, targetId, terms)
    if not ok then return false, result end
    local normalized = result.terms
    local score = WarSystem.getScore(gameState, result.war, proposerId)
    local budget = math.max(0, score)
    -- 零成本白和即使负分也允许；吞并只在后台重新确认非空全境占领后绕过预算。
    if not normalized.annexAll and result.cost > budget + 1e-8 then
        return false, string.format("战争分数不足（需要 %.2f，当前 %.2f）", result.cost, score)
    end
    local chance = normalized.annexAll and 1 or WarSystem.getPeaceAcceptChance(gameState, proposerId, targetId)
    if math.random() >= chance then
        addLog(gameState, factionName(targetId) .. "拒绝了你的议和")
        return false, factionName(targetId) .. "拒绝议和"
    end
    local settled, reason = settlePeace(gameState, proposerId, targetId, normalized, result.war.startedAt)
    if not settled then return false, reason end
    if normalized.annexAll then
        addLog(gameState, factionName(targetId) .. "国祚已绝，疆土尽归" .. factionName(proposerId))
        return true, factionName(targetId) .. "已灭亡！疆土尽归" .. factionName(proposerId)
    end
    addLog(gameState, factionName(proposerId) .. "与" .. factionName(targetId) .. "议和成功")
    return true, "议和成功！"
end

--- 玩家回应 AI 求和：接受前重新验证当前战争及当前领土，旧档无 warStartedAt 兼容。
---@param gameState table
---@param accept boolean
---@return boolean ok
---@return string reason
function DiplomacySystem.respondPendingPeace(gameState, accept)
    local pending = gameState.pendingPeace
    if not pending then return false, "当前没有待回应的求和" end
    local proposerId, targetId = pending.proposerId, pending.targetId
    if not accept then
        if gameState.pendingPeace == pending then gameState.pendingPeace = nil end
        addLog(gameState, "你拒绝了" .. factionName(proposerId) .. "的求和", false)
        return true, "已拒绝"
    end
    local ok, reason = settlePeace(gameState, targetId, proposerId, pending.terms, pending.warStartedAt)
    if not ok then
        if gameState.pendingPeace == pending then gameState.pendingPeace = nil end
        return false, reason
    end
    addLog(gameState, "你接受了" .. factionName(proposerId) .. "的求和", false)
    return true, "已接受和约"
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
    -- 洞 4：改成读管道（两条 flat 规则在上面注册过，加起来和原来一样）
    --   → 模组/事件挂 diploImprove 立刻生效
    local diploMod = Modifiers.applyFloat(0, "faction", "diploImprove",
        { gameState = gameState, faction = faction })
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
    PeaceSettlement.releaseReturns(gameState, MilitarySystem)
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

                        -- 1. 两向可为独立对象，也可共享；每份冷却每月只递减一次。
                        if rel.peaceCooldown and rel.peaceCooldown > 0 then
                            rel.peaceCooldown = rel.peaceCooldown - 1
                        end
                        local reverseRow = gameState.relations[fid2]
                        local reverse = reverseRow and reverseRow[fid1]
                        if reverse and reverse ~= rel and (reverse.peaceCooldown or 0) > 0 then
                            reverse.peaceCooldown = reverse.peaceCooldown - 1
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

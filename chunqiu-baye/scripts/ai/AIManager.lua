-- ============================================================================
-- 春秋霸业 - AI 决策管理器
-- ai/AIManager.lua
--
-- 负责：AI 势力每月决策（宣战/求和/外交/征兵/调军）
-- 从 DiplomacySystem 中提取，保持职责单一
-- 依赖：config.GameConfig, data.Factions, data.Provinces, systems.DiplomacySystem
-- ============================================================================

local GameConfig      = require("config.GameConfig")
local Factions        = require("data.Factions")
local Provinces       = require("data.Provinces")
local DiplomacySystem = require("systems.DiplomacySystem")
local MilitarySystem  = require("systems.MilitarySystem")

local AIManager = {}

-- =========================================================================
-- 常量快捷引用
-- =========================================================================
local DIP = GameConfig.Diplomacy
local AI  = GameConfig.AI

-- =========================================================================
-- AI 人格阈值配置
-- =========================================================================
-- 攻击实力比阈值：超过此比率时AI才考虑宣战
-- 攻击概率：满足实力比后每月宣战的概率
local AI_PERSONALITY = {
    ["霸者"] = {
        attackRatio   = 1.5,   -- 实力比 > 1.5 就考虑进攻
        attackChance  = 0.35,  -- 满足条件时 35% 概率宣战
        peaceRatio    = 0.5,   -- 实力比 < 0.5 才考虑求和
        peaceChance   = 0.3,   -- 求和概率较低（不轻易认输）
        improveChance = 0.05,  -- 很少主动改善关系
    },
    ["守成"] = {
        attackRatio   = 2.0,   -- 只攻击非常弱的邻国
        attackChance  = 0.2,   -- 概率较低
        peaceRatio    = 0.7,   -- 较早考虑求和
        peaceChance   = 0.6,   -- 比较愿意求和
        improveChance = 0.2,   -- 偶尔改善关系
    },
    ["求存"] = {
        attackRatio   = 2.5,   -- 只在绝对优势时进攻（几乎不会）
        attackChance  = 0.1,   -- 极低概率
        peaceRatio    = 0.8,   -- 稍有劣势就求和
        peaceChance   = 0.8,   -- 非常愿意求和
        improveChance = 0.4,   -- 经常改善关系（结交强者）
    },
    ["商贾"] = {
        attackRatio   = 2.0,   -- 不主动进攻，除非对方极弱
        attackChance  = 0.1,   -- 很低概率
        peaceRatio    = 0.7,   -- 较早求和
        peaceChance   = 0.7,   -- 愿意求和
        improveChance = 0.35,  -- 经常改善关系
    },
    ["掠夺"] = {
        attackRatio   = 1.2,   -- 稍有优势就进攻（蛮族好战）
        attackChance  = 0.45,  -- 高概率宣战
        peaceRatio    = 0.4,   -- 只有大幅劣势时才求和
        peaceChance   = 0.2,   -- 很少求和
        improveChance = 0.02,  -- 几乎不改善关系
    },
}

local DEFAULT_PERSONALITY = AI_PERSONALITY["守成"]

-- =========================================================================
-- 内部工具函数
-- =========================================================================

--- 获取势力名称（容错）
---@param factionId number
---@return string
local function factionName(factionId)
    local f = Factions.getById(factionId)
    return f and f.fullName or ("势力#" .. tostring(factionId))
end

--- 判断势力是否存活
---@param gameState table
---@param factionId number
---@return boolean
local function isFactionAlive(gameState, factionId)
    local f = gameState.factions[factionId]
    if not f then return false end
    if f.alive == false then return false end

    -- Use reverse index when available
    if gameState.factionProvinces and gameState.factionProvinces[factionId] then
        return #gameState.factionProvinces[factionId] > 0
    end
    return f.provinces and #f.provinces > 0
end

--- 计算势力的综合军事实力
---@param gameState table
---@param factionId number
---@return number strength
local function calcStrength(gameState, factionId)
    local f = gameState.factions[factionId]
    if not f then return 0 end

    local armySize = f.armySize or 0
    local population = 0
    local provinceCount = 0

    -- Use reverse index when available, fallback to f.provinces
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

--- 获取势力的所有邻国ID列表
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

--- 获取AI人格配置
---@param gameState table
---@param factionId number
---@return table personality
local function getPersonality(gameState, factionId)
    local f = gameState.factions[factionId]
    if not f then return DEFAULT_PERSONALITY end
    return AI_PERSONALITY[f.aiPersonality] or DEFAULT_PERSONALITY
end

--- 向游戏日志追加一条消息
---@param gameState table
---@param msg string
local function addLog(gameState, msg)
    if gameState.addMessage then
        gameState.addMessage(msg, "ai")
    end
end

-- =========================================================================
-- AI 决策子模块
-- =========================================================================

--- AI 处理当前正在进行的战争（考虑求和）
---@param gameState table
---@param factionId number
---@param personality table
local function aiHandleWars(gameState, factionId, personality)
    local myStr = calcStrength(gameState, factionId)

    for fid, f in pairs(gameState.factions) do
        if fid ~= factionId and isFactionAlive(gameState, fid) then
            if DiplomacySystem.isAtWar(gameState, factionId, fid) then
                local enemyStr = calcStrength(gameState, fid)
                local ratio = 0
                if enemyStr > 0 then
                    ratio = myStr / enemyStr
                end

                if ratio < personality.peaceRatio then
                    if math.random() < personality.peaceChance then
                        DiplomacySystem.proposePeace(gameState, factionId, fid)
                    end
                end
            end
        end
    end
end

--- AI 评估是否对邻国宣战
---@param gameState table
---@param factionId number
---@param personality table
local function aiEvaluateWar(gameState, factionId, personality)
    local myStr = calcStrength(gameState, factionId)
    local neighbors = getNeighborFactions(gameState, factionId)

    for _, nid in ipairs(neighbors) do
        if isFactionAlive(gameState, nid) then
            local canWar = DiplomacySystem.canDeclareWar(gameState, factionId, nid)
            if canWar then
                local neighborStr = calcStrength(gameState, nid)
                local ratio = 0
                if neighborStr > 0 then
                    ratio = myStr / neighborStr
                end

                if ratio > personality.attackRatio then
                    local relValue = DiplomacySystem.getRelationValue(gameState, factionId, nid)
                    local relModifier = 1.0
                    if relValue < -50 then
                        relModifier = 1.5
                    elseif relValue > 30 then
                        relModifier = 0.3
                    end

                    if math.random() < personality.attackChance * relModifier then
                        DiplomacySystem.declareWar(gameState, factionId, nid)
                        return  -- 每回合最多宣一次战
                    end
                end
            end
        end
    end
end

--- AI 考虑改善关系
---@param gameState table
---@param factionId number
---@param personality table
local function aiImproveRelations(gameState, factionId, personality)
    if math.random() > personality.improveChance then
        return
    end

    local neighbors = getNeighborFactions(gameState, factionId)
    if #neighbors == 0 then return end

    local bestTarget = nil
    local bestStr = 0
    for _, nid in ipairs(neighbors) do
        if not DiplomacySystem.isAtWar(gameState, factionId, nid) then
            local relValue = DiplomacySystem.getRelationValue(gameState, factionId, nid)
            if relValue < DIP.MAX_RELATION then
                local str = calcStrength(gameState, nid)
                if str > bestStr then
                    bestStr = str
                    bestTarget = nid
                end
            end
        end
    end

    if bestTarget then
        DiplomacySystem.improveRelation(gameState, factionId, bestTarget)
    end
end

--- AI 征兵决策（2026-08-31 修复：征到的兵落入首都/首省驻军，
--- 否则兵力永远停留在国家池，AI 无兵可调）
---@param gameState table
---@param factionId number
local function aiRecruit(gameState, factionId)
    local f = gameState.factions[factionId]
    if not f then return end

    local myStr = calcStrength(gameState, factionId)
    local neighbors = getNeighborFactions(gameState, factionId)

    local needRecruit = false
    for _, nid in ipairs(neighbors) do
        local neighborStr = calcStrength(gameState, nid)
        if neighborStr > 0 and myStr / neighborStr < AI.RECRUIT_THRESHOLD then
            needRecruit = true
            break
        end
    end

    if not needRecruit then
        for fid, _ in pairs(gameState.factions) do
            if fid ~= factionId and DiplomacySystem.isAtWar(gameState, factionId, fid) then
                needRecruit = true
                break
            end
        end
    end

    if not needRecruit then return end

    -- 征兵落点：首都省（无首都则第一个有主省）
    local provList = f.provinces
    if gameState.factionProvinces and gameState.factionProvinces[factionId] then
        provList = gameState.factionProvinces[factionId]
    end
    if not provList or #provList == 0 then return end

    local capProv = gameState.provinces[f.capitalId] or gameState.provinces[provList[1]]
    if not capProv or capProv.isWasteland then
        for _, pid in ipairs(provList) do
            local p = gameState.provinces[pid]
            if p and not p.isWasteland then
                capProv = p
                break
            end
        end
    end
    if not capProv then return end

    -- 与玩家一致：每月征兵上限 = 省人口 × 征兵率
    local batch = GameConfig.Military.RECRUIT_BATCH
    local monthlyMax = math.floor(capProv.population * GameConfig.Military.RECRUIT_RATE)
    local count = math.min(batch, monthlyMax)
    if count <= 0 then return end

    local batches = math.ceil(count / batch)
    local goldCost = GameConfig.Military.RECRUIT_COST_GOLD * batches * 5
    local foodCost = GameConfig.Military.RECRUIT_COST_FOOD * batches * 5
    if (f.gold or 0) < goldCost or (f.food or 0) < foodCost then return end

    f.gold = f.gold - goldCost
    f.food = f.food - foodCost
    f.armySize = (f.armySize or 0) + count
    capProv.garrison = (capProv.garrison or 0) + count

    addLog(gameState,
        factionName(factionId) .. "征兵" .. count .. "人")
end

--- AI 战争执行（2026-08-31 新增：AI 真正调军打仗）
---
--- 修复前：aiMoveArmies 只把"前线省列表"写进 armyDeployment，无人读取，
--- 导致 AI 宣战后从不交火（战争只有宣战没有战斗）。
---
--- 现在每月执行：
---   A. 前线进攻：每个与敌省相邻的己方省，驻军≥ATTACK_MIN_GARRISON 时
---      抽调 ATTACK_MOVE_RATIO 比例进攻驻军最薄弱的相邻敌省
---   B. 后方补给：驻军>SUPPLY_THRESHOLD 的己方后方省，用 BFS 在己方省图
---      上找最近前线，把 SUPPLY_MOVE 兵力向该方向移动一步（逐月前推）
---
---@param gameState table
---@param factionId number
local function aiConductWar(gameState, factionId)
    local f = gameState.factions[factionId]
    if not f then return end

    local provList = f.provinces
    if gameState.factionProvinces and gameState.factionProvinces[factionId] then
        provList = gameState.factionProvinces[factionId]
    end
    if not provList or #provList == 0 then return end

    -- 正在交战的敌国集合
    local enemySet = {}
    local hasWar = false
    for fid, _ in pairs(gameState.factions) do
        if fid ~= factionId and DiplomacySystem.isAtWar(gameState, factionId, fid) then
            enemySet[fid] = true
            hasWar = true
        end
    end
    if not hasWar then return end

    -- 己方省集合 + 前线识别（邻省含敌方省份）
    local ownSet = {}
    for _, pid in ipairs(provList) do ownSet[pid] = true end

    local frontline = {}      -- pid -> true（己方前线省）
    local enemyTargets = {}   -- pid -> {敌省pid, ...}
    for _, pid in ipairs(provList) do
        local prov = gameState.provinces[pid]
        if prov and prov.neighbors then
            for _, nid in ipairs(prov.neighbors) do
                local target = gameState.provinces[nid]
                local owner = target and target.ownerId or nil
                if owner and owner ~= factionId and not target.isWasteland then
                    if enemySet[owner] then
                        frontline[pid] = true
                        enemyTargets[pid] = enemyTargets[pid] or {}
                        enemyTargets[pid][#enemyTargets[pid] + 1] = nid
                    end
                end
            end
        end
    end

    -- 阶段 A：前线进攻（每个前线省每月最多发起一次）
    for _, pid in ipairs(provList) do
        local targets = enemyTargets[pid]
        if targets and #targets > 0 then
            local prov = gameState.provinces[pid]
            local g = prov and prov.garrison or 0
            if g >= AI.ATTACK_MIN_GARRISON then
                -- 挑驻军最薄弱的敌省作为目标
                local target = targets[1]
                local weakest = 1e18
                for _, tid in ipairs(targets) do
                    local tp = gameState.provinces[tid]
                    local tg = tp and tp.garrison or 0
                    if tg < weakest then
                        weakest = tg
                        target = tid
                    end
                end
                local moveSize = math.floor(g * AI.ATTACK_MOVE_RATIO)
                MilitarySystem.moveArmy(gameState, factionId, pid, target, moveSize)
            end
        end
    end

    -- 阶段 B：后方补给（驻军富余的后方省向前线方向移动）
    local needSupply = false
    for _, pid in ipairs(provList) do
        if not frontline[pid] then
            local prov = gameState.provinces[pid]
            local g = prov and prov.garrison or 0
            if g > AI.SUPPLY_THRESHOLD then
                needSupply = true
                break
            end
        end
    end
    if needSupply then
        -- BFS：在己方省图中找某省到最近前线省的路径，返回"第一步"
        ---@param startPid number
        ---@return number|nil nextPid
        local function bfsNextHop(startPid)
            local parent = { [startPid] = false }
            local queue = { startPid }
            local head = 1
            local found = nil
            while head <= #queue and not found do
                local cur = queue[head]
                head = head + 1
                local prov = gameState.provinces[cur]
                if prov and prov.neighbors then
                    for _, nid in ipairs(prov.neighbors) do
                        if parent[nid] == nil and ownSet[nid] then
                            parent[nid] = cur
                            if frontline[nid] then
                                found = nid
                                break
                            end
                            queue[#queue + 1] = nid
                        end
                    end
                end
            end
            if not found then return nil end
            -- 从找到的前线省回溯到起点：返回起点的下一跳
            local node = found
            while parent[node] and parent[node] ~= startPid do
                node = parent[node]
            end
            if parent[node] == startPid then
                return node
            end
            return nil
        end

        for _, pid in ipairs(provList) do
            if not frontline[pid] then
                local prov = gameState.provinces[pid]
                local g = prov and prov.garrison or 0
                if g > AI.SUPPLY_THRESHOLD then
                    local next = bfsNextHop(pid)
                    if next then
                        MilitarySystem.moveArmy(gameState, factionId, pid, next, AI.SUPPLY_MOVE)
                    end
                end
            end
        end
    end
end

-- =========================================================================
-- 公共 API
-- =========================================================================

--- AI 综合决策入口（每月调用一次，由 main.lua 调度）
---@param gameState table
---@param factionId number
function AIManager.processAI(gameState, factionId)
    if not isFactionAlive(gameState, factionId) then return end

    local personality = getPersonality(gameState, factionId)

    -- 阶段 1：处理现有战争（是否求和）
    aiHandleWars(gameState, factionId, personality)

    -- 阶段 2：评估是否宣战
    aiEvaluateWar(gameState, factionId, personality)

    -- 阶段 3：外交改善
    aiImproveRelations(gameState, factionId, personality)

    -- 阶段 4：征兵判断
    aiRecruit(gameState, factionId)

    -- 阶段 5：战争执行（前线进攻 + 后方补给）
    aiConductWar(gameState, factionId)
end

--- 获取某势力的AI人格名称
---@param gameState table
---@param factionId number
---@return string personalityName
function AIManager.getPersonalityName(gameState, factionId)
    local f = gameState.factions[factionId]
    return f and f.aiPersonality or "守成"
end

--- 获取AI人格配置表（供调试/UI显示）
---@param personalityName string
---@return table|nil config
function AIManager.getPersonalityConfig(personalityName)
    return AI_PERSONALITY[personalityName]
end

return AIManager

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
-- 人格参数（2026-09-17 调整：宣战概率整体 ÷6 —— 用户："他怎么经常在打仗"）
--   原来是"每月 35% 概率宣战" → 平均 3 个月就打一仗；现在霸者也只有 6%，
--   加上停战期 5 年（EU4 的 truce）与"关系≥0 不打"的门槛，战争变成稀罕事。
local AI_PERSONALITY = {
    ["霸者"] = {
        attackRatio   = 1.5,   -- 实力比 > 1.5 就考虑进攻
        attackChance  = 0.06,  -- 满足条件时 6% 概率宣战（原 35%）
        peaceRatio    = 0.5,   -- 实力比 < 0.5 才考虑求和
        peaceChance   = 0.3,   -- 求和概率较低（不轻易认输）
        improveChance = 0.05,  -- 很少主动改善关系
    },
    ["守成"] = {
        attackRatio   = 2.0,   -- 只攻击非常弱的邻国
        attackChance  = 0.03,  -- 概率较低（原 20%）
        peaceRatio    = 0.7,   -- 较早考虑求和
        peaceChance   = 0.6,   -- 比较愿意求和
        improveChance = 0.2,   -- 偶尔改善关系
    },
    ["求存"] = {
        attackRatio   = 2.5,   -- 只在绝对优势时进攻（几乎不会）
        attackChance  = 0.02,  -- 极低概率（原 10%）
        peaceRatio    = 0.8,   -- 稍有劣势就求和
        peaceChance   = 0.8,   -- 非常愿意求和
        improveChance = 0.4,   -- 经常改善关系（结交强者）
    },
    ["商贾"] = {
        attackRatio   = 2.0,   -- 不主动进攻，除非对方极弱
        attackChance  = 0.02,  -- 很低概率（原 10%）
        peaceRatio    = 0.7,   -- 较早求和
        peaceChance   = 0.7,   -- 愿意求和
        improveChance = 0.35,  -- 经常改善关系
    },
    ["掠夺"] = {
        attackRatio   = 1.2,   -- 稍有优势就进攻（蛮族好战）
        attackChance  = 0.08,  -- 最高的一档也只有 8%（原 45%）
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

    -- ⚠️ 与 DiplomacySystem.calcStrength 同一个公式，改一处必须改另一处
    --   （2026-09-17 重新配平：兵力 ÷5 后，原来的 `省数×1000`/`人口/10` 会盖过军队本身）
    return armySize + population / 100 + provinceCount * 100
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
                    -- 门槛（2026-09-17，照 EU4 "需要理由"）：关系不算差就不打
                    --   关系 ≥ DECLARE_WAR_MAX_RELATION(0) → 视为无仇，本次不考虑
                    if relValue < (AI.DECLARE_WAR_MAX_RELATION or 0) then
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

    -- 节制 A：冷却（2026-09-17 用户："招出军队速度也太频繁了"）
    --   原来每月都可能征 → 兵力无限滚雪球；现在两次征兵至少隔 RECRUIT_COOLDOWN 个月
    if (f.recruitCooldown or 0) > 0 then
        f.recruitCooldown = f.recruitCooldown - 1
        return
    end

    -- 节制 B：兵力上限（EU4 force limit 思路）—— 国家能养的兵 = 省份数 × 每省上限
    local provList0 = gameState.factionProvinces and gameState.factionProvinces[factionId]
        or f.provinces or {}
    local armyCap = #provList0 * (AI.ARMY_CAP_PER_PROVINCE or 2500)
    if armyCap > 0 and (f.armySize or 0) >= armyCap then
        return
    end

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

    -- 玩家、AI、自动补员共用兵源与费用规则；只从脱战且仍受控制的本国省征召。
    local provList = f.provinces or {}
    local wanted = math.min(GameConfig.Military.RECRUIT_BATCH,
        MilitarySystem.recruitRoom(gameState, f))
    if wanted <= 0 then return end
    local candidates = {}
    if f.capitalId then candidates[#candidates + 1] = f.capitalId end
    for _, pid in ipairs(provList) do
        if pid ~= f.capitalId then candidates[#candidates + 1] = pid end
    end
    for _, pid in ipairs(candidates) do
        if MilitarySystem.canRecruitIn(gameState, factionId, pid) then
            local ok, count = MilitarySystem.recruit(gameState, factionId, pid, wanted)
            if ok then
                f.recruitCooldown = AI.RECRUIT_COOLDOWN or 6
                addLog(gameState, factionName(factionId) .. "征兵" .. count .. "人")
                return
            end
        end
    end
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

    local provList = MilitarySystem.controlledProvinces(gameState, factionId)
    if #provList == 0 then return end

    -- 正在交战的敌国集合
    local enemySet = {}
    local hasWar = false
    for fid, _ in pairs(gameState.factions) do
        if fid ~= factionId and DiplomacySystem.isAtWar(gameState, factionId, fid) then
            enemySet[fid] = true
            hasWar = true
        end
    end
    -- ⚠️ 这里原来写的是 `if not hasWar then return end` —— 和平期直接整个函数返回，
    --   于是 AI **永远不会去占无主白地**（2026-09-26 用户："这些白色可占领区域我们不去占领
    --   然后这些AI也不去"）。现在改成：没仗打也要继续往下走，去抢白地（见下面的白地阶段）。

    -- 输方停手（2026-09-18 用户："±100 不强制结算：输方停手"）
    --   战争分已被打到 −100（= 对方 +100）的敌人 → 这场仗**不再进攻**：
    --   不自动议和、不退出战争，就地停手等对方来结算（玩家随时可点右下角战旗进和谈）
    local WarSystem = require("systems.WarSystem")
    local exhausted = {}      -- enemyId -> true（我在这场的分数已垫底 → 对该敌停手）
    for fid in pairs(enemySet) do
        local war = WarSystem.findWar(gameState, factionId, fid)
        if war and WarSystem.getScore(gameState, war, factionId) <= -99.999 then
            exhausted[fid] = true
        end
    end

    -- 己方省集合 + 前线识别（邻省含敌方省份）
    local ownSet = {}
    for _, pid in ipairs(provList) do ownSet[pid] = true end

    local frontline = {}      -- pid -> true（己方前线省）
    local enemyTargets = {}   -- pid -> {敌省pid, ...}
    local claimTargets = {}   -- pid -> {无主白地pid, ...}（2026-09-26 新增）
    for _, pid in ipairs(provList) do
        local prov = gameState.provinces[pid]
        if prov and prov.neighbors and not (gameState.battles and gameState.battles[pid]) then
            for _, nid in ipairs(prov.neighbors) do
                local target = gameState.provinces[nid]
                local owner = MilitarySystem.controller(target)
                if target and not target.isWasteland and not target.isOcean then
                    if owner and owner ~= factionId then
                        -- 敌省（开战才打）
                        if enemySet[owner] and not exhausted[owner] then
                            frontline[pid] = true
                            enemyTargets[pid] = enemyTargets[pid] or {}
                            enemyTargets[pid][#enemyTargets[pid] + 1] = nid
                        end
                    elseif not owner then
                        -- 无主白地（2026-09-26）：谁都能占，不要求开战
                        claimTargets[pid] = claimTargets[pid] or {}
                        claimTargets[pid][#claimTargets[pid] + 1] = nid
                    end
                end
            end
        end
    end

    -- 阶段 0：抢占无主白地（2026-09-26 用户："这些白色可占领区域…AI也不去"）
    --   白地不设防（garrison = 0），派兵过去直接 occupy —— 和玩家的规则完全一致。
    --   留守要求比打仗低（只需留一点守家），避免 AI 把老本全押出去。
    local CLAIM_KEEP = AI.CLAIM_KEEP_GARRISON or 200
    for _, pid in ipairs(provList) do
        local targets = claimTargets[pid]
        if targets and #targets > 0 then
            local prov = gameState.provinces[pid]
            local g = prov and prov.garrison or 0
            local send = math.floor(g - CLAIM_KEEP)
            if send >= (AI.CLAIM_MIN_TROOPS or 100) then
                -- 白地无人防守，派多少都能占；按比例派但不掏空老本
                local nid = targets[1]
                MilitarySystem.moveArmy(gameState, factionId, pid, nid, send)
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

-- =========================================================================
-- AI 避损耗（2026-09-19 照 CK3）
--
-- CK3 的 AI "极度厌恶损耗"：军队呆在养不起的地方会**主动调走 / 拆兵**。
-- 我们的对应物 = 驻军超过该省补给容量时，把**超出的部分**就近搬到
-- 相邻的、容量还有富余的**自家**省份。
--
-- 简化点（有意为之）：
--   * 瞬间转移（当成"就近调防"，每月只做一次、量不大，不做行军过程）
--   * 只在**明显超编**时才动（超过容量 120%），避免把部队拆得满地图都是
--   * 只对 AI 生效；玩家的兵玩家自己管（CK3 里玩家也是手动拆兵）
-- =========================================================================

---@param gameState table
---@param faction table|nil
---@return number moved 调走的兵力总数
function AIManager.avoidSupplyAttrition(gameState, faction)
    if not gameState or not faction or faction.alive == false then return 0 end
    local list = MilitarySystem.controlledProvinces(gameState, faction.id)
    if #list == 0 then return 0 end

    local moved = 0
    -- 先收集超编的省（边遍历边改 garrison 会让判断错位）
    local overflows = {}
    for i = 1, #list do
        local prov = gameState.provinces[list[i]]
        if prov and not (gameState.battles and gameState.battles[prov.id]) then
            local g = prov.garrison or 0
            local cap = MilitarySystem.supplyCapacity(prov, prov.ownerId == faction.id)
            -- 超过 120% 才动手（轻微的兵不吃亏，别天天搬来搬去）
            if g > cap * 1.2 then
                overflows[#overflows + 1] = { pid = list[i], over = g - cap, prov = prov }
            end
        end
    end
    if #overflows == 0 then return 0 end

    for _, item in ipairs(overflows) do
        local prov = item.prov
        -- 找"容量最富余"的相邻自家省
        local bestPid, bestRoom = nil, 0
        for _, npid in ipairs(prov.neighbors or {}) do
            local np = gameState.provinces[npid]
            if np and MilitarySystem.controller(np) == faction.id
                and not (gameState.battles and gameState.battles[npid]) then
                local room = MilitarySystem.supplyCapacity(np, np.ownerId == faction.id) - (np.garrison or 0)
                if room > bestRoom then
                    bestRoom, bestPid = room, npid
                end
            end
        end
        if bestPid then
            local amount = math.min(item.over, math.floor(bestRoom))
            if amount >= 1 then
                prov.garrison = (prov.garrison or 0) - amount
                local np = gameState.provinces[bestPid]
                MilitarySystem.mergeTroops(np, "garrison", {
                    size = amount, morale = prov.morale,
                    unitMix = require("data.Units").mixOf(prov, faction),
                }, faction)
                moved = moved + amount
            end
        end
    end
    return moved
end

return AIManager

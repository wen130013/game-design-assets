-- ============================================================================
-- 春秋霸业 - 军事系统
-- MilitarySystem.lua
--
-- Handles recruitment, army movement, combat resolution, and province
-- occupation for the Spring and Autumn period grand strategy game.
-- ============================================================================
local GameConfig = require("config.GameConfig")
local LeaderSystem = require("systems.LeaderSystem")
local PolicySystem = require("systems.PolicySystem")

local MilitarySystem = {}

-- ---------------------------------------------------------------------------
-- Shorthand reference to the Military config block
-- ---------------------------------------------------------------------------
local MIL = GameConfig.Military

-- ---------------------------------------------------------------------------
-- Terrain defense multipliers used during combat resolution.
-- Defenders in rough terrain gain a bonus to effective strength.
-- ---------------------------------------------------------------------------
local TERRAIN_DEFENSE = {
    ["山地"] = 1.4,
    ["丘陵"] = 1.2,
    ["森林"] = 1.15,
    ["沼泽"] = 1.1,
}

-- ============================================================================
-- recruit(gameState, factionId, provinceId)
--
-- Recruit one batch of soldiers (RECRUIT_BATCH) from the given province.
--
-- Constraints:
--   * The province must belong to the faction.
--   * The faction must have enough gold and food.
--   * Monthly recruitment is capped at province.population * RECRUIT_RATE.
--
-- Returns: true, recruitedCount   on success
--          false, reason           on failure
-- ============================================================================
function MilitarySystem.recruit(gameState, factionId, provinceId)
    local faction = gameState.factions[factionId]
    if not faction then
        return false, "势力不存在"
    end

    local province = gameState.provinces[provinceId]
    if not province then
        return false, "郡县不存在"
    end

    -- 沙漠化地块无法征兵
    if province.isWasteland then
        return false, "沙漠之地无法征兵"
    end

    -- Verify ownership
    if province.ownerId ~= factionId then
        return false, "该郡县不属于此势力"
    end

    -- Determine how many soldiers we want to recruit (one batch)
    local batchSize = MIL.RECRUIT_BATCH  -- 500

    -- Cap by monthly recruitment limit (population * RECRUIT_RATE * 政策加成)
    local monthlyMax = math.floor(province.population * MIL.RECRUIT_RATE
        * PolicySystem.getRecruitModifier(faction))

    -- Track how many soldiers have already been recruited this month.
    -- gameState.recruitedThisMonth is a table keyed by provinceId.
    gameState.recruitedThisMonth = gameState.recruitedThisMonth or {}
    local alreadyRecruited = gameState.recruitedThisMonth[provinceId] or 0

    local remaining = monthlyMax - alreadyRecruited
    if remaining <= 0 then
        return false, "本月征兵已达上限"
    end

    local count = math.min(batchSize, remaining)

    -- Cost scales linearly with the number of batches.
    -- Base cost is per RECRUIT_BATCH; for a partial batch we still pay full.
    local batches = math.ceil(count / MIL.RECRUIT_BATCH)
    local goldCost = MIL.RECRUIT_COST_GOLD * batches * 5
    local foodCost = MIL.RECRUIT_COST_FOOD * batches * 5

    if faction.gold < goldCost then
        return false, "金不足"
    end
    if faction.food < foodCost then
        return false, "粟不足"
    end

    -- Deduct resources
    faction.gold = faction.gold - goldCost
    faction.food = faction.food - foodCost

    -- Add soldiers
    faction.armySize = faction.armySize + count

    -- Update garrison on the province record
    province.garrison = (province.garrison or 0) + count

    -- Record recruitment this month
    gameState.recruitedThisMonth[provinceId] = alreadyRecruited + count

    return true, count
end

-- ============================================================================
-- moveArmy(gameState, factionId, fromProvinceId, toProvinceId, size)
--
-- Create an army movement order. The army will march from one province to a
-- neighboring province over MOVE_DAYS days (= MOVE_DAYS * 24 hours).
--
-- Returns: true, armyEntry   on success
--          false, reason      on failure
-- ============================================================================
function MilitarySystem.moveArmy(gameState, factionId, fromProvinceId, toProvinceId, size)
    local faction = gameState.factions[factionId]
    if not faction then
        return false, "势力不存在"
    end

    local fromProv = gameState.provinces[fromProvinceId]
    local toProv   = gameState.provinces[toProvinceId]
    if not fromProv then return false, "出发郡县不存在" end
    if not toProv   then return false, "目标郡县不存在" end

    -- 沙漠化地块不可作为目标（军队不能进入废土）
    if toProv.isWasteland then
        return false, "目标为沙漠之地，军队无法进入"
    end

    -- Verify faction owns the source province
    if fromProv.ownerId ~= factionId then
        return false, "出发郡县不属于此势力"
    end

    -- Verify adjacency
    local isNeighbor = false
    for _, nid in ipairs(fromProv.neighbors) do
        if nid == toProvinceId then
            isNeighbor = true
            break
        end
    end
    if not isNeighbor then
        return false, "目标郡县与出发郡县不相邻"
    end

    -- Verify sufficient garrison
    if size <= 0 then
        return false, "调动兵力必须大于零"
    end

    local garrison = fromProv.garrison or 0
    if garrison < size then
        return false, "驻军不足"
    end

    -- Remove from garrison
    fromProv.garrison = garrison - size

    -- Create army entry
    gameState.armies = gameState.armies or {}

    local totalHours = MIL.MOVE_DAYS * 24  -- 72 hours

    local armyEntry = {
        factionId    = factionId,
        from         = fromProvinceId,
        to           = toProvinceId,
        size         = size,
        morale       = MIL.BASE_MORALE,
        progress     = 0,          -- hours elapsed
        totalHours   = totalHours, -- hours needed to arrive
        realElapsed  = 0,          -- 现实秒数（保底行军可见时长用）
    }

    table.insert(gameState.armies, armyEntry)

    return true, armyEntry
end

-- ============================================================================
-- updateArmies(gameState, hoursElapsed, realSeconds)
--
-- Advance all in-transit armies by the given number of hours.
-- 2026-09-01：改为每帧调用（main.lua HandleUpdate），进度连续推进；
--   到达需要同时满足"游戏时长走满"与"现实时间 ≥ MIN_MARCH_REAL_SEC"，
--   保证任何速度档下都能看到军队移动过程（不瞬移）。
-- When an army reaches its destination:
--   * If the target province belongs to the same faction -> reinforce garrison
--   * If the target province belongs to an enemy         -> initiate combat
-- ============================================================================
function MilitarySystem.updateArmies(gameState, hoursElapsed, realSeconds)
    gameState.armies = gameState.armies or {}
    realSeconds = realSeconds or 0

    -- Process in reverse so we can safely remove entries
    for i = #gameState.armies, 1, -1 do
        local army = gameState.armies[i]
        -- 🔧 防御：统一字段访问（moveArmy 用 from/to/totalHours；
        --    GameState.createArmy 曾用 fromProvinceId/toProvinceId，兼容处理）
        local toId = army.to or army.toProvinceId
        local totalHours = army.totalHours
        if not toId or not totalHours then
            -- 非法军队记录：直接移除，避免 nil 比较 / 占 nil 省导致越界
            table.remove(gameState.armies, i)
            goto continueArmy
        end

        army.progress = army.progress + hoursElapsed
        army.realElapsed = (army.realElapsed or 0) + realSeconds

        if army.progress >= totalHours
            and army.realElapsed >= MIL.MIN_MARCH_REAL_SEC then
            -- Army has arrived
            local targetProv = gameState.provinces[toId]
            local targetOwner = targetProv and targetProv.ownerId or nil

            if targetOwner == army.factionId then
                -- Friendly territory: reinforce garrison
                targetProv.garrison = (targetProv.garrison or 0) + army.size
            elseif targetOwner then
                -- Enemy territory: 进入持续战斗（2026-09-01，HoI4 式进度战斗）
                MilitarySystem.startBattle(gameState, army, targetProv, targetOwner)
            else
                -- Unowned province: occupy directly
                MilitarySystem.occupy(gameState, army.factionId, toId)
                targetProv.garrison = (targetProv.garrison or 0) + army.size
            end

            -- Remove army from the marching list
            table.remove(gameState.armies, i)
        end

        ::continueArmy::
    end
end

-- ============================================================================
-- startBattle(gameState, army, targetProv, targetOwner)
--
-- 军队到达敌省：进入持续战斗（HoI4 式进度战斗，2026-09-01）
--   * 同省已有战斗则兵力并入相应方
--   * 新战斗：防守方驻军转入战斗（战斗中驻军由战斗对象接管）
-- ============================================================================
function MilitarySystem.startBattle(gameState, army, targetProv, targetOwner)
    gameState.battles = gameState.battles or {}
    local pid = targetProv.id
    local b = gameState.battles[pid]
    if b then
        -- 已有战斗：兵力并入相应方（第三方并入防守方）
        if b.att.factionId == army.factionId then
            b.att.size = b.att.size + army.size
        else
            b.def.size = b.def.size + army.size
        end
    else
        -- 防守方 = 当前控制者（被占领省由占领者防守，否则原主）
        local defenderId = targetProv.occupiedBy or targetOwner
        gameState.battles[pid] = {
            att = { factionId = army.factionId, size = army.size, morale = army.morale },
            def = { factionId = defenderId, size = targetProv.garrison or 0, morale = MIL.BASE_MORALE },
            progress = 0,   -- -1=防守方完胜 0=均势 +1=攻击方完胜
        }
        -- 防守方驻军转入战斗
        targetProv.garrison = 0
        -- 玩家参战：战斗开始消息 + 战争警报
        local pf = gameState.playerFactionId
        if pf and (army.factionId == pf or defenderId == pf) then
            local atkName = (gameState.factions[army.factionId] or {}).name or "?"
            local defName = (gameState.factions[defenderId] or {}).name or "?"
            local playerSide = army.factionId == pf and "attacker" or "defender"
            if gameState.addMessage then
                gameState.addMessage(
                    string.format("%s进攻%s %s！", atkName, defName, targetProv.name or "?"), "war")
            end
            if gameState.pushWarAlert then
                gameState.pushWarAlert({
                    kind = "battle_started",
                    provinceId = pid,
                    attackerId = army.factionId,
                    defenderId = defenderId,
                    provinceName = targetProv.name or "未知省份",
                    attackerName = atkName,
                    defenderName = defName,
                    playerSide = playerSide,
                    text = playerSide == "defender"
                        and ("我方领地遭到 " .. atkName .. " 进攻")
                        or ("我军正在进攻 " .. defName),
                })
            end
        end
    end
end

-- ============================================================================
-- processBattles(gameState, hoursElapsed)
--
-- 每帧推进所有进行中的战斗（main.lua HandleUpdate 调用）：
--   * 按双方有效强度（兵力×士气×君主/政策修正×地形）计算每日损失与进度
--   * progress 偏向攻击方(+)或防守方(-)，走满 ±1 或兵力归零则分胜负
--   * 攻击方胜 → 占领并留驻；防守方胜 → 击退，攻击方剩余兵力被歼灭
--   * 仅玩家参战时写消息（AI 互打不刷屏）
-- ============================================================================
function MilitarySystem.processBattles(gameState, hoursElapsed)
    if not gameState.battles then return end
    local dtDays = hoursElapsed / 24

    for pid, b in pairs(gameState.battles) do
        local province = gameState.provinces[pid]
        if not province then
            gameState.battles[pid] = nil
            goto continueBattle
        end

        local terrainMod = TERRAIN_DEFENSE[province.terrain] or 1.0
        local atkFac = gameState.factions[b.att.factionId]
        local defFac = gameState.factions[b.def.factionId]
        local atkMod = LeaderSystem.getMilitaryModifier(atkFac)
            * PolicySystem.getMilitaryModifier(atkFac)
        local defMod = LeaderSystem.getMilitaryModifier(defFac)
            * PolicySystem.getMilitaryModifier(defFac)
            * PolicySystem.getDefenseModifier(defFac)

        local atkStr = b.att.size * (b.att.morale or MIL.BASE_MORALE) / 100 * atkMod
        local defStr = b.def.size * (b.def.morale or MIL.BASE_MORALE) / 100 * terrainMod * defMod
        local total = atkStr + defStr

        if total <= 0 then
            -- 双方皆无战力：攻击方默认胜
            b.def.size = 0
            atkStr, defStr, total = 1, 0, 1
        end

        -- 双方损失（按强度比，每日最多约 30%）
        local attLoss = math.min(b.att.size, math.floor(defStr / total * b.att.size * 0.3 * dtDays))
        local defLoss = math.min(b.def.size, math.floor(atkStr / total * b.def.size * 0.3 * dtDays))
        b.att.size = math.max(0, b.att.size - attLoss)
        b.def.size = math.max(0, b.def.size - defLoss)
        if atkFac then atkFac.armySize = math.max(0, (atkFac.armySize or 0) - attLoss) end
        if defFac then defFac.armySize = math.max(0, (defFac.armySize or 0) - defLoss) end

        -- 战斗进度推进（每日 ±0.5 封顶）
        local adv = (atkStr - defStr) / total
        b.progress = math.max(-1, math.min(1, b.progress + adv * dtDays * 0.5))

        -- 胜负判定（2026-09-01：攻击方胜→占领标记 occupiedBy，不立即吞并；
        --   领土在和平条约时正式割让）
        local ended = false
        local winner, loser = nil, nil
        if b.att.size <= 0 then
            winner, loser = b.def.factionId, b.att.factionId
            province.garrison = b.def.size
            province.occupiedBy = nil   -- 击退占领者
            ended = true
        elseif b.def.size <= 0 then
            winner, loser = b.att.factionId, b.def.factionId
            province.occupiedBy = b.att.factionId
            province.garrison = b.att.size
            ended = true
        elseif b.progress >= 1.0 then
            winner, loser = b.att.factionId, b.def.factionId
            province.occupiedBy = b.att.factionId
            province.garrison = b.att.size
            if defFac then defFac.armySize = math.max(0, (defFac.armySize or 0) - b.def.size) end
            ended = true
        elseif b.progress <= -1.0 then
            winner, loser = b.def.factionId, b.att.factionId
            province.garrison = b.def.size
            province.occupiedBy = nil
            if atkFac then atkFac.armySize = math.max(0, (atkFac.armySize or 0) - b.att.size) end
            ended = true
        end

        if ended then
            gameState.battles[pid] = nil
            -- 威望变化
            if winner and loser then
                local wFac = gameState.factions[winner]
                local lFac = gameState.factions[loser]
                if wFac then wFac.prestige = (wFac.prestige or 0) + 8 end
                if lFac then lFac.prestige = math.max(0, (lFac.prestige or 0) - 8) end
            end
            -- 玩家参战：战斗结束消息 + 战争警报
            local pf = gameState.playerFactionId
            if pf and (b.att.factionId == pf or b.def.factionId == pf) then
                local wName = (gameState.factions[winner] or {}).name or "?"
                local lName = (gameState.factions[loser] or {}).name or "?"
                local provName = province.name or "?"
                local playerLostProvince = b.def.factionId == pf and winner == b.att.factionId
                local msg = string.format("%s之战结束，%s战胜%s", provName, wName, lName)
                if winner == pf then
                    msg = msg .. "（我军胜利！）"
                else
                    msg = msg .. "（我军失利）"
                end
                if playerLostProvince then
                    msg = msg .. "（领地失守）"
                end
                if gameState.addMessage then gameState.addMessage(msg, "war") end
                if gameState.pushWarAlert then
                    gameState.pushWarAlert({
                        kind = playerLostProvince and "province_lost" or "battle_finished",
                        provinceId = pid,
                        attackerId = b.att.factionId,
                        defenderId = b.def.factionId,
                        winnerId = winner,
                        loserId = loser,
                        provinceName = provName,
                        attackerName = (gameState.factions[b.att.factionId] or {}).name or "?",
                        defenderName = (gameState.factions[b.def.factionId] or {}).name or "?",
                        winnerName = wName,
                        loserName = lName,
                        playerSide = b.att.factionId == pf and "attacker" or "defender",
                        text = playerLostProvince
                            and ("我方失去 " .. provName .. "，敌军已经控制该地")
                            or (provName .. "的战斗已经结束"),
                    })
                end
            end
        end

        ::continueBattle::
    end
end


-- ============================================================================
-- occupy(gameState, factionId, provinceId)
--
-- Transfer ownership of a province to a new faction.
--   * Removes the province from the old faction's provinces list
--   * Adds the province to the new faction's provinces list
--   * Updates province.ownerId to the new faction
--   * Drops province stability to 30
--   * Checks if the old faction has lost all provinces (elimination)
-- ============================================================================
function MilitarySystem.occupy(gameState, factionId, provinceId)
    local newFaction = gameState.factions[factionId]
    if not newFaction then return end

    local province = gameState.provinces[provinceId]
    local oldFactionId = province and province.ownerId or nil

    -- Remove from old faction
    if oldFactionId then
        local oldFaction = gameState.factions[oldFactionId]
        if oldFaction then
            for i = #oldFaction.provinces, 1, -1 do
                if oldFaction.provinces[i] == provinceId then
                    table.remove(oldFaction.provinces, i)
                    break
                end
            end
        end
        -- Update reverse index
        if gameState.factionProvinces and gameState.factionProvinces[oldFactionId] then
            local idx = gameState.factionProvinces[oldFactionId]
            for i = #idx, 1, -1 do
                if idx[i] == provinceId then
                    table.remove(idx, i)
                    break
                end
            end
        end
    end

    -- Add to new faction (avoid duplicate)
    local alreadyOwned = false
    for _, pid in ipairs(newFaction.provinces) do
        if pid == provinceId then
            alreadyOwned = true
            break
        end
    end
    if not alreadyOwned then
        table.insert(newFaction.provinces, provinceId)
    end
    -- Update reverse index
    if gameState.factionProvinces then
        if not gameState.factionProvinces[factionId] then
            gameState.factionProvinces[factionId] = {}
        end
        local idx = gameState.factionProvinces[factionId]
        local found = false
        for _, pid in ipairs(idx) do
            if pid == provinceId then found = true; break end
        end
        if not found then
            idx[#idx + 1] = provinceId
        end
    end

    -- Update province ownership in runtime state
    if province then
        province.ownerId = factionId
    end

    -- Province stability drops to 30 upon occupation
    if province then
        province.stability = 30
    end

    -- Check if old faction is eliminated (no provinces left)
    if oldFactionId and oldFactionId ~= factionId then
        local oldFaction = gameState.factions[oldFactionId]
        if oldFaction and #oldFaction.provinces == 0 then
            gameState.eliminatedFactions = gameState.eliminatedFactions or {}
            gameState.eliminatedFactions[oldFactionId] = true

            -- Record elimination event
            gameState.events = gameState.events or {}
            table.insert(gameState.events, {
                type    = "faction_eliminated",
                faction = oldFactionId,
                by      = factionId,
                name    = oldFaction.fullName or oldFaction.name,
            })
        end
    end
end

-- ============================================================================
-- getArmyStrength(factionId, gameState)
--
-- Calculate the total military strength of a faction, accounting for:
--   * Standing army size
--   * Armies currently in transit
--   * Garrison distribution
--
-- Returns: a table with detailed breakdown
-- ============================================================================
function MilitarySystem.getArmyStrength(factionId, gameState)
    local faction = gameState.factions[factionId]
    if not faction then
        return { total = 0, standing = 0, marching = 0, garrisons = {} }
    end

    -- Total army from faction record
    local standing = faction.armySize

    -- Count soldiers currently marching
    local marching = 0
    gameState.armies = gameState.armies or {}
    for _, army in ipairs(gameState.armies) do
        if army.factionId == factionId then
            marching = marching + army.size
        end
    end

    -- Gather garrison counts for each owned province
    local garrisonDetails = {}
    for _, pid in ipairs(faction.provinces) do
        local prov = gameState.provinces[pid]
        garrisonDetails[pid] = prov and prov.garrison or 0
    end

    -- Total garrison
    local totalGarrison = 0
    for _, g in pairs(garrisonDetails) do
        totalGarrison = totalGarrison + g
    end

    return {
        total      = standing,
        standing   = standing,
        marching   = marching,
        garrison   = totalGarrison,
        garrisons  = garrisonDetails,
    }
end

return MilitarySystem

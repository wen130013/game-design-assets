-- 驻军、征召与补给的共用规则；正式归属与军事控制权分开。
local GameConfig = require("config.GameConfig")
local Modifiers = require("systems.Modifiers")
local Units = require("data.Units")
local MIL = GameConfig.Military
local Logistics = {}

local SUPPLY_BASE = {
    ["平原"] = 5000, ["草原"] = 4000, ["丘陵"] = 3000, ["森林"] = 3000,
    ["山地"] = 2000, ["沼泽"] = 2000, ["沙漠"] = 1000, ["农田"] = 6000,
    ["针叶林"] = 2500, ["丛林"] = 1500, ["冻土"] = 1000,
}

---@param province table|nil
---@return number|nil
function Logistics.controller(province)
    return province and (province.occupiedBy or province.ownerId) or nil
end

---@param gameState table
---@param factionId number
---@return number[]
function Logistics.controlledProvinces(gameState, factionId)
    local ids = {}
    for pid, p in pairs(gameState.provinces or {}) do
        if not p.isOcean and not p.isWasteland and Logistics.controller(p) == factionId then
            ids[#ids + 1] = pid
        end
    end
    table.sort(ids)
    return ids
end

--- 并兵同时加权构成和士气，转移不改变国家总兵力。
---@param target table
---@param field string garrison 或 size
---@param incoming table
---@param faction table|nil
function Logistics.mergeTroops(target, field, incoming, faction)
    local before, add = target[field] or 0, incoming.size or 0
    if add <= 0 then return end
    Units.mergeMix(target, before, incoming.unitMix, add, faction)
    target.morale = (before * (target.morale or MIL.BASE_MORALE)
        + add * (incoming.morale or MIL.BASE_MORALE)) / (before + add)
    target[field] = before + add
end

---@param province table
---@param isFriendly boolean|nil
---@return number
function Logistics.supplyCapacity(province, isFriendly)
    if not province then return 0 end
    local cap = (SUPPLY_BASE[province.terrain] or 3000)
        + math.floor((province.population or 0) / 1000) * 150
    return math.floor(cap * (isFriendly and 1.3 or 1.0))
end

--- 一次安装，保留 MilitarySystem 的公开接口，避免循环 require。
---@param MilitarySystem table
function Logistics.install(MilitarySystem)
    MilitarySystem.controller = Logistics.controller
    MilitarySystem.controlledProvinces = Logistics.controlledProvinces
    MilitarySystem.mergeTroops = Logistics.mergeTroops
    MilitarySystem.supplyCapacity = Logistics.supplyCapacity

    function MilitarySystem.canRecruitIn(gameState, factionId, provinceId)
        local p = gameState.provinces[provinceId]
        return p ~= nil and not p.isOcean and not p.isWasteland
            and p.ownerId == factionId and Logistics.controller(p) == factionId
            and not (gameState.battles and gameState.battles[provinceId])
    end

    function MilitarySystem.manpowerCapacity(gameState, faction, province)
        return math.max(0, Modifiers.apply((province.population or 0) * (MIL.MANPOOL_RATIO or 0.15),
            "faction", "recruit", { gameState = gameState, faction = faction }))
    end

    --- AI 的财政兵力目标也约束自动补员；玩家仍自行决定规模。
    function MilitarySystem.recruitRoom(gameState, faction)
        if gameState.playerFactionId == faction.id then return math.huge end
        local provinces = faction.provinces or {}
        local cap = #provinces * (GameConfig.AI.ARMY_CAP_PER_PROVINCE or 500)
        return math.max(0, cap - (faction.armySize or 0))
    end

    function MilitarySystem.recruitRate(faction)
        local factor = (Units.mainOf(faction).maintenance or 0.4) / 0.4
        return (MIL.RECRUIT_COST_GOLD or 20) * 5 * factor,
               (MIL.RECRUIT_COST_FOOD or 30) * 5 * factor
    end

    function MilitarySystem.recruitCostFor(faction, count)
        local gold, food = MilitarySystem.recruitRate(faction)
        local n = math.max(0, math.floor(count))
        return math.ceil(gold * n / 1000), math.ceil(food * n / 1000)
    end

    --- 玩家、AI、补员共用一次扣费/扣兵源/扣人口的事务。
    --- keepMix=true 是补员：保留原兵种比例和原士气，不用新兵洗满士气。
    function MilitarySystem.recruit(gameState, factionId, provinceId, wanted, keepMix)
        local faction = gameState.factions[factionId]
        local p = gameState.provinces[provinceId]
        if not faction then return false, "势力不存在" end
        if not p then return false, "郡县不存在" end
        if not MilitarySystem.canRecruitIn(gameState, factionId, provinceId) then
            return false, "只能在本国控制且未交战的郡县征召"
        end
        local requested = math.floor(wanted or MIL.RECRUIT_BATCH)
        if requested <= 0 then return false, "征召人数必须大于零" end
        gameState.manpower = gameState.manpower or {}
        local maxPool = MilitarySystem.manpowerCapacity(gameState, faction, p)
        local recorded = gameState.manpower[provinceId]
        local pool = math.min(recorded == nil and maxPool or recorded, maxPool)
        local goldRate, foodRate = MilitarySystem.recruitRate(faction)
        -- 费用向上取整，所以支付能力必须先取整钱粮再反推人数。
        local goldRoom = goldRate > 0 and math.floor(math.floor(faction.gold or 0) * 1000 / goldRate) or math.huge
        local foodRoom = foodRate > 0 and math.floor(math.floor(faction.food or 0) * 1000 / foodRate) or math.huge
        local count = math.floor(math.min(requested, pool, p.population or 0,
            goldRoom, foodRoom, MilitarySystem.recruitRoom(gameState, faction)))
        if count <= 0 then return false, "兵源、钱粮不足或已达兵力目标" end
        local goldCost, foodCost = MilitarySystem.recruitCostFor(faction, count)
        faction.gold = (faction.gold or 0) - goldCost
        faction.food = (faction.food or 0) - foodCost
        local oldMix = Units.mixOf(p, faction)
        p.garrison = (p.garrison or 0) + count
        if keepMix then
            p.unitMix = oldMix
        else
            Units.addTroops(p, faction, Units.mainOf(faction).id, count)
        end
        faction.armySize = (faction.armySize or 0) + count
        gameState.manpower[provinceId] = math.max(0, pool - count)
        p.population = math.max(0, (p.population or 0) - count)
        print(string.format("[Military] %s 省%d %s%d，金-%d 粮-%d，兵源余%.0f",
            tostring(faction.name), provinceId, keepMix and "补员" or "征召", count,
            goldCost, foodCost, gameState.manpower[provinceId]))
        return true, count
    end

    function MilitarySystem.commanderCapacity(gameState, faction, provinceId)
        if not gameState or not faction then return nil end
        local id = faction.provinceCommanders and faction.provinceCommanders[provinceId]
        if not id then return nil end
        local c = require("systems.CharacterSystem").getById(gameState, id)
        if not c or not c.alive then return nil end
        return (c.military or 3) * (MIL.COMMANDER_TROOPS_PER_MILITARY or 500)
    end

    function MilitarySystem.setProvinceCommander(gameState, factionId, provinceId, charId)
        if not gameState or not factionId or not provinceId then return false, "参数不全" end
        local faction = gameState.factions[factionId]
        local p = gameState.provinces[provinceId]
        if not faction then return false, "势力不存在" end
        if not p or Logistics.controller(p) ~= factionId then return false, "不是本国控制的省" end
        faction.provinceCommanders = faction.provinceCommanders or {}
        if charId == nil then faction.provinceCommanders[provinceId] = nil; return true, "已卸任" end
        local c = require("systems.CharacterSystem").getById(gameState, charId)
        if not c or not c.alive then return false, "人物不存在" end
        if c.factionId ~= factionId then return false, "不是本国人物" end
        faction.provinceCommanders[provinceId] = charId
        c.post = c.post or "将军"
        return true, string.format("%s 就任 %s 驻军统帅（统兵上限 %d）",
            tostring(c.name), tostring(p.name),
            (c.military or 3) * (MIL.COMMANDER_TROOPS_PER_MILITARY or 500))
    end

    function MilitarySystem.getProvinceCommander(gameState, factionId, provinceId)
        local faction = gameState and gameState.factions and gameState.factions[factionId]
        local id = faction and faction.provinceCommanders and faction.provinceCommanders[provinceId]
        if not id then return nil end
        local c = require("systems.CharacterSystem").getById(gameState, id)
        if c and c.alive then return c end
        return nil
    end

    function MilitarySystem.autoReplenish(gameState, faction)
        if not gameState or not faction then return 0 end
        local added = 0
        for _, pid in ipairs(faction.provinces or {}) do
            if MilitarySystem.canRecruitIn(gameState, faction.id, pid) then
                local p = gameState.provinces[pid]
                local cap = MilitarySystem.commanderCapacity(gameState, faction, pid)
                if cap and cap > (p.garrison or 0) then
                    local want = math.max(1, math.floor((cap - (p.garrison or 0)) * (MIL.REPLENISH_RATE or 0.25)))
                    local ok, count = MilitarySystem.recruit(gameState, faction.id, pid, want, true)
                    if ok then added = added + count end
                end
            end
        end
        return added
    end

    function MilitarySystem.applySupply(gameState, faction)
        if not gameState or not faction then return 0 end
        local lost = 0
        for _, pid in ipairs(Logistics.controlledProvinces(gameState, faction.id)) do
            local p = gameState.provinces[pid]
            local g = p.garrison or 0
            local cap = Logistics.supplyCapacity(p, p.ownerId == faction.id)
            if g > cap and not (gameState.battles and gameState.battles[pid]) then
                local loss = math.min(g, math.max(1, math.floor((g - cap) * (MIL.SUPPLY_ATTRITION or 0.08))))
                p.garrison = g - loss
                lost = lost + loss
            end
        end
        faction.armySize = math.max(0, (faction.armySize or 0) - lost)
        MilitarySystem.autoReplenish(gameState, faction)
        return lost
    end
end

return Logistics

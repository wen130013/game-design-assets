--- EconomySystem.lua
--- Monthly economic processing for the Spring and Autumn grand strategy game.
--- Handles tax collection, food production, army upkeep, desertion, and population growth.

local EconomySystem = {}

local GameConfig = require("config.GameConfig")
local TimeSystem = require("core.TimeSystem")
local LeaderSystem = require("systems.LeaderSystem")
local PolicySystem = require("systems.PolicySystem")

----------------------------------------------------------------------------
-- Terrain bonuses: { goldMultiplier, foodMultiplier }
----------------------------------------------------------------------------
local TERRAIN_BONUS = {
    ["平原"] = { gold = 1.0, food = 1.2 },
    ["丘陵"] = { gold = 0.9, food = 0.9 },
    ["山地"] = { gold = 0.7, food = 0.6 },
    ["森林"] = { gold = 0.8, food = 1.0 },
    ["沿海"] = { gold = 1.3, food = 0.8 },
    ["沼泽"] = { gold = 0.5, food = 0.7 },
}

----------------------------------------------------------------------------
-- Season food multipliers (1-indexed: 1=spring, 2=summer, 3=autumn, 4=winter)
----------------------------------------------------------------------------
local SEASON_FOOD_MULTIPLIER = {
    [1] = 0.8,   -- spring
    [2] = 1.0,   -- summer
    [3] = 1.5,   -- autumn (harvest)
    [4] = 0.5,   -- winter
}

--- Convenience: map season name strings to the same values for flexible lookup.
local SEASON_NAME_MULTIPLIER = {
    ["春"] = 0.8,
    ["夏"] = 1.0,
    ["秋"] = 1.5,
    ["冬"] = 0.5,
}

----------------------------------------------------------------------------
-- Desertion rate when food is negative (fraction of army lost per month)
----------------------------------------------------------------------------
local DESERTION_RATE = 0.05

----------------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------------

--- Resolve the terrain bonus table for a province. Falls back to neutral 1.0/1.0.
---@param province table
---@return table {gold: number, food: number}
local function getTerrainBonus(province)
    local terrain = province.terrain or "平原"
    return TERRAIN_BONUS[terrain] or { gold = 1.0, food = 1.0 }
end

--- Resolve the season food multiplier from either a numeric index (1-4) or a
--- single-character season name ("春"/"夏"/"秋"/"冬").
---@param season number|string
---@return number
local function getSeasonMultiplier(season)
    if type(season) == "number" then
        return SEASON_FOOD_MULTIPLIER[season] or 1.0
    end
    if type(season) == "string" then
        return SEASON_NAME_MULTIPLIER[season] or 1.0
    end
    return 1.0
end

--- Look up the tax-rate entry from GameConfig. Returns the entry table and the
--- rate multiplier separately for convenience.
---@param faction table
---@return table taxEntry
---@return number rateMultiplier
local function getTaxEntry(faction)
    local economy = GameConfig.Economy
    local taxRates = economy and economy.TAX_RATES
    if not taxRates then
        -- Fallback: standard tax
        return { name = "标准", rate = 1.0, stability = 0, growth = 0 }, 1.0
    end
    ---@type table<number, table>
    local taxTable = taxRates
    local idx = faction.taxLevel or (economy.DEFAULT_TAX or 2)
    local entry = taxTable[idx]
    if not entry then
        entry = taxTable[2] or { name = "标准", rate = 1.0, stability = 0, growth = 0 }
    end
    return entry, entry.rate
end

--- Gather all provinces under a faction's control:
---   * 自己拥有的省（ownerId）
---   * 被自己占领的省（occupiedBy，2026-09-01：占领期间产出归占领方）
---@param gameState table
---@param factionId any
---@return table[] provinces
local function getOwnedProvinces(gameState, factionId)
    ---@type table[]
    local result = {}
    local seen = {}
    -- 自己拥有的省
    if gameState.factionProvinces and gameState.factionProvinces[factionId] then
        ---@type table<number, table>
        local gsProvs = gameState.provinces or {}
        for _, pid in ipairs(gameState.factionProvinces[factionId]) do
            local prov = gsProvs[pid]
            if prov then
                result[#result + 1] = prov
                seen[pid] = true
            end
        end
    end
    -- 被自己占领的省（产出归占领方）
    ---@type table<number, table>
    local provinces = gameState.provinces or {}
    for _, prov in pairs(provinces) do
        if prov.occupiedBy == factionId and not seen[prov.id] then
            result[#result + 1] = prov
        end
    end
    return result
end

----------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------

--- Calculate the gold and food income for a single province under a given tax
--- rate entry.  Does NOT include army upkeep.
---@param province table  Province data (fields: baseGold, baseFood, terrain)
---@param taxEntry  table  A row from GameConfig.Economy.TAX_RATES
---@param season    number|string  Current season (1-4 or name)
---@return number goldIncome
---@return number foodIncome
function EconomySystem.getProvinceIncome(province, taxEntry, season)
    -- 沙漠化地块：无任何产出（历史时代3 式废土）
    if province.isWasteland then
        return 0, 0
    end
    local terrain = getTerrainBonus(province)
    local rateMultiplier = type(taxEntry) == "table" and taxEntry.rate or 1.0
    local seasonMul = getSeasonMultiplier(season)

    local goldIncome = (province.baseGold or 0) * rateMultiplier * terrain.gold
    local foodIncome = (province.baseFood or 0) * seasonMul * terrain.food

    return goldIncome, foodIncome
end

--- Build a full economic summary for one faction without mutating game state.
---@param gameState table
---@param factionId any
---@return table summary {income, foodIncome, armyUpkeepGold, armyUpkeepFood, netGold, netFood}
function EconomySystem.getFactionSummary(gameState, factionId)
    local faction = nil
    local factions = gameState.factions or {}
    for _, f in pairs(factions) do
        if f.id == factionId then
            faction = f
            break
        end
    end
    if not faction then
        return {
            income = 0, foodIncome = 0,
            armyUpkeepGold = 0, armyUpkeepFood = 0,
            netGold = 0, netFood = 0,
        }
    end

    local economy = GameConfig.Economy or {}
    local armyGoldCost = economy.ARMY_GOLD_COST or 5
    local armyFoodCost = economy.ARMY_FOOD_COST or 8

    local taxEntry, _ = getTaxEntry(faction)
    local season = TimeSystem.getSeason()

    local provinces = getOwnedProvinces(gameState, factionId)
    local totalGold = 0
    local totalFood = 0
    for i = 1, #provinces do
        local g, f = EconomySystem.getProvinceIncome(provinces[i], taxEntry, season)
        totalGold = totalGold + g
        totalFood = totalFood + f
    end
    -- 君主文治修正（预览与结算保持一致）
    totalGold = totalGold * LeaderSystem.getAdminModifier(faction)
    -- 政策/变法修正
    totalGold = totalGold * PolicySystem.getGoldModifier(faction)
    totalFood = totalFood * PolicySystem.getFoodModifier(faction)

    local armySize = faction.armySize or 0
    local armyUnits = armySize / 1000
    local upkeepGold = armyUnits * armyGoldCost
    local upkeepFood = armyUnits * armyFoodCost

    return {
        income         = totalGold,
        foodIncome     = totalFood,
        armyUpkeepGold = upkeepGold,
        armyUpkeepFood = upkeepFood,
        netGold        = totalGold - upkeepGold,
        netFood        = totalFood - upkeepFood,
    }
end

--- Main entry point: process one game month for every alive faction.
--- Mutates gameState in place (faction gold/food/armySize/morale, province population).
---@param gameState table  The authoritative game-state table.
function EconomySystem.processMonth(gameState)
    local economy = GameConfig.Economy or {}
    local armyGoldCost = economy.ARMY_GOLD_COST or 5
    local armyFoodCost = economy.ARMY_FOOD_COST or 8
    local season = TimeSystem.getSeason()

    local factions = gameState.factions or {}

    for _, faction in pairs(factions) do

        -- Skip dead factions
        if faction.alive == false then
            goto continueFaction
        end

        local taxEntry, _ = getTaxEntry(faction)
        local provinces = getOwnedProvinces(gameState, faction.id)

        ----------------------------------------------------------------
        -- 1. Income from provinces
        ----------------------------------------------------------------
        local totalGoldIncome = 0
        local totalFoodIncome = 0

        for pi = 1, #provinces do
            local prov = provinces[pi]
            local g, f = EconomySystem.getProvinceIncome(prov, taxEntry, season)
            totalGoldIncome = totalGoldIncome + g
            totalFoodIncome = totalFoodIncome + f
        end
        -- 君主文治修正：admin 影响财政收入
        totalGoldIncome = totalGoldIncome * LeaderSystem.getAdminModifier(faction)
        -- 政策/变法修正
        totalGoldIncome = totalGoldIncome * PolicySystem.getGoldModifier(faction)
        totalFoodIncome = totalFoodIncome * PolicySystem.getFoodModifier(faction)

        ----------------------------------------------------------------
        -- 2. Army upkeep
        ----------------------------------------------------------------
        local armySize = faction.armySize or 0
        local armyUnits = armySize / 1000
        local upkeepGold = armyUnits * armyGoldCost
        local upkeepFood = armyUnits * armyFoodCost

        ----------------------------------------------------------------
        -- 3. Apply net income
        ----------------------------------------------------------------
        faction.gold = (faction.gold or 0) + totalGoldIncome - upkeepGold
        faction.food = (faction.food or 0) + totalFoodIncome - upkeepFood

        ----------------------------------------------------------------
        -- 4. Negative-food consequences: morale loss + desertion
        ----------------------------------------------------------------
        if faction.food < 0 then
            -- Morale penalty (clamped to 0)
            faction.morale = math.max(0, (faction.morale or 100) - 10)

            -- Desertion: lose 5% of army
            local deserted = math.floor(armySize * DESERTION_RATE)
            faction.armySize = math.max(0, armySize - deserted)
        end

        ----------------------------------------------------------------
        -- 5. Population growth per province (affected by tax level + policies)
        ----------------------------------------------------------------
        local growthModifier = taxEntry.growth or 0  -- e.g. +0.005 or -0.01
        -- 政策/变法人口增长加成（如轻徭 +20%）
        local popMod = 1.0 + PolicySystem.getPopGrowthModifier(faction)
        for pi = 1, #provinces do
            local prov = provinces[pi]
            local pop = prov.population or 0
            local baseGrowthRate = prov.baseGrowthRate or 0.002
            local effectiveRate = (baseGrowthRate + growthModifier) * popMod

            local growth = math.floor(pop * effectiveRate)
            prov.population = math.max(0, pop + growth)
        end

        ----------------------------------------------------------------
        -- 6. Stability adjustment from tax level + policies (仁政/严法)
        ----------------------------------------------------------------
        local stabilityDelta = (taxEntry.stability or 0)
            + PolicySystem.getStabilityDelta(faction)
        if stabilityDelta ~= 0 then
            local current = faction.stability or 0
            faction.stability = math.max(-100, math.min(100, current + stabilityDelta))
        end

        ----------------------------------------------------------------
        -- 7. 附庸进贡（2026-09-01）：附庸每月上贡 10% 金/粮给宗主
        ----------------------------------------------------------------
        if faction.vassalOf then
            local suzerain = gameState.factions[faction.vassalOf]
            if suzerain and suzerain.alive ~= false then
                local tribute = math.floor((faction.gold or 0) * 0.1)
                local tributeFood = math.floor((faction.food or 0) * 0.1)
                faction.gold = (faction.gold or 0) - tribute
                faction.food = (faction.food or 0) - tributeFood
                suzerain.gold = (suzerain.gold or 0) + tribute
                suzerain.food = (suzerain.food or 0) + tributeFood
            end
        end

        ::continueFaction::
    end
end

return EconomySystem

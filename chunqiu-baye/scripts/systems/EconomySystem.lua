--- EconomySystem.lua
--- Monthly economic processing for the Spring and Autumn grand strategy game.
--- Handles tax collection, food production, army upkeep, desertion, and population growth.

local EconomySystem = {}

local GameConfig = require("config.GameConfig")
local TimeSystem = require("core.TimeSystem")
local LeaderSystem = require("systems.LeaderSystem")
local PolicySystem = require("systems.PolicySystem")
local Modifiers = require("systems.Modifiers")
local MilitaryLedger = require("systems.MilitaryLedger")
local CultureSystem = require("systems.CultureSystem")   -- 副作用：往管道注册"文化不满"规则

-- ---------------------------------------------------------------------------
-- 修正器管道登记（2026-09-13）
--   把原来"手写在公式里"的加成搬成管道规则 —— 运算方式用 scale（连乘），
--   与原来 `total × 君主 × 政策` 完全等价 → **数值一点没变**，
--   但从此资源/事件/模组都能往同一个键上加东西。
-- ---------------------------------------------------------------------------
Modifiers.rule{
    scope = "faction", key = "goldIncome", op = "scale", source = "leader:admin",
    value = function(_, ctx) return LeaderSystem.getAdminModifier(ctx.faction) end,
}
Modifiers.rule{
    scope = "faction", key = "goldIncome", op = "scale", source = "policy:gold",
    value = function(_, ctx) return PolicySystem.getGoldModifier(ctx.faction) end,
}
Modifiers.rule{
    scope = "faction", key = "foodIncome", op = "scale", source = "policy:food",
    value = function(_, ctx) return PolicySystem.getFoodModifier(ctx.faction) end,
}
-- 洞 4（2026-09-14）：人口增长也接进管道
--   原来是 `1.0 + PolicySystem.getPopGrowthModifier(fac)` 硬写在公式里 →
--   模组挂 popGrowth **不会生效**。现在注册成 scale 规则，调用方读管道。
--   （scale 值 = 1.0 + Σ政策，和原来那个式子一模一样 → 数值不变）
Modifiers.rule{
    scope = "faction", key = "popGrowth", op = "scale", source = "policy:popGrowth",
    value = function(_, ctx) return 1.0 + PolicySystem.getPopGrowthModifier(ctx.faction) end,
}

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
    -- 2026-09-22 真实地理地形接入后新增
    ["农田"]  = { gold = 1.3, food = 1.4 },
    ["草原"]  = { gold = 0.7, food = 0.9 },
    ["沙漠"]  = { gold = 0.4, food = 0.5 },
    ["针叶林"] = { gold = 0.7, food = 0.8 },
    ["丛林"]  = { gold = 0.5, food = 0.6 },
    ["冻土"]  = { gold = 0.3, food = 0.3 },
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

-- 2026-09-16 删：**税率档位**（getTaxEntry / TAX_RATES）
--   用户："国家面板里的税率和政策那里好像重复了" → 经济杠杆（收入/人口/稳定）
--   全部交给**政策卡**（得一失一那套），税率四档整体废弃。
--   原来税率提供的三项：收入倍率（rate）、人口增长（growth）、每月稳定（stability），现在都不再参与结算。

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
    ---@type table<number, table>
    local provinces = gameState.provinces or {}
    local faction = gameState.factions and gameState.factions[factionId]
    local list = (gameState.factionProvinces and gameState.factionProvinces[factionId])
        or (faction and faction.provinces) or {}
    for _, pid in ipairs(list) do
        local prov = provinces[pid]
        if prov and (prov.occupiedBy or prov.ownerId) == factionId and not seen[pid] then
            result[#result + 1] = prov
            seen[pid] = true
        end
    end
    -- 占领区和旧档缺失索引的自省均补入一次；敌占的本省不归原主结算。
    for pid, prov in pairs(provinces) do
        if (prov.occupiedBy or prov.ownerId) == factionId and not seen[pid] then
            result[#result + 1] = prov
            seen[pid] = true
        end
    end
    return result
end

----------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------

--- Calculate the gold and food income for a single province.
--- Does NOT include army upkeep.  (2026-09-16：税率倍率已废弃 → 不再乘 rate)
---@param province table  Province data (fields: baseGold, baseFood, terrain)
---@param season    number|string  Current season (1-4 or name)
---@return number goldIncome
---@return number foodIncome
function EconomySystem.getProvinceIncome(province, season)
    -- 沙漠化地块：无任何产出（历史时代3 式废土）
    if province.isWasteland then
        return 0, 0
    end
    local terrain = getTerrainBonus(province)
    local seasonMul = getSeasonMultiplier(season)

    local goldIncome = (province.baseGold or 0) * terrain.gold
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

    local season = TimeSystem.getSeason()

    local provinces = getOwnedProvinces(gameState, factionId)
    local totalGold = 0
    local totalFood = 0
    for i = 1, #provinces do
        local g, f = EconomySystem.getProvinceIncome(provinces[i], season)
        totalGold = totalGold + g
        totalFood = totalFood + f
    end
    -- 修正器管道（2026-09-13）：君主文治 + 政策/变法 + 资源/模组加成，一次性套完
    --   （原来这里是手写连乘；现在走管道，运算方式仍是 scale 连乘 → 数值不变）
    local modCtx = { gameState = gameState, faction = faction }
    totalGold = Modifiers.applyFloat(totalGold, "faction", "goldIncome", modCtx)
    totalFood = Modifiers.applyFloat(totalFood, "faction", "foodIncome", modCtx)

    local _, armySize = MilitaryLedger.snapshot(gameState, faction)
    -- 金钱维护费照 CK3（2026-09-19）：按兵种的 maintenance × 团数（兵/size）
    --   混编（2026-09-24）：按**全国实际兵种构成**加权 —— 精锐兵占比越高，养兵越贵
    local Units = require("data.Units")
    local upkeepGold = Units.upkeepOf(faction, armySize, Units.factionMix(gameState, faction))
    -- 粮草是我们自己的资源（CK3 无），保持"每 1000 兵"口径
    local upkeepFood = (armySize / 1000) * armyFoodCost

    return {
        income         = totalGold,
        foodIncome     = totalFood,
        armyUpkeepGold = upkeepGold,
        armyUpkeepFood = upkeepFood,
        netGold        = totalGold - upkeepGold,
        netFood        = totalFood - upkeepFood,
    }
end

--- 收支明细（2026-09-25）
---   给"收支面板"用：把每月收入/支出**按来源拆开**，而不是只给一个净额。
---   照 EU4 的收支面板口径 —— **按来源列，不按省列**（省份一多就爆屏，
---   而且玩家想知道的是"钱从哪来、花到哪去"，不是"每个省各出多少"）。
---
---   返回两张表（收入项 / 支出项），每项 { label, gold, food }，外加净额。
---@param gameState table
---@param factionId any
---@return table { incomeItems, expenseItems, netGold, netFood, totalGold, totalFood, totalUpkeepGold, totalUpkeepFood }
function EconomySystem.getBreakdown(gameState, factionId)
    local faction = gameState.factions and gameState.factions[factionId]
    if not faction then
        return { incomeItems = {}, expenseItems = {}, netGold = 0, netFood = 0,
                 totalGold = 0, totalFood = 0, totalUpkeepGold = 0, totalUpkeepFood = 0 }
    end

    local economy = GameConfig.Economy or {}
    local armyFoodCost = economy.ARMY_FOOD_COST or 8
    local season = TimeSystem.getSeason()
    local modCtx = { gameState = gameState, faction = faction }

    -- ── 收入：先按来源汇总，再套修正器 ──────────────────────────
    --   省份税收（含占领省；占领期间产出归占领方）
    local provinces = getOwnedProvinces(gameState, factionId)
    local rawGold, rawFood = 0, 0
    local occupiedGold, occupiedFood = 0, 0
    local ownGold, ownFood = 0, 0
    for i = 1, #provinces do
        local prov = provinces[i]
        local g, fd = EconomySystem.getProvinceIncome(prov, season)
        rawGold = rawGold + g
        rawFood = rawFood + fd
        -- 区分"自有省"与"占领省"：占领是临时的，玩家该看得出来
        if prov.occupiedBy == factionId and prov.ownerId ~= factionId then
            occupiedGold = occupiedGold + g
            occupiedFood = occupiedFood + fd
        else
            ownGold = ownGold + g
            ownFood = ownFood + fd
        end
    end

    -- 修正器（君主/政策/科技/事件）对总收入的乘算 —— 与 getFactionSummary 同口径
    local multGold = (rawGold > 0)
        and (Modifiers.applyFloat(rawGold, "faction", "goldIncome", modCtx) / rawGold) or 1
    local multFood = (rawFood > 0)
        and (Modifiers.applyFloat(rawFood, "faction", "foodIncome", modCtx) / rawFood) or 1

    local incomeItems = {}
    incomeItems[#incomeItems + 1] = {
        label = "领地赋税", gold = ownGold * multGold, food = 0,
    }
    if occupiedGold > 0 or occupiedFood > 0 then
        incomeItems[#incomeItems + 1] = {
            label = "占领区产出", gold = occupiedGold * multGold, food = 0,
        }
    end
    incomeItems[#incomeItems + 1] = {
        label = "田亩收成", gold = 0, food = ownFood * multFood + occupiedFood * multFood,
    }
    -- 修正器净影响单独列一行（让玩家看到政策/君主带来的增减）
    local modGoldDelta = rawGold * multGold - rawGold
    local modFoodDelta = rawFood * multFood - rawFood
    if math.abs(modGoldDelta) > 0.5 or math.abs(modFoodDelta) > 0.5 then
        incomeItems[#incomeItems + 1] = {
            label = "政策与君主加成", gold = modGoldDelta, food = modFoodDelta,
        }
    end

    local totalGold = rawGold * multGold
    local totalFood = rawFood * multFood

    -- ── 支出 ────────────────────────────────────────────────────
    local Units = require("data.Units")
    local _, armySize = MilitaryLedger.snapshot(gameState, faction)
    local upkeepGold = Units.upkeepOf(faction, armySize, Units.factionMix(gameState, faction))
    local upkeepFood = (armySize / 1000) * armyFoodCost

    local expenseItems = {}
    expenseItems[#expenseItems + 1] = {
        label = string.format("军饷（%d 兵）", math.floor(armySize)), gold = upkeepGold, food = 0,
    }
    expenseItems[#expenseItems + 1] = {
        label = "军粮", gold = 0, food = upkeepFood,
    }
    -- 附庸进贡（宗主收、附庸付）
    local tributeGold, tributeFood = 0, 0
    for _, other in pairs(gameState.factions or {}) do
        if other.vassalOf == factionId and other.alive ~= false then
            tributeGold = tributeGold + (other.gold or 0) * 0.10
            tributeFood = tributeFood + (other.food or 0) * 0.10
        end
    end
    if tributeGold > 0 or tributeFood > 0 then
        incomeItems[#incomeItems + 1] = {
            label = "附庸进贡", gold = tributeGold, food = tributeFood,
        }
    end

    return {
        incomeItems     = incomeItems,
        expenseItems    = expenseItems,
        totalGold       = totalGold,
        totalFood       = totalFood,
        totalUpkeepGold = upkeepGold,
        totalUpkeepFood = upkeepFood,
        netGold         = totalGold - upkeepGold,
        netFood         = totalFood - upkeepFood,
    }
end

--- 势力总人口：自己拥有的省 + 被自己占领的省
--- （口径与税收一致 —— 占领期间产出归占领方，人口也就按实际控制算）
---@param gameState table
---@param factionId any
---@return number totalPopulation
function EconomySystem.getFactionPopulation(gameState, factionId)
    local provinces = gameState.provinces or {}
    local total = 0
    ---@type table<number, boolean>
    local seen = {}
    local idx = gameState.factionProvinces and gameState.factionProvinces[factionId]
    if idx then
        for i = 1, #idx do
            local prov = provinces[idx[i]]
            if prov then
                total = total + (prov.population or 0)
                seen[prov.id] = true
            end
        end
    end
    for _, prov in pairs(provinces) do
        if prov.occupiedBy == factionId and not seen[prov.id] then
            total = total + (prov.population or 0)
        end
    end
    return total
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

        local provinces = getOwnedProvinces(gameState, faction.id)

        ----------------------------------------------------------------
        -- 1. Income from provinces
        ----------------------------------------------------------------
        local totalGoldIncome = 0
        local totalFoodIncome = 0

        for pi = 1, #provinces do
            local prov = provinces[pi]
            local g, f = EconomySystem.getProvinceIncome(prov, season)
            totalGoldIncome = totalGoldIncome + g
            totalFoodIncome = totalFoodIncome + f
        end
        -- 修正器管道（2026-09-13）：君主文治 + 政策/变法 + 资源/模组加成
        local modCtx = { gameState = gameState, faction = faction }
        totalGoldIncome = Modifiers.applyFloat(totalGoldIncome, "faction", "goldIncome", modCtx)
        totalFoodIncome = Modifiers.applyFloat(totalFoodIncome, "faction", "foodIncome", modCtx)

        ----------------------------------------------------------------
        -- 2. Army upkeep
        ----------------------------------------------------------------
        -- 从实控驻军、在途和战斗方对账；旧档 armySize 低估不能少付维护费。
        local armySize = MilitaryLedger.reconcile(gameState, faction)
        local Units = require("data.Units")
        -- 混编（2026-09-24）：按全国实际兵种构成加权（与上面 computeIncome 同口径）
        local upkeepGold = Units.upkeepOf(faction, armySize, Units.factionMix(gameState, faction))
        local upkeepFood = (armySize / 1000) * armyFoodCost

        ----------------------------------------------------------------
        -- 3. Apply net income
        ----------------------------------------------------------------
        -- ⚠️ 下限保护（2026-09-25）：扣到 0 就停，**不允许滚成负数**。
        --   旧代码直接相减 → 军费超过收入时 faction.gold 会一直往下掉，
        --   账面挂着 -5000、-12000 这种数字，UI 显示怪、而且惩罚判定也乱。
        --   现在改成：能扣多少扣多少，扣到 0 为止（欠的部分不记账）。
        local goldBefore = faction.gold or 0
        faction.gold = math.max(0, goldBefore + totalGoldIncome - upkeepGold)
        local foodBefore = faction.food or 0
        faction.food = math.max(0, foodBefore + totalFoodIncome - upkeepFood)

        -- 是否真的"付不起"：收入 + 存粮 < 军费（不是看余额为负，因为已经夹到 0 了）
        local brokeGold = (goldBefore + totalGoldIncome) < upkeepGold
        local brokeFood = (foodBefore + totalFoodIncome) < upkeepFood

        ----------------------------------------------------------------
        -- 4. 养不起兵 → 士气崩 + 逃兵（2026-09-25 扩写）
        --    旧版只处理粮草为负；金钱为负**什么都不发生**（漏了）。
        --    现在金/粮任一不足都罚，两者都不足则叠加（照 CK3"逐渐崩溃"）。
        --    照 CK3/EU4 的通行做法：**不是立即解散**，而是先掉士气、再逃兵，
        --    持续赤字把士气耗光后才哗变 —— 给玩家反应时间。
        ----------------------------------------------------------------
        local penaltyCount = (brokeGold and 1 or 0) + (brokeFood and 1 or 0)
        local MILCfg = require("config.GameConfig").Military or {}
        if penaltyCount > 0 then
            local MIL2 = MILCfg
            -- 士气惩罚（叠加）
            local moraleBefore = faction.morale or 100
            faction.morale = math.max(0, moraleBefore
                - (MIL2.BANKRUPT_MORALE_HIT or 10) * penaltyCount)
            -- 掉到预警线以下 → 明确告诉玩家"再破产就要哗变了"（2026-09-26）
            --   以前这个数字界面看不到，玩家不知道自己在滑向崩溃
            local warnAt = MIL2.FACTION_MORALE_WARN or 30
            if moraleBefore > warnAt and (faction.morale or 0) <= warnAt
               and faction.id == gameState.playerFactionId then
                if gameState.addMessage then
                    gameState.addMessage(string.format(
                        "军心不稳！国库再亏空 %d 次，军队就会哗变溃散",
                        math.max(1, math.floor((faction.morale or 0) / (MIL2.BANKRUPT_MORALE_HIT or 10)))), "war", true)
                end
            end
            -- 逃兵（叠加）：按真实驻军/在途/战斗方比例扣数，并同步总账与安全返人口。
            local desertRate = (MIL2.DESERTION_RATE or DESERTION_RATE) * penaltyCount
            local deserted = MilitaryLedger.reduceTroops(gameState, faction, math.floor(armySize * desertRate))
            if deserted > 0 then
                if gameState.addMessage and faction.id == gameState.playerFactionId then
                    gameState.addMessage(string.format(
                        "%s不足，逃兵 %d 人（士气 %d）",
                        brokeGold and brokeFood and "钱粮" or (brokeGold and "军饷" or "粮草"),
                        deserted, math.floor(faction.morale or 0)), "warning", true)
                end
            end
            -- 持续赤字 → 士气归零 → 哗变；基数必须取逃兵后的剩余，不能覆盖逃兵损失。
            local remainingArmy = faction.armySize or 0
            if (faction.morale or 0) <= 0 and remainingArmy > 0 then
                local mutiny = MilitaryLedger.reduceTroops(gameState, faction,
                    math.floor(remainingArmy * (MIL2.REVOLT_ARMY_RATE or 0.15)))
                if mutiny > 0 then
                    if gameState.addMessage then
                        gameState.addMessage(string.format(
                            "%s国库空虚，军队哗变溃散 %d 人！",
                            faction.fullName or faction.name or tostring(faction.id), mutiny),
                            "war", faction.id == gameState.playerFactionId)
                    end
                    print(string.format("[Economy] %s 哗变解散 %d 兵",
                        faction.name or faction.id or "?", mutiny))
                end
            end
        else
            -- 4.9 国家士气回升（2026-09-26 修）
            --   不欠饷的月份 → 军心慢慢回来（照 EU4 的"每月回士气"）。
            --   修掉的老问题：faction.morale 只减不加，破产几次后永久归零，
            --   之后每月都哗变，玩家没有任何翻身机会。
            local rec = MILCfg.FACTION_MORALE_RECOVERY or 5
            local cap = MILCfg.FACTION_MORALE_MAX or 100
            local cur = faction.morale or cap
            if cur < cap then
                faction.morale = math.min(cap, cur + rec)
            end
        end

        ----------------------------------------------------------------
        -- 4.5 补给损耗（2026-09-19 照 CK3）：驻军超过该省"养兵容量"的部分
        --     每月饿死/逃散（容量看地形：山地/沙漠只有平原的一半上下）
        ----------------------------------------------------------------
        do
            local MilitarySystem = require("systems.MilitarySystem")
            -- AI 先避损耗（2026-09-19 照 CK3）：AI 讨厌损耗，会把超编的兵就近调走。
            --   顺序很重要：**先搬家、再算损耗**，玩家则自己管（手动调兵）。
            if gameState.playerFactionId and faction.id ~= gameState.playerFactionId then
                local AIManager = require("ai.AIManager")
                local moved = AIManager.avoidSupplyAttrition(gameState, faction)
                if moved > 0 then
                    print(string.format("[Supply] %s 避损耗：就近调走 %d 兵",
                        faction.name or faction.id or "?", moved))
                end
            end
            local supplyLost = MilitarySystem.applySupply(gameState, faction)
            if supplyLost > 0 then
                print(string.format("[Supply] %s 补给不足，损失 %d 兵",
                    faction.name or faction.id or "?", supplyLost))
            end
        end

        ----------------------------------------------------------------
        -- 4.95 驻军士气恢复（2026-09-26 用户："接战掉、不战回"）
        --   每个省有自己的 morale（默认 100）。打仗时按战斗规则掉，打剩多少就驻防多少；
        --   这里让**不接战**的省每月慢慢回满（接战中的省由战斗对象接管，不动它的值）。
        --   为什么要有：没有恢复 → 一个省被打残一次就永远低士气，
        --   下次接战一触即溃，玩家没有任何翻盘余地（照 EU4 的每月回士气）。
        ----------------------------------------------------------------
        do
            local recRate = MILCfg.FACTION_MORALE_RECOVERY or 5   -- 复用同一档恢复速度
            local cap = MILCfg.FACTION_MORALE_MAX or 100
            local battles = gameState.battles or {}
            for pi = 1, #provinces do
                local prov = provinces[pi]
                -- 列表已包含占领区；只恢复实际控制且脱战省，不能给敌占本省回士气。
                if (prov.occupiedBy or prov.ownerId) == faction.id and not battles[prov.id] then
                    local m = prov.morale
                    if m and m < cap then
                        prov.morale = math.min(cap, m + recRate)
                    end
                end
            end
        end

        ----------------------------------------------------------------
        -- 5. Population growth per province (policies only; 税率已废弃)
        ----------------------------------------------------------------
        -- 政策/变法人口增长加成（如轻徭 +20%）
        -- 洞 4：改成读管道 → 模组/事件挂 popGrowth 也能生效（政策那条规则在上面注册过，数值不变）
        local popMod = Modifiers.applyFloat(1.0, "faction", "popGrowth",
            { gameState = gameState, faction = faction })
        for pi = 1, #provinces do
            local prov = provinces[pi]
            local pop = prov.population or 0
            local baseGrowthRate = prov.baseGrowthRate or 0.002
            local effectiveRate = baseGrowthRate * popMod

            local growth = math.floor(pop * effectiveRate)
            prov.population = math.max(0, pop + growth)
        end

        ----------------------------------------------------------------
        -- 5.5 兵源池每月恢复（2026-09-25）
        --     征兵从池子里扣，这里按月补回一部分（照 EU4 人力池 / CK3 征召兵缓回）。
        --     恢复量 = 池子上限 × MANPOOL_REGEN（默认 4%）。
        ----------------------------------------------------------------
        do
            local MilitarySystem = require("systems.MilitarySystem")
            local regen = MILCfg.MANPOOL_REGEN or 0.04
            gameState.manpower = gameState.manpower or {}
            -- 与手动征召/自动补员共用资格和修正后上限；敌占、接战、占领他国省不恢复。
            for pi = 1, #provinces do
                local prov = provinces[pi]
                if MilitarySystem.canRecruitIn(gameState, faction.id, prov.id) then
                    local cap = MilitarySystem.manpowerCapacity(gameState, faction, prov)
                    local cur = gameState.manpower[prov.id]
                    if cur == nil then cur = cap end
                    if cur < cap then
                        gameState.manpower[prov.id] = math.min(cap, cur + cap * regen)
                    elseif cur > cap then
                        gameState.manpower[prov.id] = cap   -- 人口掉了 → 池子上限跟着降
                    end
                end
            end
        end

        ----------------------------------------------------------------
        -- 6. Stability adjustment from policies (仁政/严法)
        ----------------------------------------------------------------
        -- 修正器管道（2026-09-13）：政策/变法 + 文化不满 + 事件，一次性套完
        local stabilityDelta = Modifiers.applyFloat(PolicySystem.getStabilityDelta(faction),
                "faction", "stabilityDelta", { gameState = gameState, faction = faction })
        if stabilityDelta ~= 0 then
            local current = faction.stability or 0
            faction.stability = math.max(-100, math.min(100, current + stabilityDelta))
        end

        ----------------------------------------------------------------
        -- 6.5 名声（2026-09-17，原「威望」）：特质/事件的每月增减
        --     flat 口：0 = 不变。名义上的"名声"贵在细水长流（忠义 +0.5/月，弑亲 −1/月）
        ----------------------------------------------------------------
        local prestigeDelta = Modifiers.applyFloat(0, "faction", "prestigeDelta", modCtx)
        if prestigeDelta ~= 0 then
            faction.prestige = (faction.prestige or 0) + prestigeDelta
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

        ----------------------------------------------------------------
        -- 8. 资源注册表的"每月结算"**已挪走**（2026-09-14）
        --    原先在这里调 Resources.settleMonthly，但那是**归属错误**：
        --      经济是**模组**（可以关），资源结算属于**插座**（本体的一部分）。
        --      留在经济里 → 经济模组一关，所有模组的"每月 +N"全停（"每天 +N"却没事）。
        --    现在挪到 main.lua 的 OnNewMonth，紧跟在本函数之后跑。
        --    **顺序没变**：仍然在经济结算之后，incomeMonth 的公式照样能读到
        --    本月结算完的金/粮/人口 —— 原来那条注释要的是"顺序"，不是"归属"。
        ----------------------------------------------------------------

        ::continueFaction::
    end
end

return EconomySystem

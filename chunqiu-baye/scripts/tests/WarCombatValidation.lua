-- 战分、战损、无守军与同轮双崩回归；不修改用户存档。
local War = require("systems.WarSystem")
local Military = require("systems.MilitarySystem")
local Ledger = require("systems.MilitaryLedger")
local Rules = require("systems.CombatRules")
local Config = require("config.GameConfig")

local function fixture()
    local gs = { playerFactionId = 1, factions = {
        [1] = { id = 1, name = "甲", provinces = { 1 }, capitalId = 1, armySize = 1000,
            prestige = 0, mainUnitId = "light_inf", policies = {}, characters = {} },
        [2] = { id = 2, name = "乙", provinces = { 2, 3 }, capitalId = 3, armySize = 1000,
            prestige = 0, mainUnitId = "light_inf", policies = {}, characters = {} },
    }, provinces = {
        [1] = { id = 1, ownerId = 1, _initOwner = 2, garrison = 1000, morale = 100, neighbors = { 2 }, terrain = "平原" },
        [2] = { id = 2, ownerId = 2, _initOwner = 1, garrison = 500, morale = 100, neighbors = { 1, 3 }, terrain = "平原" },
        [3] = { id = 3, ownerId = 2, _initOwner = 2, garrison = 500, morale = 100, neighbors = { 2 }, terrain = "平原" },
    }, relations = { [1] = { [2] = { atWar = true } }, [2] = { [1] = { atWar = true } } },
        armies = {}, battles = {}, wars = {} }
    return gs
end

local function run()
    local gs = fixture()
    local war = War.startWar(gs, 1, 2)
    assert(war.aArmy == 1000 and war.dArmy == 1000 and #war.dProvinceIds == 2, "开战快照不正确")
    gs.provinces[2].occupiedBy = 1
    assert(War.getScore(gs, war, 1) == 30 and War.getScore(gs, war, 2) == -30, "占领用错整局初始归属")
    local tiny = War.recordBattle(gs, 1, 2, 10)
    assert(math.abs(tiny - 0.2) < 0.00001, "小仗没有按规模计分")
    War.recordBattle(gs, 1, 2, 1000)
    assert(war.aBattle == 20 and war.dBattle == -20, "战斗贡献不封顶或双方分数不对称")
    War.recordBattle(gs, 2, 1, 1000)
    assert(war.aBattle == 0, "封顶之后不能被败仗抵消")
    gs.provinces[3].occupiedBy = 1
    assert(War.getScore(gs, war, 1) == 100 and War.getScore(gs, war, 2) == -100, "全境占领仍不足100分")
    assert(War.getPeaceAcceptChance(gs, 1, 2) == 1, "决定性胜利仍能无限拒和")
    gs.provinces[2].occupiedBy, gs.provinces[3].occupiedBy = nil, nil
    assert(War.getScore(gs, war, 1) == 0, "解放占领省未即时扣回分数")
    War.recordCasualties(gs, 2, 1, 20, 5)
    assert(war.aLoss == 5 and war.dLoss == 20 and war.stats[1].killed == 20, "战损方向错误")
    War.endWar(gs, war)
    gs.provinces[2].ownerId = 1
    gs.factions[1].provinces = { 1, 2 }
    gs.factions[2].provinces = { 3, 4 }
    gs.provinces[4] = { id = 4, ownerId = 2, garrison = 0, neighbors = { 3 } }
    local second = War.startWar(gs, 2, 1)
    gs.provinces[2].occupiedBy = 2
    assert(War.getScore(gs, second, 2) == 30, "第二场战争不按新归属快照计分")
    print("[WarValidation] PASS 当前领土快照、规模战分、全占100、战损方向、第二次战争")

    -- 纯结算接口由CombatRules提供：验证双崩对调后无先判攻方偏置。
    local left = { size = 1000, morale = 21 }
    local right = { size = 1000, morale = 21 }
    local draw = Rules.resolveRound(left, right, 500, 500, Config.Military)
    assert(draw.outcome == "draw" and draw.attLoss == draw.defLoss, "同强度双崩没有平局")
    local aWins = Rules.resolveRound(left, right, 1000, 500, Config.Military)
    local dWins = Rules.resolveRound(right, left, 500, 1000, Config.Military)
    assert(aWins.outcome == "att" and dWins.outcome == "def", "双崩翻转偏置")
    print("[WarValidation] PASS 双崩统一判定与对调公平性")

    gs = fixture()
    war = War.startWar(gs, 1, 2)
    gs.provinces[2].garrison = 0
    gs.factions[2].armySize = 500
    assert(Military.moveArmy(gs, 1, 1, 2, 400))
    Military.updateArmies(gs, 100, 10)
    Military.processBattles(gs, 24)
    assert(gs.battles[2] == nil and gs.provinces[2].garrison == 400 and gs.factions[1].armySize == 1000,
        "无守军仍让进攻方损失兵")
    assert((war.aBattle or 0) == 0, "空省刷出了战斗胜利分")
    print("[WarValidation] PASS 空守军不伤亡、不刷战斗分")

    gs = fixture()
    war = War.startWar(gs, 1, 2)
    gs.provinces[1].garrison = 0
    gs.provinces[2].garrison = 0
    gs.battles[2] = { att = { factionId = 1, size = 1000, initialSize = 1000,
            morale = 21, unitMix = { light_inf = 1 } },
        def = { factionId = 2, size = 500, initialSize = 500,
            morale = 21, unitMix = { light_inf = 1 } }, accHours = 0, progress = 0 }
    Military.processBattles(gs, 24)
    for fid, f in pairs(gs.factions) do
        local _, n = Ledger.snapshot(gs, f)
        assert(n == f.armySize, "战后阵亡/追击/撤退不守恒")
    end
    assert(gs.battles[2] == nil, "低士气战斗没有终止")
    assert((war.aLoss or 0) + (war.dLoss or 0) > 0, "战损未记录")
    print("[WarValidation] PASS 真实低士气战斗收尾与兵力守恒")

    gs = fixture()
    War.startWar(gs, 1, 2)
    gs.provinces[1].occupiedBy = 2
    gs.provinces[1].garrison = 0
    gs.provinces[2].garrison = 0
    gs.factions[1].armySize = 1000
    gs.factions[2].armySize = 500 + 1000
    gs.battles[2] = { att = { factionId = 1, size = 1000, morale = 0 },
        def = { factionId = 2, size = 1000, morale = 0 }, progress = 0, accHours = 0 }
    Military.processBattles(gs, 24)
    assert(gs.provinces[2].garrison == 1000 and #gs.armies == 1
        and gs.armies[1].size == 1000 and gs.armies[1].retreating, "零有效战力或平局无路退时删兵")
    Military.updateArmies(gs, 100, 10)
    assert(#gs.armies == 1 and gs.armies[1].size == 1000, "平局等待残兵被错误合并敌军")
    print("[WarValidation] PASS 零有效战力与无路平局残兵保留")

    gs = fixture()
    gs.provinces[1].garrison, gs.provinces[2].garrison = 0, 0
    gs.factions[1].armySize, gs.factions[2].armySize = 0, 1000
    gs.battles[2] = { att = { factionId = 1, size = 0, morale = 100 },
        def = { factionId = 2, size = 500, morale = 100 }, accHours = 0, progress = 0 }
    Military.processBattles(gs, 24)
    assert(gs.provinces[2].garrison == 500 and gs.factions[2].armySize == 1000, "空攻军仍伤守军")

    gs = fixture()
    gs.provinces[1].garrison, gs.provinces[2].garrison = 0, 0
    gs.battles[2] = { att = { factionId = 1, size = 1000, morale = 100 },
        def = { factionId = 2, size = 500, morale = 100 }, accHours = 0, progress = 0 }
    local savedBase, savedScale = Config.Military.MORALE_LOSS_BASE, Config.Military.MORALE_LOSS_SCALE
    Config.Military.MORALE_LOSS_BASE, Config.Military.MORALE_LOSS_SCALE = 0, 0
    local tickOk, tickErr = pcall(Military.processBattles, gs, 30 * 24)
    Config.Military.MORALE_LOSS_BASE, Config.Military.MORALE_LOSS_SCALE = savedBase, savedScale
    assert(tickOk, tickErr)
    assert(gs.battles[2] and gs.battles[2].accHours == 6 * 24, "超过24轮的时间被截断丢失")
    print("[WarValidation] PASS 空攻军与快进剩余时间")
    print("[WarValidation] ALL PASS")
end

function Start()
    local ok, err = pcall(run)
    if not ok then log:Write(LOG_ERROR, "[WarValidation] FAIL " .. tostring(err)) end
    engine:Exit()
end

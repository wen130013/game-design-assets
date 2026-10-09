-- 基于官方离线 Start/pcall/Exit 模板的军事规则回归，不启动游戏或修改用户存档。
local Military = require("systems.MilitarySystem")
local Units = require("data.Units")
local Config = require("config.GameConfig")

local function fixture()
    local a = { id = 1, name = "甲", armySize = 1200, gold = 10000, food = 10000,
        provinces = { 1, 2 }, capitalId = 1, mainUnitId = "light_inf", characters = {},
        provinceCommanders = {}, policies = {} }
    local d = { id = 2, name = "乙", armySize = 300, gold = 10000, food = 10000,
        provinces = { 3, 4 }, capitalId = 4, mainUnitId = "light_inf", characters = {},
        provinceCommanders = {}, policies = {} }
    local provinces = {
        [1] = { id = 1, name = "甲都", ownerId = 1, garrison = 200, morale = 100,
            population = 10000, terrain = "平原", neighbors = { 2 } },
        [2] = { id = 2, name = "甲边", ownerId = 1, garrison = 0, morale = 100,
            population = 10000, terrain = "平原", neighbors = { 1, 3 } },
        [3] = { id = 3, name = "占领省", ownerId = 2, occupiedBy = 1, garrison = 1000,
            morale = 32, unitMix = { archer = 1 }, population = 10000, terrain = "平原", neighbors = { 2, 4 } },
        [4] = { id = 4, name = "乙都", ownerId = 2, garrison = 300, morale = 100,
            population = 10000, terrain = "平原", neighbors = { 3 } },
    }
    return { factions = { [1] = a, [2] = d }, provinces = provinces, armies = {}, battles = {},
        wars = {}, relations = { [1] = { [2] = { atWar = true } }, [2] = { [1] = { atWar = true } } },
        manpower = {}, playerFactionId = 1 }
end

local function actual(gs, fid)
    local n = 0
    for _, p in pairs(gs.provinces) do
        if Military.controller(p) == fid then n = n + (p.garrison or 0) end
    end
    for _, a in ipairs(gs.armies) do if a.factionId == fid then n = n + a.size end end
    for _, b in pairs(gs.battles) do
        if b.att.factionId == fid then n = n + b.att.size end
        if b.def.factionId == fid then n = n + b.def.size end
    end
    return n
end

local function checkCount(gs)
    for fid, f in pairs(gs.factions) do
        assert(actual(gs, fid) == f.armySize, "兵力不守恒：" .. tostring(fid))
    end
end

local function run()
    local gs = fixture()
    assert(not Military.orderMove(gs, 2, 3, 4, 100), "原主调走了占领军")
    assert(not Military.recruit(gs, 2, 3, 100), "原主在占领区招兵")
    assert(not Military.canGarrisonIn(gs, 2, 3), "被占领省被误认安全落脚")
    local ok, army = Military.orderMove(gs, 1, 3, 2, 500)
    assert(ok and type(army) == "table", "占领军不能继续移动")
    assert(army.morale == 32, "出征重置了士气")
    checkCount(gs)
    Military.updateArmies(gs, 100, 10)
    assert(gs.provinces[2].garrison == 500 and gs.provinces[2].morale == 32, "到达丢失士气")
    assert(Units.mixOf(gs.provinces[2], gs.factions[1]).archer == 1, "到达丢失兵种")
    checkCount(gs)
    print("[MilitaryValidation] PASS 占领军兵权、行军士气、并兵守恒")

    gs = fixture()
    gs.provinces[3].morale = Config.Military.ROUT_MORALE
    assert(not Military.moveArmy(gs, 1, 3, 4, 100), "溃兵仍可立即再次进攻")
    assert(Military.moveArmy(gs, 1, 3, 2, 100), "溃兵不能回己方重整")
    checkCount(gs)

    gs = fixture()
    gs.factions[1].characters = { { id = 101, factionId = 1, alive = true, military = 3 } }
    gs.factions[1].provinceCommanders[2] = 101
    gs.manpower[2] = 75
    local beforePop, beforeGold, beforeFood = gs.provinces[2].population, gs.factions[1].gold, gs.factions[1].food
    local added = Military.autoReplenish(gs, gs.factions[1])
    local gold, food = Military.recruitCostFor(gs.factions[1], 75)
    assert(added == 75 and gs.manpower[2] == 0, "补员不受兵源限制")
    assert(gs.provinces[2].population == beforePop - 75, "补员未扣人口")
    assert(gs.factions[1].gold == beforeGold - gold and gs.factions[1].food == beforeFood - food, "补员费率与招募不同")
    assert(Military.autoReplenish(gs, gs.factions[1]) == 0, "耗尽兵源仍可补员")
    checkCount(gs)
    gs.battles[1] = { att = { factionId = 2, size = 0 }, def = { factionId = 1, size = 0 } }
    assert(not Military.recruit(gs, 1, 1, 100), "接战省仍能额外征召")
    gs.battles[1] = nil
    gs.factions[1].gold, gs.factions[1].food = 0.9, 0.9
    assert(not Military.recruit(gs, 1, 1, 100), "向上取整扣费导致负资源")
    print("[MilitaryValidation] PASS 补员兵源、人口、费用、接战限制")

    gs = fixture()
    gs.factions[2].armySize = 995
    gs.provinces[4].garrison = 995
    local recruited, count = Military.recruit(gs, 2, 4, 1000)
    assert(recruited and count == 5 and gs.factions[2].armySize == 1000, "AI整批超出兵力目标")
    checkCount(gs)
    print("[MilitaryValidation] PASS AI剩余额度限制")

    gs = fixture()
    gs.provinces[3].morale = 90
    assert(Military.startBattle(gs, { factionId = 2, size = 100, morale = 80, unitMix = { light_inf = 1 } }, gs.provinces[3], 2))
    gs.battles[3].att.morale = 10
    gs.provinces[4].garrison = 200
    checkCount(gs)
    -- 占领方守军获胜之后仍然保有军事控制，不能清成原主。
    Military.processBattles(gs, 24)
    assert(gs.battles[3] == nil and gs.provinces[3].occupiedBy == 1, "占领军守胜却丢失控制")
    checkCount(gs)
    print("[MilitaryValidation] PASS 占领方守胜保留占领")

    gs = fixture()
    local n = Military.disbandGarrison(gs, 1, 3, 50)
    assert(n == 50 and gs.factions[1].armySize == 1150, "裁军未同步总兵力")
    assert(Military.disbandGarrison(gs, 2, 3, 50) == 0, "原主能裁掉占领军")
    checkCount(gs)
    print("[MilitaryValidation] PASS 裁军归属与总账")

    gs = fixture()
    gs.provinces[3].morale = 90
    gs.provinces[4].garrison = 200
    Military.startBattle(gs, { factionId = 2, size = 100, morale = 80, unitMix = { light_inf = 1 } }, gs.provinces[3], 2)
    assert(Military.moveArmy(gs, 1, 2, 1, 1) == false, "空驻军省仍能出兵")
    gs.provinces[1].garrison = 100
    gs.armies[1] = { factionId = 1, from = 2, to = 3, size = 100, morale = 20,
        unitMix = { light_inf = 1 }, progress = 0, totalHours = 72, realElapsed = 0 }
    Military.updateArmies(gs, 100, 10)
    local side = gs.battles[3].def
    assert(side.size == 1100 and math.abs(side.morale - (90000 + 2000) / 1100) < 0.0001,
        "援军没有入战斗或士气未按人数合并")
    assert(gs.provinces[3].garrison == 0, "援军绕过战斗进入驻军池")
    checkCount(gs)
    print("[MilitaryValidation] PASS 实际到达援军入战与士气加权")

    gs = fixture()
    gs.provinces[3].morale = 90
    local okStop, marching = Military.moveArmy(gs, 1, 3, 4, 100)
    assert(okStop and type(marching) == "table", "停止行军测试未出兵")
    marching.progress = 70
    assert(Military.stopArmy(gs, marching), "敌控目标不能改用安全落脚省停止")
    assert(gs.provinces[4].garrison == 300, "停止行军合并到了敌驻军")
    checkCount(gs)
    print("[MilitaryValidation] PASS 停止行军不能改变兵属")
    print("[MilitaryValidation] ALL PASS")
end

function Start()
    local ok, err = pcall(run)
    if not ok then log:Write(LOG_ERROR, "[MilitaryValidation] FAIL " .. tostring(err)) end
    engine:Exit()
end

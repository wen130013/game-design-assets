-- 实际驻军/行军/战斗兵力与经济扣兵的离线回归。
local Ledger = require("systems.MilitaryLedger")
local Economy = require("systems.EconomySystem")
local Units = require("data.Units")

local function fixture()
    local f = { id = 1, name = "验证国", alive = true, provinces = { 1, 2 }, capitalId = 1,
        armySize = 777, gold = 0, food = 0, morale = 10, stability = 50,
        mainUnitId = "light_inf", characters = {}, policies = {} }
    return { playerFactionId = 1, factions = { [1] = f }, manpower = {}, wars = {}, relations = {},
        provinces = {
            [1] = { id = 1, ownerId = 1, population = 0, garrison = 300, morale = 80,
                terrain = "平原", neighbors = { 2 }, unitMix = { archer = 1 }, stability = 50 },
            [2] = { id = 2, ownerId = 1, occupiedBy = 2, population = 0, garrison = 500,
                terrain = "平原", neighbors = { 1 }, unitMix = { light_inf = 1 } },
            [3] = { id = 3, ownerId = 2, occupiedBy = 1, population = 0, garrison = 200,
                terrain = "平原", neighbors = { 1 }, unitMix = { heavy_cav = 1 } },
        },
        armies = { { factionId = 1, size = 100, morale = 50, unitMix = { archer = 1 } } },
        battles = { [4] = { att = { factionId = 1, size = 400, morale = 60, unitMix = { light_inf = 1 } },
            def = { factionId = 2, size = 50, morale = 50, unitMix = { light_inf = 1 } } } } }
end

local function run()
    local gs = fixture()
    local f = gs.factions[1]
    assert(Ledger.reconcile(gs, f) == 1000 and f.armySize == 1000, "账面未对齐真实部队")
    local mix = Units.factionMix(gs, f)
    assert(math.abs(mix.archer - 0.4) < 0.00001 and math.abs(mix.heavy_cav - 0.2) < 0.00001,
        "军费构成漏了行军或占领驻军")
    local lost, returned = Ledger.reduceTroops(gs, f, 101)
    local _, actual = Ledger.snapshot(gs, f)
    assert(lost == 101 and actual == 899 and f.armySize == 899, "多部队精确扣兵不守恒")
    assert(returned == 101 and gs.provinces[1].population == 101, "实际逃兵没有回安全人口")
    assert(gs.provinces[2].garrison == 500 and gs.battles[4].def.size == 50, "逃兵扣错敌军")
    assert(#gs.armies == 1 and gs.battles[4] ~= nil, "减员删除了在途或战斗记录")
    print("[LedgerValidation] PASS 多部队比例减员、真实总数、军费构成")

    gs = fixture()
    f = gs.factions[1]
    gs.provinces[1].occupiedBy = 2
    Ledger.reconcile(gs, f)
    lost, returned = Ledger.reduceTroops(gs, f, 77)
    assert(lost == 77 and returned == 0, "无安全本土凭空返人口")
    assert(gs.provinces[1].population == 0 and gs.provinces[3].population == 0, "逃兵增加了敌方人口")
    print("[LedgerValidation] PASS 无安全本土不向敌省返人口")

    gs = fixture()
    gs.provinces[3].garrison = 0
    gs.provinces[1].garrison = 1000
    gs.armies, gs.battles = {}, {}
    f = gs.factions[1]
    f.armySize = 7
    Economy.processMonth(gs)
    local _, current = Ledger.snapshot(gs, f)
    -- 钱粮皆欠：先逃10%=100，再由剩余900哗变15%=135，实际共减少235。
    assert(current == 765 and f.armySize == 765, "真实月度欠费未累计扣逃兵与哗变：" .. tostring(current))
    assert(gs.provinces[2].garrison == 500, "欠费扣走了占领军")
    print("[LedgerValidation] PASS 月度欠费实际减员235，残兵765")
    print("[LedgerValidation] ALL PASS")
end

function Start()
    local ok, err = pcall(run)
    if not ok then log:Write(LOG_ERROR, "[LedgerValidation] FAIL " .. tostring(err)) end
    engine:Exit()
end

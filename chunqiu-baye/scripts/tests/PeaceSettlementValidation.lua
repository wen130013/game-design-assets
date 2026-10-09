-- 和谈真实入口回归：割地/归还/军队守恒/第三国隔离/后台条款校验。
local Diplomacy = require("systems.DiplomacySystem")
local War = require("systems.WarSystem")
local Military = require("systems.MilitarySystem")
local Ledger = require("systems.MilitaryLedger")

local function fixture()
    local gs = { playerFactionId = 1, factions = {}, provinces = {}, armies = {}, battles = {},
        wars = {}, relations = {}, manpower = {}, peaceReturns = {} }
    for fid = 1, 3 do
        gs.factions[fid] = { id = fid, name = "国" .. fid, fullName = "国" .. fid,
            provinces = { (fid - 1) * 2 + 1, fid * 2 }, capitalId = (fid - 1) * 2 + 1,
            armySize = 200, gold = 1000, food = 1000, alive = true,
            mainUnitId = "light_inf", characters = {}, policies = {} }
        gs.relations[fid] = {}
        for j = 1, 3 do if j ~= fid then gs.relations[fid][j] = { value = -50, atWar = true } end end
    end
    for pid = 1, 6 do
        gs.provinces[pid] = { id = pid, name = "省" .. pid, ownerId = math.ceil(pid / 2),
            garrison = 100, morale = 70, unitMix = { light_inf = 1 }, population = 1000,
            terrain = "平原", neighbors = {} }
        if pid > 1 then gs.provinces[pid].neighbors[#gs.provinces[pid].neighbors + 1] = pid - 1 end
        if pid < 6 then gs.provinces[pid].neighbors[#gs.provinces[pid].neighbors + 1] = pid + 1 end
    end
    War.startWar(gs, 1, 2)
    War.startWar(gs, 1, 3)
    return gs
end

local function count(gs)
    local totals = {}
    for fid, f in pairs(gs.factions) do
        local _, n = Ledger.snapshot(gs, f)
        totals[fid] = n
    end
    return totals
end

local function assertTotals(gs, before)
    local after = count(gs)
    for fid, n in pairs(before) do
        assert(after[fid] == n and gs.factions[fid].armySize == n, "和谈丢兵/改变兵属：" .. fid)
    end
end

local function run()
    local gs = fixture()
    -- 甲占乙省，甲丙仍在交战：甲乙签约不能停甲丙军队或战斗。
    gs.provinces[3].occupiedBy = 1
    gs.provinces[3].unitMix = { archer = 1 }
    gs.armies[1] = { factionId = 1, from = 2, to = 5, routePath = { 4, 5 }, size = 30,
        morale = 42, unitMix = { archer = 1 }, progress = 0, realElapsed = 0, totalHours = 72 }
    gs.provinces[1].garrison = 20
    gs.provinces[5].garrison = 0
    gs.battles[5] = { att = { factionId = 1, size = 50, morale = 60 },
        def = { factionId = 3, size = 100, morale = 50 }, accHours = 0, progress = 0 }
    for _, f in pairs(gs.factions) do Ledger.reconcile(gs, f) end
    local before = count(gs)
    local thirdWar, thirdBattle, thirdArmy = War.findWar(gs, 1, 3), gs.battles[5], gs.armies[1]
    local okOffer, offer = Diplomacy.preparePeaceOffer(gs, 1, 2)
    assert(okOffer and type(offer) == "table", "无法准备新和谈")
    offer.provinces = { 3 }
    -- 占领一半且敌军严重劣势，够预算签小条款，避免随机拒和掩盖结算测试。
    local oldChance = War.getPeaceAcceptChance
    War.getPeaceAcceptChance = function() return 1 end
    local ok, msg = Diplomacy.submitPeace(gs, 1, 2, offer)
    War.getPeaceAcceptChance = oldChance
    assert(ok, tostring(msg))
    assert(gs.provinces[3].ownerId == 1 and gs.provinces[3].occupiedBy == nil
        and gs.provinces[3].garrison == 100 and gs.provinces[3].unitMix.archer == 1,
        "割地抹掉了留守占领军")
    assert(War.findWar(gs, 1, 2) == nil and not Diplomacy.isAtWar(gs, 1, 2), "和谈未结束关系和战争")
    assert(War.findWar(gs, 1, 3) == thirdWar and gs.battles[5] == thirdBattle
        and gs.armies[1] == thirdArmy, "和谈中止了第三国战争")
    assertTotals(gs, before)
    print("[PeaceValidation] PASS 割地保留驻军、第三国战斗与军令隔离、全军守恒")

    gs = fixture()
    gs.provinces[3].occupiedBy = 1
    for _, f in pairs(gs.factions) do Ledger.reconcile(gs, f) end
    before = count(gs)
    gs.pendingPeace = { proposerId = 2, targetId = 1, warStartedAt = War.findWar(gs, 1, 2).startedAt,
        terms = { provinces = {}, gold = 0, food = 0 } }
    assert(Diplomacy.respondPendingPeace(gs, true))
    assert(gs.provinces[3].ownerId == 2 and gs.provinces[3].occupiedBy == nil
        and gs.provinces[3].garrison == 0, "白和未撤军归还占领")
    assertTotals(gs, before)
    print("[PeaceValidation] PASS 白和归还占领、撤军不改变归属")

    gs = fixture()
    assert(not Diplomacy.submitPeace(gs, 1, 2, { annexAll = true, provinces = {} }), "未全占也能吞并")
    assert(not Diplomacy.submitPeace(gs, 1, 2, { provinces = { 5 } }), "索取第三国领土")
    assert(not Diplomacy.submitPeace(gs, 1, 2, { gold = -10 }), "允许负赔款")
    assert(not Diplomacy.submitPeace(gs, 1, 2, { gold = 0 / 0 }), "允许非法金额")
    assert(War.findWar(gs, 1, 2) ~= nil, "无效条款已经结束战争")
    print("[PeaceValidation] PASS 后台全占复验、第三国领土和金额验证")

    gs = fixture()
    gs.provinces[3].occupiedBy, gs.provinces[4].occupiedBy = 1, 1
    for _, f in pairs(gs.factions) do Ledger.reconcile(gs, f) end
    before = count(gs)
    assert(Diplomacy.submitPeace(gs, 1, 2, { provinces = {}, annexAll = true }))
    assert(gs.provinces[3].ownerId == 1 and gs.provinces[4].ownerId == 1, "全占吞并失败")
    assert(gs.provinces[3].garrison == 100 and gs.provinces[4].garrison == 100, "吞并清空了本国占领军")
    assertTotals(gs, before)
    print("[PeaceValidation] PASS 全占吞并与占领军守恒")

    gs = fixture()
    gs.provinces[3].occupiedBy = 1
    gs.provinces[3].garrison = 0
    gs.battles[3] = { att = { factionId = 3, size = 40, morale = 60 },
        def = { factionId = 1, size = 100, morale = 30 } }
    gs.provinces[5].garrison = 60
    for _, f in pairs(gs.factions) do Ledger.reconcile(gs, f) end
    before = count(gs)
    local retained = gs.battles[3]
    gs.pendingPeace = { proposerId = 2, targetId = 1,
        warStartedAt = War.findWar(gs, 1, 2).startedAt, terms = { provinces = {}, gold = 0 } }
    assert(Diplomacy.respondPendingPeace(gs, true))
    assert(gs.battles[3] == retained and gs.provinces[3].occupiedBy == 1 and #gs.peaceReturns == 1,
        "归还占领破坏了第三国战斗的守军归属")
    assertTotals(gs, before)
    gs.battles[3] = nil
    gs.provinces[3].garrison = 100
    gs.armies[1] = { factionId = 3, size = 40, from = 3, to = 5, totalHours = 72, progress = 0 }
    Diplomacy.processMonthlyDiplomacy(gs)
    assert(gs.provinces[3].occupiedBy == nil and #gs.peaceReturns == 0, "第三战结束后未归还占领")
    assertTotals(gs, before)
    print("[PeaceValidation] PASS 第三国交战延期归还与归属守恒")

    gs = fixture()
    gs.factions[2].provinces = { 3, 4 }
    gs.provinces[3].occupiedBy = 1
    gs.provinces[4].ownerId = 1
    gs.provinces[2].ownerId = 2
    local oldOwner = gs.provinces[2].ownerId
    local prepared, newOffer = Diplomacy.preparePeaceOffer(gs, 1, 2)
    assert(prepared and type(newOffer) == "table")
    local listed = false
    for _, p in ipairs(newOffer.provinceList) do if p.id == 2 then listed = true end end
    assert(listed and oldOwner == 2, "后续易主新领土未出现在和谈列表")
    print("[PeaceValidation] PASS 按当前归属列出可索取省份")

    gs = fixture()
    -- 100省大国占一个非首都：占领收益0.6，成本0.3，应能够谈下这一个省。
    for pid = 7, 104 do
        gs.provinces[pid] = { id = pid, name = "乙新省" .. pid, ownerId = 2,
            garrison = 0, neighbors = {}, population = 1000 }
        gs.factions[2].provinces[#gs.factions[2].provinces + 1] = pid
    end
    War.startWar(gs, 1, 2)
    gs.provinces[4].occupiedBy = 1
    assert(math.abs(War.getScore(gs, War.findWar(gs, 1, 2), 1) - 0.6) < 1e-8)
    assert(math.abs(War.getProvinceCost(gs, 4, 1) - 0.3) < 1e-8, "大国单省割地成本不配套")
    oldChance = War.getPeaceAcceptChance
    War.getPeaceAcceptChance = function() return 1 end
    local accepted, why = Diplomacy.submitPeace(gs, 1, 2, { provinces = { 4 } })
    War.getPeaceAcceptChance = oldChance
    assert(accepted, tostring(why))
    assert(gs.provinces[4].ownerId == 1, "占大国一省仍然无法割让")
    print("[PeaceValidation] PASS 大国单省占领收益足以索取该省")

    gs = fixture()
    gs.provinces[3].occupiedBy = 1
    gs.provinces[4].garrison = 0
    gs.battles[4] = { att = { factionId = 1, size = 70, morale = 35, unitMix = { archer = 1 } },
        def = { factionId = 2, size = 80, morale = 45, unitMix = { heavy_inf = 1 } } }
    for _, f in pairs(gs.factions) do Ledger.reconcile(gs, f) end
    before = count(gs)
    gs.pendingPeace = { proposerId = 2, targetId = 1, terms = {} }
    assert(Diplomacy.respondPendingPeace(gs, true))
    assert(gs.battles[4] == nil and gs.provinces[4].garrison == 80,
        "双边停战未撤出战斗或未保留守军")
    assert(not gs.relations[1][2].atWar and not gs.relations[2][1].atWar, "停战状态不对称")
    assertTotals(gs, before)
    print("[PeaceValidation] PASS 双边战斗残兵与双向外交停战")

    gs = fixture()
    gs.provinces[3].occupiedBy = 1
    gs.provinces[1].occupiedBy, gs.provinces[2].occupiedBy = 3, 3
    for _, f in pairs(gs.factions) do Ledger.reconcile(gs, f) end
    before = count(gs)
    gs.pendingPeace = { proposerId = 2, targetId = 1, terms = {} }
    assert(Diplomacy.respondPendingPeace(gs, true))
    assert(#gs.armies == 1 and gs.armies[1].size == 100 and gs.armies[1].factionId == 1
        and gs.armies[1].exiled and gs.armies[1].retreating, "无安全本土残兵被清除或未流亡待归")
    assert(gs.provinces[1].occupiedBy == 3 and gs.provinces[2].occupiedBy == 3,
        "双边停战改变第三国占领")
    assertTotals(gs, before)
    Military.updateArmies(gs, 200, 100)
    assert(#gs.armies == 1 and gs.armies[1].exiled and gs.armies[1].size == 100
        and gs.provinces[3].ownerId == 2 and gs.provinces[3].garrison == 0,
        "流亡军推进成了新的占领/进攻或丢失兵力")
    gs.provinces[1].occupiedBy = nil
    gs.provinces[1].garrison = 0
    before[3] = before[3] - 100
    Ledger.reconcile(gs, gs.factions[3])
    Military.updateArmies(gs, 1, 1)
    assert(#gs.armies == 0 and gs.provinces[1].garrison == 100, "安全本土恢复后流亡军未归营")
    assertTotals(gs, before)
    print("[PeaceValidation] PASS 无安全本土残兵保留、不再攻击、安全本土恢复后归营")

    gs = fixture()
    War.startWar(gs, 2, 3)
    gs.provinces[3].occupiedBy = 3
    for _, f in pairs(gs.factions) do Ledger.reconcile(gs, f) end
    before = count(gs)
    local payerGold, receiverGold = gs.factions[2].gold, gs.factions[3].gold
    oldChance = War.getPeaceAcceptChance
    War.getPeaceAcceptChance = function() return 1 end
    local aiAccepted, aiReason = Diplomacy.proposePeace(gs, 2, 3)
    War.getPeaceAcceptChance = oldChance
    assert(aiAccepted, tostring(aiReason))
    assert(gs.provinces[3].ownerId == 3 and gs.factions[2].gold == payerGold - 80
        and gs.factions[3].gold == receiverGold + 80, "AI求和割地或付款方向颠倒")
    assertTotals(gs, before)
    print("[PeaceValidation] PASS AI之间让步割地与赔款方向")

    gs = fixture()
    gs.pendingPeace = { proposerId = 2, targetId = 1, warStartedAt = -1, terms = {} }
    assert(not Diplomacy.respondPendingPeace(gs, true) and War.findWar(gs, 1, 2), "过期和约结束了新战争")
    local unrelated = { proposerId = 2, targetId = 3, terms = {} }
    gs.pendingPeace = unrelated
    oldChance = War.getPeaceAcceptChance
    War.getPeaceAcceptChance = function() return 1 end
    local whiteAccepted, whiteReason = Diplomacy.submitPeace(gs, 1, 2, {})
    War.getPeaceAcceptChance = oldChance
    assert(whiteAccepted, tostring(whiteReason))
    assert(gs.pendingPeace == unrelated, "双边停战清除了第三国待回应条约")
    print("[PeaceValidation] PASS 过期条约拒绝与第三国待回应隔离")

    gs = fixture()
    gs.provinces[3].occupiedBy = 1
    gs.peaceReturns = { { provinceId = 3, ownerId = 2, occupiedBy = 1 } }
    gs.relations[1][2].atWar, gs.relations[2][1].atWar = false, false
    War.endWar(gs, War.findWar(gs, 1, 2))
    gs.provinces[3].occupiedBy = 3
    Diplomacy.processMonthlyDiplomacy(gs)
    assert(gs.provinces[3].occupiedBy == 3 and gs.provinces[3].garrison == 100
        and #gs.peaceReturns == 0, "过期归还队列清掉第三国的新占领")
    print("[PeaceValidation] PASS 第三国新占领不被旧归还记录覆盖")

    gs = fixture()
    gs.provinces[1].occupiedBy = 2
    oldChance = War.getPeaceAcceptChance
    War.getPeaceAcceptChance = function() return 1 end
    local negativeAccepted, negativeReason = Diplomacy.submitPeace(gs, 1, 2, {})
    War.getPeaceAcceptChance = oldChance
    assert(negativeAccepted, tostring(negativeReason))
    assert(gs.provinces[1].occupiedBy == nil, "负分白和没有归还对手占领")
    print("[PeaceValidation] PASS 负分可提出零成本白和")

    gs = fixture()
    local Settlement = require("systems.PeaceSettlement")
    local oneValid, one = Settlement.validate(gs, 1, 2, { provinces = { 3 } })
    local twoValid, two = Settlement.validate(gs, 1, 2, { provinces = { 3, 3 } })
    assert(oneValid and twoValid and #two.terms.provinces == 1 and one.cost == two.cost,
        "重复省份未规范化或重复收费")
    gs.provinces[3].ownerId, gs.provinces[4].ownerId = 3, 3
    assert(not Settlement.validate(gs, 1, 2, { annexAll = true }), "空领土被当成全占")
    print("[PeaceValidation] PASS 条款省份去重与空全境拒绝")

    gs = fixture()
    gs.pendingPeace = { proposerId = 2, targetId = 1, terms = {} }
    assert(Diplomacy.respondPendingPeace(gs, true))
    local cooldown = gs.relations[1][2].peaceCooldown
    Diplomacy.processMonthlyDiplomacy(gs)
    assert(gs.relations[1][2].peaceCooldown == cooldown - 1
        and gs.relations[2][1].peaceCooldown == cooldown - 1, "双向独立冷却未同时递减")
    for _ = 2, cooldown do Diplomacy.processMonthlyDiplomacy(gs) end
    assert(gs.relations[1][2].peaceCooldown == 0 and gs.relations[2][1].peaceCooldown == 0,
        "停战期过后反向仍永久冷却")
    local shared = { value = 0, atWar = false, peaceCooldown = 5 }
    gs.relations[1][2], gs.relations[2][1] = shared, shared
    Diplomacy.processMonthlyDiplomacy(gs)
    assert(shared.peaceCooldown == 4, "共享关系对象冷却重复递减")
    print("[PeaceValidation] PASS 双向独立与共享关系冷却按月正确推进")
    print("[PeaceValidation] ALL PASS")
end

function Start()
    local ok, err = pcall(run)
    if not ok then
        print("[PeaceValidation] FAIL " .. tostring(err))
        log:Write(LOG_ERROR, "[PeaceValidation] FAIL " .. tostring(err))
    end
    engine:Exit()
end

-- 军事存档离线回归：纯合成状态，不 require main、不建 UI、不启动游戏局。
local MilitarySave = require("save.MilitarySave")
local Ledger = require("systems.MilitaryLedger")

local function fixture()
    return {
        playerFactionId = 1,
        factions = {
            [1] = { id = 1, name = "存档甲", armySize = 99999, capitalId = 1013,
                recruitCooldown = 4, provinceCommanders = { [1013] = 81, [7001] = 82 } },
            [8] = { id = 8, name = "存档乙", armySize = 99999, capitalId = 7001,
                recruitCooldown = 0, provinceCommanders = {} },
        },
        provinces = {
            [1013] = { id = 1013, ownerId = 1, garrison = 30, population = 1000,
                unitMix = { archer = 1 }, morale = 75, stability = 60 },
            [4001] = { id = 4001, ownerId = 8, occupiedBy = 1, garrison = 20,
                population = 800, unitMix = { heavy_cav = 1 }, morale = 60 },
            [7001] = { id = 7001, ownerId = 8, garrison = 0, population = 900,
                unitMix = { heavy_inf = 1 }, morale = 35 },
        },
        relations = { [1] = { [8] = { atWar = true } }, [8] = { [1] = { atWar = true } } },
        manpower = { [1013] = 0, [4001] = 17.5, [7001] = 29 },
        armies = {
            { id = 12, factionId = 1, from = 1013, to = 4001, routePath = { 4001, 7001 },
                size = 40, initialSize = 50, morale = 46, progress = 31.5, totalHours = 48,
                realElapsed = 1.75, forced = true, unitMix = { light_inf = 0.6, archer = 0.4 } },
            { factionId = 8, from = 4001, to = 7001, size = 15, morale = 20, progress = 0,
                totalHours = 1, realElapsed = 0, retreating = true, exiled = true,
                unitMix = { heavy_inf = 1 } },
        },
        battles = { [7001] = {
            att = { factionId = 1, size = 10, initialSize = 27, morale = 42, unitMix = { archer = 1 } },
            def = { factionId = 8, size = 20, initialSize = 63, morale = 35, unitMix = { heavy_inf = 1 } },
            progress = 0.25, accHours = 17.5,
        } },
        wars = { ["1_8"] = { aId = 1, dId = 8, aProvinces = 1, dProvinces = 2, startedAt = 55,
            aProvinceIds = { 1013 }, dProvinceIds = { 4001, 7001 }, aCapitalId = 1013, dCapitalId = 7001,
            aArmy = 170, dArmy = 180, aBattle = 3.5, dBattle = -3.5, aLoss = 17, dLoss = 43,
            stats = { [1] = { side = "a", lost = 17, killed = 43 },
                [8] = { side = "d", lost = 43, killed = 17 } } } },
        pendingPeace = { proposerId = 8, targetId = 1, warStartedAt = 55,
            terms = { provinces = { 4001 }, gold = 12, food = 0, vassal = false, annexAll = false } },
        peaceReturns = { { provinceId = 4001, ownerId = 8, occupiedBy = 1, startedAt = 42 } },
    }
end

local function roundtrip(data)
    return cjson.decode(cjson.encode(data))
end

local function run()
    local gs = fixture()
    local data = MilitarySave.capture(gs)
    assert(data.manpower["1013"] == 0 and data.manpower[1013] == nil, "兵源未显式字符串键保存")
    assert(data.battles["7001"] and data.factions["1"].provinceCommanders["1013"] == 81,
        "战斗/统帅稀疏ID未字符串保存")
    local decoded = roundtrip(data)
    local target = fixture()
    local prov, mix = target.provinces[4001], target.provinces[4001].unitMix
    local relations = target.relations
    MilitarySave.restore(target, decoded)
    assert(target.manpower[1013] == 0 and target.manpower[4001] == 17.5
        and target.manpower["1013"] == nil, "兵源JSON往返丢零值或数字键")
    assert(target.factions[1].provinceCommanders[1013] == 81
        and target.factions[1].provinceCommanders[7001] == 82
        and target.factions[1].provinceCommanders["1013"] == nil, "统帅数字键丢失")
    assert(target.factions[1].recruitCooldown == 4 and target.factions[8].recruitCooldown == 0
        and target.factions[1].capitalId == 1013, "冷却或首都丢失")
    local army = target.armies[1]
    assert(army.id == 12 and army.from == 1013 and army.to == 4001 and army.routePath[2] == 7001
        and #army.routePath == 2 and army.unitMix.archer == 0.4 and army.forced
        and army.realElapsed == 1.75 and army.progress == 31.5 and army.totalHours == 48
        and army.initialSize == 50, "行军路线/混编/急行军/进度未完整恢复")
    assert(target.armies[2].retreating and target.armies[2].exiled and target.armies[2].size == 15,
        "流亡军令变成普通进攻军令或兵力丢失")
    local battle = target.battles[7001]
    assert(battle and target.battles["7001"] == nil and battle.att.size == 10
        and battle.def.size == 20 and battle.att.initialSize == 27 and battle.def.initialSize == 63
        and battle.att.unitMix.archer == 1 and battle.def.morale == 35
        and battle.progress == 0.25 and battle.accHours == 17.5, "进行中战斗状态丢失")
    local war = target.wars["1_8"]
    assert(war.aProvinceIds[1] == 1013 and war.dProvinceIds[2] == 7001 and #war.dProvinceIds == 2
        and war.aCapitalId == 1013 and war.dCapitalId == 7001 and war.aArmy == 170 and war.dArmy == 180,
        "战争按场历史快照丢失或被当前兵力覆盖")
    assert(war.stats[1].lost == 17 and war.stats[8].killed == 17 and war.stats["1"] == nil
        and war.aBattle == 3.5 and war.dLoss == 43, "战争stats数字键或累计战损丢失")
    assert(target.pendingPeace.warStartedAt == 55 and target.pendingPeace.terms.provinces[1] == 4001
        and target.pendingPeace.terms.food == 0 and target.pendingPeace.terms.vassal == false,
        "同一场战争和谈丢失")
    assert(#target.peaceReturns == 1 and target.peaceReturns[1].startedAt == 42
        and target.peaceReturns[1].occupiedBy == 1, "延后归还占领队列丢失")
    assert(prov == target.provinces[4001] and prov.ownerId == 8 and prov.occupiedBy == 1
        and prov.garrison == 20 and prov.unitMix == mix and target.relations == relations,
        "军事restore修改了省归属/驻军/兵种或外交基础数据")
    local _, actualA = Ledger.snapshot(target, target.factions[1])
    local _, actualD = Ledger.snapshot(target, target.factions[8])
    assert(actualA == 100 and actualD == 35 and target.factions[1].armySize == actualA
        and target.factions[8].armySize == actualD, "恢复总账漏占领驻军、在途、战斗或流亡军")
    assert(gs.factions[1].armySize == 99999, "capture修改了输入总账")
    print("[MilitarySaveValidation] PASS JSON往返、数字键、完整军令/战斗/战争快照、总账守恒")

    -- capture/restore 均不能留下嵌套表别名；不经JSON时也要隔离。
    target = fixture()
    MilitarySave.restore(target, data)
    target.armies[1].routePath[1] = -1
    target.wars["1_8"].stats[1].lost = -1
    assert(data.armies[1].routePath[1] == 4001 and data.wars["1_8"].stats["1"].lost == 17,
        "restore修改穿透原快照")
    gs.armies[1].unitMix.archer = 0.1
    gs.battles[7001].att.size = 0
    assert(data.armies[1].unitMix.archer == 0.4 and data.battles["7001"].att.size == 10,
        "capture未复制嵌套军事状态")
    print("[MilitarySaveValidation] PASS capture/restore嵌套表隔离")

    target = fixture()
    local legacy = roundtrip({ factions = { ["1"] = { capitalId = 1013 }, ["8"] = {} },
        armies = { { factionId = 1, from = 1013, to = 4001, size = 5, morale = 60,
            progress = 12, totalHours = 72 } },
        wars = { ["1_8"] = { aId = 1, dId = 8, aProvinces = 1, dProvinces = 2,
            stats = { ["1"] = { lost = 7, killed = 8 } } } } })
    MilitarySave.restore(target, legacy)
    war = target.wars["1_8"]
    assert(next(target.manpower) == nil and next(target.battles) == nil and #target.peaceReturns == 0
        and target.pendingPeace == nil and next(target.factions[1].provinceCommanders) == nil
        and target.factions[1].recruitCooldown == 0 and target.factions[8].capitalId == nil,
        "旧档未清旧局军事残留或沿用旧首都")
    assert(#target.armies == 1 and target.armies[1].size == 5 and target.armies[1].realElapsed == 0
        and target.armies[1].unitMix == nil and target.armies[1].routePath == nil
        and target.armies[1].exiled == nil, "旧军令未兼容或保留上一局字段")
    assert(war.aProvinceIds == nil and war.dProvinceIds == nil and war.aCapitalId == nil
        and war.dCapitalId == nil and war.aArmy == nil and war.dArmy == nil and war.stats[1].lost == 7,
        "旧档擅造历史快照或stats未数字化")
    MilitarySave.restore(target, {})
    assert(next(target.wars) == nil and #target.armies == 0 and next(target.battles) == nil
        and target.factions[1].armySize == 50 and target.factions[8].armySize == 0,
        "缺全部军事字段的档未清残留或未按驻军对账")
    print("[MilitarySaveValidation] PASS 旧档清残留、军令兼容、不伪造历史")

    data = roundtrip(MilitarySave.capture(fixture()))
    data.pendingPeace.warStartedAt = -1
    target = fixture()
    MilitarySave.restore(target, data)
    assert(target.pendingPeace == nil, "过期和谈恢复到了同双方的新战争")
    data.pendingPeace.warStartedAt = nil
    MilitarySave.restore(target, data)
    assert(target.pendingPeace and target.pendingPeace.warStartedAt == nil, "无时间戳老和谈未兼容")
    data.wars = {}
    MilitarySave.restore(target, data)
    assert(target.pendingPeace == nil, "无双边战争仍恢复和谈")
    print("[MilitarySaveValidation] PASS 和谈按双方及warStartedAt校验、无时间戳旧档兼容")

    -- 只有条款带身份时间戳的旧和谈也必须拒绝过期，不能在capture丢掉保护。
    gs = fixture()
    gs.pendingPeace.warStartedAt = nil
    gs.pendingPeace.terms.startedAt = -1
    assert(MilitarySave.capture(gs).pendingPeace == nil, "capture丢掉terms-only过期保护")
    local stale = roundtrip({ wars = MilitarySave.capture(fixture()).wars, pendingPeace = gs.pendingPeace })
    target = fixture()
    MilitarySave.restore(target, stale)
    assert(target.pendingPeace == nil, "terms-only旧过期stamp未拒绝")
    print("[MilitarySaveValidation] PASS terms-only旧过期stamp捕获与恢复拒绝")

    gs.pendingPeace.terms.startedAt = 55
    local stamped = roundtrip(MilitarySave.capture(gs))
    assert(stamped.pendingPeace and stamped.pendingPeace.warStartedAt == nil
        and stamped.pendingPeace.terms.startedAt == 55, "匹配terms.stamp未保存往返")
    MilitarySave.restore(target, stamped)
    assert(target.pendingPeace and target.pendingPeace.warStartedAt == nil
        and target.pendingPeace.terms.startedAt == 55, "匹配terms.stamp恢复丢失")
    print("[MilitarySaveValidation] PASS 匹配terms.stamp捕获JSON往返及恢复保留")

    -- 实际保存入口与合成状态接口必须共用相同的军事捕获器；原省份白名单不动。
    local SaveManager = require("save.SaveManager")
    gs = fixture()
    local collected = roundtrip(SaveManager.collect(gs, { year = 700, month = 3 }))
    assert(collected.manpower["1013"] == 0 and collected.battles["7001"].att.initialSize == 27
        and collected.armies[1].routePath[2] == 7001 and collected.armies[2].exiled
        and collected.factions["1"].provinceCommanders["1013"] == 81
        and collected.wars["1_8"].dArmy == 180 and collected.pendingPeace.warStartedAt == 55
        and #collected.peaceReturns == 1, "SaveManager.collect未接共同capture")
    local ps = collected.provinceStates["4001"]
    assert(ps.ownerId == 8 and ps.occupiedBy == 1 and ps.garrison == 20 and ps.unitMix.heavy_cav == 1,
        "SaveManager军事接线改变原省份保存逻辑")
    print("[MilitarySaveValidation] PASS SaveManager.collect共同capture与原省份字段保持")
    print("[MilitarySaveValidation] ALL PASS")
end

function Start()
    local ok, err = pcall(run)
    if not ok then
        print("[MilitarySaveValidation] FAIL " .. tostring(err))
        log:Write(LOG_ERROR, "[MilitarySaveValidation] FAIL " .. tostring(err))
    end
    engine:Exit()
end

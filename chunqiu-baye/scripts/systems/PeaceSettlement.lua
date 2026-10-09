-- 双边和约校验与收尾。MilitarySystem 由调用方注入，避免外交/军事循环依赖。
-- 不改第三国战斗、占领或军令；返军始终保留真实 factionId。
local GameConfig = require("config.GameConfig")
local WarSystem = require("systems.WarSystem")
local Ledger = require("systems.MilitaryLedger")
local PeaceSettlement = {}

---@param value any
---@return boolean
local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

---@param a number|nil
---@param b number|nil
---@param first number
---@param second number
---@return boolean
local function samePair(a, b, first, second)
    return (a == first and b == second) or (a == second and b == first)
end

---@param gameState table
---@param first number
---@param second number
---@return table|nil
local function relation(gameState, first, second)
    local rows = gameState.relations or {}
    local row = rows[first] or {}
    local reverse = rows[second] or {}
    return row[second] or reverse[first]
end

---@param battle table|nil
---@param first number
---@param second number
---@return boolean
local function bilateralBattle(battle, first, second)
    return battle ~= nil and battle.att ~= nil and battle.def ~= nil
        and samePair(battle.att.factionId, battle.def.factionId, first, second)
end

--- 当前有效目标省，且没有第三国控制/战斗，才允许纳入条约。
---@param gameState table
---@param provinceId number
---@param claimantId number
---@param concederId number
---@return boolean
function PeaceSettlement.canClaimProvince(gameState, provinceId, claimantId, concederId)
    local p = gameState.provinces and gameState.provinces[provinceId]
    if not p or p.ownerId ~= concederId or p.isOcean or p.isWasteland then return false end
    if p.occupiedBy and p.occupiedBy ~= claimantId and p.occupiedBy ~= concederId then return false end
    local battle = gameState.battles and gameState.battles[provinceId]
    return battle == nil or bilateralBattle(battle, claimantId, concederId)
end

--- 纯校验，不修改 terms/战争/关系。返回 {terms, war, cost, allOccupied, targetProvinceIds}。
--- 不在这里限制预算：AI 让步不按让步方的战争分数索赔，玩家 submit 单独检查。
---@param gameState table
---@param claimantId number
---@param concederId number
---@param terms table|nil
---@param expectedStartedAt number|nil 旧档 nil 兼容；同月战争仍非完全唯一身份
---@return boolean ok
---@return any result
function PeaceSettlement.validate(gameState, claimantId, concederId, terms, expectedStartedAt)
    if not gameState or not finite(claimantId) or not finite(concederId) or claimantId == concederId then
        return false, "和约双方无效"
    end
    local factions = gameState.factions or {}
    if not factions[claimantId] or not factions[concederId] then return false, "和约势力不存在" end
    local rel = relation(gameState, claimantId, concederId)
    local war = WarSystem.findWar(gameState, claimantId, concederId)
    if not rel or not rel.atWar or not war then return false, "双方并未处于战争状态" end
    if (rel.peaceCooldown or 0) > 0 then return false, "和平冷却中" end
    if terms ~= nil and type(terms) ~= "table" then return false, "和约条款无效" end
    terms = terms or {}
    local stamp = expectedStartedAt
    if stamp == nil then stamp = terms.startedAt end
    if stamp ~= nil and (not finite(stamp) or stamp ~= war.startedAt) then
        return false, "这份和约已过期，请重新提出条款"
    end
    local gold = terms.gold
    local food = terms.food
    if gold == nil then gold = 0 end
    if food == nil then food = 0 end
    if not finite(gold) or not finite(food) or gold < 0 or food < 0 then
        return false, "赔款和赔粮必须是非负有限数值"
    end
    if (terms.vassal ~= nil and type(terms.vassal) ~= "boolean")
        or (terms.annexAll ~= nil and type(terms.annexAll) ~= "boolean") then
        return false, "附庸或吞并条款无效"
    end
    if terms.vassal and terms.annexAll then return false, "吞并与附庸不能同时要求" end
    local requested = terms.provinces
    if requested == nil then requested = {} end
    if type(requested) ~= "table" then return false, "割地清单无效" end
    local provinces, seen = {}, {}
    for index, pid in pairs(requested) do
        if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or index > #requested
            or not finite(pid) or pid % 1 ~= 0 then return false, "割地清单无效" end
        if not PeaceSettlement.canClaimProvince(gameState, pid, claimantId, concederId) then
            return false, "割让省已易主、无效或涉及第三国控制/战斗"
        end
        if not seen[pid] then provinces[#provinces + 1] = pid; seen[pid] = true end
    end
    table.sort(provinces)
    local targetIds, allOccupied = {}, true
    for pid, p in pairs(gameState.provinces or {}) do
        if p.ownerId == concederId and not p.isOcean and not p.isWasteland then
            targetIds[#targetIds + 1] = pid
            if p.occupiedBy ~= claimantId
                or not PeaceSettlement.canClaimProvince(gameState, pid, claimantId, concederId) then
                allOccupied = false
            end
        end
    end
    table.sort(targetIds)
    allOccupied = #targetIds > 0 and allOccupied
    if terms.annexAll then
        if not allOccupied then return false, "吞并要求对方当前全境非空且全部被你占领，不能涉及第三国战斗" end
        provinces = targetIds
    end
    ---@type number
    local cost = math.ceil(gold / 100) + math.ceil(food / 100)
    for _, pid in ipairs(provinces) do cost = cost + WarSystem.getProvinceCost(gameState, pid, claimantId) end
    if terms.vassal then cost = cost + 30 end
    if not finite(cost) or cost < 0 then return false, "和约成本无效" end
    return true, {
        war = war, cost = cost, allOccupied = allOccupied, targetProvinceIds = targetIds,
        terms = { provinces = provinces, gold = gold, food = food,
            vassal = terms.vassal == true, annexAll = terms.annexAll == true, startedAt = war.startedAt },
    }
end

---@param gameState table
---@param factionId number
---@param pid number|nil
---@param military table
---@return boolean
local function safeHome(gameState, factionId, pid, military)
    local p = pid and gameState.provinces[pid]
    return p ~= nil and p.ownerId == factionId and military.controller(p) == factionId
        and not p.isOcean and not p.isWasteland and not (gameState.battles and gameState.battles[pid])
end

--- 安全首都优先；割都后可重选，未失去所有本土时保留不安全首都作为政治首都。
---@param gameState table
---@param factionId number
---@param military table
---@return number|nil safeProvinceId
local function chooseHome(gameState, factionId, military)
    local faction = gameState.factions[factionId]
    if not faction then return nil end
    if safeHome(gameState, factionId, faction.capitalId, military) then return faction.capitalId end
    local ids = {}
    for pid, p in pairs(gameState.provinces) do
        if p.ownerId == factionId and not p.isOcean and not p.isWasteland then ids[#ids + 1] = pid end
    end
    table.sort(ids)
    for _, pid in ipairs(ids) do
        if safeHome(gameState, factionId, pid, military) then faction.capitalId = pid; return pid end
    end
    local current = faction.capitalId and gameState.provinces[faction.capitalId]
    if not current or current.ownerId ~= factionId or current.isOcean or current.isWasteland then
        faction.capitalId = ids[1]
    end
    return nil
end

---@param gameState table
---@param factionId number
---@return boolean
local function ownsLand(gameState, factionId)
    for _, p in pairs(gameState.provinces) do
        if p.ownerId == factionId and not p.isOcean and not p.isWasteland then return true end
    end
    return false
end

---@param gameState table
---@param text string
local function message(gameState, text)
    if gameState.addMessage then gameState.addMessage(text, "diplomacy", false)
    else
        gameState.log = gameState.log or {}
        gameState.log[#gameState.log + 1] = { text = text, year = gameState.year, month = gameState.month }
    end
end

--- 每份抽出的部队只在这里落一次：本土 -> 流亡等待；败国 -> 明确遣散并扣总账。
---@param gameState table
---@param troop table
---@param military table
---@param preferredId number|nil
local function returnTroops(gameState, troop, military, preferredId)
    if (troop.size or 0) <= 0 then return end
    local fid = troop.factionId
    local faction = gameState.factions[fid]
    if safeHome(gameState, fid, preferredId, military) then
        military.mergeTroops(gameState.provinces[preferredId], "garrison", troop, faction)
        return
    end
    local homeId = chooseHome(gameState, fid, military)
    if homeId then military.mergeTroops(gameState.provinces[homeId], "garrison", troop, faction); return end
    if not ownsLand(gameState, fid) then
        if faction then faction.armySize = math.max(0, (faction.armySize or 0) - troop.size) end
        message(gameState, string.format("和约撤军：%s失去全部本土，明确遣散 %d 名残兵",
            faction and (faction.fullName or faction.name) or tostring(fid), troop.size))
        return
    end
    -- 原军令可复用，清掉进攻路线；Military.updateArmies 对 exiled 只尝试安全本土归营。
    troop.exiled = true
    troop.retreating = true
    troop.routePath = nil
    troop.to = troop.from or troop.fromProvinceId or preferredId
    troop.progress = 0
    troop.realElapsed = 0
    troop.totalHours = 1
    gameState.armies = gameState.armies or {}
    gameState.armies[#gameState.armies + 1] = troop
    message(gameState, string.format("和约撤军：%s %d 名残兵暂无安全本土，流亡待归，不再攻击",
        faction and (faction.fullName or faction.name) or tostring(fid), troop.size))
end

---@param source table
---@param factionId number
---@param field string
---@param provinceId number
---@return table troop
local function troopOf(source, factionId, field, provinceId)
    return { factionId = factionId, size = math.max(0, source[field] or 0),
        unitMix = source.unitMix, morale = source.morale, from = provinceId }
end

--- 重开战争时立即清旧延期归还，避免同月开战又结束后误退新占领。
---@param gameState table
---@param first number
---@param second number
function PeaceSettlement.discardReturns(gameState, first, second)
    local queue = gameState.peaceReturns or {}
    for i = #queue, 1, -1 do
        local item = queue[i]
        if samePair(item.ownerId, item.occupiedBy, first, second) then table.remove(queue, i) end
    end
end

---@param gameState table
---@param provinceId number
---@param ownerId number
---@param occupierId number
---@param startedAt number|nil
local function deferReturn(gameState, provinceId, ownerId, occupierId, startedAt)
    gameState.peaceReturns = gameState.peaceReturns or {}
    for _, item in ipairs(gameState.peaceReturns) do
        if item.provinceId == provinceId and item.ownerId == ownerId and item.occupiedBy == occupierId then return end
    end
    gameState.peaceReturns[#gameState.peaceReturns + 1] = {
        provinceId = provinceId, ownerId = ownerId, occupiedBy = occupierId, startedAt = startedAt,
    }
end

--- 校验成功后提交双边和约。第五参注入 MilitarySystem；不在模块顶层 require 它。
---@param gameState table
---@param claimantId number
---@param concederId number
---@param terms table|nil
---@param military table
---@param expectedStartedAt number|nil
---@return boolean ok
---@return string reason
function PeaceSettlement.settle(gameState, claimantId, concederId, terms, military, expectedStartedAt)
    local ok, result = PeaceSettlement.validate(gameState, claimantId, concederId, terms, expectedStartedAt)
    if not ok then return false, result end
    if not military or not military.controller or not military.mergeTroops or not military.occupy then
        return false, "和约军事收尾接口未就绪"
    end
    local normalized, war = result.terms, result.war
    local rel = relation(gameState, claimantId, concederId)
    if not rel then return false, "和约关系记录不存在" end
    local claimant, conceder = gameState.factions[claimantId], gameState.factions[concederId]
    Ledger.reconcile(gameState, claimant)
    Ledger.reconcile(gameState, conceder)
    local cede, returnAreas, returned = {}, {}, {}
    for _, pid in ipairs(normalized.provinces) do cede[pid] = true end
    for pid, p in pairs(gameState.provinces) do
        if samePair(p.ownerId, p.occupiedBy, claimantId, concederId) and not cede[pid] then
            returnAreas[pid] = true
        end
    end
    gameState.battles = gameState.battles or {}
    -- 只拆 A 对 B；A 对 C/B 对 C 原战斗及双方记录保持原样。
    for pid, battle in pairs(gameState.battles) do
        if bilateralBattle(battle, claimantId, concederId) then
            returned[#returned + 1] = { troop = troopOf(battle.att, battle.att.factionId, "size", pid), preferred = pid }
            returned[#returned + 1] = { troop = troopOf(battle.def, battle.def.factionId, "size", pid), preferred = pid }
            gameState.battles[pid] = nil
        end
    end
    gameState.armies = gameState.armies or {}
    for i = #gameState.armies, 1, -1 do
        local army = gameState.armies[i]
        local fid = army.factionId
        if (fid == claimantId or fid == concederId) and not army.exiled then
            local enemyId = fid == claimantId and concederId or claimantId
            local route = army.routePath
            local finalId = (route and route[#route]) or army.to or army.toProvinceId
            local final = finalId and gameState.provinces[finalId]
            local controller = military.controller(final)
            -- 控制者为第三国的终点保留；攻 C 的军令即使经过 B 也不能整支撤掉。
            local cancel = controller == enemyId
                or (returnAreas[finalId] and controller == fid)
                or (cede[finalId] and fid == concederId)
            if cancel then
                table.remove(gameState.armies, i)
                returned[#returned + 1] = { troop = army }
            end
        end
    end
    -- 先抽出部队再改控制者；第三国战场延期归还，不能把其守军转成原主军。
    for pid in pairs(returnAreas) do
        local p = gameState.provinces[pid]
        if gameState.battles[pid] then deferReturn(gameState, pid, p.ownerId, p.occupiedBy, war.startedAt)
        else
            returned[#returned + 1] = { troop = troopOf(p, p.occupiedBy, "garrison", pid) }
            p.garrison = 0
            p.unitMix = nil
            p.occupiedBy = nil
        end
    end
    for _, pid in ipairs(normalized.provinces) do
        local p = gameState.provinces[pid]
        local controller = military.controller(p)
        local saved = troopOf(p, controller, "garrison", pid)
        p.garrison = 0
        p.unitMix = nil
        military.occupy(gameState, claimantId, pid)
        p.occupiedBy = nil
        if controller == claimantId then military.mergeTroops(p, "garrison", saved, claimant)
        else returned[#returned + 1] = { troop = saved } end
    end
    chooseHome(gameState, claimantId, military)
    chooseHome(gameState, concederId, military)
    for _, item in ipairs(returned) do returnTroops(gameState, item.troop, military, item.preferred) end
    if normalized.vassal then conceder.vassalOf = claimantId end
    for _, key in ipairs({ "gold", "food" }) do
        local amount = normalized[key]
        if amount > 0 then
            local actual = math.min(math.max(0, conceder[key] or 0), amount)
            conceder[key] = (conceder[key] or 0) - actual
            claimant[key] = (claimant[key] or 0) + actual
        end
    end
    Ledger.reconcile(gameState, claimant)
    Ledger.reconcile(gameState, conceder)
    -- 开局两向关系可为独立对象；只同步这双方战争状态，不改全工程关系结构。
    if rel then
        rel.atWar = false
        rel.peaceCooldown = GameConfig.Diplomacy.PEACE_COOLDOWN_MONTHS
    end
    local rows = gameState.relations or {}
    local forward = rows[claimantId] and rows[claimantId][concederId]
    local reverse = rows[concederId] and rows[concederId][claimantId]
    if forward then
        forward.atWar = false
        forward.peaceCooldown = GameConfig.Diplomacy.PEACE_COOLDOWN_MONTHS
    end
    if reverse then
        reverse.atWar = false
        reverse.peaceCooldown = GameConfig.Diplomacy.PEACE_COOLDOWN_MONTHS
    end
    if WarSystem.findWar(gameState, claimantId, concederId) == war then WarSystem.endWar(gameState, war) end
    local pending = gameState.pendingPeace
    if pending and samePair(pending.proposerId, pending.targetId, claimantId, concederId) then
        gameState.pendingPeace = nil
    end
    if gameState.checkElimination then gameState.checkElimination(concederId) end
    return true, "议和成功！"
end

--- 月度处理第三国战场上的延期归还：无重开战争、控制/所有权仍匹配、脱战才释放。
---@param gameState table
---@param military table
function PeaceSettlement.releaseReturns(gameState, military)
    local queue = gameState.peaceReturns or {}
    for i = #queue, 1, -1 do
        local item = queue[i]
        local p = gameState.provinces and gameState.provinces[item.provinceId]
        local rel = relation(gameState, item.ownerId, item.occupiedBy)
        local reopened = WarSystem.findWar(gameState, item.ownerId, item.occupiedBy) or (rel and rel.atWar)
        if reopened or not p or p.ownerId ~= item.ownerId or p.occupiedBy ~= item.occupiedBy then
            table.remove(queue, i)
        elseif not (gameState.battles and gameState.battles[item.provinceId]) then
            local faction = gameState.factions[item.occupiedBy]
            if faction then Ledger.reconcile(gameState, faction) end
            local troop = troopOf(p, item.occupiedBy, "garrison", item.provinceId)
            p.garrison = 0
            p.unitMix = nil
            p.occupiedBy = nil
            returnTroops(gameState, troop, military)
            if faction then Ledger.reconcile(gameState, faction) end
            table.remove(queue, i)
        end
    end
end

return PeaceSettlement

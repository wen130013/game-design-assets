-- 真实兵力账本：纯 Lua、无游戏模块依赖，供经济与兵种构成共用。
-- 只修改人数和国家总账；不删除军令/战斗，不改变士气、兵种、路线或战斗状态。
local MilitaryLedger = {}

---@class MilitaryLedgerEntry
---@field source table 驻军省、在途军令或战斗一方的原始记录
---@field field string garrison 或 size
---@field size number 快照人数

---@param records table
---@return table keys
local function sortedKeys(records)
    local keys = {}
    for key in pairs(records) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        if type(a) == "number" and type(b) == "number" then return a < b end
        return tostring(a) < tostring(b)
    end)
    return keys
end

--- 只读快照；固定顺序为省 ID、军令数组顺序、战斗省 ID（att 先于 def）。
--- 驻军归实控方 occupiedBy or ownerId，军令/战斗方归 factionId。
---@param gameState table|nil
---@param faction table|nil
---@return MilitaryLedgerEntry[] entries
---@return number total
function MilitaryLedger.snapshot(gameState, faction)
    ---@type MilitaryLedgerEntry[]
    local entries = {}
    local total = 0
    if not gameState or not faction or faction.id == nil then return entries, total end
    local function add(source, field)
        local size = math.max(0, source[field] or 0)
        if size > 0 then
            entries[#entries + 1] = { source = source, field = field, size = size }
            total = total + size
        end
    end
    ---@type table<number, table>
    local provinces = gameState.provinces or {}
    for _, pid in ipairs(sortedKeys(provinces)) do
        local p = provinces[pid]
        if (p.occupiedBy or p.ownerId) == faction.id then add(p, "garrison") end
    end
    for _, army in ipairs(gameState.armies or {}) do
        if army.factionId == faction.id then add(army, "size") end
    end
    ---@type table<number, table>
    local battles = gameState.battles or {}
    for _, pid in ipairs(sortedKeys(battles)) do
        local battle = battles[pid]
        if battle.att and battle.att.factionId == faction.id then add(battle.att, "size") end
        if battle.def and battle.def.factionId == faction.id then add(battle.def, "size") end
    end
    return entries, total
end

--- 月度维护费前对齐总账；旧档低估/高估都以真实部队为准。
---@param gameState table
---@param faction table
---@return number total
function MilitaryLedger.reconcile(gameState, faction)
    local _, total = MilitaryLedger.snapshot(gameState, faction)
    if faction then faction.armySize = total end
    return total
end

--- 返人口只去本国仍控制、脱战且非海洋/废土的省。
--- 安全首都优先，否则按省 ID 取首个安全本省；没有安全本省则不返。
---@param gameState table
---@param faction table
---@param count number
---@return number returned
local function returnPopulation(gameState, faction, count)
    ---@type table<number, table>
    local provinces = gameState.provinces or {}
    local battles = gameState.battles or {}
    local function isSafe(p, pid)
        return p and p.ownerId == faction.id and (p.occupiedBy or p.ownerId) == faction.id
            and not p.isOcean and not p.isWasteland and not battles[pid]
    end
    local capitalId = faction.capitalId
    if capitalId and isSafe(provinces[capitalId], capitalId) then
        local capital = provinces[capitalId]
        capital.population = (capital.population or 0) + count
        return count
    end
    for _, pid in ipairs(sortedKeys(provinces)) do
        local p = provinces[pid]
        if isSafe(p, pid) then
            p.population = (p.population or 0) + count
            return count
        end
    end
    return 0
end

--- 按各支真实人数比例扣兵，最大余数法精确分摊整数减员。
--- 余数相同时使用快照序号打破平局，不受 pairs 遍历顺序影响。
--- 先对齐真实总账，再减员；count 超过实兵则至多全员减完。
---@param gameState table
---@param faction table
---@param count number
---@return number reduced 实际减员数
---@return number returned 实际返人口数（无安全本省为 0）
function MilitaryLedger.reduceTroops(gameState, faction, count)
    local entries, total = MilitaryLedger.snapshot(gameState, faction)
    if not gameState or not faction then return 0, 0 end
    faction.armySize = total
    local wanted = math.min(math.max(0, math.floor(count or 0)), total)
    if wanted <= 0 then return 0, 0 end

    local allocations, order = {}, {}
    local assigned = 0
    for i, entry in ipairs(entries) do
        local share = wanted * entry.size / total
        local loss = math.floor(share)
        allocations[i] = loss
        assigned = assigned + loss
        order[#order + 1] = { index = i, remainder = share - loss }
    end
    table.sort(order, function(a, b)
        if a.remainder ~= b.remainder then return a.remainder > b.remainder end
        return a.index < b.index
    end)
    local remaining = wanted - assigned
    for i = 1, remaining do
        local index = order[i].index
        allocations[index] = allocations[index] + 1
    end
    for i, entry in ipairs(entries) do
        entry.source[entry.field] = entry.size - allocations[i]
    end
    faction.armySize = total - wanted
    return wanted, returnPopulation(gameState, faction, wanted)
end

return MilitaryLedger

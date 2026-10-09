-- 军事存档白名单：纯 Lua，仅依赖真实兵力账本，不加载 UI 或游戏入口。
-- capture 返回与 SaveManager 相同的顶层结构；restore 在省份恢复后调用，绝不改省归属/驻军。
local MilitarySave = {}
local Ledger = require("systems.MilitaryLedger")

local ARMY_FIELDS = { "id", "factionId", "from", "to", "fromProvinceId", "toProvinceId",
    "size", "initialSize", "morale", "progress", "totalHours", "realElapsed",
    "routePath", "unitMix", "forced", "retreating", "exiled" }
local SIDE_FIELDS = { "factionId", "size", "initialSize", "morale", "unitMix" }
local WAR_FIELDS = { "aId", "dId", "aProvinces", "dProvinces", "startedAt",
    "aBattle", "dBattle", "aLoss", "dLoss", "aProvinceIds", "dProvinceIds",
    "aCapitalId", "dCapitalId", "aArmy", "dArmy" }
local TERM_FIELDS = { "provinces", "gold", "food", "vassal", "annexAll", "startedAt" }

--- 只复制白名单字段里的普通数据；快照与原状态、恢复结果与存档互不共享嵌套表。
---@param value any
---@return any
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

---@param source table|nil
---@param fields string[]
---@return table
local function fieldsOf(source, fields)
    local out = {}
    for _, field in ipairs(fields) do
        if source and source[field] ~= nil then out[field] = copy(source[field]) end
    end
    return out
end

--- 数字 ID 映射显式存字符串键，避免 cjson 把稀疏数字表当数组或生成 null 洞。
---@param source table|nil
---@param numeric boolean
---@return table
local function idMap(source, numeric)
    local out = {}
    for key, value in pairs(source or {}) do
        local id = tonumber(key)
        if id then out[numeric and id or tostring(id)] = copy(value) end
    end
    return out
end

---@param source table|nil
---@param numeric boolean
---@return table
local function warsOf(source, numeric)
    local out = {}
    for key, war in pairs(source or {}) do
        local rec = fieldsOf(war, WAR_FIELDS)
        rec.stats = idMap(war.stats, numeric)
        -- 六项历史快照没有就保持 nil：不以当前归属/首都/兵力伪造宣战时历史。
        out[key] = rec
    end
    return out
end

---@param source table|nil
---@param numeric boolean
---@return table
local function battlesOf(source, numeric)
    local out = {}
    for key, battle in pairs(source or {}) do
        local id = tonumber(key)
        if id then
            local rec = fieldsOf(battle, { "progress", "accHours" })
            if battle.att then rec.att = fieldsOf(battle.att, SIDE_FIELDS) end
            if battle.def then rec.def = fieldsOf(battle.def, SIDE_FIELDS) end
            out[numeric and id or tostring(id)] = rec
        end
    end
    return out
end

---@param source table|nil
---@return table[]
local function armiesOf(source)
    local out = {}
    for _, army in ipairs(source or {}) do out[#out + 1] = fieldsOf(army, ARMY_FIELDS) end
    return out
end

---@param source table|nil
---@return table[]
local function returnsOf(source)
    local out = {}
    for _, item in ipairs(source or {}) do
        out[#out + 1] = fieldsOf(item, { "provinceId", "ownerId", "occupiedBy", "startedAt" })
    end
    return out
end

--- 仅恢复仍对应同一场双边战争的和谈；旧档无时间戳兼容，不补造时间戳。
---@param pending table|nil
---@param wars table
---@return table|nil
local function pendingOf(pending, wars)
    if not pending then return nil end
    local proposer, target = pending.proposerId, pending.targetId
    if type(proposer) ~= "number" or type(target) ~= "number" or proposer == target then return nil end
    local key = math.min(proposer, target) .. "_" .. math.max(proposer, target)
    local war = wars[key]
    if not war or not ((war.aId == proposer and war.dId == target)
        or (war.aId == target and war.dId == proposer)) then return nil end
    local startedAt = pending.warStartedAt
    if startedAt == nil and pending.terms then startedAt = pending.terms.startedAt end
    if startedAt ~= nil and startedAt ~= war.startedAt then return nil end
    local out = fieldsOf(pending, { "proposerId", "targetId", "warStartedAt" })
    out.terms = fieldsOf(pending.terms, TERM_FIELDS)
    return out
end

--- 构造可直接 cjson.encode 的军事快照；不修改输入状态。
---@param gameState table
---@return table data
function MilitarySave.capture(gameState)
    local data = {
        manpower = idMap(gameState.manpower, false),
        battles = battlesOf(gameState.battles, false),
        armies = armiesOf(gameState.armies),
        wars = warsOf(gameState.wars, false),
        peaceReturns = returnsOf(gameState.peaceReturns),
        factions = {},
    }
    for fid, faction in pairs(gameState.factions or {}) do
        local rec = fieldsOf(faction, { "armySize", "capitalId", "recruitCooldown" })
        rec.provinceCommanders = idMap(faction.provinceCommanders, false)
        data.factions[tostring(fid)] = rec
    end
    data.pendingPeace = pendingOf(gameState.pendingPeace, data.wars)
    return data
end

--- 省份/外交基础状态已恢复后接线；旧档未存字段必须清旧局，不沿用残留。
--- 队伍/战斗缺失的初始规模仍交现有军事逻辑兜底；省兵种比例保持原加载逻辑。
---@param gameState table
---@param data table
function MilitarySave.restore(gameState, data)
    gameState.manpower = idMap(data.manpower, true)
    gameState.battles = battlesOf(data.battles, true)
    gameState.armies = armiesOf(data.armies)
    gameState.wars = warsOf(data.wars, true)
    gameState.peaceReturns = returnsOf(data.peaceReturns)
    gameState.pendingPeace = pendingOf(data.pendingPeace, gameState.wars)
    for _, army in ipairs(gameState.armies) do
        army.progress = army.progress or 0
        army.realElapsed = army.realElapsed or 0
    end
    local savedFactions = data.factions or {}
    for fid, faction in pairs(gameState.factions or {}) do
        local saved = savedFactions[tostring(fid)] or savedFactions[fid] or {}
        faction.provinceCommanders = idMap(saved.provinceCommanders, true)
        faction.recruitCooldown = saved.recruitCooldown or 0
        -- nil 也必须写回：无首都档不能继承上一局或基础剧本的首都。
        faction.capitalId = saved.capitalId
        -- 总账取恢复后的真实驻军/在途/战斗人数，修复旧档虚高/虚低，不改任何部队人数。
        Ledger.reconcile(gameState, faction)
    end
end

return MilitarySave

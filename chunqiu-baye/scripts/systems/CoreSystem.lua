-- ============================================================================
-- CoreSystem.lua — 核心（core）与复国（2026-09-16）
--
-- 解决的问题：**一块地被别人占了之后，原来的主人还算不算数？**
--   * 现在只有 `prov._initOwner`（开局归属）一层，且永不更新 →
--     秦被晋灭、晋被楚灭之后，秦永远回不来了（历史线断了）
--   * 本系统把"谁对这块地有合法主张"记成**一个集合**（可多国同时持有），
--     参考 EU4 的 core：占有满 N 年就获得核心、失地满 M 年后核心过期。
--
-- 三条规则（用户 2026-09-16 拍板）：
--   ① 占有满 3 年 → 拿到该省核心（门槛：国家存续 ≥ 3 年，防"立傀儡刷核心"）
--   ② 失地满 100 年 → 核心过期删除（历史真的翻篇了）
--   ③ 每省最多 5 个核心，超了按"保留分"裁剪：
--        保留分 = 存续年数 / (1 + 已失去年数 / 25)   （同文化组 ×1.5）
--      → 离今天越远、活得越短的国家，越先被忘掉
--
-- 叛乱时怎么用（挂在现成的 rebellion 钩子上）：
--   * 该省有核心持有者 → **复国**（优先已灭亡的：真正的"复国"；否则省并入同文化的存活国）
--   * 一个都没有 → 建新国，名字走 方位前缀 → 地名 → 序号 兜底
--
-- 数据（都挂在既有对象上，不加全局结构）：
--   faction.foundedYear / destroyedYear / culture
--   province.cores = { [factionId] = { gainedYear, lostYear } }
--   province._ownerSinceYear（易主年份，本系统自己观察维护，不改别的系统）
-- ============================================================================

local Cultures = require("data.Cultures")
local MilitarySystem = require("systems.MilitarySystem")

local CoreSystem = {}

--- 占有满 N 年 → 获得核心
CoreSystem.HOLD_YEARS   = 3
--- 失地满 N 年 → 核心过期（用户定：约一百年）
CoreSystem.FORGET_YEARS = 100
--- 每省核心上限（超了按保留分裁剪）
CoreSystem.MAX_PER_PROV = 5
--- 国家存续不足 N 年 → 不给核心（防"立个傀儡刷核心"）
CoreSystem.MIN_LIFE     = 3
--- 同文化组加成（该省文化与候选国同组 → 保留分 ×1.5）
CoreSystem.SAME_GROUP_BONUS = 1.5
--- 保留分里"时间衰减"的尺度：已失去年数每 +25 年，分数减半
CoreSystem.DECAY_YEARS  = 25
--- 起义/复国时的启动资源（不是凭空有国库）
CoreSystem.REVIVE_GOLD = 30
CoreSystem.REVIVE_FOOD = 30
CoreSystem.REVIVE_ARMY = 300

-- ---------------------------------------------------------------------------
-- 小工具
-- ---------------------------------------------------------------------------
--- 当前年份（TimeSystem 没就绪时退回开局年 -770）
--- ⚠️ TimeSystem.getTime() 返回的是 **多返回值**（year, month, day, hour），不是表（踩过）
---@return number
local function currentYear()
    local ok, TimeSystem = pcall(require, "core.TimeSystem")
    if ok and TimeSystem and TimeSystem.getTime then
        local y = TimeSystem.getTime()
        if type(y) == "number" then return math.floor(y) end
    end
    return -770
end

--- 势力的文化 = 首都省的文化（没有首都 → 麾下第一个省 → 记过的 → 华夏）
---@param gameState table
---@param f table
---@return string
local function factionCulture(gameState, f)
    if not f then return "华夏" end
    local pid = f.capitalId or (f.provinces and f.provinces[1])
    local prov = pid and gameState.provinces[pid]
    if prov and prov.culture then return prov.culture end
    return f.culture or "华夏"
end

--- 两个文化是否同组（同组 = 近亲文化，复国时更"名正言顺"）
---@param a string|nil
---@param b string|nil
---@return boolean
local function sameCultureGroup(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local da, db = Cultures.get(a), Cultures.get(b)
    local ga = da and da.group
    local gb = db and db.group
    return ga ~= nil and ga == gb
end

--- 势力存续年数（被灭的算到被灭那年）
---@param f table
---@param year number
---@return number
local function lifetimeOf(f, year)
    local born = (f and f.foundedYear) or year
    local died = (f and f.destroyedYear) or year
    return math.max(1, died - born)
end

-- ---------------------------------------------------------------------------
-- 初始化（幂等）
-- ---------------------------------------------------------------------------
--- 开局：每块有主的地 = 那个主人的第一个核心；顺带记下各势力的建国年与文化
---@param gameState table
function CoreSystem.ensureInit(gameState)
    if gameState._coresReady then return end
    gameState._coresReady = true

    local year = currentYear()
    for _, f in pairs(gameState.factions or {}) do
        f.foundedYear = f.foundedYear or year
        f.culture = f.culture or factionCulture(gameState, f)
    end
    for _, p in pairs(gameState.provinces or {}) do
        if not p.isOcean and not p.isWasteland then
            p.cores = p.cores or {}
            if p.ownerId and not p.cores[p.ownerId] then
                p.cores[p.ownerId] = { gainedYear = year }
            end
            p._coreLastOwner = p.ownerId
            p._ownerSinceYear = year
        end
    end
    print(string.format("[Core] 核心系统就绪（%d 年 · 持有 %d 年得核心 · %d 年过期 · 每省上限 %d）",
        year, CoreSystem.HOLD_YEARS, CoreSystem.FORGET_YEARS, CoreSystem.MAX_PER_PROV))
end

-- ---------------------------------------------------------------------------
-- 保留分：谁更"该被记住"
-- ---------------------------------------------------------------------------
---@param gameState table
---@param fid number
---@param entry table { gainedYear, lostYear }
---@param prov table
---@param year integer
---@return number
function CoreSystem.scoreFor(gameState, fid, entry, prov, year)
    local f = gameState.factions and gameState.factions[fid]
    local score = lifetimeOf(f, year) / (1 + ((year - (entry.lostYear or year)) / CoreSystem.DECAY_YEARS))
    if f and prov and sameCultureGroup(f.culture, prov.culture) then
        score = score * CoreSystem.SAME_GROUP_BONUS
    end
    return score
end

--- 每省核心超上限 → 按保留分裁掉最低的
---@param gameState table
---@param prov table
---@param year integer
function CoreSystem.prune(gameState, prov, year)
    local n = 0
    for _ in pairs(prov.cores) do n = n + 1 end
    if n <= CoreSystem.MAX_PER_PROV then return end

    local list = {}
    for fid, entry in pairs(prov.cores) do
        list[#list + 1] = { fid = fid, score = CoreSystem.scoreFor(gameState, fid, entry, prov, year) }
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    for i = CoreSystem.MAX_PER_PROV + 1, #list do
        prov.cores[list[i].fid] = nil
    end
end

-- ---------------------------------------------------------------------------
-- 每月结算：拿核心 / 标失地 / 过期 / 裁剪
-- ---------------------------------------------------------------------------
---@param gameState table
function CoreSystem.processMonthly(gameState)
    if not gameState._coresReady then CoreSystem.ensureInit(gameState) end
    local year = currentYear()

    -- 势力：建国年 / 灭亡年 / 文化快照
    for _, f in pairs(gameState.factions or {}) do
        f.foundedYear = f.foundedYear or year
        if f.alive == false and not f.destroyedYear then
            f.destroyedYear = year
        end
        f.culture = f.culture or factionCulture(gameState, f)
    end

    -- 省：易主观察 → 得核心 / 失地标记 / 过期 / 裁剪
    for _, p in pairs(gameState.provinces or {}) do
        if not p.isOcean and not p.isWasteland then
            local owner = p.ownerId
            if p._coreLastOwner ~= owner then
                p._coreLastOwner = owner
                p._ownerSinceYear = year
            end
            p.cores = p.cores or {}

            -- ① 现主人持满 N 年 → 拿核心（存续太短的国家不给）
            if owner and p._ownerSinceYear and (year - p._ownerSinceYear) >= CoreSystem.HOLD_YEARS then
                local f = gameState.factions and gameState.factions[owner]
                if f and (year - (f.foundedYear or year)) >= CoreSystem.MIN_LIFE and not p.cores[owner] then
                    p.cores[owner] = { gainedYear = year }
                end
            end

            -- ② 不再持有 → 记失地年份；失地够久 → 核心过期
            for fid, entry in pairs(p.cores) do
                if fid == owner then
                    entry.lostYear = nil
                elseif not entry.lostYear then
                    entry.lostYear = year
                elseif (year - entry.lostYear) >= CoreSystem.FORGET_YEARS then
                    p.cores[fid] = nil   -- 历史翻篇
                end
            end

            -- ③ 超上限 → 裁剪
            CoreSystem.prune(gameState, p, year)
        end
    end
end

-- ---------------------------------------------------------------------------
-- 复国：叛乱时从核心集合里挑"谁最有资格回来"
-- ---------------------------------------------------------------------------
--- 挑候选：优先**已灭亡**的核心持有者（真"复国"），其次存活的（省并入同文化国）。
--- 同类里按保留分最高。
---@param gameState table
---@param provinceId number
---@return table|nil { fid, score, reviving }
function CoreSystem.pickRestorer(gameState, provinceId)
    local p = gameState.provinces and gameState.provinces[provinceId]
    if not p or not p.cores then return nil end
    local year = currentYear()
    local bestDead, bestAlive = nil, nil

    for fid, entry in pairs(p.cores) do
        local f = gameState.factions and gameState.factions[fid]
        if f and fid ~= p.ownerId and (f.provinces and #f.provinces > 0 or f.alive == false) then
            local score = CoreSystem.scoreFor(gameState, fid, entry, p, year)
            if f.alive == false then
                if not bestDead or score > bestDead.score then
                    bestDead = { fid = fid, score = score, reviving = true }
                end
            else
                if not bestAlive or score > bestAlive.score then
                    bestAlive = { fid = fid, score = score, reviving = false }
                end
            end
        end
    end
    return bestDead or bestAlive
end

--- 让 fid 重新拿到 provinceId（复国 / 独立都走这里）
---@param gameState table
---@param fid number
---@param provinceId number
---@return boolean ok
function CoreSystem.restore(gameState, fid, provinceId)
    local f = gameState.factions and gameState.factions[fid]
    local p = gameState.provinces and gameState.provinces[provinceId]
    if not f or not p then return false end
    local year = currentYear()
    local wasDead = (f.alive == false)

    if wasDead then
        f.alive = true
        f.destroyedYear = nil
        f.foundedYear = year          -- 复国算"重新立国"：从今年起算
        f.provinces = {}
        if gameState.eliminatedFactions then gameState.eliminatedFactions[fid] = nil end
    end

    -- 启动资源（起义军不是凭空有国库的）
    f.gold = math.max(f.gold or 0, CoreSystem.REVIVE_GOLD)
    f.food = math.max(f.food or 0, CoreSystem.REVIVE_FOOD)
    f.armySize = math.max(f.armySize or 0, CoreSystem.REVIVE_ARMY)
    f.stability = math.max(tonumber(f.stability) or 0, 40)
    f.capitalId = provinceId

    MilitarySystem.occupy(gameState, fid, provinceId)   -- 交接：列表/反查/稳定度/灭亡判定都它管
    p.occupiedBy = nil                                  -- 起义成功 → 不再算"被占领"
    p.cores = p.cores or {}
    p.cores[fid] = { gainedYear = (p.cores[fid] and p.cores[fid].gainedYear) or year }

    -- 跟原主人翻脸（独立即开战）
    CoreSystem.declareHostility(gameState, fid, p._coreLastOwner)
    return wasDead
end

--- 新势力与旧主人进入战争状态
---@param gameState table
---@param fid number
---@param enemyId number|nil
function CoreSystem.declareHostility(gameState, fid, enemyId)
    if not enemyId or enemyId == fid then return end
    local rel = gameState.relations
    if not rel or not rel[fid] then return end
    if not rel[fid][enemyId] then return end
    rel[fid][enemyId].atWar = true
    rel[fid][enemyId].value = math.min(rel[fid][enemyId].value or 0, -60)
    if rel[enemyId] and rel[enemyId][fid] then
        rel[enemyId][fid].atWar = true
        rel[enemyId][fid].value = math.min(rel[enemyId][fid].value or 0, -60)
    end
end

-- ---------------------------------------------------------------------------
-- 建新国（没有核心可复国时）：命名 = 方位前缀 → 地名 → 序号
-- ---------------------------------------------------------------------------
--- 新势力的 id（取现有最大 id + 1）
---@param gameState table
---@return number
function CoreSystem.nextFactionId(gameState)
    local maxId = 0
    for fid, _ in pairs(gameState.factions or {}) do
        if fid > maxId then maxId = fid end
    end
    return maxId + 1
end

--- 名字是否已被占用
---@param gameState table
---@param name string
---@return boolean
local function nameTaken(gameState, name)
    for _, f in pairs(gameState.factions or {}) do
        if f.name == name then return true end
    end
    return false
end

--- 给新国家起名：① 方位 + 母国名（东周/西周那套）② 省名 ③ 加序号兜底
---@param gameState table
---@param provinceId number
---@param parentId number|nil
---@return string name
---@return string? fullName
function CoreSystem.suggestName(gameState, provinceId, parentId)
    local p = gameState.provinces and gameState.provinces[provinceId]
    local parent = parentId and gameState.factions and gameState.factions[parentId]
    local provName = (p and p.name) or "新邦"
    local name, fullName = nil, nil

    -- ① 方位前缀：新邦领土相对母国首都的方向（中文历史的经典命名法：东周/西周、南明/北元）
    --    ⚠️ 只对**单字国名**用（周→东周 ✅）。多字国名加方位会很难听/重复：
    --       东胡 在东边 → "东东胡"（踩过）→ 多字名直接走地名规则
    if parent and parent.name and #parent.name <= 3 and parent.capitalId then   -- ≤3 字节 = 1 个汉字
        local cap = gameState.provinces[parent.capitalId]
        if cap and cap.center and p and p.center then
            local dx = p.center[1] - cap.center[1]
            local dy = p.center[2] - cap.center[2]      -- 地图 y 向下 = 南
            local dir
            if math.abs(dx) >= math.abs(dy) then
                dir = dx >= 0 and "东" or "西"
            else
                dir = dy >= 0 and "南" or "北"
            end
            local candidate = dir .. parent.name
            if not nameTaken(gameState, candidate) then
                name = candidate
                fullName = candidate .. "国"
            end
        end
    end

    -- ② 地名（用这块地自己的名字）
    if not name and not nameTaken(gameState, provName) then
        name = provName
        fullName = provName .. "国"
    end

    -- ③ 兜底：加序号
    if not name then
        local base = provName
        local i = 2
        while nameTaken(gameState, base .. "（" .. i .. "）") and i < 100 do
            i = i + 1
        end
        name = base .. "（" .. i .. "）"
        fullName = name
    end

    return name, fullName
end

--- 母国色系里派生一个能区分的颜色（同色会看不出是两国）
---@param base table
---@param id number
---@return table
local function variantColor(base, id)
    local r = (base and base[1]) or 150
    local g = (base and base[2]) or 150
    local b = (base and base[3]) or 150
    local k = id % 3
    if k == 0 then r, g = g, r
    elseif k == 1 then g, b = b, g
    else b, r = r, b end
    local function c(v) return math.max(30, math.min(235, v + 18)) end
    return { c(r), c(g), c(b), 255 }
end

--- 建一个新国家（从 provinceId 独立出去）
---@param gameState table
---@param provinceId number
---@param parentId number|nil
---@return number|nil newFactionId
function CoreSystem.foundNewState(gameState, provinceId, parentId)
    local p = gameState.provinces and gameState.provinces[provinceId]
    if not p then return nil end
    local year = currentYear()
    local id = CoreSystem.nextFactionId(gameState)
    local name, fullName = CoreSystem.suggestName(gameState, provinceId, parentId)
    local parent = parentId and gameState.factions and gameState.factions[parentId]

    ---@type table
    local f = {
        id = id,
        name = name,
        fullName = fullName,
        color = variantColor(parent and parent.color, id),
        provinces = {},
        capitalId = provinceId,
        gold = CoreSystem.REVIVE_GOLD,
        food = CoreSystem.REVIVE_FOOD,
        armySize = CoreSystem.REVIVE_ARMY,
        prestige = 20,
        taxRate = 2,
        stability = 45,
        traits = {},
        aiPersonality = "求存",
        diplomacyBonus = 0,
        militaryPenalty = 0,
        alive = true,
        foundedYear = year,
        culture = p.culture or "华夏",
        mods = {},
    }
    f.bonuses = { diplomacy = 0, military = 0, trade = 0, defense = 0, farming = 0, militaryPenalty = 0 }
    gameState.factions[id] = f

    -- 关系表：新势力与所有既有势力都要有行/列（AI 和外交系统假设它存在）
    local relations = gameState.relations
    if relations then
        relations[id] = relations[id] or {}
        for otherId, _ in pairs(gameState.factions) do
            if otherId ~= id then
                if not relations[id][otherId] then
                    relations[id][otherId] = { value = 0, atWar = false, peaceCooldown = 0 }
                end
                if not relations[otherId][id] then
                    relations[otherId][id] = { value = 0, atWar = false, peaceCooldown = 0 }
                end
            end
        end
    end

    -- 资源登记（绑定型资源的初始值）
    local okR, Resources = pcall(require, "data.Resources")
    if okR and Resources and Resources.ensure then Resources.ensure(f) end

    MilitarySystem.occupy(gameState, id, provinceId)
    p.occupiedBy = nil
    CoreSystem.declareHostility(gameState, id, parentId)
    return id
end

-- ---------------------------------------------------------------------------
-- 叛乱钩子：真让省脱离（CultureSystem 只报信，这里动手）
-- ---------------------------------------------------------------------------
---@param gameState table
---@param provinceId number
---@return number|nil 新/复活的势力 id
function CoreSystem.handleRebellion(gameState, provinceId)
    if type(provinceId) ~= "number" then return nil end
    local p = gameState.provinces and gameState.provinces[provinceId]
    if not p or p.isWasteland or p.isOcean then return nil end
    local formerOwner = p.ownerId
    local isPlayersProvince = (formerOwner == gameState.playerFactionId)

    local cand = CoreSystem.pickRestorer(gameState, provinceId)
    local newId, revived
    if cand then
        revived = CoreSystem.restore(gameState, cand.fid, provinceId)
        newId = cand.fid
    else
        newId = CoreSystem.foundNewState(gameState, provinceId, formerOwner)
        revived = false
    end
    if not newId then return nil end

    local nf = gameState.factions[newId]
    local provName = p.name or ("省" .. tostring(provinceId))
    local msg
    if revived then
        msg = string.format("%s 举义复国，光复 %s！", tostring(nf and nf.name), tostring(provName))
    else
        msg = string.format("%s 脱离 %s 自立，据 %s！", tostring(nf and nf.name),
            tostring(gameState.factions[formerOwner] and gameState.factions[formerOwner].name or "旧主"),
            tostring(provName))
    end
    if gameState.addMessage then
        -- notify：只有"跟自己有关"才推通知（用户 2026-09-16 定的口径）
        gameState.addMessage(msg, "war", isPlayersProvince or newId == gameState.playerFactionId)
    end
    print("[Core] " .. msg)
    return newId
end

--- 把 "rebellion" 钩子接上（幂等）
function CoreSystem.registerHooks()
    if CoreSystem._hooked then return end
    CoreSystem._hooked = true
    local Hooks = require("systems.Hooks")
    Hooks.on("rebellion", function(payload)
        if payload and payload.gameState and payload.provinceId then
            CoreSystem.handleRebellion(payload.gameState, payload.provinceId)
        end
    end)
    print("[Core] 已接管 rebellion 钩子（叛乱 → 复国 / 自立）")
end

return CoreSystem

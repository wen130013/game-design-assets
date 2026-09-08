------------------------------------------------------------------------
-- GameState.lua
-- Runtime game state for the Spring and Autumn grand strategy game.
-- Holds live copies of faction / province data, diplomacy relations,
-- armies, messages, and game phase.
------------------------------------------------------------------------

local Factions  = require("data.Factions")
local Provinces = require("data.Provinces")
local Geography = require("data.Geography")
local LeaderSystem = require("systems.LeaderSystem")

local GameState = {}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local VALID_PHASES = { select = true, playing = true, paused = true, gameover = true }
local MAX_MESSAGES = 200  -- ring-buffer cap for the event log

--- Culture groups used for initial relation bonuses.
--- Factions sharing a culture key start with +10 relations when neighboring.
local CULTURE_MAP = {
    -- 华夏 (Central Plains civilisation) - 主要诸侯国
    [1]  = "华夏",   -- 周
    [2]  = "华夏",   -- 齐
    [3]  = "华夏",   -- 晋
    [5]  = "华夏",   -- 秦
    [6]  = "华夏",   -- 鲁
    [7]  = "华夏",   -- 宋
    [8]  = "华夏",   -- 卫
    [9]  = "华夏",   -- 郑
    [10] = "华夏",   -- 燕
    [13] = "华夏",   -- 蔡
    [14] = "华夏",   -- 陈
    [15] = "华夏",   -- 曹
    -- 华夏 - 小国
    [24] = "华夏",   -- 邢
    [25] = "华夏",   -- 邾
    [27] = "华夏",   -- 纪
    [28] = "华夏",   -- 许
    [30] = "华夏",   -- 申
    [31] = "华夏",   -- 虢
    [34] = "华夏",   -- 杞
    [35] = "华夏",   -- 薛
    [36] = "华夏",   -- 滕
    [37] = "华夏",   -- 黄
    [38] = "华夏",   -- 江
    [39] = "华夏",   -- 谭
    -- 荆楚
    [4]  = "荆楚",   -- 楚
    [29] = "荆楚",   -- 息（楚文化圈，后为楚所灭）
    [32] = "荆楚",   -- 邓（荆楚边缘，后为楚所灭）
    [33] = "荆楚",   -- 随（汉东大国，楚文化圈）
    -- 东夷
    [26] = "东夷",   -- 莒（东夷大国）
    -- 吴越
    [11] = "吴越",   -- 吴
    [12] = "吴越",   -- 越
}

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Deep-copy a table (handles nested tables; ignores metatables/functions).
---@param src table
---@return table
local function deepCopy(src)
    if type(src) ~= "table" then return src end
    local copy = {}
    for k, v in pairs(src) do
        copy[k] = deepCopy(v)
    end
    return copy
end

--- Clamp a number between lo and hi.
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Build a set of province ids owned by a given faction id, using the
--- static Factions data.
---@param factionId number
---@return table<number, boolean>
local function factionProvinceSet(factionId)
    local set = {}
    local f = Factions.getById(factionId)
    if f then
        for _, pid in ipairs(f.provinces) do
            set[pid] = true
        end
    end
    return set
end

--- Check whether two factions are geographic neighbors (share at least
--- one pair of adjacent provinces).
---@param f1Provinces table list of province ids
---@param f2Provinces table list of province ids
---@return boolean
local function factionsAreNeighbors(f1Provinces, f2Provinces)
    local f2Set = {}
    for _, pid in ipairs(f2Provinces) do
        f2Set[pid] = true
    end
    for _, pid in ipairs(f1Provinces) do
        local prov = Provinces.byId[pid]
        if prov and prov.neighbors then
            for _, nid in ipairs(prov.neighbors) do
                if f2Set[nid] then return true end
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Current game phase.
---@type string
GameState.phase = "select"

--- Player's chosen faction id (set by init).
---@type number|nil
GameState.playerFactionId = nil

--- Currently selected province id on the map (UI state).
---@type number|nil
GameState.selectedProvinceId = nil

--- Live faction table, keyed by faction id.
---@type table<number, table>
GameState.factions = {}

--- Live province table, keyed by province id.
---@type table<number, table>
GameState.provinces = {}

--- Diplomacy relations: relations[fid1][fid2] = {value, atWar, peaceCooldown}
---@type table<number, table<number, table>>
GameState.relations = {}

--- Reverse index: factionId -> {provinceId, ...} for O(1) territory lookups.
---@type table<number, table>
GameState.factionProvinces = {}

--- Active armies list.
---@type table[]
GameState.armies = {}

--- Message / event log (most recent last).
---@type table[]
GameState.messages = {}

--- 战争警报队列：只存需要玩家关注的战斗事件。
---@type table[]
GameState.warAlerts = {}

--- Auto-incrementing id for armies.
local nextArmyId = 1

------------------------------------------------------------------------
-- init(playerFactionId)
------------------------------------------------------------------------

--- Initialise (or reset) all runtime state.
--- Deep-copies static faction and province data so mutations are safe.
---@param playerFactionId number  The faction id the player has chosen.
function GameState.init(playerFactionId)
    -- 版本号：每次初始化 +1（渲染缓存据此失效重建）
    GameState.version = (GameState.version or 0) + 1
    -- Phase & player --------------------------------------------------
    GameState.phase            = "playing"
    GameState.playerFactionId  = playerFactionId
    GameState.selectedProvinceId = nil

    -- 🔧 模组化架构：势力数据自带 provinces（由模组/示例势力定义），
    --    不再运行时生成领地分配（applyGeneratedTerritories 会清空无主势力）。

    -- Build reverse index: factionId -> {pid, ...} for live use ------
    GameState.factionProvinces = {}
    for _, f in ipairs(Factions.data) do
        GameState.factionProvinces[f.id] = {}
        for _, pid in ipairs(f.provinces) do
            local tbl = GameState.factionProvinces[f.id]
            tbl[#tbl + 1] = pid
        end
    end

    -- Factions --------------------------------------------------------
    GameState.factions = {}
    for _, srcFaction in ipairs(Factions.data) do
        local f        = deepCopy(srcFaction)
        f.alive        = true

        -- Consolidate bonus fields into a bonuses sub-table for clarity.
        f.bonuses = {
            diplomacy = f.diplomacyBonus  or 0,
            military  = f.militaryBonus   or 0,
            trade     = f.tradeBonus      or 0,
            defense   = f.defenseBonus    or 0,
            farming   = f.farmingBonus    or 0,
            militaryPenalty = f.militaryPenalty or 0,
        }

        -- Keep original flat fields so existing code can still read them,
        -- but the bonuses table is the canonical location going forward.

        GameState.factions[f.id] = f
    end

    -- Provinces -------------------------------------------------------
    GameState.provinces = {}
    for _, srcProv in ipairs(Provinces.data) do
        local p = deepCopy(srcProv)

        -- 玩法字段补全：地图包数据（如 EU4 包）可能缺 terrain/经济字段。
        -- 按地理 zone 生成地形与经济（平衡配置在 Geography.zones / terrainStats）
        if not p.terrain then
            local zone = Geography.getZone(p.center[1], p.center[2])
            if zone and zone.terrainWeights then
                local total = 0
                for _, w in pairs(zone.terrainWeights) do total = total + w end
                local r = math.random() * math.max(1, total)
                local terrain = "平原"
                for name, w in pairs(zone.terrainWeights) do
                    r = r - w
                    if r <= 0 then
                        terrain = name
                        break
                    end
                end
                p.terrain = terrain
            else
                p.terrain = "平原"
            end
            local st = Geography.terrainStats[p.terrain]
            if st then
                p.baseGold    = math.random(st.goldMin, st.goldMax)
                p.baseFood    = math.random(st.foodMin, st.foodMax)
                p.population  = math.random(st.popMin, st.popMax)
            else
                p.baseGold   = 2
                p.baseFood   = 3
                p.population = 3000
            end
        end

        -- Skip ocean provinces — they are not part of game logic
        if p.isOcean then
            p.ownerId     = nil
            p.garrison    = 0
            p.stability   = 0
            p.development = 0
            GameState.provinces[p.id] = p
        else
            -- Determine owner from Factions data (already updated by applyGeneratedTerritories).
            p.ownerId     = Factions.getFactionByProvince(p.id) or nil
            p._initOwner  = p.ownerId   -- 初始归属（2026-09-01：判断省是否被占领过，底图据此动态更新颜色+斜线标记）
            p.occupiedBy  = nil         -- 2026-09-01：被占领标记（斜线；条约时正式割让）
            p.culture     = "华夏"       -- 文化（预留：后期文化系统影响叛乱/收入/征兵）
            p.garrison    = 0
            p.stability   = 60          -- starting provincial stability
            p.development = 30          -- starting development (0-100)
            p.isWasteland = p.isWasteland or false   -- 沙漠化（不可占领/无产出）
            GameState.provinces[p.id] = p
        end
    end

    -- Set garrison for owned provinces based on faction army sizes.
    -- Distribute each faction's armySize evenly across its provinces.
    for _, f in pairs(GameState.factions) do
        local provCount = #f.provinces
        if provCount > 0 then
            local perProv = math.floor(f.armySize / provCount)
            local remainder = f.armySize - perProv * provCount
            for i, pid in ipairs(f.provinces) do
                local prov = GameState.provinces[pid]
                if prov and not prov.isOcean then
                    prov.garrison = perProv + (i == 1 and remainder or 0)
                end
            end
        end
    end

    -- Armies (empty at start) -----------------------------------------
    GameState.armies = {}
    nextArmyId       = 1

    -- Messages --------------------------------------------------------
    GameState.messages = {}
    GameState.warAlerts = {}

    -- Diplomacy relations ---------------------------------------------
    GameState.relations = {}
    local factionIds = {}
    for fid, _ in pairs(GameState.factions) do
        factionIds[#factionIds + 1] = fid
    end
    table.sort(factionIds)

    -- Initialise all pairs to 0 / no war.
    for _, fid in ipairs(factionIds) do
        GameState.relations[fid] = {}
        for _, fid2 in ipairs(factionIds) do
            if fid ~= fid2 then
                GameState.relations[fid][fid2] = {
                    value         = 0,
                    atWar         = false,
                    peaceCooldown = 0,
                }
            end
        end
    end

    -- Apply initial relation modifiers --------------------------------

    -- 1) 周 (id=1) starts with +30 to all factions.
    local ZHOU_ID = 1
    if GameState.factions[ZHOU_ID] then
        for _, fid in ipairs(factionIds) do
            if fid ~= ZHOU_ID then
                GameState.relations[ZHOU_ID][fid].value = 30
                GameState.relations[fid][ZHOU_ID].value = 30
            end
        end
    end

    -- 2) Same-culture neighbors get +10.
    for i = 1, #factionIds do
        for j = i + 1, #factionIds do
            local a, b = factionIds[i], factionIds[j]
            local cultureA = CULTURE_MAP[a]
            local cultureB = CULTURE_MAP[b]
            if cultureA and cultureB and cultureA == cultureB then
                local fa = GameState.factions[a]
                local fb = GameState.factions[b]
                if fa and fb and factionsAreNeighbors(fa.provinces, fb.provinces) then
                    local relAB = GameState.relations[a][b]
                    local relBA = GameState.relations[b][a]
                    relAB.value = relAB.value + 10
                    relBA.value = relBA.value + 10
                end
            end
        end
    end

    -- Clamp all relation values into [-100, 100].
    for _, fid in ipairs(factionIds) do
        for _, fid2 in ipairs(factionIds) do
            if fid ~= fid2 then
                local r = GameState.relations[fid][fid2]
                r.value = clamp(r.value, -100, 100)
            end
        end
    end

    -- 君主系统：为所有势力生成/补齐君主（读档后由恢复逻辑处理已有君主）----
    LeaderSystem.initFactions(GameState)

    -- 地图模式（2026-09-01）：political 政治 / region 地区 / war 战争 / ally 盟友 / resource 资源
    GameState.mapMode = "political"
    GameState.allyViewFactionId = playerFactionId   -- 盟友模式视角国（默认玩家）

    -- Initial log entry -----------------------------------------------
    local pf = GameState.factions[playerFactionId]
    local fname = pf and pf.fullName or "未知"
    GameState.addMessage("你选择了" .. fname .. "，逐鹿天下由此开始！", "system")
end

------------------------------------------------------------------------
-- Phase management
------------------------------------------------------------------------

--- Set the current game phase.
---@param newPhase string  One of "select", "playing", "paused", "gameover".
function GameState.setPhase(newPhase)
    if VALID_PHASES[newPhase] then
        GameState.phase = newPhase
    end
end

------------------------------------------------------------------------
-- Faction helpers
------------------------------------------------------------------------

--- Get the player's faction table (live data).
---@return table|nil
function GameState.getPlayerFaction()
    if GameState.playerFactionId then
        return GameState.factions[GameState.playerFactionId]
    end
    return nil
end

--- Get a faction by id.
---@param factionId number
---@return table|nil
function GameState.getFaction(factionId)
    return GameState.factions[factionId]
end

--- Check whether a faction is still alive (owns at least one province).
--- If not, mark alive = false and log elimination.
---@param factionId number
function GameState.checkElimination(factionId)
    local f = GameState.factions[factionId]
    if not f or not f.alive then return end

    -- Count owned provinces using reverse index (fast) or fallback.
    local count = 0
    local idx = GameState.factionProvinces[factionId]
    if idx then
        count = #idx
    else
        for _, p in pairs(GameState.provinces) do
            if p.ownerId == factionId then
                count = count + 1
            end
        end
    end

    if count == 0 then
        f.alive = false
        f.provinces = {}
        GameState.addMessage(f.fullName .. "已灭亡！", "war")

        -- If this was the player, game over.
        if factionId == GameState.playerFactionId then
            GameState.setPhase("gameover")
            GameState.addMessage("你的国家已被消灭，游戏结束。", "system")
        end
    end
end

------------------------------------------------------------------------
-- Province helpers
------------------------------------------------------------------------

--- Get a province by id.
---@param provinceId number
---@return table|nil
function GameState.getProvince(provinceId)
    return GameState.provinces[provinceId]
end

--- 将省份沙漠化/恢复（历史时代3 式：不可占领/无产出/不能驻军）
---@param provinceId number
---@param wasteland boolean  true=化为沙漠, false=恢复
---@return boolean
function GameState.setWasteland(provinceId, wasteland)
    local p = GameState.provinces[provinceId]
    if not p then
        return false
    end
    wasteland = (wasteland ~= false)   -- 默认 true;显式 false 表示恢复
    p.isWasteland = wasteland
    if wasteland then
        -- 沙漠化：清除归属与驻军（先保存旧归属用于同步反向索引）
        local fid = p.ownerId
        p.ownerId  = nil
        p.occupiedBy = nil   -- 沙漠化同时清除占领标记
        p.garrison = 0
        p.stability = 0
        if fid then
            if GameState.factionProvinces[fid] then
                local lst = GameState.factionProvinces[fid]
                for i = #lst, 1, -1 do
                    if lst[i] == provinceId then
                        table.remove(lst, i)
                        break
                    end
                end
            end
            -- 同步势力的 provinces 列表（排行榜/AI 依赖）
            local f = GameState.factions[fid]
            if f and f.provinces then
                for i = #f.provinces, 1, -1 do
                    if f.provinces[i] == provinceId then
                        table.remove(f.provinces, i)
                        break
                    end
                end
            end
        end
    end
    GameState.version = (GameState.version or 0) + 1
    return true
end

------------------------------------------------------------------------
-- Diplomacy helpers
------------------------------------------------------------------------

--- Get the relation record between two factions.
---@param fid1 number
---@param fid2 number
---@return table|nil  {value, atWar, peaceCooldown}
function GameState.getRelation(fid1, fid2)
    if fid1 == fid2 then return nil end
    local row = GameState.relations[fid1]
    if row then return row[fid2] end
    return nil
end

--- Set the relation value between two factions (symmetric).
--- Clamps the value to [-100, 100].
---@param fid1 number
---@param fid2 number
---@param value number
function GameState.setRelation(fid1, fid2, value)
    if fid1 == fid2 then return end
    value = clamp(value, -100, 100)
    local r1 = GameState.getRelation(fid1, fid2)
    local r2 = GameState.getRelation(fid2, fid1)
    if r1 then r1.value = value end
    if r2 then r2.value = value end
end

--- Adjust (add to) the relation value between two factions (symmetric).
---@param fid1 number
---@param fid2 number
---@param delta number
function GameState.adjustRelation(fid1, fid2, delta)
    local r1 = GameState.getRelation(fid1, fid2)
    if r1 then
        local newVal = clamp(r1.value + delta, -100, 100)
        GameState.setRelation(fid1, fid2, newVal)
    end
end

------------------------------------------------------------------------
-- Army helpers
------------------------------------------------------------------------

--- Create a new army and add it to the active list.
---@param factionId number
---@param size number
---@param fromProvinceId number
---@param toProvinceId number
---@return table army  The newly created army record.
function GameState.createArmy(factionId, size, fromProvinceId, toProvinceId)
    local army = {
        id             = nextArmyId,
        factionId      = factionId,
        size           = size,
        fromProvinceId = fromProvinceId,
        toProvinceId   = toProvinceId,
        progress       = 0.0,  -- 0 = at origin, 1 = arrived
        morale         = 100,
    }
    nextArmyId = nextArmyId + 1
    GameState.armies[#GameState.armies + 1] = army
    return army
end

--- Remove an army by its id.
---@param armyId number
function GameState.removeArmy(armyId)
    for i = #GameState.armies, 1, -1 do
        if GameState.armies[i].id == armyId then
            table.remove(GameState.armies, i)
            return
        end
    end
end

--- Find all armies belonging to a faction.
---@param factionId number
---@return table[] armies
function GameState.getArmiesByFaction(factionId)
    local result = {}
    for _, a in ipairs(GameState.armies) do
        if a.factionId == factionId then
            result[#result + 1] = a
        end
    end
    return result
end

------------------------------------------------------------------------
-- Message / event log
------------------------------------------------------------------------

--- Add a message to the event log.
---@param text string
---@param msgType string|nil  e.g. "system", "war", "diplomacy", "economy"
function GameState.addMessage(text, msgType)
    local entry = {
        text = text,
        type = msgType or "info",
        time = os.time and os.time() or 0,
    }
    GameState.messages[#GameState.messages + 1] = entry

    -- Trim if over cap (remove oldest).
    while #GameState.messages > MAX_MESSAGES do
        table.remove(GameState.messages, 1)
    end
end

--- Push a war alert for the player. The main loop pauses and presents it.
---@param alert table {kind, provinceId, attackerId, defenderId, winnerId?, loserId?, provinceName, text, playerSide}
function GameState.pushWarAlert(alert)
    GameState.warAlerts = GameState.warAlerts or {}
    GameState.warAlerts[#GameState.warAlerts + 1] = alert
end

--- Pop the oldest war alert.
---@return table|nil
function GameState.popWarAlert()
    if not GameState.warAlerts or #GameState.warAlerts == 0 then return nil end
    return table.remove(GameState.warAlerts, 1)
end

--- Get the N most recent messages.
---@param n number
---@return table[]
function GameState.getRecentMessages(n)
    n = n or 10
    local total = #GameState.messages
    if n >= total then
        -- Return a shallow copy of the entire list.
        local out = {}
        for i = 1, total do out[i] = GameState.messages[i] end
        return out
    end
    local out = {}
    for i = total - n + 1, total do
        out[#out + 1] = GameState.messages[i]
    end
    return out
end

return GameState

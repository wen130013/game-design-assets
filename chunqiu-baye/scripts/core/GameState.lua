------------------------------------------------------------------------
-- GameState.lua
-- Runtime game state for the Spring and Autumn grand strategy game.
-- Holds live copies of faction / province data, diplomacy relations,
-- armies, messages, and game phase.
------------------------------------------------------------------------

local Factions  = require("data.Factions")
local Provinces = require("data.Provinces")
local Geography = require("data.Geography")
local MapPack   = require("data.MapPack")
-- 真实地理地形表（gen_terrain.py 生成：Natural Earth 地貌 + WWF 生态区 + 农田锚点）
-- 用 pcall 保护：文件缺失时回退旧的随机地形，不影响启动
local hasRealTerrain, TerrainReal = pcall(require, "data.TerrainReal")
if not hasRealTerrain then
    TerrainReal = nil
end
local LeaderSystem = require("systems.LeaderSystem")
local Resources = require("data.Resources")

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

    -- 模组自己的全局格子（2026-09-14 · 洞 2）：模组要存的**全局**东西（不属于某个势力的）
    -- 都塞这里，整格随档走。势力的那一格在 `faction.mods`（同样整格随档）。
    -- 卸载模组 → 把 `mods["模组id"]` 整块删掉即可，不污染本体的字段。
    GameState.mods = {}

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

        -- 资源注册表：补齐"注册型"资源的初始值（绑定型如金/粮本来就在数据里）
        Resources.ensure(f)

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
            -- 真实地理地形优先：gen_terrain.py 离线生成（Natural Earth 地貌 + WWF 生态区 +
            --   大河农业区锚点），逐省固化在 data/TerrainReal.lua（world 包 3235 省 / eu4 包 2386 省）。
            --   ⚠️ 生效范围：**两个地图包都全图启用**（2026-09-23 用户："为什么还是只有这一块
            --     有颜色" → eu4 之前"只改可玩区"的限制取消；world 早已全图）。
            -- ⚠️ 用 **activeId（字符串）**——`getActive()` 返回的是包对象（table），
            --   拿它当 key 查 TerrainReal 永远是 nil（2026-09-23 实测抓到的 bug：
            --   真实地形因此从未生效，全图 95% 落进旧随机成了"平原"）。
            local packTbl = TerrainReal and TerrainReal[MapPack.activeId]
            local useReal = packTbl ~= nil
            local real = useReal and packTbl[p.id] or nil
            if real then
                p.terrain = real
            else
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
            end
            local st = Geography.terrainStats[p.terrain]
            if st then
                -- 2026-09-19 数值规模 ×10（用户："把数字往上升，全部向 CK3 看齐"）：
                --   兵力/人口/钱粮/成本**整体等比放大** → 玩法不变，数字量级向 CK3 靠拢
                p.baseGold    = math.random(st.goldMin, st.goldMax) * 10
                p.baseFood    = math.random(st.foodMin, st.foodMax) * 10
                p.population  = math.random(st.popMin, st.popMax) * 10
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
            -- 驻军士气（2026-09-26）：每省独立，默认满。接战掉、不战回
            --   （战斗在 MilitarySystem.startBattle 读它、结算写回；恢复在 EconomySystem.processMonth）
            p.morale      = 100
            p.stability   = 60          -- starting provincial stability
            p.development = 30          -- starting development (0-100)
            p.isWasteland = p.isWasteland or false   -- 沙漠化（不可占领/无产出）
            GameState.provinces[p.id] = p
        end
    end

    -- 地形分布自检（2026-09-23）：开局时打印一次，便于从日志确认真实地形是否生效。
    --   （曾因 `MapPack.getActive()` 返回包对象而非 id、查表永远 nil，导致真实地形静默失效、
    --     全图 95% 落进旧随机成"平原"——就是靠这条日志定位的，保留作长期体检。）
    do
        local cnt, total = {}, 0
        for _, pv in pairs(GameState.provinces) do
            if not pv.isOcean then
                local key = pv.terrain or "?"
                cnt[key] = (cnt[key] or 0) + 1
                total = total + 1
            end
        end
        local parts = {}
        for k, v in pairs(cnt) do parts[#parts + 1] = string.format("%s=%d", k, v) end
        table.sort(parts)
        print(string.format("[Terrain] 包=%s 陆地省=%d 分布: %s",
            tostring(MapPack.activeId), total, table.concat(parts, " ")))
    end

    -- Set garrison for owned provinces based on faction army sizes.
    --   2026-09-17 改（用户："他们的军队也太多了……而且并不是所有的省份都有的"）：
    --   照 EU4 / HOI4 —— **常备军集中在首都与边境**，内地不设防（garrison = 0）。
    --   原来"平均分到每个省" → 地图上每个省都冒出一块部队牌，又密又糊。
    --     首都   ：40%
    --     边境省 ：平分 60%（边境 = 有邻省属于别的势力；没有边境省时并入首都）
    --     内陆省 ：0（被敌国长驱直入是设计的一部分，跟 EU4 无要塞省一样）
    for _, f in pairs(GameState.factions) do
        local provIds = f.provinces or {}
        local total = f.armySize or 0
        if #provIds > 0 and total > 0 then
            -- 前线省 + 紧张度（2026-09-18 用户："军队所在的更加集中"）：
            --   紧张度 = 接壤几个**外部势力**（同一国多个省只算一次）——
            --   夹在两个邻国之间的省比只挨着一个的更危险，优先给它兵。
            local border = {}          -- { {pid=, threat=} }，随后按 threat 降序
            for _, pid in ipairs(provIds) do
                local prov = GameState.provinces[pid]
                local def = Provinces and Provinces.byId and Provinces.byId[pid]
                if prov and not prov.isOcean and def and def.neighbors then
                    local seenOwner = {}
                    local threat = 0
                    for _, nid in ipairs(def.neighbors) do
                        local np = GameState.provinces[nid]
                        local oid = np and np.ownerId
                        if oid and oid ~= f.id and not seenOwner[oid] then
                            seenOwner[oid] = true
                            threat = threat + 1
                        end
                    end
                    if threat > 0 then
                        border[#border + 1] = { pid = pid, threat = threat }
                    end
                end
            end
            table.sort(border, function(a, b)
                if a.threat ~= b.threat then return a.threat > b.threat end
                return a.pid < b.pid
            end)

            -- 首都（或第一个有效省）
            local capId = f.capitalId
            local capProv = capId and GameState.provinces[capId]
            if not capProv or capProv.isOcean then
                capProv = GameState.provinces[provIds[1]]
                capId = provIds[1]
            end

            -- ★ 驻军省数（2026-09-18 用户口径）：**按国土大小取 1~5 个**
            --   （照 P 社：地图上只有几支"军"，其它省全空 → 不碎、不糊）
            --     ≤3 省 → 1 个（只有首都）  4~10 → 2 个  11~25 → 3 个
            --     26~40  → 4 个            40+  → 5 个
            local n = #provIds
            local slots = 1
            if n > 3  then slots = 2 end
            if n > 10 then slots = 3 end
            if n > 25 then slots = 4 end
            if n > 40 then slots = 5 end

            -- 前线名额 = slots − 1（首都占一个），从最危险的前线省里取
            local picks = {}
            for _, e in ipairs(border) do
                if #picks >= slots - 1 then break end
                if e.pid ~= capId then picks[#picks + 1] = e.pid end
            end

            -- 分兵：首都 40%、其余名额平分 60%；**没有前线名额 → 全部集中首都**
            local capShare = math.floor(total * 0.4)
            local rest = total - capShare
            if #picks == 0 then
                capShare, rest = total, 0
            end
            if capProv then capProv.garrison = capShare end
            if rest > 0 then
                local per = math.floor(rest / #picks)
                local rem = rest - per * #picks
                for i, pid in ipairs(picks) do
                    local prov = GameState.provinces[pid]
                    if prov then
                        prov.garrison = per + (i == 1 and rem or 0)
                    end
                end
            end
        end
    end

    -- 新局军事状态全部清空，避免同进程重开沿用旧战场/兵源/待回应和约。
    GameState.armies = {}
    GameState.battles = {}
    GameState.wars = {}
    GameState.manpower = {}
    GameState.pendingPeace = nil
    GameState.peaceReturns = {}
    nextArmyId       = 1

    -- Messages --------------------------------------------------------
    GameState.messages = {}

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

    -- 战争迷雾（2026-09-24）：
    --   规则 = 接壤视野（EU4 式）——自己省 + 与己方领土接壤的省可见，其余敌军隐藏。
    --   开关来自选国页设置（CountrySelect 写进 _G.CS_SETTINGS.fog：1=关 2=开）。
    --   默认关闭：老存档 / 没走过选国页的开局不该突然被迷雾挡住。
    do
        local cs = _G.CS_SETTINGS
        GameState.fogOfWar = (type(cs) == "table" and cs.fog == 2) or false
        -- 可见省缓存（按 GameState.version + 己方领地签名失效，见 GameState.isProvinceVisible）
        GameState.fogCache_ = nil
        print(string.format("[Fog] 战争迷雾：%s", GameState.fogOfWar and "开启" or "关闭"))
    end

    -- Initial log entry -----------------------------------------------
    --   2026-09-16 用户："一开始选了国家那个通知不要有" → 直接不发
    --   （原来这里和 main.lua 各写一条"你选择了…"，重复 + 骚扰，两份都已删）
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

--- 换"我是谁" —— **换视角，不重置世界**（2026-09-15 新加）
---
--- 和 `GameState.init()` 的区别（**这条最重要**）：
---   `init`   = **开一局**：重建势力表 / 省份 / 时间，一切归零
---   本函数   = **同一局换个人看**：谁占哪、谁在打谁、时间**全都不动**
---
--- 传 `nil` = 进入**看海（观战）模式**。
---
--- 🔥 为什么核心这么简单：月度 AI 循环判断的是 `faction.id ~= GameState.playerFactionId`，
---   所以换完之后 **原来那个国家自动交给 AI、新国家自动不再走 AI** —— 不需要额外代码。
---   顶栏（`GameUI.update`）和地图（`MapRenderer`）也都是**每帧现读** `playerFactionId`，
---   不是建好就固定 → 下一帧就跟着变；`GameUI.update` 里本来就写了"没势力 → 显示观战"的分支。
---@param factionId number|nil 目标势力 id；nil = 看海
---@return boolean ok
---@return string|nil reason
function GameState.setViewFaction(factionId)
    if factionId ~= nil then
        local f = GameState.factions[factionId]
        if not f then return false, "找不到势力 " .. tostring(factionId) end
        if f.alive == false then return false, "「" .. tostring(f.name) .. "」已经灭亡了" end
    end

    GameState.playerFactionId = factionId
    GameState.allyViewFactionId = factionId    -- 盟友视角跟着走（否则地图会停在"看别人的地"）
    GameState.mapMode = "political"            -- 地图模式复位

    if factionId then
        local f = GameState.factions[factionId]
        GameState.addMessage("你现在以「" .. tostring(f.fullName or f.name) .. "」的视角执掌天下。", "system")
    else
        GameState.addMessage("已进入观战模式（看海）—— 天下自行运转，你只是看着。", "system")
    end
    return true, nil
end

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

-- ========================================================================
-- 战争迷雾（2026-09-24）
--   规则 = **接壤视野**（EU4 式）：自己省 + 与己方领土接壤的省可见，其余隐藏。
--   三家参考游戏的差别（已查证）：
--     * CK3  原版**没有**地图迷雾（要装 mod），走的是"外交情报"模型 → 抄不到
--     * EU4  有 Terra Incognita，但敌军在迷雾里**仍能看到位置** → 只是探索机制
--     * AoH3 开局可选三档强度，境外敌军**完全看不见** → 我们取这条（用户选定）
--   自己的军队**永远可见**（三家都如此），所以这里只判"省可不可见"。
-- ========================================================================

--- 算出全部可见省（自己省 + 与其接壤的省），结果缓存。
---   缓存按「己方领地签名」失效：领地一变（占省/丢省）签名就变，重算一次。
---   省份数量两千多，每次全量遍历邻接表也就几千次操作，但渲染每帧都要问
---   "这个省可见吗"，所以必须缓存，不能每帧重算。
---@return table<number, boolean>
function GameState.getVisibleProvinces()
    local pid = GameState.playerFactionId
    -- 没开迷雾 / 看海模式（没有"我"）→ 全部可见
    if not GameState.fogOfWar or not pid then
        return nil            -- nil = 不做限制（调用方据此走快速路径）
    end

    local mine = GameState.factionProvinces and GameState.factionProvinces[pid]
    local sig = (mine and #mine or 0) .. ":"
    if mine then
        for i = 1, #mine do sig = sig .. mine[i] .. "," end
    end
    local cache = GameState.fogCache_
    if cache and cache.sig == sig and cache.version == GameState.version then
        return cache.visible
    end

    local visible = {}
    for i = 1, #(mine or {}) do
        local p = GameState.provinces[mine[i]]
        if p then
            visible[p.id] = true
            -- 接壤省可见（一跳）
            for _, nid in ipairs(p.neighbors or {}) do
                visible[nid] = true
            end
        end
    end

    GameState.fogCache_ = { sig = sig, version = GameState.version, visible = visible }
    return visible
end

--- 某个省在迷雾下是否可见（没开迷雾 → 永远 true）。
---@param provinceId number|nil
---@return boolean
function GameState.isProvinceVisible(provinceId)
    if not provinceId then return false end
    local visible = GameState.getVisibleProvinces()
    if not visible then return true end       -- 没开迷雾
    return visible[provinceId] == true
end

--- 某支军队在迷雾下是否可见（自己的永远可见；别人的看所在省可不可见）。
---@param factionId number|nil 军队归属
---@param provinceId number|nil 军队所在/前往的省
---@return boolean
function GameState.isArmyVisible(factionId, provinceId)
    if not GameState.fogOfWar then return true end
    if factionId == GameState.playerFactionId then return true end   -- 自己的永远可见
    return GameState.isProvinceVisible(provinceId)
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
---@param notify boolean|nil true = 上"通知条"（**涉及玩家**的大事）；默认 false 只进日志
---   2026-09-16 用户："不要随便什么东西就通知，必须得涉及到你的"
function GameState.addMessage(text, msgType, notify)
    local entry = {
        text = text,
        type = msgType or "info",
        time = os.time and os.time() or 0,
        read = false,                      -- 点开看过 → true（从通知条消失）
        notify = notify and true or false, -- 不上通知条的消息只进日志
    }
    GameState.messages[#GameState.messages + 1] = entry

    -- Trim if over cap (remove oldest).
    while #GameState.messages > MAX_MESSAGES do
        table.remove(GameState.messages, 1)
    end
end

-- 🗑 战争警报队列（pushWarAlert / popWarAlert）已于 2026-09-18 删除：
--   用户拍板"删掉战争警报的暂停 + 弹红框，改右上角普通通知"。
--   战斗开始/结束现在走 GameState.addMessage(..., "war", true) → 顶栏下右侧通知条。

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

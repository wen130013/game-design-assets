---@meta
--- Factions.lua - 39 factions for the Spring and Autumn period grand strategy game
---
--- 15 诸侯大国 (IDs 1-15):
---   周, 齐, 晋, 楚, 秦, 鲁, 宋, 卫, 郑, 燕, 吴, 越, 蔡, 陈, 曹
---
--- 8 蛮族 (IDs 16-23):
---   赤狄, 白狄, 长狄, 山戎, 犬戎, 东胡, 林胡, 楼烦
---
--- 16 小国 (IDs 24-39):
---   邢, 邾, 莒, 纪, 许, 息, 申, 西虢, 邓, 随, 杞, 薛, 滕, 黄, 江, 谭
---
--- Unowned territories: 27(中山), 33(晋西),
---   35(莱地), 37(东夷), 38(义渠), 39(汉中), 41(巴地),
---   42(巴东), 43(楚西), 44(楚南), 45(越北), 46(蜀地),
---   47(南蛮), 48(百濮), 49(百越), 50(百越东)

local MapPack = require("data.MapPack")

local Factions = {}

-- 模组化架构：本体不内置势力。
-- 当前加载"示例随机势力"（GeneratedFactions.lua）用于查看地图颜色效果；
-- 正式势力由模组系统提供（mods/ 目录）。
-- ⚠️ 势力数据的**省份 id 与地图包绑定**（同一个 id 在不同包里是不同地方），所以按包提供：
--   * eu4（旧大陆）= 示例随机势力（按 eu4 省份 id 生成，看地图颜色用）
--   * world（新世界）= **无势力**（用户 2026-09-15 定：新世界"只是看一下地图长什么样，
--     不要任何国家"）。将来要给某张图配势力，在 FACTION_SOURCES 里加一行即可。
---@type table<string, table>
local FACTION_SOURCES = {
    eu4 = require("data.GeneratedFactions"),
}

--- 按**当前地图包**重载势力数据（换包必须跟着换；`MapPack.switchTo` 会调它）
function Factions.reload()
    Factions.data = FACTION_SOURCES[MapPack.activeId] or {}
    Factions._provinceToFaction = nil   -- 省份→势力索引按旧表建过，失效
    print(string.format("[Factions] 重载：%d 个势力（包 %s）",
        #Factions.data, tostring(MapPack.activeId)))
end

Factions.reload()   -- 首次加载（require 时执行一次，行为与旧版一致）

--- Color used for unowned / neutral provinces
Factions.neutralColor = {120, 120, 120, 255}

--- Lookup table: province ID -> faction ID (built on first access)
---@type table<number, number>|nil
Factions._provinceToFaction = nil

--- Returns the faction ID that owns a given province, or nil if unowned.
---@param provinceId number
---@return number|nil factionId
function Factions.getFactionByProvince(provinceId)
    if not Factions._provinceToFaction then
        Factions._provinceToFaction = {}
        for _, f in ipairs(Factions.data) do
            for _, pid in ipairs(f.provinces) do
                Factions._provinceToFaction[pid] = f.id
            end
        end
    end
    return Factions._provinceToFaction[provinceId]
end

--- Returns a faction record by its ID, or nil if not found.
---@param factionId number
---@return table|nil
function Factions.getById(factionId)
    for _, f in ipairs(Factions.data) do
        if f.id == factionId then
            return f
        end
    end
    return nil
end

--- Returns the RGBA color for a province (faction color or neutral gray).
---@param provinceId number
---@return table color {r, g, b, a}
function Factions.getProvinceColor(provinceId)
    local fid = Factions.getFactionByProvince(provinceId)
    if fid then
        local f = Factions.getById(fid)
        if f then return f.color end
    end
    return Factions.neutralColor
end

------------------------------------------------------------------------
-- 领地分配
-- 由 GameState.init() 根据省份 ownerId 调用，把各省归属应用到势力上。
------------------------------------------------------------------------

--- Override faction provinces/capitalId with generated data,
--- and scale army/resource stats based on territory size.
---@param factionProvMap table  factionId -> {pid, ...}
---@param factionCapitalProv table  factionId -> capitalProvinceId
function Factions.applyGeneratedTerritories(factionProvMap, factionCapitalProv)
    -- Invalidate cached lookup
    Factions._provinceToFaction = nil

    for _, f in ipairs(Factions.data) do
        local provList = factionProvMap[f.id]
        if provList and #provList > 0 then
            f.provinces = provList
            f.capitalId = factionCapitalProv[f.id] or provList[1]

            -- Scale army size based on province count
            -- Base: ~2500 per province for large states, ~2000 for barbarians, ~1500 for small
            local perProv
            if f.id <= 15 then
                perProv = 2500  -- major states
            elseif f.id <= 23 then
                perProv = 2000  -- barbarians
            else
                perProv = 1500  -- small states
            end
            f.armySize = perProv * #provList

            -- Scale gold and food based on province count
            local goldPerProv = f.id <= 15 and 150 or (f.id <= 23 and 80 or 60)
            local foodPerProv = f.id <= 15 and 120 or (f.id <= 23 and 70 or 50)
            f.gold = goldPerProv * #provList
            f.food = foodPerProv * #provList
        else
            -- Faction has no generated territory — clear to avoid ID collisions
            -- with the new image-extracted province IDs (1-122)
            f.provinces = {}
        end
    end

    -- Rebuild the province-to-faction lookup
    Factions._provinceToFaction = nil
    Factions.getFactionByProvince(0)  -- force rebuild
end

return Factions

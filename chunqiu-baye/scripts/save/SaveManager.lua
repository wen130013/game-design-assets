-- ============================================================================
-- 春秋霸业 - 存档管理器
-- save/SaveManager.lua
--
-- 负责：游戏状态序列化 / 反序列化 / 存档读写
--   * 只存"动态数据"：势力数值、省份归属/驻军/治安/人口、关系、战争、军队、时间
--   * 静态数据（省份多边形/邻接/地形）不存，读档时由 Provinces.data 重建
-- 存储：相对路径 "save.json"（引擎自动项目+用户隔离）
-- ============================================================================

local SaveManager = {}

local MapPack = require("data.MapPack")

local SAVE_PATH = "save.json"
local SAVE_VERSION = 1

--- 检查是否存在可用存档（存档必须匹配当前地图包，地图包切换后旧存档视为不存在）
---@return boolean
function SaveManager.hasSave()
    if not fileSystem or not fileSystem:FileExists(SAVE_PATH) then
        return false
    end
    return SaveManager.load() ~= nil
end

--- 收集可保存数据（不直接序列化整个 gameState，避免表过大/循环引用）
---@param gameState table
---@param timeState table  TimeSystem.getState() 的结果
---@return table data
function SaveManager.collect(gameState, timeState)
    local data = {
        version = SAVE_VERSION,
        mapPack = MapPack.activeId,
        playerFactionId = gameState.playerFactionId,
        time = timeState,
        factions = {},
        provinceStates = {},
        relations = {},
        wars = {},
        armies = {},
    }

    -- 势力关键字段
    for fid, f in pairs(gameState.factions) do
        data.factions[tostring(fid)] = {
            id         = f.id,
            name       = f.name,
            fullName   = f.fullName,
            color      = f.color,
            gold       = f.gold,
            food       = f.food,
            armySize   = f.armySize,
            prestige   = f.prestige,
            stability  = f.stability,
            morale     = f.morale,
            alive      = f.alive,
            capitalId  = f.capitalId,
            provinces  = f.provinces,
            aiPersonality = f.aiPersonality,
            taxLevel   = f.taxLevel,
            leader     = f.leader,
            vassalOf   = f.vassalOf,
            policies   = f.policies,
            policyProgress = f.policyProgress,
            reforms    = f.reforms,
            reformEffects = f.reformEffects,
        }
    end

    -- 省份动态字段（静态部分由 Provinces.data 重建）
    for pid, p in pairs(gameState.provinces) do
        if not p.isOcean then
            data.provinceStates[tostring(pid)] = {
                ownerId    = p.ownerId,
                occupiedBy = p.occupiedBy,
                garrison   = p.garrison,
                stability  = p.stability,
                population = p.population,
                isWasteland = p.isWasteland,
            }
        end
    end

    -- 外交关系（数字键转字符串）
    for a, row in pairs(gameState.relations) do
        for b, rel in pairs(row) do
            if type(rel) == "table" then
                data.relations[tostring(a) .. "_" .. tostring(b)] = {
                    value         = rel.value,
                    atWar         = rel.atWar,
                    peaceCooldown = rel.peaceCooldown,
                }
            end
        end
    end

    -- 战争
    for key, war in pairs(gameState.wars or {}) do
        data.wars[key] = {
            aId = war.aId,
            dId = war.dId,
            aProvinces = war.aProvinces,
            dProvinces = war.dProvinces,
        }
    end

    -- 军队
    for i = 1, #(gameState.armies or {}) do
        local a = gameState.armies[i]
        data.armies[i] = {
            factionId  = a.factionId,
            from       = a.from,
            to         = a.to,
            size       = a.size,
            morale     = a.morale,
            progress   = a.progress,
            totalHours = a.totalHours,
        }
    end

    return data
end

--- 保存当前游戏状态
---@param gameState table
---@param timeState table TimeSystem.getState() 的结果
---@return boolean success
---@return string|nil reason
function SaveManager.save(gameState, timeState)
    local data = SaveManager.collect(gameState, timeState)
    local ok, json = pcall(cjson.encode, data)
    if not ok then
        return false, "序列化失败"
    end

    local file = File(SAVE_PATH, FILE_WRITE)
    if not file or not file:IsOpen() then
        return false, "无法写入存档文件"
    end
    file:WriteString(json)
    file:Close()
    return true, nil
end

--- 读取存档
---@return table|nil data  存档数据（collect 的反结构）
function SaveManager.load()
    if not fileSystem or not fileSystem:FileExists(SAVE_PATH) then
        return nil
    end
    local file = File(SAVE_PATH, FILE_READ)
    if not file or not file:IsOpen() then
        return nil
    end
    local str = file:ReadString()
    file:Close()
    if not str or str == "" then return nil end

    local ok, data = pcall(cjson.decode, str)
    if not ok or type(data) ~= "table" then return nil end
    -- 地图包校验：存档与当前地图包不一致则不可加载（省份 id 空间不同）
    if data.mapPack and data.mapPack ~= MapPack.activeId then
        print("[Save] 存档地图包(" .. tostring(data.mapPack) .. ") ≠ 当前地图包("
            .. tostring(MapPack.activeId) .. ")，忽略旧存档")
        return nil
    end
    return data
end

--- 获取存档概要（供主菜单"继续游戏"显示）
---@return table|nil {factionName, date}
function SaveManager.getSummary()
    local data = SaveManager.load()
    if not data then return nil end
    local f = data.factions and data.factions[tostring(data.playerFactionId)]
    return {
        factionName = f and f.name or nil,
        time = data.time,
    }
end

return SaveManager

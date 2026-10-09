-- ============================================================================
-- 春秋霸业 - 存档管理器
-- save/SaveManager.lua
--
-- 负责：游戏状态序列化 / 反序列化 / 存档读写
--   * 只存"动态数据"：势力数值、省份归属/驻军/治安/人口、关系、战争、军队、时间
--   * 静态数据（省份多边形/邻接/地形）不存，读档时由 Provinces.data 重建
-- 存储：saves/slot_N.json（10 个存档位；旧 save.json 首次访问自动迁移到 1 号位）
-- ============================================================================

local SaveManager = {}

local MapPack = require("data.MapPack")
local MilitarySave = require("save.MilitarySave")

local SAVE_DIR = "saves"
local SLOT_COUNT = 10                      -- 存档位数量
local SAVE_VERSION = 2                     -- v2：世界全球开放后，读旧档时清洗"幽灵沙漠"标记
local LEGACY_SAVE_PATH = "save.json"       -- 旧版单存档（仅首次访问时迁移到 1 号位）
local LAST_SLOT_PATH = "save_last.txt"     -- 最近使用的存档位（"继续游戏"用）
local MIGRATED_FLAG = SAVE_DIR .. "/legacy_migrated.flag"  -- 旧档迁移标记（防止删除后又被迁移复活）

--- 存档位文件路径
---@param slot number
---@return string
local function slotPath(slot)
    return string.format("%s/slot_%d.json", SAVE_DIR, slot)
end

--- 确保存档目录存在
local function ensureSaveDir()
    if fileSystem and fileSystem.DirExists and not fileSystem:DirExists(SAVE_DIR) then
        fileSystem:CreateDir(SAVE_DIR)
    end
end

--- 读取并解析存档文件（含地图包校验）
---@param path string
---@return table|nil
local function readSaveFile(path)
    if not fileSystem or not fileSystem:FileExists(path) then
        return nil
    end
    local file = File(path, FILE_READ)
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
            .. tostring(MapPack.activeId) .. ")，忽略该存档")
        return nil
    end
    -- 旧版本存档兼容（v1）：当时地图自带 2000+ 沙漠省，存档会记录 isWasteland=true。
    -- 世界已全球开放后，这些旧标记若被恢复会被当作"动态沙漠"渲染（黄褐+颗粒），
    -- 出现与新地图不一致的"幽灵沙漠"。v1 档读入时统一清除（编辑器场景文件不受影响）。
    if (data.version or 1) < 2 and data.provinceStates then
        for _, ps in pairs(data.provinceStates) do
            if type(ps) == "table" then
                ps.isWasteland = false
            end
        end
    end
    return data
end

--- 旧版单存档迁移：save.json → 1 号位（只做一次；标记文件防复活，迁移后删除旧档）
local function migrateLegacySave()
    if not fileSystem or not fileSystem:FileExists(LEGACY_SAVE_PATH) then return end
    if fileSystem:FileExists(MIGRATED_FLAG) then return end
    ensureSaveDir()
    -- 先落标记：之后无论玩家如何删改存档位，旧档都不再参与迁移
    local flagFile = File(MIGRATED_FLAG, FILE_WRITE)
    if flagFile and flagFile:IsOpen() then
        flagFile:WriteString("1")
        flagFile:Close()
    end
    if not fileSystem:FileExists(slotPath(1)) then
        local data = readSaveFile(LEGACY_SAVE_PATH)
        if data then
            local ok, json = pcall(cjson.encode, data)
            if ok then
                local file = File(slotPath(1), FILE_WRITE)
                if file and file:IsOpen() then
                    file:WriteString(json)
                    file:Close()
                    print("[Save] 已把旧存档迁移到 1 号存档位")
                end
            end
        end
    end
    -- 迁移（或已有 1 号位）后删除旧档，避免歧义
    fileSystem:Delete(LEGACY_SAVE_PATH)
end

--- 最近使用的存档位（无记录时取第一个非空槽）
---@return number|nil
function SaveManager.getLastSlot()
    if fileSystem and fileSystem:FileExists(LAST_SLOT_PATH) then
        local file = File(LAST_SLOT_PATH, FILE_READ)
        if file and file:IsOpen() then
            local s = file:ReadString()
            file:Close()
            local n = s and tonumber((s:gsub("%s+", "")))
            if n and n >= 1 and n <= SLOT_COUNT and fileSystem:FileExists(slotPath(n)) then
                return n
            end
        end
    end
    for n = 1, SLOT_COUNT do
        if fileSystem and fileSystem:FileExists(slotPath(n)) then
            return n
        end
    end
    return nil
end

--- 记录最近使用的存档位
---@param slot number
function SaveManager.setLastSlot(slot)
    local file = File(LAST_SLOT_PATH, FILE_WRITE)
    if file and file:IsOpen() then
        file:WriteString(tostring(slot))
        file:Close()
    end
end

--- 检查是否存在任意可用存档（任意存档位 / 旧档）
---@return boolean
function SaveManager.hasAnySave()
    migrateLegacySave()
    -- 旧档仅在尚未迁移时可用（迁移后旧档不再算存档，防止删除后复活）
    if fileSystem and fileSystem:FileExists(LEGACY_SAVE_PATH)
        and not fileSystem:FileExists(MIGRATED_FLAG) then
        return true
    end
    for n = 1, SLOT_COUNT do
        if fileSystem and fileSystem:FileExists(slotPath(n)) then
            return true
        end
    end
    return false
end

--- 检查是否存在可用存档（兼容旧调用：任意存档位非空即可）
---@return boolean
function SaveManager.hasSave()
    return SaveManager.hasAnySave()
end

--- 存档位是否存在（含损坏文件）
---@param slot number
---@return boolean
function SaveManager.slotExists(slot)
    return fileSystem ~= nil and fileSystem:FileExists(slotPath(slot)) or false
end

--- 列出全部存档位信息（存档面板用）
---@return table[] 每项 {slot, exists, name, dateText, playset, savedAt, data}
---  data = 解析后的完整存档数据（缩略图用；损坏/空档为 nil），调用方不要再改它
function SaveManager.listSlots()
    migrateLegacySave()
    local out = {}
    for n = 1, SLOT_COUNT do
        local info = { slot = n, exists = false, name = nil, dateText = nil, data = nil }
        if fileSystem and fileSystem:FileExists(slotPath(n)) then
            info.exists = true
            local data = readSaveFile(slotPath(n))
            if data then
                local f = data.factions and data.factions[tostring(data.playerFactionId)]
                info.name = (f and (f.fullName or f.name)) or "未知势力"
                local t = data.time or {}
                info.dateText = string.format("前%d年 %d月", t.year or 0, t.month or 1)
                info.playset = data.mods and data.mods.playset or nil
                info.savedAt = data.saved_at or nil
                info.data = data
            else
                info.name = "（损坏或不兼容）"
            end
        end
        out[#out + 1] = info
    end
    return out
end

--- 保存到指定存档位
---@param slot number
---@param gameState table
---@param timeState table
---@return boolean success
---@return string|nil reason
function SaveManager.saveToSlot(slot, gameState, timeState)
    if slot < 1 or slot > SLOT_COUNT then
        return false, "存档位无效"
    end
    local data = SaveManager.collect(gameState, timeState)
    local ok, json = pcall(cjson.encode, data)
    if not ok then
        return false, "序列化失败"
    end
    ensureSaveDir()
    local file = File(slotPath(slot), FILE_WRITE)
    if not file or not file:IsOpen() then
        return false, "无法写入存档文件"
    end
    file:WriteString(json)
    file:Close()
    SaveManager.setLastSlot(slot)
    return true, nil
end

--- 读取指定存档位

--- 比对"存档当时启用的模组"和"当前游玩集启用的模组"
---
--- 读档前用（2026-09-14 用户设计）：**不再默默把游玩集切回去** ——
---   用户："当你读取存档，采用的模组应该是你**现在**的模组。当然它会给你个界面，
---         显示有些模组进行了修改，问你是**把模组改回去**还是**继续读取**。"
---   → 本函数只**算出差异**，弹窗和三个按钮交给界面层（见 MainMenu 的「读档模组确认」）
---
---@param data table 存档数据
---@return table|nil 差异表；**nil = 完全一致，不用问**
function SaveManager.diffMods(data)
    if not data or not data.mods then return nil end
    local ok, MM = pcall(require, "mods.ModManager")
    if not ok or not MM then return nil end

    local savedIds = {}          -- 存档当时启用的
    for _, m in ipairs(data.mods.list or {}) do
        savedIds[tostring(m.id)] = m
    end
    local curIds = {}            -- 当前游玩集启用的
    for _, m in ipairs(MM.listMods()) do
        if MM.isEnabled(m.id) then curIds[tostring(m.id)] = m end
    end

    local missing, extra, versionChanged = {}, {}, {}
    for id, sm in pairs(savedIds) do
        local cm = curIds[id]
        if not cm then
            missing[#missing + 1] = { id = id, name = tostring(sm.name or id) }
        elseif tostring(cm.version) ~= tostring(sm.version) then
            versionChanged[#versionChanged + 1] = {
                id = id, name = tostring(sm.name or id),
                saveV = tostring(sm.version), curV = tostring(cm.version),
            }
        end
    end
    for id, cm in pairs(curIds) do
        if not savedIds[id] then
            extra[#extra + 1] = { id = id, name = tostring(cm.name or id) }
        end
    end

    -- 排序：让弹窗里的列表稳定（pairs 顺序不定）
    table.sort(missing,        function(a, b) return a.id < b.id end)
    table.sort(extra,          function(a, b) return a.id < b.id end)
    table.sort(versionChanged, function(a, b) return a.id < b.id end)

    if #missing == 0 and #extra == 0 and #versionChanged == 0 then
        return nil      -- 一模一样 → 不用打扰玩家
    end

    local savePlayset = data.mods.playset
    return {
        savePlayset  = savePlayset,
        curPlayset   = MM.getActivePlayset(),
        playsetChanged = (savePlayset ~= nil and savePlayset ~= MM.getActivePlayset()),
        -- 存档那个游玩集**现在还在不在** —— 不在的话「改回存档的模组」这个选项做不了
        savePlaysetExists = (savePlayset ~= nil and MM.playsets_[tostring(savePlayset)] ~= nil),
        missing = missing, extra = extra, versionChanged = versionChanged,
    }
end

--- 模组校验（清单 A15 ⑩/⑫）：缺模组/版本不符 → **只打日志**
---   ⚠️ 2026-09-14：**删掉了"自动切回存档的游玩集"**。
---      原来这里会默默 `setActivePlayset(存档的游玩集)` —— 玩家刚在主菜单改的勾选会被读档无声覆盖，
---      一头雾水。现在改成由界面弹窗问（见 SaveManager.diffMods + MainMenu 的读档确认弹窗）。
---@param data table|nil 存档或剧本数据
local function checkMods(data)
    local diff = SaveManager.diffMods(data)
    if not diff then return end
    if #diff.missing > 0 then
        local names = {}
        for _, m in ipairs(diff.missing) do
            names[#names + 1] = string.format("%s(%s)", m.name, m.id)
        end
        print("[Save] ⚠️ 本档缺少模组：" .. table.concat(names, ", "))
    end
    for _, v in ipairs(diff.versionChanged) do
        print(string.format("[Save] ⚠️ 模组 %s 版本变了：存档 v%s / 当前 v%s",
            v.name, v.saveV, v.curV))
    end
    if #diff.extra > 0 then
        print(string.format("[Save] ℹ️ 当前比本档多 %d 个模组", #diff.extra))
    end
end

---@param slot number
---@return table|nil data
function SaveManager.loadSlot(slot)
    local data = readSaveFile(slotPath(slot))
    if data then
        SaveManager.setLastSlot(slot)
        checkMods(data)
    end
    return data
end

--- 删除指定存档位
---@param slot number
---@return boolean
function SaveManager.deleteSlot(slot)
    if not fileSystem or not fileSystem:FileExists(slotPath(slot)) then
        return false
    end
    local ok = fileSystem:Delete(slotPath(slot))
    if ok and SaveManager.getLastSlot() == slot then
        -- 最近槽被删：记录清掉（下次回退到第一个非空槽）
        if fileSystem:FileExists(LAST_SLOT_PATH) then
            fileSystem:Delete(LAST_SLOT_PATH)
        end
    end
    return ok
end

--- 收集可保存数据（不直接序列化整个 gameState，避免表过大/循环引用）
---@param gameState table
---@param timeState table  TimeSystem.getState() 的结果
---@return table data
function SaveManager.collect(gameState, timeState)
    -- 本局启用的模组（清单 A15 ⑩：存档记录"游玩集 + 模组 + 版本"，读档时校验）
    local modsInfo = { playset = nil, list = {} }
    do
        local ok, MM = pcall(require, "mods.ModManager")
        if ok and MM then
            modsInfo.playset = MM.getActivePlayset()
            for _, m in ipairs(MM.listMods()) do
                if MM.isEnabled(m.id) then
                    modsInfo.list[#modsInfo.list + 1] = {
                        id = m.id, name = m.name, version = m.version,
                    }
                end
            end
        end
    end

    local data = {
        version = SAVE_VERSION,
        mapPack = MapPack.activeId,
        mods = modsInfo,                        -- ⚠️ 这个名字已经被"模组清单"占了（读档校验用）
        -- 模组自己的**全局**格子（2026-09-14 · 洞 2）。叫 modState 是为了避开上面那个 mods。
        -- 势力各有一格在 data.factions[key].mods；这里是"不属于某个势力"的东西（如全局路线表）。
        modState = gameState.mods,
        saved_at = os.date("%Y-%m-%d %H:%M"),   -- 现实保存时间（老存档没有 → 界面显示"—"）
        playerFactionId = gameState.playerFactionId,
        -- 战争迷雾开关（2026-09-24）：随存档走，读档后保持玩家原来的选择
        fogOfWar = gameState.fogOfWar == true,
        -- 人物生死（2026-09-28）：nil 视为开启（老存档没有这个字段 → 默认开）
        mortalityEnabled = gameState.mortalityEnabled ~= false,
        -- 人物系统的 id 计数器（2026-09-17）：不存的话读档后新人物会跟老人物**撞 id**
        characterNextId = require("systems.CharacterSystem")._nextId,
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
            leader     = f.leader,
            -- 人物/官职/后宫（2026-09-17）：**含特质**（traits 是中文名 id 列表）
            --   不存的话读档后官员和特质全丢（特质是"人"的一部分）
            characters = f.characters,
            consorts   = f.consorts,
            leaderId   = f.leaderId,
            vassalOf   = f.vassalOf,
            policies   = f.policies,
            policyAxes = f.policyAxes,   -- 政策光谱轴档位（2026-09-17 起政策是轴不是卡）
            reforms    = f.reforms,
            reformEffects = f.reformEffects,
            -- 资源注册表（2026-09-13）：注册型资源（积分/人力/木材…）随档存
            resources  = f.resources,
            -- 模组自己的格子（2026-09-14 · 洞 2）：**整格存**。
            --   本体不需要知道里面是什么 —— 模组想存什么存什么。
            --   ⚠️ 别写进 f 的其它字段：白名单是"哪些字段能活过存档"的唯一依据，
            --      散着加字段会让本体越来越不知道哪些是模组的。
            mods       = f.mods,
        }
    end

    -- 省份动态字段（静态部分由 Provinces.data 重建）
    for pid, p in pairs(gameState.provinces) do
        if not p.isOcean then
            data.provinceStates[tostring(pid)] = {
                ownerId    = p.ownerId,
                occupiedBy = p.occupiedBy,
                garrison   = p.garrison,
                -- 混编（2026-09-24）：兵种构成随存档保存（老存档没有 → 读档时按主力兵种兜底）
                unitMix    = p.unitMix,
                -- 驻军士气（2026-09-26）：每省独立，随存档保存
                morale     = p.morale,
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

    -- 军事白名单与离线合成状态测试共用 capture；省份动态保存逻辑保持原样。
    local military = MilitarySave.capture(gameState)
    data.manpower = military.manpower
    data.battles = military.battles
    data.wars = military.wars
    data.armies = military.armies
    data.pendingPeace = military.pendingPeace
    data.peaceReturns = military.peaceReturns
    for key, fields in pairs(military.factions) do
        local saved = data.factions[key]
        if saved then
            for name, value in pairs(fields) do saved[name] = value end
        end
    end

    return data
end

--- 保存当前游戏状态（兼容旧调用：存到最近使用的存档位，没有则 1 号位）
---@param gameState table
---@param timeState table TimeSystem.getState() 的结果
---@return boolean success
---@return string|nil reason
function SaveManager.save(gameState, timeState)
    local slot = SaveManager.getLastSlot() or 1
    return SaveManager.saveToSlot(slot, gameState, timeState)
end

--- 读取存档（兼容旧调用：读最近使用的存档位，没有则第一个非空槽 / 旧档）
---@return table|nil data  存档数据（collect 的反结构）
function SaveManager.load()
    migrateLegacySave()
    local slot = SaveManager.getLastSlot()
    if slot then
        return readSaveFile(slotPath(slot))
    end
    -- 仅剩旧档（槽位全空）且尚未迁移时兜底读旧档
    if fileSystem and not fileSystem:FileExists(MIGRATED_FLAG) then
        return readSaveFile(LEGACY_SAVE_PATH)
    end
    return nil
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



-- ============================================================================
-- 剧本（Scenario）读写：与存档同结构，独立文件 scenario.json
-- 编辑器产物；开局时写回 save.json 复用整个读档管线
-- ============================================================================
local SCENARIO_PATH = "scenario.json"

--- 是否存在剧本
---@return boolean
function SaveManager.hasScenario()
    if not fileSystem or not fileSystem:FileExists(SCENARIO_PATH) then
        return false
    end
    return true
end

--- 保存剧本数据（结构 = SaveManager.collect 的反结构）
---@param data table
---@return boolean, string|nil
function SaveManager.saveScenario(data)
    local ok, json = pcall(cjson.encode, data)
    if not ok then
        return false, "剧本序列化失败"
    end
    local file = File(SCENARIO_PATH, FILE_WRITE)
    if not file or not file:IsOpen() then
        return false, "无法写入剧本文件"
    end
    file:WriteString(json)
    file:Close()
    return true, nil
end

--- 读取剧本
---@return table|nil
function SaveManager.loadScenario()
    if not fileSystem or not fileSystem:FileExists(SCENARIO_PATH) then
        return nil
    end
    local file = File(SCENARIO_PATH, FILE_READ)
    if not file or not file:IsOpen() then
        return nil
    end
    local str = file:ReadString()
    file:Close()
    if not str or str == "" then return nil end
    local ok, data = pcall(cjson.decode, str)
    if not ok or type(data) ~= "table" then return nil end
end

return SaveManager

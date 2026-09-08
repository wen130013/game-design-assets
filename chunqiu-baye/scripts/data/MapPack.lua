------------------------------------------------------------------------
-- MapPack.lua — 地图包管理器（2026-08-31）
--
-- "地图包" = 一套完整地图数据（ID 位图 / 成品图瓦片 / 省份数据 / LUT / 投影）。
-- 游戏可选择加载哪套地图包；每个包独立，无继承关系。
--
-- 已注册地图包：
--   * eu4    EU4 欧亚非（主线，2457 省，data/eu4/eu4_provinces.svg 生成）
--   * legacy 旧手绘欧亚非底图（10800×6864，保留可回退）
--
-- 未来新增地图包（如维多利亚3模组）：
--   1. scripts/data/mappacks/<id>.lua 描述配置
--   2. scripts/data/mappacks/<id>/Provinces_N.lua 省份数据分片
--   3. assets/image/<id>/ 位图/成品图/LUT/瓦片
--   4. 注册进 MapPack.registry 即可
--
-- 用法：
--   local MapPack = require("data.MapPack")
--   MapPack.MAP_W / MapPack.BITMAP_PATH / ...（转发当前包字段）
--   MapPack.project(lon, lat) → x, y
--   MapPack.getActive() / MapPack.setActive("eu4")
------------------------------------------------------------------------

local GameConfig = require("config.GameConfig")

local MapPack = {}

-- 地图包注册表（key = 包 id，与主菜单/存档选择一致）
MapPack.registry = {
    legacy = require("data.mappacks.legacy"),
    eu4    = require("data.mappacks.eu4"),
}

-- 当前激活地图包 id（开局/存档选择；默认 EU4 主线）
MapPack.activeId = GameConfig.MapPack or "eu4"

---@type table
local active = MapPack.registry[MapPack.activeId]
if not active then
    print("[MapPack] ⚠️ 未知地图包 '" .. MapPack.activeId .. "'，回退 eu4")
    MapPack.activeId = "eu4"
    active = MapPack.registry.eu4
end

-- 转发当前包的全部配置字段（除函数）
for k, v in pairs(active) do
    if k ~= "project" then
        MapPack[k] = v
    end
end

--- 当前包已登记的所有数据分片前缀（require 用，形如 "data.mappacks.eu4.Provinces_%d"）
---@type string[]
MapPack.provincePrefixes = active.PROVINCE_FILES or {}

--- 投影：经纬度 → 地图逻辑像素
---@param lon number
---@param lat number
---@return number x
---@return number y
function MapPack.project(lon, lat)
    return active.project(lon, lat)
end

--- 当前地图包对象（含全部字段与方法）
---@return table
function MapPack.getActive()
    return active
end

--- 切换到指定地图包（运行时热切换需调用方重建 Provinces 索引与渲染器）
---@param id string
---@return boolean 是否成功
function MapPack.setActive(id)
    local p = MapPack.registry[id]
    if not p then
        return false
    end
    MapPack.activeId = id
    active = p
    for k, v in pairs(active) do
        if k ~= "project" then
            MapPack[k] = v
        end
    end
    MapPack.provincePrefixes = active.PROVINCE_FILES or {}
    print("[MapPack] 切换到地图包: " .. p.name)
    return true
end

print("[MapPack] 激活地图包: " .. active.name)

return MapPack

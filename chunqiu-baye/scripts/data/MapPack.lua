------------------------------------------------------------------------
-- MapPack.lua — 地图包管理器（2026-08-31）
--
-- "地图包" = 一套完整地图数据（ID 位图 / 成品图瓦片 / 省份数据 / LUT / 投影）。
-- 游戏可选择加载哪套地图包；每个包独立，无继承关系。
--
-- 已注册地图包：
--   * eu4    **旧大陆**（显示名，2026-09-15 用户拍板）—— 欧亚非，2457 省，data/eu4/eu4_provinces.svg 生成
--              将来要加的全球图叫「**新世界**」
--
-- ⚠️ 2026-09-14 删掉了 legacy（旧手绘欧亚非，用户拍板）：
--   它和 eu4 **都是欧亚非**（所以看着像），但省份划分/底图/投影都不同，定位只是"回退用"。
--   删之前查出一个 bug：legacy 的 project() 和它自己的底图对不上
--   （公式只覆盖 24 个经度，底图却是整个世界 → 中国会画到大西洋里）。见制作清单。
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
--
-- 🗺 两张图的关系（2026-09-15）：
--   eu4   = 「旧大陆」—— 源 SVG 裁掉西经 31.5° 以西（欧亚非，2457 省，5640×3840）
--   world = 「新世界」—— 同一份源 SVG **不裁**（全球含美洲/大洋洲，3359 省，9600×3840）
--
--   ⚠️ 两包**共用同一个投影**，只差一个裁剪常数（eu4.lua `CROP_X0 = 495` / world.lua `= 0`）。
--      投影的 x 是纯线性的，所以同一个省在两包里**形状完全一样，只是整体平移 +3960**。
--      但它们仍是**两套独立的省份数据**（id 各自从 1 开始），存档按 mapPack id 区分。
--
-- ⚠️ 铁律：**id 永不变**。显示名随便改（eu4 包现在的显示名是「旧大陆」），
--    存档 / 游玩集里记的都是 id。
MapPack.registry = {
    eu4   = require("data.mappacks.eu4"),
    world = require("data.mappacks.world"),
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

--- 当前包的「资源型」省份数据路径（assets 下 JSON，按需下载；无则 nil）
--- 大数据包用这个把省份数据搬出首包（如旧 legacy 把 3.9MB 省份数据塞进 assets/data/）
---@type string|nil
MapPack.provinceAsset = active.PROVINCE_ASSET

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
    MapPack.provinceAsset = active.PROVINCE_ASSET
    print("[MapPack] 切换到地图包: " .. p.name)
    return true
end

--- 换地图包 —— **完整流程**（2026-09-15）
---
--- 为什么不能只调 `setActive`：地图包不只是"几个字段"。省份数据、渲染器的模块级常量、
--- 空间索引，全都是**加载时按当时那个包算好**的。只切字段会出现：
---   ① 省份数据还是旧包的（形状/数量都不对）
---   ② 渲染常量还是旧包的 → **画面压扁 + 点击命中错位**（用户实测"点不了"就是这个）
---
--- 本函数负责"包里这套数据"的四件事，**别的不管**：
---   ① 包的字段（setActive）→ ② 省份数据（Provinces.reload）
---   → ③ 势力数据（Factions.reload，按包给；如新世界无势力）→ ④ 渲染常量+空间索引
---
--- ⚠️ 调用方**还要自己处理**依赖地图的东西：底图缓存、现有的 MapWidget、GameState 里的省份表…
--- ⚠️ **局内（已经开局）不要调**：世界数据全按**省份 id** 存，换包 = 换整套 id 空间，必然对不上。
---    只有"还没开局"的地方（选国页 / 编辑器）能换。业界也一样（P 社换图 mod = 旧存档报废）。
---@param id string 目标包 id
---@return boolean ok
function MapPack.switchTo(id)
    if not MapPack.registry[id] then
        print("[MapPack] ⚠️ switchTo：没有这个包 " .. tostring(id))
        return false
    end
    if id == MapPack.activeId then
        return true     -- 已经是这个包：幂等，不做无谓的重建
    end
    -- ⚠️ 用 require 而不是文件顶部的局部变量：MapPack ↔ Provinces ↔ MapRenderer 三者互相引用，
    --    顶部 require 会成环；放在函数里（调用时才加载）就没这个问题。
    MapPack.setActive(id)                                  -- ① 字段
    require("data.Provinces").reload()                     -- ② 整套省份数据
    require("data.Factions").reload()                      -- ③ 势力数据（按包：新世界 = 无势力）
    require("map.MapRenderer").refreshMapConstants()       -- ④ 渲染常量 + 空间索引
    return true
end

print("[MapPack] 激活地图包: " .. active.name)

return MapPack

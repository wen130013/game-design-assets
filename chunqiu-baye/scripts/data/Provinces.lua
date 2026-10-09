------------------------------------------------------------------------
-- Provinces.lua
-- Province data extracted from the map image by extract_map_provinces.py
-- (line detection → region segmentation → vectorization).
-- Each polygon follows the border lines drawn on the source map image.
------------------------------------------------------------------------

local Provinces = {}

local Geography = require("data.Geography")
local MapPack = require("data.MapPack")
local Profile = require("core.Profile")

-- 省份数据两种来源：
--   ① 脚本分片 require（小数据包，如 eu4：data.mappacks.eu4.Provinces_N.lua）
--   ② 资源型数据（大包用：省份数据放 assets/data/<包>/xxx.dat，内容是 JSON，按需下载）——
--      不进首包，由引擎 DWP 按需下载（首次需要时会自动触发下载）
Provinces.data = {}

--- 读取 assets 下的省份 JSON；本地没有则触发后台下载并返回 nil
---@param path string
---@return table|nil
local function loadAssetProvinces(path)
    if not cache:Exists(path) then
        print("[Provinces] 地图包数据不在本地，触发下载: " .. path)
        cache:DownloadResource(path, function(ok)
            if ok then
                print("[Provinces] 地图包数据下载完成: " .. path .. "（重进编辑器/重开游戏生效）")
            else
                print("[Provinces] ⚠️ 地图包数据下载失败: " .. path)
            end
        end)
        return nil
    end
    local f = cache:GetFile(path)
    if not f then
        print("[Provinces] ⚠️ 读取失败: " .. path)
        return nil
    end
    local txt = f:ReadString()
    f:Close()
    local ok, arr = pcall(cjson.decode, txt)
    if not ok or type(arr) ~= "table" then
        print("[Provinces] ⚠️ JSON 解析失败: " .. path .. " → " .. tostring(arr))
        return nil
    end
    return arr
end

--- 按**当前地图包**重载整套省份数据（2026-09-15 · 换图用）
---
--- 为什么要函数化：原来这一大段是**模块级代码，require 时跑一次就完了**，
--- 换地图包时没有任何办法让它重跑 → 省份数据还停在上一个包。
---
--- ⚠️ require 有缓存，但换包后 `PROVINCE_FILES` 的前缀不同（`data.mappacks.world.Provinces_%d`
---    vs `data.mappacks.eu4.Provinces_%d`）→ 是**新的模块名**，能正常加载。
---    （旧包的分片仍留在 require 缓存里，换回去时秒加载——这是好事。）
---
--- ⚠️ 函数体保持原缩进没重排（只加了两行括号），**是为了把 diff 压到最小、降低改错风险**。
function Provinces.reload()
Provinces.data = {}
Provinces.byId = {}

if MapPack.provinceAsset then
    local arr = loadAssetProvinces(MapPack.provinceAsset)
    if arr then
        for _, p in ipairs(arr) do
            Provinces.data[#Provinces.data + 1] = p
        end
        print(string.format("[Provinces] 资源加载 %d 省（%s）", #arr, MapPack.provinceAsset))
    end
end

-- 数据分片加载：按当前地图包注册的前缀加载（如 data.mappacks.eu4.Provinces_N.lua）
if #Provinces.data == 0 then
    for _, prefix in ipairs(MapPack.provincePrefixes) do
        local part = 1
        while true do
            local ok, chunk = pcall(require, string.format(prefix, part))
            if not ok then
                break
            end
            ---@type table
            chunk = chunk
            for _, p in ipairs(chunk) do
                Provinces.data[#Provinces.data + 1] = p
            end
            part = part + 1
        end
        if part > 1 then
            break
        end
    end
end
-- 2026-09-14：删掉了"兜底加载 data.WorldProvinces"那段死代码 ——
--   那些旧分片文件早就不在了（eu4 迁移时就删了），这段 pcall 每次都失败、纯属摆设。

Profile.mark("省份数据加载（" .. #Provinces.data .. " 省）")

-- Build id→province lookup table
Provinces.byId = {}
for _, p in ipairs(Provinces.data) do
    Provinces.byId[p.id] = p
end

-- Build faction → province list index from ownerId, and pick the province
-- nearest each faction's geographic capital as its capital.
Provinces.factionProvinces = {}
Provinces.factionCapitalProv = {}

for _, p in ipairs(Provinces.data) do
    if p.ownerId then
        local list = Provinces.factionProvinces[p.ownerId]
        if not list then
            list = {}
            Provinces.factionProvinces[p.ownerId] = list
        end
        list[#list + 1] = p.id
    end
end

for fid, list in pairs(Provinces.factionProvinces) do
    local cap = Geography.factionCapitals[fid]
    local bestPid = list[1]
    if cap then
        local bestD = 1e18
        for _, pid in ipairs(list) do
            local p = Provinces.byId[pid]
            local dx = p.center[1] - cap[1]
            local dy = p.center[2] - cap[2]
            local d = dx * dx + dy * dy
            if d < bestD then
                bestD = d
                bestPid = pid
            end
        end
    end
    Provinces.factionCapitalProv[fid] = bestPid
end

log:Write(LOG_INFO, "[Provinces] Loaded " .. #Provinces.data .. " provinces from map image")
end   -- Provinces.reload()

-- 首次加载：保持原行为（require 时就把当前包的数据装好）
Provinces.reload()

------------------------------------------------------------------------
-- Helper: calculate centroid from polygon (area-weighted geometric centroid)
-- 面积加权几何质心：对凹多边形也大致居中（顶点平均会偏移到边上）
------------------------------------------------------------------------
function Provinces.calcCenter(polygon)
    local n = #polygon
    if n < 3 then
        local sx, sy = 0, 0
        for _, p in ipairs(polygon) do
            sx = sx + p[1]
            sy = sy + p[2]
        end
        return { sx / math.max(1, n), sy / math.max(1, n) }
    end
    local cx, cy, area = 0, 0, 0
    for i = 1, n do
        local j = (i % n) + 1
        local xi, yi = polygon[i][1], polygon[i][2]
        local xj, yj = polygon[j][1], polygon[j][2]
        local cross = xi * yj - xj * yi
        area = area + cross
        cx = cx + (xi + xj) * cross
        cy = cy + (yi + yj) * cross
    end
    area = area / 2
    if math.abs(area) < 1e-6 then
        -- 退化多边形：回退顶点平均
        local sx, sy = 0, 0
        for _, p in ipairs(polygon) do
            sx = sx + p[1]
            sy = sy + p[2]
        end
        return { sx / n, sy / n }
    end
    return { cx / (6 * area), cy / (6 * area) }
end

return Provinces

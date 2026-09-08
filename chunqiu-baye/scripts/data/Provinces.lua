------------------------------------------------------------------------
-- Provinces.lua
-- Province data extracted from the map image by extract_map_provinces.py
-- (line detection → region segmentation → vectorization).
-- Each polygon follows the border lines drawn on the source map image.
------------------------------------------------------------------------

local Provinces = {}

local Geography = require("data.Geography")
local MapPack = require("data.MapPack")

-- 数据分片加载：按当前地图包注册的前缀加载（如 data.mappacks.eu4.Provinces_N.lua）
Provinces.data = {}
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
if #Provinces.data == 0 then
    -- 兜底：旧单文件格式
    local ok, chunk = pcall(require, "data.WorldProvinces")
    if ok and chunk then
        for _, p in ipairs(chunk) do
            Provinces.data[#Provinces.data + 1] = p
        end
    end
end

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

------------------------------------------------------------------------
-- 地图包：legacy（旧手绘欧亚非底图）
-- 保留原尺寸/资源路径，便于回退旧地图（2026-08-31 EU4 主线切换前）
-- 省份数据：scripts/data/WorldProvinces_N.lua（data.WorldProvinces_%d）
------------------------------------------------------------------------

local legacy = {}

legacy.id = "legacy"
legacy.name = "手绘欧亚非（旧）"
legacy.desc = "旧手绘欧亚非底图（10800×6864，中国中心投影）"

legacy.MAP_W = 10800
legacy.MAP_H = 6864
legacy.BITMAP_W = 4096
legacy.BITMAP_H = 2603
legacy.BITMAP_SCALE = legacy.MAP_W / legacy.BITMAP_W  -- 2.6367
legacy.BITMAP_PATH = "image/map_political.png"
legacy.PROVINCE_ID_PATH = "image/province_id.png"
legacy.PROVINCE_LUT_PATH = "image/province_lut.png"
legacy.TILE_PATH_PATTERN = "image/tiles/map_%d_%d.png"
legacy.TILE_PX = 1024
legacy.PROVINCE_FILES = { "data.WorldProvinces_%d" }
legacy.INITIAL_ZOOM = 0.20
legacy.MIN_ZOOM = 0.07
legacy.MAX_ZOOM = 6.0
legacy.LUT_W = 4096

--- 旧投影：中国中心（lon 100 → x 0，lat 47 → y 0）
function legacy.project(lon, lat)
    return (lon - 100) * 450, (47 - lat) * 222.222
end

return legacy

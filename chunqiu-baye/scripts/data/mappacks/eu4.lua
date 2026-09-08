-- ============================================================
-- 地图包：EU4 欧亚非（由 gen_eu4_map.py 生成，勿手改）
-- 数据源：data/eu4/eu4_provinces.svg（MapChart EU4，3360 省裁剪后 2457 省）
-- 投影：等距圆柱 lon∈[-180,180] → x∈[0,1200] 裁剪后映射画布
--       lat∈[78.54,-42.03] → y∈[0,480]（MapChart EU4 纬度标定）
-- ============================================================
return {
  id = "eu4",
  name = "EU4 欧亚非",
  desc = "基于欧陆风云4省份划分的欧亚非地图（2457 省，历史粒度适中）",
  MAP_W = 5640,
  MAP_H = 3840,
  BITMAP_W = 5640,
  BITMAP_H = 3840,
  BITMAP_SCALE = 1.0,
  BITMAP_PATH = "image/eu4/map_political.png",
  PROVINCE_ID_PATH = "image/eu4/province_id.png",
  PROVINCE_LUT_PATH = "image/eu4/province_lut.png",
  TILE_PATH_PATTERN = "image/eu4/tiles/map_%d_%d.png",
  TILE_PX = 1024,
  PROVINCE_FILES = { "data.mappacks.eu4.Provinces_%d" },
  INITIAL_ZOOM = 0.160,  -- 全图视角（按 900px 视口宽估）
  MIN_ZOOM = 0.05,
  MAX_ZOOM = 16,   -- 高清位图支撑的大倍率
  LUT_W = 4096,
  -- 投影：lon/lat → 逻辑像素（等距圆柱，纬度 78.54°N..-42.03°S 标定）
  project = function(lon, lat)
    local x = ((lon + 180.0) / 360.0 * 1200.0 - 495) * 8
    local y = (78.54 - lat) * 3.981 * 8
    return x, y
  end,
}

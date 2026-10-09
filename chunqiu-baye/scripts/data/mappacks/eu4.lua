-- ============================================================
-- 地图包：**旧大陆**（id 仍是 eu4）（由 gen_eu4_map.py 生成，勿手改）
-- 数据源：data/eu4/eu4_provinces.svg（MapChart EU4，3360 省裁剪后 2457 省）
-- 投影：等距圆柱 lon∈[-180,180] → x∈[0,1200] 裁剪后映射画布
--       lat∈[78.54,-42.03] → y∈[0,480]（MapChart EU4 纬度标定）
--
-- 🏷 名字（2026-09-15 用户拍板）：显示名改成「**旧大陆**」，将来那张全球图叫「**新世界**」。
--    ⚠️ **id 不动**（还是 "eu4"）—— 铁律：显示名随便改，id 永不变
--      （存档里的 mapPack、游玩集里的 map 记的都是 id，改名字不影响任何已有存档）
-- ============================================================
return {
  id = "eu4",
  name = "旧大陆",
  desc = "欧亚非大陆（基于欧陆风云4省份划分，2457 省）",
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

  -- 整图底图（2026-09-12 起主线）：地图画面直接铺一张完整成品图，不再分块瓦片。
  -- 半分辨率版给低倍率（全图视角）用：显存 1/4、缩小采样更少摩尔纹；
  -- 放大到 ≥1.0 才切全分辨率。两图内容一致，只是尺寸不同。
  -- （由 work_tmp/make_whole_images.py 拼接/缩放生成）
  WHOLE_IMAGE_PATH      = "image/eu4/map_political.png",
  WHOLE_IMAGE_HALF_PATH = "image/eu4/map_political_half.png",
  -- 编辑器"无主底图"（省份全部按无主色渲染，方便涂抹分封）
  NEUTRAL_WHOLE_IMAGE_PATH      = "image/eu4/map_neutral.png",
  NEUTRAL_WHOLE_IMAGE_HALF_PATH = "image/eu4/map_neutral_half.png",
  PROVINCE_FILES = { "data.mappacks.eu4.Provinces_%d" },
  INITIAL_ZOOM = 0.160,  -- 全图视角（按 900px 视口宽估）
  MIN_ZOOM = 0.05,
  -- 最大缩放 2026-09-13 由 16 降到 4（F0 症状③）：
  -- 底图是 5640×3840 位图、与逻辑坐标 1:1，倍率 N 就等于把位图放大 N 倍。
  -- 16 倍时一个地图像素铺满 16 个屏幕像素 → 省界糊成一片（用户反馈"放大发虚"）。
  -- 4 倍是"看得清省界 / 又能贴近看局部"的平衡点（P 社也不给无限放大）。
  MAX_ZOOM = 4,
  LUT_W = 4096,
  -- 投影：lon/lat → 逻辑像素（等距圆柱，纬度 78.54°N..-42.03°S 标定）
  project = function(lon, lat)
    local x = ((lon + 180.0) / 360.0 * 1200.0 - 495) * 8
    local y = (78.54 - lat) * 3.981 * 8
    return x, y
  end,
}

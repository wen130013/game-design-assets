-- ============================================================
-- 地图包：新世界（由 gen_eu4_map.py --pack world 生成，勿手改）
-- 数据源：data/eu4/eu4_provinces.svg（MapChart EU4，3360 省，全球 360°（不裁）后 3359 省）
-- 投影：等距圆柱 lon∈[-180,180] → x∈[0,1200]（全取）
--       lat∈[78.54,-42.03] → y∈[0,480]（MapChart EU4 纬度标定）
-- ⚠️ 生成命令：python3 gen_eu4_map.py --pack world --crop 0 --keep-oceania --no-tiles --no-desert
-- ============================================================
return {
  id = "world",
  name = "新世界",
  desc = "全球地图（含美洲/大洋洲，基于欧陆风云4省份划分）（3359 省）",
  MAP_W = 9600,
  MAP_H = 3840,
  BITMAP_W = 9600,
  BITMAP_H = 3840,
  BITMAP_SCALE = 1.0,
  BITMAP_PATH = "image/world/map_political.png",
  PROVINCE_ID_PATH = "image/world/province_id.png",
  PROVINCE_LUT_PATH = "image/world/province_lut.png",
  TILE_PATH_PATTERN = "image/world/tiles/map_%d_%d.png",
  TILE_PX = 1024,

  -- 整图底图（**主线**，2026-09-12 起）：直接铺一张完整成品图，不再分块瓦片。
  -- 半分辨率给低倍率（全图视角）用：显存 1/4、缩小采样摩尔纹更少；
  -- 放大到 ≥1.0 才切全分辨率。两图内容一致，只是尺寸不同。
  -- ⚠️ 本包**没有生成瓦片**（--no-tiles）：整图路径配了就永远走整图，
  --    MapRenderer 的分块回退分支不会被触发（见 MapRenderer.lua 的
  --    `if MapPack.WHOLE_IMAGE_PATH then ... else _renderTileBackground(...)`）。
  -- ⚠️ 新世界用**无主版**底图（2026-09-15 用户拍板）：这张图没有势力，
  --    政治版的"每省一色"彩色块会看起来像国家；无主版统一米色，更像"纯地图"。
  --    （政治版 map_political*.png 仍在 assets 里，将来若给新世界配势力可换回。）
  -- ⚠️ 底图由 --no-desert 生成（2026-09-15 再拍板）：**地图上不画沙漠** ——
  --    可玩区外也画省界（全世界都是区块）；isWasteland 的游戏设定保留（点击限制等照旧）。
  --    重新生成命令见文件头"生成命令"，**必须带 --no-desert**，否则沙漠会回来。
  WHOLE_IMAGE_PATH      = "image/world/map_neutral.png",
  WHOLE_IMAGE_HALF_PATH = "image/world/map_neutral_half.png",
  -- 编辑器"无主底图"（省份全部按无主色渲染，方便涂抹分封）——与主底图同一份
  NEUTRAL_WHOLE_IMAGE_PATH      = "image/world/map_neutral.png",
  NEUTRAL_WHOLE_IMAGE_HALF_PATH = "image/world/map_neutral_half.png",

  -- 📌 默认镜头（2026-09-15 用户已拍板：**保持全图视野**，不做"默认聚焦"）：
  --   这张图的几何中心 = (4800,1920) = 大西洋，而可玩区在中国（右上角）。
  --   用户选择保持现状（看"新世界"就先看全世界，要细看自己缩放过去）。
  --   （曾评估的"默认聚焦可玩区 x≈7813,y≈1450"未采用。）

  PROVINCE_FILES = { "data.mappacks.world.Provinces_%d" },
  INITIAL_ZOOM = 0.094,  -- 全图视角（按 900px 视口宽估）
  MIN_ZOOM = 0.05,
  -- 最大缩放 4（对齐 eu4 包 · 见清单 F0 症状③）：
  --   生成器默认给的是 SCALE*2=16，但 16 倍时一个地图像素铺满 16 屏幕像素 → 省界糊成一片。
  --   4 是"看得清省界 / 又能贴近看局部"的平衡点。
  MAX_ZOOM = 4,
  LUT_W = 4096,
  -- 投影：lon/lat → 逻辑像素（等距圆柱，纬度 78.54°N..-42.03°S 标定）
  -- ⚠️ x 是**纯线性**（减常数 + 乘常数）：改 CROP_X0 只是整体平移，形状不变
  project = function(lon, lat)
    local x = ((lon + 180.0) / 360.0 * 1200.0 - 0) * 8
    local y = (78.54 - lat) * 3.981 * 8
    return x, y
  end,
}

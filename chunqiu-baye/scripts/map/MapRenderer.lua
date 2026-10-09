------------------------------------------------------------------------
-- MapRenderer.lua — 地图 Widget（2D 路线 v4）
--
-- ⚠️ 2026-09-12：**停用 3D/shader 方案**（手机小游戏运行时不支持 3D 渲染；
--    社区有完全相同案例，官方回复移动端 shader"还需几周"）。
--    现在地图画面 = NanoVG 瓦片底图 + 逐省矢量上色/描边。
--    3D 实现（MapLayer / MapShaderRenderer / shader）已归档到 work_tmp/3d_map_parked/，
--    代码里所有 `self.shaderRenderer` 分支因该字段恒为 nil 而不执行（保留以便将来复活）。
--
-- 渲染架构（P 社式 GPU 逐像素方案）：
--   * 地图画面 → MapShaderRenderer（3D quad + SurfaceShader + LUT）
--     位图 = 唯一事实源：底图/填色/边界/点击全部同源，数据层 0 缝隙
--   * 本 Widget → 交互层（hover/点击/拖拽/滚轮）+ 叠加层
--     （省名标签、首都、驻军、minimap、调军目标、军队箭头、编辑工具）
--
-- v3 变化：
--   * 删除 NanoVG 的底图/逐省填色/边界线绘制（改由 GPU shader 处理）
--   * hover/选中高亮由 shader uniform 完成
--   * 每帧同步相机到 3D 层；势力/地形变化时重建 LUT 纹理
------------------------------------------------------------------------

local Widget = require("urhox-libs/UI/Core/Widget")
local UI = require("urhox-libs/UI")
local ImageCache = require("urhox-libs/UI/Core/ImageCache")
local Provinces = require("data.Provinces")
local SpatialIndex = require("map.SpatialIndex")
local Geography = require("data.Geography")
local MapPack = require("data.MapPack")
local MapEditor = require("map.MapEditor")
local GameState = require("core.GameState")
local GameConfig = require("config.GameConfig")

local MapRenderer = {}

-- Build spatial index once at load time (world map space)
local spatialIdx = SpatialIndex.new(Geography.MAP_W, Geography.MAP_H)
spatialIdx:build(Provinces.data)

----------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------
local CAM_PAN_SPEED    = 3000  -- logical units per second at zoom 1.0 (scaled 10x)
local ZOOM_MIN         = MapPack.MIN_ZOOM or 0.07
local ZOOM_MAX         = MapPack.MAX_ZOOM or 6.0
local ZOOM_FACTOR      = 1.15  -- multiplicative zoom per wheel notch (15%)
local ZOOM_LERP_SPEED  = 12.0  -- smooth interpolation speed (higher = snappier)

-- 手机端手感参数（2026-09-12）
local PAN_FLING_DECAY      = 5.0    -- 惯性平移衰减（越大停得越快）
local PAN_FLING_MIN        = 40.0   -- 惯性停止阈值（逻辑像素/秒）
local TILE_LOADS_PER_FRAME = 2      -- 每帧最多新建几张瓦片（PNG 解码贵，一次全建会卡顿）

local INITIAL_CAM_X    = Geography.MAP_W * 0.5  -- 地图中心
local INITIAL_CAM_Y    = Geography.MAP_H * 0.5
local INITIAL_ZOOM     = MapPack.INITIAL_ZOOM or 0.20  -- 世界地图全图视角（视口≈地图宽）

-- Province label LOD thresholds (screen-space)
local LABEL_MIN_ZOOM          = 0.35  -- below this, no province names
-- 选择粒度阈值（2026-09-18 用户拍板 · **两段式**）：
--   zoom ≥ 该值 → 点谁是谁：直接选省
--   zoom <  该值 → 第一下点 = **选国家**（整国染亮 + 国境描边）；
--                在"这个国家已被选中"的前提下再点它内部 = **选那块省**（钻进去）
-- ⚠️ 与 LABEL_MIN_ZOOM 同值：语义对齐"看得见省名 = 可以往下钻到省"
local SELECT_FACTION_MAX_ZOOM = 0.35
local LABEL_FOCUS_MIN_ZOOM    = 0.20  -- hovered/selected always labeled above this
local LABEL_MIN_AREA          = 700   -- min on-screen px² for a name at medium zoom
local LABEL_MIN_AREA_SMALL    = 250   -- min on-screen px² at high zoom (small fragments)
local CAPITAL_MIN_ZOOM        = 0.30  -- capital markers appear above this zoom
-- 国名显示区间（2026-09-18 用户："放大的话这个国家的名字就不见，这样的话就不会占地方"）
--   zoom < MIN ：国家在屏幕上太小，名字挤不下 → 不画（面积门槛会再过滤一轮小国）
--   MIN ~ MAX  ：显示（战略视角看国家分布）
--   zoom ≥ MAX ：放大是在看省/细节，国名又小又占地方 → **隐去**
local FACTION_LABEL_MIN_ZOOM  = 0.20  -- 国名出现倍率（0.55→0.20：缩到全图也能看见国家分布）
local FACTION_LABEL_MAX_ZOOM  = 0.80  -- 国名消失倍率（放大让出画面）
local FACTION_LABEL_MIN_AREA = 700   -- 领土屏幕面积(px²)低于此值不显示国名(拉远小国消失)
local FACTION_LABEL_SIZE_MIN = 16    -- 14→16：用户反馈"国名太小了"（显示区间内字号整体上调）
local FACTION_LABEL_SIZE_MAX = 22
-- 国名配色（2026-09-18 · P 社式）：暖白字 + 深墨描边。
--   原来用"提亮后的国色"——浅色国字压在同色系国土上，对比度不够（用户："颜色问题"）。
--   白字黑边是 EU4/CK3/HOI4 的通用解：任何国土色/地形色上都读得清，描边顺带把笔画加厚。
local FACTION_LABEL_FILL     = { 255, 252, 240, 255 }   -- 暖白（比纯白柔和，和羊皮纸底图更搭）
local FACTION_LABEL_STROKE   = { 30, 22, 12, 235 }      -- 深墨色描边
local FACTION_LABEL_STROKE_W = 1.6

-- Minimap removed (手机版：小地图占地方，删掉，2026-08-29)

-- 分块瓦片渲染：成品图切成 1024px 瓦片（assets/image/tiles/map_TX_TY.png），
-- 只渲染视口内可见的瓦片（为世界大地图铺路，2026-08-30）
local TILE_PX   = MapPack.TILE_PX or 1024
local TILE_L    = TILE_PX * (Geography.MAP_W / Geography.BITMAP_W)  -- 每块逻辑尺寸
local TILE_COLS = math.ceil(Geography.BITMAP_W / TILE_PX)
local TILE_ROWS = math.ceil(Geography.BITMAP_H / TILE_PX)

-- 瓦片边缘出血（bleed）：与 gen_tiles / gen_political_map / gen_neutral_tiles 三个
-- 切片脚本的 PAD 必须保持一致。切片时每块向外多带 TILE_PAD 源像素（裙边），绘制时
-- 同样外扩，邻块的出血互相覆盖 → 消除缩小时瓦片接缝处出现的横竖细线。
local TILE_PAD   = 4
local TILE_PAD_L = TILE_PAD * (Geography.MAP_W / Geography.BITMAP_W)  -- 出血逻辑尺寸

--- 换地图包之后**重新同步所有"加载时抓死"的东西**（2026-09-15）
---
--- 为什么需要：本文件有一堆模块级 local 是 require 时就算好的
--- （ZOOM_MIN/MAX、INITIAL_CAM/INITIAL_ZOOM、TILE_*，以及按旧 MAP 尺寸 + 旧省份数据
---   建出来的 spatialIdx）。换包之后它们全是旧包的，而**渲染 / 相机钳制 / 点击命中 /
---   视口裁剪全在用它们** → 画面压扁、点击错位。
--- `MapPack.switchTo()` 会在「切包 + 重载省份数据」之后调它。
---
--- ⚠️ **以后再加"加载时抓包"的常量，必须同时加进这个函数**，否则就是同一个坑。
--- （排查方法：`grep -n '^local [A-Za-z_]* *= *(Geography|MapPack|Provinces)\.' scripts/`）
function MapRenderer.refreshMapConstants()
    ZOOM_MIN      = MapPack.MIN_ZOOM or 0.07
    ZOOM_MAX      = MapPack.MAX_ZOOM or 6.0
    INITIAL_CAM_X = Geography.MAP_W * 0.5
    INITIAL_CAM_Y = Geography.MAP_H * 0.5
    INITIAL_ZOOM  = MapPack.INITIAL_ZOOM or 0.20

    TILE_PX    = MapPack.TILE_PX or 1024
    TILE_L     = TILE_PX * (Geography.MAP_W / Geography.BITMAP_W)
    TILE_COLS  = math.ceil(Geography.BITMAP_W / TILE_PX)
    TILE_ROWS  = math.ceil(Geography.BITMAP_H / TILE_PX)
    TILE_PAD_L = TILE_PAD * (Geography.MAP_W / Geography.BITMAP_W)

    -- 空间索引是按旧尺寸 + 旧省份数据建的 → 必须重建
    spatialIdx = SpatialIndex.new(Geography.MAP_W, Geography.MAP_H)
    spatialIdx:build(Provinces.data)

    print(string.format("[Map] 换包后重算：%dx%d，倍率 %.3f~%g，索引 %d 省",
        Geography.MAP_W, Geography.MAP_H, ZOOM_MIN, ZOOM_MAX, #Provinces.data))
end

-- 整图底图（2026-09-12 主线，见 MapPack.WHOLE_IMAGE_PATH）
--   地图画面 = 一张完整成品图直接铺满 (0,0,MAP_W,MAP_H)，不再分块。
--   低倍率用半分辨率图（显存 1/4、缩小采样摩尔纹更少），≥ WHOLE_FULL_ZOOM 用全分辨率。
local WHOLE_FULL_ZOOM    = 1.0   -- 切换到全分辨率整图的倍率阈值
local WHOLE_RETRY_SEC    = 0.5   -- 整图未就绪时的重试间隔（秒）；手机边玩边下时靠它续等

-- 被占领省的斜条纹（2026-09-13）
-- 被占领省的画法（2026-09-16 重调 · 用户："被占领了但颜色显示不明显"）
--   借 EU4/CK3 的做法，三条线索叠起来：
--     ① 底色压暗（OCCUPIED_DIM_ALPHA）
--     ② 占领方颜色的**粗斜纹**（OCCUPIED_STRIPE_*）
--     ③ 一圈占领方颜色的**边框**（OCCUPIED_BORDER_ALPHA）
--   原来只有 ②，而且条纹细（tile=32 把 64px 图缩一半 → 屏幕 ~3px）、透明度也低（150）
--   → 占领方与原主颜色接近时（秦的橄榄绿 vs 白狄的土黄）几乎看不出来
local OCCUPIED_STRIPE_TILE  = 84   -- 屏幕像素：一个条纹周期占多少 px（2026-09-19 64→84：条纹加粗，
                                   --   低缩放/省小时原来的细密纹理"看不清有没有被占"——用户反馈）
local OCCUPIED_STRIPE_ALPHA = 240  -- 条纹透明度（接近实色，才压得住底下的原主颜色）
local OCCUPIED_DIM_ALPHA    = 70   -- 被占省底色压暗程度（0=不压暗）
local OCCUPIED_BORDER_ALPHA = 235  -- 被占省外圈描边透明度（用占领方颜色）

-- ==========================================================================
-- 被占领表现：4 种方案对比开关（2026-09-16 用户："把方法全做出来让我看看哪个更好"）
--   1 = 现状      ：底压暗 + 占领方色斜纹 + 占领方色描边
--   2 = EU4 强制明暗：原主色**强制降饱和+压暗**（一律变灰暗底），占领方色**保色相拉亮度**
--                  → 明暗关系是"绝对"的，不依赖两国颜色像不像
--   3 = HOI4 铺满  ：占领方色**铺满整块**，被占状态靠半透明黑斜纹表达（没有两层颜色叠色）
--   4 = 铺满+旗标  ：方案 3 + 省中心插一面占领方小燕尾旗（颜色 + 国名首字）
-- 运行时用 MapRenderer.SetOccupiedStyle(n) 或环境变量 OCC_STYLE=n 切换
-- ==========================================================================
-- 2026-09-16 用户拍板：默认用**方案 2**（EU4 强制明暗）——撞色测试下也分得开，
-- 且保留"这块原本是谁的"信息（底色 = 原主色的灰暗版）
local OCCUPIED_STYLE = 2
local OCC_BASE_DESAT   = 0.72   -- 方案2：原主色降饱和到剩多少（0=全灰 1=不变）
local OCC_BASE_MAX_L   = 0.30   -- 方案2：原主色压暗后的亮度上限（0~1）
local OCC_STRIPE_MIN_L = 0.42   -- 方案2：条纹亮度下限（暗色国家会提到这里）
local OCC_STRIPE_MAX_L = 0.68   -- 方案2：条纹亮度上限（亮色国家会压到这里）
local OCC_FULL_DIM     = 0      -- 方案3/4：占领方色铺满时是否也压暗（0=不压）
local OCC_FLAG_W       = 26     -- 被占省中心旗：旗面宽（屏幕 px）
local OCC_FLAG_H       = 32     -- 被占省中心旗：旗面高（屏幕 px）
local OCC_FLAG_MIN_ZOOM = 0.45  -- 中心旗的最低缩放（2026-09-19：从"仅方案4"放开为**所有方案都画**——
                                --   用户反复"放大也看不到被占"，省变色+斜纹仍可能被当成"邻国的地"，
                                --   插一面占领方的旗是最后、也是最醒目的兜底线索；再小就不画免得糊成一片）

--- 切换被占领表现方案（1~4）
function MapRenderer.SetOccupiedStyle(n)
    OCCUPIED_STYLE = tonumber(n) or 1
    print("[Map] 被占领表现方案 = " .. tostring(OCCUPIED_STYLE))
end

---@return integer
function MapRenderer.GetOccupiedStyle()
    return OCCUPIED_STYLE
end

-- ---------------------------------------------------------------- 颜色工具
-- RGB(0~255) → HSL(0~1)；再转回来。用于"强制明暗角色"（方案2）
local function rgbToHsl(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local l = (mx + mn) * 0.5
    if mx == mn then return 0, 0, l end
    local d = mx - mn
    local s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
    local h
    if mx == r then h = (g - b) / d + (g < b and 6 or 0)
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    return h / 6, s, l
end

local function hslToRgb(h, s, l)
    local function hue(p, q, t)
        if t < 0 then t = t + 1 elseif t > 1 then t = t - 1 end
        if t < 1 / 6 then return p + (q - p) * 6 * t end
        if t < 1 / 2 then return q end
        if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
        return p
    end
    if s <= 0 then
        local v = math.floor(l * 255 + 0.5)
        return v, v, v
    end
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    return math.floor(hue(p, q, h + 1 / 3) * 255 + 0.5),
           math.floor(hue(p, q, h) * 255 + 0.5),
           math.floor(hue(p, q, h - 1 / 3) * 255 + 0.5)
end

local function clamp01(v)
    if v < 0 then return 0 elseif v > 1 then return 1 end
    return v
end

--- 方案2 底：原主色 → 灰暗底（降饱和 + 压亮度）
local function occupyBaseColor(c)
    local h, s, l = rgbToHsl(c[1] or 150, c[2] or 150, c[3] or 150)
    s = s * OCC_BASE_DESAT
    l = math.min(l, OCC_BASE_MAX_L)
    return hslToRgb(h, s, l)
end

--- 方案2 条纹：占领方色 → 保色相、把亮度拉进 [MIN_L, MAX_L]、饱和度抬起来
local function occupyStripeColor(c)
    local h, s, l = rgbToHsl(c[1] or 255, c[2] or 255, c[3] or 255)
    s = clamp01(math.max(s, 0.55))
    l = clamp01(math.max(OCC_STRIPE_MIN_L, math.min(OCC_STRIPE_MAX_L, l)))
    return hslToRgb(h, s, l)
end

--- 粗略估算一段文字的像素宽（汉字按 size、ASCII 按 0.55×size）。
--- 用途：给文字画"深色名牌"托底时要知道要多宽（引擎没绑 nvgTextBounds，自己量）
---@param s string
---@param size number
---@return number
local function labelTextWidth(s, size)
    local w = 0
    local i = 1
    local n = #s
    while i <= n do
        local b = string.byte(s, i) or 32
        local step = 1
        if b >= 0xF0 then step = 4
        elseif b >= 0xE0 then step = 3
        elseif b >= 0xC0 then step = 2 end
        if step > 1 then
            w = w + size          -- 汉字：按字号宽
        else
            w = w + size * 0.55   -- 数字/空格：窄一些
        end
        i = i + step
    end
    return w
end

--- 取国名首字（旗面上只写一个字）。
--- ⚠️ 不能直接用 string.sub(name,1,1)：那会截出半个汉字（3 字节 UTF-8 的第 1 个字节），
---    字体渲染出来是空白（踩过：旗子画出来了但旗面上没字）。
---    引擎里 `utf8` 库不可用，所以按首字节的位模式判断该字占几个字节自己切。
local function firstCharOf(name)
    if not name or name == "" then return "?" end
    local b = string.byte(name, 1)
    if not b then return "?" end
    local n = 1
    if b >= 0xF0 then n = 4
    elseif b >= 0xE0 then n = 3
    elseif b >= 0xC0 then n = 2 end
    return string.sub(name, 1, n)
end
local WHOLE_MAX_RETRY    = 20    -- 下载等待上限（约 10 秒）；超了就不再催，避免无休止重试

local HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B = 255, 215, 0   -- gold selection
local MOVE_TARGET_R, MOVE_TARGET_G, MOVE_TARGET_B = 50, 255, 100  -- green move targets
local HIGHLIGHT_WIDTH = 3.0

-- Label text colours
local LABEL_INK       = { 62, 46, 26, 235 }   -- dark ink brown (readable on parchment)

----------------------------------------------------------------------------
-- Geographical colour palette (earth tones by regional zone, Spring & Autumn)
-- Each faction is coloured by its home region on the map.
-- Unowned provinces use the parchment base colour.
----------------------------------------------------------------------------
-- 无主省（未占领）填充色 = **灰白**（2026-09-23 用户："如果是未被占领区域那就是灰白色"）。
--   原来是 210,196,158 的暖米色 —— 和"沙漠"的沙黄几乎同色，地图上分不清"没人管"还是"沙漠"。
--   改成中性灰白后：与沙漠（亮沙黄 232,205,118）、平原（淡黄绿 188,202,142）都能一眼分开。
--   （P 社同理：EU4 无主 = 浅灰、CK3 无主 = 灰褐，都用冷/中性色。）
local UNOWNED_R, UNOWNED_G, UNOWNED_B = 206, 204, 199

-- 荒地固定色（2026-09-23 用户拍板："米色那种是荒地、不可点击；不管右下角换什么观看模式，
--   国家还是地形，都是那个颜色"）——取旧底图沙地米色，全矢量底里荒地**一律**填它，
--   任何视图模式都不会被覆盖。玩家看到的语义：**灰白 = 未占领（可点）／米色 = 荒地（不可点）**。
local WASTELAND_R, WASTELAND_G, WASTELAND_B = 210, 196, 158

local FACTION_GEO_COLORS = {
    [1]  = {150, 115, 195},  -- 周王室 中原 purple（2026-08-31 原 gold 与沙漠色撞,改紫）
    [2]  = {92, 155, 145},  -- 齐 齐鲁 teal
    [3]  = {165, 115, 75},  -- 晋 晋地 sienna
    [4]  = {105, 138, 80},  -- 楚 荆楚 olive
    [5]  = {178, 175, 58},  -- 秦 关中 terracotta
    [6]  = {122, 135, 165},  -- 鲁 齐鲁 seafoam
    [7]  = {185, 105, 125},  -- 宋 中原 rose（2026-08-31 原 beige 与沙漠色撞,改玫红）
    [8]  = {138, 160, 115},  -- 卫 中原 sage
    [9]  = {80, 150, 175},  -- 郑 中原 azure（2026-08-31 原 amber 与沙漠色撞,改青蓝）
    [10] = {150, 105, 150},  -- 燕 北方 slate
    [11] = {75, 150, 138},  -- 吴 江南 teal
    [12] = {85, 98, 135},  -- 越 江南 forest teal
    [13] = {85, 140, 118},  -- 蔡 荆楚 dusty olive
    [14] = {168, 140, 95},  -- 陈 中原 sandy tan
    [15] = {172, 148, 90},  -- 曹 中原 warm tan
    [16] = {130, 150, 65},  -- 赤狄 北方 rust
    [17] = {160, 150, 135},  -- 白狄 西北 grey-brown
    [18] = {125, 120, 115},  -- 长狄 北方 dark grey
    [19] = {115, 120, 130},  -- 山戎 东北 dark slate
    [20] = {140, 105, 70},  -- 犬戎 西 dark ochre
    [21] = {110, 125, 95},  -- 东胡 东北 dark olive
    [22] = {100, 120, 85},  -- 林胡 北方 forest grey
    [23] = {135, 133, 110},  -- 楼烦 北方 stone grey
    [24] = {150, 115, 85},  -- 邢 晋地 muted sienna
    [25] = {115, 160, 150},  -- 邾 齐鲁 seafoam
    [26] = {127, 110, 155},  -- 莒 齐鲁 coastal
    [27] = {120, 162, 152},  -- 纪 齐鲁 pale teal
    [28] = {170, 150, 110},  -- 许 中原 warm sand
    [29] = {142, 155, 108},  -- 息 荆楚 pale olive
    [30] = {132, 150, 100},  -- 申 荆楚 sage
    [31] = {155, 90, 60},  -- 西虢 关中 rust
    [32] = {120, 142, 95},  -- 邓 荆楚 muted green
    [33] = {115, 140, 90},  -- 随 荆楚 olive green
    [34] = {112, 155, 145},  -- 杞 齐鲁 coastal
    [35] = {108, 152, 140},  -- 薛 齐鲁 sea green
    [36] = {118, 160, 145},  -- 滕 齐鲁 pale teal
    [37] = {145, 142, 82},  -- 黄 荆楚 gold-olive
    [38] = {95, 145, 130},  -- 江 江南 river teal
    [39] = {120, 148, 140},  -- 谭 齐鲁 coastal grey
}

local ARROW_COLOR_R, ARROW_COLOR_G, ARROW_COLOR_B = 220, 220, 30
local ARROW_WIDTH      = 2.5
local ARROW_HEAD_SIZE  = 8.0

----------------------------------------------------------------------------
-- Terrain view colours (CK3-style terrain mode, toggled with T key)
----------------------------------------------------------------------------
-- 地形视图配色（2026-09-23 重配：拉开对比）
--   旧表的毛病：平原(米)/农田(浅绿)/丘陵(黄)/草原(黄绿) 四个色挤在米黄绿区间，远看一整片；
--   沙漠的沙黄又和旧"无主米色"撞。
--   新表按 暖（黄系）/ 中（褐系）/ 冷（绿系、蓝系）三档拉开色调与明度：
local TERRAIN_VIEW_COLORS = {
    ["平原"] = {188, 202, 142},   -- 淡黄绿
    ["丘陵"] = {182, 166, 110},   -- 黄褐
    ["山地"] = {142, 116,  90},   -- 深棕
    ["森林"] = { 92, 144,  88},   -- 深绿
    ["草原"] = {212, 202, 116},   -- 干草黄绿（偏黄）
    ["沿海"] = {176, 198, 178},   -- 青灰绿
    ["沼泽"] = {110, 138, 110},   -- 墨绿
    ["盆地"] = {196, 172, 118},   -- 褐
    ["沙漠"] = {232, 205, 118},   -- 亮沙黄（与无主灰白 206,204,199 明显分开）
    ["高原"] = {170, 150, 112},   -- 灰褐
    ["江湖"] = {112, 168, 178},   -- 水蓝
    ["荒漠"] = {222, 200, 146},   -- 浅沙（比沙漠淡，仍明显暖色）
    -- 真实地理地形（gen_terrain.py 的 11 种）对应色
    ["农田"]  = {166, 196, 104},  -- 亮绿（良田）
    ["针叶林"] = { 70, 126, 100},  -- 青绿
    ["丛林"]  = { 58, 126,  66},  -- 浓绿
    ["冻土"]  = {190, 214, 232},  -- 灰蓝
}

----------------------------------------------------------------------------
-- Utility helpers
----------------------------------------------------------------------------

--- Clamp a number between lo and hi.
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Clamp a camera axis; when the viewport is bigger than the map, centre it.
local function clampCamAxis(v, minV, maxV)
    if minV >= maxV then return (minV + maxV) * 0.5 end
    return clamp(v, minV, maxV)
end

--- Lighten an RGB channel by amount (cap 255).
local function lighten(c, amount)
    local v = c + amount
    return v > 255 and 255 or v
end

--- Compute the centroid of a polygon (list of {x,y} tables).
--- 多边形重心（**面积重心**，不是顶点平均）
---   2026-10-04 修：原来用的是"顶点平均"，顶点分布不均时会被拉偏
---   （用户截图：细长省的驻军旗/军队旗飘到邻省地盘上）。
---   现在改成面积重心，与省份数据里的 prov.center 算法一致。
---@param polygon table
---@return number cx
---@return number cy
local function polygonCentroid(polygon)
    local n = #polygon
    if n == 0 then return 0, 0 end
    if n < 3 then
        local sx, sy = 0, 0
        for i = 1, n do sx = sx + polygon[i][1]; sy = sy + polygon[i][2] end
        return sx / n, sy / n
    end
    local A, cx, cy = 0, 0, 0
    for i = 1, n do
        local x0, y0 = polygon[i][1], polygon[i][2]
        local j = (i % n) + 1
        local x1, y1 = polygon[j][1], polygon[j][2]
        local cr = x0 * y1 - x1 * y0
        A = A + cr
        cx = cx + (x0 + x1) * cr
        cy = cy + (y0 + y1) * cr
    end
    if math.abs(A) < 1e-9 then
        -- 退化（面积≈0）：回退到顶点平均
        local sx, sy = 0, 0
        for i = 1, n do sx = sx + polygon[i][1]; sy = sy + polygon[i][2] end
        return sx / n, sy / n
    end
    A = A * 0.5
    return cx / (6 * A), cy / (6 * A)
end

--- 把一条环（含洞）追加进"当前 path"（**不**调用 nvgBeginPath）。
--- 多省合成一条 path 一次填充时必须用这个：path 内的若干子路径会按并集填充，
--- 共享边落在并集内部 → 既不会重影、也不会被叠加两次（见选中高亮）。
--- 支持洞（holes）：洞环以 NVG_HOLE winding 绘制，fill 时自动挖洞。
---@param nvg table
---@param polygon table
---@param holes table|nil
local function traceRingInto(nvg, polygon, holes)
    if not polygon or #polygon < 3 then return end
    nvgMoveTo(nvg, polygon[1][1], polygon[1][2])
    for i = 2, #polygon do
        nvgLineTo(nvg, polygon[i][1], polygon[i][2])
    end
    nvgClosePath(nvg)
    if holes then
        for _, hole in ipairs(holes) do
            if #hole >= 3 then
                nvgMoveTo(nvg, hole[1][1], hole[1][2])
                for i = 2, #hole do
                    nvgLineTo(nvg, hole[i][1], hole[i][2])
                end
                nvgClosePath(nvg)
                nvgPathWinding(nvg, NVG_HOLE)
            end
        end
    end
end

--- Trace a polygon path using NanoVG transform (no manual offset needed).
--- 单省绘制用这个（自开一条 path）。
---@param nvg table
---@param polygon table
---@param holes table|nil
local function tracePolygon(nvg, polygon, holes)
    nvgBeginPath(nvg)
    traceRingInto(nvg, polygon, holes)
end

--- Draw an arrow head at (toX,toY) pointing from (fromX,fromY).
local function drawArrowHead(nvg, fromX, fromY, toX, toY, size)
    local dx, dy = toX - fromX, toY - fromY
    local len = math.max(1, math.sqrt(dx * dx + dy * dy))
    local ux, uy = dx / len, dy / len
    local px, py = -uy, ux
    local ax = toX - ux * size * 0.7
    local ay = toY - uy * size * 0.7
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, ax, ay)
    nvgLineTo(nvg, ax + px * size * 0.5, ay + py * size * 0.5)
    nvgLineTo(nvg, toX, toY)
    nvgLineTo(nvg, ax - px * size * 0.5, ay - py * size * 0.5)
    nvgClosePath(nvg)
    nvgFill(nvg)
end

---@class MapWidget : Widget
local MapWidget = Widget:Extend("MapWidget")

--- Draw a shadowed label at (x,y) with the given size and colour.
--- 描边偏移表（8 方向）—— NanoVG 没有 text-stroke，用"同一串字偏移画 8 遍深色 + 中心画主色"模拟。
--- 这同时干了两件事：① 描边把字从底色里抠出来（P 社式白字黑边）② 笔画变厚 = 视觉加粗。
local STROKE_DX = {  1, -1,  0,  0,  0.7,  0.7, -0.7, -0.7 }
local STROKE_DY = {  0,  0,  1, -1,  0.7, -0.7,  0.7, -0.7 }

---@param nvg table
---@param x number
---@param y number
---@param text string
---@param size number
---@param color table {r,g,b,a}
---@param strokeColor table|nil {r,g,b,a} 传了就画描边（P 社式白字+深边）；不传 = 老行为（右下 1px 阴影）
---@param strokeW number|nil 描边宽度（px）；国名建议 1.6
function MapWidget:_drawLabel(nvg, x, y, text, size, color, strokeColor, strokeW)
    nvgFontFace(nvg, "sans")   -- 复用 UI 注册的 sans(MiSans)
    nvgFontSize(nvg, size)
    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    if strokeColor and strokeW and strokeW > 0 then
        nvgFillColor(nvg, nvgRGBA(strokeColor[1], strokeColor[2], strokeColor[3],
            strokeColor[4] or 255))
        for i = 1, 8 do
            nvgText(nvg, x + STROKE_DX[i] * strokeW, y + STROKE_DY[i] * strokeW, text, nil)
        end
    else
        nvgFillColor(nvg, nvgRGBA(35, 26, 14, 205))
        nvgText(nvg, x + 1, y + 1, text, nil)
    end
    nvgFillColor(nvg, nvgRGBA(color[1], color[2], color[3], color[4] or 255))
    nvgText(nvg, x, y, text, nil)
end

--- 画一面**燕尾旗**（旗面 = 势力色 + 深色底边 + 金边，旗面写 1~2 个字）。
--- 地图上的占领旗标 / 顶栏势力徽记 / 选择国家卡片 都走这一个函数，保证形制统一。
---@param nvg table
---@param x number 旗面左上角 x
---@param y number 旗面左上角 y
---@param w number 旗面宽
---@param h number 旗面高
---@param col table 势力色 {r,g,b}
---@param text string 旗面文字
---@param opts table|nil { lw=线宽单位(地图里传 1/zoom), fontSize=字号, fontFace=字体名, pole=是否画旗杆 }
function MapRenderer.DrawBanner(nvg, x, y, w, h, col, text, opts)
    opts = opts or {}
    local lw = opts.lw or 1                     -- 线宽单位（屏幕恒定时传 1/zoom）
    local fs = opts.fontSize or (h * 0.58)
    local r, g, b = col[1] or 255, col[2] or 255, col[3] or 255

    -- 旗杆（左侧竖线，伸出旗面一点）
    if opts.pole ~= false then
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, x, y - 5 * lw)
        nvgLineTo(nvg, x, y + h + 5 * lw)
        nvgStrokeColor(nvg, nvgRGBA(38, 28, 16, 235))
        nvgStrokeWidth(nvg, 2.0 * lw)
        nvgStroke(nvg)
    end

    -- 燕尾旗面：右边中部挖一个 V 口
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, x, y)
    nvgLineTo(nvg, x + w, y)
    nvgLineTo(nvg, x + w * 0.68, y + h * 0.5)
    nvgLineTo(nvg, x + w, y + h)
    nvgLineTo(nvg, x, y + h)
    nvgClosePath(nvg)
    -- ① 先描一圈**深色底边**：旗面颜色和底下的省色同色时（占领方=这块领土的既有色），
    --    没有这圈深色旗子就"融进背景"了（踩过）
    nvgStrokeColor(nvg, nvgRGBA(24, 18, 10, 235))
    nvgStrokeWidth(nvg, 4.0 * lw)
    nvgStroke(nvg)
    nvgFillColor(nvg, nvgRGBA(r, g, b, 255))
    nvgFill(nvg)
    -- ② 金边（跟顶栏/国境线的金同色系）
    nvgStrokeColor(nvg, nvgRGBA(214, 176, 92, 245))
    nvgStrokeWidth(nvg, 1.6 * lw)
    nvgStroke(nvg)

    -- 旗面文字：按底色明度自动选深墨/白字
    local luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255
    local ink = luma > 0.62 and { 32, 24, 12, 250 } or { 250, 243, 230, 250 }
    local tx = x + w * (opts.textAnchor or 0.42)
    local ty = y + h * 0.5
    nvgFontFace(nvg, opts.fontFace or "sans")   -- 复用 UI 注册的 sans(MiSans)
    nvgFontSize(nvg, fs)
    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(nvg, nvgRGBA(20, 14, 8, 185))  -- 文字投影（浅色旗面上也读得清）
    nvgText(nvg, tx + lw, ty + lw, text, nil)
    nvgFillColor(nvg, nvgRGBA(ink[1], ink[2], ink[3], ink[4]))
    nvgText(nvg, tx, ty, text, nil)
end

--- 占领省中心的旗标：把 DrawBanner 摆到省质心上方。
--- 注意：调用点在 nvgScale(zoom) 之后的**逻辑坐标**空间里 → 尺寸/线宽都要除以 zoom 保持屏幕恒定。
---@param nvg table
---@param cx number 省中心（逻辑坐标）
---@param cy number
---@param zoom number
---@param col table 占领方颜色 {r,g,b}
---@param text string 旗面文字
function MapWidget:_drawOccFlag(nvg, cx, cy, zoom, col, text)
    if not self:_ensureFont(nvg) then return end   -- 字体没就绪就别画（不然只有旗没有字）
    local lw = 1 / zoom
    local w, h = OCC_FLAG_W * lw, OCC_FLAG_H * lw
    -- ⚠️ 整体上移：省名牌子（东胡 500 那种）画在省中心，旗子放中心会被牌子压住看不见
    MapRenderer.DrawBanner(nvg, cx - w * 0.5, cy - h - 26 * lw, w, h, col, text,
        { lw = lw, fontSize = 18 * lw })
end

--- Ensure the label font is loaded, return true on success.
---@param nvg table
---@return boolean
function MapWidget:_ensureFont(nvg)
    if self.fontId_ then
        return true
    end
    if not nvg then return false end
    self.fontId_ = nvgCreateFont(nvg, "mapfont", "Fonts/MiSans-Regular.ttf")
    return self.fontId_ and self.fontId_ >= 0
end

function MapWidget:Init(props)
    props = props or {}
    props.overflow = "hidden"
    props.backgroundColor = {12, 18, 30, 255}   -- 深色背景（地图外区域，避免黑边刺眼）

    -- Store custom props before calling parent
    self.gameState = props.gameState
    -- P 社 shader 渲染层（3D 地图画面）
    self.shaderRenderer = props.shaderRenderer or nil

    -- Camera state
    self.camX = INITIAL_CAM_X
    self.camY = INITIAL_CAM_Y
    self.zoom = INITIAL_ZOOM
    self.targetZoom = INITIAL_ZOOM    -- smooth zoom target

    -- 首帧自适应"全图视角"（2026-09-15）
    --   原来 INITIAL_ZOOM 是**按 900px 视口宽硬猜**的一个常数（见 eu4.lua 的注释），
    --   视口不是 900 就装不下整张图 —— 选国页左边加了「地图名」那一列之后
    --   地图面板只剩 ~548px，西非直接被切掉，这才暴露出来。
    --   改成等布局算完（Render 里第一次拿到有效 layout）按实际视口算倍率。
    self._needFitAll = true

    -- Interaction state
    self.hoveredProvinceId  = nil
    self.selectedProvinceId = nil
    -- 选择粒度："faction"=整国（整国染亮）／"province"=单省／nil=无选择
    self.selectionLevel_    = nil
    -- 只按国家选（选国页用）：点谁都只整国高亮，永不钻到省
    self.factionSelectOnly  = props.factionSelectOnly or false

    -- Army move mode: highlight valid target provinces
    self.armyMoveMode       = false
    self.armyMoveFrom       = nil
    self.armyMoveTargets    = {}          -- set of valid target province ids {[id]=true}
    self.elapsedTime_       = 0           -- for pulse animation
    -- 选中的军队 → 金色脉冲光晕（2026-09-23 用户："点之后可以发光来证明我们点击了它"）
    self.selectedArmy_      = nil         -- 行军军队对象（r.army）
    self.selectedGarrison_  = nil         -- 驻军所在省 id（r.provId）

    -- Callback (set externally)
    self.onProvinceClick = props.onProvinceClick or nil
    self.onArmyMoveTarget = props.onArmyMoveTarget or nil
    -- 点击地图上的军队旗标 → 打开军队面板（2026-09-23）
    self.onArmyClick = props.onArmyClick or nil
    -- 点击省上的驻军旗 → 打开左下角驻军面板，不选省
    self.onGarrisonClick = props.onGarrisonClick or nil

    -- Drag panning state (left-click drag)
    self.isDragging_   = false
    self.dragStartX_   = 0
    self.dragStartY_   = 0
    self.lastDragX_    = 0
    self.lastDragY_    = 0
    self.pointerDown_  = false

    -- Pointer position (for zoom-to-cursor on wheel)
    self.pointerX_ = nil
    self.pointerY_ = nil

    -- 多点触控（双指捏合缩放，手机版）
    self.touchPoints_ = {}          -- [pointerId] = {x, y}
    self.lastPinchDist_ = nil       -- 上一帧两指距离

    -- 手势状态：捏合缩放（锚点固定手指下的地点）+ 松手惯性平移
    self.pinchActive_        = false
    self.pinchStartDist_     = nil
    self.pinchBaseZoom_      = nil
    self.pinchAnchorScreen_  = nil  -- {x,y} 两指中点（屏幕）
    self.pinchAnchorLogical_ = nil  -- {x,y} 对应的地图逻辑坐标
    self.flingVX_            = 0    -- 惯性速度（逻辑像素/秒）
    self.flingVY_            = 0
    self.prevCamX_           = nil
    self.prevCamY_           = nil
    self.dragFromTouch_      = false

    -- 地图编辑工具（MapEditor 接入）
    self.editorPaintDown_ = false
    self.showEditorHelp_ = false

    -- 和平条约涂抹选省（历史时代3 式：按住左键滑动连续加选）
    -- 通用"涂抹模式"（2026-09-16 泛化）——两种场景共用同一套：
    --   ① 和平条约选省（外部用 isPaintable 限定"可索取省"）
    --   ② 国交行动（点/涂抹国家即执行：宣战、改善关系…）
    --   由外部设 paintEnabled + onPaintProvince，就进入该模式。
    self.paintEnabled = false       -- 是否处于涂抹模式（由面板/窗口开启）
    self.paintDown_   = false       -- 当前是否按住涂抹
    self.painted_     = false       -- 本次按住是否确实涂抹过省（用于区分单击 vs 涂抹）
    self.paintStartPickable_ = false -- 按住起点是否落在"可涂省"上（决定涂抹 vs 拖动地图）
    self.onPaintProvince = props.onPaintProvince or nil  -- 涂抹/点选回调(forceSelect)
    self.onPaintEnd      = props.onPaintEnd or nil       -- 一次涂抹结束（松开）回调
    self.isPaintable     = props.isPaintable or nil      -- 判断省是否可涂（nil=都可涂）

    -- 选中势力"国家外轮廓"缓存（点击选中国家时构建；切换选择时重算）
    self.outlineOwner_ = nil
    self.outlineFocus_ = nil
    self.outlineSegs_  = nil

    -- shader LUT 状态（归属/地形/地图模式变化 → 重建 LUT 纹理）
    self.lutDirty_    = true
    self.lutSig_      = nil
    self.lutFrame_    = 0
    -- 视口同步回调（由地图 3D 层提供：把 widget 逻辑布局同步成 3D 视口矩形）
    self.onSyncViewport = props.onSyncViewport or nil

    -- View mode: "political" (faction colours) or "terrain" (CK3-style)
    self.viewMode_ = props.viewMode or "political"

    -- Lazy caches
    self.fontId_   = nil
    self.terrCenters_ = nil
    -- 整图底图：重试节流 + 失败计数（见 _wholeImageHandle）
    self.wholeRetryAt_ = 0
    ---@type table<string, number>
    self.wholeFail_    = {}    -- 每张整图的失败次数（仅用于日志节流）
    ---@type table<string, boolean>
    self.wholeDownloadAsked_ = {}  -- 已主动发起过下载的整图（避免重复请求）
    ---@type string|nil
    self.wholeLodPath_ = nil   -- 当前用的整图（用于 LOD 切换时打日志）
    -- 省份 ID 位图（P 社方案）：懒加载一次
    self.provinceBitmap_ = nil  --[[@as Image]]
    self.provinceBitmapAttempted_ = false
    -- 边界图集（2026-09-15）：国境线高亮的像素级数据（由 gen_border_atlas.py 生成）
    --   贴的是"黑线像素本身的染色"→ 零对位差、缩放免疫（不再"另画一条线去盖"）
    self.borderAtlasData_ = nil
    self.borderAtlasTried_ = false

    -- LUT 刷新标记（势力/地形变化时重建）
    self.lutVersion_ = -1
    self.lutViewMode_ = nil

    -- Call parent constructor (MUST do this!)
    Widget.Init(self, props)
end

------------------------------------------------------------
-- Coordinate transforms
------------------------------------------------------------

--- Logical (map) coords  -->  screen coords (absolute).
function MapWidget:logicalToScreen(lx, ly)
    local l = self:GetAbsoluteLayout()
    if not l then return 0, 0 end
    local halfW = l.w * 0.5
    local halfH = l.h * 0.5
    local sx = (lx - self.camX) * self.zoom + halfW + l.x
    local sy = (ly - self.camY) * self.zoom + halfH + l.y
    return sx, sy
end

--- 算某个省在屏幕上的**包围盒尺寸**（用于判断旗标放不放得下）
---   2026-09-29 加：小省的旗标会溢出到邻省，需要按省的实际大小缩放。
---@param polygon table 省的多边形（地图坐标）
---@return number w 屏幕宽度
---@return number h 屏幕高度
function MapWidget:provinceScreenSize(polygon)
    if not polygon or #polygon < 3 then return 0, 0 end
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for i = 1, #polygon do
        local p = polygon[i]
        local sx, sy = self:logicalToScreen(p[1], p[2])
        if sx < minX then minX = sx end
        if sx > maxX then maxX = sx end
        if sy < minY then minY = sy end
        if sy > maxY then maxY = sy end
    end
    return maxX - minX, maxY - minY
end

--- Screen coords (absolute)  -->  logical (map) coords.
function MapWidget:screenToLogical(sx, sy)
    local l = self:GetAbsoluteLayout()
    if not l then return 0, 0 end
    local halfW = l.w * 0.5
    local halfH = l.h * 0.5
    local lx = (sx - l.x - halfW) / self.zoom + self.camX
    local ly = (sy - l.y - halfH) / self.zoom + self.camY
    return lx, ly
end

-- 游戏内顶栏遮挡的高度（屏幕像素）。相机上滑补偿用（2026-09-23）：
--   顶栏盖住视口顶部这一条，不补偿的话最上面的领土永远滑不出来、点不到。
local TOP_UI_PX = 64

--- Clamp the camera so the viewport stays inside the world map.
--- ⚠️ 顶部 UI 补偿（2026-09-23 用户："上滑到极限后，最上面的领土被顶栏挡住、点不到"）：
---   原本按"视口顶部 = 地图顶边"卡死，被顶栏盖住的那条领土永远露不出来；
---   现在允许相机再往上滑 TOP_UI_PX 个屏幕像素（换算成地图坐标），被挡的领土即可滑进可见区。
---   左右/底部不补（无遮挡，底部是海洋）。
function MapWidget:_clampCamera()
    local l = self:GetAbsoluteLayout()
    if not l or l.w <= 0 or l.h <= 0 then return end
    local minX = l.w * 0.5 / self.zoom
    local minY = l.h * 0.5 / self.zoom
    local padTop = TOP_UI_PX / self.zoom
    self.camX = clampCamAxis(self.camX, minX, Geography.MAP_W - minX)
    self.camY = clampCamAxis(self.camY, minY - padTop, Geography.MAP_H - minY)
end

--- 把整张世界图缩放到刚好装进**当前视口**，并居中。
---
--- 为什么不直接用 INITIAL_ZOOM：那是按「视口宽 ≈ 900px」硬猜的常数
--- （`mappacks/eu4.lua:36` 的注释写明）。视口一变（手机分辨率不同、
--- 选国页左边多了「地图名」那一列…）就装不下整图了 —— 表现是地图被切掉一边。
--- 这个函数按实际 layout 算，任何视口都对。
---@param fill number|nil 留白系数（默认 0.98，别贴边）
---@return boolean 成功与否（布局还没算好时返回 false）
function MapWidget:fitWholeMap(fill)
    local l = self:GetAbsoluteLayout()
    if not l or l.w <= 0 or l.h <= 0 then return false end
    fill = fill or 0.98
    -- 取两个轴向里更"紧"的那个，保证整图两个方向都装得下
    local z = math.min(l.w / Geography.MAP_W, l.h / Geography.MAP_H) * fill
    self.zoom = clamp(z, ZOOM_MIN, ZOOM_MAX)
    self.targetZoom = self.zoom
    self.camX = Geography.MAP_W * 0.5
    self.camY = Geography.MAP_H * 0.5
    -- 装不满的那个轴向 min>=max，clampCamAxis 会直接取中点（=居中），安全
    self:_clampCamera()
    return true
end

------------------------------------------------------------
-- Province lookup（P 社栅格位图方案：位图 = 唯一事实源）
------------------------------------------------------------

--- 懒加载省份 ID 位图（province_id.png，P社位图即数据）
---@return Image|nil
function MapWidget:getProvinceBitmap()
    if not self.provinceBitmapAttempted_ then
        self.provinceBitmapAttempted_ = true
        self.provinceBitmap_ = cache:GetResource("Image", MapPack.PROVINCE_ID_PATH)
        if not self.provinceBitmap_ then
            print("[Map] 警告：province_id.png 未加载，点击检测不可用")
        end
    end
    return self.provinceBitmap_
end

--- 按位图查色确定省份：逻辑坐标 → 位图像素 → O(1) 查省 ID。
--- 位图像素 RGB = (R=0, G=id>>8, B=id&0xFF)。
--- ⚠️ GetPixelInt 字节序 = 0xAABBGGRR（A 最高位，R 最低位）：
---   B = (v>>16)&0xFF, G = (v>>8)&0xFF
--- 点击命中省（2026-09-18 加"就近吸附"）
--- 用户需求：手指点偏一点（落在海面/边界缝隙/空白）时不该"没反应"，
--- 而应吸附到最近的省份 —— 这是所有地图游戏的通行容错做法（EU4/AoH3/三国志都有）。
--- 实现：先精确问一次位图；没中就在一个逐渐放大的方框里螺旋外扩找最近的非空像素。
---@param sx number
---@param sy number
---@return number|nil
function MapWidget:getProvinceAtPoint(sx, sy, allowSnap)
    local lx, ly = self:screenToLogical(sx, sy)
    local img = self:getProvinceBitmap()
    if not img then
        return nil
    end

    -- 精确命中
    local id = self:_provinceIdAtLogical(lx, ly)
    if id then return id end

    -- 就近吸附（**只给点击用**）：以 SNAP_R 逻辑像素为半径，逐圈外扩找第一个省
    -- ⚠️ 悬停必须传 allowSnap=false（2026-09-18 踩坑：悬停也吸附 → 鼠标停在海上时
    --    每帧狂搜几千次像素，游戏卡到点不动，用户反馈"放到很大还是点不了地区"）
    if allowSnap == false then return nil end
    -- 吸附半径按**屏幕**恒定（≈20px），换算成逻辑像素后夹在 [10, 40]：
    --   放大 → 吸得紧（不会抢到隔壁省）；缩小 → 吸得宽（手指精度的容错）
    -- （2026-09-18：原来写死 24 逻辑像素 —— zoom=3 时等于屏幕上 72px，太抢）
    local SNAP_R = math.min(40, math.max(10, 20 / math.max(self.zoom, 0.001)))
    local step = Geography.BITMAP_SCALE          -- 一轮走一个位图像素
    local maxRing = math.max(1, math.floor(SNAP_R / step))
    for ring = 1, maxRing do
        -- 上/下两条横边
        for dx = -ring, ring do
            local cand = self:_provinceIdAtLogical(lx + dx * step, ly - ring * step)
                or self:_provinceIdAtLogical(lx + dx * step, ly + ring * step)
            if cand then return cand end
        end
        -- 左/右两条竖边
        for dy = -ring + 1, ring - 1 do
            local cand = self:_provinceIdAtLogical(lx - ring * step, ly + dy * step)
                or self:_provinceIdAtLogical(lx + ring * step, ly + dy * step)
            if cand then return cand end
        end
    end
    return nil
end

--- 逻辑坐标 → 省 ID（位图 O(1) 查询；越界/海面返回 nil）
---@param lx number
---@param ly number
---@return number|nil
function MapWidget:_provinceIdAtLogical(lx, ly)
    local img = self:getProvinceBitmap()
    if not img then return nil end
    local px = math.floor(lx / Geography.BITMAP_SCALE)
    local py = math.floor(ly / Geography.BITMAP_SCALE)
    if px < 0 or py < 0 or px >= Geography.BITMAP_W or py >= Geography.BITMAP_H then
        return nil
    end
    local v = img:GetPixelInt(px, py)
    local g = (v >> 8) & 0xFF
    local b = (v >> 16) & 0xFF
    local id = g * 256 + b
    if id <= 0 or id > #Provinces.data then
        return nil
    end
    return id
end

--- 构建"该势力的国境贴图项列表"（2026-09-15 · A 模式：只亮跨势力的外圈）
--- 数据源 = 边界图集（gen_border_atlas.py 从省 ID 位图逐像素提取"省与省相接处"）——
--- 贴的就是黑线像素本身的染色：零对位差、缩放免疫（放大 4 倍也不露黑，用户实测需求）。
---@param ownerId number
---@return table[]|nil 贴图项 { a, b, ax, ay, wx, wy, w, h }；nil = 无图集（调用方回退画线）
function MapWidget:_buildOwnerOutlineAtlas(ownerId)
    local data = self:_getBorderAtlas()
    if not data then return nil end
    local gs = self.gameState
    if not gs then return nil end
    local function ownerOf(pid)
        if not pid or pid == 0 then return nil end
        local lv = gs.provinces[pid]
        return lv and lv.ownerId or nil
    end
    local list = {}
    local edges = data.edges
    for i = 1, #edges do
        local e = edges[i]
        local a = ownerOf(e[1])
        local b = ownerOf(e[2])
        if (a == ownerId) ~= (b == ownerId) then   -- 一侧是、另一侧不是 → 国境线
            list[#list + 1] = e
        end
    end
    return list
end

--- 惰性加载边界图集数据（按当前地图包；失败返回 nil → 国境线回退"画线"模式）
function MapWidget:_getBorderAtlas()
    if self.borderAtlasTried_ then return self.borderAtlasData_ end
    self.borderAtlasTried_ = true
    local modName = "data.mappacks." .. tostring(MapPack.activeId) .. ".Borders"
    local ok, data = pcall(require, modName)
    if ok and type(data) == "table" and type(data.edges) == "table" and #data.edges > 0 then
        self.borderAtlasData_ = data
        print(string.format("[Map] 边界图集就绪：%d 条边，图 %s（%dx%d）",
            #data.edges, tostring(data.image), data.atlasW or -1, data.atlasH or -1))
    else
        print("[Map] 边界图集不可用（" .. modName .. "）→ 国境线回退画线模式")
    end
    return self.borderAtlasData_
end

--- 构建某势力的"国家外轮廓"线段表（同国省与省之间不画线；只保留与外部的交界边）
--- 原理：取每条省界边的中点，作法线向两侧偏移取点，用省份位图查两侧归属——
---   两侧都属于同一势力 → 内部边（跳过）；否则是外轮廓（保留）。
--- 结果按（势力，被点省）缓存，点击切换时才重算。
---@param ownerId number
---@return table[] segments { x1, y1, x2, y2 }
function MapWidget:_buildOwnerOutline(ownerId)
    local segs = {}
    local gs = self.gameState
    if not gs then return segs end
    local function ownerOf(pid)
        if not pid then return nil end
        local lv = gs.provinces[pid]
        return lv and lv.ownerId or nil
    end
    -- 采样偏移（逻辑像素）：太小时 ±off 两侧可能都落在"边界线像素带"里
    --（ID 位图上边界像素的归属是任一侧）→ 误判成"同国内部边"→ 国境线**漏段**。
    -- 4px 让采样点落到两侧省内部，判定才稳（2026-09-15 修"金边时有时无"）
    local off = 4.0 * (Geography.BITMAP_SCALE or 1)
    for i = 1, #Provinces.data do
        local prov = Provinces.data[i]
        local live = gs.provinces[prov.id]
        if live and live.ownerId == ownerId and not prov.isWasteland
           and prov.polygon and #prov.polygon >= 3 then
            local poly = self:_renderPoly(prov)
            local n = #poly
            for k = 1, n do
                local a = poly[k]
                local b = poly[k % n + 1]
                if a and b then
                    local ax, ay, bx, by = a[1], a[2], b[1], b[2]
                    local dx, dy = bx - ax, by - ay
                    local len = math.sqrt(dx * dx + dy * dy)
                    if len > 0.001 then
                        local mx, my = (ax + bx) * 0.5, (ay + by) * 0.5
                        local nx, ny = -dy / len, dx / len
                        local p1 = self:_provinceIdAtLogical(mx + nx * off, my + ny * off)
                        local p2 = self:_provinceIdAtLogical(mx - nx * off, my - ny * off)
                        local isInner = (ownerOf(p1) == ownerId) and (ownerOf(p2) == ownerId)
                        if not isInner then
                            segs[#segs + 1] = { ax, ay, bx, by }
                        end
                    end
                end
            end
        end
    end
    return segs
end

------------------------------------------------------------
-- Selection helpers
------------------------------------------------------------

--- 调试资源注入（历史时代3 式快捷键：小键盘1/R/3/4/5 各资源 +100）
---@param kind string "gold"|"food"|"army"|"prestige"|"stability"
---@param amount number
function MapWidget:addDebugResource(kind, amount)
    local gs = self.gameState
    local fid = gs and gs.playerFactionId
    local f = fid and gs.factions[fid]
    if not f then return end
    local names = {
        gold = "金钱", food = "粮草", army = "兵力",
        prestige = "名声", stability = "稳定",
    }
    if kind == "gold" then
        f.gold = (f.gold or 0) + amount
    elseif kind == "food" then
        f.food = (f.food or 0) + amount
    elseif kind == "army" then
        f.armySize = (f.armySize or 0) + amount
    elseif kind == "prestige" then
        f.prestige = (f.prestige or 0) + amount
    elseif kind == "stability" then
        f.stability = math.min(100, (f.stability or 0) + amount)
    else
        return
    end
    if gs.addMessage then
        gs.addMessage("[" .. (names[kind] or kind) .. "] +" .. tostring(amount), "system")
    end
    print("[Debug] " .. (names[kind] or kind) .. " +" .. tostring(amount))
end

--- 决定"这次点击"应该选到哪一级（2026-09-18 用户口径 · 两段式）
---
--- 规则：
---   * zoom ≥ SELECT_FACTION_MAX_ZOOM（看得清） → 点谁是谁，直接选省
---   * zoom <  阈值（缩得很远）：
---       - 当前选中的省**不属于**被点省所在国家 → 第一下 = 选国家（整国染亮）
---       - 当前选中的省**属于**同一个国家      → 再点内部 = 选那块省（钻进去 / 继续切省）
---   * 无主省/沙漠 → 永远按省（没有"国家"可选）
---   * `factionSelectOnly`（选国页）→ 只选国家，**永不钻到省**；无主地 = 不选中
---@param provId number|nil
---@return string|nil level "province" | "faction" | nil（清空选择）
function MapWidget:_resolveSelectionLevel(provId)
    if not provId then return nil end
    local live = self.gameState and self.gameState.provinces[provId]
    if live and live.isWasteland then return nil end

    local ownerId = live and live.ownerId or nil

    -- 选国页：点谁都只按"国家"选（整国高亮 + 右侧介绍卡），不给钻到省
    if self.factionSelectOnly then
        return ownerId and "faction" or nil
    end

    if not ownerId then return "province" end                    -- 无主之地
    if self.zoom >= SELECT_FACTION_MAX_ZOOM then return "province" end

    -- 缩得很远：同一个国家已经选中了吗？（国家粒度或省粒度都算）
    if self.selectedProvinceId then
        local cur = self.gameState.provinces[self.selectedProvinceId]
        if cur and cur.ownerId == ownerId then
            return "province"    -- 已选该国 → 钻到省
        end
    end
    return "faction"             -- 还没选过这个国家 → 先选国家
end

--- 清掉地图上的选中高亮（2026-09-23 用户："关闭详情（点叉号）…为什么这个区块还是发亮"）：
---   省选中高亮 + 军队旗的沿形金光。由 UI 层在"用户主动关面板/点空白"时调
---   （GameUI.onClearMapHighlight → main.lua 注入）。
---   ⚠️ 不要在程序化 hide（如点别的省顺手收起）里调 —— 那会把刚设上的新高亮也清掉。
function MapWidget:clearSelectionHighlight()
    self.selectedArmy_     = nil
    self.selectedGarrison_ = nil
    self:setSelectedProvince(nil)
end

--- 只清军队金光（点省份时用 —— 省高亮随后由 setSelectedProvince 另设，不能一起清）
function MapWidget:clearArmyHighlight()
    self.selectedArmy_     = nil
    self.selectedGarrison_ = nil
end

---@param id number|nil 省 id（nil = 清空选择）
---@param level string|nil "province" | "faction"；不传则保持现有粒度（没有则按当前倍率兜底）
function MapWidget:setSelectedProvince(id, level)
    self.selectedProvinceId = id
    if not id then
        self.selectionLevel_ = nil
    elseif level then
        self.selectionLevel_ = level
    elseif not self.selectionLevel_ then
        self.selectionLevel_ = (self.zoom >= SELECT_FACTION_MAX_ZOOM) and "province" or "faction"
    end
    if self.shaderRenderer then
        self.shaderRenderer:setSelected(id)
        -- 整国高亮：选中省所属势力（无主/沙漠为 nil → 只高亮单省）
        local owner = nil
        if id then
            local live = self.gameState and self.gameState.provinces[id]
            if live and not live.isWasteland then
                owner = live.ownerId
            end
        end
        self.shaderRenderer:setSelectedFaction(owner)
    end
end

--- 标记 LUT 需要重建（归属变化 / 地图模式切换 / 编辑器上色后调用）
function MapWidget:markLutDirty()
    self.lutDirty_ = true
end

--- 归属签名：用于自动检测归属变化（大陆军占领、AI 战争等不经过本 widget 的修改）
---@return integer
function MapWidget:_lutSignature()
    local h = 2166136261
    local mode = tostring((self.gameState and self.gameState.mapMode) or "political")
    for i = 1, #mode do
        h = (h ~ mode:byte(i)) * 16777619
    end
    h = (h ~ (self.viewMode_ == "terrain" and 1 or 2)) * 16777619
    local provs = self.gameState and self.gameState.provinces
    if provs then
        for pid, st in pairs(provs) do
            local o = (st and st.ownerId) or 0
            local pn = tonumber(pid) or 0
            h = (h ~ (o * 31 + pn)) * 16777619
        end
    end
    return h
end

--- LUT 重建（脏标记 or 每 20 帧兜底比对签名）
--- ⚠️ 单次重建实测约 9ms（CPU 侧 2×4096 次 Image:SetPixel），编辑器连续涂抹时
---    必须限流：两次重建至少间隔 4 帧，避免每笔都重建拖慢编辑器。
function MapWidget:_refreshLutIfNeeded()
    local sr = self.shaderRenderer
    if not sr then return end
    self.lutFrame_ = (self.lutFrame_ or 0) + 1
    if self.lutDirty_ then
        if (self.lutFrame_ - (self.lutLastBuild_ or -99)) < 4 then
            return
        end
        self.lutDirty_ = false
    elseif (self.lutFrame_ % 20) == 0 then
        local sig = self:_lutSignature()
        if sig == self.lutSig_ then return end
    else
        return
    end
    self.lutLastBuild_ = self.lutFrame_
    self.lutSig_ = self:_lutSignature()
    sr:updateLUT(
        function(id) return self:_lutColorFor(id) end,
        function(id) return self:_lutFactionKeyFor(id) end
    )
    print("[Map] LUT 重建（shader 地图上色）")
end

--- 聚焦到省份：把镜头移动到省份中心并选中它
---@param provinceId number
---@param zoom number|nil
---@return boolean
function MapWidget:focusProvince(provinceId, zoom)
    local prov = provinceId and Provinces.byId[provinceId]
    if not prov or not prov.center then return false end

    -- 显式按"省"粒度：本函数的语义就是"聚焦到这一块省"（不管当前倍率多低）
    self:setSelectedProvince(provinceId, "province")
    self.camX = prov.center[1]
    self.camY = prov.center[2]
    if zoom then
        self.zoom = clamp(zoom, ZOOM_MIN, ZOOM_MAX)
        self.targetZoom = self.zoom
    end
    self:_clampCamera()
    return true
end

function MapWidget:getSelectedProvince()
    return self.selectedProvinceId
end

--- 聚焦到一组省份的包围盒（和平条约打开时把镜头拉到被索取方领土）
--- 自动计算中心 + 适配视口的最佳缩放（留出条约左右栏的余量，避免遮挡）。
---@param provinceIds number[]|nil  逻辑坐标（地图单位）
---@param options table|nil { paddingRatio=0.18, maxZoom=2.2, instant=false }
---@return boolean
function MapWidget:focusTerritory(provinceIds, options)
    options = options or {}
    local l = self:GetAbsoluteLayout()
    if not l or l.w <= 0 or l.h <= 0 then return false end

    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local n = 0
    for _, pid in ipairs(provinceIds or {}) do
        local prov = pid and Provinces.byId[pid]
        if prov and prov.center then
            local cx, cy = prov.center[1], prov.center[2]
            if cx < minX then minX = cx end
            if cx > maxX then maxX = cx end
            if cy < minY then minY = cy end
            if cy > maxY then maxY = cy end
            n = n + 1
        end
    end
    if n == 0 then return false end

    local padRatio = options.paddingRatio or 0.18
    local w = (maxX - minX) * (1 + padRatio * 2)
    local h = (maxY - minY) * (1 + padRatio * 2)
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end

    -- 视口可用区 = 减去左右条约栏 + 顶部标题栏（用宽高比折算）
    local availW = l.w * 0.52   -- 中间地图可见区≈屏幕宽 52%
    local availH = l.h * 0.82   -- 顶部标题栏约 12%、底部留白
    local zoomX = availW / w
    local zoomY = availH / h
    local z = math.min(zoomX, zoomY)
    z = math.max(ZOOM_MIN, math.min(ZOOM_MAX, z))
    local maxZoom = options.maxZoom or 2.2
    if z > maxZoom then z = maxZoom end

    local cx = (minX + maxX) * 0.5
    local cy = (minY + maxY) * 0.5

    if options.instant then
        self.camX, self.camY, self.zoom, self.targetZoom = cx, cy, z, z
    else
        self.camX, self.camY = cx, cy
        self.targetZoom = z
    end
    self:_clampCamera()
    return true
end

------------------------------------------------------------
-- 多边形取用（描边/填色共用）
-- 2026-09-12：删掉低模（lodLow）。原因：金边是 2px 细线，容差 8px 的低模
-- 会把底图上 ±8px 的小弯捋成直线 → 用户看到"金边是直的、不贴边界"。
-- 现在数据本身就是「按判省位图共享像素边重建 + 容差 1px」的高精度环，
-- 低缩放/高缩放共用同一份几何，也就不再需要 LOD 切换。
------------------------------------------------------------

---@param prov table
---@return table[] polygon
function MapWidget:_renderPoly(prov)
    return prov.polygon
end

---@param prov table
---@return table[]|nil holes
function MapWidget:_renderHoles(prov)
    return prov.holes
end

------------------------------------------------------------
-- Live ownership helpers
------------------------------------------------------------

--- Live owner faction id for a province (falls back to static data).
---@param prov table province record (static data is fine, we read .id)
---@return number|nil
function MapWidget:_ownerId(prov)
    if self.gameState and self.gameState.provinces then
        local live = self.gameState.provinces[prov.id]
        if live and live.ownerId ~= nil then
            return live.ownerId
        end
    end
    return prov.ownerId
end

--- Faction colour by faction id.
---@param factionId number|nil
function MapWidget:_factionColorById(factionId)
    if factionId then
        local gc = FACTION_GEO_COLORS[factionId]
        if gc then
            return gc[1], gc[2], gc[3]
        end
        if self.gameState and self.gameState.factions then
            local faction = self.gameState.factions[factionId]
            if faction and faction.color then
                return faction.color[1] or 180,
                       faction.color[2] or 180,
                       faction.color[3] or 180
            end
        end
    end
    return UNOWNED_R, UNOWNED_G, UNOWNED_B
end

--- Get the faction colour for a province (uses LIVE ownership when available).
function MapWidget:_factionColor(prov)
    return self:_factionColorById(self:_ownerId(prov))
end

--- Live faction display name by id (falls back to "?").
function MapWidget:_factionName(factionId)
    if self.gameState and self.gameState.factions then
        local f = self.gameState.factions[factionId]
        if f then return f.name or "?" end
    end
    return "?"
end

--- Build (and cache) the capital marker list from live faction data.
--- 每个势力的 capitalId 即首都（GenFactions 生成）；EU4 数据无 ownerId，
--- 计算每个势力的领土几何中心与包围盒（所有省份 center 平均 + bbox 合并），
--- 国名显示在领土中央（避免拉远错位）；bbox 用于屏幕面积过滤与碰撞避让。
---@return table[]  array of { factionId, center={x,y}, bbox={minX,minY,maxX,maxY} }
function MapWidget:_buildTerritoryCenters()
    if self.terrCenters_ then return self.terrCenters_ end
    local list = {}
    local gs = self.gameState
    if gs and gs.factions then
        for fid, f in pairs(gs.factions) do
            local provs = f and f.provinces
            if provs and #provs > 0 then
                local sx, sy, n = 0, 0, 0
                local bMinX, bMinY, bMaxX, bMaxY = nil, nil, nil, nil
                for _, pid in ipairs(provs) do
                    local prov = Provinces.byId[pid]
                    if prov and prov.center then
                        sx = sx + prov.center[1]
                        sy = sy + prov.center[2]
                        n = n + 1
                    end
                    local bb = prov and spatialIdx:getAABB(prov.id)
                    if bb then
                        if not bMinX or bb.minX < bMinX then bMinX = bb.minX end
                        if not bMinY or bb.minY < bMinY then bMinY = bb.minY end
                        if not bMaxX or bb.maxX > bMaxX then bMaxX = bb.maxX end
                        if not bMaxY or bb.maxY > bMaxY then bMaxY = bb.maxY end
                    end
                end
                if n > 0 then
                    list[#list + 1] = {
                        factionId = fid,
                        center    = { sx / n, sy / n },
                        bbox      = bMinX and {
                            minX = bMinX, minY = bMinY, maxX = bMaxX, maxY = bMaxY,
                        } or nil,
                    }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.factionId < b.factionId end)
    self.terrCenters_ = list
    return self.terrCenters_
end

--- 编辑工具：统计当前选中的区块数
function MapWidget:_countSelected()
    local n = 0
    for _, v in pairs(MapEditor.selected) do
        if v then n = n + 1 end
    end
    return n
end

--- LUT 颜色函数：省 id → {r,g,b}（0-255）。返回 nil 用默认色。
--- political 模式：势力色；无主 = 米色。terrain 模式：地形色。
---@param id number
---@return table|nil
function MapWidget:_lutColorFor(id)
    local prov = Provinces.byId[id]
    if not prov or prov.isOcean then
        return nil
    end
    -- 编辑器等外部上色回调优先（自定义政治着色）
    if self.overlayColorFn then
        local r, g, b = self.overlayColorFn(id, prov)
        if r then return { r, g, b } end
        return { UNOWNED_R, UNOWNED_G, UNOWNED_B }
    end
    -- 地形模式（2026-09-19 用户：「文化」按钮改「地形」）：
    --   走 mapMode（不是 viewMode_）—— LUT 签名本来就含 mapMode，切模式自动重建，少一处同步
    if self.gameState and self.gameState.mapMode == "terrain" then
        local tc = TERRAIN_VIEW_COLORS[prov.terrain] or TERRAIN_VIEW_COLORS["平原"]
        return tc
    end
    if self.viewMode_ == "terrain" then
        local tc = TERRAIN_VIEW_COLORS[prov.terrain] or TERRAIN_VIEW_COLORS["平原"]
        return tc
    end
    local oid = self:_ownerId(prov)
    if oid then
        local r, g, b = self:_factionColorById(oid)
        return { r, g, b }
    end
    -- 无主省：米色（与底图陆地色一致）
    return { UNOWNED_R, UNOWNED_G, UNOWNED_B }
end

--- LUT 势力键函数：省 id → 边界判定键（同势力同键 → 不画内部边界）。
--- 有主省 = faction_id；无主省 = 256 + id（每省唯一，与势力键不冲突）；
--- 海洋 = 0（由 shader 单独处理海岸线）。
---@param id number
---@return number
function MapWidget:_lutFactionKeyFor(id)
    local prov = Provinces.byId[id]
    if not prov or prov.isOcean then
        return 0
    end
    -- 地形模式：每省独立键 → 画出全部省界（地形按地块看，不该按国家合并）
    if self.gameState and self.gameState.mapMode == "terrain" then
        return 256 + id
    end
    local oid = self:_ownerId(prov)
    if oid then
        return oid
    end
    return 256 + id
end

------------------------------------------------------------
-- Update (per-frame)
------------------------------------------------------------

function MapWidget:Update(dt)
    self.elapsedTime_ = self.elapsedTime_ + dt

    -- =====================================================================
    -- 调试快捷键（历史时代3 式资源注入）：
    --   小键盘1 = 金钱+100   R = 粮草+100   小键盘3 = 兵力+100
    --   小键盘4 = 名声+100  小键盘5 = 稳定+100
    -- （原小键盘 1-6 的 MapEditor 删除/合并/涂抹/撤销/帮助已按用户要求移除）
    -- =====================================================================
    if input:GetKeyPress(KEY_KP_1) then
        self:addDebugResource("gold", 100)
    end
    if input:GetKeyPress(KEY_R) then
        self:addDebugResource("food", 100)
    end
    if input:GetKeyPress(KEY_KP_3) then
        self:addDebugResource("army", 100)
    end
    if input:GetKeyPress(KEY_KP_4) then
        self:addDebugResource("prestige", 100)
    end
    if input:GetKeyPress(KEY_KP_5) then
        self:addDebugResource("stability", 100)
    end
    if input:GetKeyPress(KEY_S) then
        MapEditor.save()
    end
    if input:GetKeyPress(KEY_ESCAPE) then
        MapEditor.exit()
        print("[MapEditor] 已退出编辑模式")
    end

    -- Keyboard panning
    local speed = CAM_PAN_SPEED * dt / self.zoom
    if input:GetKeyDown(KEY_UP) then
        self.camY = self.camY - speed
    end
    if input:GetKeyDown(KEY_DOWN) then
        self.camY = self.camY + speed
    end
    if input:GetKeyDown(KEY_LEFT) then
        self.camX = self.camX - speed
    end
    if input:GetKeyDown(KEY_RIGHT) then
        self.camX = self.camX + speed
    end

    -- Minimap toggle removed (M key freed)

    -- View mode toggle (T key): political ↔ terrain
    if input:GetKeyPress(KEY_T) then
        if self.viewMode_ == "political" then
            self.viewMode_ = "terrain"
        else
            self.viewMode_ = "political"
        end
        self.lutDirty_ = true   -- 换色方案 → 重建 LUT
        print("[Map] 视图切换: " .. (self.viewMode_ == "terrain" and "地形" or "政治"))
    end

    -- ── 拖动中记录相机速度（供松手后的惯性）──
    if self.isDragging_ and self.prevCamX_ then
        local inv = 1.0 / math.max(dt, 0.001)
        local vx = (self.camX - self.prevCamX_) * inv
        local vy = (self.camY - self.prevCamY_) * inv
        self.flingVX_ = self.flingVX_ * 0.6 + vx * 0.4
        self.flingVY_ = self.flingVY_ * 0.6 + vy * 0.4
    end
    self.prevCamX_, self.prevCamY_ = self.camX, self.camY

    -- ── 松手惯性：指数衰减滑行（只对触摸生效，鼠标拖动无惯性）──
    if not self.isDragging_ and not self.pinchActive_ and self.dragFromTouch_ then
        local sp = math.sqrt(self.flingVX_ * self.flingVX_ + self.flingVY_ * self.flingVY_)
        if sp > PAN_FLING_MIN then
            -- ⚠️ 方向必须与拖动一致：拖动时 camX 的增量就是速度方向 → 这里要「加」
            -- （2026-09-12 修：之前写成减号，松手后地图往反方向回弹）
            self.camX = self.camX + self.flingVX_ * dt
            self.camY = self.camY + self.flingVY_ * dt
            local k = math.exp(-PAN_FLING_DECAY * dt)
            self.flingVX_ = self.flingVX_ * k
            self.flingVY_ = self.flingVY_ * k
            -- 速度上限：约 2.5 屏/秒，避免快速滑动后地图飞出去
            local pl = self:GetAbsoluteLayout()
            if pl and pl.w > 0 then
                local vmax = 2.5 * pl.w / math.max(self.zoom, 0.001)
                local sp2 = math.sqrt(self.flingVX_ * self.flingVX_ + self.flingVY_ * self.flingVY_)
                if sp2 > vmax then
                    local scale = vmax / sp2
                    self.flingVX_ = self.flingVX_ * scale
                    self.flingVY_ = self.flingVY_ * scale
                end
            end
        else
            self.flingVX_, self.flingVY_ = 0, 0
        end
    end

    -- ── 平滑缩放 ──
    local diff = self.targetZoom - self.zoom
    if math.abs(diff) > 0.001 then
        local t = 1.0 - math.exp(-ZOOM_LERP_SPEED * dt)
        self.zoom = self.zoom + diff * t
    elseif self.zoom ~= self.targetZoom then
        self.zoom = self.targetZoom
    end

    -- ── 捏合锚点：每帧按「当前 zoom」重算相机 ──
    -- （旧实现按 targetZoom 算，而画面还在渐变 → 手指下的地点会漂）
    if self.pinchActive_ and self.pinchAnchorLogical_ and self.pinchAnchorScreen_ then
        local pl = self:GetAbsoluteLayout()
        if pl and pl.w > 0 and pl.h > 0 then
            local sx, sy = self.pinchAnchorScreen_.x, self.pinchAnchorScreen_.y
            self.camX = self.pinchAnchorLogical_.x - (sx - pl.x - pl.w * 0.5) / self.zoom
            self.camY = self.pinchAnchorLogical_.y - (sy - pl.y - pl.h * 0.5) / self.zoom
        end
    end

    self:_clampCamera()

    -- =====================================================================
    -- 🔧 P 社 shader 层同步：相机 + LUT（势力/地形变化时重建）
    -- =====================================================================
    if self.shaderRenderer then

        local l = self:GetAbsoluteLayout()
        -- NaN 防御（布局首帧可能返回 NaN，NaN 比较恒为 false）
        local lw, lh = (l and l.w) or 0, (l and l.h) or 0
        if not (lw == lw) or not (lh == lh) then lw, lh = 0, 0 end
        local viewW = lw > 0 and lw or 800
        local viewH = lh > 0 and lh or 600
        self.shaderRenderer:update(self.camX, self.camY, self.zoom, viewW, viewH)

        -- 3D 视口对齐到 widget 区域（否则地图会画到其它 UI 面板范围外）
        if self.onSyncViewport and l and lw > 0 and lh > 0 then
            self.onSyncViewport(l.x, l.y, lw, lh)
        end

        -- 归属/地形/地图模式变化 → 重建 LUT 纹理
        self:_refreshLutIfNeeded()
    end
end

------------------------------------------------------------
-- 底图（整图）
------------------------------------------------------------

--- 取整图纹理句柄；失败返回 0。
--- 失败分两种，处理方式相反：
---   ① 资源还在「边玩边下」（手机首次进入）→ 主动催下载 + 隔 0.5s 清负缓存重试
---   ② 文件已在本地却仍解不出来（纹理超设备上限/显存不够）→ **不再重试**
---      （重试等于反复解码几十 MB 的 PNG，只会让画面一直卡）
---@param path string|nil
---@return number handle
function MapWidget:_wholeImageHandle(path)
    if not path or path == "" then
        return 0
    end
    local wasLoaded = ImageCache.IsLoaded(path)
    local t0 = os.clock()
    local h = ImageCache.Get(path)
    if h and h > 0 then
        if not wasLoaded then
            print(string.format("[Map] 底图解码 %s → %.0f ms", path, (os.clock() - t0) * 1000))
        end
        return h
    end

    -- 文件在本地了吗？（拿不到下载状态 API 时按「在本地」处理，只看解码结果）
    local c = GetCache()
    local state = (c and c.GetDownloadState) and c:GetDownloadState(path) or nil
    local localReady = (state == nil) or (state == DOWNLOAD_COMPLETED)
    if localReady then
        local n = (self.wholeFail_[path] or 0) + 1
        self.wholeFail_[path] = n
        if n == 1 then
            print(string.format("[Map] ⚠️ 底图解码失败（本地已有文件，判为设备纹理/显存限制）: %s", path))
        end
        return 0
    end

    -- 还没下完：催下载 + 节流重试
    local n = (self.wholeFail_[path] or 0) + 1
    if n > WHOLE_MAX_RETRY then
        return 0
    end
    if os.clock() >= self.wholeRetryAt_ then
        self.wholeRetryAt_ = os.clock() + WHOLE_RETRY_SEC
        self.wholeFail_[path] = n
        if n == 1 or n % 10 == 0 then
            print(string.format("[Map] ⏳ 底图还在下载 %s（第 %d 次重试，state=%s）",
                path, n, tostring(state)))
        end
        ImageCache.Release(path)              -- 清负缓存，下一轮重新尝试解码
        if not self.wholeDownloadAsked_[path] then
            self.wholeDownloadAsked_[path] = true
            if c and c.DownloadResource then
                c:DownloadResource(path, function(ok, err)
                    print(string.format("[Map] 底图下载 %s → %s%s", path, tostring(ok),
                        err and (" / " .. tostring(err)) or ""))
                end)
            end
        end
    end
    return 0
end

--- 底图是否已就绪（载入画面据此决定「要不要再等一帧」—— 手机首次进入要下载底图）。
--- 未就绪时顺手催一下（首次会发起 DWP 下载），所以载入循环里调它就能推进下载。
---@return boolean
function MapWidget:IsMapImageReady()
    local p = MapPack.WHOLE_IMAGE_HALF_PATH or MapPack.WHOLE_IMAGE_PATH
    if not p then
        return true
    end
    if ImageCache.IsLoaded(p) then
        return true
    end
    self:_wholeImageHandle(p)
    return false
end

--- 交战标记图标（双剑交叉）句柄；加载不出来返回 0（调用方退回白叉）。
--- 路径在 GameConfig.Icons.battle.path（玩家/模组可改）；手机首次可能还在下载，
--- 所以失败时隔 1 秒清一次负缓存重试。
---@return number handle
function MapWidget:_battleIconHandle()
    local cfg = GameConfig.Icons and GameConfig.Icons.battle
    ---@type string|nil
    local path = nil
    if type(cfg) == "table" then
        path = cfg.path                      -- { path =, size =, frames =, fps = }
    elseif type(cfg) == "string" then
        path = cfg                           -- 兼容只写路径的老写法
    end
    if not path or path == "" then
        return 0
    end
    local h = ImageCache.Get(path)
    if h and h > 0 then
        return h
    end
    local now = os.clock()
    if now >= (self.battleIconRetryAt_ or 0) then
        self.battleIconRetryAt_ = now + 1.0
        ImageCache.Release(path)
    end
    return 0
end

--- 被占领省的斜条纹图案句柄；配套 GameConfig.Icons.occupiedStripes（模组可换）
--- ⚠️ 必须带 **REPEAT** 标志创建：条纹靠"平铺"铺满整个省，默认 CLAMP 模式下
---    只有第一格是实的、其余是边缘拉伸 → 看起来什么都没有（踩过）。
---@return number handle
function MapWidget:_occupiedStripeHandle()
    local path = GameConfig.Icons and GameConfig.Icons.occupiedStripes
    if not path or path == "" then
        return 0
    end
    if self.stripeHandle_ and self.stripeHandle_ > 0 then
        return self.stripeHandle_
    end
    local now = os.clock()
    if now < (self.stripeRetryAt_ or 0) then
        return 0
    end
    self.stripeRetryAt_ = now + 1.0
    local nvg = ImageCache.GetContext and ImageCache.GetContext()
    if not nvg then
        return 0
    end
    -- 6 = NVG_IMAGE_REPEATX(2) | NVG_IMAGE_REPEATY(4)
    local h = nvgCreateImage(nvg, path, 6)
    if h and h > 0 then
        self.stripeHandle_ = h
        print("[Map] 被占领条纹贴图已加载：" .. path)
        return h
    end
    return 0
end

--- 选当前帧该画的整图：低倍率→半分辨率（省显存），≥WHOLE_FULL_ZOOM→全分辨率。
--- 全分辨率未就绪（如手机显存不足/加载失败）时自动回退半分辨率，绝不空图。
---@return number handle
---@return string|nil path
function MapWidget:_pickWholeImage()
    local full = MapPack.WHOLE_IMAGE_PATH
    local half = MapPack.WHOLE_IMAGE_HALF_PATH
    local handle, path = 0, nil
    if full and self.zoom >= WHOLE_FULL_ZOOM then
        local h = self:_wholeImageHandle(full)
        if h > 0 then handle, path = h, full end
    end
    if handle <= 0 and half then
        local h = self:_wholeImageHandle(half)
        if h > 0 then handle, path = h, half end
    end
    -- 没有半分辨率版、或半分辨率加载失败：低倍率时仍用全分辨率顶着
    if handle <= 0 and full then
        local h = self:_wholeImageHandle(full)
        if h > 0 then handle, path = h, full end
    end
    if path ~= self.wholeLodPath_ then
        self.wholeLodPath_ = path
        print(string.format("[Map] 底图 → %s (zoom=%.2f)", tostring(path), self.zoom))
    end
    return handle, path
end

--- 预加载底图（建地图 widget 时同步解一次）。
--- 两张都解：半分辨率（低倍率用）+ 全分辨率（放大到 ≥1.0 用）——
--- 否则第一次捏合放大要现解码几百毫秒，手感上就是「卡一下」。
---@return number handle 主用图（半分辨率）句柄
function MapWidget:PreloadMapImage()
    local half = MapPack.WHOLE_IMAGE_HALF_PATH
    local full = MapPack.WHOLE_IMAGE_PATH
    local t0 = os.clock()
    local h = self:_wholeImageHandle(half or full)
    if full and full ~= half then
        self:_wholeImageHandle(full)     -- 全分辨率：失败也继续（_pickWholeImage 会回退半图）
    end
    print(string.format("[Map] 底图预载完成 %.0f ms（半图 handle=%s）",
        (os.clock() - t0) * 1000, tostring(h)))
    return h
end

--- 分块瓦片底图（回退路径：地图包没配 WHOLE_IMAGE_PATH 时使用）
--- 瓦片按需解码、每帧限流，未就绪的块会短暂露黑底 —— 主线已改整图。
---@param nvg any
---@param vMinX number
---@param vMinY number
---@param vMaxX number
---@param vMaxY number
function MapWidget:_renderTileBackground(nvg, vMinX, vMinY, vMaxX, vMaxY)
    local txMin = math.max(0, math.floor(vMinX / TILE_L))
    local txMax = math.min(TILE_COLS - 1, math.floor(vMaxX / TILE_L))
    local tyMin = math.max(0, math.floor(vMinY / TILE_L))
    local tyMax = math.min(TILE_ROWS - 1, math.floor(vMaxY / TILE_L))

    -- 每帧最多新建 N 张瓦片（PNG 解码很贵，一次全建会卡顿）；
    -- 同时向外扩一圈做「预加载」（只加载不绘制），拖动/缩放时下一块已就绪
    local newLoads = 0
    local handle = 0
    local lxMin = math.max(0, txMin - 1)
    local lxMax = math.min(TILE_COLS - 1, txMax + 1)
    local lyMin = math.max(0, tyMin - 1)
    local lyMax = math.min(TILE_ROWS - 1, tyMax + 1)

    for ty = lyMin, lyMax do
        for tx = lxMin, lxMax do
            local inView = (tx >= txMin and tx <= txMax and ty >= tyMin and ty <= tyMax)
            local tilePath = string.format(MapPack.TILE_PATH_PATTERN, tx, ty)
            local loaded = ImageCache.IsLoaded(tilePath)
            if not loaded and newLoads >= TILE_LOADS_PER_FRAME then
                handle = 0                      -- 本帧配额用完：下一帧再加载
            else
                if not loaded then newLoads = newLoads + 1 end
                handle = ImageCache.Get(tilePath)
            end
            if not inView then handle = 0 end   -- 外圈只预加载，不绘制
            if not handle or handle <= 0 then
                -- nvgCreateImage 首次失败会被 ImageCache 永久缓存为 handle=0(Web 首帧
                -- 异步/资源未就绪常见),之后永不重试 → 地图整片黑。释放负缓存,
                -- 让后续帧重新尝试加载,直到成功为止。
                ImageCache.Release(tilePath)
            else
                -- 出血瓦片：文件为 (TILE_PX+2*PAD)²，绘制同样外扩 PAD 逻辑尺寸；
                -- 邻块的出血区内容一致，互相覆盖后无接缝（消除缩小时的横竖细线）
                local ox = tx * TILE_L - TILE_PAD_L
                local oy = ty * TILE_L - TILE_PAD_L
                local ow = TILE_L + TILE_PAD_L * 2
                local oh = TILE_L + TILE_PAD_L * 2
                nvgBeginPath(nvg)
                nvgRect(nvg, ox, oy, ow, oh)
                nvgFillPaint(nvg, nvgImagePattern(nvg, ox, oy, ow, oh, 0, handle, 1.0))
                nvgFill(nvg)
            end
        end
    end
end

------------------------------------------------------------
-- Render (NanoVG 叠加层；底图 = 整图或瓦片)
------------------------------------------------------------

function MapWidget:Render(nvg)
    local l = self:GetAbsoluteLayout()
    if not l or l.w <= 0 or l.h <= 0 then
        return
    end
    -- NaN 相机防御：zoom/cam 出现非有限数时跳过本帧（否则所有坐标变换 NaN → 整图不绘制）
    if self.zoom ~= self.zoom or self.camX ~= self.camX or self.camY ~= self.camY then
        return
    end

    -- 首帧自适应全图视角：布局这时才算出有效尺寸，所以只能等到这里做（只做一次）
    -- ⚠️ 只在"没人动过相机"时才自动全图：相机还停在初始常量上才算没人动过。
    --    否则会把 SHOT_CAM（直接写 camX/camY）、focusProvince、SHOT_ZOOM 这类
    --    **显式指定过视角**的调用覆盖掉。
    if self._needFitAll then
        self._needFitAll = false
        if self.camX == INITIAL_CAM_X and self.camY == INITIAL_CAM_Y
            and self.zoom == INITIAL_ZOOM then
            self:fitWholeMap()
        end
    end

    local camX = self.camX
    local camY = self.camY
    local zoom = self.zoom

    -- Compute viewport bounds in logical coords for culling (labels / overlays)
    local halfW = l.w * 0.5
    local halfH = l.h * 0.5
    local vMinX = camX - halfW / zoom
    local vMinY = camY - halfH / zoom
    local vMaxX = camX + halfW / zoom
    local vMaxY = camY + halfH / zoom

    -- 可见省（标签/叠加层用；地图画面已由 shader 全权渲染）
    local visibleProvs = {}
    local visibleCount = 0
    for i = 1, #Provinces.data do
        local prov = Provinces.data[i]
        if not prov.isOcean and prov.polygon and #prov.polygon >= 3 then
            if spatialIdx:isInViewport(prov.id, vMinX, vMinY, vMaxX, vMaxY) then
                visibleCount = visibleCount + 1
                visibleProvs[visibleCount] = prov
            end
        end
    end

    -- Transform: map logical coords → screen coords（叠加层绘制）
    nvgSave(nvg)
    nvgIntersectScissor(nvg, l.x, l.y, l.w, l.h)
    nvgTranslate(nvg, l.x + halfW - camX * zoom, l.y + halfH - camY * zoom)
    nvgScale(nvg, zoom, zoom)

    -- =====================================================================
    -- 底图：整图优先（MapPack.WHOLE_IMAGE_PATH 存在时），否则回退分块瓦片
    --
    -- 为什么改整图（2026-09-12）：瓦片按需解码（每帧限流 2 张），未就绪的块就是
    -- 一块黑——拖动/缩放时满屏黑方块。整图只有一次解码（建 widget 时预载），
    -- 之后永不缺块；显存也更省（5640×3840 整图 86MB < 全部瓦片 100MB+）。
    -- 低倍率画半分辨率图（21MB），放大到 ≥1.0 才切全分辨率。
    -- =====================================================================
    -- 全矢量改造（2026-09-22）：游戏内（有 gameState）映射底图**不再绘制** —— 下方的
    --   「矢量地图底」已全覆盖（海=纯色、陆=逐省矢量填色），缩放不再有像素感；
    --   位图底图仅保留给编辑器（overlayColorFn）和无 gameState 的兜底路径。
    --   要回退成"位图底 + 矢量叠加"：把 useBitmapBase 改回恒 true 即可。
    local useBitmapBase = (self.gameState == nil) or (self.overlayColorFn ~= nil)
    if not self.shaderRenderer and useBitmapBase then
        if MapPack.WHOLE_IMAGE_PATH then
            local handle = self:_pickWholeImage()
            if handle > 0 then
                nvgBeginPath(nvg)
                nvgRect(nvg, 0, 0, Geography.MAP_W, Geography.MAP_H)
                nvgFillPaint(nvg, nvgImagePattern(nvg, 0, 0, Geography.MAP_W, Geography.MAP_H,
                    0, handle, 1.0))
                nvgFill(nvg)
            end
        else
            self:_renderTileBackground(nvg, vMinX, vMinY, vMaxX, vMaxY)
        end
    end

    -- =====================================================================
    -- 自定义政治着色层（可选）：编辑器等场景设置 mapWidget.overlayColorFn 后，
    -- 已归属(有主)省份按返回的 RGB 填充国家色；返回 nil 的省(无主/海洋/沙漠)不画。
    -- shader 地图层在位时改由 LUT 上色（_lutColorFor 会优先调用 overlayColorFn），
    -- 因此这里不再重复填充（避免盖住 shader 底图）。
    -- =====================================================================
    if self.overlayColorFn and not self.shaderRenderer then
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            if prov.polygon and #prov.polygon >= 3 then
                local r, g, b = self.overlayColorFn(prov.id, prov)
                if r then
                    local rp = self:_renderPoly(prov)
                    local rh = self:_renderHoles(prov)
                    nvgBeginPath(nvg)
                    tracePolygon(nvg, rp, rh)
                    nvgClosePath(nvg)
                    nvgFillColor(nvg, nvgRGBA(r, g, b, 242))
                    nvgFill(nvg)
                    -- 同色 2px 描边：闭合相邻省多边形之间的底图缝隙，
                    -- 避免放大后色块边界出现"锯齿裂纹"（填充+同色描边=无缝拼接）
                    nvgStrokeColor(nvg, nvgRGBA(r, g, b, 242))
                    nvgStrokeWidth(nvg, 2.0)
                    nvgStroke(nvg)
                end
            end
        end
    end

    -- =====================================================================
    -- 沙漠化地块：黄褐色覆盖 + 颗粒纹理（polygon 与底图同源,贴边无缝）
    -- isWasteland 是运行时状态,从 gameState.provinces 读取
    -- 注意:静态沙漠省(数据自带 isWasteland,如外围荒地)底图瓦片已是沙漠色,
    --   这里只渲染"游戏内动态沙漠化"的省(静态非沙漠但运行时变沙漠)
    -- =====================================================================
    for vi = 1, visibleCount do
        local prov = visibleProvs[vi]
        local live = self.gameState and self.gameState.provinces[prov.id]
        if live and live.isWasteland and not prov.isWasteland
           and prov.polygon and #prov.polygon >= 3 then
            local renderPoly = self:_renderPoly(prov)
            local renderHoles = self:_renderHoles(prov)
            -- 2026-09-17 用户："化为沙漠为什么像这个样子？我们的沙漠不长这样，为什么这么多点"
            --   → 不再用"纯色 + 点阵"，改成**直接取底图上真实沙漠的贴图**来平铺（同一张底图、
            --     同一个缩放，所以和地图天然的沙漠一模一样，也不会有颗粒感）。
            --   做法：找出一个**静态沙漠省**的中心当采样点，把整图 pattern 平移过去：
            --     图案原点 = -采样点 → 该省范围就贴上了那里的沙漠纹理。
            if not self._desertSample and self.provinces then
                for _, p in pairs(self.provinces) do
                    if p.isWasteland and p.polygon and #p.polygon >= 3 then
                        local cx0, cy0 = polygonCentroid(p.polygon)
                        self._desertSample = { x = cx0, y = cy0 }
                        break
                    end
                end
            end
            local desertHandle = (not self.shaderRenderer and MapPack.WHOLE_IMAGE_PATH)
                and self:_pickWholeImage() or 0
            if desertHandle > 0 and self._desertSample then
                nvgBeginPath(nvg)
                tracePolygon(nvg, renderPoly, renderHoles)
                nvgClosePath(nvg)
                nvgFillPaint(nvg, nvgImagePattern(nvg,
                    -self._desertSample.x, -self._desertSample.y,
                    Geography.MAP_W, Geography.MAP_H, 0, desertHandle, 1.0))
                nvgFill(nvg)
            else
                -- 兜底（shader 地图 / 拿不到底图）：纯沙漠色
                nvgBeginPath(nvg)
                tracePolygon(nvg, renderPoly, renderHoles)
                nvgClosePath(nvg)
                nvgFillColor(nvg, nvgRGBA(214, 186, 132, 245))
                nvgFill(nvg)
            end
            nvgBeginPath(nvg)
            tracePolygon(nvg, renderPoly, renderHoles)
            nvgClosePath(nvg)
            nvgStrokeColor(nvg, nvgRGBA(140, 95, 48, 230))
            nvgStrokeWidth(nvg, 1.5 / zoom)
            nvgStroke(nvg)
        end
    end

    -- 地图模式着色（2026-09-01）：war 参战国红 / ally 视角国绿·敌红·盟友蓝·中立灰
    local mapMode = self.gameState and self.gameState.mapMode or "political"

    -- =====================================================================
    -- 矢量地图底（2026-09-22 全矢量改造 · 用户："把所有的都改成那个矢量…不要再出问题"）
    --   海面铺纯色 + 逐省矢量填色/描边 —— 海/陆/界线全部矢量绘制：
    --     · 任意缩放都平滑（不再有底图放大的像素感）
    --     · 观感与旧底图一致（海色 156,183,212 与无主米色 210,196,158 都对齐旧底图）
    --   取色（按当前 mapMode）：
    --     terrain            → 地形色（含无主/荒地）
    --     war / ally         → 我方蓝 / 敌方红 / 盟友蓝 / 中立灰（口径沿用旧分支）
    --     political/region/resource → 势力色（无主 = 米色兜底）
    --   画法：① 先描深灰粗边（地图坐标 3.0：缩放行为与旧底图一致、并盖住省间缝隙）
    --         ② 再填色 → 只留边界外侧的深灰线（无缝且区块清楚）
    --   低倍率（zoom < 0.4）省界看不清 → 跳过描边省一半开销
    -- =====================================================================
    if self.gameState and not self.shaderRenderer then
        local gs = self.gameState
        local mode = mapMode
        -- 取色结果用**复用表**承载：不返回多值（EmmyLua 对"多返回值联合"会误报类型错误），
        -- 复用同一个表也避免每帧每省新建 table 的 GC 压力
        local colorBuf = { 0, 0, 0 }
        ---@type fun(prov: table, live: table|nil): number[]|nil
        local colorFn
        if mode == "terrain" then
            -- 地形色范围（2026-09-23 定稿）：**全图每省都上色**，没有例外。
            --   曾经的"荒地不上色"规则（2026-09-22 用户："他如果是荒地那就是原本荒地的颜色"）
            --   已取消 —— 因为地图包里的 `isWasteland` 实际含义是"**可玩区以外的省**"
            --   （eu4 包 2259 个、world 包 3161 个），保留这条规则等于全世界只有可玩区
            --   那一块有颜色（用户："怎么还是只有这一块地方有颜色"）。
            --   数据本身是齐的：TerrainReal 覆盖了包括荒地在内的全部省份。
            colorFn = function(_, live)
                local tc = TERRAIN_VIEW_COLORS[(live and live.terrain) or "平原"]
                    or TERRAIN_VIEW_COLORS["平原"]
                colorBuf[1], colorBuf[2], colorBuf[3] = tc[1], tc[2], tc[3]
                return colorBuf
            end
        elseif mode == "war" or mode == "ally" then
            local pf = gs.playerFactionId
            local viewId = gs.allyViewFactionId or pf   -- 盟友视角国（默认玩家）
            -- 是否参与任何战争
            local function atWarAny(fid)
                local row = gs.relations and gs.relations[fid]
                if not row then return false end
                for _, rel in pairs(row) do
                    if rel and rel.atWar then return true end
                end
                return false
            end
            -- a 与 b 是否有共同敌人（视为盟友）
            local function shareEnemy(a, b)
                local row = gs.relations and gs.relations[a]
                if not row then return false end
                for c, rel in pairs(row) do
                    if rel and rel.atWar then
                        local rb = gs.relations[b] and gs.relations[b][c]
                        if rb and rb.atWar then return true end
                    end
                end
                return false
            end
            local function pick(r, g, b)
                colorBuf[1], colorBuf[2], colorBuf[3] = r, g, b
                return colorBuf
            end
            colorFn = function(_, live)
                local owner = live and live.ownerId
                if not owner then return nil end          -- 无主 → 米色兜底
                if mode == "war" then
                    if not pf then
                        -- 看海模式（没有"我方"）→ 旧口径：参战国红，其余走米色兜底
                        if atWarAny(owner) then return pick(220, 60, 60) end
                        return nil
                    end
                    local atWarWithPlayer = gs.relations[pf] and gs.relations[pf][owner]
                        and gs.relations[pf][owner].atWar
                    if owner == pf then return pick(70, 120, 235) end        -- 我方蓝
                    if atWarWithPlayer then return pick(220, 60, 60) end     -- 敌方红
                    return pick(120, 120, 120)                               -- 其余（不参战）灰
                end
                -- ally：选中绿 / 盟友蓝 / 敌方红 / 中立灰
                local atWarWithView = gs.relations[viewId] and gs.relations[viewId][owner]
                    and gs.relations[viewId][owner].atWar
                if owner == viewId then return pick(60, 200, 90) end
                if atWarWithView then return pick(220, 60, 60) end
                if shareEnemy(viewId, owner) then return pick(80, 140, 235) end
                return pick(120, 120, 120)
            end
        else
            -- political / region / resource：势力色（无主 → 米色兜底）
            colorFn = function(prov, live)
                local oid = (live and live.ownerId) or prov.ownerId
                if not oid then return nil end
                local fr, fg, fb = self:_factionColorById(oid)
                colorBuf[1] = fr or UNOWNED_R
                colorBuf[2] = fg or UNOWNED_G
                colorBuf[3] = fb or UNOWNED_B
                return colorBuf
            end
        end

        -- ① 海：整幅地图矩形铺纯色（采样自旧底图海面）；湖泊 = 省多边形 holes 挖空后透出这层
        nvgBeginPath(nvg)
        nvgRect(nvg, 0, 0, Geography.MAP_W, Geography.MAP_H)
        nvgFillColor(nvg, nvgRGBA(156, 183, 212, 255))
        nvgFill(nvg)
        -- ② 陆：逐省「深灰描边 → 填充」，描边宽 **3.0 地图像素固定**（不除 zoom）。
        --   固定宽度的深灰描边够粗 → 相邻两省的描边在中间连成一条 → 无缝、无重影；
        --   放大时线跟着变粗，跟底图上的省界行为一致。
        --   （2026-09-23 回退：用户拍板"用原来这版重新改" —— 后续的"屏幕恒定细线"
        --     会裂、"三遍法"放大有双线，都废弃。）
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            if prov.polygon and #prov.polygon >= 3 then
                local live = gs.provinces and gs.provinces[prov.id]
                -- 运行时沙漠化的省跳过（沙漠覆盖层画在本层之下，跳过才能透出来）
                local skip = live and live.isWasteland and not prov.isWasteland
                if not skip then
                    local c = colorFn(prov, live)
                    ---@type number
                    local r = (c and c[1]) or UNOWNED_R
                    ---@type number
                    local g = (c and c[2]) or UNOWNED_G
                    ---@type number
                    local b = (c and c[3]) or UNOWNED_B
                    -- 荒地：**所有视图模式、所有界面**一律固定米色（语义见文件顶 WASTELAND_* 注释）。
                    --   ⚠️ 判定要**同时看运行时态和地图静态数据**（2026-09-23 用户："那些荒地
                    --   在选择国家[界面]应该是它们本来的颜色才对"）：选国页/编辑器里 gameState
                    --   的省记录可能没有 isWasteland 字段，只认 live 会把 2259 个荒地全画成灰白。
                    if (live and live.isWasteland) or prov.isWasteland then
                        r, g, b = WASTELAND_R, WASTELAND_G, WASTELAND_B
                    end
                    local rp = self:_renderPoly(prov)
                    local rh = self:_renderHoles(prov)
                    nvgBeginPath(nvg)
                    tracePolygon(nvg, rp, rh)
                    nvgClosePath(nvg)
                    nvgStrokeColor(nvg, nvgRGBA(52, 50, 44, 235))
                    nvgStrokeWidth(nvg, 3.0)
                    nvgStroke(nvg)
                    nvgBeginPath(nvg)
                    tracePolygon(nvg, rp, rh)
                    nvgClosePath(nvg)
                    nvgFillColor(nvg, nvgRGBA(r, g, b, 255))
                    nvgFill(nvg)
                end
            end
        end
    end

    -- （war / ally 的填色已并入上面的「矢量地图底」统一分支 —— 2026-09-22 全矢量改造）

    -- 占领标记（2026-09-01）：被占领(occupiedBy)省 → 白色斜线；
    --   被吞并(ownerId≠初始)省 → 运行时填充当前主色；
    --   战斗中的省也叠加斜线（AoH3 式被占标记）
    if self.gameState then
        local gs = self.gameState
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            local live = gs.provinces and gs.provinces[prov.id]
            if live and not live.isWasteland and prov.polygon and #prov.polygon >= 3 then
                local occupiedBy = live.occupiedBy
                local annexed = live._initOwner and live.ownerId and live.ownerId ~= live._initOwner
                -- 交战标记改由 _renderArmyBadges 的「战斗行」画（屏幕坐标），这里只管占领/吞并
                if occupiedBy or annexed then
                    -- 吞并后颜色更新（运行时填充当前主色）
                    if annexed and live.ownerId then
                        local f = gs.factions and gs.factions[live.ownerId]
                        local c = f and f.color or { 150, 150, 150, 255 }
                        nvgBeginPath(nvg)
                        tracePolygon(nvg, self:_renderPoly(prov), self:_renderHoles(prov))
                        nvgClosePath(nvg)
                        nvgFillColor(nvg, nvgRGBA(c[1], c[2], c[3], 255))
                        nvgFill(nvg)
                    end
                    -- 省中心标记（2026-09-13 用户拍板的三态）：
                    --   * 被占领 → 占领方颜色的**斜条纹**（EU4/AoH3 通用语；替掉原来的白叉）
                    --   * 交战中 → 由 _renderArmyBadges 里的「战斗行」（两军旗标 + 中间双剑）负责，
                    --     这里不再画省中心图标（原来那个会随缩放/摆动，已废弃）
                    --   * 已割让/吞并 → 直接变新主人纯色（上面那段重填）
                    if occupiedBy then
                        local cx, cy = polygonCentroid(prov.polygon)
                        local sx, sy = self:logicalToScreen(cx, cy)
                        local onScreen = (sx >= l.x - 80 and sx <= l.x + l.w + 80
                            and sy >= l.y - 80 and sy <= l.y + l.h + 80)
                        local pat = self:_occupiedStripeHandle()
                        if pat > 0 and onScreen then
                            local occ = gs.factions and gs.factions[occupiedBy]
                            local col = (occ and occ.color) or { 255, 255, 255 }
                            local tile = OCCUPIED_STRIPE_TILE / zoom   -- 屏幕恒定间距
                            local style = OCCUPIED_STYLE
                            local poly = self:_renderPoly(prov)
                            local holes = self:_renderHoles(prov)

                            if style == 3 or style == 4 then
                                -- ============ 方案3/4：HOI4 铺满 ============
                                -- 占领方色**直接铺满整块**（不再做"两层颜色叠色"→
                                -- 根本不存在"占领方色和原主色像不像"的问题），
                                -- "被占了"这个状态由**半透明黑斜纹**（非颜色信号）表达。
                                nvgBeginPath(nvg)
                                tracePolygon(nvg, poly, holes)
                                nvgClosePath(nvg)
                                nvgFillColor(nvg, nvgRGBA(col[1] or 255, col[2] or 255, col[3] or 255,
                                    255 - OCC_FULL_DIM))
                                nvgFill(nvg)

                                -- 黑斜纹 = "被占、尚未割让"的统一符号（跟占领方是谁无关）
                                nvgBeginPath(nvg)
                                tracePolygon(nvg, poly, holes)
                                nvgClosePath(nvg)
                                nvgFillPaint(nvg, nvgImagePatternTinted(nvg, 0, 0, tile, tile, 0, pat,
                                    nvgRGBA(20, 16, 10, 100)))
                                nvgFill(nvg)
                            elseif style == 2 then
                                -- ============ 方案2：EU4 强制明暗 ============
                                -- 原主色**强制降饱和+压暗** → 一律变"灰暗底"；
                                -- 占领方色**保色相、把亮度拉进固定区间** → 一律是"鲜色条纹"。
                                -- 差异来自"灰 vs 彩、暗 vs 亮"，跟两国颜色像不像无关。
                                local br0, bg0, bb0 = self:_factionColorById(live.ownerId)
                                local br, bg, bb = occupyBaseColor({ br0, bg0, bb0 })
                                nvgBeginPath(nvg)
                                tracePolygon(nvg, poly, holes)
                                nvgClosePath(nvg)
                                nvgFillColor(nvg, nvgRGBA(br, bg, bb, 255))
                                nvgFill(nvg)

                                local sr, sg, sb = occupyStripeColor(col)
                                nvgBeginPath(nvg)
                                tracePolygon(nvg, poly, holes)
                                nvgClosePath(nvg)
                                nvgFillPaint(nvg, nvgImagePatternTinted(nvg, 0, 0, tile, tile, 0, pat,
                                    nvgRGBA(sr, sg, sb, OCCUPIED_STRIPE_ALPHA)))
                                nvgFill(nvg)
                            else
                                -- ============ 方案1：现状（压暗 + 占领方色斜纹）============
                                -- ① 先压暗底色（EU4 式"被占地区整体变暗"）：
                                --    不压暗的话，占领方颜色和原主颜色接近时（如 秦 的橄榄绿 vs 白狄 的土黄）
                                --    条纹会糊在一起，根本看不出被占了
                                nvgBeginPath(nvg)
                                tracePolygon(nvg, poly, holes)
                                nvgClosePath(nvg)
                                nvgFillColor(nvg, nvgRGBA(0, 0, 0, OCCUPIED_DIM_ALPHA))
                                nvgFill(nvg)

                                -- ② 占领方颜色的**粗斜纹**（2026-09-16 加粗/提到接近不透明）：
                                --    图案锚在 (0,0) → 全图条纹连续（不会每省各画一套）；填充自动裁剪在多边形内
                                nvgBeginPath(nvg)
                                tracePolygon(nvg, poly, holes)
                                nvgClosePath(nvg)
                                nvgFillPaint(nvg, nvgImagePatternTinted(nvg, 0, 0, tile, tile, 0, pat,
                                    nvgRGBA(col[1] or 255, col[2] or 255, col[3] or 255, OCCUPIED_STRIPE_ALPHA)))
                                nvgFill(nvg)
                            end

                            -- ③ 描一圈**占领方颜色**的边（所有方案共用；最醒目的一条线索）：
                            --    缩到全图时条纹会变糊，但"谁占了这块"看边框颜色就够
                            nvgBeginPath(nvg)
                            tracePolygon(nvg, poly, holes)
                            nvgClosePath(nvg)
                            nvgStrokeColor(nvg, nvgRGBA(col[1] or 255, col[2] or 255, col[3] or 255,
                                OCCUPIED_BORDER_ALPHA))
                            -- 2026-09-19 加粗（1.6/2.2 → 2.4/3.0）：用户"占了但地图上看不出来"
                            nvgStrokeWidth(nvg, math.max(2.4, 3.0 / zoom))
                            nvgStroke(nvg)

                            -- ④ 方案4：省中心插一面占领方小燕尾旗（颜色 + 国名首字）兜底
                            -- 被占省中心插旗（2026-09-19：所有方案都画，不再只是方案4）——
                            --   占领方色 + 国名首字，任何缩放下都能一眼认出"这块被谁占了"
                            if zoom >= OCC_FLAG_MIN_ZOOM then
                                self:_drawOccFlag(nvg, cx, cy, zoom, col,
                                    firstCharOf(occ and occ.name))
                            end
                        end
                    end
                end
            end
        end
    end

    -- 交互高亮：点击省 → 整国染亮 + 国家外轮廓描边（AoH/P社式，2026-09-12 改）
    --   * 染亮：整国统一亮度（不区分被点省） → 连成一片
    --   * 描边：只画"国家外轮廓"（同国省与省之间的边不画）→ 看得见国界、没有内部缝隙
    --   * 轮廓线段按（势力 + 被点省）缓存，切换选择时才重算
    -- ⚠️ shader 地图层在位时整段跳过：整国染亮改由 shader 的 selected_faction
    --    uniform 完成（逐像素、无缝隙、无重影），省得多边形叠加再糊一层
    local focusId = self.selectedProvinceId
    if focusId and not self.shaderRenderer then
        local fprov = Provinces.byId[focusId]
        if fprov and fprov.polygon and #fprov.polygon >= 3 then
            -- 被点省所属势力（运行时归属，沙漠/无主为 nil）
            local focusOwner = nil
            local liveFocus = self.gameState and self.gameState.provinces[focusId]
            if liveFocus and not liveFocus.isWasteland then
                focusOwner = liveFocus.ownerId
            end

            -- 整国统一染亮：**所有目标省合成一条 path、只填一次**（2026-09-13 F0 修复）
            --
            -- 为什么不能逐省 fill+stroke：
            --   * 相邻两省的共享边会被两侧各省各描一遍 → 半透明描边 α45+α45 叠加成 α90，
            --     于是"一国**内部**的省界金线比国境线还浓"（用户反馈症状①）；
            --   * 描边本身有宽度（2 map px），叠加处外扩 → 边界上出现一圈"金晕"。
            -- 合成一条 path 后：共享边落在并集内部（不是 path 边界）→ 既不会有缝、
            --   也不会被叠加两次；整块区域只做一次 alpha 混合 → 浓度处处均匀。
            -- 国境线仍由下面的 _buildOwnerOutline（只画一次、屏幕恒定宽度）负责。
            -- 选择粒度（2026-09-18 用户拍板 · 两段式）：
            --   selectionLevel_ == "faction" → 整国染亮 + 国境描边（缩很远时点第一下 = 选国家）
            --   否则                          → 只亮被点的那一块（+ 该省金边）
            --   无主/沙漠省没有归属 → 永远按省选（整国染亮无从谈起）
            local byProvince = (self.selectionLevel_ ~= "faction") or not focusOwner

            if byProvince then
                -- 单省高亮：fill 与 stroke 各走一条独立 path（同"和平会议选省"的画法）
                nvgBeginPath(nvg)
                traceRingInto(nvg, self:_renderPoly(fprov), self:_renderHoles(fprov))
                nvgFillColor(nvg, nvgRGBA(HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B, 45))
                nvgFill(nvg)
                nvgBeginPath(nvg)
                traceRingInto(nvg, self:_renderPoly(fprov), self:_renderHoles(fprov))
                nvgStrokeColor(nvg, nvgRGBA(HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B, 235))
                nvgStrokeWidth(nvg, math.max(2.0, 2.0 / zoom))
                nvgStroke(nvg)
            else

            local anyHighlight = false
            nvgBeginPath(nvg)
            for vi = 1, visibleCount do
                local prov = visibleProvs[vi]
                if prov.polygon and #prov.polygon >= 3 then
                    local pid = prov.id
                    local isFocus = (pid == focusId)
                    local sameOwner = false
                    if focusOwner then
                        local live = self.gameState and self.gameState.provinces[pid]
                        if live and live.ownerId == focusOwner and not live.isWasteland then
                            sameOwner = true
                        end
                    end
                    if isFocus or sameOwner then
                        traceRingInto(nvg, self:_renderPoly(prov), self:_renderHoles(prov))
                        anyHighlight = true
                    end
                end
            end
            if anyHighlight then
                nvgFillColor(nvg, nvgRGBA(HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B, 45))
                nvgFill(nvg)
            end

            -- 国家外轮廓（2026-09-15：优先"边界图集贴图"= 黑线像素染色，零露边）
            if focusOwner then
                if self.outlineOwner_ ~= focusOwner or self.outlineFocus_ ~= focusId then
                    self.outlineOwner_ = focusOwner
                    self.outlineFocus_ = focusId
                    self.outlineAtlas_ = self:_buildOwnerOutlineAtlas(focusOwner)
                    if not self.outlineAtlas_ then
                        -- 图集不可用 → 回退：旧的"采样分段 + 双层描边"画线
                        self.outlineSegs_ = self:_buildOwnerOutline(focusOwner)
                    else
                        self.outlineSegs_ = nil
                    end
                end

                -- ① 图集贴图（首选）：把图集上"这条边"的区域贴到它的世界坐标上——
                --    贴的是黑线像素本身的染色，任何缩放都不露黑（详见 gen_border_atlas.py）
                local atlasList = self.outlineAtlas_
                if atlasList and #atlasList > 0 then
                    local handle = ImageCache.Get(self.borderAtlasData_.image)
                    if not handle or handle <= 0 then
                        ImageCache.Release(self.borderAtlasData_.image)   -- 清负缓存，下帧重试
                    else
                        local atlasW = self.borderAtlasData_.atlasW
                        local atlasH = self.borderAtlasData_.atlasH
                        for si = 1, #atlasList do
                            local e = atlasList[si]
                            local ax, ay = e[3], e[4]
                            local wx, wy, tw, th = e[5], e[6], e[7], e[8]
                            nvgBeginPath(nvg)
                            nvgRect(nvg, wx, wy, tw, th)
                            -- 图案局部偏移：让图集坐标 (ax, ay) 恰好落在世界坐标 (wx, wy)
                            -- ⚠️ 必须用 nvgFillPaint 传图案（只调 nvgImagePattern 不生效，
                            --    nvgFill 会沿用上一次的填充色 → 整块变色，踩过）
                            nvgFillPaint(nvg, nvgImagePattern(nvg, wx - ax, wy - ay,
                                atlasW, atlasH, 0, handle, 1.0))
                            nvgFill(nvg)
                        end
                    end
                elseif self.outlineSegs_ and #self.outlineSegs_ > 0 then
                    -- ② 回退：画线（旧方案；图集缺失时用；线宽规则同前——逻辑宽恒定+屏幕保底）
                    local segs = self.outlineSegs_
                    local sn = #segs
                    nvgLineCap(nvg, NVG_ROUND)
                    nvgLineJoin(nvg, NVG_ROUND)
                    nvgBeginPath(nvg)
                    for si = 1, sn do
                        local s = segs[si]
                        nvgMoveTo(nvg, s[1], s[2])
                        nvgLineTo(nvg, s[3], s[4])
                    end
                    nvgStrokeColor(nvg, nvgRGBA(148, 106, 10, 235))
                    nvgStrokeWidth(nvg, math.max(2.7, 2.7 / zoom))
                    nvgStroke(nvg)
                    nvgStrokeColor(nvg, nvgRGBA(HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B, 235))
                    nvgStrokeWidth(nvg, math.max(2.0, 2.0 / zoom))
                    nvgStroke(nvg)
                end
            end

            end   -- /byProvince：整国染亮分支（缩很小才走）
        end
    end

    -- =====================================================================
    -- 叠加层（逻辑坐标空间）：编辑高亮 / 调军目标 / 军队箭头
    -- =====================================================================

    -- 和平会议：已选省份金色高亮（点选割让目标，2026-09-02）
    if self.peaceSelectedIds and next(self.peaceSelectedIds) then
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            if self.peaceSelectedIds[prov.id] then
                nvgBeginPath(nvg)
                tracePolygon(nvg, self:_renderPoly(prov), self:_renderHoles(prov))
                nvgClosePath(nvg)
                nvgFillColor(nvg, nvgRGBA(255, 200, 90, 40))
                nvgFill(nvg)
                nvgBeginPath(nvg)
                tracePolygon(nvg, self:_renderPoly(prov), self:_renderHoles(prov))
                nvgClosePath(nvg)
                nvgStrokeColor(nvg, nvgRGBA(255, 200, 90, 235))
                nvgStrokeWidth(nvg, (HIGHLIGHT_WIDTH + 1.5) / zoom)
                nvgStroke(nvg)
            end
        end
    end

    -- 🔧 编辑工具：合并选中的区块高亮（青色脉冲描边 + 淡青填充）
    if MapEditor.mode then
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            if MapEditor.selected[prov.id] then
                local pulse = 0.5 + 0.5 * math.abs(math.sin(self.elapsedTime_ * 4.0))
                nvgBeginPath(nvg)
                tracePolygon(nvg, self:_renderPoly(prov), self:_renderHoles(prov))
                nvgClosePath(nvg)
                nvgFillColor(nvg, nvgRGBA(80, 220, 255, math.floor(30 + 40 * pulse)))
                nvgFill(nvg)
                nvgBeginPath(nvg)
                tracePolygon(nvg, self:_renderPoly(prov), self:_renderHoles(prov))
                nvgClosePath(nvg)
                nvgStrokeColor(nvg, nvgRGBA(80, 220, 255, math.floor(160 + 95 * pulse)))
                nvgStrokeWidth(nvg, (HIGHLIGHT_WIDTH + 1) / zoom)
                nvgStroke(nvg)
            end
        end
    end

    -- 军队移动目标：绿色脉冲描边（多个目标，用 NanoVG 叠加）
    if self.armyMoveMode then
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            if self.armyMoveTargets[prov.id] then
                local pulse = math.abs(math.sin(self.elapsedTime_ * 3.0))
                nvgBeginPath(nvg)
                tracePolygon(nvg, self:_renderPoly(prov), self:_renderHoles(prov))
                nvgClosePath(nvg)
                nvgStrokeColor(nvg, nvgRGBA(MOVE_TARGET_R, MOVE_TARGET_G, MOVE_TARGET_B,
                    math.floor(140 + 115 * pulse)))
                nvgStrokeWidth(nvg, (HIGHLIGHT_WIDTH + 1) / zoom)
                nvgStroke(nvg)
                nvgBeginPath(nvg)
                tracePolygon(nvg, self:_renderPoly(prov), self:_renderHoles(prov))
                nvgClosePath(nvg)
                nvgFillColor(nvg, nvgRGBA(MOVE_TARGET_R, MOVE_TARGET_G, MOVE_TARGET_B,
                    math.floor(30 + 25 * pulse)))
                nvgFill(nvg)
            end
        end
    end

    -- 5. Army movement arrows
    if self.gameState and self.gameState.armies then
        nvgFillColor(nvg, nvgRGBA(ARROW_COLOR_R, ARROW_COLOR_G, ARROW_COLOR_B, 220))
        nvgStrokeColor(nvg, nvgRGBA(ARROW_COLOR_R, ARROW_COLOR_G, ARROW_COLOR_B, 220))
        nvgStrokeWidth(nvg, ARROW_WIDTH / zoom)

        for _, army in pairs(self.gameState.armies) do
            local fromId = army.from or army.fromProvinceId
            local toId   = army.to or army.toProvinceId
            if fromId and toId then
                local fromProv = self:_findProvince(fromId)
                local toProv   = self:_findProvince(toId)
                if fromProv and toProv and fromProv.polygon and toProv.polygon then
                    local fx, fy = polygonCentroid(fromProv.polygon)
                    local tx, ty = polygonCentroid(toProv.polygon)
                    nvgBeginPath(nvg)
                    nvgMoveTo(nvg, fx, fy)
                    nvgLineTo(nvg, tx, ty)
                    nvgStroke(nvg)
                    drawArrowHead(nvg, fx, fy, tx, ty, ARROW_HEAD_SIZE / zoom)
                end
            end
        end
    end


    nvgRestore(nvg)

    -- =====================================================================
    -- Screen-space overlay pass (labels, capitals, minimap)
    -- =====================================================================
    nvgSave(nvg)
    nvgIntersectScissor(nvg, l.x, l.y, l.w, l.h)

    self:_renderArmyBadges(nvg, l, zoom, visibleProvs, visibleCount)

    -- 国名/省名标签最后画（2026-09-01：文字在最上层，不被军队旗面遮挡）
    self:_renderLabels(nvg, l, visibleProvs, visibleCount, zoom)

    -- 🔧 编辑工具：屏幕提示
    if MapEditor.mode then
        if self:_ensureFont(nvg) then
            local msg
            if MapEditor.mode == "select" then
                msg = "合并模式 [已选 " .. self:_countSelected() .. "] 点击选中/取消 → 小键盘3合并"
            elseif MapEditor.mode == "paint" then
                msg = "涂抹模式 [已选 " .. self:_countSelected() .. "] 按住拖动选中 → 小键盘3合并"
            end
            nvgFontFace(nvg, "sans")
            nvgFontSize(nvg, 18)
            nvgTextAlign(nvg, NVG_ALIGN_CENTER)
            nvgFillColor(nvg, nvgRGBA(255, 255, 200, 235))
            nvgText(nvg, l.x + l.w * 0.5, l.y + l.h * 0.16, msg)
            nvgTextAlign(nvg, NVG_ALIGN_LEFT)
        end
    end

    -- 🔧 编辑工具：按键帮助面板（小键盘6 开关）
    if self.showEditorHelp_ then
        if self:_ensureFont(nvg) then
            local pW = 300
            local rows = {
                { "小键盘 1", "删除选中区块（变海洋）" },
                { "小键盘 2", "合并选择模式（点击选中/取消）" },
                { "小键盘 3", "合并所有选中的区块" },
                { "小键盘 4", "涂抹模式（按住拖动选中）" },
                { "小键盘 5", "回退（撤销上一步操作）" },
                { "小键盘 6", "本帮助面板（再按关闭）" },
                { "S",        "保存编辑结果到地图" },
                { "ESC",      "退出编辑模式" },
            }
            local pH = 30 + #rows * 22 + 12
            local px = l.x + 14
            local py = l.y + 80
            nvgBeginPath(nvg)
            nvgRoundedRect(nvg, px, py, pW, pH, 8)
            nvgFillColor(nvg, nvgRGBA(20, 20, 30, 220))
            nvgFill(nvg)
            nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, 60))
            nvgStrokeWidth(nvg, 1)
            nvgStroke(nvg)

            nvgFontSize(nvg, 16)
            nvgFontFace(nvg, "sans")
            nvgTextAlign(nvg, NVG_ALIGN_LEFT)
            nvgFillColor(nvg, nvgRGBA(255, 220, 120, 240))
            nvgText(nvg, px + 12, py + 20, "地图编辑快捷键")

            local ty = py + 44
            for _, row in ipairs(rows) do
                nvgFontSize(nvg, 13)
                nvgFillColor(nvg, nvgRGBA(140, 220, 255, 235))
                nvgText(nvg, px + 12, ty, row[1])
                nvgFillColor(nvg, nvgRGBA(220, 220, 220, 200))
                nvgText(nvg, px + 90, ty, row[2])
                ty = ty + 22
            end
            nvgTextAlign(nvg, NVG_ALIGN_LEFT)
        end
    end

    nvgRestore(nvg)
end

------------------------------------------------------------
-- 屏幕空间军队标识（2026-09-01）：固定屏幕尺寸，放大不模糊
--   * 移动中军队：平滑插值位置
--   * 各省驻军：分级显示（zoom≥0.8 大兵力，≥1.2 全部）
--   * 交战中：攻守双方旗面+国名+数字 + 交叉剑 + 绿/红进度条
------------------------------------------------------------

---@param nvg table
---@param l table absolute layout {x, y, w, h}
---@param zoom number
---@param visibleProvs table array of visible land provinces
---@param visibleCount number
function MapWidget:_renderArmyBadges(nvg, l, zoom, visibleProvs, visibleCount)
    local gs = self.gameState
    if not gs then return end
    local pf = gs.playerFactionId

    -- 本帧所有军队牌/战斗行的屏幕矩形（每帧重建）→ 给标签层做避让用
    self._armyRects_ = {}
    -- 本帧军队旗标的**点击热区**（带 army 引用）→ OnPointerUp 命中用（2026-09-23 军队面板）
    self._armyHitRects_ = {}

    -- 画一个军队标识（屏幕坐标，固定尺寸：旗面 46×22，名字在旗面内，数字在外侧）
    ---@param factionId number|nil
    ---@param size number
    ---@param sx number 旗面左上角屏幕 x
    ---@param sy number 旗面左上角屏幕 y
    ---@param align string|nil "left"=数字在旗右侧（默认）；"right"=数字在旗左侧（战斗行守方用）
    ---@param align string|nil "left"=数字在旗右侧（默认）；"right"=数字在旗左侧（战斗行守方用）
    ---@param shape string|nil "army"=牙旗（军队，默认）| "war"=大纛（战斗/战争）
    ---@param scale number|nil 旗标缩放（小省用 <1，避免旗子溢出到邻省）
    local function drawBadge(factionId, size, sx, sy, align, shape, scale)
        local f = gs.factions and gs.factions[factionId]
        local color = f and f.color or { 150, 150, 150, 255 }
        local name = f and f.name or "?"
        shape = shape or "army"
        scale = scale or 1.0
        -- 旗面尺寸按素材比例：牙旗旗面 371:251（横）、大纛旗面 230:428（竖）
        local w, h
        if shape == "war" then
            h = 30; w = math.floor(h * 230 / 428 + 0.5)     -- 16
        else
            h = 28; w = math.floor(h * 371 / 251 + 0.5)     -- 41
        end
        -- 应用缩放（2026-09-29 用户："一个区块一个，可是这个样子不行"）
        --   小省的旗子会**溢出到邻省**，看起来像跑错地方了
        w = math.max(12, math.floor(w * scale + 0.5))
        h = math.max(10, math.floor(h * scale + 0.5))
        -- 记下这块牌子占的屏幕矩形 → 后面的省名/国名标签**避开它**
        --   （2026-09-17 用户："军队和国名重叠了"；EU4/HOI4 的做法：军队牌优先，
        --     省名遇到部队就让位，而不是两层糊在一起）
        self._armyRects_ = self._armyRects_ or {}
        self._armyRects_[#self._armyRects_ + 1] = {
            x = (align == "right") and (sx - 38) or sx,
            y = sy - 3,
            w = w + 38,
            h = h + 6,
        }
        -- 旗面：AI 纯白素材 → nvgImagePatternTinted 染势力色
        local clothH = ImageCache.Get("image/flags/" .. shape .. "_cloth.png")
        if clothH and clothH > 0 then
            nvgBeginPath(nvg)
            nvgRect(nvg, sx, sy, w, h)
            nvgFillPaint(nvg, nvgImagePatternTinted(nvg, sx, sy, w, h, 0, clothH,
                nvgRGBA(color[1], color[2], color[3], 245)))
            nvgFill(nvg)
        else
            -- 素材没就绪：退回纯色块（保证地图永远有军队标识）
            nvgBeginPath(nvg)
            nvgRoundedRect(nvg, sx, sy, w, h, 3)
            nvgFillColor(nvg, nvgRGBA(color[1], color[2], color[3], 240))
            nvgFill(nvg)
        end
        -- 边：玩家军队金色，其他白
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, sx, sy, w, h, 2)
        if factionId == pf then
            nvgStrokeColor(nvg, nvgRGBA(255, 200, 50, 255))
        else
            nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, 170))
        end
        nvgStrokeWidth(nvg, 1.2)
        nvgStroke(nvg)
        -- 国名（旗面内居中，1 字大、2 字小）+ 兵力数字（旗面外侧）
        if self:_ensureFont(nvg) then
            nvgFontFace(nvg, "sans")
            nvgTextAlign(nvg, NVG_ALIGN_CENTER)
            local nmLen = #name
            local nmFont = (nmLen >= 6) and 10 or 15      -- 汉字 3 字节：2 字 = 6 字节
            nmFont = math.max(8, math.floor(nmFont * scale + 0.5))   -- 随旗标一起缩
            nvgFontSize(nvg, nmFont)
            -- 描边：靛青投在旗面左上一层，保证亮色旗也读得清
            nvgFillColor(nvg, nvgRGBA(20, 16, 12, 160))
            nvgText(nvg, sx + w / 2 + 1, sy + h / 2 + 5, name)
            nvgFillColor(nvg, nvgRGBA(255, 255, 255, 245))
            nvgText(nvg, sx + w / 2, sy + h / 2 + 4, name)
            nvgFontSize(nvg, math.max(8, math.floor(10 * scale + 0.5)))
            nvgFillColor(nvg, nvgRGBA(255, 255, 255, 230))
            if align == "right" then
                nvgTextAlign(nvg, NVG_ALIGN_RIGHT)      -- 数字在旗左侧（右对齐到旗左边）
                nvgText(nvg, sx - 4, sy + h * 0.8, tostring(size))
            else
                nvgTextAlign(nvg, NVG_ALIGN_LEFT)
                nvgText(nvg, sx + w + 4, sy + h * 0.8, tostring(size))
            end
        end
    end

    -- 选中军队的**沿形金光**（2026-09-23 用户："不要动态的光源…也不要金框…
    --   沿着这个边加一个金光"）：
    --   做法 = 用**同一张旗面素材**放大、染金，垫在旗面**下层**。
    --   因为用的是旗子自己的图，露出来的金边**完全贴合旗形**——牙旗右侧的 V 形燕尾、
    --   大纛的竖幅都跟得上，不需要轮廓数据，也不会出现"矩形框套不住 V 口"的露馅。
    --   三层由外到内（外圈淡、内圈浓）= 静态光晕；**不做呼吸脉冲**。
    ---@param sx number 旗面左上角屏幕 x
    ---@param sy number 旗面左上角屏幕 y
    ---@param w number 旗面宽
    ---@param h number 旗面高
    ---@param shape string|nil "army"=牙旗（默认）| "war"=大纛
    local function drawSelectGlow(sx, sy, w, h, shape)
        local clothH = ImageCache.Get("image/flags/" .. (shape or "army") .. "_cloth.png")
        if not clothH or clothH <= 0 then return end
        local layers = { { 1.18, 88 }, { 1.10, 110 }, { 1.05, 130 } }
        for i = 1, #layers do
            local k, a = layers[i][1], layers[i][2]
            local gw, gh = w * k, h * k
            local gx, gy = sx - (gw - w) * 0.5, sy - (gh - h) * 0.5
            nvgBeginPath(nvg)
            nvgRect(nvg, gx, gy, gw, gh)
            nvgFillPaint(nvg, nvgImagePatternTinted(nvg, gx, gy, gw, gh, 0, clothH,
                nvgRGBA(255, 206, 92, a)))
            nvgFill(nvg)
        end
    end

    -- 屏幕坐标是否在视口附近（带边距，防止边缘标识突然消失）
    ---@param sx number
    ---@param sy number
    ---@return boolean
    local function onScreen(sx, sy)
        return sx > l.x - 80 and sx < l.x + l.w + 80
           and sy > l.y - 60 and sy < l.y + l.h + 60
    end

    -- 移动中军队：目标位置 + 帧间平滑插值（资源模式隐藏军队，只专注产出）
    self.armyRenderPos_ = self.armyRenderPos_ or {}
    local aliveArmies = {}
    -- 2026-09-23：军队旗标改为**所有视图模式**都显示（用户："这个军队他是可以点击的，这不就像
    --   历史时代3吗" —— AoH3 的坑正是"区域视图下移动中的军队点不到"）；拉太远仍隐藏。
    if zoom >= 0.5 then
        for _, army in pairs(gs.armies or {}) do
            local fromId = army.from or army.fromProvinceId
            local toId   = army.to or army.toProvinceId
            local total  = army.totalHours or 72
            local t = 0
            if total > 0 then
                t = math.min(1, math.max(0, (army.progress or 0) / total))
            end
            local fromProv = self:_findProvince(fromId)
            local toProv   = self:_findProvince(toId)
            -- 战争迷雾（2026-09-24）：别国军队只在"看得见的省"里才画。
            --   行军中的部队跨两个省 → 出发地或目的地任一可见就可见
            --   （否则会出现"军队走到迷雾里就凭空消失/又凭空出现"的观感）。
            --   自己的军队永远可见（GameState.isArmyVisible 内部已保证）。
            local armyVisible = true
            if gs.isArmyVisible then
                armyVisible = gs.isArmyVisible(army.factionId, fromId)
                    or gs.isArmyVisible(army.factionId, toId)
            end
            if armyVisible and fromProv and toProv and fromProv.polygon and toProv.polygon then
                local fx, fy = polygonCentroid(fromProv.polygon)
                local tx, ty = polygonCentroid(toProv.polygon)
                tx = fx + (tx - fx) * t
                ty = fy + (ty - fy) * t
                -- 平滑：向目标位置插值
                local prev = self.armyRenderPos_[army]
                local x, y
                if prev then
                    x = prev.x + (tx - prev.x) * 0.18
                    y = prev.y + (ty - prev.y) * 0.18
                else
                    x, y = tx, ty
                end
                self.armyRenderPos_[army] = { x = x, y = y }
                aliveArmies[army] = true
                local sx, sy = self:logicalToScreen(x, y)

                -- 行军路线（2026-09-27 用户："画出行军路线"）
                --   AoH3 / EU4 都有：点完目标能看到"它要去哪、走哪条路"。
                --   画法：从军队**当前旗子位置** → 剩余各站省中心的折线（屏幕坐标）。
                --   颜色用势力色的亮版，半透明虚线感（每段之间留空隙）。
                --   只在"还有后续站"时画（单跳且快到了就没必要）。
                if nvg and army.routePath and #army.routePath > 0 then
                    -- 固定用**高对比亮金**，不跟随势力色：
                    --   势力色可能和地块撞色（如齐国青绿画在青绿省上几乎看不见）。
                    local cr, cg, cb = 255, 214, 90
                    -- 折线节点：当前位置 + 剩余各站中心
                    local pts = { { sx, sy } }
                    for _, pid in ipairs(army.routePath) do
                        local rp = self:_findProvince(pid)
                        if rp and rp.polygon and #rp.polygon >= 3 then
                            local rx, ry = polygonCentroid(rp.polygon)
                            local psx, psy = self:logicalToScreen(rx, ry)
                            pts[#pts + 1] = { psx, psy }
                        end
                    end
                    if #pts >= 2 then
                        -- 先描一层深色底（保证在浅色地块上也看得见）
                        for pass = 1, 2 do
                            if pass == 1 then
                                nvgStrokeColor(nvg, nvgRGBA(15, 12, 6, 210))
                                nvgStrokeWidth(nvg, 7.0)
                            else
                                nvgStrokeColor(nvg, nvgRGBA(cr, cg, cb, 255))
                                nvgStrokeWidth(nvg, 3.5)
                            end
                            nvgBeginPath(nvg)
                            nvgMoveTo(nvg, pts[1][1], pts[1][2])
                            for i = 2, #pts do
                                nvgLineTo(nvg, pts[i][1], pts[i][2])
                            end
                            nvgStroke(nvg)
                        end
                        -- 终点画一个空心圈，标出"目的地"
                        local last = pts[#pts]
                        nvgBeginPath(nvg)
                        nvgCircle(nvg, last[1], last[2], 11)
                        nvgStrokeColor(nvg, nvgRGBA(15, 12, 6, 220))
                        nvgStrokeWidth(nvg, 6.0)
                        nvgStroke(nvg)
                        nvgBeginPath(nvg)
                        nvgCircle(nvg, last[1], last[2], 11)
                        nvgStrokeColor(nvg, nvgRGBA(cr, cg, cb, 255))
                        nvgStrokeWidth(nvg, 3.0)
                        nvgStroke(nvg)
                    end
                end

                if onScreen(sx, sy) then
                    -- 选中的那支：先画沿形金光，再画旗（旗面盖在光上）
                    if self.selectedArmy_ == army then
                        drawSelectGlow(sx - 23, sy - 11, 41, 28)   -- 牙旗实际旗面 41×28
                    end
                    drawBadge(army.factionId, army.size or 0, sx - 23, sy - 11)
                    -- 点击热区：**贴合旗面**（2026-09-23 用户："旗帜的大小比它的判定要小"）——
                    --   旗面 41×28 + 每边 4px 余量 = 49×36；行军中的军队也照记 → 随时能拦。
                    self._armyHitRects_[#self._armyHitRects_ + 1] =
                        { army = army, x = sx - 27, y = sy - 15, w = 49, h = 36 }
                end
            end
        end
    end
    -- 清理已到达/被移除军队的平滑位置
    for army, _ in pairs(self.armyRenderPos_) do
        if not aliveArmies[army] then
            self.armyRenderPos_[army] = nil
        end
    end

    -- =====================================================================
    -- 战斗行（2026-09-13 · 照《帝皇：罗马》）：[攻方旗+兵力] ⚔ [兵力+守方旗]
    --   * 屏幕坐标绘制 → 尺寸恒定（放大缩小不变）；**静止不晃**（原来那个摆动已删）
    --   * 与军队标识同一可见性规则：zoom < 0.5 直接不画（拉远自动消失）
    --   * 开战时进攻方军队已从 armies 移除（并入战斗），所以不会画出两个同国旗标
    -- =====================================================================
    -- 2026-09-23 起战斗行同样不限视图模式（与军队旗标口径一致）；拉太远仍隐藏
    if zoom >= 0.5 then
        local icon = self:_battleIconHandle()
        local cfg = GameConfig.Icons and GameConfig.Icons.battle
        local SW = ((type(cfg) == "table" and cfg.size) or 22)   -- 双剑图标边长（屏幕像素）
        local BADGE_W, BADGE_H = 46, 22
        local NUM_W = 34        -- 数字预留宽度（用于整行居中）
        local GAP = 6
        for pid, b in pairs(gs.battles or {}) do
            local prov = self:_findProvince(pid)
            -- 战争迷雾（2026-09-24）：战斗行同理 —— 看不见的省里在打什么，不该显示。
            --   例外：**自己参战**的战斗永远可见（否则自己的兵在打却看不见，没法指挥）。
            local battleVisible = true
            if gs.fogOfWar and gs.isProvinceVisible then
                local pf = gs.playerFactionId
                local mineFighting = pf and ((b.att and b.att.factionId == pf)
                                          or (b.def and b.def.factionId == pf))
                battleVisible = mineFighting or gs.isProvinceVisible(pid)
            end
            if battleVisible and prov and prov.polygon and #prov.polygon >= 3 then
                local cx, cy = polygonCentroid(prov.polygon)
                local sx, sy = self:logicalToScreen(cx, cy)
                if onScreen(sx, sy) then
                    local halfW = BADGE_W + NUM_W + GAP + SW / 2
                    local top = sy - BADGE_H / 2 - 16   -- 上移 16px：避开同在省中心的首都/驻军标记
                    -- 攻方（左）：旗 + 数字在右
                    --   旗型统一成**牙旗**（2026-09-25 用户："为什么交战之后双方的军队会变样子，
                    --   他们是变细了吗"）：原来战斗用大纛（230:428 竖长条，画出来 16×30），
                    --   跟平时行军的牙旗（371:251 横宽，41×28）形状完全不同 —— 一开战旗子
                    --   就"变细"，看着像换了支军队。现在统一用牙旗，只靠左右分居+中间双剑区分。
                    drawBadge(b.att and b.att.factionId, (b.att and b.att.size) or 0,
                        sx - halfW, top, "left", "army")
                    -- 守方（右）：数字在左 + 旗
                    drawBadge(b.def and b.def.factionId, (b.def and b.def.size) or 0,
                        sx + halfW - BADGE_W, top, "right", "army")
                    -- 中间双剑（静止、无旋转无缩放）
                    if icon and icon > 0 then
                        local iy = sy - 16                  -- 与旗标同一行中线（同样上移）
                        nvgBeginPath(nvg)
                        nvgRect(nvg, sx - SW * 0.5, iy - SW * 0.5, SW, SW)
                        nvgFillPaint(nvg, nvgImagePattern(nvg, sx - SW * 0.5, iy - SW * 0.5,
                            SW, SW, 0, icon, 1.0))
                        nvgFill(nvg)
                    end
                    -- 点击热区（2026-09-26 用户："交战中也可以看到他们的士气"）：
                    --   整行（左旗 + 双剑 + 右旗）都算，点开看双方兵力/士气。
                    --   以前战斗行**没有热区** → 交战中根本点不开，看不到士气。
                    self._armyHitRects_[#self._armyHitRects_ + 1] = {
                        battle = b, provId = pid,
                        x = sx - halfW - BADGE_W,
                        y = top - 6,
                        w = (halfW + BADGE_W) * 2,
                        h = BADGE_H + 12,
                    }
                end
            end
        end
    end

    -- 各省驻军（分级显示，避免拉远密密麻麻；资源模式隐藏军队）
    if (gs.mapMode == "political" or gs.mapMode == "region" or gs.mapMode == "war") and zoom >= 0.8 then
        -- ★ 小股驻军不显示（2026-09-18 用户："太破碎了"）：
        --   兵力现在集中在大点上（开局 1~5 个驻军省，照 P 社），地图上只该看到"军"——
        --   战后残留的 8 / 12 / 18 这种碎数字一律不画（点开省份面板仍能看真实驻军）。
        local minGarrison = 40
        if zoom < 1.2 then
            minGarrison = 80     -- 中缩放只显示大股
        end
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            local live = gs.provinces and gs.provinces[prov.id]
            local garrison = live and live.garrison or 0
            -- 战争迷雾（2026-09-24）：看不见的省不画驻军旗（自己的省永远可见，
            --   isArmyVisible 内部已保证）。否则迷雾等于白开 —— 别国兵力一目了然。
            local garVisible = true
            if gs.isArmyVisible and live then
                garVisible = gs.isArmyVisible(live.ownerId, prov.id)
            end
            -- 驻军 >0 才显示（沙漠/无主省兵力为 0）
            if garVisible and garrison > 0 and garrison >= minGarrison
                and prov.polygon and #prov.polygon >= 3 then
                local cx, cy = polygonCentroid(prov.polygon)
                local sx, sy = self:logicalToScreen(cx, cy)
                if onScreen(sx, sy) then
                    -- 旗标缩放（2026-09-29 用户："一个区块一个，可是这个样子不行"）：
                    --   省太小 → 41×28 的旗子会**溢出到邻省**，看着像跑错地方了。
                    --   做法：按省的屏幕包围盒算能放多大，超出就等比缩。
                    --   基准：旗面 41×28 + 右侧数字约 34px → 需要约 80×40 才放得下。
                    local pw, ph = self:provinceScreenSize(prov.polygon)
                    local scale = 1.0
                    if pw > 0 and ph > 0 then
                        -- 留 15% 余量，别贴着省界
                        local fitW = (pw * 0.85) / 80
                        local fitH = (ph * 0.85) / 40
                        scale = math.min(1.0, fitW, fitH)
                        -- 别缩太小（小于 0.45 就看不清国名了）
                        scale = math.max(0.45, scale)
                    end
                    -- 画在**正中心**（原来偏右下 sx-23/sy+8，小省时更容易出界）
                    local w = math.max(12, math.floor(41 * scale + 0.5))
                    local h = math.max(10, math.floor(28 * scale + 0.5))
                    local bx, by = sx - w / 2, sy - h / 2
                    -- 选中这处驻军 → 沿形金光（2026-09-23）
                    if self.selectedGarrison_ == prov.id then
                        drawSelectGlow(bx, by, w, h)   -- 跟着旗标一起缩
                    end
                    drawBadge(live.ownerId, garrison, bx, by, nil, nil, scale)
                    -- 点击热区贴旗（2026-09-23 用户："旗帜的大小比它的判定要小"）：
                    --   旗面 + 右侧兵力数字（约 34px，随缩放）+ 4px 余量
                    self._armyHitRects_[#self._armyHitRects_ + 1] = {
                        provId = prov.id,
                        x = bx - 4,
                        y = by - 4,
                        w = w + 38 * scale + 8,
                        h = h + 8,
                    }
                end
            end
        end
    end

    -- 资源模式：省上显示金/粮产出（2026-09-01）
    if gs.mapMode == "resource" and zoom >= 1.0 and self:_ensureFont(nvg) then
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            local live = gs.provinces and gs.provinces[prov.id]
            if live and not live.isWasteland and prov.polygon and #prov.polygon >= 3 then
                local cx, cy = polygonCentroid(prov.polygon)
                local sx, sy = self:logicalToScreen(cx, cy)
                if onScreen(sx, sy) then
                    nvgFontFace(nvg, "sans")
                    local fs = 12
                    nvgFontSize(nvg, fs)
                    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                    -- 资源标注改成「**深色名牌 + 金字**」（2026-09-16 用户："资源颜色跟沙漠/背景比还是看不清"）：
                    --   原来只有描边式托底，在米色/沙色省份上仍然糊；给一块实心底牌最稳，
                    --   也跟地图上其它"牌子"（国名旗标、省名牌）是同一套视觉语言。
                    local rlbl = string.format("金%d 粮%d",
                        math.floor(live.baseGold or 0), math.floor(live.baseFood or 0))
                    local tw = labelTextWidth(rlbl, fs)
                    local pw, ph = tw + 12, 18
                    local pcx, pcy = sx, sy - 16
                    nvgBeginPath(nvg)
                    nvgRoundedRect(nvg, pcx - pw * 0.5, pcy - ph * 0.5, pw, ph, 4)
                    nvgFillColor(nvg, nvgRGBA(24, 18, 10, 205))
                    nvgFill(nvg)
                    nvgStrokeColor(nvg, nvgRGBA(198, 162, 90, 175))
                    nvgStrokeWidth(nvg, 1.0)
                    nvgStroke(nvg)
                    nvgFillColor(nvg, nvgRGBA(255, 236, 176, 250))
                    nvgText(nvg, pcx, pcy, rlbl)
                end
            end
        end
    end
end

------------------------------------------------------------
-- Screen-space labels (province names / garrison / capitals)
------------------------------------------------------------

--- 屏幕矩形是否压到本帧任何军队牌/战斗行上
---   标签避让用：军队牌优先，标签让位（EU4 / HOI4 的 declutter 做法）
---@param x number 标签中心 x
---@param y number 标签左上 y
---@param w number
---@param h number
---@return boolean
function MapWidget:_labelHitsArmy(x, y, w, h)
    local rects = self._armyRects_
    if not rects or #rects == 0 then return false end
    local x0, x1 = x - w * 0.5, x + w * 0.5
    local y0, y1 = y, y + h
    for i = 1, #rects do
        local r = rects[i]
        if x1 > r.x and x0 < r.x + r.w and y1 > r.y and y0 < r.y + r.h then
            return true
        end
    end
    return false
end

---@param nvg table
---@param l table absolute layout {x, y, w, h}
---@param visibleProvs table array of visible land provinces
---@param visibleCount number
---@param zoom number
function MapWidget:_renderLabels(nvg, l, visibleProvs, visibleCount, zoom)
    local gs = self.gameState
    local mapMode = gs and gs.mapMode or "political"
    -- 2026-09-01 地图模式：省名只在"地区"模式显示；
    --   政治模式只显示国名（省名留给地区模式），war/ally 只显示国名
    -- 2026-09-16 用户："显示资源的同时为什么还会显示其他的" → 资源模式**不再叠省名**
    --   （资源模式 = 纯数据覆盖层：省名会跟"金X 粮Y"的名牌糊在一起）
    local showProvinceNames = (mapMode == "region")
    local focusedId = self.hoveredProvinceId or self.selectedProvinceId
    local showNames  = zoom >= LABEL_MIN_ZOOM
    local showFocused = zoom >= LABEL_FOCUS_MIN_ZOOM

    -- 捏合缩放时先不画省名（手机上明显省帧；松手后立刻恢复）
    if self.pinchActive_ then return end
    if (not showNames and not (showFocused and focusedId)) and zoom < CAPITAL_MIN_ZOOM then
        return
    end

    if not self:_ensureFont(nvg) then return end

    local minArea = (zoom >= 0.9) and LABEL_MIN_AREA_SMALL or LABEL_MIN_AREA
    local nameSize = math.max(11, math.min(16, zoom * 20))

    -- Province names + garrison numbers
    if showProvinceNames and (showNames or showFocused) then
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            -- 沙漠省不显示名字（外围荒地/废土无名）
            local liveProv = self.gameState and self.gameState.provinces[prov.id]
            if not prov.isOcean and not prov.isWasteland
               and not (liveProv and liveProv.isWasteland) and prov.center then
                local bb = spatialIdx:getAABB(prov.id)
                local area = 0
                if bb then
                    area = (bb.maxX - bb.minX) * (bb.maxY - bb.minY) * zoom * zoom
                end
                local isFocused = (prov.id == self.selectedProvinceId)
                -- 2026-09-01: 省名常显（AoH3 式）——大面积省平时直接显示，
                -- 选中省强制显示；省名下方的驻军数字已由"旗帜+数字"标识取代，不再重复绘制
                local wantName = showNames and (area >= minArea or isFocused)
                if wantName then
                    local cx, cy = prov.center[1], prov.center[2]
                    local sx, sy = self:logicalToScreen(cx, cy)
                    if sx >= l.x - 60 and sx <= l.x + l.w + 60
                       and sy >= l.y - 24 and sy <= l.y + l.h + 24 then
                        local size = isFocused and (nameSize + 2) or nameSize
                        -- 避让军队牌：有部队的地方省名让位（EU4/HOI4 declutter）
                        local tw = labelTextWidth(prov.name, size)
                        if not self:_labelHitsArmy(sx, sy, tw, size * 1.25) then
                            self:_drawLabel(nvg, sx, sy, prov.name, size, LABEL_INK)
                        end
                    end
                end
            end
        end
    end

    -- Capital markers + faction names（地区/资源模式不显示国名）
    if zoom >= CAPITAL_MIN_ZOOM and mapMode ~= "region" and mapMode ~= "resource" then
        self:_renderCapitals(nvg, l, zoom)
    end
end

--- 渲染各国国名（EU4 式三件套）：
---  1. 领土屏幕面积 >= FACTION_LABEL_MIN_AREA 才显示（拉远小国名消失）
---  2. 字号随缩放 12-18px
---  3. 标签碰撞避让：重叠时隐藏面积较小的国名（先画大的）
---@param nvg table
---@param l table absolute layout
---@param zoom number
function MapWidget:_renderCapitals(nvg, l, zoom)
    if zoom < FACTION_LABEL_MIN_ZOOM then return end
    if zoom >= FACTION_LABEL_MAX_ZOOM then return end   -- 放大 → 国名让位（见上方区间说明）
    local list = self:_buildTerritoryCenters()
    local gs = self.gameState

    -- 收集满足面积/视口条件的国名,按领土屏幕面积从大到小排序
    local items = {}
    for ci = 1, #list do
        local item = list[ci]
        local fid = item.factionId
        local live = gs and gs.factions and gs.factions[fid]
        if live and live.alive ~= false and item.bbox then
            local bw = (item.bbox.maxX - item.bbox.minX) * zoom
            local bh = (item.bbox.maxY - item.bbox.minY) * zoom
            local area = bw * bh
            if area >= FACTION_LABEL_MIN_AREA then
                local sx, sy = self:logicalToScreen(item.center[1], item.center[2])
                if sx >= l.x - 60 and sx <= l.x + l.w + 60
                   and sy >= l.y - 30 and sy <= l.y + l.h + 30 then
                    local r, g, b = self:_factionColorById(fid)
                    items[#items + 1] = {
                        fid = fid,
                        name = self:_factionName(fid),
                        sx = sx, sy = sy, area = area,
                        r = r, g = g, b = b,
                    }
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.area > b.area end)

    -- 字号随缩放：显示区间（0.20~0.80）内落在 16~18px（原来 10+zoom*2 在这区间恒为 14 = 用户说的"太小"）
    local size = math.max(FACTION_LABEL_SIZE_MIN,
                          math.min(FACTION_LABEL_SIZE_MAX, math.floor(11 + zoom * 9)))
    -- 碰撞避让（AABB）：重叠则跳过较小的（已按面积降序,后面的更小）
    local placed = {}
    for ci = 1, #items do
        local it = items[ci]
        local chars = utf8 and utf8.len(it.name) or #it.name
        local w = chars * size * 0.95 + 6
        local h = size * 1.25
        local collide = false
        for pi = 1, #placed do
            local p = placed[pi]
            if it.sx + w * 0.5 > p.x - p.w * 0.5 and it.sx - w * 0.5 < p.x + p.w * 0.5
               and it.sy + h * 0.5 > p.y - p.h * 0.5 and it.sy - h * 0.5 < p.y + p.h * 0.5 then
                collide = true
                break
            end
        end
        if not collide then
            -- 再避让军队牌：压到部队牌上的国名让位（EU4/HOI4 declutter；2026-09-17 用户："军队和国名重叠了"）
            if self:_labelHitsArmy(it.sx, it.sy - h * 0.5, w, h) then
                collide = true
            end
        end
        if not collide then
            -- 国名样式（2026-09-18 用户："有没有更粗的字体、颜色问题"）：
            --   原来是"提亮后的国色" —— 浅色国字压在同色系的国土上，对比度不够。
            --   改成 P 社通用做法：**暖白字 + 深墨描边**（描边同时带来加粗感），
            --   任何国土色/地形色上都能读清（详见 _drawLabel 的描边实现）。
            self:_drawLabel(nvg, it.sx, it.sy, it.name, size,
                FACTION_LABEL_FILL, FACTION_LABEL_STROKE, FACTION_LABEL_STROKE_W)
            placed[#placed + 1] = { x = it.sx, y = it.sy, w = w, h = h }
        end
    end
end

-- 按下后移动超过这个距离才算"拖地图"，否则抬手算"点击"
-- ⚠️ 2026-09-18：原来是 5px —— 手机上手指点一下常会移动十几像素，
--    于是点击被吞、用户反馈"放到很大也点不了地区"。鼠标/触摸统一放宽到 14px。
local DRAG_THRESHOLD = 14

--- 当前触点数量
---@return integer
local function countTouches(self)
    local n = 0
    for _ in pairs(self.touchPoints_) do n = n + 1 end
    return n
end

--- 出现第二个触点 → 进入捏合：记录锚点（两指中点 + 其对应该地图逻辑点，用当前 zoom）
function MapWidget:_maybeStartPinch()
    local tp = {}
    for _, p in pairs(self.touchPoints_) do tp[#tp + 1] = p end
    if #tp < 2 then return end
    local d = math.sqrt((tp[1].x - tp[2].x) ^ 2 + (tp[1].y - tp[2].y) ^ 2)
    if d <= 0 then return end
    local cx = (tp[1].x + tp[2].x) * 0.5
    local cy = (tp[1].y + tp[2].y) * 0.5
    local lx, ly = self:screenToLogical(cx, cy)
    self.pinchActive_        = true
    self.pinchStartDist_     = d
    self.pinchBaseZoom_      = self.zoom      -- 以当前（而非目标）缩放为基准，避免跳变
    self.pinchAnchorScreen_  = { x = cx, y = cy }
    self.pinchAnchorLogical_ = { x = lx, y = ly }
    self.pointerDown_        = false
    self.isDragging_         = false
end

--- 捏合中：比例按「起始距离」累计算目标缩放；锚点跟随两指中点（可同时平移）
function MapWidget:_updatePinch()
    local tp = {}
    for _, p in pairs(self.touchPoints_) do tp[#tp + 1] = p end
    if #tp < 2 or not self.pinchStartDist_ or self.pinchStartDist_ <= 0 then return end
    local d = math.sqrt((tp[1].x - tp[2].x) ^ 2 + (tp[1].y - tp[2].y) ^ 2)
    if d <= 0 then return end
    self.targetZoom = clamp(self.pinchBaseZoom_ * (d / self.pinchStartDist_), ZOOM_MIN, ZOOM_MAX)
    self.pinchAnchorScreen_ = { x = (tp[1].x + tp[2].x) * 0.5, y = (tp[1].y + tp[2].y) * 0.5 }
end

function MapWidget:OnPointerDown(event)
    Widget.OnPointerDown(self, event)

    -- 记录触点（多指捏合用）
    local pid = event.pointerId or 0
    self.touchPoints_[pid] = { x = event.x, y = event.y }
    self.dragFromTouch_ = (pid ~= 0)
    self.flingVX_, self.flingVY_ = 0, 0          -- 触摸即停惯性
    if countTouches(self) >= 2 then
        self:_maybeStartPinch()
    end

    if event.button == MOUSEB_LEFT then
        if MapEditor.mode then
            self.pointerDown_ = true
            self.isDragging_  = false
            if MapEditor.mode == "paint" then
                local provId = self:getProvinceAtPoint(event.x, event.y)
                if provId then
                    MapEditor.selected[provId] = true
                end
            end
            return
        end

        -- 涂抹模式：仅当按住起点落在"可涂省"上才进入涂抹（否则正常拖动地图）
        if self.paintEnabled then
            local provId = self:getProvinceAtPoint(event.x, event.y)
            local pickable = provId and self.isPaintable and self.isPaintable(provId)
            self.paintStartPickable_ = pickable == true
            self.paintDown_ = self.paintStartPickable_
            self.painted_   = false
        end

        self.pointerDown_ = true
        self.isDragging_  = false
        self.dragStartX_  = event.x
        self.dragStartY_  = event.y
        self.lastDragX_   = event.x
        self.lastDragY_   = event.y
    end
end

---@param event PointerEvent
function MapWidget:OnPointerMove(event)
    Widget.OnPointerMove(self, event)

    self.pointerX_ = event.x
    self.pointerY_ = event.y

    -- 更新触点位置
    local pid = event.pointerId or 0
    if self.touchPoints_[pid] then
        self.touchPoints_[pid].x = event.x
        self.touchPoints_[pid].y = event.y
    end

    -- 双指捏合：事件里只更新触点，缩放/锚点交给 Update 按帧统一计算
    -- （触摸事件一帧可能到多次，直接算会抖）
    if self.pinchActive_ then
        self:_updatePinch()
        self.pointerDown_ = false
        self.isDragging_ = false
        return
    end
    if countTouches(self) >= 2 then
        self:_maybeStartPinch()
        return
    end
    self.lastPinchDist_ = nil

    self.lastPinchDist_ = nil

    if self.pointerDown_ then
        if MapEditor.mode then
            if MapEditor.mode == "paint" then
                local provId = self:getProvinceAtPoint(event.x, event.y)
                if provId then
                    MapEditor.selected[provId] = true
                    if MapEditor.onChanged then
                        MapEditor.onChanged()
                    end
                end
            end
            return
        end

        -- 和平条约涂抹：按住拖动时连续刷选可索取省（仅加选，不拖相机）
        if self.paintDown_ then
            local provId = self:getProvinceAtPoint(event.x, event.y)
            if provId and self.onPaintProvince then
                self.onPaintProvince(provId, true)   -- forceSelect: 涂抹只加选
                self.painted_ = true
            end
            return
        end

        if not self.isDragging_ then
            local dx = event.x - self.dragStartX_
            local dy = event.y - self.dragStartY_
            if dx * dx + dy * dy > DRAG_THRESHOLD * DRAG_THRESHOLD then
                self.isDragging_ = true
            end
        end

        if self.isDragging_ then
            local dx = event.x - self.lastDragX_
            local dy = event.y - self.lastDragY_
            self.camX = self.camX - dx / self.zoom
            self.camY = self.camY - dy / self.zoom
            self.lastDragX_ = event.x
            self.lastDragY_ = event.y
        end
    else
        -- Not pressing → update hover（同步到 shader 高亮）
        -- ⚠️ 悬停染亮默认关闭（2026-08-31 用户要求）；如要开启，传入 props.hoverHighlight = true
        self.hoveredProvinceId = self:getProvinceAtPoint(event.x, event.y, false)
        if self.shaderRenderer and self.hoverHighlight then
            self.shaderRenderer:setHover(self.hoveredProvinceId)
        end
    end
end

---@param event PointerEvent
function MapWidget:OnPointerUp(event)
    Widget.OnPointerUp(self, event)

    -- ⚠️ UI 遮挡（2026-09-19 用户："我点那个上面不会透过这个框直接点到后边的领土"）：
    --   点击落在浮层面板上时直接吞掉，不选省（否则点弹窗会把后面的省份选中）
    if event.button == MOUSEB_LEFT and self.pointerBlockCheck
        and self.pointerBlockCheck(event.x, event.y) then
        self.pointerDown_ = false
        self.isDragging_ = false
        return
    end

    -- 清除触点；全部抬起 → 结束捏合（拖动速度保留给惯性滑行）
    local pid = event.pointerId or 0
    self.touchPoints_[pid] = nil
    if countTouches(self) == 0 then
        self.lastPinchDist_      = nil
        self.pinchActive_        = false
        self.pinchStartDist_     = nil
        self.pinchBaseZoom_      = nil
        self.pinchAnchorScreen_  = nil
        self.pinchAnchorLogical_ = nil
    end

    if event.button == MOUSEB_LEFT then
        if self.pointerDown_ and not self.isDragging_ then
            -- 军队点击**优先**（2026-09-23）：旗标热区命中 → 开军队面板，不再选省。
            --   * 行军中的军队（r.army）同样可点（AoH3 痛点：移动中点不到）
            --   * 省上的驻军旗（r.provId）也走这里：旗面常压到邻省，不能穿透去选省
            --   倒序：后画的牌子在上层，重叠时点到的是眼睛看到的那面旗。
            if (self.onArmyClick or self.onGarrisonClick or self.onBattleClick) and self._armyHitRects_ then
                for i = #self._armyHitRects_, 1, -1 do
                    local r = self._armyHitRects_[i]
                    if event.x >= r.x and event.x <= r.x + r.w
                        and event.y >= r.y and event.y <= r.y + r.h then
                        local handled = false
                        -- 交战中（2026-09-26）：点战斗行 → 看双方兵力/士气（只读）
                        if r.battle and self.onBattleClick then
                            handled = self.onBattleClick(r.battle, r.provId) ~= false
                        elseif r.provId and self.onGarrisonClick then
                            handled = self.onGarrisonClick(r.provId) ~= false
                        elseif r.army and self.onArmyClick then
                            self.onArmyClick(r.army)
                            handled = true
                        end
                        if handled then
                            -- 选中高亮（2026-09-23 用户："点之后可以发光来证明我们点击了它"）
                            self.selectedArmy_     = r.army
                            self.selectedGarrison_ = r.provId
                            self.pointerDown_ = false
                            self.isDragging_ = false
                            return
                        end
                        break
                    end
                end
            end
            -- 没点到军队 → 取消军队高亮（发光只属于"当前点中的那面旗"）
            self.selectedArmy_     = nil
            self.selectedGarrison_ = nil
            local provId = self:getProvinceAtPoint(event.x, event.y)

            if MapEditor.mode == "select" then
                MapEditor.toggleSelect(provId)
                if provId then
                    print("[MapEditor] " .. (MapEditor.selected[provId] and "选中" or "取消") ..
                          " 区块: " .. (Provinces.byId[provId] and Provinces.byId[provId].name or "?") ..
                          " (当前选中 " .. self:_countSelected() .. " 个)")
                end
                return
            elseif MapEditor.mode == "paint" then
                if provId then
                    MapEditor.selected[provId] = true
                    if MapEditor.onChanged then
                        MapEditor.onChanged()
                    end
                end
                return
            end

            -- 和平条约涂抹：
            --   按住拖动 → 已在 OnPointerMove 连续刷选（painted_=true），松开时不再触发单击
            --   单击（未拖）→ 交给当前涂抹模式处理
            if self.paintEnabled then
                if not self.painted_ then
                    if provId and self.onPaintProvince then
                        self.onPaintProvince(provId)
                    end
                end
            elseif self.armyMoveMode then
                -- 任意省模式（2026-09-26）：点哪走哪（内部 BFS 寻路）；
                --   旧模式只认 armyMoveTargets 里的相邻省。
                local valid = provId and (self.armyMoveAnyTarget or self.armyMoveTargets[provId])
                if valid and provId ~= self.armyMoveFrom then
                    if self.onArmyMoveTarget then
                        self.onArmyMoveTarget(self.armyMoveFrom, provId)
                    end
                end
                self:exitArmyMoveMode()
            else
                -- 选择粒度（2026-09-18 用户口径 · 两段式）：
                --   远视角第一下 = 选国家；已选该国的前提下再点内部 = 选那块省；近视角直接选省
                --   沙漠废土/海洋 → 清空选择（不选中、不高亮、不弹面板，2026-09-01 规则保留）
                local level = self:_resolveSelectionLevel(provId)
                local selId = level and provId or nil
                self:setSelectedProvince(selId, level)
                if self.onProvinceClick then
                    self.onProvinceClick(selId)
                end
            end
        end
        self.pointerDown_ = false
        self.isDragging_  = false
        self.paintDown_ = false   -- 涂抹结束复位
        if self.paintEnabled and self.onPaintEnd then self.onPaintEnd() end
    end
end

function MapWidget:OnMouseLeave()
    self.hoveredProvinceId = nil
    if self.shaderRenderer then
        self.shaderRenderer:setHover(nil)
    end
    self.pointerDown_ = false
    self.isDragging_  = false
    self.paintDown_ = false
    self.touchPoints_ = {}
    self.lastPinchDist_ = nil
end

function MapWidget:OnWheel(dx, dy)
    local factor = 1.0
    if dy > 0 then
        factor = ZOOM_FACTOR
    elseif dy < 0 then
        factor = 1.0 / ZOOM_FACTOR
    else
        return
    end

    local newTarget = clamp(self.targetZoom * factor, ZOOM_MIN, ZOOM_MAX)
    if newTarget == self.targetZoom then return end

    self.targetZoom = newTarget

    -- Zoom TOWARD the cursor
    local l = self:GetAbsoluteLayout()
    if l and self.pointerX_ and self.pointerY_ then
        local mx = self.pointerX_
        local my = self.pointerY_
        local halfW = l.w * 0.5
        local halfH = l.h * 0.5
        local lx = (mx - l.x - halfW) / self.zoom + self.camX
        local ly = (my - l.y - halfH) / self.zoom + self.camY
        self.camX = lx - (mx - l.x - halfW) / newTarget
        self.camY = ly - (my - l.y - halfH) / newTarget
    end

    self:_clampCamera()
end

------------------------------------------------------------
-- Army move mode API
------------------------------------------------------------

--- Enter army move mode: highlight neighbor provinces as valid targets.
---@param fromId number  source province id
---@param neighborIds table  array of valid target province ids
--- 进入"待选调军目标"状态（2026-09-26 改为 AoH3 式）
---   neighborIds 不传 = **任意省都可选**（点哪走哪，内部 BFS 寻路）；
---   传了 = 只允许这些省（旧行为，保留兼容）。
---@param fromId number 出发省
---@param neighborIds number[]|nil
function MapWidget:enterArmyMoveMode(fromId, neighborIds)
    self.armyMoveMode = true
    self.armyMoveFrom = fromId
    self.armyMoveTargets = {}
    self.armyMoveAnyTarget = (neighborIds == nil)   -- 任意省模式
    if neighborIds then
        for _, nid in ipairs(neighborIds) do
            self.armyMoveTargets[nid] = true
        end
    end
end

--- Exit army move mode and clear highlights.
function MapWidget:exitArmyMoveMode()
    self.armyMoveMode = false
    self.armyMoveFrom = nil
    self.armyMoveTargets = {}
    self.armyMoveAnyTarget = nil
end

--- Zoom in programmatically (e.g. from UI button).
function MapWidget:zoomIn()
    self.targetZoom = clamp(self.targetZoom * ZOOM_FACTOR * ZOOM_FACTOR, ZOOM_MIN, ZOOM_MAX)
    self:_clampCamera()
end

--- Zoom out programmatically (e.g. from UI button).
function MapWidget:zoomOut()
    self.targetZoom = clamp(self.targetZoom / (ZOOM_FACTOR * ZOOM_FACTOR), ZOOM_MIN, ZOOM_MAX)
    self:_clampCamera()
end

--- Get the current zoom level.
function MapWidget:getZoom()
    return self.zoom
end

--- Lookup a province record by id
function MapWidget:_findProvince(id)
    return Provinces.byId[id]
end

------------------------------------------------------------
-- Public factory
------------------------------------------------------------

--- Create the map renderer widget.
---@param gameState table  -- shared game state with .factions, .armies etc.
---@param shaderRenderer table|nil  -- MapShaderRenderer 实例（P 社 shader 地图画面）
---@param opts table|nil  -- 可选：{ viewMode = "political"|"terrain", onSyncViewport = function,
---                                    factionSelectOnly = boolean }
---   factionSelectOnly：只按国家选（选国页）—— 点谁都只整国高亮，永不钻到省
---@return table widget    -- a Widget instance (use as child of a Panel)
function MapRenderer.create(gameState, shaderRenderer, opts)
    opts = opts or {}
    local widget = MapWidget {
        gameState = gameState,
        shaderRenderer = shaderRenderer,
        viewMode = opts.viewMode,
        onSyncViewport = opts.onSyncViewport,
        factionSelectOnly = opts.factionSelectOnly,
        position  = "absolute",
        top       = 0,
        left      = 0,
        width     = "100%",
        height    = "100%",
    }
    -- 底图在这里就解码（首次解码较贵）：建地图 widget 时同步解一次，
    -- 之后走缓存；手机首次进入若底图还没下载完，靠渲染侧 0.5s 重试自动补上。
    widget:PreloadMapImage()
    return widget
end

return MapRenderer

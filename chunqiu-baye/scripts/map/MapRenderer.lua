------------------------------------------------------------------------
-- MapRenderer.lua — 地图 Widget（shader 渲染集成版 v3.1）
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
local MapShaderRenderer = require("map.MapShaderRenderer")

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

local INITIAL_CAM_X    = Geography.MAP_W * 0.5  -- 地图中心
local INITIAL_CAM_Y    = Geography.MAP_H * 0.5
local INITIAL_ZOOM     = MapPack.INITIAL_ZOOM or 0.20  -- 世界地图全图视角（视口≈地图宽）

-- Province label LOD thresholds (screen-space)
local LABEL_MIN_ZOOM          = 0.35  -- below this, no province names
local LABEL_FOCUS_MIN_ZOOM    = 0.20  -- hovered/selected always labeled above this
local LABEL_MIN_AREA          = 700   -- min on-screen px² for a name at medium zoom
local LABEL_MIN_AREA_SMALL    = 250   -- min on-screen px² at high zoom (small fragments)
local CAPITAL_MIN_ZOOM        = 0.30  -- capital markers appear above this zoom
local FACTION_LABEL_MIN_ZOOM  = 0.55  -- faction names appear above this zoom
local FACTION_LABEL_MIN_AREA = 700   -- 领土屏幕面积(px²)低于此值不显示国名(拉远小国消失)
local FACTION_LABEL_SIZE_MIN = 14
local FACTION_LABEL_SIZE_MAX = 20

-- Minimap removed (手机版：小地图占地方，删掉，2026-08-29)

-- 分块瓦片渲染：成品图切成 1024px 瓦片（assets/image/tiles/map_TX_TY.png），
-- 只渲染视口内可见的瓦片（为世界大地图铺路，2026-08-30）
local TILE_PX   = MapPack.TILE_PX or 1024
local TILE_L    = TILE_PX * (Geography.MAP_W / Geography.BITMAP_W)  -- 每块逻辑尺寸
local TILE_COLS = math.ceil(Geography.BITMAP_W / TILE_PX)
local TILE_ROWS = math.ceil(Geography.BITMAP_H / TILE_PX)

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
local UNOWNED_R, UNOWNED_G, UNOWNED_B = 210, 196, 158

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
local TERRAIN_VIEW_COLORS = {
    ["平原"] = {200, 194, 148},
    ["丘陵"] = {176, 172, 122},
    ["山地"] = {148, 126,  96},
    ["森林"] = {106, 150,  98},
    ["草原"] = {176, 186, 108},
    ["沿海"] = {198, 190, 152},
    ["沼泽"] = {126, 148, 112},
    ["盆地"] = {192, 170, 120},
    ["沙漠"] = {216, 198, 132},
    ["高原"] = {168, 152, 118},
    ["江湖"] = {112, 168, 178},
    ["荒漠"] = {222, 206, 148},
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
local function polygonCentroid(polygon)
    local cx, cy = 0, 0
    local n = #polygon
    if n == 0 then return 0, 0 end
    for i = 1, n do
        cx = cx + polygon[i][1]
        cy = cy + polygon[i][2]
    end
    return cx / n, cy / n
end

--- Trace a polygon path using NanoVG transform (no manual offset needed).
--- 支持洞（holes）：洞环以 NVG_HOLE winding 绘制，fill 时自动挖洞。
---@param nvg table
---@param polygon table
---@param holes table|nil
local function tracePolygon(nvg, polygon, holes)
    nvgBeginPath(nvg)
    if polygon and #polygon >= 3 then
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
---@param nvg table
---@param x number
---@param y number
---@param text string
---@param size number
---@param color table {r,g,b,a}
function MapWidget:_drawLabel(nvg, x, y, text, size, color)
    nvgFontFace(nvg, "sans")   -- 复用 UI 注册的 sans(MiSans)
    nvgFontSize(nvg, size)
    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(nvg, nvgRGBA(35, 26, 14, 205))
    nvgText(nvg, x + 1, y + 1, text, nil)
    nvgFillColor(nvg, nvgRGBA(color[1], color[2], color[3], color[4] or 255))
    nvgText(nvg, x, y, text, nil)
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

    -- Interaction state
    self.hoveredProvinceId  = nil
    self.selectedProvinceId = nil

    -- Army move mode: highlight valid target provinces
    self.armyMoveMode       = false
    self.armyMoveFrom       = nil
    self.armyMoveTargets    = {}          -- set of valid target province ids {[id]=true}
    self.elapsedTime_       = 0           -- for pulse animation

    -- Callback (set externally)
    self.onProvinceClick = props.onProvinceClick or nil
    self.onArmyMoveTarget = props.onArmyMoveTarget or nil

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

    -- 地图编辑工具（MapEditor 接入）
    self.editorPaintDown_ = false
    self.showEditorHelp_ = false

    -- 和平条约涂抹选省（历史时代3 式：按住左键滑动连续加选）
    self.peacePaintEnabled = false    -- 由和平条约窗口开启
    self.peacePaintDown_   = false    -- 当前是否按住涂抹
    self.peacePainted_     = false    -- 本次按住是否确实涂抹过省（用于区分单击 vs 涂抹）
    self.peacePaintStartPickable_ = false  -- 按住起点是否落在可索取省上（决定涂抹 vs 拖动地图）
    self.onPeacePaintProvince = props.onPeacePaintProvince or nil  -- 涂抹回调(强制选中)
    self.isPeacePickable = props.isPeacePickable or nil             -- 判断省是否可索取

    -- View mode: "political" (faction colours) or "terrain" (CK3-style)
    self.viewMode_ = props.viewMode or "political"

    -- Lazy caches
    self.fontId_   = nil
    self.terrCenters_ = nil
    -- 省份 ID 位图（P 社方案）：懒加载一次
    self.provinceBitmap_ = nil  --[[@as Image]]
    self.provinceBitmapAttempted_ = false

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

--- Clamp the camera so the viewport stays inside the world map.
function MapWidget:_clampCamera()
    local l = self:GetAbsoluteLayout()
    if not l or l.w <= 0 or l.h <= 0 then return end
    local minX = l.w * 0.5 / self.zoom
    local minY = l.h * 0.5 / self.zoom
    self.camX = clampCamAxis(self.camX, minX, Geography.MAP_W - minX)
    self.camY = clampCamAxis(self.camY, minY, Geography.MAP_H - minY)
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
function MapWidget:getProvinceAtPoint(sx, sy)
    local lx, ly = self:screenToLogical(sx, sy)
    local img = self:getProvinceBitmap()
    if not img then
        return nil
    end
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
        prestige = "威望", stability = "稳定",
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

function MapWidget:setSelectedProvince(id)
    self.selectedProvinceId = id
    if self.shaderRenderer then
        self.shaderRenderer:setSelected(id)
    end
end

--- 聚焦到省份：把镜头移动到省份中心并选中它
---@param provinceId number
---@param zoom number|nil
---@return boolean
function MapWidget:focusProvince(provinceId, zoom)
    local prov = provinceId and Provinces.byId[provinceId]
    if not prov or not prov.center then return false end

    self:setSelectedProvince(provinceId)
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
-- LOD: 按当前缩放返回渲染用多边形（仅编辑工具/叠加层使用）
------------------------------------------------------------
function MapWidget:_renderPoly(prov)
    local z = self.zoom
    if z >= 0.4 then
        return prov.polygon
    else
        return prov.lodLow or prov.polygon
    end
end

--- 与 _renderPoly 对应的洞环（zoom<0.4 用 lodLowHoles）
function MapWidget:_renderHoles(prov)
    local z = self.zoom
    if z >= 0.4 then
        return prov.holes
    else
        return prov.lodLowHoles or prov.holes
    end
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
    --   小键盘4 = 威望+100  小键盘5 = 稳定+100
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
        print("[Map] 视图切换: " .. (self.viewMode_ == "terrain" and "地形" or "政治"))
    end

    -- Smooth zoom interpolation
    local diff = self.targetZoom - self.zoom
    if math.abs(diff) > 0.001 then
        local t = 1.0 - math.exp(-ZOOM_LERP_SPEED * dt)
        self.zoom = self.zoom + diff * t
    elseif self.zoom ~= self.targetZoom then
        self.zoom = self.targetZoom
    end

    self:_clampCamera()

    -- =====================================================================
    -- 🔧 P 社 shader 层同步：相机 + LUT（势力/地形变化时重建）
    -- =====================================================================
    if self.shaderRenderer then

        local l = self:GetAbsoluteLayout()
        local viewW = (l and l.w > 0) and l.w or 800
        local viewH = (l and l.h > 0) and l.h or 600
        self.shaderRenderer:update(self.camX, self.camY, self.zoom, viewW, viewH)

        -- 显示色 LUT 为静态资源（create 时一次性绑定，见 MapShaderRenderer），
        -- 引擎对已渲染材质的纹理替换/SetData 不刷新，故此处不再重建。
        -- hover/选中高亮经 SetShaderParameter 传递，仍有效。
    end
end

------------------------------------------------------------
-- Render (NanoVG 叠加层，地图画面由 3D shader 层渲染)
------------------------------------------------------------

function MapWidget:Render(nvg)
    local l = self:GetAbsoluteLayout()
    if not l or l.w <= 0 or l.h <= 0 then
        return
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
    -- 底图：分块瓦片渲染（tiles/map_TX_TY.png，由 gen_tiles.py 切分）
    -- 只渲染当前视口可见的瓦片；地图数据可任意大（世界地图），
    -- 不可见瓦片不渲染也不加载，保证性能。
    -- （视口边界 vMinX/vMaxX/vMinY/vMaxY 已在函数开头计算）
    -- =====================================================================
    local txMin = math.max(0, math.floor(vMinX / TILE_L))
    local txMax = math.min(TILE_COLS - 1, math.floor(vMaxX / TILE_L))
    local tyMin = math.max(0, math.floor(vMinY / TILE_L))
    local tyMax = math.min(TILE_ROWS - 1, math.floor(vMaxY / TILE_L))

    for ty = tyMin, tyMax do
        for tx = txMin, txMax do
            local handle = ImageCache.Get(string.format(MapPack.TILE_PATH_PATTERN, tx, ty))
            if handle and handle > 0 then
                -- 相邻瓦片重叠 1px：消除 NanoVG 抗锯齿在瓦片接缝处留下的缝隙
                local ox = tx * TILE_L - 0.5
                local oy = ty * TILE_L - 0.5
                local ow = TILE_L + 1
                local oh = TILE_L + 1
                nvgBeginPath(nvg)
                nvgRect(nvg, ox, oy, ow, oh)
                nvgFillPaint(nvg, nvgImagePattern(nvg, ox, oy, ow, oh, 0, handle, 1.0))
                nvgFill(nvg)
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
            nvgBeginPath(nvg)
            tracePolygon(nvg, renderPoly, renderHoles)
            nvgClosePath(nvg)
            nvgFillColor(nvg, nvgRGBA(200, 162, 98, 235))
            nvgFill(nvg)
            -- 沙漠颗粒（深色小点阵,与省色/底图明显区分）
            -- 低缩放时跳过（外围沙漠省成百上千,逐点阵开销大）
            if zoom >= 1.0 then
                local bb = spatialIdx:getAABB(prov.id)
                if bb then
                    local step = 10
                    nvgFillColor(nvg, nvgRGBA(150, 105, 55, 170))
                    local gx0 = math.floor(bb.minX / step) * step
                    local gy0 = math.floor(bb.minY / step) * step
                    local gx = gx0
                    while gx <= bb.maxX do
                        local gy = gy0
                        while gy <= bb.maxY do
                            if Geography.isPointInPolygon(gx, gy, renderPoly) then
                                nvgBeginPath(nvg)
                                nvgCircle(nvg, gx, gy, 1.6)
                                nvgFill(nvg)
                            end
                            gy = gy + step
                        end
                        gx = gx + step
                    end
                end
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
    if (mapMode == "war" or mapMode == "ally") and self.gameState then
        local gs = self.gameState
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

        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            local live = gs.provinces and gs.provinces[prov.id]
            local owner = live and live.ownerId
            if owner and prov.polygon and #prov.polygon >= 3 then
                local cr, cg, cb, ca
                if mapMode == "war" then
                    if atWarAny(owner) then
                        cr, cg, cb, ca = 220, 60, 60, 150   -- 参战国红
                    end
                else
                    local atWarWithView = gs.relations[viewId] and gs.relations[viewId][owner]
                        and gs.relations[viewId][owner].atWar
                    if owner == viewId then
                        cr, cg, cb, ca = 60, 200, 90, 175    -- 视角国绿
                    elseif atWarWithView then
                        cr, cg, cb, ca = 220, 60, 60, 175    -- 敌方红
                    elseif shareEnemy(viewId, owner) then
                        cr, cg, cb, ca = 80, 140, 235, 175  -- 盟友蓝
                    else
                        cr, cg, cb, ca = 120, 120, 120, 150 -- 中立灰
                    end
                end
                if cr then
                    nvgBeginPath(nvg)
                    tracePolygon(nvg, self:_renderPoly(prov), self:_renderHoles(prov))
                    nvgClosePath(nvg)
                    nvgFillColor(nvg, nvgRGBA(cr, cg, cb, ca))
                    nvgFill(nvg)
                end
            end
        end
    end

    -- 占领标记（2026-09-01）：被占领(occupiedBy)省 → 白色斜线；
    --   被吞并(ownerId≠初始)省 → 运行时填充当前主色；
    --   战斗中的省也叠加斜线（AoH3 式被占标记）
    if self.gameState then
        local gs = self.gameState
        local battles = gs.battles or {}
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            local live = gs.provinces and gs.provinces[prov.id]
            if live and not live.isWasteland and prov.polygon and #prov.polygon >= 3 then
                local occupiedBy = live.occupiedBy
                local annexed = live._initOwner and live.ownerId and live.ownerId ~= live._initOwner
                local inBattle = battles[prov.id] ~= nil
                if occupiedBy or annexed or inBattle then
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
                    -- 白色斜线标记（省中心 X：被占领/交战）
                    if occupiedBy or inBattle then
                        local cx, cy = polygonCentroid(prov.polygon)
                        local sx, sy = self:logicalToScreen(cx, cy)
                        if sx >= l.x - 60 and sx <= l.x + l.w + 60
                           and sy >= l.y - 60 and sy <= l.y + l.h + 60 then
                            local len = 13 / zoom
                            nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, 215))
                            nvgStrokeWidth(nvg, 3 / zoom)
                            nvgBeginPath(nvg)
                            nvgMoveTo(nvg, cx - len, cy - len)
                            nvgLineTo(nvg, cx + len, cy + len)
                            nvgMoveTo(nvg, cx + len, cy - len)
                            nvgLineTo(nvg, cx - len, cy + len)
                            nvgStroke(nvg)
                        end
                    end
                end
            end
        end
    end

    -- 交互高亮：点击省 → 高亮整个国家领土（AoH/P社式，2026-09-01）
    --   * 被点省：金色粗描边 + 明显填充
    --   * 同势力其他省：金色描边 + 淡填充（显示该国全部区块）
    --   * 无主/海洋省：只高亮自身
    -- 悬停高亮仍保持关闭（2026-08-31 用户要求）
    local focusId = self.selectedProvinceId
    if focusId then
        local fprov = Provinces.byId[focusId]
        if fprov and fprov.polygon and #fprov.polygon >= 3 then
            -- 被点省所属势力（运行时归属，沙漠/无主为 nil）
            local focusOwner = nil
            local liveFocus = self.gameState and self.gameState.provinces[focusId]
            if liveFocus and not liveFocus.isWasteland then
                focusOwner = liveFocus.ownerId
            end

            for vi = 1, visibleCount do
                local prov = visibleProvs[vi]
                if prov.polygon and #prov.polygon >= 3 then
                    local pid = prov.id
                    if pid == focusId then
                        -- 被点省：最亮
                        local rp = self:_renderPoly(prov)
                        local rh = self:_renderHoles(prov)
                        nvgBeginPath(nvg)
                        tracePolygon(nvg, rp, rh)
                        nvgClosePath(nvg)
                        nvgFillColor(nvg, nvgRGBA(HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B, 45))
                        nvgFill(nvg)
                        nvgBeginPath(nvg)
                        tracePolygon(nvg, rp, rh)
                        nvgClosePath(nvg)
                        nvgStrokeColor(nvg, nvgRGBA(HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B, 235))
                        nvgStrokeWidth(nvg, 2.5 / zoom)
                        nvgStroke(nvg)
                    elseif focusOwner then
                        -- 同势力其他省：统一高亮
                        local live = self.gameState and self.gameState.provinces[pid]
                        if live and live.ownerId == focusOwner and not live.isWasteland then
                            local rp = self:_renderPoly(prov)
                            local rh = self:_renderHoles(prov)
                            nvgBeginPath(nvg)
                            tracePolygon(nvg, rp, rh)
                            nvgClosePath(nvg)
                            nvgFillColor(nvg, nvgRGBA(HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B, 20))
                            nvgFill(nvg)
                            nvgBeginPath(nvg)
                            tracePolygon(nvg, rp, rh)
                            nvgClosePath(nvg)
                            nvgStrokeColor(nvg, nvgRGBA(HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B, 200))
                            nvgStrokeWidth(nvg, 1.6 / zoom)
                            nvgStroke(nvg)
                        end
                    end
                end
            end
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

    -- 画一个军队标识（屏幕坐标，固定尺寸：旗面 46×22，名字在旗面内，数字在右侧）
    ---@param factionId number
    ---@param size number
    ---@param sx number 旗面左上角屏幕 x
    ---@param sy number 旗面左上角屏幕 y
    local function drawBadge(factionId, size, sx, sy)
        local f = gs.factions and gs.factions[factionId]
        local color = f and f.color or { 150, 150, 150, 255 }
        local name = f and f.name or "?"
        local w, h = 46, 22
        -- 旗面（国家色）
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, sx, sy, w, h, 3)
        nvgFillColor(nvg, nvgRGBA(color[1], color[2], color[3], 240))
        nvgFill(nvg)
        -- 边：玩家军队金色，其他白
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, sx, sy, w, h, 3)
        if factionId == pf then
            nvgStrokeColor(nvg, nvgRGBA(255, 200, 50, 255))
        else
            nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, 170))
        end
        nvgStrokeWidth(nvg, 1.2)
        nvgStroke(nvg)
        -- 国名（旗面内居中）+ 兵力数字（旗面右侧）
        if self:_ensureFont(nvg) then
            nvgFontFace(nvg, "sans")
            nvgTextAlign(nvg, NVG_ALIGN_CENTER)
            nvgFontSize(nvg, 12)
            nvgFillColor(nvg, nvgRGBA(255, 255, 255, 245))
            nvgText(nvg, sx + w / 2, sy + h / 2 + 4, name)
            nvgTextAlign(nvg, NVG_ALIGN_LEFT)
            nvgFontSize(nvg, 10)
            nvgFillColor(nvg, nvgRGBA(255, 255, 255, 230))
            nvgText(nvg, sx + w + 4, sy + h * 0.8, tostring(size))
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
    if gs.mapMode ~= "resource" and gs.mapMode ~= "ally" and zoom >= 0.5 then
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
            if fromProv and toProv and fromProv.polygon and toProv.polygon then
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
                if onScreen(sx, sy) then
                    drawBadge(army.factionId, army.size or 0, sx - 23, sy - 11)
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

    -- 各省驻军（分级显示，避免拉远密密麻麻；资源模式隐藏军队）
    if gs.mapMode ~= "resource" and gs.mapMode ~= "ally" and zoom >= 0.8 then
        local minGarrison = 0
        if zoom < 1.2 then
            minGarrison = 1000   -- 中缩放只显示大兵力
        end
        for vi = 1, visibleCount do
            local prov = visibleProvs[vi]
            local live = gs.provinces and gs.provinces[prov.id]
            local garrison = live and live.garrison or 0
            -- 驻军 >0 才显示（沙漠/无主省兵力为 0）
            if garrison > 0 and garrison >= minGarrison
                and prov.polygon and #prov.polygon >= 3 then
                local cx, cy = polygonCentroid(prov.polygon)
                local sx, sy = self:logicalToScreen(cx, cy)
                if onScreen(sx, sy) then
                    drawBadge(live.ownerId, garrison, sx - 23, sy + 8)
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
                    nvgFontSize(nvg, 12)
                    nvgTextAlign(nvg, NVG_ALIGN_CENTER)
                    nvgFillColor(nvg, nvgRGBA(255, 235, 170, 230))
                    nvgText(nvg, sx, sy - 16, string.format("金%d 粮%d",
                        math.floor(live.baseGold or 0), math.floor(live.baseFood or 0)))
                end
            end
        end
    end
end

------------------------------------------------------------
-- Screen-space labels (province names / garrison / capitals)
------------------------------------------------------------

---@param nvg table
---@param l table absolute layout {x, y, w, h}
---@param visibleProvs table array of visible land provinces
---@param visibleCount number
---@param zoom number
function MapWidget:_renderLabels(nvg, l, visibleProvs, visibleCount, zoom)
    local gs = self.gameState
    local mapMode = gs and gs.mapMode or "political"
    -- 2026-09-01 地图模式：省名只在"地区/资源"模式显示；
    --   政治模式只显示国名（省名留给地区模式），war/ally 只显示国名
    local showProvinceNames = (mapMode == "region" or mapMode == "resource")
    local focusedId = self.hoveredProvinceId or self.selectedProvinceId
    local showNames  = zoom >= LABEL_MIN_ZOOM
    local showFocused = zoom >= LABEL_FOCUS_MIN_ZOOM

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
                        self:_drawLabel(nvg, sx, sy, prov.name, size, LABEL_INK)
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

    local size = math.max(FACTION_LABEL_SIZE_MIN,
                          math.min(FACTION_LABEL_SIZE_MAX, math.floor(10 + zoom * 2)))
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
            self:_drawLabel(nvg, it.sx, it.sy, it.name, size,
                { lighten(it.r, 100), lighten(it.g, 100), lighten(it.b, 100), 255 })
            placed[#placed + 1] = { x = it.sx, y = it.sy, w = w, h = h }
        end
    end
end

local DRAG_THRESHOLD = 5  -- pixels moved before a press becomes a drag

function MapWidget:OnPointerDown(event)
    Widget.OnPointerDown(self, event)

    -- 记录触点（多指捏合用）
    local pid = event.pointerId or 0
    self.touchPoints_[pid] = { x = event.x, y = event.y }

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

        -- 和平条约涂抹选省：仅当按住起点落在可索取省上才进入涂抹（否则正常拖动地图）
        if self.peacePaintEnabled then
            local provId = self:getProvinceAtPoint(event.x, event.y)
            local pickable = provId and self.isPeacePickable and self.isPeacePickable(provId)
            self.peacePaintStartPickable_ = pickable == true
            self.peacePaintDown_ = self.peacePaintStartPickable_
            self.peacePainted_   = false
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

    -- 双指捏合缩放（手机版，替代已移除的 +/− 按钮）
    local tp = {}
    for _, p in pairs(self.touchPoints_) do
        tp[#tp + 1] = p
    end
    if #tp >= 2 then
        local d = math.sqrt((tp[1].x - tp[2].x) ^ 2 + (tp[1].y - tp[2].y) ^ 2)
        if self.lastPinchDist_ and self.lastPinchDist_ > 0 then
            local factor = d / self.lastPinchDist_
            if math.abs(factor - 1) > 0.02 then
                local newTarget = clamp(self.targetZoom * factor, ZOOM_MIN, ZOOM_MAX)
                if newTarget ~= self.targetZoom then
                    -- 以两指中心为锚点缩放
                    local cx = (tp[1].x + tp[2].x) * 0.5
                    local cy = (tp[1].y + tp[2].y) * 0.5
                    local lx, ly = self:screenToLogical(cx, cy)
                    self.targetZoom = newTarget
                    local l = self:GetAbsoluteLayout()
                    if l then
                        local halfW = l.w * 0.5
                        local halfH = l.h * 0.5
                        self.camX = lx - (cx - l.x - halfW) / newTarget
                        self.camY = ly - (cy - l.y - halfH) / newTarget
                    end
                end
            end
        end
        self.lastPinchDist_ = d
        -- 捏合期间不触发单指拖动/点击
        self.pointerDown_ = false
        self.isDragging_ = false
        return
    end
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
        if self.peacePaintDown_ then
            local provId = self:getProvinceAtPoint(event.x, event.y)
            if provId and self.onPeacePaintProvince then
                self.onPeacePaintProvince(provId, true)   -- forceSelect: 涂抹只加选
                self.peacePainted_ = true
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
        self.hoveredProvinceId = self:getProvinceAtPoint(event.x, event.y)
        if self.shaderRenderer then
            self.shaderRenderer:setHover(self.hoveredProvinceId)
        end
    end
end

---@param event PointerEvent
function MapWidget:OnPointerUp(event)
    Widget.OnPointerUp(self, event)

    -- 清除触点（多指捏合用）
    local pid = event.pointerId or 0
    self.touchPoints_[pid] = nil
    if next(self.touchPoints_) == nil then
        self.lastPinchDist_ = nil
    end

    if event.button == MOUSEB_LEFT then
        if self.pointerDown_ and not self.isDragging_ then
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
            --   按住拖动 → 已在 OnPointerMove 连续刷选（peacePainted_=true），松开时不再触发单击
            --   单击（未拖）→ 选中/取消该省
            if self.peacePaintEnabled then
                if not self.peacePainted_ then
                    if provId and self.onPeacePaintProvince then
                        self.onPeacePaintProvince(provId)
                    end
                end
            elseif self.armyMoveMode then
                if provId and self.armyMoveTargets[provId] then
                    if self.onArmyMoveTarget then
                        self.onArmyMoveTarget(self.armyMoveFrom, provId)
                    end
                end
                self:exitArmyMoveMode()
            else
                -- 沙漠废土不可点击（2026-09-01）：不选中、不高亮、不弹面板
                local live = self.gameState and self.gameState.provinces[provId]
                if provId and live and live.isWasteland then
                    self.selectedProvinceId = nil
                    if self.shaderRenderer then
                        self.shaderRenderer:setSelected(nil)
                    end
                    if self.onProvinceClick then
                        self.onProvinceClick(nil)
                    end
                else
                    self.selectedProvinceId = provId
                    if self.shaderRenderer then
                        self.shaderRenderer:setSelected(provId)
                    end
                    if self.onProvinceClick then
                        self.onProvinceClick(provId)
                    end
                end
            end
        end
        self.pointerDown_ = false
        self.isDragging_  = false
        self.peacePaintDown_ = false   -- 涂抹结束复位
    end
end

function MapWidget:OnMouseLeave()
    self.hoveredProvinceId = nil
    if self.shaderRenderer then
        self.shaderRenderer:setHover(nil)
    end
    self.pointerDown_ = false
    self.isDragging_  = false
    self.peacePaintDown_ = false
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
function MapWidget:enterArmyMoveMode(fromId, neighborIds)
    self.armyMoveMode = true
    self.armyMoveFrom = fromId
    self.armyMoveTargets = {}
    for _, nid in ipairs(neighborIds) do
        self.armyMoveTargets[nid] = true
    end
end

--- Exit army move mode and clear highlights.
function MapWidget:exitArmyMoveMode()
    self.armyMoveMode = false
    self.armyMoveFrom = nil
    self.armyMoveTargets = {}
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
---@return table widget    -- a Widget instance (use as child of a Panel)
function MapRenderer.create(gameState, shaderRenderer)
    return MapWidget {
        gameState = gameState,
        shaderRenderer = shaderRenderer,
        position  = "absolute",
        top       = 0,
        left      = 0,
        width     = "100%",
        height    = "100%",
    }
end

return MapRenderer

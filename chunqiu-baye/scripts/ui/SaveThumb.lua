-- ============================================================================
-- SaveThumb.lua — 存档缩略图（纯色块小地图）
--
-- 用途：存档页每行显示该存档的世界地图缩影（势力版图一眼可辨）。
-- 数据来源：存档里的 provinceStates（归属/占领/沙漠）+ factions（颜色）；
--          省份形状取当前地图包的静态多边形 —— 不依赖截图 API、不依赖游戏运行状态，
--          所以主菜单（还没进游戏）也能显示。
--
-- 三步流水线（前两步各只算一次，之后走缓存）：
--   ① ID 网格：把当前地图包全部省界多边形栅格化成 GRID_W×GRID_H 的
--      "每格属于哪个省"网格（扫描线填充；每个地图包缓存一份）
--   ② 颜色 LUT：省 id → 颜色（有主=势力色 / 被占领=占领方色 / 沙漠=沙色 / 无主=米色）
--   ③ 色块矩形：对网格做贪心矩形合并（相邻同色合成一块），按颜色分组 →
--      渲染时每种颜色只发一次 path/fill，整张缩略图通常只有几十个矩形
--
-- 用法：
--   local thumb = SaveThumb.build(saveData)         -- 传存档 data（可重复调用，按表缓存）
--   local w = SaveThumb.Widget { thumb = thumb, width = 88, height = 60 }
-- ============================================================================

local Widget = require("urhox-libs/UI/Core/Widget")

local SaveThumb = {}

------------------------------------------------------------------------
-- 网格尺寸 = 显示尺寸（1 格 1 像素）；88/60 ≈ 5640/3840（EU4 地图宽高比）
------------------------------------------------------------------------
local GRID_W, GRID_H = 88, 60
SaveThumb.GRID_W = GRID_W
SaveThumb.GRID_H = GRID_H

------------------------------------------------------------------------
-- 配色（与地图渲染保持一致）
------------------------------------------------------------------------
local SEA       = { 156, 182, 211 }   -- 海色
local UNOWNED   = { 210, 196, 158 }   -- 无主米色
local WASTELAND = { 200, 162,  98 }   -- 沙漠 / 化为沙漠的省

SaveThumb.SEA = SEA

local UNOWNED_KEY   = UNOWNED[1] * 65536 + UNOWNED[2] * 256 + UNOWNED[3]
local WASTELAND_KEY = WASTELAND[1] * 65536 + WASTELAND[2] * 256 + WASTELAND[3]

--- 颜色打包成单个整数（用于快速比较 / 分组）
---@param c table {r,g,b}
---@return number
local function packColor(c)
    return c[1] * 65536 + c[2] * 256 + c[3]
end

------------------------------------------------------------------------
-- 缓存
------------------------------------------------------------------------
---@type table<string, table>          地图包 id → { cells = number[], w, h }
local idGridCache = {}

---@type table<table, table>           存档 data 表 → 缩略图数据（弱键：随存档表回收）
local thumbCache = setmetatable({}, { __mode = "k" })

------------------------------------------------------------------------
-- ① 扫描线填充：把一个省的多边形写入 ID 网格
--    （网格坐标 = 地图坐标 × (GRID_W/MAP_W, GRID_H/MAP_H)）
------------------------------------------------------------------------
---@param cells number[] 网格（行优先，索引 = y*GRID_W + x + 1）
---@param poly number[][] 省界多边形（地图坐标）
---@param sx number
---@param sy number
---@param id number
local function fillPolygon(cells, poly, sx, sy, id)
    local n = #poly
    if n < 3 then return end

    -- 逐边求与各扫描线（格子中心 y+0.5）的交点 x，按行收集
    ---@type table<number, number[]>
    local xs = {}
    for i = 1, n do
        local a = poly[i]
        local b = poly[i % n + 1]
        local y1 = a[2] * sy
        local y2 = b[2] * sy
        if y1 ~= y2 then
            local x1 = a[1] * sx
            local x2 = b[1] * sx
            local lo, hi = y1, y2
            if lo > hi then lo, hi = hi, lo end
            local r0 = math.max(0, math.ceil(lo - 0.5))
            local r1 = math.min(GRID_H - 1, math.ceil(hi - 0.5) - 1)
            local inv = (x2 - x1) / (y2 - y1)
            for r = r0, r1 do
                local t = xs[r]
                if not t then
                    t = {}
                    xs[r] = t
                end
                t[#t + 1] = x1 + (r + 0.5 - y1) * inv
            end
        end
    end

    -- 每行交点排序后成对填充（偶奇规则）
    for r = 0, GRID_H - 1 do
        local t = xs[r]
        if t and #t >= 2 then
            table.sort(t)
            local base = r * GRID_W
            for k = 1, #t - 1, 2 do
                local c0 = math.max(0, math.ceil(t[k] - 0.5))
                local c1 = math.min(GRID_W - 1, math.ceil(t[k + 1] - 0.5) - 1)
                for c = c0, c1 do
                    cells[base + c + 1] = id
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- ① 构建（并缓存）当前地图包的 ID 网格
------------------------------------------------------------------------
---@return table|nil { cells = number[], w = number, h = number }
local function getIdGrid()
    local MapPack = require("data.MapPack")
    local key = MapPack.activeId
    local cached = idGridCache[key]
    if cached then return cached end

    local Provinces = require("data.Provinces")
    -- 资源型地图包（省份数据是 .dat，按需下载）可能还没下载完 → 这次先不做缩略图
    if not Provinces.data or #Provinces.data == 0 then
        return nil
    end

    local t0 = os.clock()
    local sx = GRID_W / MapPack.MAP_W
    local sy = GRID_H / MapPack.MAP_H

    ---@type number[]
    local cells = {}
    local n = 0
    for _, p in ipairs(Provinces.data) do
        if not p.isOcean and p.polygon then
            fillPolygon(cells, p.polygon, sx, sy, p.id)
            n = n + 1
        end
    end

    local grid = { cells = cells, w = GRID_W, h = GRID_H }
    idGridCache[key] = grid
    print(string.format("[SaveThumb] ID 网格已生成（%s：%d 省 → %d×%d，%.0f ms）",
        tostring(key), n, GRID_W, GRID_H, (os.clock() - t0) * 1000))
    return grid
end

------------------------------------------------------------------------
-- ② 颜色 LUT：存档 → 省 id → 打包颜色
------------------------------------------------------------------------
---@param data table 存档数据
---@return table<number, number> lut, table<number, table> colors
local function buildColorLut(data)
    local lut = {}
    local colors = {}
    for fid, f in pairs(data.factions or {}) do
        local c = f.color
        local id = f.id or tonumber(fid)
        if id and c then
            local k = packColor(c)
            lut[id] = k
            colors[k] = { c[1], c[2], c[3] }
        end
    end
    return lut, colors
end

------------------------------------------------------------------------
-- ③ 网格 + 颜色 → 贪心矩形合并 → 按颜色分组
------------------------------------------------------------------------
---@class SaveThumbGroup
---@field r number
---@field g number
---@field b number
---@field rects number[] 扁平的 x,y,w,h 序列

---@class SaveThumbData
---@field w number
---@field h number
---@field groups SaveThumbGroup[]
---@field nRects number

---@param grid table
---@param data table 存档数据
---@return SaveThumbData
local function buildRects(grid, data)
    local cells = grid.cells
    local gW, gH = grid.w, grid.h
    local lut, colors = buildColorLut(data)
    colors[UNOWNED_KEY] = { UNOWNED[1], UNOWNED[2], UNOWNED[3] }
    colors[WASTELAND_KEY] = { WASTELAND[1], WASTELAND[2], WASTELAND[3] }

    -- 省 id → 打包颜色（只遍历存档里的省，O(存档省数)）
    ---@type table<number, number>
    local pack = {}
    for pid, ps in pairs(data.provinceStates or {}) do
        local id = tonumber(pid)
        if id then
            if ps.isWasteland then
                pack[id] = WASTELAND_KEY
            else
                local oid = ps.occupiedBy or ps.ownerId
                pack[id] = (oid and lut[oid]) or UNOWNED_KEY
            end
        end
    end

    local used = {}
    ---@type table<number, number[]>
    local buckets = {}
    ---@type number[]
    local order = {}

    for y = 0, gH - 1 do
        local rowBase = y * gW
        for x = 0, gW - 1 do
            local idx = rowBase + x + 1
            local pid = cells[idx]
            if pid and not used[idx] then
                local k = pack[pid] or UNOWNED_KEY
                -- 向右延伸
                local w = 1
                while x + w < gW do
                    local i2 = rowBase + x + w + 1
                    local p2 = cells[i2]
                    if used[i2] or not p2 or (pack[p2] or UNOWNED_KEY) ~= k then break end
                    w = w + 1
                end
                -- 向下延伸（整行同色才加高）
                local h = 1
                local grow = true
                while grow and y + h < gH do
                    local base2 = (y + h) * gW
                    for i = 0, w - 1 do
                        local i3 = base2 + x + i + 1
                        local p3 = cells[i3]
                        if used[i3] or not p3 or (pack[p3] or UNOWNED_KEY) ~= k then
                            grow = false
                            break
                        end
                    end
                    if grow then h = h + 1 end
                end
                -- 标记占用
                for yy = 0, h - 1 do
                    local base3 = (y + yy) * gW
                    for xx = 0, w - 1 do
                        used[base3 + x + xx + 1] = true
                    end
                end
                -- 记入该颜色的矩形表
                local list = buckets[k]
                if not list then
                    list = {}
                    buckets[k] = list
                    order[#order + 1] = k
                end
                list[#list + 1] = x
                list[#list + 1] = y
                list[#list + 1] = w
                list[#list + 1] = h
            end
        end
    end

    local groups = {}
    local nRects = 0
    for _, k in ipairs(order) do
        local c = colors[k] or UNOWNED
        local rects = buckets[k]
        groups[#groups + 1] = { r = c[1], g = c[2], b = c[3], rects = rects }
        nRects = nRects + #rects / 4
    end
    return { w = gW, h = gH, groups = groups, nRects = nRects }
end

------------------------------------------------------------------------
-- 对外：构建缩略图数据（按存档 data 表缓存）
------------------------------------------------------------------------
---@param data table|nil 存档数据（SaveManager 读出的结构）
---@return SaveThumbData|nil
function SaveThumb.build(data)
    if type(data) ~= "table" or type(data.provinceStates) ~= "table" then
        return nil
    end
    local cached = thumbCache[data]
    if cached then return cached end

    local grid = getIdGrid()
    if not grid then return nil end

    local t0 = os.clock()
    local thumb = buildRects(grid, data)
    thumbCache[data] = thumb
    print(string.format("[SaveThumb] 缩略图已生成（%d 个色块，%.0f ms）",
        thumb.nRects or 0, (os.clock() - t0) * 1000))
    return thumb
end

-- ============================================================================
-- 渲染 widget：把缩略图数据画到自己的矩形范围内
-- ============================================================================

---@class SaveThumbWidget : Widget
---@field private thumb_ SaveThumbData|nil
local SaveThumbWidget = Widget:Extend("SaveThumbWidget")

---@param props WidgetProps
function SaveThumbWidget:Init(props)
    props = props or {}
    props.overflow = "hidden"
    props.backgroundColor = { 0, 0, 0, 0 }   -- 海色自己画（要盖满整格）
    self.thumb_ = props.thumb
    Widget.Init(self, props)
end

--- 换一张缩略图（同一个存档行复用 widget 时用）
---@param thumb SaveThumbData|nil
function SaveThumbWidget:SetThumb(thumb)
    self.thumb_ = thumb
end

---@param nvg NVGContextWrapper
function SaveThumbWidget:Render(nvg)
    local l = self:GetAbsoluteLayout()
    if not l or l.w <= 0 or l.h <= 0 then return end

    -- 海色底
    nvgBeginPath(nvg)
    nvgRect(nvg, l.x, l.y, l.w, l.h)
    nvgFillColor(nvg, nvgRGBA(SEA[1], SEA[2], SEA[3], 255))
    nvgFill(nvg)

    local t = self.thumb_
    if t then
        local sx = l.w / t.w
        local sy = l.h / t.h
        for _, g in ipairs(t.groups) do
            local rects = g.rects
            if rects and #rects > 0 then
                nvgBeginPath(nvg)
                for i = 1, #rects, 4 do
                    nvgRect(nvg,
                        l.x + rects[i] * sx, l.y + rects[i + 1] * sy,
                        rects[i + 2] * sx, rects[i + 3] * sy)
                end
                nvgFillColor(nvg, nvgRGBA(g.r, g.g, g.b, 255))
                nvgFill(nvg)
            end
        end
    end

    self:RenderBorder(nvg, { 120, 100, 66, 220 }, 1, 0)
end

function SaveThumbWidget:Destroy()
    self.thumb_ = nil
    Widget.Destroy(self)
end

SaveThumb.Widget = SaveThumbWidget

return SaveThumb

------------------------------------------------------------------------
-- SpatialIndex.lua
-- Grid-based spatial index for fast province hit detection.
-- Replaces O(n) linear scan with O(1) grid lookup + 1-3 precise tests.
------------------------------------------------------------------------

local SpatialIndex = {}
SpatialIndex.__index = SpatialIndex

--- Grid configuration
local GRID_COLS = 40
local GRID_ROWS = 25    -- 960/40=24, 600/25=24 → roughly square cells

------------------------------------------------------------------------
-- Constructor
------------------------------------------------------------------------

--- Create a new spatial index for the given map dimensions.
---@param mapW number  logical map width (e.g. 960)
---@param mapH number  logical map height (e.g. 600)
---@return table
function SpatialIndex.new(mapW, mapH)
    local self = setmetatable({}, SpatialIndex)
    self.mapW = mapW
    self.mapH = mapH
    self.cellW = mapW / GRID_COLS
    self.cellH = mapH / GRID_ROWS
    self.cols = GRID_COLS
    self.rows = GRID_ROWS

    -- grid[row][col] = { provinceId1, provinceId2, ... }
    self.grid = {}
    for r = 1, GRID_ROWS do
        self.grid[r] = {}
        for c = 1, GRID_COLS do
            self.grid[r][c] = {}
        end
    end

    -- AABB cache: aabb[provinceId] = {minX, minY, maxX, maxY}
    self.aabb = {}

    return self
end

------------------------------------------------------------------------
-- Build index from province data
------------------------------------------------------------------------

--- Compute AABB for a polygon.
---@param polygon table  array of {x, y}
---@return number minX, number minY, number maxX, number maxY
local function computeAABB(polygon)
    local minX, minY =  1e9,  1e9
    local maxX, maxY = -1e9, -1e9
    for i = 1, #polygon do
        local x, y = polygon[i][1], polygon[i][2]
        if x < minX then minX = x end
        if y < minY then minY = y end
        if x > maxX then maxX = x end
        if y > maxY then maxY = y end
    end
    return minX, minY, maxX, maxY
end

--- Register all provinces into the spatial index.
---@param provinces table  array of province records with .id, .polygon
function SpatialIndex:build(provinces)
    -- Clear grid
    for r = 1, self.rows do
        for c = 1, self.cols do
            self.grid[r][c] = {}
        end
    end
    self.aabb = {}

    for i = 1, #provinces do
        local prov = provinces[i]
        if prov.polygon and #prov.polygon >= 3 then
            local minX, minY, maxX, maxY = computeAABB(prov.polygon)
            self.aabb[prov.id] = { minX = minX, minY = minY, maxX = maxX, maxY = maxY }

            -- Determine which grid cells this AABB overlaps
            local c1 = math.max(1, math.floor(minX / self.cellW) + 1)
            local c2 = math.min(self.cols, math.floor(maxX / self.cellW) + 1)
            local r1 = math.max(1, math.floor(minY / self.cellH) + 1)
            local r2 = math.min(self.rows, math.floor(maxY / self.cellH) + 1)

            for r = r1, r2 do
                for c = c1, c2 do
                    local cell = self.grid[r][c]
                    cell[#cell + 1] = prov.id
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Query
------------------------------------------------------------------------

--- Get candidate province IDs that might contain the point (x, y).
--- Caller should do precise point-in-polygon on these candidates.
---@param x number  logical x coordinate
---@param y number  logical y coordinate
---@return table  array of province IDs (may be empty)
function SpatialIndex:query(x, y)
    local c = math.floor(x / self.cellW) + 1
    local r = math.floor(y / self.cellH) + 1

    if c < 1 or c > self.cols or r < 1 or r > self.rows then
        return {}
    end

    return self.grid[r][c]
end

------------------------------------------------------------------------
-- AABB access (for viewport culling)
------------------------------------------------------------------------

--- Get the AABB for a province.
---@param provinceId number
---@return table|nil  {minX, minY, maxX, maxY}
function SpatialIndex:getAABB(provinceId)
    return self.aabb[provinceId]
end

--- Check if a province's AABB intersects a viewport rectangle.
---@param provinceId number
---@param vMinX number  viewport left in logical coords
---@param vMinY number  viewport top in logical coords
---@param vMaxX number  viewport right in logical coords
---@param vMaxY number  viewport bottom in logical coords
---@return boolean
function SpatialIndex:isInViewport(provinceId, vMinX, vMinY, vMaxX, vMaxY)
    local bb = self.aabb[provinceId]
    if not bb then return false end
    return bb.maxX >= vMinX and bb.minX <= vMaxX
       and bb.maxY >= vMinY and bb.minY <= vMaxY
end

return SpatialIndex

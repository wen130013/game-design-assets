------------------------------------------------------------
-- MapEditor.lua
-- 地图编辑工具：删除区块 / 合并区块 / 涂抹选中
--
-- 小键盘：
--   KP1 删除当前选中的区块（变成海洋）
--   KP2 进入合并选择模式（点击选中/取消选中多个区块）
--   KP3 合并所有选中区块为一块（名字取第一个选中的）
--   KP4 涂抹模式（按住左键滑动，触及的区块全部选中）
--   S   保存编辑结果到 world_provinces.json（下次启动生效）
--   ESC 退出编辑模式
------------------------------------------------------------

local Provinces = require("data.Provinces")
local Geography = require("data.Geography")

local MapEditor = {}

-- Editor mode: nil / "select" / "paint"
MapEditor.mode = nil
MapEditor.selected = {}      -- {[id]=true}
MapEditor.onChanged = nil    -- 数据变化回调（刷新渲染）

-- 是否已有保存过（提示用）
MapEditor.savedOnce = false

-- 操作历史（撤销栈）：每项 {desc=描述, ids={受影响省份id}, snap={[id]=省份快照}}
MapEditor.history = {}
MapEditor.historyMax = 50    -- 最多保留 50 条历史

------------------------------------------------------------
-- 快照：深拷贝省份关键字段
------------------------------------------------------------
function MapEditor._snapshotProv(prov)
    local poly = {}
    for _, pt in ipairs(prov.polygon or {}) do
        poly[#poly + 1] = { pt[1], pt[2] }
    end
    local nb = {}
    for _, nid in ipairs(prov.neighbors or {}) do
        nb[#nb + 1] = nid
    end
    return {
        name = prov.name,
        polygon = poly,
        center = { prov.center[1], prov.center[2] },
        isOcean = prov.isOcean,
        neighbors = nb,
        terrain = prov.terrain,
        baseGold = prov.baseGold,
        baseFood = prov.baseFood,
        population = prov.population,
        ownerId = prov.ownerId,
        suppressOceanCover = prov.suppressOceanCover,
        editorFilled = prov.editorFilled,
        absorbedBy = prov.absorbedBy,
    }
end

function MapEditor._restoreProv(prov, snap)
    prov.name = snap.name
    prov.polygon = snap.polygon
    prov.center = snap.center
    prov.isOcean = snap.isOcean
    prov.neighbors = snap.neighbors
    prov.terrain = snap.terrain
    prov.baseGold = snap.baseGold
    prov.baseFood = snap.baseFood
    prov.population = snap.population
    prov.ownerId = snap.ownerId
    prov.suppressOceanCover = snap.suppressOceanCover
    prov.editorFilled = snap.editorFilled
    prov.absorbedBy = snap.absorbedBy
end

------------------------------------------------------------
-- 记录操作（修改数据前调用）：记录受影响省份的快照
------------------------------------------------------------
function MapEditor._recordStart(desc)
    return { desc = desc, ids = {}, snap = {} }
end

function MapEditor._recordProv(action, prov)
    if not prov or action.ids[prov.id] then
        return
    end
    action.ids[#action.ids + 1] = prov.id
    action.snap[prov.id] = MapEditor._snapshotProv(prov)
end

function MapEditor._recordCommit(action)
    -- 去重（可能重复记录）
    local seen = {}
    local ids = {}
    for _, id in ipairs(action.ids) do
        if not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    action.ids = ids
    MapEditor.history[#MapEditor.history + 1] = action
    if #MapEditor.history > MapEditor.historyMax then
        table.remove(MapEditor.history, 1)
    end
end

------------------------------------------------------------
-- 撤销最近一次操作
------------------------------------------------------------
function MapEditor.undo()
    local action = MapEditor.history[#MapEditor.history]
    if not action then
        return false
    end
    MapEditor.history[#MapEditor.history] = nil
    for _, id in ipairs(action.ids) do
        local prov = Provinces.byId[id]
        local snap = action.snap[id]
        if prov and snap then
            MapEditor._restoreProv(prov, snap)
        end
    end
    MapEditor.selected = {}
    if MapEditor.onChanged then
        MapEditor.onChanged()
    end
    return true
end

------------------------------------------------------------
-- 通用：多边形面积
------------------------------------------------------------
function MapEditor.polyArea(poly)
    local s = 0
    local n = #poly
    for i = 1, n do
        local x1, y1 = poly[i][1], poly[i][2]
        local x2, y2 = poly[(i % n) + 1][1], poly[(i % n) + 1][2]
        s = s + (x1 * y2 - x2 * y1)
    end
    return math.abs(s * 0.5)
end

------------------------------------------------------------
-- 删除区块：isOcean=true（渲染时自动跳过，显示为海）
------------------------------------------------------------
function MapEditor.deleteProvince(id)
    local prov = Provinces.byId[id]
    if not prov then
        return false
    end
    -- 记录历史：被删省 + 其所有邻居（邻居的 neighbors 也会被修改）
    local action = MapEditor._recordStart("删除 " .. (prov.name or "?"))
    MapEditor._recordProv(action, prov)
    for _, pid in ipairs(prov.neighbors or {}) do
        local nb = Provinces.byId[pid]
        if nb then
            MapEditor._recordProv(action, nb)
        end
    end

    prov.isOcean = true
    -- 从邻接关系移除
    for _, pid in ipairs(prov.neighbors or {}) do
        local nb = Provinces.byId[pid]
        if nb and nb.neighbors then
            for i = #nb.neighbors, 1, -1 do
                if nb.neighbors[i] == id then
                    table.remove(nb.neighbors, i)
                end
            end
        end
    end
    prov.neighbors = {}
    MapEditor.selected[id] = nil
    MapEditor._recordCommit(action)
    if MapEditor.onChanged then
        MapEditor.onChanged()
    end
    return true
end

------------------------------------------------------------
-- 多边形并集（栅格法，逻辑坐标 → 栅格 → 外轮廓 → 还原）
------------------------------------------------------------
function MapEditor.unionPolys(polys)
    if #polys == 1 then
        return polys[1]
    end
    -- 计算包围盒
    local minX, minY, maxX, maxY = 1e18, 1e18, -1e18, -1e18
    for _, poly in ipairs(polys) do
        for _, pt in ipairs(poly) do
            if pt[1] < minX then minX = pt[1] end
            if pt[1] > maxX then maxX = pt[1] end
            if pt[2] < minY then minY = pt[2] end
            if pt[2] > maxY then maxY = pt[2] end
        end
    end
    local bw = maxX - minX
    local bh = maxY - minY
    if bw < 1 or bh < 1 then
        return polys[1]
    end
    -- 栅格分辨率：约 1000 宽（高精度，接近 Python 端效果；合并一次约 1-2 秒）
    local GRID = 1000
    local gw = math.max(8, math.min(GRID, math.floor(GRID * bw / math.max(bw, bh))))
    local gh = math.max(8, math.floor(gw * bh / math.max(bw, 1)))
    -- 用表模拟位图
    local mask = {}
    local function setPx(gx, gy)
        if gx >= 0 and gy >= 0 and gx < gw and gy < gh then
            mask[gy * gw + gx + 1] = 1
        end
    end
    local function fillPoly(poly)
        -- 扫描线填充：对每一行，找多边形交点区间
        local rows = {}
        local n = #poly
        for i = 1, n do
            local x1, y1 = poly[i][1], poly[i][2]
            local x2, y2 = poly[(i % n) + 1][1], poly[(i % n) + 1][2]
            local gy1 = math.floor((y1 - minY) / bh * (gh - 1))
            local gy2 = math.floor((y2 - minY) / bh * (gh - 1))
            if gy1 > gy2 then
                gy1, gy2 = gy2, gy1
                x1, y1, x2, y2 = x2, y2, x1, y1
            end
            for gy = math.max(0, gy1), math.min(gh - 1, gy2) do
                local t = 0
                if gy2 ~= gy1 then
                    t = (gy - gy1) / (gy2 - gy1)
                end
                local ix = x1 + (x2 - x1) * t
                local gx = math.floor((ix - minX) / bw * (gw - 1))
                local row = rows[gy + 1]
                if not row then
                    row = {}
                    rows[gy + 1] = row
                end
                row[#row + 1] = gx
            end
        end
        -- 每行奇偶填充
        for gy = 0, gh - 1 do
            local row = rows[gy + 1]
            if row and #row >= 2 then
                table.sort(row)
                for i = 1, #row, 2 do
                    local x0 = row[i]
                    local x1v = row[i + 1] or x0
                    for gx = x0, x1v do
                        setPx(gx, gy)
                    end
                end
            end
        end
    end

    for _, poly in ipairs(polys) do
        fillPoly(poly)
    end

    -- 🔧 腐蚀 1 格：抵消栅格化边界外扩，让合并边界与邻居贴合不重叠
    -- 若区域太小（腐蚀后面积损失 > 25%），跳过腐蚀避免过度收缩
    local beforeCount = 0
    for k, v in pairs(mask) do
        if v == 1 then beforeCount = beforeCount + 1 end
    end
    local eroded = {}
    for y = 1, gh - 2 do
        for x = 1, gw - 2 do
            if mask[y * gw + x + 1]
               and mask[y * gw + (x - 1) + 1]
               and mask[y * gw + (x + 1) + 1]
               and mask[(y - 1) * gw + x + 1]
               and mask[(y + 1) * gw + x + 1] then
                eroded[#eroded + 1] = y * gw + x + 1
            end
        end
    end
    local afterCount = #eroded
    if beforeCount > 0 and afterCount >= beforeCount * 0.75 then
        -- 重建 mask（清空后按腐蚀结果填回）
        for k in pairs(mask) do
            mask[k] = nil
        end
        for _, idx in ipairs(eroded) do
            mask[idx] = 1
        end
    end

    -- 🔧 正确的外轮廓提取：Moore-Neighbor 边界追踪
    -- 沿填充区域边界走一圈，保持真实连接顺序（凹形状也不会出错）
    local DX = { 1, 1, 0, -1, -1, -1, 0, 1 }  -- 方向 0..7（顺时针）
    local DY = { 0, -1, -1, -1, 0, 1, 1, 1 }
    local boundary = {}
    do
        -- 找起点：最左上方的填充像素
        local sx, sy = nil, nil
        for y = 0, gh - 1 do
            for x = 0, gw - 1 do
                if mask[y * gw + x + 1] then
                    sx, sy = x, y
                    break
                end
            end
            if sx then break end
        end
        if sx then
            local cx, cy = sx, sy
            local backtrack = 4  -- 假设从左边进入起点
            local steps = 0
            while true do
                boundary[#boundary + 1] = { cx, cy }
                steps = steps + 1
                if steps > gw * gh * 2 then break end  -- 安全保护
                local found = false
                for step = 1, 8 do
                    local dir = (backtrack + step) % 8
                    local nx = cx + DX[dir + 1]
                    local ny = cy + DY[dir + 1]
                    if nx >= 0 and ny >= 0 and nx < gw and ny < gh
                       and mask[ny * gw + nx + 1] then
                        cx, cy = nx, ny
                        backtrack = (dir + 4) % 8
                        found = true
                        break
                    end
                end
                if not found then
                    break  -- 孤立像素
                end
                if cx == sx and cy == sy and #boundary > 2 then
                    break  -- 回到起点，完成
                end
            end
        end
    end
    if #boundary < 3 then
        return polys[1]
    end

    -- 还原逻辑坐标
    local result = {}
    for _, p in ipairs(boundary) do
        local px = minX + p[1] / (gw - 1) * bw
        local py = minY + p[2] / (gh - 1) * bh
        result[#result + 1] = { px, py }
    end
    -- 🔧 简化：Douglas-Peucker（保留显著拐角，去掉像素级锯齿）
    local function distToSegment(p, a, b)
        local abx, aby = b[1] - a[1], b[2] - a[2]
        local apx, apy = p[1] - a[1], p[2] - a[2]
        local len2 = abx * abx + aby * aby
        if len2 < 1e-12 then
            return math.sqrt(apx * apx + apy * apy)
        end
        local t = (apx * abx + apy * aby) / len2
        t = math.max(0, math.min(1, t))
        local qx, qy = a[1] + abx * t, a[2] + aby * t
        local dx, dy = p[1] - qx, p[2] - qy
        return math.sqrt(dx * dx + dy * dy)
    end

    local function dp(points, eps)
        local n = #points
        if n < 3 then
            return points
        end
        -- 找到离首尾直线最远的点
        local maxDist, maxIdx = 0, 0
        for i = 2, n - 1 do
            local d = distToSegment(points[i], points[1], points[n])
            if d > maxDist then
                maxDist, maxIdx = d, i
            end
        end
        if maxDist > eps then
            local left = dp({ table.unpack(points, 1, maxIdx) }, eps)
            local right = dp({ table.unpack(points, maxIdx, n) }, eps)
            local out = {}
            for i = 1, #left - 1 do
                out[#out + 1] = left[i]
            end
            for i = 1, #right do
                out[#out + 1] = right[i]
            end
            return out
        end
        return { points[1], points[n] }
    end

    -- 栅格每个格子的逻辑尺寸 ≈ bw/(gw-1)，eps 用 2 个格子去除锯齿
    local cellSize = bw / math.max(1, gw - 1)
    local eps = math.max(2.0, cellSize * 2.0)
    local simplified = dp(result, eps)
    -- 确保闭合多边形顶点足够
    if #simplified < 3 then
        return result
    end
    return simplified
end

------------------------------------------------------------
-- 合并选中区块
------------------------------------------------------------
function MapEditor.mergeSelected()
    local ids = {}
    for id, _ in pairs(MapEditor.selected) do
        ids[#ids + 1] = id
    end
    if #ids < 2 then
        return false
    end

    -- 记录历史：所有参与合并的省 + 它们的邻居
    local action = MapEditor._recordStart("合并 " .. #ids .. " 个区块")
    local affectedNbrs = {}
    for _, id in ipairs(ids) do
        local prov = Provinces.byId[id]
        if prov then
            MapEditor._recordProv(action, prov)
            for _, nid in ipairs(prov.neighbors or {}) do
                affectedNbrs[nid] = true
            end
        end
    end
    for nid, _ in pairs(affectedNbrs) do
        local nb = Provinces.byId[nid]
        if nb then
            MapEditor._recordProv(action, nb)
        end
    end

    -- 收集所有选中的多边形（跳过已海洋化的）
    local polys = {}
    local keepName = nil
    for _, id in ipairs(ids) do
        local prov = Provinces.byId[id]
        if prov and not prov.isOcean then
            polys[#polys + 1] = prov.polygon
            if not keepName then
                keepName = prov.name
            end
        end
    end
    if #polys < 2 then
        return false
    end

    local mergedPoly = MapEditor.unionPolys(polys)
    if not mergedPoly or #mergedPoly < 3 then
        return false
    end

    -- 第一个省份作为合并结果
    local target = Provinces.byId[ids[1]]
    if not target then
        return false
    end
    target.name = keepName or target.name
    target.polygon = mergedPoly
    target.center = Provinces.calcCenter(mergedPoly)
    target.isOcean = false
    target.suppressOceanCover = false  -- target 保持陆地显示
    target.editorFilled = true         -- 需要填色盖住内部被合并省的描边线

    -- 其余省份吸收进 target（海洋化但不盖海色，避免"合并后变海洋"）
    for i = 2, #ids do
        local prov = Provinces.byId[ids[i]]
        if prov and prov ~= target then
            prov.isOcean = true
            prov.neighbors = {}
            prov.suppressOceanCover = true  -- 被合并吸收，不显示海色覆盖
            prov.absorbedBy = target.id     -- 记录吸收者：点击命中它也算命中区块
        end
    end

    -- 重建邻接：删除的省从邻居列表移除，目标省合并所有邻居
    local allNbrs = {}
    for _, id in ipairs(ids) do
        local prov = Provinces.byId[id]
        if prov and prov.neighbors then
            for _, nid in ipairs(prov.neighbors) do
                if not MapEditor.selected[nid] and nid ~= target.id then
                    allNbrs[nid] = true
                end
            end
        end
    end
    target.neighbors = {}
    for nid, _ in pairs(allNbrs) do
        target.neighbors[#target.neighbors + 1] = nid
        local nb = Provinces.byId[nid]
        if nb and nb.neighbors then
            -- 把 target.id 加入邻居，移除已被海洋化的
            local found = false
            for i = #nb.neighbors, 1, -1 do
                if nb.neighbors[i] == target.id then
                    found = true
                elseif MapEditor.selected[nb.neighbors[i]] and nb.neighbors[i] ~= target.id then
                    table.remove(nb.neighbors, i)
                end
            end
            if not found then
                nb.neighbors[#nb.neighbors + 1] = target.id
            end
        end
    end
    table.sort(target.neighbors)

    MapEditor.selected = {}
    MapEditor._recordCommit(action)
    if MapEditor.onChanged then
        MapEditor.onChanged()
    end
    return true
end

------------------------------------------------------------
-- 模式控制
------------------------------------------------------------
function MapEditor.enterSelect()
    MapEditor.mode = "select"
end

function MapEditor.enterPaint()
    MapEditor.mode = "paint"
end

function MapEditor.exit()
    MapEditor.mode = nil
    MapEditor.selected = {}
end

------------------------------------------------------------
-- 选中/取消
------------------------------------------------------------
function MapEditor.toggleSelect(id)
    if not id then
        return
    end
    if MapEditor.selected[id] then
        MapEditor.selected[id] = nil
    else
        MapEditor.selected[id] = true
    end
    if MapEditor.onChanged then
        MapEditor.onChanged()
    end
end

------------------------------------------------------------
-- 保存编辑结果（写 world_provinces.json）
------------------------------------------------------------
function MapEditor.save()
    -- 收集有效省份（含 isOcean 删除区块：保留多边形和标记，
    -- 重新加载后海色覆盖层才能继续把删除区块画成海洋）
    local out = {}
    for _, p in ipairs(Provinces.data) do
        local poly = {}
        for _, pt in ipairs(p.polygon) do
            poly[#poly + 1] = { pt[1], pt[2] }
        end
        out[#out + 1] = {
            id = p.id,
            name = p.name,
            center = p.center,
            polygon = poly,
            terrain = p.terrain or "平原",
            baseGold = p.baseGold or 5,
            baseFood = p.baseFood or 8,
            population = p.population or 5000,
            ownerId = p.ownerId,
            isOcean = p.isOcean or false,
            editorFilled = p.editorFilled or nil,
            suppressOceanCover = p.suppressOceanCover or nil,
            absorbedBy = p.absorbedBy or nil,
            neighbors = p.neighbors or {},
        }
    end
    -- 重排 id
    for i, p in ipairs(out) do
        p.id = i
    end
    -- 写文件（沙箱相对路径，用 cjson 编码）
    local cjson = require("cjson")
    local f = File("world_provinces.json", FILE_WRITE)
    if f and not f:IsOpen() then
        f:Dispose()
        f = nil
    end
    if not f then
        print("[MapEditor] ❌ 无法打开 world_provinces.json")
        return false
    end
    f:WriteString(cjson.encode(out))
    f:Dispose()
    print("[MapEditor] ✅ 已保存 " .. #out .. " 个省份到 world_provinces.json")
    MapEditor.savedOnce = true
    return true
end

return MapEditor

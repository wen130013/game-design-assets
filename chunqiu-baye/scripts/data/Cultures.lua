-- ============================================================================
-- Cultures.lua — 文化表（"插座"第六块的数据层 · 2026-09-13）
--
-- 现状：省份早就有 `culture` 字段（`gameState.provinces[pid].culture`），
--       但**从来没有任何代码去读它**（全是"华夏"占位）→ 这个字段等于没有。
-- 本文件 + systems/CultureSystem.lua 把"读它"的逻辑补上：
--       异文化省份 → 稳定度惩罚（走修正器管道）→ 占比越高越难治理
--
-- 一条文化：
--   { id = "华夏", group = "中原", desc = "…" }
--   group 决定"容忍度"：同组文化惩罚减半，跨组全罚
--
-- 用法（模组/事件/编辑器）：
--   local Cultures = require("data.Cultures")
--   Cultures.add{ id = "百越", group = "南方" }
--   Cultures.setTolerance("华夏", "百越", 0.5)   -- 华夏对百越的容忍度（0~1）
-- ============================================================================

local Cultures = {}

---@class CultureDef
---@field id string 稳定 id（省份 culture 字段存的就是它）
---@field group string 文化组（同组互相容忍）
---@field desc string|nil

-- 文化表：**同时当数组和 map 用**（数组保顺序、map 按 id 查）——
-- 刻意不写严格类型标注：写成 map 会让 ipairs 报 param-type-mismatch
---@type table
Cultures.defs = {
    { id = "华夏", group = "中原", desc = "诸夏礼乐，天下正统" },
    { id = "东夷", group = "东方", desc = "齐东滨海之民" },
    { id = "荆蛮", group = "南方", desc = "楚地山泽之民" },
    { id = "西戎", group = "西方", desc = "秦陇以西的部族" },
    { id = "北狄", group = "北方", desc = "燕代以北的游牧部族" },
    { id = "百越", group = "南方", desc = "江南岭南的越人" },
}

--- 从数组形式建索引（defs 既是数组也是 map，两用）
for _, c in ipairs(Cultures.defs) do
    Cultures.defs[c.id] = c
end

--- 文化组之间的默认容忍度（0 = 完全不容忍 → 全额惩罚；1 = 完全容忍 → 无惩罚）
Cultures.GROUP_TOLERANCE = 0.5   -- 同组默认容忍度（惩罚减半）

--- 指定"甲文化对乙地区"的容忍度覆盖：key = "华夏>百越"
---@type table<string, number>
Cultures.tolerance_ = {}

--- 每个"异文化省份占比"对应的**每月稳定度惩罚上限**（占比 1.0 时的值）
Cultures.MAX_STABILITY_PENALTY = 4

-- ---------------------------------------------------------------------------
-- 查询
-- ---------------------------------------------------------------------------
--- 取文化定义（不存在则造一个"其他组"，保证任何省份都能算）
---@param id string|nil
---@return CultureDef
function Cultures.get(id)
    local c = id and Cultures.defs[id]
    if c and c.group then return c end
    return { id = id or "未开化", group = "其他" }
end

--- 某个"治理方文化"对"某文化"的容忍度（0~1）
---@param ownerCulture string
---@param culture string
---@return number
function Cultures.tolerance(ownerCulture, culture)
    local key = tostring(ownerCulture) .. ">" .. tostring(culture)
    local t = Cultures.tolerance_[key]
    if t ~= nil then return t end
    local a, b = Cultures.get(ownerCulture), Cultures.get(culture)
    if a.id == b.id then return 1.0 end
    if a.group == b.group then return Cultures.GROUP_TOLERANCE end
    return 0.0
end

--- 覆盖容忍度（0~1；1 = 视为自己人，不再惩罚）
---@param ownerCulture string
---@param culture string
---@param value number
function Cultures.setTolerance(ownerCulture, culture, value)
    Cultures.tolerance_[tostring(ownerCulture) .. ">" .. tostring(culture)] = value
end

--- 注册/覆盖一条文化
---@param def CultureDef
---@return CultureDef
function Cultures.add(def)
    assert(type(def) == "table" and def.id, "文化必须有 id")
    if not def.group then def.group = "其他" end
    if not Cultures.defs[def.id] then
        table.insert(Cultures.defs, def)
    end
    Cultures.defs[def.id] = def
    return def
end

return Cultures

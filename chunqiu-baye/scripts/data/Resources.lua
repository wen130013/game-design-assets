-- ============================================================================
-- Resources.lua — 资源注册表（"插座"第一块 · 2026-09-13）
--
-- 为什么要有它：
--   在这之前，游戏只认三个写死的数字：金（faction.gold）、粮（faction.food）、
--   兵（faction.armySize）。想加"积分 / 威望 / 人力 / 木材"这种新数值，
--   没有任何地方会去读它 —— 写了也不会涨、涨了也没人看。
--   本文件就是那个"插座"：注册一条 → 经济系统按月结算 → 顶栏自动显示。
--
-- 两种资源（分清楚，别混）：
--   * 绑定型 binding —— 值仍存在势力**已有的字段**上（gold/food/armySize/prestige）
--       注册表只描述"叫什么、什么颜色、顶栏排第几、显不显示"，**零破坏**：
--       全工程那些直接读写 f.gold 的老代码一行都不用改。
--   * 注册型 registered —— 新资源，值存在 `faction.resources[id]`
--       按 income 结算（数字 = 每月固定值；函数 = 自己算）
--
-- 一条资源长这样：
--   Resources.register{
--     id     = "jifen",          -- 稳定 id（存档里用它，永不变；中文名随便改）
--     name   = "积分",            -- 显示名
--     color  = { 226, 192, 120 }, -- 顶栏颜色
--     order  = 60,               -- 顶栏排序（小的在前）
--     show   = true,             -- 顶栏是否显示
--     init   = 0,                -- 新势力初始值
--     cap    = 999,              -- 上限（nil = 不封顶）
--     incomeDay   = 1,           -- **每天**收入：数字 或 function(gameState, faction) -> number
--     incomeMonth = 30,          -- **每月**收入（月末结算一次；和 incomeDay 可以只用一个）
--     effects = {                -- **影响谁**（2026-09-13 接上"修正器管道"）
--       { key = "recruit",   per = 100, mul  = 0.05 },  -- 每 100 点 → 征兵额度 +5%
--       { key = "goldIncome", per = 200, flat = 3 },    -- 每 200 点 → 金收入 +3（基础单位）
--     },
--     desc   = "每过一天 +1；每 100 点征兵 +5%",
--   }
--
--   effects 的键（key）就是修正器管道里的作用键，目前公式侧接了这些：
--     goldIncome（金收入，乘算） / foodIncome（粮收入，乘算） / recruit（每月征兵额度，乘算）
--
-- 用法（任何系统；将来模组也能这么调）：
--   local Resources = require("data.Resources")
--   Resources.add(faction, "jifen", 3)
--   local n = Resources.get(faction, "jifen")
--
-- ⚠️ 本期**不做"影响谁"**（比如"积分每 100 点征兵 +5%"）——那需要"修正器管道"
--    （让所有公式从管道取数值），是下一块插座，见 docs/制作清单.md A6。
-- ⚠️ 顶栏图标还没做（顶栏现在是纯文字），所以本表暂时没有 icon 字段；
--    等顶栏支持图标时再加（对应清单 D「图标生成」）。
-- ============================================================================

local Modifiers = require("systems.Modifiers")

local Resources = {}

---@class ResourceDef
---@field id string 稳定 id（存档用）
---@field name string 显示名
---@field color number[] {r,g,b}
---@field order number 顶栏排序（小的在前）
---@field show boolean 顶栏是否显示
---@field field string|nil 绑定型：值在势力哪个字段上（如 "gold"）
---@field computed string|nil 只读型：由外部算出来（如 "population"），不存值
---@field init number|nil 新势力初始值
---@field cap number|nil 上限（nil = 不封顶）
---@field incomeDay number|function|nil 每天收入：数字 或 function(gameState, faction) -> number
---@field incomeMonth number|function|nil 每月收入：同上
---@field effects table[]|nil 效果挂钩：这个资源能影响什么，见下方说明
---@field desc string|nil 说明（给编辑器/工具看）

---@type ResourceDef[]
Resources.defs_ = {}
---@type table<string, ResourceDef>
Resources.byId_ = {}

-- ---------------------------------------------------------------------------
-- 注册
-- ---------------------------------------------------------------------------
--- 注册一种资源（重复 id 会覆盖，方便调试时改定义）
---@param d ResourceDef
---@return ResourceDef
function Resources.register(d)
    assert(type(d) == "table" and d.id and d.name, "资源定义必须有 id 和 name")
    if d.color == nil then d.color = { 200, 200, 200 } end
    if d.order == nil then d.order = 100 end
    if d.show == nil then d.show = true end

    Resources.byId_[d.id] = d
    local list = Resources.defs_
    for i = 1, #list do
        if list[i].id == d.id then
            list[i] = d
            table.sort(list, function(a, b) return a.order < b.order end)
            Resources._registerEffects(d)
            return d
        end
    end
    list[#list + 1] = d
    table.sort(list, function(a, b) return a.order < b.order end)
    Resources._registerEffects(d)
    return d
end

-- ---------------------------------------------------------------------------
-- 效果挂钩 → 修正器管道（"影响谁"这一步）
--   资源表里写 effects = { { key="recruit", per=100, mul=0.05 }, … }
--   → 每 100 点资源，往管道的 recruit 键上加 5%（重算式：资源一变动，效果自动跟着变）
-- ---------------------------------------------------------------------------
---@param d ResourceDef
function Resources._registerEffects(d)
    Modifiers.unrule("resource:" .. d.id)      -- 先撤掉旧定义，避免重复叠加
    for _, e in ipairs(d.effects or {}) do
        local per  = e.per or 1
        local mul  = e.mul
        local flat = e.flat
        Modifiers.rule{
            scope  = e.scope or "faction",
            key    = e.key,
            op     = mul and "mul" or "flat",
            source = "resource:" .. d.id,
            value = function(_, ctx)
                local f = ctx and ctx.faction
                local v = f and Resources.get(f, d.id) or 0
                local tiers = math.floor((v or 0) / per)
                if mul then return tiers * mul end
                return tiers * (flat or 0)
            end,
        }
    end
end

--- 全部资源定义（已按 order 排序）
---@return ResourceDef[]
function Resources.list()
    return Resources.defs_
end

---@param id string
---@return ResourceDef|nil
function Resources.getDef(id)
    return Resources.byId_[id]
end

--- 这个定义是不是"绑定型"（值在势力已有字段上）
---@param d ResourceDef
---@return boolean
function Resources.isBinding(d)
    return d.field ~= nil
end

-- ---------------------------------------------------------------------------
-- 读写
-- ---------------------------------------------------------------------------
--- 给势力补齐注册型资源的初始值（新游戏 / 读老档都要调；只补缺的，不覆盖已有值）
---@param f table 势力
function Resources.ensure(f)
    if type(f) ~= "table" then return end
    if f.resources == nil then f.resources = {} end
    for _, d in ipairs(Resources.defs_) do
        if not Resources.isBinding(d) and d.computed == nil then
            if f.resources[d.id] == nil then
                f.resources[d.id] = d.init or 0
            end
        elseif Resources.isBinding(d) and d.init ~= nil then
            -- 老档可能缺字段（比如后来才加的威望）→ 补初始值
            if f[d.field] == nil then f[d.field] = d.init end
        end
    end
end

--- 取一个资源的值（绑定型取字段；注册型取 resources[id]；只读型返回 nil）
---@param f table 势力
---@param id string
---@return number|nil
function Resources.get(f, id)
    local d = Resources.byId_[id]
    if not d or not f then return nil end
    if Resources.isBinding(d) then return f[d.field] end
    if d.computed then return nil end
    return (f.resources or {})[id] or 0
end

--- 直接设值（注册型会被钳制到 [0, cap]；绑定型不钳制 —— 金/粮为负是游戏既有机制）
---@param f table 势力
---@param id string
---@param v number
function Resources.set(f, id, v)
    local d = Resources.byId_[id]
    if not d or not f then return end
    if Resources.isBinding(d) then
        f[d.field] = v
        return
    end
    if d.computed then return end
    if f.resources == nil then f.resources = {} end
    if v < 0 then v = 0 end
    if d.cap and v > d.cap then v = d.cap end
    f.resources[id] = v
end

--- 增减一个资源（走 set，所以注册型会自动带上限/下限）
---@param f table 势力
---@param id string
---@param amount number 可负
function Resources.add(f, id, amount)
    if not amount or amount == 0 then return end
    local cur = Resources.get(f, id)
    if cur == nil then return end
    Resources.set(f, id, cur + amount)
end

-- ---------------------------------------------------------------------------
-- 结算（由游戏的时间回调驱动：每天 / 每月各一次）
-- ---------------------------------------------------------------------------
--- 算一条资源的收入（数字直接用；函数则 pcall 包住，公式写错只跳过这一条）
---@param v number|function
---@return number|nil
local function incomeAmount(v, gameState, f)
    if type(v) == "function" then
        local ok, val = pcall(v, gameState, f)
        if not ok then
            print("[Resources] ⚠️ income 公式出错（已跳过）：" .. tostring(val))
            return nil
        end
        return val
    end
    return v
end

--- 结算所有"注册型且有 incomeDay"的资源（每天调一次）
---@param gameState table
---@param f table 势力
function Resources.settleDaily(gameState, f)
    for _, d in ipairs(Resources.defs_) do
        if not Resources.isBinding(d) and d.computed == nil and d.incomeDay ~= nil then
            local amount = incomeAmount(d.incomeDay, gameState, f)
            if amount and amount ~= 0 then Resources.add(f, d.id, amount) end
        end
    end
end

--- 结算所有"注册型且有 incomeMonth"的资源（每月调一次）
---@param gameState table
---@param f table 势力
function Resources.settleMonthly(gameState, f)
    for _, d in ipairs(Resources.defs_) do
        if not Resources.isBinding(d) and d.computed == nil and d.incomeMonth ~= nil then
            local amount = incomeAmount(d.incomeMonth, gameState, f)
            if amount and amount ~= 0 then Resources.add(f, d.id, amount) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 内置资源（= 顶栏现在显示的那几项；全部是绑定型，数据仍在原字段上）
--   order 决定顶栏从左到右的顺序；名字/颜色以此为准（GameUI 不再写死）
-- ---------------------------------------------------------------------------
Resources.register{
    id = "pop", name = "人口", computed = "population",
    color = { 120, 205, 195 }, order = 10, show = true,
    desc = "势力总人口：由省份人口汇总，只读（由 UI 侧缓存计算）",
}
Resources.register{
    id = "gold", name = "金钱", field = "gold",
    color = { 255, 200, 50 }, order = 20, show = true, init = 150,
    desc = "绑定 faction.gold（经济系统结算）",
}
Resources.register{
    id = "food", name = "粮草", field = "food",
    color = { 120, 200, 80 }, order = 30, show = true, init = 120,
    desc = "绑定 faction.food（经济系统结算；为负会掉士气+逃兵）",
}
Resources.register{
    id = "army", name = "兵力", field = "armySize",
    color = { 200, 100, 100 }, order = 40, show = true,
    desc = "绑定 faction.armySize（征兵/战斗结算）",
}
Resources.register{
    id = "prestige", name = "名声", field = "prestige",
    color = { 220, 180, 255 }, order = 50, show = true,
    desc = "绑定 faction.prestige（2026-09-17 显示名由「威望」改为「名声」）",
}

return Resources

-- ============================================================================
-- Modifiers.lua — 修正器管道（"插座"第二块 · 2026-09-13）
--
-- 解决什么问题：
--   在这之前，"加成"是各处各写各的：经济系统里手写 `× 君主文治 × 政策`，
--   军事系统里手写 `× 政策`。新东西（资源/事件/模组）想插一脚，就得去改那些公式代码。
--   本文件把所有加成收进**一条管道**，公式侧只调一次 apply 就行。
--
-- 顺序**写死**（清单 A8：模组只能给数值，不能改顺序）：
--       基础 → 加法(flat) → 百分比(mul) → 连乘(scale) → 取整 → 钳制
--
-- 三种运算：
--   flat  加法：+10            → 先把所有加法来源相加
--   mul   百分比：+0.05 = +5%  → 相加后一次性乘：×(1 + Σmul)
--   scale 连乘：×1.2           → 再逐个相乘（给"本来就是乘法"的老加成用，保持老数值不变）
--
-- 一条规则：
--   Modifiers.rule{
--     scope  = "faction",          -- 作用域（现在只有 "faction"）
--     key    = "goldIncome",       -- 作用键：**必须见下面的 Modifiers.KEYS 清单**
--     op     = "mul",              -- flat / mul / scale
--     value  = 0.05,               -- 数字，或 function(gameState, ctx) -> number
--     source = "resource:jifen",   -- 谁加的（排查用；也能按来源一键移除）
--   }
--
-- ⚠️ **key 不是随便起的**（2026-09-14 补）：把加成写进管道，还得**有人去读**才有用。
--    挂到一个没人读的 key = 广播到没人听的频道：代码能跑、但什么都不会发生。
--    所以下面列了一张 **Modifiers.KEYS 公共接口清单** —— 清单上的才是"有人在听的口"。
--    （注册时如果 key 不在清单里，会当场警告一句，省得作者白写）
--
-- 用法（公式侧）：
--   local v = Modifiers.apply(base, "faction", "goldIncome", { gameState = gs, faction = f })
--   -- apply = 取整版（征兵额度这种要整数）；applyFloat = 不取整（金/粮收入）
--
-- 谁往管道里注册：
--   * 老系统：经济/军事把它们原来的加成登记成 scale 规则（数值与以前完全一致）
--   * 资源：在资源表里写 `effects = { { key="recruit", per=100, mul=0.05 } }`
--     （每 100 点 → 征兵 +5%）→ 由 data/Resources.lua 自动登记成规则
--   * 将来的事件/模组：调 Modifiers.rule{...} 即可
-- ============================================================================

local Modifiers = {}

---@class ModifierRule
---@field scope string
---@field key string
---@field op string "flat" | "mul" | "scale"
---@field value number|function
---@field source string

-- ---------------------------------------------------------------------------
-- 公共接口清单（2026-09-14 · 洞 4）
--   「有哪些 key 是**真的有人在读**的」—— 清单上的才是能挂的口。
--   加新口的标准流程：① 在某个系统里真的加一行 `Modifiers.applyXXX(..., "新key", ...)`
--                      ② 再加进这张表 ③ 补一句说明
--   ⚠️ 只往表里加、却不加"读"的那一行 → 就是个空炮口，别这么干。
-- ---------------------------------------------------------------------------
---@type table<string, string>  key → 这个口是干什么的（也是给模组作者看的文档）
Modifiers.KEYS = {
    -- 经济（读的地方：EconomySystem 月结算）
    goldIncome     = "金钱收入倍率（scale）",
    foodIncome     = "粮草收入倍率（scale）",
    popGrowth      = "人口增长倍率（scale；调用方从 1.0 起算）",
    -- 军事（读的地方：MilitarySystem 战斗结算 / 征兵）
    recruit        = "征兵额度倍率（scale）",
    militaryPower  = "战力倍率（scale；攻守双方都读）",
    defensePower   = "防御倍率（scale；只有守方读）",
    -- 外交（读的地方：DiplomacySystem 改善关系）
    diploImprove   = "改善关系加成（**flat 加法**，调用方从 0 起算）",
    -- 文化（读的地方：CultureSystem 稳定度结算）
    stabilityDelta = "稳定度变化（**flat 加法**，调用方从 0 起算）",
    -- 名声（读的地方：EconomySystem 月结算；2026-09-17 由「威望」改名）
    prestigeDelta  = "名声月度变化（**flat 加法**，调用方从 0 起算）",
}

---@type ModifierRule[]
Modifiers.rules_ = {}
---@type table<string, {min:number|nil, max:number|nil}>  键 → 钳制范围
Modifiers.range_ = {}

-- ---------------------------------------------------------------------------
-- 注册 / 移除
-- ---------------------------------------------------------------------------
--- 注册一条修正规则（同一 source + key 会覆盖，方便调试时改定义）
---@param d ModifierRule
---@return ModifierRule
function Modifiers.rule(d)
    assert(type(d) == "table" and d.key, "修正规则必须有 key")
    if d.scope == nil then d.scope = "faction" end
    if d.op == nil then d.op = "mul" end
    if d.source == nil then d.source = "unknown" end
    assert(d.op == "flat" or d.op == "mul" or d.op == "scale",
        "op 只能是 flat / mul / scale，收到：" .. tostring(d.op))
    assert(d.value ~= nil, "修正规则必须有 value")

    -- 公共接口自检（2026-09-14 · 洞 4）：key 不在清单里 → **没人读它**，白挂
    --   只警告不拦截：本条可能按新的口来的（清单还没来得及更新），不该让整局跑不起来
    if Modifiers.KEYS and not Modifiers.KEYS[d.key] then
        print(string.format(
            "[Modifiers] ⚠️ key=%s 不在公共接口清单里 → 可能没有任何地方读它（source=%s）。"
            .. "清单见 Modifiers.KEYS；要加新口得先在某个系统里真的加一行 applyXXX",
            tostring(d.key), tostring(d.source)))
    end

    -- 去重：同 source + scope + key 视为同一条（改定义）
    local list = Modifiers.rules_
    for i = 1, #list do
        local r = list[i]
        if r.source == d.source and r.scope == d.scope and r.key == d.key then
            list[i] = d
            return d
        end
    end
    list[#list + 1] = d
    return d
end

--- 按来源移除（模组停用 / 资源取消注册时用）
---@param source string
---@return number removed
function Modifiers.unrule(source)
    local list = Modifiers.rules_
    local removed = 0
    for i = #list, 1, -1 do
        if list[i].source == source then
            table.remove(list, i)
            removed = removed + 1
        end
    end
    return removed
end

--- 清空（测试用）
function Modifiers.clear()
    Modifiers.rules_ = {}
    Modifiers.range_ = {}
end

--- 给某个键设钳制范围（钳制是管道的最后一步）
---@param scope string
---@param key string
---@param min number|nil
---@param max number|nil
function Modifiers.setRange(scope, key, min, max)
    Modifiers.range_[scope .. "." .. key] = { min = min, max = max }
end

--- 某个作用键上的全部规则（调试/界面展示用）
---@param scope string
---@param key string
---@return ModifierRule[]
function Modifiers.rulesFor(scope, key)
    local out = {}
    for _, r in ipairs(Modifiers.rules_) do
        if r.scope == scope and r.key == key then out[#out + 1] = r end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- 计算
-- ---------------------------------------------------------------------------
--- 取规则的值（函数则 pcall 包住：公式写错只跳过这一条，不拖垮整局）
---@param value number|function
---@return number
local function resolveValue(value, gameState, ctx)
    if type(value) == "function" then
        local ok, v = pcall(value, gameState, ctx)
        if not ok then
            print("[Modifiers] ⚠️ 修正公式出错（已跳过）：" .. tostring(v))
            return 0
        end
        return tonumber(v) or 0
    end
    return tonumber(value) or 0
end

--- 拆开算一遍（不取整、不钳制）——给调试/界面看"这条数值是怎么来的"
---@param base number
---@param scope string
---@param key string
---@param ctx table|nil { gameState = , faction = , province = }
---@return table { base, flat, mul, scale, value }
function Modifiers.breakdown(base, scope, key, ctx)
    local flat, mul, scale = 0, 0, 1
    local gs = ctx and ctx.gameState or nil
    for _, r in ipairs(Modifiers.rules_) do
        if r.scope == scope and r.key == key then
            local v = resolveValue(r.value, gs, ctx)
            if r.op == "flat" then
                flat = flat + v
            elseif r.op == "scale" then
                scale = scale * v
            else
                mul = mul + v
            end
        end
    end
    -- 顺序写死：基础 → 加法 → 百分比 → 连乘
    local v = base + flat
    v = v * (1 + mul)
    v = v * scale
    return { base = base, flat = flat, mul = mul, scale = scale, value = v }
end

--- 套管道（不取整）：金/粮这种可以是小数的用这个
---@param base number
---@param scope string
---@param key string
---@param ctx table|nil
---@return number
function Modifiers.applyFloat(base, scope, key, ctx)
    local b = Modifiers.breakdown(base, scope, key, ctx)
    ---@type number
    local v = b.value
    local r = Modifiers.range_[scope .. "." .. key]
    local lo = r and r.min or nil     -- 单独取出来：否则 LSP 认为 v 可能被赋成 nil
    local hi = r and r.max or nil
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

--- 套管道（取整）：征兵额度、兵力这种必须整数的用这个
---@param base number
---@param scope string
---@param key string
---@param ctx table|nil
---@return number
function Modifiers.apply(base, scope, key, ctx)
    return math.floor(Modifiers.applyFloat(base, scope, key, ctx))
end

return Modifiers

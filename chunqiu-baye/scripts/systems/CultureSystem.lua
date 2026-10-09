-- ============================================================================
-- CultureSystem.lua — 文化系统（"插座"第六块的逻辑层 · 2026-09-13）
--
-- 它回答的问题：**异文化的省份有多难管？**
--   * 势力自己的文化 = 首都所在省的文化（数据驱动，不给势力加新字段）
--   * 每块异文化省份按"容忍度"折算成不满 → 占比越高，每月稳定度掉得越多
--   * 容忍度可以调（Cultures.setTolerance / 事件 / 模组）→ 政策能改善统治
--
-- 落地方式：**走修正器管道**（键 `stabilityDelta`，加法），
--   所以它和"仁政/严法"那些政策加成是同一套结算，不会各算各的。
--
-- 每月还会检查一次"要不要叛乱"：不满最高的异文化省份超过阈值 → 触发钩子
--   `Hooks.fire("rebellion", { gameState, factionId, provinceId, culture })`
--   （本系统只负责"报信"；真让省脱离/出叛军，交给事件或模组接钩子去做）
-- ============================================================================

local Cultures = require("data.Cultures")
local Modifiers = require("systems.Modifiers")
local Hooks = require("systems.Hooks")

local CultureSystem = {}

--- 叛乱阈值：异文化占比 ≥ 这个值 且 稳定度 < 0 才考虑叛乱
CultureSystem.REBELLION_SHARE = 0.5

-- ---------------------------------------------------------------------------
-- 基础查询
-- ---------------------------------------------------------------------------
--- 势力自己的文化 = 首都省的文化（没有首都 → 麾下第一个省 → 默认"华夏"）
---@param gameState table
---@param f table 势力
---@return string
function CultureSystem.getFactionCulture(gameState, f)
    if not f then return "华夏" end
    local pid = f.capitalId or (f.provinces and f.provinces[1])
    local prov = pid and gameState.provinces[pid]
    if prov and prov.culture then return prov.culture end
    return "华夏"
end

--- 某势力的文化构成摘要
---@param gameState table
---@param f table 势力
---@return table { ownerCulture, total, foreign, penalty, byCulture = { culture → count } }
function CultureSystem.summary(gameState, f)
    local owner = CultureSystem.getFactionCulture(gameState, f)
    local total, foreign, penalty = 0, 0, 0
    local byCulture = {}
    for _, pid in ipairs(f.provinces or {}) do
        local prov = gameState.provinces[pid]
        if prov and not prov.isWasteland then
            total = total + 1
            local c = prov.culture or owner
            byCulture[c] = (byCulture[c] or 0) + 1
            if c ~= owner then
                foreign = foreign + 1
                penalty = penalty + (1.0 - Cultures.tolerance(owner, c))
            end
        end
    end
    local share = total > 0 and (penalty / total) or 0     -- 0~1：按容忍度加权的不满占比
    return {
        ownerCulture = owner,
        total = total,
        foreign = foreign,
        share = share,
        penalty = -math.floor(share * Cultures.MAX_STABILITY_PENALTY + 0.5),
        byCulture = byCulture,
    }
end

-- ---------------------------------------------------------------------------
-- 接进修正器管道：每月稳定度里的"文化惩罚"
--   （注册成规则后，EconomySystem 那边只要调一次 apply 就能拿到）
-- ---------------------------------------------------------------------------
Modifiers.rule{
    scope = "faction", key = "stabilityDelta", op = "flat", source = "culture:unrest",
    value = function(gameState, ctx)
        local f = ctx and ctx.faction
        if not gameState or not f then return 0 end
        return CultureSystem.summary(gameState, f).penalty
    end,
}

-- ---------------------------------------------------------------------------
-- 每月：叛乱检查
-- ---------------------------------------------------------------------------
---@param gameState table
function CultureSystem.processMonthly(gameState)
    for _, f in pairs(gameState.factions or {}) do
        if f.alive ~= false then
            local s = CultureSystem.summary(gameState, f)
            local stability = f.stability or 0
            if s.share >= CultureSystem.REBELLION_SHARE and stability < 0 then
                local target = CultureSystem.pickUnrestProvince(gameState, f, s.ownerCulture)
                if target then
                    local prov = gameState.provinces[target]
                    if gameState.addMessage and f.id == gameState.playerFactionId then
                        gameState.addMessage(string.format(
                            "%s民风不服（%s），%s有叛乱之兆！",
                            tostring(prov.culture), tostring(prov.name),
                            tostring(f.name)), "war", true)   -- notify：玩家自己的省份
                    end
                    Hooks.fire("rebellion", {
                        gameState = gameState,
                        factionId = f.id,
                        provinceId = target,
                        culture = prov.culture,
                    })
                end
            end
        end
    end
end

--- 找"最该出事"的那个异文化省（容忍度最低 = 最不服）
---@param gameState table
---@param f table
---@param ownerCulture string
---@return number|nil provinceId
function CultureSystem.pickUnrestProvince(gameState, f, ownerCulture)
    local bestId, bestScore = nil, -1
    for _, pid in ipairs(f.provinces or {}) do
        local prov = gameState.provinces[pid]
        if prov and not prov.isWasteland and prov.culture and prov.culture ~= ownerCulture then
            local score = 1.0 - Cultures.tolerance(ownerCulture, prov.culture)
            if score > bestScore then
                bestScore, bestId = score, pid
            end
        end
    end
    return bestId
end

return CultureSystem

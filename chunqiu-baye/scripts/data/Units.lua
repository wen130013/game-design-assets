-- ============================================================================
-- Units.lua — 兵种表（2026-09-19 第三版：数值整套照抄 CK3）
--
-- 用户口径："既然兵种是抄了他们（CK3），那么数值也必须得是这样才可以"。
-- 下面的 damage/toughness/pursuit/screen/size/maintenance 全部取自
-- CK3 的 Men-at-Arms 实际数值（2024-2026 版本口径）：
--
--   兵种        CK3 原型      伤害 坚韧 追击 掩护 每团人数 维护费  克制
--   轻步兵      散兵           50   35   59   16   100    0.4   重步兵
--   弓手        弓箭手         75   85   40   10   100    0.4   散兵
--   弩兵        弩兵           85   90   45   12   100    0.5   重步兵/骑兵
--   重步兵      重步兵        100  100   10   15   100    0.5   长枪兵
--   长枪兵      长枪兵         80   95   12   20   100    0.5   骑兵
--   轻骑兵      轻骑兵         90   60   50   10   100    0.5   弓兵
--   重骑兵      重骑兵        115   90   35   15    50    0.8   散兵/弓兵
--   战车兵      弓骑兵         70   65   55   10    50    0.5   重步兵/散兵
--   （CK3 没有战车；战车兵套用"弓骑兵"的数值——同属机动兵）
--
-- CK3 的两条撤退阶段公式（我们照用）：
--   追击：每点造成 0.17 伤害     → PURSUIT_DAMAGE
--   掩护：每点挡掉 0.33 伤害     → SCREEN_REDUCTION
--
-- 设计（沿用第二版）：
--   * 4 大类里先做 3 类（步/弓/骑），攻城类等围城机制
--   * 兵种**不分阶、并列可选**；科技解锁；国家有一个"主力兵种"
--   * 相克：攻击**对方主力兵种所属大类**时乘算
--   * 战力单位 = "每 size 人"（CK3 的团）→ 总战力 = (兵力 / size) × 属性
-- ============================================================================

local Units = {}

--- 追击/掩护的战斗系数（CK3 口径）
Units.PURSUIT_DAMAGE = 0.17    -- 每点追击造成的伤害
Units.SCREEN_REDUCTION = 0.33  -- 每点掩护挡掉的伤害

--- 大类（顺序 = UI 里的分组顺序）
Units.CATEGORIES = {
    { id = "inf", label = "步兵" },
    { id = "arc", label = "弓兵" },
    { id = "cav", label = "骑兵" },
}

---@class UnitDef
---@field id string 稳定 id（存档用它，别改）
---@field cat string 大类 id（inf/arc/cav）
---@field name string 显示名
---@field damage number 伤害（CK3 Damage）
---@field toughness number 坚韧（CK3 Toughness）
---@field pursuit number 追击（CK3 Pursuit；追杀溃兵）
---@field screen number 掩护（CK3 Screen；逃跑时减损）
---@field size number 每"团"人数（CK3：步兵 100 / 骑兵 50）
---@field maintenance number 维护费（每月每团金；CK3 口径）
---@field unlock string|nil 解锁科技 id（nil = 开局可用）
---@field vs table|nil 相克 { 大类id = 系数 }
---@field desc string|nil 一句话说明

---@type table
Units.defs = {
    -- ── 步兵 ──────────────────────────────────────────────
    { id = "light_inf", cat = "inf", name = "轻步兵", damage = 50, toughness = 35,
      pursuit = 59, screen = 16, size = 100, maintenance = 0.4,
      unlock = nil, vs = { inf = 1.15 }, desc = "轻装散兵：便宜、追击极强（追杀溃兵一绝）" },
    { id = "heavy_inf", cat = "inf", name = "重步兵", damage = 100, toughness = 100,
      pursuit = 10, screen = 15, size = 100, maintenance = 0.5,
      unlock = "bronze", vs = { inf = 1.15 }, desc = "重装步卒：攻守俱佳，正面顶线" },
    { id = "spearman",  cat = "inf", name = "长枪兵", damage = 80, toughness = 95,
      pursuit = 12, screen = 20, size = 100, maintenance = 0.5,
      unlock = "ironarms", vs = { cav = 1.5 }, desc = "长枪结阵：**克骑兵 ×1.5**，掩护高" },

    -- ── 弓兵 ──────────────────────────────────────────────
    { id = "archer",    cat = "arc", name = "弓手",   damage = 75, toughness = 85,
      pursuit = 40, screen = 10, size = 100, maintenance = 0.4,
      unlock = nil, vs = { inf = 1.0 }, desc = "远程输出：克制轻装（散兵）" },
    { id = "crossbow",  cat = "arc", name = "弩兵",   damage = 85, toughness = 90,
      pursuit = 45, screen = 12, size = 100, maintenance = 0.5,
      unlock = "stirrup", vs = { inf = 1.2, cav = 1.2 }, desc = "强弩：**克步兵与骑兵 ×1.2**" },

    -- ── 骑兵 ──────────────────────────────────────────────
    { id = "light_cav", cat = "cav", name = "轻骑兵", damage = 90, toughness = 60,
      pursuit = 50, screen = 10, size = 100, maintenance = 0.5,
      unlock = "cavalry", vs = { arc = 1.3 }, desc = "轻骑：**克弓兵**，机动作战" },
    { id = "heavy_cav", cat = "cav", name = "重骑兵", damage = 115, toughness = 90,
      pursuit = 35, screen = 15, size = 50, maintenance = 0.8,
      unlock = "stirrup", vs = { arc = 1.4 }, desc = "重装冲击骑兵：**克弓兵 ×1.4**，最强也最贵（50 人一团）" },
    { id = "chariot",   cat = "cav", name = "战车兵", damage = 70, toughness = 65,
      pursuit = 55, screen = 10, size = 50, maintenance = 0.5,
      unlock = "chariot", vs = { inf = 1.2 }, desc = "战车：春秋重器，追击极强" },
}

--- 从数组形式建索引（defs 既是数组也是 map，两用）
for _, u in ipairs(Units.defs) do
    Units.defs[u.id] = u
end

--- 按 id 取兵种定义
---@param id string|nil
---@return table|nil
function Units.get(id)
    if not id then return nil end
    return Units.defs[id]
end

--- 全部兵种（数组）
---@return table[]
function Units.all()
    return Units.defs
end

--- 取某大类下的兵种（保持表内顺序）
---@param catId string
---@return table[]
function Units.byCategory(catId)
    local out = {}
    for _, u in ipairs(Units.defs) do
        if u.cat == catId then out[#out + 1] = u end
    end
    return out
end

--- 大类显示名
---@param catId string
---@return string
function Units.catName(catId)
    for _, c in ipairs(Units.CATEGORIES) do
        if c.id == catId then return c.label end
    end
    return catId
end

-- 解锁判定 ----------------------------------------------------------------

local TechSystem = nil   -- 延迟 require（避免循环依赖）

--- 某科技是否已完成（容错：TechSystem 未就绪/势力为空 → false）
---@param faction table|nil
---@param techId string|nil
---@return boolean
function Units.hasTech(faction, techId)
    if not techId then return true end
    if not faction then return false end
    if not TechSystem then TechSystem = require("systems.TechSystem") end
    if not TechSystem.isDone then return false end
    return TechSystem.isDone(faction, techId) == true
end

--- 该势力是否解锁了某兵种
---@param faction table|nil
---@param unitId string
---@return boolean
function Units.isUnlocked(faction, unitId)
    local def = Units.get(unitId)
    if not def then return false end
    return Units.hasTech(faction, def.unlock)
end

--- 该势力当前可用的全部兵种
---@param faction table|nil
---@return table[]
function Units.available(faction)
    local out = {}
    for _, u in ipairs(Units.defs) do
        if Units.isUnlocked(faction, u.id) then out[#out + 1] = u end
    end
    return out
end

--- 势力主力兵种（没设 / 已失效 → 轻步兵兜底）
---@param faction table|nil
---@return table
function Units.mainOf(faction)
    local id = faction and faction.mainUnitId
    local def = Units.get(id)
    if def and Units.isUnlocked(faction, def.id) then return def end
    return Units.defs["light_inf"]
end

-- 混编（2026-09-24）----------------------------------------------------------
--   一支军队可以有多个兵种。存储方式：**总兵力仍是 prov.garrison（纯数字，不动）**，
--   另存一张**比例表** prov.unitMix = { light_inf = 0.8, archer = 0.2 }（和为 1）。
--   好处：调军/战斗/解散/占领/存档等 40 多处读写 garrison 的地方**一行都不用改**，
--   兵种明细 = garrison × unitMix[兵种]，纯派生。
--
--   为什么存比例而不是绝对人数：
--     战斗会按比例扣减双方兵力，绝对人数表需要在每个扣减点同步维护，极易漏；
--     比例表在兵力变化时自动"等比缩放"，永远自洽。
-- ---------------------------------------------------------------------------

--- 把一张比例表归一化（和 = 1）；空表/全零 → 用兜底兵种占 100%
---@param mix table|nil
---@param fallbackId string|nil 兜底兵种 id
---@return table<string, number>
function Units.normalizeMix(mix, fallbackId)
    local out, sum = {}, 0
    if type(mix) == "table" then
        for id, v in pairs(mix) do
            local n = tonumber(v) or 0
            if n > 0 and Units.get(id) then
                out[id] = n
                sum = sum + n
            end
        end
    end
    if sum <= 0 then
        return { [fallbackId or "light_inf"] = 1.0 }
    end
    for id, v in pairs(out) do out[id] = v / sum end
    return out
end

--- 取某省驻军的兵种比例表（没有记录 → 该势力主力兵种占 100%）
---@param province table|nil
---@param faction table|nil
---@return table
function Units.mixOf(province, faction)
    local fallback = Units.mainOf(faction).id
    if not province or type(province.unitMix) ~= "table" then
        return { [fallback] = 1.0 }
    end
    return Units.normalizeMix(province.unitMix, fallback)
end

--- 征召后更新比例：newMix = (总兵力 × 旧比例 + 新征人数 × 新兵种) / 新总兵力
---@param province table 目标省（原地更新 unitMix）
---@param faction table|nil
---@param unitId string 本次征召的兵种
---@param addCount number 本次征召人数
function Units.addTroops(province, faction, unitId, addCount)
    if not province or not unitId or (addCount or 0) <= 0 then return end
    if not Units.get(unitId) then return end
    local before = province.garrison or 0        -- ⚠️ 调用方已在 garrison 上加了 addCount
    local old = before - addCount                -- 原有兵力
    local mix = {}
    if old > 0 then
        for id, r in pairs(Units.mixOf(province, faction)) do
            mix[id] = (mix[id] or 0) + r * old
        end
    end
    mix[unitId] = (mix[unitId] or 0) + addCount
    province.unitMix = Units.normalizeMix(mix, unitId)
end

--- 按比例把总兵力拆成 { 兵种id = 人数 }（面板显示 / 战斗结算用）
---   用"最大余数法"保证各兵种人数之和**恰好等于** total
---@param province table|nil
---@param faction table|nil
---@param total number|nil 不传则用 province.garrison
---@return table<string, number>
function Units.detailOf(province, faction, total)
    local n = total or (province and province.garrison) or 0
    local mix = Units.mixOf(province, faction)
    local ids, out, sum = {}, {}, 0
    for id, r in pairs(mix) do
        local cnt = math.floor(n * r)
        out[id] = cnt
        sum = sum + cnt
        ids[#ids + 1] = id
    end
    -- 余数补给比例最大的那个兵种，凑齐总数
    if n - sum > 0 and #ids > 0 then
        local best, bestR = ids[1], -1
        for _, id in ipairs(ids) do
            if mix[id] > bestR then best, bestR = id, mix[id] end
        end
        out[best] = out[best] + (n - sum)
    end
    return out
end

--- 合并两支部队的兵种（按人数加权）：用于调军到达、多军并入同一省/同一场战斗
---   target 只要是"带 unitMix 字段的表"即可（省记录 或 战斗的一方 b.att / b.def）
---@param target table|nil 目标（原地更新 unitMix）
---@param targetCount number 目标**原有**兵力（不含并入的）
---@param incomingMix table|nil 并入方的比例表
---@param incomingCount number 并入方兵力
---@param faction table|nil
function Units.mergeMix(target, targetCount, incomingMix, incomingCount, faction)
    if not target then return end
    if (incomingCount or 0) <= 0 then return end
    local mix = {}
    if (targetCount or 0) > 0 then
        for id, r in pairs(Units.mixOf(target, faction)) do
            mix[id] = (mix[id] or 0) + r * targetCount
        end
    end
    local fallback = Units.mainOf(faction).id
    for id, r in pairs(Units.normalizeMix(incomingMix, fallback)) do
        mix[id] = (mix[id] or 0) + r * incomingCount
    end
    target.unitMix = Units.normalizeMix(mix, fallback)
end

-- 战斗接口（供 MilitarySystem 调用）----------------------------------------

--- 计算某方的战力（CK3 口径：战力 = (兵力 / 每团人数) × 伤害/坚韧 × 相克）
---@param faction table|nil 我方势力
---@param enemyFaction table|nil 敌方势力
---@param troops number 参战兵力
---@param asDefender boolean|nil true = 用坚韧（防御）
---@param mix table|nil 我方兵种比例表（不传 = 势力主力兵种占 100%）
---@param enemyMix table|nil 敌方兵种比例表（不传 = 用敌方势力主力兵种）
---@return number
function Units.power(faction, enemyFaction, troops, asDefender, mix, enemyMix)
    local mine = Units.mainOf(faction)
    local theirs = Units.mainOf(enemyFaction)
    local selfMix = Units.normalizeMix(mix, mine.id)
    -- 敌方构成：优先用调用方传进来的真实混编（攻守双方各自的省/军队）
    local enemyMixSrc = (type(enemyMix) == "table") and enemyMix or { [theirs.id] = 1.0 }
    ---@type table<string, number>
    local foeMix = Units.normalizeMix(enemyMixSrc, theirs.id)
    -- 敌方各大类的占比（相克按"对方兵种构成"逐类加权）
    ---@type table<string, number>
    local foeCatShare = {}
    for id, r in pairs(foeMix) do
        local d = Units.get(id)
        if d then foeCatShare[d.cat] = (foeCatShare[d.cat] or 0) + r end
    end

    -- 我方战力 = Σ 各兵种 (人数/每团人数) × 伤害或坚韧 × 对敌方构成的相克系数
    local power = 0
    for id, r in pairs(selfMix) do
        local def = Units.get(id)
        if def then
            local n = troops * r
            local stat = asDefender and (def.toughness or 100) or (def.damage or 100)
            local p = (n / (def.size or 100)) * stat
            local vs = def.vs
            if vs then
                local mul = 0
                for cat, share in pairs(foeCatShare) do
                    if vs[cat] then mul = mul + share * vs[cat] end
                end
                if mul > 0 then p = p * mul end
            end
            power = power + p
        end
    end
    return power
end

--- 撤退阶段（溃退）的追击/掩护计算
---   追击方：damage = Σ (各兵种兵力/size) × 追击 × PURSUIT_DAMAGE
---   逃跑方：减免  = Σ (各兵种兵力/size) × 掩护 × SCREEN_REDUCTION
---@param pursuerFaction table|nil 追击方
---@param fleeingFaction table|nil 逃跑方
---@param pursuerTroops number 追击方剩余兵力
---@param fleeingTroops number 逃跑方剩余兵力
---@param pursuerMix table|nil 追击方兵种比例（不传 = 主力兵种）
---@param fleeingMix table|nil 逃跑方兵种比例（不传 = 主力兵种）
---@return number pursuitLoss 逃跑方在撤退阶段的损失
function Units.retreatLoss(pursuerFaction, fleeingFaction, pursuerTroops, fleeingTroops,
                           pursuerMix, fleeingMix)
    local pursuer = Units.mainOf(pursuerFaction)
    local fleer = Units.mainOf(fleeingFaction)
    local function weight(faction, mix, troops, key)
        local selfMix = Units.normalizeMix(mix, Units.mainOf(faction).id)
        local sum = 0
        for id, r in pairs(selfMix) do
            local def = Units.get(id)
            if def then sum = sum + (troops * r / (def.size or 100)) * (def[key] or 0) end
        end
        return sum
    end
    local raw = weight(pursuerFaction, pursuerMix, pursuerTroops, "pursuit") * Units.PURSUIT_DAMAGE
    local blocked = weight(fleeingFaction, fleeingMix, fleeingTroops, "screen") * Units.SCREEN_REDUCTION
    local loss = math.max(0, raw - blocked)
    -- 最多追死逃跑方的 60%（防止一场追击全歼）
    return math.min(loss, fleeingTroops * 0.6)
end

--- 维护费（每月，全势力）：Σ (各兵种兵力/每团人数) × 单价
---@param faction table|nil
---@param troops number|nil 不传则用 faction.armySize
---@param mix table|nil 兵种比例表（不传 = 势力主力兵种占 100%）
---@return number gold
function Units.upkeepOf(faction, troops, mix)
    local main = Units.mainOf(faction)
    local n = troops or (faction and faction.armySize) or 0
    local selfMix = Units.normalizeMix(mix, main.id)
    local total = 0
    for id, r in pairs(selfMix) do
        local def = Units.get(id)
        if def then
            total = total + (n * r / (def.size or 100)) * (def.maintenance or 0.5)
        end
    end
    return total
end

--- 势力全部真实部队的平均兵种比例：实控驻军（含占领区）+ 在途 + 战斗双方。
---   无记录的部队按主力兵种算；复用无依赖账本，不引入 MilitarySystem 循环 require。
---@param gameState table|nil
---@param faction table|nil
---@return table
function Units.factionMix(gameState, faction)
    local main = Units.mainOf(faction)
    local entries, total = require("systems.MilitaryLedger").snapshot(gameState, faction)
    if total <= 0 then return { [main.id] = 1.0 } end
    local acc = {}
    for _, entry in ipairs(entries) do
        for id, r in pairs(Units.mixOf(entry.source, faction)) do
            acc[id] = (acc[id] or 0) + r * entry.size
        end
    end
    return Units.normalizeMix(acc, main.id)
end

return Units

-- ============================================================================
-- 春秋霸业 - 政策系统
-- systems/PolicySystem.lua
--
-- 政策 = 光谱轴 + 变法改革
--
--   A. 政策**光谱轴**（税率 / 经济 / 内政 / 军事）：
--      每条轴从左到右几档立场，玩家挪档位，**点即生效、长期持续**
--      （2026-09-17 用户："它有中间，然后偏左偏右……而不是各个方面都有"）
--   B. 变法改革（一次性大决策）：
--      永久效果 + 持续数月的稳定副作用（各变法持续时间不同）
--
-- 数据挂在 faction 上：
--   f.policyAxes      = { tax=2, economy=2, domestic=2, military=2 }  档位下标（1=最左）
--   f.reforms         = { "商鞅变法", ... }                     已实行的变法
--   f.reformEffects   = { {id, monthsLeft, stability}, ... }    进行中的副作用
-- ============================================================================

local PolicySystem = {}

-- =========================================================================
-- 政策 / 变法**数据**已搬到 data/Policies.lua（2026-09-13，插座第五块）：
--   * 数据和逻辑分家 → 模组可以加政策卡/变法，不用改系统代码
--   * 这里只是**引用同一张表**（不是拷贝）→ 下面所有 getXxxModifier 和界面代码一行都不用改
local Policies = require("data.Policies")

PolicySystem.AXES    = Policies.AXES      -- 政策光谱轴（数组顺序 = 面板显示顺序）
PolicySystem.REFORMS = Policies.REFORMS

-- =========================================================================
-- 内部工具
-- =========================================================================

--- 势力是否已研究过某变法
---@param faction table
---@param reformId string
---@return boolean
local function hasReform(faction, reformId)
    if not faction.reforms then return false end
    for _, id in ipairs(faction.reforms) do
        if id == reformId then return true end
    end
    return false
end

--- 取势力当前**每条轴选中的立场**
---@param faction table
---@return table[] options 选中的 option 列表（元素含 effects）
local function activeAxisOptions(faction)
    local result = {}
    for _, axis in ipairs(PolicySystem.AXES) do
        local opt = axis.options[PolicySystem.getAxisIndex(faction, axis.id)]
        if opt then result[#result + 1] = opt end
    end
    return result
end

--- 取势力已实行的变法表
---@param faction table
---@return table reforms
local function activeReforms(faction)
    local result = {}
    local reforms = faction.reforms or {}
    for _, rid in ipairs(reforms) do
        for _, def in ipairs(PolicySystem.REFORMS) do
            if def.id == rid then
                result[#result + 1] = def
                break
            end
        end
    end
    return result
end

-- =========================================================================
-- 查询
-- =========================================================================

--- 找一条政策轴
---@param axisId string
---@return table|nil axis
function PolicySystem.findAxis(axisId)
    for _, a in ipairs(PolicySystem.AXES) do
        if a.id == axisId then return a end
    end
    return nil
end

--- 势力在某轴上的档位下标（1 = 最左）；没设过 → 该轴的 default
---@param faction table
---@param axisId string
---@return number index
function PolicySystem.getAxisIndex(faction, axisId)
    local axis = PolicySystem.findAxis(axisId)
    if not axis then return 1 end
    local axes = faction and faction.policyAxes
    local idx = (axes and axes[axisId]) or axis.default or 1
    if idx < 1 then idx = 1 end
    if idx > #axis.options then idx = #axis.options end
    return idx
end

--- 势力在某轴上选中的立场定义
---@param faction table
---@param axisId string
---@return table|nil option
function PolicySystem.getAxisOption(faction, axisId)
    local axis = PolicySystem.findAxis(axisId)
    if not axis then return nil end
    return axis.options[PolicySystem.getAxisIndex(faction, axisId)]
end

--- 某立场是这条轴上的第几档（用于"偏左/中道/偏右"文案）
---@param axis table
---@param index number
---@return string "left"|"center"|"right"
function PolicySystem.leanOf(axis, index)
    local n = #axis.options
    local mid = math.floor((n + 1) / 2)
    if index == mid then return "center" end
    return index < mid and "left" or "right"
end

-- =========================================================================
-- 效果修正（供 Economy/Military/Diplomacy 挂钩）
--   2026-09-17 起：政策是**光谱轴上的立场**，各轴 effects 求和，长期持续
-- =========================================================================

--- 政策轴给某属性的净加成（各轴选中立场的 effects[key] 求和）
---@param faction table
---@param key string 属性键，见 data/Policies.lua 的 Policies.ATTR_NAMES
---@return number delta 例：0.20 = +20%，-0.12 = -12%
local function axisDelta(faction, key)
    local d = 0
    for _, opt in ipairs(activeAxisOptions(faction)) do
        local eff = opt.effects
        if eff and eff[key] then d = d + eff[key] end
    end
    return d
end

--- 变法给某属性的加成（变法仍是各自的直接字段，如 { gold = 0.20 }）
---@param faction table
---@param key string
---@return number delta
local function reformDelta(faction, key)
    local d = 0
    for _, def in ipairs(activeReforms(faction)) do
        if def[key] then d = d + def[key] end
    end
    return d
end

--- 某立场的效果文案（UI 用）：一条一条列出来，带"好坏"标记
---   2026-09-17：颜色不按 +/- 机械判断，而是"对玩家有利=绿 / 有害=红"；
---   政策这边的键都是"越高越好"，所以正=绿、负=红
---@param option table 轴上的一档立场
---@return table[] items { text = string, good = boolean }
function PolicySystem.axisOptionText(option)
    local names = Policies.ATTR_NAMES or {}
    local items = {}
    local eff = (option and option.effects) or {}
    -- 固定顺序输出 → 每次刷新文案不会跳来跳去
    for _, key in ipairs({ "gold", "food", "popGrowth", "recruit", "military", "defense", "stability" }) do
        local v = eff[key]
        if v and v ~= 0 then
            local name = names[key] or key
            local text
            if key == "stability" then
                -- 稳定是"每月几点"，不是百分比
                text = string.format("%s %s%d", name, v > 0 and "+" or "−", math.abs(v))
            else
                text = string.format("%s %s%d%%", name, v > 0 and "+" or "−",
                    math.floor(math.abs(v) * 100 + 0.5))
            end
            items[#items + 1] = { text = text, good = v > 0 }
        end
    end
    return items
end

--- 金钱收入倍率修正（政策轴 + 变法）
---@param faction table
---@return number multiplier
function PolicySystem.getGoldModifier(faction)
    return 1.0 + axisDelta(faction, "gold") + reformDelta(faction, "gold")
end

--- 粮草收入倍率修正
---@param faction table
---@return number multiplier
function PolicySystem.getFoodModifier(faction)
    return 1.0 + axisDelta(faction, "food") + reformDelta(faction, "food")
end

--- 战斗力倍率修正（进攻）
---@param faction table
---@return number multiplier
function PolicySystem.getMilitaryModifier(faction)
    return 1.0 + axisDelta(faction, "military") + reformDelta(faction, "military")
end

--- 防御倍率修正
---@param faction table
---@return number multiplier
function PolicySystem.getDefenseModifier(faction)
    return 1.0 + axisDelta(faction, "defense") + reformDelta(faction, "defense")
end

--- 人口增长加法修正
---@param faction table
---@return number additive
function PolicySystem.getPopGrowthModifier(faction)
    return axisDelta(faction, "popGrowth") + reformDelta(faction, "popGrowth")
end

--- 征兵上限倍率修正
---@param faction table
---@return number multiplier
function PolicySystem.getRecruitModifier(faction)
    return 1.0 + axisDelta(faction, "recruit") + reformDelta(faction, "recruit")
end

--- 每月稳定度修正（政策轴 + 变法的长期效果；变法副作用另走 processMonthly）
---@param faction table
---@return number delta
function PolicySystem.getStabilityDelta(faction)
    return axisDelta(faction, "stability") + reformDelta(faction, "stability")
end

--- 改善关系加成（政策轴 + 变法；**加法**，调用方从 0 起算）
---   目前政策轴/变法都没有 diplo 效果键 → 恒为 0；保留此函数是因为
---   DiplomacySystem 的 diploImprove 管道规则要读它（缺了会每帧抛错）。
---   以后要加"外交"类政策，在 Policies 的 effects 里加 diplo 键即可自动生效。
---@param faction table
---@return number delta
function PolicySystem.getDiploModifier(faction)
    return axisDelta(faction, "diplo") + reformDelta(faction, "diplo")
end

-- =========================================================================
-- 行动
-- =========================================================================

--- 把某条政策轴挪到指定立场（**点即生效**，不花一次性代价，直到再换）
---   2026-09-17 用户："它有中间，然后偏左偏右" → 政策就是轴上挪位置
---@param gameState table
---@param factionId number
---@param axisId string 轴 id（tax / economy / domestic / military）
---@param optionId string 立场 id（如 "重农"）
---@return boolean ok
---@return string|nil reason
function PolicySystem.setAxis(gameState, factionId, axisId, optionId)
    local f = gameState.factions[factionId]
    if not f then return false, "势力不存在" end
    if f.alive == false then return false, "势力已灭亡" end

    local axis = PolicySystem.findAxis(axisId)
    if not axis then return false, "未知政策" end
    local idx
    for i, opt in ipairs(axis.options) do
        if opt.id == optionId then idx = i; break end
    end
    if not idx then return false, "该政策没有这个立场" end

    f.policyAxes = f.policyAxes or {}
    if f.policyAxes[axisId] == idx then return true, nil end   -- 已经站这档，不重复提示
    f.policyAxes[axisId] = idx

    if gameState.addMessage then
        gameState.addMessage("政策「" .. axis.name .. "」改为「" .. optionId .. "」", "system")
    end
    return true, nil
end

-- 2026-09-16 删：政策"实施进度"（processDaily / getProgress / isImplementing）
--   用户："我实行什么政策他不需要什么时间" → 政策卡现在**点即生效**，
--   不再有 daysLeft / totalDays 那套 HoI4 式进度

--- 解锁一个变法（2026-09-16：**由"某人上书"事件调用**——玩家同意后才出现在政策面板）
---@param gameState table
---@param factionId number
---@param reformId string
---@return boolean ok
function PolicySystem.unlockReform(gameState, factionId, reformId)
    local f = gameState.factions[factionId]
    if not f then return false end
    local def
    for _, r in ipairs(PolicySystem.REFORMS) do
        if r.id == reformId then def = r; break end
    end
    if not def then return false end
    if PolicySystem.isReformKnown(f, reformId) then return true end
    f.reformsKnown = f.reformsKnown or {}
    f.reformsKnown[#f.reformsKnown + 1] = reformId
    if gameState.addMessage and factionId == gameState.playerFactionId then
        -- 2026-09-16 用户："通知里不要加小括号里的东西" → 去掉括号，改成直接说
        gameState.addMessage("「" .. reformId .. "」已列入变法案，可在政策面板实行", "system", true)
    end
    return true
end

--- 该变法是否已解锁（有人提出过了）
---@param faction table
---@param reformId string
---@return boolean
function PolicySystem.isReformKnown(faction, reformId)
    if not faction or not faction.reformsKnown then return false end
    for _, id in ipairs(faction.reformsKnown) do
        if id == reformId then return true end
    end
    return false
end

--- 激活变法（一次性大决策，永久效果 + 持续副作用）
---@param gameState table
---@param factionId number
---@param reformId string
---@return boolean ok
---@return string|nil reason
function PolicySystem.activateReform(gameState, factionId, reformId)
    local f = gameState.factions[factionId]
    if not f then return false, "势力不存在" end

    -- 找变法定义
    local def = nil
    for _, r in ipairs(PolicySystem.REFORMS) do
        if r.id == reformId then
            def = r
            break
        end
    end
    if not def then return false, "未知变法" end

    if hasReform(f, reformId) then
        return false, "该变法已实行"
    end
    -- 2026-09-16：变法要"有人提出"过才能实行（事件解锁）
    if not PolicySystem.isReformKnown(f, reformId) then
        return false, "尚未有人提出此变法"
    end

    -- 资源校验（金/名声）
    local cost = def.cost or {}
    if (f.gold or 0) < (cost.gold or 0) then
        return false, "金钱不足（需要 " .. (cost.gold or 0) .. "）"
    end
    if (f.prestige or 0) < (cost.prestige or 0) then
        return false, "名声不足（需要 " .. (cost.prestige or 0) .. "）"
    end

    -- 扣除资源
    f.gold = (f.gold or 0) - (cost.gold or 0)
    f.prestige = (f.prestige or 0) - (cost.prestige or 0)

    -- 记录变法
    f.reforms = f.reforms or {}
    f.reforms[#f.reforms + 1] = reformId

    -- 添加持续副作用（各变法持续时间不同）
    local penalty = def.penalty
    if penalty and penalty.months and penalty.stability then
        f.reformEffects = f.reformEffects or {}
        f.reformEffects[#f.reformEffects + 1] = {
            id          = reformId,
            monthsLeft  = penalty.months,
            stability   = penalty.stability,
        }
    end

    if gameState.addMessage then
        local msg = "实行变法「" .. reformId .. "」！"
        if penalty and penalty.months then
            msg = msg .. "（旧贵族不满，未来 " .. penalty.months
                .. " 个月稳定每月 " .. penalty.stability .. "）"
        end
        gameState.addMessage(msg, "system")
    end
    return true, nil
end

--- 每月处理：变法副作用扣稳定并倒计时（main.lua OnNewMonth 调用）
---@param gameState table
function PolicySystem.processMonthly(gameState)
    for fid, f in pairs(gameState.factions) do
        local effects = f.reformEffects
        if effects and #effects > 0 then
            local remaining = {}
            for _, e in ipairs(effects) do
                f.stability = math.max(-100, math.min(100,
                    (f.stability or 0) + e.stability))
                e.monthsLeft = e.monthsLeft - 1
                if e.monthsLeft > 0 then
                    remaining[#remaining + 1] = e
                end
            end
            f.reformEffects = remaining
        end
    end
end

--- 获取某势力变法实行状态（UI 用）
---@param faction table
---@param reformId string
---@return string "done"|"active"|"locked"|"unknown"
---   unknown = 还没人提出（2026-09-16：面板上隐藏或标"待有人提出"）
function PolicySystem.getReformState(faction, reformId)
    if hasReform(faction, reformId) then
        return "done"
    end
    if not PolicySystem.isReformKnown(faction, reformId) then
        return "unknown"
    end
    -- 能否负担
    for _, r in ipairs(PolicySystem.REFORMS) do
        if r.id == reformId then
            local cost = r.cost or {}
            if (faction.gold or 0) >= (cost.gold or 0)
                and (faction.prestige or 0) >= (cost.prestige or 0) then
                return "active"
            end
            return "locked"
        end
    end
    return "locked"
end

return PolicySystem

-- 单日战斗纯规则：输入同一时刻的双方快照，一次返回伤亡、士气与结果。
-- 兵种/地形/修正器由 MilitarySystem 算有效战力；本模块不改国家、驻军或战争账。
local CombatRules = {}

---@param att table
---@param def table
---@param attPower number 已含当前士气的攻方有效战力
---@param defPower number 已含当前士气的守方有效战力
---@param rules table GameConfig.Military（沿用原数值）
---@return table
function CombatRules.resolveRound(att, def, attPower, defPower, rules)
    local attBefore, defBefore = math.max(0, att.size or 0), math.max(0, def.size or 0)
    local attMorale = math.max(0, att.morale or rules.BASE_MORALE)
    local defMorale = math.max(0, def.morale or rules.BASE_MORALE)
    local aPower, dPower = math.max(0, attPower), math.max(0, defPower)
    local result = {
        attSize = attBefore, defSize = defBefore,
        attMorale = attMorale, defMorale = defMorale,
        attLoss = 0, defLoss = 0, progressDelta = 0,
        reason = "", routSide = "", wiped = false,
    }

    -- 空军先结束，不能凭每日最少伤亡/基础士气消耗制造不存在的交战。
    if attBefore <= 0 or defBefore <= 0 then
        result.reason = "empty"
        if attBefore <= 0 and defBefore <= 0 then
            result.outcome = "draw"
        else
            result.outcome = attBefore > 0 and "att" or "def"
            result.wiped = true
        end
        return result
    end

    local total = aPower + dPower
    if total <= 0 then
        -- 两方都无有效战力：退战保兵，不把某一方兵力改成零。
        result.outcome, result.reason = "draw", "no_power"
        return result
    end

    -- 伤亡只读战前快照，两边算完才由调用方统一写回。
    result.attLoss = math.min(attBefore, math.max(rules.BATTLE_MIN_LOSS,
        math.floor(dPower / total * attBefore * rules.BATTLE_DAILY_LOSS_MAX)))
    result.defLoss = math.min(defBefore, math.max(rules.BATTLE_MIN_LOSS,
        math.floor(aPower / total * defBefore * rules.BATTLE_DAILY_LOSS_MAX)))
    result.attSize, result.defSize = attBefore - result.attLoss, defBefore - result.defLoss
    result.attMorale = math.max(0, attMorale
        - (rules.MORALE_LOSS_BASE + rules.MORALE_LOSS_SCALE * result.attLoss / attBefore))
    result.defMorale = math.max(0, defMorale
        - (rules.MORALE_LOSS_BASE + rules.MORALE_LOSS_SCALE * result.defLoss / defBefore))
    result.progressDelta = (aPower - dPower) / total * 0.5

    -- 双归零/双崩必须先成对判断，不能因先检查攻方而偏向守方。
    if result.attSize <= 0 or result.defSize <= 0 then
        result.reason = "destroyed"
        if result.attSize <= 0 and result.defSize <= 0 then
            result.outcome = "draw"
        else
            result.outcome = result.attSize > 0 and "att" or "def"
            result.wiped = true
        end
        return result
    end
    local attRouted, defRouted = result.attMorale <= rules.ROUT_MORALE,
        result.defMorale <= rules.ROUT_MORALE
    if attRouted and defRouted then
        result.reason = "double_rout"
        -- 同一轮战前有效战力的对称比较。不能用掉到零后的士气重算而抹掉优势。
        if aPower > dPower * 1.05 then
            result.outcome, result.routSide = "att", "def"
        elseif dPower > aPower * 1.05 then
            result.outcome, result.routSide = "def", "att"
        else
            result.outcome = "draw"
        end
    elseif attRouted or defRouted then
        result.reason = "rout"
        result.outcome = attRouted and "def" or "att"
        result.routSide = attRouted and "att" or "def"
    end
    return result
end

return CombatRules

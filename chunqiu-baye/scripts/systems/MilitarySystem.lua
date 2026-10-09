-- ============================================================================
-- 春秋霸业 - 军事系统
-- MilitarySystem.lua
--
-- Handles recruitment, army movement, combat resolution, and province
-- occupation for the Spring and Autumn period grand strategy game.
-- ============================================================================
local GameConfig = require("config.GameConfig")
local LeaderSystem = require("systems.LeaderSystem")
local PolicySystem = require("systems.PolicySystem")
local Modifiers = require("systems.Modifiers")
local Hooks = require("systems.Hooks")
local Logistics = require("systems.MilitaryLogistics")
local CombatRules = require("systems.CombatRules")

local MilitarySystem = {}

-- ---------------------------------------------------------------------------
-- 修正器管道登记（2026-09-13）：政策/变法给的征兵加成
--   用 scale（连乘）—— 与原来 `× PolicySystem.getRecruitModifier(faction)` 等价
-- ---------------------------------------------------------------------------
Modifiers.rule{
    scope = "faction", key = "recruit", op = "scale", source = "policy:recruit",
    value = function(_, ctx) return PolicySystem.getRecruitModifier(ctx.faction) end,
}

-- ---------------------------------------------------------------------------
-- 修正器管道登记（2026-09-14 · 洞 4）：**战力 / 防御**
--   之前这两个是**直接调** PolicySystem 的 getter（`× getMilitaryModifier(fac)`），
--   没走管道 → **模组往管道挂 militaryPower / defensePower 完全不会生效**（没人读）。
--   现在改成和 recruit 一样：注册成 scale 规则，调用方读管道。
--   用 scale（连乘）+ 一条一条乘 → 与原来 `君主 × 政策` 的**乘积完全相等**，数值不变。
-- ---------------------------------------------------------------------------
Modifiers.rule{
    scope = "faction", key = "militaryPower", op = "scale", source = "leader:military",
    value = function(_, ctx) return LeaderSystem.getMilitaryModifier(ctx.faction) end,
}
Modifiers.rule{
    scope = "faction", key = "militaryPower", op = "scale", source = "policy:military",
    value = function(_, ctx) return PolicySystem.getMilitaryModifier(ctx.faction) end,
}
Modifiers.rule{
    scope = "faction", key = "defensePower", op = "scale", source = "policy:defense",
    value = function(_, ctx) return PolicySystem.getDefenseModifier(ctx.faction) end,
}

-- ---------------------------------------------------------------------------
-- Shorthand reference to the Military config block
-- ---------------------------------------------------------------------------
local MIL = GameConfig.Military

-- ---------------------------------------------------------------------------
-- Terrain defense multipliers used during combat resolution.
-- Defenders in rough terrain gain a bonus to effective strength.
-- ---------------------------------------------------------------------------
local TERRAIN_DEFENSE = {
    ["山地"] = 1.4,
    ["丘陵"] = 1.2,
    ["森林"] = 1.15,
    ["沼泽"] = 1.1,
    -- 2026-09-22 真实地理地形接入后新增（照 CK3 档位：沙漠/丛林同山地 +2）
    ["沙漠"] = 1.35,
    ["丛林"] = 1.35,
    ["针叶林"] = 1.15,
}

-- 驻军、补给、征召和统帅共用规则由 Logistics 安装，避免两套实现漂移。
Logistics.install(MilitarySystem)

-- ============================================================================
-- launchOffensive(gameState, factionId)
--
-- 宣战即出兵（2026-09-17 用户："既然交战这些军队就应该立刻出发"）。
--   对每个"与敌国省份相邻"的我方省份，派出**一半驻军**去打那个敌省
--   （另一半留守）；没有相邻敌省就不动（等后续推进/调兵）。
--   要解决的问题：以前宣战后两军就在原地干耗 → 战争分恒为 0。
--
-- Returns: 出动的军队数
-- ============================================================================
-- 主动进攻只针对当前控制者；达到 -100 的一方停手，不影响己方调军重整。
---@param gameState table
---@param factionId number
---@param provinceId number
---@param morale number|nil
---@return boolean
local function canAttackProvince(gameState, factionId, provinceId, morale)
    local p = gameState.provinces[provinceId]
    if not p or p.isOcean or p.isWasteland then return false end
    local controller = Logistics.controller(p)
    if not controller or controller == factionId then return true end
    if (morale or MIL.BASE_MORALE) <= MIL.ROUT_MORALE then return false end
    local DiplomacySystem = require("systems.DiplomacySystem")
    if not DiplomacySystem.isAtWar(gameState, factionId, controller) then return false end
    local WarSystem = require("systems.WarSystem")
    local war = WarSystem.findWar(gameState, factionId, controller)
    return not war or WarSystem.getScore(gameState, war, factionId) > -99.999
end

function MilitarySystem.launchOffensive(gameState, factionId)
    if not gameState or not factionId or not gameState.factions[factionId] then return 0 end
    local sent = 0
    local minimum = GameConfig.AI.ATTACK_MIN_GARRISON or 180

    -- 只有脱战且实际控制的省出兵；被敌占的本国省没有可用兵权。
    local frontier = {}
    for _, pid in ipairs(Logistics.controlledProvinces(gameState, factionId)) do
        local prov = gameState.provinces[pid]
        if not (gameState.battles and gameState.battles[pid]) then
            for _, nid in ipairs(prov.neighbors or {}) do
                local np = gameState.provinces[nid]
                local controller = Logistics.controller(np)
                if controller and controller ~= factionId
                    and MilitarySystem.canPassThrough(gameState, factionId, nid)
                    and canAttackProvince(gameState, factionId, nid, prov.morale) then
                    frontier[pid] = nid
                    break
                end
            end
        end
    end
    if next(frontier) == nil then return 0 end

    for pid, enemyId in pairs(frontier) do
        local prov = gameState.provinces[pid]
        local g = prov.garrison or 0
        if g >= minimum then
            local ok = MilitarySystem.moveArmy(gameState, factionId, pid, enemyId, math.floor(g * 0.5))
            if ok then sent = sent + 1 end
        end
    end

    -- 内陆只沿脱战的己方控制省向前线集结，不越过敌占原省。
    for _, pid in ipairs(Logistics.controlledProvinces(gameState, factionId)) do
        local prov = gameState.provinces[pid]
        local g = prov.garrison or 0
        if not frontier[pid] and g >= minimum
            and not (gameState.battles and gameState.battles[pid]) then
            local prev, queue, head = { [pid] = pid }, { pid }, 1
            local target = nil
            while head <= #queue and not target do
                local cur = queue[head]; head = head + 1
                if frontier[cur] and cur ~= pid then
                    target = cur
                else
                    for _, nid in ipairs(gameState.provinces[cur].neighbors or {}) do
                        if not prev[nid] and Logistics.controller(gameState.provinces[nid]) == factionId
                            and MilitarySystem.canGarrisonIn(gameState, factionId, nid) then
                            prev[nid] = cur
                            queue[#queue + 1] = nid
                        end
                    end
                end
            end
            if target then
                local cur = target
                while prev[cur] and prev[cur] ~= pid do cur = prev[cur] end
                if cur ~= pid then
                    local ok = MilitarySystem.moveArmy(gameState, factionId, pid, cur, math.floor(g * 0.5))
                    if ok then sent = sent + 1 end
                end
            end
        end
    end
    return sent
end

-- ============================================================================
-- 寻路（2026-09-26）：选中军队 → 点任意目标省（AoH3 式交互）
--   AoH3 里点一下军队再点目标省，军队自己走过去；不需要"只能点相邻省"。
--   我们原来是"点「调军」按钮 → 只能点相邻的绿色省"，手机上很别扭。
--   这里提供 BFS 最短路，把"相邻 N 步"拆成连续的多段行军。
-- ============================================================================

--- 求从 fromId 到 toId 的最短陆路（只走非海洋、非废土省）
---   不限制"必须是自己或盟友的地" —— 敌对省也可以作为路径终点/途经点；
---   非战斗途经点继续行军，终点才触发新战斗。
---
---   通行权（2026-09-26）：传了 factionId 就按 **canPassThrough** 过滤 ——
---   只走自家 / 无主 / 交战国，**中立国绕开**（否则军队抄近路穿过中立国，
---   走到人家地盘就自动开战，把第三方拖进战争）。
---   不传 factionId = 旧行为（只避海/废土），供不关心归属的调用方使用。
---@param gameState table
---@param fromId number
---@param toId number
---@param factionId number|nil 行军方势力（传了才启用通行权过滤）
---@return number[]|nil path 含起终点的完整路径；无路可走返回 nil
function MilitarySystem.findPath(gameState, fromId, toId, factionId)
    if not gameState or not fromId or not toId then return nil end
    if fromId == toId then return { fromId } end
    local provinces = gameState.provinces
    if not provinces or not provinces[fromId] or not provinces[toId] then return nil end

    local prev = { [fromId] = fromId }
    local queue, head = { fromId }, 1
    local found = false
    while head <= #queue do
        local cur = queue[head]; head = head + 1
        if cur == toId then found = true; break end
        local cp = provinces[cur]
        for _, nid in ipairs((cp and cp.neighbors) or {}) do
            if not prev[nid] then
                local np = provinces[nid]
                -- 终点与中间站**同一条规则**（2026-09-28 修 bug）：
                --   之前终点无条件放行，导致"中立国也能当目标"（用户："它可以去但是它其实
                --   不应该去"）—— 走到中立国就自动开战，把第三方拖进战争。
                --   现在统一走 canPassThrough：自家/无主/交战国能到，中立国到不了。
                --   （交战国仍能当终点 → 走到那儿开战，这是玩家意图，不受影响）
                local passable
                if factionId then
                    passable = MilitarySystem.canPassThrough(gameState, factionId, nid)
                else
                    passable = np and not np.isOcean and not np.isWasteland
                end
                if passable then
                    prev[nid] = cur
                    queue[#queue + 1] = nid
                end
            end
        end
    end
    if not found then return nil end

    local path, cur = {}, toId
    while cur ~= fromId do
        table.insert(path, 1, cur)
        cur = prev[cur]
    end
    table.insert(path, 1, fromId)
    return path
end

--- 把一条路径变成连续的军令（多段行军）
---   为了不引入"部队对象"，这里**逐段派兵**：第一段出发时扣兵，
---   后续段由 updateArmies 到达后自动续接（army.routePath 记录剩余路径）。
---   非战斗途经点不落地扣兵/并兵；已有战斗先处理同 faction 援军。
---@param gameState table
---@param factionId number
---@param fromId number
---@param toId number
---@param size number
---@return boolean ok
---@return table|string 成功 = armyEntry；失败 = 错误信息
function MilitarySystem.orderMove(gameState, factionId, fromId, toId, size)
    if not gameState or not factionId then return false, "参数不全" end
    local fromProv = gameState.provinces and gameState.provinces[fromId]
    if not fromProv then return false, "出发省不存在" end
    if Logistics.controller(fromProv) ~= factionId then return false, "出发省不由你控制" end
    if gameState.battles and gameState.battles[fromId] then return false, "接战省不能调军" end
    if type(size) ~= "number" or size <= 0 or (fromProv.garrison or 0) < size then
        return false, "驻军不足或调动数量无效"
    end
    if fromId == toId then return false, "目的地就是出发地" end
    local destination = gameState.provinces[toId]
    if not destination then return false, "目的省不存在" end
    if not canAttackProvince(gameState, factionId, toId, fromProv.morale) then
        return false, "不能主动进攻此省（未交战、士气过低或战争分已达-100）"
    end

    local path = MilitarySystem.findPath(gameState, fromId, toId, factionId)
    if not path or #path < 2 then
        -- 给出更准确的原因，方便玩家判断（2026-09-28）
        local tp = gameState.provinces[toId]
        local owner = Logistics.controller(tp)
        if owner and owner ~= factionId and not MilitarySystem.canPassThrough(gameState, factionId, toId) then
            local of = gameState.factions[owner]
            return false, string.format("不能进入 %s 的领土（未交战的中立国）",
                (of and of.name) or "他国")
        end
        return false, "无路可走（隔着海、废土，或必须穿过中立国）"
    end

    -- 第一跳：走 path[2]；把整条路径挂在军队上，到达后自动续接
    local nextId = path[2]
    local ok, result = MilitarySystem.moveArmy(gameState, factionId, fromId, nextId, size, toId)
    if not ok then return false, result end
    if type(result) == "table" then
        -- 剩余路径（不含已走的第一段），到达后由 updateArmies 续接
        local rest = {}
        for i = 2, #path do rest[#rest + 1] = path[i] end
        result.routePath = rest
    end
    return true, result
end

-- ============================================================================
-- moveArmy(gameState, factionId, fromProvinceId, toProvinceId, size)
--
-- Create an army movement order. The army will march from one province to a
-- neighboring province over MOVE_DAYS days (= MOVE_DAYS * 24 hours).
--
-- Returns: true, armyEntry   on success
--          false, reason      on failure
-- ============================================================================
---@param orderTargetId number|nil 多段军令的最终目标，仅终点判主动进攻
function MilitarySystem.moveArmy(gameState, factionId, fromProvinceId, toProvinceId, size, orderTargetId)
    local faction = gameState.factions[factionId]
    if not faction then
        return false, "势力不存在"
    end

    local fromProv = gameState.provinces[fromProvinceId]
    local toProv   = gameState.provinces[toProvinceId]
    if not fromProv then return false, "出发郡县不存在" end
    if not toProv   then return false, "目标郡县不存在" end

    if fromProv.isOcean or fromProv.isWasteland
        or not MilitarySystem.canPassThrough(gameState, factionId, toProvinceId) then
        return false, "目标无法通行（海洋、废土或中立控制省）"
    end
    if Logistics.controller(fromProv) ~= factionId then
        return false, "出发郡县不由此势力控制"
    end
    if gameState.battles and gameState.battles[fromProvinceId] then
        return false, "接战省不能调军"
    end
    if not canAttackProvince(gameState, factionId, orderTargetId or toProvinceId, fromProv.morale) then
        return false, "士气过低或战争分已达-100，不能主动进攻"
    end

    -- Verify adjacency
    local isNeighbor = false
    for _, nid in ipairs(fromProv.neighbors or {}) do
        if nid == toProvinceId then
            isNeighbor = true
            break
        end
    end
    if not isNeighbor then
        return false, "目标郡县与出发郡县不相邻"
    end

    -- Verify sufficient garrison
    if type(size) ~= "number" or size <= 0 then
        return false, "调动兵力必须大于零"
    end

    local garrison = fromProv.garrison or 0
    if garrison < size then
        return false, "驻军不足"
    end

    -- 混编（2026-09-24）：出征部队**按出发省的比例**带走兵种构成
    --   出发省 garrison 减少时，剩下的兵保持同一比例（比例表不用改）
    local UnitsData = require("data.Units")
    local marchingMix = UnitsData.mixOf(fromProv, faction)

    -- Remove from garrison
    fromProv.garrison = garrison - size

    -- Create army entry
    gameState.armies = gameState.armies or {}

    local totalHours = MIL.MOVE_DAYS * 24  -- 72 hours

    local armyEntry = {
        factionId    = factionId,
        from         = fromProvinceId,
        to           = toProvinceId,
        size         = size,
        morale       = fromProv.morale or MIL.BASE_MORALE,
        progress     = 0,          -- hours elapsed
        totalHours   = totalHours, -- hours needed to arrive
        realElapsed  = 0,          -- 现实秒数（保底行军可见时长用）
        unitMix      = marchingMix,-- 这支部队的兵种构成（行军/战斗/并入都用它）
    }

    table.insert(gameState.armies, armyEntry)

    return true, armyEntry
end

-- ============================================================================
-- 军队面板动作（2026-09-23）：停止行军 / 急行军 / 裁军
--   面板 UI 在 GameUI.createUnitPanel，这里是对应的玩法动作。
-- ============================================================================

-- ============================================================================
-- 通行权（2026-09-26 用户口径）
--
--   规则：军队只能走 **自家省 / 无主地 / 已交战的敌国**；**中立国绕开**。
--
--   为什么中立国要绕开（用户问："如果对方还没有和我们交战那应该怎么办呢"）：
--     · 军队根本不会踏进中立国 → 也就不存在"走到中立国该不该打"的问题
--     · 避免误操作：只想抄近路，结果把第三方拖进战争，很烦
--     · 符合 P 社逻辑（CK3 没通行权不能进别人领地；EU4 进中立国=宣战）
--
--   ⚠️ 本游戏目前**没有盟友/通行权系统**（只有关系值 + 交战状态），
--     所以"盟友允许通行"暂不实现；以后加外交系统再扩展 canEnterProvince。
-- ============================================================================

--- 这支军队能不能"落脚"在这个省（驻防/停留）
---   自家省 / 无主地（非废土、非海）→ 能；别人（中立或敌国）的地 → 不能
---   注意：**交战敌国也不能落脚** —— 走到那儿是打仗，不是驻防。
---@param gameState table
---@param factionId number
---@param provinceId number
---@return boolean
function MilitarySystem.canGarrisonIn(gameState, factionId, provinceId)
    local p = gameState and gameState.provinces and gameState.provinces[provinceId]
    if not p or p.isOcean or p.isWasteland then return false end
    local controller = Logistics.controller(p)
    if gameState.battles and gameState.battles[provinceId] then return false end
    -- 无主地若残留未知驻军，不能把它当作己方并兵容器。
    return controller == factionId or (controller == nil and (p.garrison or 0) <= 0)
end

--- 这支军队能不能**经过**这个省（通行权）
---   自家 / 无主 / 交战国 → 能；中立国 → 不能（寻路绕开）
---@param gameState table
---@param factionId number
---@param provinceId number
---@return boolean
function MilitarySystem.canPassThrough(gameState, factionId, provinceId)
    local p = gameState and gameState.provinces and gameState.provinces[provinceId]
    if not p or p.isOcean or p.isWasteland then return false end
    local battle = gameState.battles and gameState.battles[provinceId]
    if battle and battle.att.factionId ~= factionId and battle.def.factionId ~= factionId then
        return false -- 第三国不能通过已有战斗，更不能混入任一方。
    end
    local controller = Logistics.controller(p)
    if not controller or controller == factionId then return true end
    local DiplomacySystem = require("systems.DiplomacySystem")
    return DiplomacySystem.isAtWar(gameState, factionId, controller) == true
end

--- 从某省出发，BFS 找**最近的能落脚省**（自家 / 无主 / 我已占领）
---   用途（2026-09-26）：军队的目标被中立国占了、又不能开战时，退到这里。
---   只沿**可通行**的省走（中立国同样绕开，避免"撤退路上又踩进中立国"）。
---@param gameState table
---@param factionId number
---@param fromId number 起点（通常是那个落不了脚的目标省）
---@param maxHops number|nil 最大跳数（默认 8，防止全图乱找）
---@param controlledOnly boolean|nil 溃退只落脚己方控制省，不获取白地
---@return number|nil provinceId
function MilitarySystem._nearestGarrisonProvince(gameState, factionId, fromId, maxHops, controlledOnly)
    if not gameState or not factionId or not fromId then return nil end
    local provinces = gameState.provinces
    if not provinces or not provinces[fromId] then return nil end
    local limit = maxHops or 8
    local visited = { [fromId] = true }
    local frontier = { fromId }
    for _ = 1, limit do
        local nextF = {}
        for _, curId in ipairs(frontier) do
            local cur = provinces[curId]
            for _, nid in ipairs((cur and cur.neighbors) or {}) do
                if not visited[nid] then
                    visited[nid] = true
                    -- 先看能不能落脚（自家/无主/已占）
                    if MilitarySystem.canGarrisonIn(gameState, factionId, nid)
                        and (not controlledOnly or Logistics.controller(provinces[nid]) == factionId) then
                        return nid
                    end
                    -- 落脚不了但能经过 → 继续往外找
                    if MilitarySystem.canPassThrough(gameState, factionId, nid)
                        and not (gameState.battles and gameState.battles[nid]) then
                        nextF[#nextF + 1] = nid
                    end
                end
            end
        end
        if #nextF == 0 then break end
        frontier = nextF
    end
    return nil
end

--- 只有安全落脚成功后才能从行军表删除；白地先取得归属，统一加权并兵。
---@param gameState table
---@param army table
---@param provinceId number|nil
---@return boolean
local function garrisonArmy(gameState, army, provinceId)
    if not provinceId or not MilitarySystem.canGarrisonIn(gameState, army.factionId, provinceId) then
        return false
    end
    local faction = gameState.factions[army.factionId]
    if not faction then return false end
    local prov = gameState.provinces[provinceId]
    if not prov.ownerId then
        -- occupy 会清驻军；若白地已有本方占领驻军，保存它，不能重复占领取走旧兵。
        local before, oldMix, oldMorale = prov.garrison or 0, prov.unitMix, prov.morale
        MilitarySystem.occupy(gameState, army.factionId, provinceId)
        prov.garrison, prov.unitMix, prov.morale = before, oldMix, oldMorale
        prov.occupiedBy = nil
    end
    Logistics.mergeTroops(prov, "garrison", army, faction)
    return true
end

--- 行军中止：先验证真实军令，再选择脱战安全落脚点；找不到时保留军队。
---@param gameState table
---@param army table
---@return boolean
function MilitarySystem.stopArmy(gameState, army)
    if not gameState or not army or not gameState.armies or army.retreating or army.exiled then
        return false
    end
    local index = nil
    for i = #gameState.armies, 1, -1 do
        if gameState.armies[i] == army then index = i; break end
    end
    if not index then return false end
    local total = army.totalHours or 1
    local t = total > 0 and ((army.progress or 0) / total) or 0
    local fromId, toId = army.from or army.fromProvinceId, army.to or army.toProvinceId
    local preferred = t >= 0.5 and toId or fromId
    local alternate = t >= 0.5 and fromId or toId
    local targetId = preferred
    if not targetId or not MilitarySystem.canGarrisonIn(gameState, army.factionId, targetId) then
        targetId = alternate
    end
    if not targetId or not MilitarySystem.canGarrisonIn(gameState, army.factionId, targetId) then
        targetId = MilitarySystem._nearestGarrisonProvince(gameState, army.factionId, preferred or alternate)
    end
    if not garrisonArmy(gameState, army, targetId) then return false end
    table.remove(gameState.armies, index)
    print(string.format("[Military] 行军中止：%d 兵安全驻防（省 %s）",
        army.size or 0, tostring(targetId)))
    return true
end

--- 急行军：剩余路程压缩到 1/speed，代价 = 士气 -cost。
---@param army table
---@return boolean ok
---@return string|nil msg
function MilitarySystem.forcedMarch(army)
    if not army then return false, "没有军队" end
    if army.retreating or army.exiled then return false, "溃退或流亡军队不能急行军" end
    if army.forced then return false, "已在急行军" end
    local speed = (MIL and MIL.FORCED_MARCH_SPEED) or 1.5
    local cost  = (MIL and MIL.FORCED_MARCH_COST) or 15
    army.forced = true
    army.totalHours = math.max(1, (army.totalHours or 72) / speed)
    army.morale = math.max(0, (army.morale or (MIL and MIL.BASE_MORALE) or 100) - cost)
    print(string.format("[Military] 急行军：剩余路程压缩为 %.0f%%，士气 -%d", 100 / speed, cost))
    return true, string.format("急行军！士气 -%d", cost)
end

--- 裁军：从某省驻军遣散一部分（amount 为空/≤0 = 全部遣散）。
---@param gameState table
---@param factionId number
---@param provinceId number
---@param amount number|nil
---@return number 实际遣散数
function MilitarySystem.disbandGarrison(gameState, factionId, provinceId, amount)
    if not gameState or not factionId or not provinceId then return 0 end
    local prov = gameState.provinces[provinceId]
    local faction = gameState.factions[factionId]
    if not prov or not faction or Logistics.controller(prov) ~= factionId
        or prov.isOcean or prov.isWasteland
        or (gameState.battles and gameState.battles[provinceId]) then return 0 end
    local g = prov.garrison or 0
    local n = (amount and amount > 0) and math.min(math.floor(amount), g) or g
    if n <= 0 then return 0 end
    prov.garrison = g - n
    -- UI 和 main 均未另扣总数，此处只扣一次。
    faction.armySize = math.max(0, (faction.armySize or 0) - n)
    -- 遣散的兵**回归人口**（2026-09-25 照 AoH3：征兵时从人口抽走，解散时还回去）
    prov.population = (prov.population or 0) + n
    print(string.format("[Military] 裁军：省 %s 遣散 %d（余 %d，人口 +%d）",
        tostring(provinceId), n, prov.garrison, n))
    return n
end

-- ============================================================================
-- updateArmies(gameState, hoursElapsed, realSeconds)
--
-- Advance all in-transit armies by the given number of hours.
-- 2026-09-01：改为每帧调用（main.lua HandleUpdate），进度连续推进；
--   到达需要同时满足"游戏时长走满"与"现实时间 ≥ MIN_MARCH_REAL_SEC"，
--   保证任何速度档下都能看到军队移动过程（不瞬移）。
-- When an army reaches its destination:
--   * If the target province belongs to the same faction -> reinforce garrison
--   * If the target province belongs to an enemy         -> initiate combat
-- ============================================================================
function MilitarySystem.updateArmies(gameState, hoursElapsed, realSeconds)
    gameState.armies = gameState.armies or {}
    realSeconds = realSeconds or 0

    for i = #gameState.armies, 1, -1 do
        local army = gameState.armies[i]
        -- 和谈专用流亡军：只返回本国拥有、控制且脱战的本土，绝不抢白地或重开战。
        if army.exiled then
            local faction = gameState.factions[army.factionId]
            local homeId = faction and faction.capitalId
            local home = homeId and gameState.provinces[homeId]
            if not home or home.ownerId ~= army.factionId
                or not MilitarySystem.canGarrisonIn(gameState, army.factionId, homeId) then
                homeId = nil
                for _, pid in ipairs(Logistics.controlledProvinces(gameState, army.factionId)) do
                    local p = gameState.provinces[pid]
                    if p.ownerId == army.factionId
                        and MilitarySystem.canGarrisonIn(gameState, army.factionId, pid) then
                        homeId = pid
                        break
                    end
                end
            end
            if homeId and garrisonArmy(gameState, army, homeId) then
                table.remove(gameState.armies, i)
            end
            goto continueArmy
        end

        local toId = army.to or army.toProvinceId
        local totalHours = army.totalHours
        if not toId or not totalHours then
            -- 有兵的旧/异常军令先保留，不能因字段缺失直接删兵。
            if (army.size or 0) <= 0 then table.remove(gameState.armies, i) end
            goto continueArmy
        end
        army.progress = (army.progress or 0) + hoursElapsed
        army.realElapsed = (army.realElapsed or 0) + realSeconds
        if army.progress >= totalHours and army.realElapsed >= MIL.MIN_MARCH_REAL_SEC then
            local targetProv = gameState.provinces[toId]
            local battle = gameState.battles and gameState.battles[toId]
            -- 已有战斗先归入真正的 faction side；不能把守方援军藏进省驻军，不能混第三国。
            if battle and not army.retreating then
                if MilitarySystem.startBattle(gameState, army, targetProv, Logistics.controller(targetProv)) then
                    table.remove(gameState.armies, i)
                    goto continueArmy
                end
            elseif not army.retreating and MilitarySystem.canPassThrough(gameState, army.factionId, toId) then
                -- 保持既定规则：非战斗途经点只续军令，只有最终目标占领/接战。
                local routePath = army.routePath
                if routePath and #routePath > 1 then
                    local nextId = routePath[2]
                    if MilitarySystem.canPassThrough(gameState, army.factionId, nextId) then
                        local rest = {}
                        for k = 2, #routePath do rest[#rest + 1] = routePath[k] end
                        army.from, army.to = toId, nextId
                        army.progress, army.realElapsed = 0, 0
                        army.totalHours = MIL.MOVE_DAYS * 24
                        army.routePath = rest
                        army._blocked = nil
                        goto continueArmy
                    end
                    -- 下一跳变成中立/不可通行：当前省安全则就地收兵，否则走安全撤回。
                else
                    if garrisonArmy(gameState, army, toId)
                        or (targetProv and canAttackProvince(gameState, army.factionId, toId, army.morale)
                            and MilitarySystem.startBattle(gameState, army, targetProv, Logistics.controller(targetProv))) then
                        table.remove(gameState.armies, i)
                        goto continueArmy
                    end
                end
            elseif army.retreating and Logistics.controller(targetProv) == army.factionId
                and garrisonArmy(gameState, army, toId) then
                table.remove(gameState.armies, i)
                goto continueArmy
            end

            -- 目标易手/第三方接战/不能进攻时安全撤回；找不到则保留原军令和兵力等待。
            local retreatTo = nil
            if MilitarySystem.canGarrisonIn(gameState, army.factionId, toId)
                and (not army.retreating or Logistics.controller(targetProv) == army.factionId) then
                retreatTo = toId
            else
                retreatTo = MilitarySystem._nearestGarrisonProvince(gameState, army.factionId, toId,
                    nil, army.retreating == true)
                local fromId = army.from or army.fromProvinceId
                if not retreatTo and fromId
                    and MilitarySystem.canGarrisonIn(gameState, army.factionId, fromId)
                    and (not army.retreating
                        or Logistics.controller(gameState.provinces[fromId]) == army.factionId) then
                    retreatTo = fromId
                end
            end
            if garrisonArmy(gameState, army, retreatTo) then
                local pName = targetProv and targetProv.name or tostring(toId)
                local rName = gameState.provinces[retreatTo].name or tostring(retreatTo)
                print(string.format("[Military] 目标 %s 无法停留/接战，%d 兵安全退往 %s",
                    pName, army.size or 0, rName))
                if gameState.addMessage then
                    gameState.addMessage(string.format("目标 %s 无法停留，我军退往 %s", pName, rName), "military")
                end
                table.remove(gameState.armies, i)
            elseif not army._blocked then
                army._blocked = true
                print(string.format("[Military] 省 %s 无安全落脚点，保留 %d 兵军令等待",
                    tostring(toId), army.size or 0))
            end
        end
        ::continueArmy::
    end
end

-- ============================================================================
-- startBattle(gameState, army, targetProv, targetOwner)
--
-- 军队到达敌省：进入持续战斗（HoI4 式进度战斗，2026-09-01）
--   * 同省已有战斗则兵力并入相应方
--   * 新战斗：防守方驻军转入战斗（战斗中驻军由战斗对象接管）
-- ============================================================================
---@return boolean accepted 仅成功入驻或接战时消费行军军令
function MilitarySystem.startBattle(gameState, army, targetProv, targetOwner)
    if not gameState or not army or not targetProv or army.retreating or army.exiled then return false end
    local faction = gameState.factions[army.factionId]
    if not faction or (army.size or 0) <= 0 then return false end
    gameState.battles = gameState.battles or {}
    local pid = targetProv.id
    local UnitsData = require("data.Units")
    local b = gameState.battles[pid]
    if b then
        -- 同 faction 援军才并入；第三国返回 false，调用方必须保留其军令。
        local side = b.att.factionId == army.factionId and b.att
            or (b.def.factionId == army.factionId and b.def or nil)
        if not side then return false end
        side.initialSize = (side.initialSize or side.size or 0) + army.size
        Logistics.mergeTroops(side, "size", army, faction)
        return true
    end

    local defenderId = Logistics.controller(targetProv)
    if not defenderId or defenderId == army.factionId then
        return garrisonArmy(gameState, army, pid)
    end
    if not MilitarySystem.canPassThrough(gameState, army.factionId, pid)
        or not canAttackProvince(gameState, army.factionId, pid, army.morale) then return false end
    local defFac = gameState.factions[defenderId]
    if not defFac then return false end
    local defSize = targetProv.garrison or 0
    gameState.battles[pid] = {
        att = { factionId = army.factionId, size = army.size, initialSize = army.size,
                morale = army.morale or MIL.BASE_MORALE,
                unitMix = UnitsData.normalizeMix(army.unitMix, UnitsData.mainOf(faction).id) },
        def = { factionId = defenderId, size = defSize, initialSize = defSize,
                morale = targetProv.morale or MIL.BASE_MORALE,
                unitMix = UnitsData.mixOf(targetProv, defFac) },
        progress = 0,
        accHours = 0,
    }
    targetProv.garrison = 0
    local pf = gameState.playerFactionId
    if pf and (army.factionId == pf or defenderId == pf) and gameState.addMessage then
        gameState.addMessage(string.format("%s进攻%s %s！",
            faction.name or "?", defFac.name or "?", targetProv.name or "?"), "war", true)
    end
    return true
end

-- ============================================================================
-- retreat(gameState, factionId, size, fromProvinceId, morale)
--
-- 溃退（2026-09-13，照 P 社）：战斗里士气崩溃的一方带着**残兵**撤到相邻的己方省份。
--   * 撤退部队 = 一条普通行军记录 + retreating=true（行军更慢、且不能被再次派遣）
--   * 到达后并入该省驻军（走 updateArmies 的既有逻辑）
--   * **无路可退**（周边没有己方省 / 己方省正在交战）→ 返回 false，调用方按"被全歼"处理
-- ============================================================================
---@param gameState table
---@param factionId number
---@param size number
---@param fromProvinceId number
---@param morale number|nil
---@param mix table|nil 溃兵的兵种构成（不传 = 按势力主力兵种兜底）
---@return boolean ok
---@return number|nil targetProvinceId
function MilitarySystem.retreat(gameState, factionId, size, fromProvinceId, morale, mix)
    if not gameState or not factionId or (size or 0) <= 0 then return false end
    local from = gameState.provinces and gameState.provinces[fromProvinceId]
    if not from or not from.neighbors then return false end
    local battles = gameState.battles or {}

    -- 就近找己方省：BFS，最多 ROUT_RETREAT_RANGE 跳（照 P 社"撤到最近的己方省"；
    -- 严格"必须相邻"太苛刻——很多省四周全是敌国，会导致本可撤退的部队被白白全歼）
    local range = MIL.ROUT_RETREAT_RANGE or 3
    local visited = { [fromProvinceId] = true }
    local frontier = { fromProvinceId }
    local best, bestDepth, bestGarrison = nil, nil, -1
    for depth = 1, range do
        local nextFrontier = {}
        for _, curId in ipairs(frontier) do
            local cur = gameState.provinces[curId]
            for _, nid in ipairs((cur and cur.neighbors) or {}) do
                if not visited[nid] then
                    visited[nid] = true
                    local np = gameState.provinces[nid]
                    if np and MilitarySystem.canPassThrough(gameState, factionId, nid) and not battles[nid] then
                        nextFrontier[#nextFrontier + 1] = nid
                        if Logistics.controller(np) == factionId then
                            local g = np.garrison or 0
                            if (not best) or depth < bestDepth
                               or (depth == bestDepth and g > bestGarrison) then
                                best, bestDepth, bestGarrison = nid, depth, g
                            end
                        end
                    end
                end
            end
        end
        if best then break end          -- 已找到最近一跳的候选就不用再往外找
        frontier = nextFrontier
        if #frontier == 0 then break end
    end

    if not best then
        return false                    -- 无路可退 → 调用方按"被全歼"处理
    end

    gameState.armies = gameState.armies or {}
    table.insert(gameState.armies, {
        factionId   = factionId,
        from        = fromProvinceId,
        to          = best,
        size        = size,
        morale      = math.max(0, morale or 0),
        progress    = 0,
        totalHours  = MIL.ROUT_RETREAT_HOURS or 96,
        realElapsed = 0,
        retreating  = true,     -- 溃退中（保留标记：以后可用于"不能再被派遣/士气恢复"）
        -- 混编：溃兵保留被打散前的兵种构成
        unitMix     = mix,
    })
    return true, best
end

-- ============================================================================
-- processBattles(gameState, hoursElapsed)
--
-- 每帧推进所有进行中的战斗（main.lua HandleUpdate 调用）：
--   * **按游戏"天"结算**（每满 BATTLE_TICK_HOURS 一轮）：兵力每天都在掉（每方至少 1）
--     —— 修掉"数字不动、然后敌人一次全没"的老毛病（老代码按帧 floor，小部队恒为 0 损失）
--   * 士气按"当日受创比例"下降；**士气崩溃 → 溃退**（带残兵撤到相邻己方省，无路可退才被全歼）
--   * progress 仍在推进，但只用于战报/战争分数，不再决定全歼
--   * 攻击方胜 → 占领该省并留驻；防守方胜 → 保住该省
--   * 仅玩家参战时写消息（AI 互打不刷屏）
-- ============================================================================
-- 日伤亡、追击和无路全歼共用记账；军队/战斗对象的 size 由调用点提交。
---@param gameState table
---@param battle table
---@param attLoss number
---@param defLoss number
local function recordBattleLosses(gameState, battle, attLoss, defLoss)
    local atkFac, defFac = gameState.factions[battle.att.factionId], gameState.factions[battle.def.factionId]
    if atkFac then atkFac.armySize = math.max(0, (atkFac.armySize or 0) - attLoss) end
    if defFac then defFac.armySize = math.max(0, (defFac.armySize or 0) - defLoss) end
    if attLoss > 0 or defLoss > 0 then
        require("systems.WarSystem").recordCasualties(gameState,
            battle.att.factionId, battle.def.factionId, attLoss, defLoss)
    end
end

-- 平局是双方退战而非守方获胜：留住防线，攻方撤走；无路时保留等待军令。
---@param gameState table
---@param province table
---@param pid number
---@param battle table
---@param reason string
local function finishDraw(gameState, province, pid, battle, reason)
    local Units = require("data.Units")
    gameState.battles[pid] = nil
    province.garrison = battle.def.size
    province.morale = battle.def.morale or MIL.BASE_MORALE
    province.unitMix = Units.normalizeMix(battle.def.unitMix,
        Units.mainOf(gameState.factions[battle.def.factionId]).id)
    -- 不改 ownerId/occupiedBy：平局守方保留原军事控制权。
    local routed, retreatTo = false, nil
    if battle.att.size > 0 then
        routed, retreatTo = MilitarySystem.retreat(gameState, battle.att.factionId,
            battle.att.size, pid, battle.att.morale, battle.att.unitMix)
        if not routed then
            gameState.armies = gameState.armies or {}
            gameState.armies[#gameState.armies + 1] = {
                factionId = battle.att.factionId, from = pid, to = pid,
                size = battle.att.size, morale = battle.att.morale or MIL.BASE_MORALE,
                unitMix = battle.att.unitMix, progress = 0, realElapsed = 0,
                totalHours = MIL.ROUT_RETREAT_HOURS or 96, retreating = true,
            }
        end
    end
    local pf = gameState.playerFactionId
    if pf and (battle.att.factionId == pf or battle.def.factionId == pf) and gameState.addMessage then
        local suffix = routed and "，攻方撤退，守方留守"
            or (battle.att.size > 0 and "，攻方暂无退路，残兵等待撤回" or "")
        gameState.addMessage(string.format("%s之战平局，双方脱战%s", province.name or "?", suffix), "war", true)
    end
    Hooks.fire("battle_end", {
        gameState = gameState, provinceId = pid, draw = true, reason = reason,
        wiped = false, routed = routed, retreatTo = retreatTo,
        attackerId = battle.att.factionId, defenderId = battle.def.factionId,
    })
end

function MilitarySystem.processBattles(gameState, hoursElapsed)
    if not gameState.battles then return end

    for pid, b in pairs(gameState.battles) do
        local province = gameState.provinces[pid]
        if not province then
            gameState.battles[pid] = nil
            goto continueBattle
        end

        -- ===== 按"游戏天"结算（2026-09-13 改，照 P 社）=====
        -- 原来按帧结算：损失 = floor(比例×兵力×0.3×天数)，小部队每帧算出来都是 0
        -- → 数字纹丝不动，直到进度条走满才把输方剩余兵力一次性清零（"敌人突然全消失"）
        b.accHours = (b.accHours or 0) + hoursElapsed
        local rounds = math.min(24, math.floor(b.accHours / MIL.BATTLE_TICK_HOURS))
        if rounds <= 0 then
            goto continueBattle                 -- 还没到结算时刻
        end
        -- 只扣实际允许处理的轮数，卡顿/快进的剩余小时留给后续更新。
        b.accHours = b.accHours - rounds * MIL.BATTLE_TICK_HOURS

        local terrainMod = TERRAIN_DEFENSE[province.terrain] or 1.0
        local atkFac = gameState.factions[b.att.factionId]
        local defFac = gameState.factions[b.def.factionId]

        -- 兵种（2026-09-19 第三版：数值整套照 CK3）：
        --   战力 = (兵力 / 每团人数) × 伤害(攻)/坚韧(守) × 相克 —— 每轮按当时兵力重算
        local Units = require("data.Units")
        -- 洞 4：改成读管道（君主/政策已经在上面注册成 scale 规则 → 乘积和原来一样）
        --   好处：模组/事件/资源往 militaryPower / defensePower 挂规则**立刻生效**
        local atkMod = Modifiers.applyFloat(1.0, "faction", "militaryPower",
            { gameState = gameState, faction = atkFac })
        local defMod = Modifiers.applyFloat(1.0, "faction", "militaryPower",
            { gameState = gameState, faction = defFac })
            * Modifiers.applyFloat(1.0, "faction", "defensePower",
                { gameState = gameState, faction = defFac })

        -- 旧战斗没有初始规模时以本次处理前兵力兜底，之后援军仍累计。
        b.att.initialSize = b.att.initialSize or b.att.size
        b.def.initialSize = b.def.initialSize or b.def.size
        local ended, winner, loser = false, nil, nil
        local routSide = nil
        local wiped, draw, reason = false, false, ""

        for _ = 1, rounds do
            -- CK3 口径战力：兵种伤害/坚韧 × 兵力 × 士气 × 修正（相克已含在 Units.power 里）
            --   混编（2026-09-24）：按双方**真实兵种构成**逐兵种加权，相克也逐兵种算
            local atkStr = Units.power(atkFac, defFac, b.att.size, false, b.att.unitMix, b.def.unitMix)
                * (b.att.morale or MIL.BASE_MORALE) / 100 * atkMod
            local defStr = Units.power(defFac, atkFac, b.def.size, true, b.def.unitMix, b.att.unitMix)
                * (b.def.morale or MIL.BASE_MORALE) / 100 * terrainMod * defMod
            local result = CombatRules.resolveRound(b.att, b.def, atkStr, defStr, MIL)
            -- 同一战前快照推导的双方兵力、士气同时提交，再统一扣总账/记战损。
            b.att.size, b.def.size = result.attSize, result.defSize
            b.att.morale, b.def.morale = result.attMorale, result.defMorale
            recordBattleLosses(gameState, b, result.attLoss, result.defLoss)
            b.progress = math.max(-1, math.min(1, (b.progress or 0) + result.progressDelta))
            if result.outcome then
                ended, reason, wiped = true, result.reason, result.wiped
                if result.outcome == "draw" then
                    draw = true
                else
                    local attWins = result.outcome == "att"
                    winner = attWins and b.att.factionId or b.def.factionId
                    loser = attWins and b.def.factionId or b.att.factionId
                    if result.routSide ~= "" then routSide = result.routSide end
                end
            end
            if ended then break end
        end

        if ended then
            if draw then
                finishDraw(gameState, province, pid, b, reason)
                goto continueBattle
            end
            gameState.battles[pid] = nil

            -- ===== 结果落地（2026-09-13）：占领/驻军 + 溃退（能撤就撤，撤不走才被歼）=====
            local loserIsAtt = (loser == b.att.factionId)
            local loserSize = loserIsAtt and b.att.size or b.def.size
            local loserMorale = loserIsAtt and (b.att.morale or 0) or (b.def.morale or 0)

            -- ===== 撤退阶段：追击 vs 掩护（2026-09-19 照 CK3）=====
            --   CK3 口径：追击每点造成 0.17 伤害、掩护每点挡掉 0.33 伤害。
            --   打赢的一方在溃兵逃跑路上继续杀伤 —— 这是"歼灭战"的来源；
            --   逃跑方按自己的**掩护**属性减免（长枪兵掩护 20 最能保命）。
            local winnerIsAtt = (winner == b.att.factionId)
            local winnerSize = winnerIsAtt and b.att.size or b.def.size
            local winnerMix  = winnerIsAtt and b.att.unitMix or b.def.unitMix
            local loserMix   = winnerIsAtt and b.def.unitMix or b.att.unitMix
            local winnerFac = gameState.factions[winner]
            local loserFac = gameState.factions[loser]
            local pursuitLoss = math.floor(Units.retreatLoss(winnerFac, loserFac, winnerSize, loserSize,
                winnerMix, loserMix))
            pursuitLoss = math.min(pursuitLoss, loserSize)      -- 不能超过残余兵力
            if pursuitLoss >= 1 then
                loserSize = loserSize - pursuitLoss
                recordBattleLosses(gameState, b,
                    loserIsAtt and pursuitLoss or 0, loserIsAtt and 0 or pursuitLoss)
                if loserIsAtt then b.att.size = loserSize else b.def.size = loserSize end
            end
            province.occupiedBy = winner ~= province.ownerId and winner or nil
            if winner == b.att.factionId then
                -- 攻方胜：控制该省（不立即吞并，和约再割让）
                province.garrison = b.att.size
                -- 混编：该省驻军从此按**胜方残兵**的兵种构成（旧构成随原驻军一起打没了）
                province.unitMix = Units.normalizeMix(b.att.unitMix,
                    Units.mainOf(gameState.factions[b.att.factionId]).id)
                -- 驻军士气（2026-09-26）：胜方带着自己打剩的士气驻防
                province.morale = b.att.morale or MIL.BASE_MORALE
            else
                -- 守方胜：保住当前控制权（包括守住原占领省），攻方残兵溃退
                province.garrison = b.def.size
                province.unitMix = Units.normalizeMix(b.def.unitMix,
                    Units.mainOf(gameState.factions[b.def.factionId]).id)
                -- 驻军士气（2026-09-26）：守住了，但士气是打剩的那个值
                province.morale = b.def.morale or MIL.BASE_MORALE
            end

            local routed, retreatTo = false, nil
            if not wiped and routSide and loserSize > 0 then
                -- 混编：溃兵带上自己这边的兵种构成
                local loserMix = loserIsAtt and b.att.unitMix or b.def.unitMix
                local ok, targetId = MilitarySystem.retreat(gameState, loser, loserSize, pid, loserMorale,
                    loserMix)
                if ok then
                    routed, retreatTo = true, targetId
                else
                    wiped = true            -- 无路可退 → 全歼
                end
            end
            if wiped and loserSize > 0 then
                -- 只追加此前未扣的残兵；日结算与追击已经各记过一次。
                recordBattleLosses(gameState, b,
                    loserIsAtt and loserSize or 0, loserIsAtt and 0 or loserSize)
                if loserIsAtt then b.att.size = 0 else b.def.size = 0 end
            end

            -- 空军没有真正交战：不刷胜负威望或战斗分。
            if winner and loser and reason ~= "empty" then
                local wFac = gameState.factions[winner]
                local lFac = gameState.factions[loser]
                if wFac then wFac.prestige = (wFac.prestige or 0) + 8 end
                if lFac then lFac.prestige = math.max(0, (lFac.prestige or 0) - 8) end
                local loserInitialSize = loserIsAtt and b.att.initialSize or b.def.initialSize
                require("systems.WarSystem").recordBattle(gameState, winner, loser, loserInitialSize)
            end

            -- 战斗俘获人才（2026-09-28 用户："战斗俘获人才"）
            --   打赢的一方有概率招降对方一个**低忠诚**人物（忠诚高的人不背主）。
            --   只对玩家参战的战斗发消息，AI 互打不刷屏。
            if winner and loser and wiped and reason ~= "empty" then
                local CS = require("systems.CharacterSystem")
                local wf = gameState.factions[winner]
                local lf = gameState.factions[loser]
                if wf and lf and lf.characters then
                    -- 挑一个忠诚最低、且不是君主的
                    local pick, pickLoy = nil, 999
                    for _, c in ipairs(lf.characters) do
                        if c.alive ~= false and c.post ~= "君主" then
                            local loy = c.loyalty or 60
                            if loy < 45 and loy < pickLoy then pick, pickLoy = c, loy end
                        end
                    end
                    -- 30% 概率真的招降（不是每场都有）
                    if pick and math.random() < 0.30 then
                        for i = #lf.characters, 1, -1 do
                            if lf.characters[i].id == pick.id then table.remove(lf.characters, i) end
                        end
                        pick.factionId = winner
                        pick.loyalty = math.random(45, 65)      -- 降将忠诚不高
                        pick.post = nil
                        pick.rank = nil
                        pick.titleFrom = "降将"
                        wf.characters = wf.characters or {}
                        wf.characters[#wf.characters + 1] = pick
                        if gameState.addMessage and gameState.playerFactionId == winner then
                            gameState.addMessage(string.format("敌军 %s 阵前归降！", tostring(pick.name)),
                                "military")
                        end
                        print(string.format("[Military] 俘获招降：%s 从 %s 转投 %s",
                            tostring(pick.name), tostring(lf.name), tostring(wf.name)))
                    end
                end
            end
            -- 玩家参战：战斗结束消息 + 战争警报
            local pf = gameState.playerFactionId
            if pf and (b.att.factionId == pf or b.def.factionId == pf) then
                local wName = (gameState.factions[winner] or {}).name or "?"
                local lName = (gameState.factions[loser] or {}).name or "?"
                local provName = province.name or "?"
                local playerLostProvince = b.def.factionId == pf and winner == b.att.factionId
                local msg = string.format("%s之战结束，%s战胜%s", provName, wName, lName)
                if winner == pf then
                    msg = msg .. "（我军胜利！"
                else
                    msg = msg .. "（我军失利"
                end
                if routed and retreatTo then
                    local rName = (gameState.provinces[retreatTo] or {}).name or "?"
                    msg = msg .. string.format("，%s溃退至%s", winner == pf and "敌军" or "我军", rName)
                elseif wiped then
                    msg = msg .. (winner == pf and "，敌军被全歼" or "，我军被全歼")
                end
                msg = msg .. "）"
                if playerLostProvince then
                    msg = msg .. "（领地失守）"
                end
                -- 2026-09-18：战争警报弹框已删 → 只发通知（右上角通知条）
                --   括号里的提示在通知条上会被省略（条上只留摘要），点开详情/日志能看全
                msg = msg .. "（可点右下角战旗议和）"
                if gameState.addMessage then gameState.addMessage(msg, "war", true) end
            end

            -- 脚本钩子（2026-09-13）：一场仗打完了
            Hooks.fire("battle_end", {
                gameState = gameState,
                provinceId = pid,
                winnerId = winner,
                loserId = loser,
                wiped = wiped,
                routed = routed,
                retreatTo = retreatTo,
                attackerId = b.att.factionId,
                defenderId = b.def.factionId,
            })
        end

        ::continueBattle::
    end
end


-- ============================================================================
-- occupy(gameState, factionId, provinceId)
--
-- Transfer ownership of a province to a new faction.
--   * Removes the province from the old faction's provinces list
--   * Adds the province to the new faction's provinces list
--   * Updates province.ownerId to the new faction
--   * Drops province stability to 30
--   * Checks if the old faction has lost all provinces (elimination)
-- ============================================================================
function MilitarySystem.occupy(gameState, factionId, provinceId)
    local newFaction = gameState.factions[factionId]
    if not newFaction then return end

    local province = gameState.provinces[provinceId]
    local oldFactionId = province and province.ownerId or nil

    -- Remove from old faction
    if oldFactionId then
        local oldFaction = gameState.factions[oldFactionId]
        if oldFaction then
            for i = #oldFaction.provinces, 1, -1 do
                if oldFaction.provinces[i] == provinceId then
                    table.remove(oldFaction.provinces, i)
                    break
                end
            end
        end
        -- Update reverse index
        if gameState.factionProvinces and gameState.factionProvinces[oldFactionId] then
            local idx = gameState.factionProvinces[oldFactionId]
            for i = #idx, 1, -1 do
                if idx[i] == provinceId then
                    table.remove(idx, i)
                    break
                end
            end
        end
    end

    -- Add to new faction (avoid duplicate)
    local alreadyOwned = false
    for _, pid in ipairs(newFaction.provinces) do
        if pid == provinceId then
            alreadyOwned = true
            break
        end
    end
    if not alreadyOwned then
        table.insert(newFaction.provinces, provinceId)
    end
    -- Update reverse index
    if gameState.factionProvinces then
        if not gameState.factionProvinces[factionId] then
            gameState.factionProvinces[factionId] = {}
        end
        local idx = gameState.factionProvinces[factionId]
        local found = false
        for _, pid in ipairs(idx) do
            if pid == provinceId then found = true; break end
        end
        if not found then
            idx[#idx + 1] = provinceId
        end
    end

    -- Update province ownership in runtime state
    if province then
        province.ownerId = factionId
        -- ⚠️ 无主地占领必须**清掉 garrison**（2026-09-26 用户："无主之地…既然敌方国家
        --   已经到了这个地方为什么没有被占领"）：
        --   无主地按设计 garrison = 0（GameState 开局就是 0），但若这里不清，
        --   就会留下 ownerId=nil + garrison>0 的**自相矛盾**状态 ——
        --   地图画成灰色（按 ownerId 上色）却还挂着 "?" + 兵力数字的旗标，
        --   看起来像"无主但有守军"，谁也占不了。
        --   占领后驻军由**占领方的兵力**决定（见 updateArmies 里并入的那支军队）。
        province.garrison = 0
    end

    -- Province stability drops to 30 upon occupation
    if province then
        province.stability = 30
    end

    -- Check if old faction is eliminated (no provinces left)
    if oldFactionId and oldFactionId ~= factionId then
        local oldFaction = gameState.factions[oldFactionId]
        if oldFaction and #oldFaction.provinces == 0 then
            gameState.eliminatedFactions = gameState.eliminatedFactions or {}
            gameState.eliminatedFactions[oldFactionId] = true

            -- Record elimination event
            gameState.events = gameState.events or {}
            table.insert(gameState.events, {
                type    = "faction_eliminated",
                faction = oldFactionId,
                by      = factionId,
                name    = oldFaction.fullName or oldFaction.name,
            })
        end
    end

    -- 脚本钩子（2026-09-13）：一个省易主了
    Hooks.fire("province_conquered", {
        gameState = gameState,
        provinceId = provinceId,
        factionId = factionId,
        fromFactionId = oldFactionId,
    })
end

-- ============================================================================
-- getArmyStrength(factionId, gameState)
--
-- Calculate the total military strength of a faction, accounting for:
--   * Standing army size
--   * Armies currently in transit
--   * Garrison distribution
--
-- Returns: a table with detailed breakdown
-- ============================================================================
function MilitarySystem.getArmyStrength(factionId, gameState)
    local faction = gameState.factions[factionId]
    if not faction then
        return { total = 0, standing = 0, marching = 0, garrisons = {} }
    end

    -- Total army from faction record
    local standing = faction.armySize

    -- Count soldiers currently marching
    local marching = 0
    gameState.armies = gameState.armies or {}
    for _, army in ipairs(gameState.armies) do
        if army.factionId == factionId then
            marching = marching + army.size
        end
    end

    -- 驻军属于军事控制方，不能把被敌占的本国省算成自己的兵。
    local garrisonDetails = {}
    for _, pid in ipairs(Logistics.controlledProvinces(gameState, factionId)) do
        local prov = gameState.provinces[pid]
        garrisonDetails[pid] = prov and prov.garrison or 0
    end

    -- Total garrison
    local totalGarrison = 0
    for _, g in pairs(garrisonDetails) do
        totalGarrison = totalGarrison + g
    end

    return {
        total      = standing,
        standing   = standing,
        marching   = marching,
        garrison   = totalGarrison,
        garrisons  = garrisonDetails,
    }
end

return MilitarySystem

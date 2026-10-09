-- ============================================================================
-- 春秋霸业 - 君主系统
-- systems/LeaderSystem.lua
--
-- 为每个势力维护一位君主（治国者）：
--   * 开局生成：15 诸侯大国用春秋历史君主，蛮族/小国随机酋长
--   * 三项能力 1~5：文治(admin) 影响经济收入，武功(military) 影响战斗力，
--     外交(diplo) 影响改善关系速度
--   * 每年年龄 +1，按年龄概率死亡，死后生成继承人
--   * 君主数据挂在 gameState.factions[fid].leader 上，随存档保存/恢复
-- ============================================================================

local LeaderSystem = {}

-- =========================================================================
-- 历史君主表（开局，势力 id -> {name, age, admin, diplo, military}）
-- 时代为春秋早期（前770年前后），部分君主为简化/游戏化处理
-- =========================================================================
local HISTORICAL_LEADERS = {
    [1]  = { name = "姬宜臼", title = "周平王",  age = 50, admin = 4, diplo = 4, military = 2 },  -- 周
    [2]  = { name = "姜购",   title = "齐庄公",  age = 40, admin = 3, diplo = 3, military = 4 },  -- 齐
    [3]  = { name = "姬仇",   title = "晋文侯",  age = 40, admin = 4, diplo = 3, military = 5 },  -- 晋
    [4]  = { name = "熊仪",   title = "楚若敖",  age = 55, admin = 3, diplo = 2, military = 4 },  -- 楚
    [5]  = { name = "嬴开",   title = "秦襄公",  age = 50, admin = 3, diplo = 3, military = 5 },  -- 秦
    [6]  = { name = "姬称",   title = "鲁孝公",  age = 55, admin = 4, diplo = 4, military = 2 },  -- 鲁
    [7]  = { name = "子白",   title = "宋戴公",  age = 45, admin = 3, diplo = 4, military = 2 },  -- 宋
    [8]  = { name = "姬和",   title = "卫武公",  age = 70, admin = 4, diplo = 5, military = 3 },  -- 卫
    [9]  = { name = "姬掘突", title = "郑武公",  age = 35, admin = 4, diplo = 4, military = 4 },  -- 郑
    [10] = { name = "姬郑",   title = "燕哀侯",  age = 45, admin = 2, diplo = 3, military = 2 },  -- 燕
    [11] = { name = "姬光",   title = "吴君",    age = 50, admin = 2, diplo = 2, military = 3 },  -- 吴
    [12] = { name = "姒无余", title = "越君",    age = 50, admin = 2, diplo = 2, military = 3 },  -- 越
    [13] = { name = "姬所事", title = "蔡厘侯",  age = 45, admin = 3, diplo = 3, military = 2 },  -- 蔡
    [14] = { name = "妫燮",   title = "陈平公",  age = 50, admin = 3, diplo = 4, military = 2 },  -- 陈
    [15] = { name = "姬雉",   title = "曹惠伯",  age = 50, admin = 3, diplo = 3, military = 3 },  -- 曹
}

-- 诸侯国姓氏（继承时生成新君名用）
local SURNAMES = {
    [1]  = "姬",  -- 周
    [2]  = "姜",  -- 齐
    [3]  = "姬",  -- 晋
    [4]  = "熊",  -- 楚
    [5]  = "嬴",  -- 秦
    [6]  = "姬",  -- 鲁
    [7]  = "子",  -- 宋
    [8]  = "姬",  -- 卫
    [9]  = "姬",  -- 郑
    [10] = "姬",  -- 燕
    [11] = "姬",  -- 吴
    [12] = "姒",  -- 越
    [13] = "姬",  -- 蔡
    [14] = "妫",  -- 陈
    [15] = "姬",  -- 曹
    [16] = "隗",  -- 赤狄
    [17] = "隗",  -- 白狄
    [19] = "戎",  -- 山戎
    [20] = "戎",  -- 犬戎
    [21] = "胡",  -- 东胡
    [22] = "胡",  -- 林胡
    [23] = "胡",  -- 楼烦
    [24] = "巴",  -- 巴
    [25] = "蜀",  -- 蜀
    [26] = "越",  -- 百越
    [27] = "蛮",  -- 南蛮
}

-- 通用名表（新君随机取名）
local GENERIC_NAMES = {
    "重耳", "夷吾", "纠", "弃疾", "围", "比", "椒", "无忌", "克", "午",
    "醜", "晏", "婴", "驷", "胜", "越", "光", "夫差", "椒丘", "寿梦",
    "札", "偃师", "御说", "杵臼", "昭", "悼", "弘", "敖", "麇", "商臣",
    "壬", "莒", "彭", "爽", "邃", "骊", "骃", "骐", "骆", "驹",
}

-- =========================================================================
-- 内部工具
-- =========================================================================

--- 随机生成 1~5 能力值（10% 概率 5，20% 概率 4，否则 2~3）
---@return integer
local function rollAbility()
    local r = math.random()
    if r < 0.1 then
        return 5
    elseif r < 0.3 then
        return 4
    elseif r < 0.65 then
        return 3
    else
        return 2
    end
end

--- 生成一个随机继承人
---@param factionId number
---@return table leader
local function generateHeir(factionId)
    local surname = SURNAMES[factionId] or "姬"
    local name = GENERIC_NAMES[math.random(#GENERIC_NAMES)]
    return {
        name     = surname .. name,
        age      = math.random(18, 35),
        admin    = rollAbility(),
        diplo    = rollAbility(),
        military = rollAbility(),
    }
end

--- 旧君主去世：标记死亡并从角色表移出（2026-09-29）
---   ⚠️ **保留** f.leaderId 之外的信息：childIds 在角色对象上，
---   移出列表不影响"子女还能找到父亲"（getById 走 id 索引，不依赖列表）。
---   为什么要移出：不然朝廷面板/人才列表里会一直挂着已死的人。
---@param gameState table
---@param factionId number
function LeaderSystem._removeRulerFromCharacters(gameState, factionId)
    local f = gameState and gameState.factions and gameState.factions[factionId]
    if not f or not f.leaderId then return end
    local list = f.characters
    if list then
        for i = #list, 1, -1 do
            if list[i].id == f.leaderId then
                list[i].alive = false
                list[i].post = nil
                -- ⚠️ 只从**活人列表**移出，**全局索引仍保留**（2026-09-29）：
                --   血脉追溯要靠 getById 找父辈。如果索引也删了，
                --   子女的 parentId 就查不到对象 → 继承顺序算不出血缘 → 断链。
                table.remove(list, i)
                break
            end
        end
    end
    -- 注意：**不清空 f.leaderId** —— CharacterSystem.getById 靠它查旧君主，
    --   而 applySuccession 之后会把它改指向新君。这里只负责"人不在列表里"。
end

--- 君主更替后，把新君同步进 CharacterSystem 的角色表（2026-09-28）
---   做三件事：
---     ① 旧君主角色标记 alive=false 并移出列表（别让死人留在朝廷里）
---     ② 按新 leader 造一份角色（五维来自 leader 的 admin/diplo/military）
---     ③ 回写 f.leaderId 指向新角色
---   容错：CharacterSystem 未初始化 / 没开人物系统 → 静默跳过（不阻断继位）。
---@param gameState table
---@param factionId number
function LeaderSystem._syncHeirToCharacters(gameState, factionId)
    local ok, CharacterSystem = pcall(require, "systems.CharacterSystem")
    if not ok or not CharacterSystem then return end
    local f = gameState and gameState.factions and gameState.factions[factionId]
    if not f or not f.leader then return end

    -- ① 旧君主角色：标记死亡 + 移出列表
    if f.leaderId then
        local list = f.characters
        if list then
            for i = #list, 1, -1 do
                if list[i].id == f.leaderId then
                    list[i].alive = false
                    list[i].post = nil
                    table.remove(list, i)
                    break
                end
            end
        end
        f.leaderId = nil
    end

    -- ② 新君角色（五维口径与 ensureInit 里保持一致）
    local l = f.leader
    local newId = CharacterSystem._nextId or 1
    CharacterSystem._nextId = newId + 1
    local heir = {
        id = newId,
        name = l.name,
        titleFrom = "国君",
        age = l.age or 25,
        gender = "男",
        diplomacy  = l.diplo or 3,
        military   = l.military or 3,
        management = l.admin or 3,
        intrigue   = math.random(2, 4),
        learning   = math.random(2, 4),
        loyalty = 100,
        factionId = factionId,
        post = "君主",
        alive = true,
    }
    l.intrigue = heir.intrigue
    l.learning = heir.learning
    local okT, Traits = pcall(require, "data.Traits")
    if okT and Traits then
        Traits.roll(heir, 2)
        Traits.applyAttrs(heir)
    end
    f.characters = f.characters or {}
    f.characters[#f.characters + 1] = heir
    -- ③ 回写关联 id
    f.leaderId = newId
end

--- 按年龄计算每年死亡概率
---@param age number
---@return number
local function deathChance(age)
    if age >= 60 then return 0.15 end
    if age >= 50 then return 0.08 end
    if age >= 40 then return 0.03 end
    -- 幼主保护（2026-09-29）：未成年君主**死亡概率减半**
    --   为什么：实测出现"Y117→123→129 连续三个幼主继位"——幼主在位几年就死，
    --   下一任更小，恶性循环。史实上幼主也常有摄政庇护，这里用概率体现。
    --   （真正的摄政系统以后再做；先保证王朝不会在几代幼主里断掉）
    if age < 16 then return 0.005 end
    return 0.01
end

--- 取势力名称（容错）
---@param gameState table
---@param factionId number
---@return string
local function factionName(gameState, factionId)
    local f = gameState.factions[factionId]
    return f and (f.fullName or f.name) or ("势力#" .. tostring(factionId))
end

-- =========================================================================
-- 公共 API
-- =========================================================================

--- 为所有存活势力生成君主（开局/读档兜底调用）
---@param gameState table
function LeaderSystem.initFactions(gameState)
    for fid, f in pairs(gameState.factions) do
        if not f.leader then
            local hist = HISTORICAL_LEADERS[fid]
            if hist then
                f.leader = {
                    name     = hist.name,
                    age      = hist.age,
                    admin    = hist.admin,
                    diplo    = hist.diplo,
                    military = hist.military,
                }
            else
                f.leader = generateHeir(fid)
            end
        end
    end
end

--- 每年推进：年龄 +1、死亡判定、继承
---@param gameState table
function LeaderSystem.processYear(gameState)
    for fid, f in pairs(gameState.factions) do
        if f.alive == false then goto continueLeader end
        local leader = f.leader
        if not leader then
            -- 兜底：缺失则生成
            f.leader = generateHeir(fid)
            goto continueLeader
        end

        leader.age = leader.age + 1

        if math.random() < deathChance(leader.age) then
            local oldName = leader.name
            -- ⚠️ 顺序很关键（2026-09-29 踩过坑）：
            --   inheritanceOrder 是**通过 f.leaderId 找君主的**，一旦把旧君主移出
            --   角色表，getById 就返回 nil → 算出来是空顺序 → 又退化成空降陌生人。
            --   所以必须**先算继承人，再移走旧君主**。
            local CS = require("systems.CharacterSystem")
            local oldChar = f.leaderId and CS.getById(gameState, f.leaderId)
            local heirChar = CS.inheritanceOrder(gameState, fid)[1]

            -- ① 旧君主标记死亡并移出角色表
            if oldChar then oldChar.alive = false end
            LeaderSystem._removeRulerFromCharacters(gameState, fid)

            -- ② 血缘继承：把王位给**刚才算好的**第一顺位
            --   ⚠️ 必须把 heirChar 传进去：此刻旧君主已移出角色表，
            --     applySuccession 内部重算会拿不到君主 → 顺序为空 → 白算一场。
            local heirName, bloodline = nil, ""
            if heirChar then
                CS.applySuccession(gameState, fid, heirChar)
                heirName = heirChar.name
                if oldChar and heirChar.parentId == oldChar.id then
                    bloodline = "（先君子嗣）"
                end
            end

            -- ③ 兜底：没有血缘继承人（新势力/开局就绝嗣）→ 空降
            if not heirName then
                f.leader = generateHeir(fid)
                LeaderSystem._syncHeirToCharacters(gameState, fid)
                heirName = f.leader.name
            end

            gameState.addMessage(
                factionName(gameState, fid) .. "君主 " .. oldName
                .. " 薨逝，新君 " .. tostring(heirName) .. " 继位" .. bloodline, "system")
        end
        ::continueLeader::
    end
end

--- 君主对经济收入的修正系数（admin 影响）
--- 文治 3=±0，每点 ±5%
---@param faction table
---@return number  multiplier（如 1.05 = +5%）
function LeaderSystem.getAdminModifier(faction)
    local l = faction and faction.leader
    if not l then return 1.0 end
    return 1.0 + (l.admin - 3) * 0.05
end

--- 君主对战斗力的修正系数（military 影响）
--- 武功 3=±0，每点 ±5%
---@param faction table
---@return number  multiplier
function LeaderSystem.getMilitaryModifier(faction)
    local l = faction and faction.leader
    if not l then return 1.0 end
    return 1.0 + (l.military - 3) * 0.05
end

--- 君主对外交的修正（diplo 影响改善关系速度）
--- 外交 3=±0，每点 ±1
---@param faction table
---@return number  delta
function LeaderSystem.getDiploModifier(faction)
    local l = faction and faction.leader
    if not l then return 0 end
    return l.diplo - 3
end

return LeaderSystem

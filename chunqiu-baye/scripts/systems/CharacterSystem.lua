-- ============================================================================
-- CharacterSystem.lua — 人物 / 官职 / 后宫（2026-09-16）
--
-- 设计口径（用户拍板）：
--   * **属性挂在"人"身上，不挂在国家/君主身上** —— 一个人去当官、当祭司、
--     当将军，走到哪个位置，那套属性就在哪个位置生效
--   * 五维用 CK3 那套（用户："你这个太古代了听不懂，还不如直接用他的那个"）：
--       外交 diplomacy / 军事 military / 管理 management / 谋略 intrigue / 学识 learning
--     1~5，**3 = 基准**（与旧的 文治/武功/外交 口径一致：每点 ±5%）
--   * 职位用**各朝代最耳熟的官名**（用户："给我拼凑这些知名的职位——宰相、大将军、六部"）：
--       三公（丞相/大将军/御史大夫）+ 六部（吏户礼兵刑工）+ 学官（太史令）
--
-- 与旧系统的关系（**零破坏迁移**）：
--   * `faction.leader` 仍然存在、仍被 LeaderSystem 读写（经济/军事/外交的修正器照旧跑）
--   * 本系统只是把君主**同时**登记成 `faction.characters` 里的一员（post = "君主"），
--     并把五维补齐（leader.admin → management、leader.diplo → diplomacy、
--     leader.military → military，另加 intrigue/learning）
-- ============================================================================

local Names = require("data.Names")

local CharacterSystem = {}

--- 五维的展示名（顶栏/面板统一用这里，改口径只改一处）
CharacterSystem.ATTRS = {
    { id = "diplomacy",  name = "外交" },
    { id = "military",   name = "军事" },
    { id = "management", name = "管理" },
    { id = "intrigue",   name = "谋略" },
    { id = "learning",   name = "学识" },
}

--- 职位表（三公 + 六部 + 学官）
--- attr = 用哪一维；mod = 走修正器管道时的键与系数
--- mod.per = 该维**每高出基准 1 点**带来的加成（3 = 基准 → 0）
--- mod.op  = "mul"（百分比，默认）| "flat"（直接加数）
CharacterSystem.POSTS = {
    { id = "chancellor",     name = "丞相",     attr = "management", mod = { key = "goldIncome",     per = 0.03 } },
    { id = "generalissimo",  name = "大将军",   attr = "military",   mod = { key = "recruit",        per = 0.04 } },
    { id = "censor",         name = "御史大夫", attr = "intrigue",   mod = { key = "stabilityDelta", per = 0.5, op = "flat" } },
    { id = "minister_personnel", name = "吏部尚书", attr = "management", mod = { key = "stabilityDelta", per = 0.4, op = "flat" } },
    { id = "minister_revenue",   name = "户部尚书", attr = "management", mod = { key = "goldIncome",     per = 0.05 } },
    { id = "minister_rites",     name = "礼部尚书", attr = "diplomacy",  mod = { key = "diploImprove",   per = 1.0, op = "flat" } },
    { id = "minister_war",       name = "兵部尚书", attr = "military",   mod = { key = "foodIncome",     per = 0.04 } },
    { id = "minister_justice",   name = "刑部尚书", attr = "intrigue",   mod = { key = "stabilityDelta", per = 0.4, op = "flat" } },
    { id = "minister_works",     name = "工部尚书", attr = "learning",   mod = { key = "popGrowth",      per = 0.05 } },
    { id = "astrologer",         name = "太史令",   attr = "learning",   mod = { key = "goldIncome",     per = 0.02 } },
}

--- 后宫位号（按位次从高到低；先秦用 夫人/嫔/世妇/御 那一套）
CharacterSystem.CONSORT_RANKS = { "夫人", "嫔", "世妇", "御" }

-- ---------------------------------------------------------------------------
-- 人物生成
-- ---------------------------------------------------------------------------
--- 随机一维（1~5，3 居多）
---@return integer
local function rollAttr()
    local r = math.random()
    if r < 0.08 then return 5 end
    if r < 0.28 then return 4 end
    if r < 0.70 then return 3 end
    return 2
end

--- 造一个新人
---@param factionId number
---@param gender string "男"|"女"
---@param ageMin number
---@param ageMax number
---@return table
local function makeCharacter(factionId, gender, ageMin, ageMax)
    local person = Names.randomPerson()
    local id = CharacterSystem._nextId or 1
    CharacterSystem._nextId = id + 1
    local c = {
        id = id,
        name = person.name,
        titleFrom = person.title,          -- 出身/自称（"布衣李悝"那种）
        age = math.random(ageMin, ageMax),
        gender = gender,
        diplomacy = rollAttr(),
        military = rollAttr(),
        management = rollAttr(),
        intrigue = rollAttr(),
        learning = rollAttr(),
        loyalty = math.random(40, 80),
        factionId = factionId,
        post = nil,                        -- nil = 在野/闲置
        alive = true,
    }
    -- 特质（2026-09-17，照 CK3）：1~2 个，第 3 个约 1/4 概率
    local Traits = require("data.Traits")
    Traits.roll(c, math.random(1, 4) == 1 and 3 or 2)
    Traits.applyAttrs(c)                   -- 特质带来的属性修正（如"勇敢"军事 +2）
    return c
end

--- 取势力人物表（不存在就地建）
---@param faction table
---@return table
local function charactersOf(faction)
    faction.characters = faction.characters or {}
    return faction.characters
end

-- ---------------------------------------------------------------------------
-- 初始化（幂等）
-- ---------------------------------------------------------------------------
---@param gameState table
function CharacterSystem.ensureInit(gameState)
    if gameState._charactersReady then return end
    gameState._charactersReady = true

    for _, f in pairs(gameState.factions or {}) do
        local list = charactersOf(f)

        -- ① 君主：把旧的 faction.leader 登记成人物（补齐五维 + 五维映射）
        if f.leader and not f.leaderId then
            local l = f.leader
            local pid = CharacterSystem._nextId or 1
            CharacterSystem._nextId = pid + 1
            local leaderChar = {
                id = pid,
                name = l.name,
                titleFrom = "国君",
                age = l.age or 40,
                gender = "男",
                diplomacy  = l.diplo or 3,
                military   = l.military or 3,
                management = l.admin or 3,
                intrigue   = rollAttr(),
                learning   = rollAttr(),
                loyalty = 100,
                factionId = f.id,
                post = "君主",
                alive = true,
            }
            l.intrigue = leaderChar.intrigue
            l.learning = leaderChar.learning
            -- 君主特质（2026-09-17，照 CK3）：2~3 个
            local Traits = require("data.Traits")
            Traits.roll(leaderChar, math.random(1, 2) == 1 and 3 or 2)
            Traits.applyAttrs(leaderChar)
            list[#list + 1] = leaderChar
            f.leaderId = pid
        elseif f.leader and f.leaderId then
            -- 读档/重入：五维回填到 leader（LeaderSystem 只认 admin/diplo/military）
            local c = CharacterSystem.getById(gameState, f.leaderId)
            if c then
                c.diplomacy  = c.diplomacy or f.leader.diplo or 3
                c.military   = c.military or f.leader.military or 3
                c.management = c.management or f.leader.admin or 3
                c.intrigue   = c.intrigue or rollAttr()
                c.learning   = c.learning or rollAttr()
            end
        end

        -- ② 在野人才（可被任命的官员候选人）：每国 4~6 人
        if #list <= 1 then
            local n = math.random(4, 6)
            for _ = 1, n do
                list[#list + 1] = makeCharacter(f.id, "男", 20, 55)
            end
        end
        -- 登记进全局索引（含君主）
        for _, c in ipairs(list) do CharacterSystem._index(gameState, c) end
    end
    CharacterSystem.rebuildIndex(gameState)
    CharacterSystem.registerModifiers()
    print("[Character] 人物系统就绪")
end

--- 把各职位的加成接进修正器管道（幂等）
---   加成 = (该维 - 3) × per → 3 点 = 不增不减；5 点 = 满配
function CharacterSystem.registerModifiers()
    if CharacterSystem._modsReady then return end
    CharacterSystem._modsReady = true
    local Modifiers = require("systems.Modifiers")

    for _, post in ipairs(CharacterSystem.POSTS) do
        local m = post.mod
        if m then
            Modifiers.rule {
                scope = "faction",
                key = m.key,
                op = m.op or "mul",
                source = "post:" .. post.id,          -- 每个职位一条，互不覆盖
                value = function(gameState, ctx)
                    local f = ctx and ctx.faction
                    if not f then return 0 end
                    local holder = CharacterSystem.getHolder(gameState, f.id, post.id)
                    if not holder then return 0 end
                    local attr = holder[post.attr] or 3
                    return (attr - 3) * (m.per or 0)
                end,
            }
        end
    end
    print("[Character] 已把 " .. tostring(#CharacterSystem.POSTS) .. " 个职位的加成接进修正器")

    -- --------------------------------------------------------------------
    -- 特质（2026-09-17，照 CK3）：**按势力聚合**，不是每个人一条规则
    --   为什么：世界大起来（1000 国 / 1.6 万人）如果每人注册一条，
    --   每月经济结算要把上万条规则走一遍。这里每个 key 只有一条规则，
    --   内部再去遍历"该势力当前在位的人"（君主 + 有职位的，通常 ≤ 11 人）。
    -- --------------------------------------------------------------------
    local Traits = require("data.Traits")
    --- 特质能作用的键（= Modifiers.KEYS 清单里军事/经济/外交/文化那几个）
    local TRAIT_KEYS = {
        "goldIncome", "foodIncome", "popGrowth", "recruit",
        "militaryPower", "defensePower", "diploImprove", "stabilityDelta",
        "prestigeDelta",   -- 名声（2026-09-17：原「威望」，忠义/残暴这类名声特质吃这条）
    }
    local flatKeys = { diploImprove = true, stabilityDelta = true, prestigeDelta = true }   -- 加法口 vs 乘法口
    for _, key in ipairs(TRAIT_KEYS) do
        Modifiers.rule {
            scope = "faction",
            key = key,
            op = flatKeys[key] and "flat" or "scale",
            source = "trait:" .. key,
            value = function(gameState, ctx)
                local f = ctx and ctx.faction
                if not f then return flatKeys[key] and 0 or 1 end
                local sum = Traits.sumMods(CharacterSystem.activeOf(gameState, f.id))[key] or 0
                -- scale 口是"倍率"（1.0 = 不变），flat 口是"加数"（0 = 不变）
                return flatKeys[key] and sum or (1.0 + sum)
            end,
        }
    end
    print("[Character] 已把特质的加成接进修正器（按势力聚合，共 " .. tostring(#TRAIT_KEYS) .. " 条）")
end

--- 军职（将领特质的生效载体；与 data/Traits.lua 的 Traits.MILITARY_POSTS 一致）
CharacterSystem.MILITARY_POSTS = {
    generalissimo = true,   -- 大将军
    minister_war  = true,   -- 兵部尚书
}

--- 某势力**当前在位的人**：君主 + 所有在职官员（特质只在这时生效）
---   （口径与"属性挂在人身上，走到哪个位置在哪个位置生效"一致）
---@param gameState table
---@param factionId number
---@return table[]
function CharacterSystem.activeOf(gameState, factionId)
    local f = gameState and gameState.factions and gameState.factions[factionId]
    if not f then return {} end
    local out = {}
    for _, c in ipairs(f.characters or {}) do
        if c.alive ~= false and (c.post == "君主" or (c.post ~= nil)) then
            out[#out + 1] = c
        end
    end
    return out
end

--- 人物的特质文案（面板/提示用）
---@param char table
---@return string 例："勇敢、经世之才"
function CharacterSystem.traitText(char)
    if not char or not char.traits or #char.traits == 0 then return "——" end
    return table.concat(char.traits, "、")
end

-- ---------------------------------------------------------------------------
-- 查询
-- ---------------------------------------------------------------------------
--- 按 id 找人物
---@param gameState table
---@param charId number
---@return table|nil
function CharacterSystem.getById(gameState, charId)
    if not charId then return nil end
    -- ① 先查**全局人物索引**（2026-09-29 加）
    --   为什么需要：原来只遍历"活人列表"，人一旦移出（如君主去世）就查不到了。
    --   但**血脉追溯要靠 getById 找父辈** —— 移出后父辈查不到 → 继承顺序算不出血缘
    --   → 血缘链断裂（实测：200 年 7 次换君，parentId 有值但父查不到）。
    --   索引里保留所有出现过的人（含死者），活人列表只管"当前在朝的人"。
    local idx = gameState._charIndex
    if idx and idx[charId] then return idx[charId] end
    -- ② 兜底：索引没建/没收录 → 老路子遍历
    for _, f in pairs(gameState.factions or {}) do
        for _, c in ipairs(f.characters or {}) do
            if c.id == charId then return c end
        end
    end
    return nil
end

--- 把人登记进全局索引（含死者，供血脉追溯）
---@param gameState table
---@param char table
function CharacterSystem._index(gameState, char)
    if not (gameState and char and char.id) then return end
    gameState._charIndex = gameState._charIndex or {}
    gameState._charIndex[char.id] = char
end

--- 重建全局索引（读档后 / ensureInit 时调）
---@param gameState table
function CharacterSystem.rebuildIndex(gameState)
    if not gameState then return end
    gameState._charIndex = {}
    for _, f in pairs(gameState.factions or {}) do
        for _, c in ipairs(f.characters or {}) do
            if c and c.id then gameState._charIndex[c.id] = c end
        end
        for _, c in ipairs(f.consorts or {}) do
            if c and c.id then gameState._charIndex[c.id] = c end
        end
    end
end

--- 某势力的人物表
---@param gameState table
---@param factionId number
---@return table[]
function CharacterSystem.listOf(gameState, factionId)
    local f = gameState.factions and gameState.factions[factionId]
    if not f then return {} end
    return charactersOf(f)
end

--- 某职位的在任者
---@param gameState table
---@param factionId number
---@param postId string
---@return table|nil
function CharacterSystem.getHolder(gameState, factionId, postId)
    for _, c in ipairs(CharacterSystem.listOf(gameState, factionId)) do
        if c.post == postId then return c end
    end
    return nil
end

--- 官职候选（本势力**没有职位**的人）——后宫不在候选里
---@param gameState table
---@param factionId number
---@return table[]
function CharacterSystem.candidatesFor(gameState, factionId)
    local out = {}
    for _, c in ipairs(CharacterSystem.listOf(gameState, factionId)) do
        if c.post == nil and c.gender == "男" then
            out[#out + 1] = c
        end
    end
    table.sort(out, function(a, b) return a.age < b.age end)
    return out
end

--- 某职位当前能给势力的系数（3 = 基准 → 0；每点 ±5%）
---@param gameState table
---@param factionId number
---@param postId string
---@return number
function CharacterSystem.postBonus(gameState, factionId, postId)
    local c = CharacterSystem.getHolder(gameState, factionId, postId)
    if not c then return 0 end
    for _, p in ipairs(CharacterSystem.POSTS) do
        if p.id == postId then
            return ((c[p.attr] or 3) - 3) * 0.05
        end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- 任免
-- ---------------------------------------------------------------------------
--- 任命：把某人物放到某职位（原来那位自动卸任；同一人只能占一个职位）
---@param gameState table
---@param factionId number
---@param postId string
---@param charId number
---@return boolean ok
---@return string|nil reason
function CharacterSystem.appoint(gameState, factionId, postId, charId)
    -- 职位必须真实存在（不然会静默挂上一个不存在的职位 —— 离屏测试踩过：
    --   SHOT_COURT=1,harem 把 "harem" 当成职位 id 任命成功了）
    local known = false
    for _, p in ipairs(CharacterSystem.POSTS) do
        if p.id == postId then known = true end
    end
    if not known then return false, "没有这个职位：" .. tostring(postId) end

    local c = CharacterSystem.getById(gameState, charId)
    if not c or c.factionId ~= factionId then return false, "此人不在你麾下" end
    if c.gender ~= "男" then return false, "后宫不任官职" end

    -- 同一人只能占一个位置
    if c.post and c.post ~= postId then
        c.post = nil
    end
    -- 原任者卸任
    local holder = CharacterSystem.getHolder(gameState, factionId, postId)
    if holder and holder.id ~= charId then
        holder.post = nil
    end
    c.post = postId
    return true
end

--- 罢免某职位
---@param gameState table
---@param factionId number
---@param postId string
---@return boolean
function CharacterSystem.dismiss(gameState, factionId, postId)
    local holder = CharacterSystem.getHolder(gameState, factionId, postId)
    if not holder then return false end
    holder.post = nil
    return true
end

-- ---------------------------------------------------------------------------
-- 培养（2026-09-28 第4步）
--
--   两种方式（用户："两者都要"）：
--     ① 培养属性：花金/粮，立即 +1（受上限约束）
--     ② 历练：花更多资源，进入"历练中"状态，若干月后回来随机得一个特质
--
--   设计口径：
--     * 属性上限 **10**（与 Traits.applyAttrs 的 math.min(10,...) 一致）
--     * 培养越接近上限越贵（避免无脑堆满）
--     * 历练的产物由 Traits.roll 决定（可能好可能坏，有随机性）
--     * 历练期间该人物**不能**被任命/当将军（状态字段 training_）
-- ---------------------------------------------------------------------------

--- 培养一次属性的花费（金/粮），越接近上限越贵
---@param current number 当前属性值
---@return number gold
---@return number food
function CharacterSystem.trainCost(current)
    local v = math.max(1, math.min(10, current or 3))
    -- 基础 40 金 / 60 粮，每高 1 点 +60%（1→2 便宜，9→10 很贵）
    local mult = 1.0 + (v - 1) * 0.6
    return math.floor(40 * mult + 0.5), math.floor(60 * mult + 0.5)
end

--- 历练的花费（金/粮）与时长（月）
---@return number gold
---@return number food
---@return number months
function CharacterSystem.trainingCost()
    return 120, 180, 6
end

--- 培养某人的一项属性（花资源，立即 +1）
---@param gameState table
---@param factionId number
---@param charId number
---@param attrId string "diplomacy"|"military"|"management"|"intrigue"|"learning"
---@return boolean ok
---@return string|nil msg
function CharacterSystem.trainAttr(gameState, factionId, charId, attrId)
    local f = gameState and gameState.factions and gameState.factions[factionId]
    if not f then return false, "势力不存在" end
    local c = CharacterSystem.getById(gameState, charId)
    if not c or c.alive == false then return false, "人物不存在" end
    if c.factionId ~= factionId then return false, "此人不在你麾下" end
    if c.training_ then return false, "此人正在历练中" end

    -- 属性 id 必须合法
    local valid = false
    for _, a in ipairs(CharacterSystem.ATTRS) do
        if a.id == attrId then valid = true end
    end
    if not valid then return false, "没有这项属性" end

    local cur = c[attrId] or 3
    if cur >= 10 then return false, "该项已至上限（10）" end

    local gold, food = CharacterSystem.trainCost(cur)
    if (f.gold or 0) < gold then return false, string.format("金钱不足（需 %d）", gold) end
    if (f.food or 0) < food then return false, string.format("粮草不足（需 %d）", food) end

    f.gold = f.gold - gold
    f.food = f.food - food
    c[attrId] = cur + 1
    print(string.format("[Character] 培养 %s：%s %d→%d（花 %d 金 %d 粮）",
        tostring(c.name), attrId, cur, cur + 1, gold, food))
    return true, string.format("%s %s +1", tostring(c.name), attrId)
end

--- 派某人去历练（花资源，若干月后回来随机得特质）
---@param gameState table
---@param factionId number
---@param charId number
---@return boolean ok
---@return string|nil msg
function CharacterSystem.startTraining(gameState, factionId, charId)
    local f = gameState and gameState.factions and gameState.factions[factionId]
    if not f then return false, "势力不存在" end
    local c = CharacterSystem.getById(gameState, charId)
    if not c or c.alive == false then return false, "人物不存在" end
    if c.factionId ~= factionId then return false, "此人不在你麾下" end
    if c.training_ then return false, "此人已在历练中" end
    if c.post == "君主" then return false, "国君不可外出历练" end

    local gold, food, months = CharacterSystem.trainingCost()
    if (f.gold or 0) < gold then return false, string.format("金钱不足（需 %d）", gold) end
    if (f.food or 0) < food then return false, string.format("粮草不足（需 %d）", food) end

    f.gold = f.gold - gold
    f.food = f.food - food
    c.training_ = months                     -- 剩余月数
    -- 历练期间卸任（人不在，不能当官/当将军）
    c.suspendedPost_ = c.post
    c.post = nil
    if f.provinceCommanders then
        for pid, cid in pairs(f.provinceCommanders) do
            if cid == c.id then f.provinceCommanders[pid] = nil end
        end
    end
    print(string.format("[Character] %s 外出历练（%d 个月）", tostring(c.name), months))
    return true, string.format("%s 已启程历练", tostring(c.name))
end

--- 月度推进历练：倒计时归零 → 回朝并随机得一个特质
---   由 main.lua 的 TimeSystem.on("month") 调用。
---@param gameState table
function CharacterSystem.processMonthTraining(gameState)
    if not gameState then return end
    for _, f in pairs(gameState.factions or {}) do
        for _, c in ipairs(f.characters or {}) do
            if c.training_ then
                c.training_ = c.training_ - 1
                if c.training_ <= 0 then
                    c.training_ = nil
                    -- 历练成果：随机一个特质（可能好可能坏 —— Traits.roll 自己会挑）
                    local Traits = require("data.Traits")
                    local before = #(c.traits or {})
                    Traits.roll(c, 1)          -- 加 1 个（内部会去重）
                    local gained = nil
                    if #(c.traits or {}) > before then
                        gained = c.traits[#c.traits]
                    end
                    -- 属性也小涨一点（历练总有收获）
                    local attrs = { "diplomacy", "military", "management", "intrigue", "learning" }
                    local pick = attrs[math.random(#attrs)]
                    c[pick] = math.min(10, (c[pick] or 3) + 1)
                    -- 恢复原职（如果位置还空着）
                    if c.suspendedPost_ then
                        local holder = CharacterSystem.getHolder(gameState, f.id, c.suspendedPost_)
                        if not holder then c.post = c.suspendedPost_ end
                        c.suspendedPost_ = nil
                    end
                    if f.id == gameState.playerFactionId and gameState.addMessage then
                        gameState.addMessage(string.format("%s 历练归来%s",
                            tostring(c.name),
                            gained and ("，习得「" .. tostring(gained) .. "」") or ""), "system")
                    end
                    print(string.format("[Character] %s 历练归来（得特质 %s，%s +1）",
                        tostring(c.name), tostring(gained), pick))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 家族与子嗣（2026-09-29）
--
--   用户："如果君王死掉怎么办他的孩子呢，十字军之王不是会有什么小孩吗"
--
--   为什么必须做：原来 LeaderSystem.generateHeir 是**凭空造一个陌生人**当新君
--   （随机名字 + 随机年龄 18~35）→ 君主死了跟自己毫无关系，人物系统因此"没用"。
--   有了子嗣，继承才成立：**你儿子继位**，而不是路人甲。
--
--   设计口径（用户拍板）：
--     * 君主 + 后宫/配偶，**每年按概率**生子（年龄影响概率，照 CK3）
--     * 孩子是**真实人物**（从 0 岁开始，进 faction.characters）
--     * 亲子关系用 parentId / childIds 双向记录（供继承排序用）
--     * 遗传：父母五维的平均值 ± 随机波动（照 CK3 的"父母影响子女基础值"）
-- ---------------------------------------------------------------------------

--- 生育年龄区间（照 CK3 的大致口径）
CharacterSystem.FERTILE_MIN = 16
CharacterSystem.FERTILE_MAX = 45

--- 年度生育概率（母亲年龄越大越低）
---@param motherAge number
---@return number 0~1
function CharacterSystem.birthChance(motherAge)
    local a = motherAge or 25
    if a < CharacterSystem.FERTILE_MIN or a > CharacterSystem.FERTILE_MAX then return 0 end
    -- 20~30 岁最高（约 35%），两端递减
    if a <= 30 then
        return 0.20 + (a - CharacterSystem.FERTILE_MIN) * 0.015
    end
    return math.max(0.03, 0.35 - (a - 30) * 0.03)
end

--- 生一个孩子（父母双方的五维做遗传）
---@param gameState table
---@param faction table
---@param father table|nil 父亲（通常是君主）
---@param mother table|nil 母亲（后宫/配偶）
---@return table|nil child
function CharacterSystem.bearChild(gameState, faction, father, mother)
    if not faction then return nil end
    local gender = (math.random() < 0.52) and "男" or "女"
    local child = makeCharacter(faction.id, gender, 0, 0)
    child.age = 0
    -- 遗传：父母同维平均 + 随机波动（±1），夹在 1~10
    --   照 CK3"父母能力影响子女基础值"的口径
    local attrs = { "diplomacy", "military", "management", "intrigue", "learning" }
    for _, k in ipairs(attrs) do
        local fv = father and father[k]
        local mv = mother and mother[k]
        local base
        if fv and mv then base = (fv + mv) / 2
        elseif fv then base = fv
        elseif mv then base = mv
        else base = 3 end
        local v = math.floor(base + 0.5) + math.random(-1, 1)
        -- 用 case 分支（动态索引赋值会被静态分析判类型不符）
        local val = math.max(1, math.min(10, v))
        if k == "diplomacy" then child.diplomacy = val
        elseif k == "military" then child.military = val
        elseif k == "management" then child.management = val
        elseif k == "intrigue" then child.intrigue = val
        else child.learning = val end
    end
    -- 血缘
    child.parentId = father and father.id or nil
    child.motherId = mother and mother.id or nil
    child.titleFrom = "公子"
    child.loyalty = 100            -- 自家人
    child.post = nil
    -- 双向登记
    if father then
        father.childIds = father.childIds or {}
        father.childIds[#father.childIds + 1] = child.id
    end
    if mother then
        mother.childIds = mother.childIds or {}
        mother.childIds[#mother.childIds + 1] = child.id
    end
    faction.characters = faction.characters or {}
    faction.characters[#faction.characters + 1] = child
    CharacterSystem._index(gameState, child)
    return child
end

--- 年度：君主与后宫生育（照 CK3 的"每年有概率得子"）
---   只对**活着的势力**做；孩子进 faction.characters（真实人物，会长大）
---@param gameState table
function CharacterSystem.processYearBirths(gameState)
    if not gameState then return end
    for _, f in pairs(gameState.factions or {}) do
        if f.alive ~= false then
            local ruler = f.leaderId and CharacterSystem.getById(gameState, f.leaderId)
            if ruler and ruler.alive ~= false and ruler.gender == "男" then
                -- 子嗣上限 6（防人口爆炸）
                local n = #(ruler.childIds or {})
                if n < 6 then
                    -- ⚠️ 先确保后宫存在：consortsOf 是**懒加载**的，
                    --   直接读 f.consorts 会是空表 → 永远生不出孩子
                    CharacterSystem.consortsOf(gameState, f.id)
                    -- 从后宫/配偶里挑一位生育年龄内的
                    local mothers = {}
                    for _, c in ipairs(f.consorts or {}) do
                        if c.alive ~= false
                           and (c.age or 99) >= CharacterSystem.FERTILE_MIN
                           and (c.age or 99) <= CharacterSystem.FERTILE_MAX then
                            mothers[#mothers + 1] = c
                        end
                    end
                    -- 也把势力里育龄女性算上（不只是后宫）
                    for _, c in ipairs(f.characters or {}) do
                        if c.alive ~= false and c.gender == "女"
                           and (c.age or 99) >= CharacterSystem.FERTILE_MIN
                           and (c.age or 99) <= CharacterSystem.FERTILE_MAX then
                            mothers[#mothers + 1] = c
                        end
                    end
                    if #mothers > 0 then
                        local m = mothers[math.random(#mothers)]
                        if math.random() < CharacterSystem.birthChance(m.age) then
                            local child = CharacterSystem.bearChild(gameState, f, ruler, m)
                            if child and f.id == gameState.playerFactionId and gameState.addMessage then
                                gameState.addMessage(string.format("国君喜得%s：%s（%s所出）",
                                    child.gender == "男" and "公子" or "公主",
                                    tostring(child.name), tostring(m.name)), "system")
                            end
                            if child then
                                print(string.format("[Character] %s 得子 %s（母 %s）",
                                    tostring(ruler.name), tostring(child.name), tostring(m.name)))
                            end
                        end
                    end
                end
            end
        end
    end
end

--- 取某人的子女（按年龄降序 = 长子在前，供继承用）
---@param gameState table
---@param char table|nil
---@return table[]
function CharacterSystem.childrenOf(gameState, char)
    local out = {}
    if not char or not char.childIds then return out end
    -- 顺带清理失效引用（2026-09-29 修）：
    --   子女死后其 id 仍留在 childIds 里 → getById 返回 nil。
    --   不清理的话，列表会越来越脏（踩过：调试打印出现"子 nil age=nil"）。
    local alive = {}
    for _, cid in ipairs(char.childIds) do
        local c = CharacterSystem.getById(gameState, cid)
        if c and c.alive ~= false then
            out[#out + 1] = c
            alive[#alive + 1] = cid
        end
    end
    if #alive ~= #char.childIds then char.childIds = alive end
    table.sort(out, function(a, b) return (a.age or 0) > (b.age or 0) end)
    return out
end

-- ---------------------------------------------------------------------------
-- 继承（2026-09-29）
--
--   用户："如果君王死掉怎么办他的孩子呢"
--
--   长子继承法（用户拍板"只做长子继承"）：
--     继承顺序 = 嫡长子 → 次子 → … → 女儿（长→幼）
--              → 君主的兄弟（旁支）→ 都没有才"远房/空降"
--
--   ⚠️ 和 LeaderSystem 的分工：
--     * 本模块只**算顺序**（inheritanceOrder）和**执行继承**（applySuccession）
--     * LeaderSystem 仍负责"每年年龄+1、判死"，死后调这里拿继承人
--     * 这样"谁能继承"的知识集中在一处，UI 也能直接调来显示"继承顺序"
-- ---------------------------------------------------------------------------

--- 算某势力的继承顺序（长子继承法）
---   返回按顺位排列的候选人列表（第 1 个 = 第一顺位继承人）
---@param gameState table
---@param factionId number
---@return table[] ordered
function CharacterSystem.inheritanceOrder(gameState, factionId)
    local f = gameState and gameState.factions and gameState.factions[factionId]
    if not f then return {} end
    local out = {}
    local ruler = f.leaderId and CharacterSystem.getById(gameState, f.leaderId)
    if not ruler then return out end

    -- ① 直系：子女（长子在前；男优先于女，同性别按年龄）
    local kids = CharacterSystem.childrenOf(gameState, ruler)
    local sons, daughters = {}, {}
    for _, c in ipairs(kids) do
        if c.gender == "男" then sons[#sons + 1] = c else daughters[#daughters + 1] = c end
    end
    for _, c in ipairs(sons) do out[#out + 1] = c end
    for _, c in ipairs(daughters) do out[#out + 1] = c end

    -- ② 旁支：君主的兄弟（同父）
    if ruler.parentId then
        local father = CharacterSystem.getById(gameState, ruler.parentId)
        if father then
            for _, b in ipairs(CharacterSystem.childrenOf(gameState, father)) do
                if b.id ~= ruler.id and b.gender == "男" then out[#out + 1] = b end
            end
        end
    end

    -- ②.5 幼主摄政（2026-09-29）
    --
    --   ⚠️ 这里踩过一个**断血脉**的大坑：
    --   第一版"未成年直接跳过、顺位让给成年旁支" → 君主死时孩子还小 →
    --   王位给了**无血缘的远房** → 新君跟老君没血缘 → 老君的孩子沦为路人 →
    --   血缘链从此断裂，之后永远是空降。测了 120 年，血缘继承 0 次。
    --
    --   照 CK3 的做法改成**幼主 + 摄政**：
    --     * 有未成年子嗣 → 血脉优先，选最年长的那个子嗣当**幼主**
    --     * 幼主未成年期间由**摄政**（faction.regentId）代管
    --     * 幼主成年后（>=16）自动亲政（见 processYear 里的摄政检查）
    --   这样血脉不断，也避免"4 岁小孩独掌大权"的荒唐。
    -- 长子继承的**正确语义**（2026-09-29 修正）：
    --   第一顺位就是**最年长的儿子**（不论成年与否）。
    --     * 他成年 → 直接继位
    --     * 他未成年 → 他当幼主，由摄政代管（**不能让位给弟弟**，
    --       否则"长子继承"就变成"成年儿子继承"了，等于改变继承法）
    --   所以这里**不重排**，只把完全不合适的（死人）剔掉。
    local candidates = {}
    for _, c in ipairs(out) do
        if c.alive ~= false then candidates[#candidates + 1] = c end
    end
    out = candidates

    -- ③ 兜底：本国其它成年男性（远房/重臣），按年龄长→幼
    if #out == 0 then
        local others = {}
        for _, c in ipairs(f.characters or {}) do
            if c.alive ~= false and c.gender == "男" and c.id ~= ruler.id
               and (c.age or 0) >= 16 and c.post ~= "君主" then
                others[#others + 1] = c
            end
        end
        table.sort(others, function(a, b) return (a.age or 0) > (b.age or 0) end)
        for _, c in ipairs(others) do out[#out + 1] = c end
    end
    return out
end

--- 执行继承：把王位给指定继承人（不传则现算第一顺位）
---
---   ⚠️ 为什么要支持**外部传入 heir**（2026-09-29 踩坑）：
---     LeaderSystem 必须在"移走旧君主**之前**"算好继承人（因为顺序靠 leaderId 查君主），
---     但它移走旧君主后再调本函数 → 本函数内部重算时 getById(leaderId) 已经是 nil
---     → 顺序为空 → 返回 nil → 调用方状态错乱（王位给了人但 f.leader 没换）。
---   所以让调用方把算好的继承人传进来，本函数只负责"登基"。
---@param gameState table
---@param factionId number
---@param heir table|nil 已选定的继承人（不传 = 内部现算）
---@return table|nil newRuler
function CharacterSystem.applySuccession(gameState, factionId, heir)
    local f = gameState and gameState.factions and gameState.factions[factionId]
    if not f then return nil end
    if not heir then
        heir = CharacterSystem.inheritanceOrder(gameState, factionId)[1]
    end
    if not heir then return nil end

    -- 新君上位：登记成君主角色，回写 leaderId + leader（旧接口仍要）
    heir.post = "君主"
    heir.titleFrom = "国君"
    f.leaderId = heir.id
    f.leader = {
        name     = heir.name,
        age      = heir.age or 0,
        admin    = heir.management or 3,     -- 旧接口：admin = 管理
        diplo    = heir.diplomacy or 3,
        military = heir.military or 3,
    }

    -- 幼主 → 指派摄政（2026-09-29）
    --   照 CK3：未成年君主不能亲政，由一位成年重臣代管。
    --   摄政只是"标记"，不改变 leader 归属 —— 等幼主成年自动解除。
    f.regentId = nil
    if (heir.age or 0) < 16 then
        -- 摄政人选：除幼主外，五维总和最高的成年本国人物
        local best, bestSum = nil, -1
        for _, c in ipairs(f.characters or {}) do
            if c.alive ~= false and c.id ~= heir.id and (c.age or 0) >= 16 then
                local s = 0
                for _, a in ipairs(CharacterSystem.ATTRS) do s = s + (c[a.id] or 3) end
                if s > bestSum then best, bestSum = c, s end
            end
        end
        if best then
            f.regentId = best.id
            print(string.format("[Character] %s 年幼（%d 岁），由 %s 摄政",
                tostring(heir.name), heir.age or 0, tostring(best.name)))
        end
    end

    print(string.format("[Character] %s 继位（%s，%d 岁）",
        tostring(heir.name), tostring(f.name), heir.age or 0))
    return heir
end

--- 幼主成年 → 亲政（解除摄政）
---   由 processYear 每年调一次。
---@param gameState table
function CharacterSystem.processRegency(gameState)
    if not gameState then return end
    for _, f in pairs(gameState.factions or {}) do
        if f.alive ~= false and f.regentId then
            local ruler = f.leaderId and CharacterSystem.getById(gameState, f.leaderId)
            if not ruler or ruler.alive == false then
                f.regentId = nil                       -- 幼主没了，摄政自动结束
            elseif (ruler.age or 0) >= 16 then
                -- 亲政
                f.regentId = nil
                if f.id == gameState.playerFactionId and gameState.addMessage then
                    gameState.addMessage(string.format("%s 年满十六，正式亲政",
                        tostring(ruler.name)), "system")
                end
                print(string.format("[Character] %s 亲政（%s）",
                    tostring(ruler.name), tostring(f.name)))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 人才获取（2026-09-28）
--
--   用户："十字军之王他们那个人才获取有很多途径"
--   我们原来只有"开局给 4~6 个、死了才补" → 太被动。补三条途径：
--     ① recruitGuest：**花钱招募**在野人才（照 CK3 的 15 金招人，但按能力定价）
--     ② spawnWanderer：**游方士人上门**（每年概率触发，可收可不收）
--     ③ 战斗俘获（在 MilitarySystem 那边调 offerDefector）
--
--   设计口径：
--     * 招募价 = 基础 + 五维总和加成（人才越好越贵）
--     * 游方士人：每年小概率来一个，属性比在野的略好（"有本事的人才肯走动"）
--     * 俘获：打赢后有概率把对方一个**低忠诚**人物招降过来
-- ---------------------------------------------------------------------------

--- 招募在野人才的价钱（金）：能力越强越贵
---@param char table
---@return number gold
function CharacterSystem.recruitPrice(char)
    if not char then return 0 end
    local sum = 0
    for _, a in ipairs(CharacterSystem.ATTRS) do
        sum = sum + (char[a.id] or 3)
    end
    -- 五维总和 15 = 基准 → 60 金；每高 1 点 +12 金
    return math.max(30, 60 + (sum - 15) * 12)
end

--- 花钱招募一个在野人才（加入本国）
---@param gameState table
---@param factionId number
---@param charId number
---@return boolean ok
---@return string msg
function CharacterSystem.recruitGuest(gameState, factionId, charId)
    local f = gameState and gameState.factions and gameState.factions[factionId]
    if not f then return false, "势力不存在" end
    local c = CharacterSystem.getById(gameState, charId)
    if not c or c.alive == false then return false, "人物不存在" end
    if c.factionId == factionId then return false, "此人已在你麾下" end
    if c.post or c.rank then return false, "此人已有职位" end

    local price = CharacterSystem.recruitPrice(c)
    if (f.gold or 0) < price then
        return false, string.format("金钱不足（需 %d）", price)
    end
    f.gold = f.gold - price

    -- 从原势力（可能是 nil=无主）移出，加入本国
    local old = c.factionId and gameState.factions[c.factionId]
    if old and old.characters then
        for i = #old.characters, 1, -1 do
            if old.characters[i].id == c.id then table.remove(old.characters, i) end
        end
    end
    c.factionId = factionId
    c.loyalty = math.max(40, c.loyalty or 60)
    f.characters = f.characters or {}
    f.characters[#f.characters + 1] = c
    CharacterSystem._index(gameState, c)
    print(string.format("[Character] 招募 %s 入朝（花 %d 金）", tostring(c.name), price))
    return true, string.format("%s 已入朝（花 %d 金）", tostring(c.name), price)
end

--- 生成一位"游方士人"（上门求仕）
---   属性比普通在野略好（30% 概率某维 +1），有名字/出身
---@param factionId number
---@return table
function CharacterSystem.spawnWanderer(factionId)
    local c = makeCharacter(factionId, "男", 22, 50)
    c.titleFrom = "游方士人"
    c.loyalty = math.random(50, 75)
    -- 30% 概率某一维额外 +1（"有本事的人才肯走动"）
    --   用 case 分支直接写字段（不走 c[k] 动态索引）：
    --   makeCharacter 的返回类型被推断成含字面量字段的表，动态索引赋值会报类型不符
    if math.random() < 0.30 then
        local attrs = { "diplomacy", "military", "management", "intrigue", "learning" }
        local k = attrs[math.random(#attrs)]
        if k == "diplomacy" then
            c.diplomacy = math.min(10, (c.diplomacy or 3) + 1)
        elseif k == "military" then
            c.military = math.min(10, (c.military or 3) + 1)
        elseif k == "management" then
            c.management = math.min(10, (c.management or 3) + 1)
        elseif k == "intrigue" then
            c.intrigue = math.min(10, (c.intrigue or 3) + 1)
        else
            c.learning = math.min(10, (c.learning or 3) + 1)
        end
    end
    return c
end

--- 年度：游方士人上门（照 CK3 的访客机制）
---   用户："十字军之王他们那个人才获取有很多途径"
---   为什么不走事件系统：EventSystem 的效果只走"插座"（Resources/Modifiers/Hooks），
---     **不允许事件改游戏内部状态**（见 Events.lua 文件头）。而"加一个人"是改角色表，
---     所以这里直接在年度推进里做，用消息通知玩家。
---   口径：每年约 25% 概率来一位（有上限，免得人才泛滥）；只对玩家势力发通知。
---@param gameState table
function CharacterSystem.processYearWanderers(gameState)
    if not gameState then return end
    for _, f in pairs(gameState.factions or {}) do
        if f.alive ~= false then
            -- 在野人才够多就不来了（上限 8，避免人才泛滥）
            local idle = 0
            for _, c in ipairs(f.characters or {}) do
                if c.alive ~= false and not c.post and not c.rank then idle = idle + 1 end
            end
            if idle < 8 and math.random() < 0.25 then
                local w = CharacterSystem.spawnWanderer(f.id)
                f.characters = f.characters or {}
                f.characters[#f.characters + 1] = w
                CharacterSystem._index(gameState, w)
                if f.id == gameState.playerFactionId and gameState.addMessage then
                    -- 报一下最强的那一维，让玩家知道值不值得用
                    local bestId, bestV = nil, 0
                    for _, a in ipairs(CharacterSystem.ATTRS) do
                        if (w[a.id] or 0) > bestV then bestId, bestV = a.id, w[a.id] end
                    end
                    local bestName = bestId or "学识"
                    for _, a in ipairs(CharacterSystem.ATTRS) do
                        if a.id == bestId then bestName = a.name end
                    end
                    gameState.addMessage(string.format(
                        "游方士人 %s 前来求仕（%s %d）", tostring(w.name), bestName, bestV),
                        "system")
                end
                print(string.format("[Character] %s 来投（势力 %s）", tostring(w.name), tostring(f.name)))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 阴谋（2026-09-28 第4步）
--
--   两类（用户："都要有"）：
--     ① 对他国下手（"离间"）：降低目标人物的忠诚/属性，削弱敌国
--     ② 对内控忠诚（"安抚"/"威慑"）：提升/打压自己人的忠诚，防止叛变
--
--   设计口径：
--     * 消耗**名声**（prestige）—— 阴谋是暗箱操作，花的是声望不是钱
--     * 有**成功率**，失败有代价（名声白花 + 可能暴露）
--     * 成功率取决于主使者的**谋略**（intrigue）vs 目标的谋略
--     * 冷却：同一个人一年只能被搞一次（防刷）
-- ---------------------------------------------------------------------------

--- 阴谋基础花费（名声）
CharacterSystem.SCHEME_COST = 60

--- 计算阴谋成功率（0~1）
---@param actor table 主使（谋略越高越强）
---@param target table 目标（谋略越高越难搞）
---@return number 0~1
function CharacterSystem.schemeChance(actor, target)
    local a = (actor and actor.intrigue or 3)
    local t = (target and target.intrigue or 3)
    -- 基础 50%，双方谋略差每点 ±8%
    local p = 0.5 + (a - t) * 0.08
    return math.max(0.1, math.min(0.9, p))
end

--- 对他国人物下手：离间（降忠诚 / 削属性）
---@param gameState table
---@param factionId number 主使势力
---@param actorId number 主使者（本国人物）
---@param targetId number 目标人物（他国）
---@return boolean ok
---@return string msg
function CharacterSystem.schemeAlienate(gameState, factionId, actorId, targetId)
    local f = gameState and gameState.factions and gameState.factions[factionId]
    if not f then return false, "势力不存在" end
    local actor = CharacterSystem.getById(gameState, actorId)
    local target = CharacterSystem.getById(gameState, targetId)
    if not actor or actor.factionId ~= factionId then return false, "主使者不在你麾下" end
    if not target or target.alive == false then return false, "目标不存在" end
    if target.factionId == factionId then return false, "不能离间自己人（用安抚/威慑）" end
    if target.schemeCooldown_ and target.schemeCooldown_ > 0 then
        return false, "此人最近已被算计过"
    end
    local cost = CharacterSystem.SCHEME_COST
    if (f.prestige or 0) < cost then
        return false, string.format("名声不足（需 %d）", cost)
    end
    f.prestige = f.prestige - cost
    target.schemeCooldown_ = 12          -- 一年内不再被算计

    local chance = CharacterSystem.schemeChance(actor, target)
    if math.random() < chance then
        -- 成功：忠诚暴跌；若忠诚本就低，还会掉一项属性
        target.loyalty = math.max(0, (target.loyalty or 50) - math.random(15, 30))
        local extra = ""
        if (target.loyalty or 50) < 30 and math.random() < 0.5 then
            local attrs = { "diplomacy", "military", "management", "intrigue", "learning" }
            local k = attrs[math.random(#attrs)]
            target[k] = math.max(1, (target[k] or 3) - 1)
            extra = "，其" .. k .. "受损"
        end
        print(string.format("[Scheme] 离间成功：%s 对 %s", tostring(actor.name), tostring(target.name)))
        return true, string.format("离间成功！%s 忠诚大降%s", tostring(target.name), extra)
    end
    print(string.format("[Scheme] 离间失败：%s 对 %s", tostring(actor.name), tostring(target.name)))
    return false, "事泄！名声白费，对方提高了警惕"
end

--- 对内控忠诚：安抚（+忠诚，稳）或威慑（大幅 +忠诚但有代价）
---@param gameState table
---@param factionId number
---@param actorId number 主使者
---@param targetId number 目标（本国人物）
---@param mode string "soothe"（安抚）| "intimidate"（威慑）
---@return boolean ok
---@return string msg
function CharacterSystem.schemeLoyalty(gameState, factionId, actorId, targetId, mode)
    local f = gameState and gameState.factions and gameState.factions[factionId]
    if not f then return false, "势力不存在" end
    local actor = CharacterSystem.getById(gameState, actorId)
    local target = CharacterSystem.getById(gameState, targetId)
    if not actor or actor.factionId ~= factionId then return false, "主使者不在你麾下" end
    if not target or target.alive == false then return false, "目标不存在" end
    if target.factionId ~= factionId then return false, "只能对自己人用（对外用离间）" end
    if target.id == actor.id then return false, "不能对自己下手" end

    local cost = CharacterSystem.SCHEME_COST
    if (f.prestige or 0) < cost then
        return false, string.format("名声不足（需 %d）", cost)
    end
    f.prestige = f.prestige - cost

    if mode == "intimidate" then
        -- 威慑：忠诚涨得多，但**稳定度**受损（人人自危）
        target.loyalty = math.min(100, (target.loyalty or 50) + math.random(20, 35))
        f.stability = math.max(0, (f.stability or 60) - 3)
        print(string.format("[Scheme] 威慑 %s：忠诚 → %d（稳定 -3）",
            tostring(target.name), target.loyalty))
        return true, string.format("%s 忠诚升至 %d（稳定度 -3）",
            tostring(target.name), target.loyalty)
    end
    -- 安抚：忠诚稳步涨，无副作用
    target.loyalty = math.min(100, (target.loyalty or 50) + math.random(10, 20))
    print(string.format("[Scheme] 安抚 %s：忠诚 → %d", tostring(target.name), target.loyalty))
    return true, string.format("%s 忠诚升至 %d", tostring(target.name), target.loyalty)
end

--- 月度推进：阴谋冷却递减
---@param gameState table
function CharacterSystem.processMonthSchemes(gameState)
    if not gameState then return end
    for _, f in pairs(gameState.factions or {}) do
        for _, c in ipairs(f.characters or {}) do
            if c.schemeCooldown_ and c.schemeCooldown_ > 0 then
                c.schemeCooldown_ = c.schemeCooldown_ - 1
                if c.schemeCooldown_ <= 0 then c.schemeCooldown_ = nil end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 年度推进：年龄增长 / 死亡 / 职位清理（2026-09-28）
--
-- 为什么需要这个：
--   原来只有 LeaderSystem 管君主的年龄和死亡（faction.leader），而 CharacterSystem
--   里那份"君主角色"、以及官员/后宫**完全不老化、不死亡** —— 两套数据各走各的。
--   结果：君主继位后角色表还是旧的；官员当到天荒地老。
--
-- 设计口径（用户拍板）：
--   * "人物生死"做成**开局设置项**（选国页），存 GameState.mortalityEnabled
--   * 开启 → 官员/后宫也会随年龄老死，职位空出来要重新任命（像 CK3）
--   * 关闭 → 只有君主会老死（LeaderSystem 管），官员/后宫不受影响
--   * **君主不在这里判死**（LeaderSystem 已经在管，避免同一年死两次/双重继承）
-- ---------------------------------------------------------------------------

--- 按年龄算年度死亡概率（与 LeaderSystem.deathChance 同口径，保证体感一致）
---@param age number
---@return number
local function deathChance(age)
    if age >= 70 then return 0.30 end
    if age >= 60 then return 0.15 end
    if age >= 50 then return 0.08 end
    if age >= 40 then return 0.03 end
    return 0.01
end

--- 年度推进：所有人物 +1 岁；开启"人物生死"时判定官员/后宫死亡并清理职位
---   由 main.lua 的 TimeSystem.on("year") 调用（紧挨 LeaderSystem.processYear）。
---@param gameState table
function CharacterSystem.processYear(gameState)
    if not gameState then return end
    local mortality = gameState.mortalityEnabled ~= false   -- 默认开
    for _, f in pairs(gameState.factions or {}) do
        if f.alive ~= false then
            -- ① 年龄增长（全体：君主/官员/在野/后宫）
            local function ageUp(list)
                for _, c in ipairs(list or {}) do
                    if c.alive ~= false then c.age = (c.age or 30) + 1 end
                end
            end
            ageUp(f.characters)
            ageUp(f.consorts)

            if mortality then
                -- ② 死亡判定：**跳过君主**（LeaderSystem 管，避免双重继承）
                local died = {}
                local function checkList(list)
                    for i = #(list or {}), 1, -1 do
                        local c = list[i]
                        if c.alive ~= false and c.post ~= "君主" then
                            if math.random() < deathChance(c.age or 30) then
                                c.alive = false
                                -- 死了就腾出职位（官职/统帅/后宫位号）
                                if c.post then c.post = nil end
                                died[#died + 1] = c
                                table.remove(list, i)
                            end
                        end
                    end
                end
                checkList(f.characters)
                checkList(f.consorts)

                -- ③ 在职官员死了 → 清掉 provinceCommanders 里指向他的统帅位
                if #died > 0 and f.provinceCommanders then
                    local deadIds = {}
                    for _, c in ipairs(died) do deadIds[c.id] = true end
                    for pid, cid in pairs(f.provinceCommanders) do
                        if deadIds[cid] then f.provinceCommanders[pid] = nil end
                    end
                end

                -- ④ 通知玩家（只报自己势力的，AI 的不刷屏）
                if #died > 0 and f.id == gameState.playerFactionId and gameState.addMessage then
                    for _, c in ipairs(died) do
                        local role = c.gender == "女" and "后宫" or "臣属"
                        gameState.addMessage(string.format("%s %s 亡故（享年 %d）",
                            role, c.name or "?", c.age or 0), "system")
                    end
                end

                -- ⑤ 人才补充：死光了就补新人，否则国家会没人可用
                local list = f.characters or {}
                if #list < 3 then
                    local need = math.random(2, 4)
                    for _ = 1, need do
                        local nc = makeCharacter(f.id, "男", 20, 45)
                        list[#list + 1] = nc
                        CharacterSystem._index(gameState, nc)
                    end
                end
                -- 后宫同理（保持 1~3 人，别断档）
                local cs = f.consorts or {}
                if #cs < 1 then
                    local need = math.random(1, 3)
                    for i = 1, need do
                        local c = makeCharacter(f.id, "女", 16, 30)
                        c.rank = CharacterSystem.CONSORT_RANKS[math.min(i, #CharacterSystem.CONSORT_RANKS)]
                        c.post = nil
                        cs[#cs + 1] = c
                        CharacterSystem._index(gameState, c)
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 后宫
-- ---------------------------------------------------------------------------
--- 取（或生成）势力后宫
---@param gameState table
---@param factionId number
---@return table[]
function CharacterSystem.consortsOf(gameState, factionId)
    local f = gameState.factions and gameState.factions[factionId]
    if not f then return {} end
    f.consorts = f.consorts or {}
    if #f.consorts == 0 then
        local n = math.random(2, 4)
        for i = 1, n do
            local c = makeCharacter(factionId, "女", 16, 35)
            c.rank = CharacterSystem.CONSORT_RANKS[math.min(i, #CharacterSystem.CONSORT_RANKS)]
            c.post = nil
            f.consorts[#f.consorts + 1] = c
            CharacterSystem._index(gameState, c)
        end
    end
    return f.consorts
end

return CharacterSystem

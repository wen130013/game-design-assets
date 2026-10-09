-- ============================================================================
-- Events.lua — 事件表（"插座"第四块的数据层 · 2026-09-13）
--
-- 事件 = 「什么时候可能发生」+「发生了什么」+「玩家怎么选」+「选完有什么效果」。
-- 之前的 EventManager 只是个 27 行空壳，没有任何事件可用；本文件填上内容。
--
-- 一条事件：
--   {
--     id     = "harvest_good",      -- 稳定 id（存档/调试用）
--     title  = "丰年",              -- 弹窗标题
--     text   = "……",                -- 正文
--     weight = 10,                  -- 权重（越大越容易抽到；0 = 不参与随机）
--     once   = true,                -- 是否只能发生一次（默认 false）
--     minYear / maxYear = -770,     -- 可选：只在这段时间内可能发生
--     cond   = function(gs, f) end, -- 可选：额外条件（返回 true 才可能发生）
--     choices = {                   -- 1~4 个选项
--       { text = "…", effects = { … } },
--     },
--   }
--
-- 效果（effects 里可以混着写，按顺序执行）：
--   { res = "gold", add = 120 }                      -- 加减资源（含注册型资源，见 Resources.lua）
--   { mod = { key="goldIncome", op="mul", value=0.1, months=12 } }
--                                                    -- 临时修正（走 Modifiers 管道，months 个月后自动撤销）
--   { msg = "……" }                                    -- 往消息栏写一条
--   { hook = "war_declared", payload = { … } }        -- 触发脚本钩子（事件也能被别人挂钩）
--
-- ⚠️ 效果只走"插座"（Resources / Modifiers / Hooks），事件自己不改游戏内部状态 ——
--    这样模组后加的资源/加成，事件一样能用。
--
-- 注册（**模组 / 扩展内容用** · 2026-09-15 补）：
--   local Events = require("data.Events")
--   Events.add{ id="100237_xxx", title="…", text="…", choices={ … } }
--   → **追加**式（只写自己那条，官方的自动留着）；id 撞车时整个替换
-- ============================================================================

local TimeSystem = require("core.TimeSystem")

local Events = {}

-- 月度抽取发生在月初；只限定秋季（本游戏为 7–9 月），不加秋收日门槛。
local function isAutumn()
    return TimeSystem.getSeason() == "秋"
end

-- 说明：这里刻意**不用严格的 @class 标注** —— 事件的 effects 里是"开放结构"
--   （res/mod/msg/hook 各种键），写死类型会让 LSP 报 assign-type-mismatch，
--   而事件表本来就该是"随便加字段"的数据，字段含义见文件头注释。

---@type table[]
Events.defs = {

    -- ---------------------------------------------------------------- 内政
    {
        id = "harvest_good", title = "丰年",
        weight = 12, cond = isAutumn,
        text = "今年风调雨顺，仓廪充实。地方官吏请示：这些余粮该如何处置？",
        choices = {
            {
                text = "入国库（粮草 +120）",
                effects = { { res = "food", add = 120 } },
            },
            {
                text = "赏赐国人（名声 +5）",
                effects = { { res = "prestige", add = 5 },
                            { msg = "国君开仓赏民，国人称颂。" } },
            },
        },
    },
    {
        id = "harvest_bad", title = "歉收",
        weight = 8, cond = isAutumn,
        text = "秋收不佳，仓廪空虚。有大夫进言：不如开仓赈济、减免赋税。",
        choices = {
            {
                text = "开仓减税（粮草 −60，金收入 −5%，持续 12 个月）",
                effects = { { res = "food", add = -60 },
                            { mod = { key = "goldIncome", op = "mul", value = -0.05, months = 12 } },
                            { msg = "朝廷开仓赈济，减免赋税以助国人度荒。" } },
            },
            {
                text = "征集民粮（粮草 +80，名声 −5）",
                effects = { { res = "food", add = 80 }, { res = "prestige", add = -5 },
                            { msg = "朝廷征集民间余粮充实仓廪，国人怨其苛取。" } },
            },
        },
    },

    -- ------------------------------------------------- 变法之议（2026-09-16 重做）
    --   用户设想："事件里出现一个人说他主张什么变法 → 你同不同意 → 同意后
    --   变法面板里就多出这一条"。
    --
    --   ⚠️ 提议人**不是固定名字**（用户："并不是用一些固定的名字，而是随便来一个，
    --      而且他可能是什么官职也可能不是"）→ 本文用占位符，生成时随机取名 + 随机身份：
    --        {who}    = "客卿公孙衍" / "布衣李悝"（身份可能是官职，也可能不是）
    --        {reform} = 变法的名字（见 data/Policies.lua 的 REFORMS）
    --        {desc}   = 变法的效果说明
    --      draft = "reform" 表示"生成时从玩家还没听过的变法里随机挑一条"。
    --
    --   变法全部已知后本条自然不再出现（EventSystem 生成时挑不到就跳过）
    {
        id = "reform_proposal", title = "变法之议",
        weight = 9, once = false,
        speaker = "random",
        draft = "reform",
        text = "{who}上书言事：臣闻「{reform}」之策——{desc}。若行之，可富国强兵。君上意下如何？",
        choices = {
            {
                text = "准（列入变法案）",
                effects = { { reform = "{reform}" },
                            { msg = "{who}所献「{reform}」已列入变法案。" } },
            },
            {
                text = "再议（名声 +2）",
                effects = { { res = "prestige", add = 2 },
                            { msg = "国君未置可否，{who}退下。" } },
            },
        },
    },

    -- ---------------------------------------------------------------- 军事
    {
        -- 2026-09-16：原标题也叫"变法之议"，但它只是临时治军加成、不进变法案，
        --   容易和上面那条搞混 → 改名"整军之议"，并同样用随机提议人
        id = "military_reform", title = "整军之议",
        weight = 6, once = true,
        cond = function(_, f) return f and (f.armySize or 0) > 0 end,
        speaker = "random",
        text = "{who}进言：请整军治武——伍什连坐、军功授爵。此举可强兵，然国内议论纷纷。",
        choices = {
            {
                text = "推行新制（征兵 +15%，持续 24 个月）",
                effects = { { mod = { key = "recruit", op = "mul", value = 0.15, months = 24 } },
                            { msg = "新制推行，军伍为之一新。" } },
            },
            {
                text = "维持旧制（名声 +3）",
                effects = { { res = "prestige", add = 3 },
                            { msg = "国君力排众议，维持旧制。" } },
            },
        },
    },

    -- ---------------------------------------------------------------- 外交
    {
        id = "envoy_gift", title = "远邦来使",
        -- 暂缺真实来使国家/外交后续；保留 id、选项和注册接口供旧数据/模组使用。
        weight = 0,
        text = "远方来使献上珍宝，言辞间似有所求。",
        choices = {
            {
                text = "厚赐来使（金 −40，名声 +6）",
                effects = { { res = "gold", add = -40 }, { res = "prestige", add = 6 },
                            { msg = "厚赐来使，远邦称善。" } },
            },
            {
                text = "收下献礼（金 +40）",
                effects = { { res = "gold", add = 40 },
                            { msg = "收下献礼，来使面有难色。" } },
            },
        },
    },
}

--- 注册一条事件（**模组 / 扩展内容用** · 2026-09-15）
---
--- 为什么要有它：
---   原来模组想加事件，只能**整张表替换** `Events.defs` —— 那就得把官方这几条**抄一遍**，
---   官方一更新模组就过时；两个模组都加事件时，后加载的还会把前面的**整张挤掉**。
---   有了这个口，模组**只写自己那条**，官方的自动留着（和 `Policies.addCard` / `Cultures.add` 一样是**追加**式）。
---
--- 用法：
---   local Events = require("data.Events")
---   Events.add{
---     id = "100237_meng_zhi_meng",   -- ⚠️ 建议带自己的模组前缀，避免和官方/别的模组撞 id
---     title = "弭兵之盟", text = "……", weight = 8,
---     choices = { { text = "歃血为盟（名声 +10）", effects = { { res = "prestige", add = 10 } } } },
---   }
---
--- id 撞车时：**后来的整个替换掉前面的** —— 模组想改官方某条事件也是这么干
---@param def table { id, title, text, choices, weight?, once?, cond?, minYear?, maxYear? }
---@return boolean ok
---@return string|nil reason
function Events.add(def)
    if type(def) ~= "table" or not def.id then return false, "事件必须有 id" end
    if not def.title then return false, "事件必须有 title" end
    if type(def.choices) ~= "table" or #def.choices == 0 then
        return false, "事件至少要有一个选项（choices）"
    end
    if def.weight == nil then def.weight = 10 end       -- 不写权重就按 10（和其它条目一致）

    for i, e in ipairs(Events.defs) do
        if e.id == def.id then
            Events.defs[i] = def        -- 撞 id → 整个替换
            return true, nil
        end
    end
    Events.defs[#Events.defs + 1] = def
    return true, nil
end

--- 按 id 取事件定义
---@param id string
---@return table|nil
function Events.get(id)
    for _, e in ipairs(Events.defs) do
        if e.id == id then return e end
    end
    return nil
end

return Events

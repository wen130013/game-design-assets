-- ============================================================================
-- Policies.lua — 政策 / 变法数据表（"插座"第五块 · 2026-09-13）
--
-- 2026-09-17 **政策改成"光谱轴"**（用户拍板："它有中间，然后偏左偏右……
--   而不是各个方面都有，这不太符合政策"）：
--     一条政策 = 一条轴，轴上只有**左倾 / 中道 / 右倾**几个立场（税率是四档），
--     玩家在轴上挪位置 —— 而不是从一堆互不相干的卡里挑。像 HOI4 的政令条。
--
--   一条轴：
--     { id="经济", name="经济",
--       options = {                       -- 从左到右，**档位顺序即光谱顺序**
--         { id="重农", effects={ food=0.20, gold=-0.12 } },   -- 左
--         { id="平准", effects={ gold=0.05, food=0.05 } },    -- 中
--         { id="重商", effects={ gold=0.20, food=-0.12 } },   -- 右
--       },
--       default = 2 }                     -- 开局默认站哪一档（中道）
--
--   effects 键（全部是**百分比增减 / 每月点数**，长期持续，不花一次性代价）：
--     见 Policies.ATTR_NAMES；数值正 = 加成，负 = 代价。
--     ⚠️ 中道档可以什么都不给（如税率的标准档 = effects 空表），那是"不作为"。
--
--   一个变法（一次性大改革）：由事件里"有人上书"解锁后才出现在面板上。
--     { id="商鞅变法", who="商鞅", desc="…", gold=0.20,
--       cost={ gold=200, prestige=50 },
--       penalty={ months=24, stability=-2 } }
--
-- 注册（模组/事件/编辑器用）：
--   local Policies = require("data.Policies")
--   Policies.addAxis{ id="官制", name="官制", options={ … }, default=1 }
--   Policies.addReform{ id="吴起变法", desc="…", military=0.2, cost={ gold=180 } }
--
-- ⚠️ id 是**稳定标识**（存档里存的是 id），别改已发布内容的 id；显示名/描述随便改。
-- ============================================================================

local Policies = {}

--- 属性显示名（面板文案用；也是**可用的 effects 键**）
---   2026-09-16 用户："要按比例的、以后一直持续的" → 政策效果只用这些**百分比**属性
Policies.ATTR_NAMES = {
    gold      = "金钱收入",
    food      = "粮草产出",
    popGrowth = "人口增长",
    recruit   = "征兵",
    military  = "战斗力",
    defense   = "防御",
    stability = "稳定",     -- 唯一按月结算的点数（+1 = 每月 +1）
}

--- 政策轴（数组，顺序即 UI 显示顺序）：左倾 → 中道 → 右倾
---@type table[]
Policies.AXES = {
    {
        id = "tax", name = "税率",
        options = {
            -- 左：藏富于民 → 钱少但人口涨、民心稳
            { id = "低税", effects = { gold = -0.15, popGrowth = 0.15, stability = 1 } },
            -- 中：标准（既不激励也不苛待）
            { id = "标准", effects = {} },
            -- 右：多收但伤民
            { id = "高税", effects = { gold = 0.15, popGrowth = -0.08, stability = -1 } },
            { id = "压榨", effects = { gold = 0.35, popGrowth = -0.20, stability = -3 } },
        },
        default = 2,
    },
    {
        id = "economy", name = "经济",
        options = {
            { id = "重农", effects = { food = 0.20, gold = -0.12 } },
            { id = "平准", effects = { gold = 0.05, food = 0.05 } },
            { id = "重商", effects = { gold = 0.20, food = -0.12 } },
        },
        default = 2,
    },
    {
        id = "domestic", name = "内政",
        options = {
            { id = "仁政", effects = { popGrowth = 0.20, recruit = -0.12 } },
            { id = "礼乐", effects = { popGrowth = 0.08, stability = 1 } },
            { id = "严法", effects = { recruit = 0.15, popGrowth = -0.12 } },
        },
        default = 2,
    },
    {
        id = "military", name = "军事",
        options = {
            { id = "固守", effects = { defense = 0.20, military = -0.10 } },
            { id = "均衡", effects = { military = 0.05, defense = 0.05 } },
            { id = "尚武", effects = { military = 0.15, recruit = 0.10, popGrowth = -0.10 } },
        },
        default = 2,
    },
}

--- 变法改革（一次性大决策）：数组，顺序即 UI 显示顺序
---   **2026-09-16 两处改动**（用户拍板）：
---   ① **跨代**——不再全是春秋战国，从春秋一路到清（名人变法各有"提出者 who"）
---   ② **由人提出**——变法**开局不可用**：要等"某人上书主张变法"的事件，
---      你同意后才**解锁**（`PolicySystem.unlockReform`）——面板上才出现这一条
---@type table[]
Policies.REFORMS = {
    -- 春秋
    {
        id = "管仲相齐", who = "管仲", desc = "金钱 +20%、粮草 +10%",
        gold = 0.20, food = 0.10,
        cost = { gold = 120, prestige = 30 },
        penalty = { months = 12, stability = -1 },
    },
    -- 战国
    {
        id = "李悝变法", who = "李悝", desc = "粮草 +25%，人口增长 +10%",
        food = 0.25, popGrowth = 0.10,
        cost = { gold = 150, prestige = 40 },
        penalty = { months = 12, stability = -1 },
    },
    {
        id = "吴起变法", who = "吴起", desc = "征兵 +15%、战力 +10%",
        recruit = 0.15, military = 0.10,
        cost = { gold = 130, prestige = 40 },
        penalty = { months = 12, stability = -1 },
    },
    {
        id = "商鞅变法", who = "商鞅", desc = "金钱 +20%，稳定长期受损",
        gold = 0.20,
        cost = { gold = 200, prestige = 50 },
        penalty = { months = 24, stability = -2 },
    },
    {
        id = "胡服骑射", who = "赵武灵王", desc = "战力 +15%，征兵上限 +15%",
        military = 0.15, recruit = 0.15,
        cost = { gold = 150, prestige = 50 },
        penalty = { months = 12, stability = -1 },
    },
    {
        id = "废井田", who = "商鞅", desc = "金钱 +10%，粮草 +10%",
        gold = 0.10, food = 0.10,
        cost = { gold = 120 },
        penalty = { months = 8, stability = -1 },
    },
    -- 秦汉
    {
        id = "郡县天下", who = "李斯", desc = "金钱 +10%、稳定 +1/月",
        gold = 0.10, stability = 1,
        cost = { gold = 180, prestige = 50 },
        penalty = { months = 18, stability = -1 },
    },
    {
        id = "盐铁官营", who = "桑弘羊", desc = "金钱 +25%",
        gold = 0.25,
        cost = { gold = 200, prestige = 40 },
        penalty = { months = 18, stability = -2 },
    },
    {
        id = "推恩令", who = "主父偃", desc = "稳定 +2/月、金钱 +5%",
        stability = 2, gold = 0.05,
        cost = { gold = 160, prestige = 60 },
        penalty = { months = 12, stability = -1 },
    },
    -- 隋唐
    {
        id = "科举取士", who = "房玄龄", desc = "人口 +15%、稳定 +1/月",
        popGrowth = 0.15, stability = 1,
        cost = { gold = 200, prestige = 60 },
        penalty = { months = 24, stability = -1 },
    },
    {
        id = "两税法", who = "杨炎", desc = "金钱 +15%、粮草 +10%",
        gold = 0.15, food = 0.10,
        cost = { gold = 220, prestige = 50 },
        penalty = { months = 18, stability = -1 },
    },
    -- 宋
    {
        id = "王安石变法", who = "王安石", desc = "金钱 +20%、粮草 +15%，稳定受损",
        gold = 0.20, food = 0.15,
        cost = { gold = 260, prestige = 70 },
        penalty = { months = 24, stability = -2 },
    },
    -- 明
    {
        id = "张居正改革", who = "张居正", desc = "金钱 +20%、粮草 +10%，稳定受损",
        gold = 0.20, food = 0.10,
        cost = { gold = 280, prestige = 70 },
        penalty = { months = 24, stability = -2 },
    },
    -- 清
    {
        id = "摊丁入亩", who = "雍正", desc = "人口 +20%、金钱 +10%",
        popGrowth = 0.20, gold = 0.10,
        cost = { gold = 300, prestige = 80 },
        penalty = { months = 18, stability = -1 },
    },
}

-- ---------------------------------------------------------------------------
-- 注册口（模组 / 事件 / 编辑器用）
-- ---------------------------------------------------------------------------
--- 加一条政策轴（同 id 视为覆盖）
---@param axis table { id, name, options={ {id, effects}, ... }, default }
---@return table axis
function Policies.addAxis(axis)
    assert(type(axis) == "table" and axis.id and type(axis.options) == "table",
        "addAxis 需要 axis.id 和 axis.options")
    for i = 1, #Policies.AXES do
        if Policies.AXES[i].id == axis.id then
            Policies.AXES[i] = axis
            return axis
        end
    end
    Policies.AXES[#Policies.AXES + 1] = axis
    return axis
end

--- 加一个变法（同 id 视为覆盖）
---@param reform table { id, desc, cost, penalty, gold/food/… }
---@return table reform
function Policies.addReform(reform)
    assert(type(reform) == "table" and reform.id, "addReform 需要 reform.id")
    for i = 1, #Policies.REFORMS do
        if Policies.REFORMS[i].id == reform.id then
            Policies.REFORMS[i] = reform
            return reform
        end
    end
    Policies.REFORMS[#Policies.REFORMS + 1] = reform
    return reform
end

--- 某变法在不在表里
---@param reformId string
---@return boolean
function Policies.hasReform(reformId)
    for _, r in ipairs(Policies.REFORMS) do
        if r.id == reformId then return true end
    end
    return false
end

return Policies

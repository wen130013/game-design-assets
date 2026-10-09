-- ============================================================================
-- Interactions.lua — 国交行动表（2026-09-16）
--
-- 用户设想（原话要点）：
--   ① "点击别人的国家，都会出现我和对方交流的，不管是什么暗杀对方的首领、
--      或者间谍之类的，而不只是现在的宣战" → 点别国省份要弹**一整排国交动作**
--   ② "先把内容做出来，能不能用先不管" → 先把条目/说明/入口做出来
--   ③ "外交如果点出宣战，它会自动弹跳到外边，然后点任何的国家就是立刻宣战，
--      并且……可以拉远点儿一涂抹直接向他们宣战" → 选完动作回到地图，
--      **点/涂抹国家**即执行（`paintable = true` 的动作支持涂抹）
--
-- 一条行动：
--   id       稳定标识（存档/日志用）
--   name     按钮文字
--   desc     说明（面板底部提示行显示）
--   kind     "hostile" | "friendly" | "neutral"（决定按钮配色）
--   impl     是否已实现：**false 的点了会提示"尚未开放"**（内容先摆出来）
--   paintable 是否支持"地图涂抹"批量执行（一次涂抹对碰到的每个国家各触发一次）
--   diplo    是否出现在"外交关系"面板的行动栏里
--
-- ⚠️ 加新动作 = 往下面表里加一条（系统代码不用动）；
--    真正执行的地方在 main.lua 的 `RunInteraction()`（按 id 分发）。
-- ============================================================================

local Interactions = {}

Interactions.LABEL = "国交行动"   -- UI 上这一排按钮的标题

---@type table[]
Interactions.ACTIONS = {
    {
        id = "war", name = "宣战", kind = "hostile",
        desc = "对其开战，可攻占其领土",
        impl = true, paintable = true, diplo = true,
    },
    {
        id = "improve", name = "改善关系", kind = "friendly",
        desc = "花金钱提升两国关系",
        impl = true, paintable = true, diplo = true,
    },
    {
        id = "peace", name = "求和", kind = "neutral",
        desc = "向其提出停战与割地条件",
        impl = true, paintable = false, diplo = true,
    },
    -- ↓ 以下为 2026-09-16 先摆出来的"内容"（用户："能不能用先不管"）
    {
        id = "gift", name = "赠礼", kind = "friendly",
        desc = "馈赠财货，快速提升两国关系",
        impl = false, paintable = true, diplo = true,
    },
    {
        id = "assassinate", name = "暗杀", kind = "hostile",
        desc = "遣死士刺杀其君主，可能引发内乱",
        impl = false, paintable = false, diplo = true,
    },
    {
        id = "spy", name = "间谍", kind = "hostile",
        desc = "派细作潜伏：窃取情报、破坏城防",
        impl = false, paintable = true, diplo = true,
    },
    {
        id = "instigate", name = "挑拨", kind = "hostile",
        desc = "煽动其与他国开战",
        impl = false, paintable = false, diplo = true,
    },
}

--- 按 id 取一条行动
---@param id string
---@return table|nil
function Interactions.get(id)
    for _, a in ipairs(Interactions.ACTIONS) do
        if a.id == id then return a end
    end
    return nil
end

--- 外交面板行动栏用的那几条
---@return table[]
function Interactions.diploList()
    local list = {}
    for _, a in ipairs(Interactions.ACTIONS) do
        if a.diplo then list[#list + 1] = a end
    end
    return list
end

return Interactions

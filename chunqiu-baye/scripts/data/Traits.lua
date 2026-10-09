-- ============================================================================
-- Traits.lua — 人物特质表（2026-09-17，照 CK3 那套）
--
-- 用户："这些特质直接复制别的游戏十字军之王三" → 按 CK3 的分类来：
--   * 性格：德行 / 罪恶成对（勇敢↔怯懦、勤勉↔懒惰、慷慨↔贪婪…）
--   * 教育：五系（军事/外交/管理/谋略/学识）各三档
--   * 先天：天才/聪慧/迟钝/愚钝、强壮/虚弱、美貌/丑陋…
--   * 健康：强健 / 病弱
--
-- 一条特质长这样：
--   { id = "勇敢", kind = "性格", desc = "战力 +5%，勇冠三军",
--     attr = { military = 2 },            -- 改**这个人**的五维（上任后通过职位加成生效）
--     mods = { militaryPower = 0.05 } }   -- 只要此人在位就吃到的**国家**加成
--
-- ⚠️ 设计约束（世界很大时也不怕 · 2026-09-17 用户担心 1000 国）：
--   ① 本表**全局共享**，不随人物数量增长（1000 国 16000 人也是这一份）
--   ② 效果**按势力聚合**注册（见 CharacterSystem.registerModifiers），
--      不是"每个人注册一条规则" —— 否则每月结算要遍历上万个修正器
--   ③ 每个角色最多 3 个特质（Traits.MAX_PER_CHAR）
--   ④ 存档只写特质 id（中文名即 id，字符串共享）
--
-- 可用 mods 键 = Modifiers.KEYS 清单（goldIncome/foodIncome/popGrowth/recruit/
--   militaryPower/defensePower/diploImprove/stabilityDelta），填错会被管道警告。
-- ============================================================================

local Traits = {}

--- 每人最多几个特质（照 CK3：性格最多 3 个）
Traits.MAX_PER_CHAR = 3

--- 分类名（UI 分组/调试用）
Traits.KINDS = { "性格", "教育", "先天", "健康", "将领", "生活", "名声", "伤病" }

--- 特质表（id 就是中文名 → 显示/存档共用一份，UI 直接显示 c.traits）
---@type table[]
Traits.LIST = {
    -- ===================== 性格：德行 =====================
    { id = "慷慨", kind = "性格", desc = "金钱收入 −3%，但民心安稳",
      attr = { diplomacy = 1 }, mods = { goldIncome = -0.03, stabilityDelta = 0.3 } },
    { id = "诚实", kind = "性格", desc = "外交更容易谈成",
      attr = { diplomacy = 1 }, mods = { diploImprove = 1 } },
    { id = "仁慈", kind = "性格", desc = "稳定 +0.5/月，征兵略减",
      attr = { diplomacy = 1 }, mods = { stabilityDelta = 0.5, recruit = -0.03 } },
    { id = "勇敢", kind = "性格", desc = "战力 +5%，军事 +2",
      attr = { military = 2 }, mods = { militaryPower = 0.05 } },
    { id = "冷静", kind = "性格", desc = "稳定 +0.4/月",
      attr = { diplomacy = 1 }, mods = { stabilityDelta = 0.4 } },
    { id = "勤勉", kind = "性格", desc = "金/粮收入 +5%",
      attr = { management = 1 }, mods = { goldIncome = 0.05, foodIncome = 0.05 } },
    { id = "节制", kind = "性格", desc = "人口增长 +5%",
      attr = { learning = 1 }, mods = { popGrowth = 0.05 } },
    { id = "谦卑", kind = "性格", desc = "外交 +1、稳定 +0.3/月",
      attr = { diplomacy = 1 }, mods = { diploImprove = 1, stabilityDelta = 0.3 } },
    { id = "知足", kind = "性格", desc = "稳定 +0.4/月，不喜扩张",
      attr = { management = 1 }, mods = { stabilityDelta = 0.4 } },
    { id = "信任", kind = "性格", desc = "外交 +1，但易受人欺",
      attr = { diplomacy = 1, intrigue = -1 }, mods = { diploImprove = 1 } },
    { id = "合群", kind = "性格", desc = "外交 +1",
      attr = { diplomacy = 1 }, mods = { diploImprove = 1 } },
    { id = "公正", kind = "性格", desc = "稳定 +0.5/月",
      attr = { management = 1 }, mods = { stabilityDelta = 0.5 } },
    { id = "孤僻", kind = "性格", desc = "学识 +1，不善外交",
      attr = { learning = 1 }, mods = { diploImprove = -1 } },

    -- ===================== 性格：罪恶 =====================
    { id = "贪婪", kind = "性格", desc = "金钱 +6%，稳定 −0.3/月",
      attr = { management = 1 }, mods = { goldIncome = 0.06, stabilityDelta = -0.3 } },
    { id = "狡诈", kind = "性格", desc = "谋略 +2，外交受阻",
      attr = { intrigue = 2 }, mods = { diploImprove = -1 } },
    { id = "冷酷", kind = "性格", desc = "征兵 +5%，稳定 −0.4/月",
      attr = { intrigue = 1 }, mods = { recruit = 0.05, stabilityDelta = -0.4 } },
    { id = "怯懦", kind = "性格", desc = "防御 +5%，军事 −1",
      attr = { military = -1 }, mods = { defensePower = 0.05 } },
    { id = "暴躁", kind = "性格", desc = "战力 +5%，外交 −1",
      attr = { military = 1 }, mods = { militaryPower = 0.05, diploImprove = -1 } },
    { id = "懒惰", kind = "性格", desc = "管理 −1，人口 −5%",
      attr = { management = -1 }, mods = { popGrowth = -0.05 } },
    { id = "放纵", kind = "性格", desc = "金钱 −5%，谋略 +1",
      attr = { intrigue = 1 }, mods = { goldIncome = -0.05, popGrowth = -0.03 } },
    { id = "傲慢", kind = "性格", desc = "战力 +5%，外交 −1",
      attr = { military = 1 }, mods = { militaryPower = 0.05, diploImprove = -1 } },
    { id = "野心勃勃", kind = "性格", desc = "征兵 +5%、金钱 +5%，稳定 −0.3/月",
      attr = { intrigue = 1 }, mods = { recruit = 0.05, goldIncome = 0.05, stabilityDelta = -0.3 } },
    { id = "多疑", kind = "性格", desc = "谋略 +2，外交 −1",
      attr = { intrigue = 2 }, mods = { diploImprove = -1 } },
    { id = "专断", kind = "性格", desc = "征兵 +5%，稳定 −0.4/月",
      attr = { military = 1 }, mods = { recruit = 0.05, stabilityDelta = -0.4 } },

    -- ===================== 教育（五系 × 三档） =====================
    { id = "略知兵法", kind = "教育", desc = "军事 +1", attr = { military = 1 } },
    { id = "精于兵道", kind = "教育", desc = "军事 +2、战力 +2%",
      attr = { military = 2 }, mods = { militaryPower = 0.02 } },
    { id = "用兵如神", kind = "教育", desc = "军事 +3、战力 +6%",
      attr = { military = 3 }, mods = { militaryPower = 0.06 } },

    { id = "通晓礼仪", kind = "教育", desc = "外交 +1", attr = { diplomacy = 1 } },
    { id = "善于辞令", kind = "教育", desc = "外交 +2、改善关系 +1",
      attr = { diplomacy = 2 }, mods = { diploImprove = 1 } },
    { id = "纵横捭阖", kind = "教育", desc = "外交 +3、改善关系 +2",
      attr = { diplomacy = 3 }, mods = { diploImprove = 2 } },

    { id = "粗通账目", kind = "教育", desc = "管理 +1", attr = { management = 1 } },
    { id = "理财有方", kind = "教育", desc = "管理 +2、金钱 +3%",
      attr = { management = 2 }, mods = { goldIncome = 0.03 } },
    { id = "经世之才", kind = "教育", desc = "管理 +3、金钱 +5%、粮草 +5%",
      attr = { management = 3 }, mods = { goldIncome = 0.05, foodIncome = 0.05 } },

    { id = "略知权谋", kind = "教育", desc = "谋略 +1", attr = { intrigue = 1 } },
    { id = "深谙人心", kind = "教育", desc = "谋略 +2、稳定 +0.3/月",
      attr = { intrigue = 2 }, mods = { stabilityDelta = 0.3 } },
    { id = "算无遗策", kind = "教育", desc = "谋略 +3、稳定 +0.5/月",
      attr = { intrigue = 3 }, mods = { stabilityDelta = 0.5 } },

    { id = "涉猎群书", kind = "教育", desc = "学识 +1", attr = { learning = 1 } },
    { id = "博学多闻", kind = "教育", desc = "学识 +2、人口 +3%",
      attr = { learning = 2 }, mods = { popGrowth = 0.03 } },
    { id = "学贯古今", kind = "教育", desc = "学识 +3、人口 +6%",
      attr = { learning = 3 }, mods = { popGrowth = 0.06 } },

    -- ===================== 先天 =====================
    { id = "天才", kind = "先天", desc = "五维各 +2（百年一遇）",
      attr = { diplomacy = 2, military = 2, management = 2, intrigue = 2, learning = 2 } },
    { id = "聪慧", kind = "先天", desc = "五维各 +1",
      attr = { diplomacy = 1, military = 1, management = 1, intrigue = 1, learning = 1 } },
    { id = "迟钝", kind = "先天", desc = "五维各 −1",
      attr = { diplomacy = -1, military = -1, management = -1, intrigue = -1, learning = -1 } },
    { id = "愚钝", kind = "先天", desc = "五维各 −2",
      attr = { diplomacy = -2, military = -2, management = -2, intrigue = -2, learning = -2 } },
    { id = "强壮", kind = "先天", desc = "军事 +2、战力 +4%",
      attr = { military = 2 }, mods = { militaryPower = 0.04 } },
    { id = "虚弱", kind = "先天", desc = "军事 −1、征兵 −4%",
      attr = { military = -1 }, mods = { recruit = -0.04 } },
    { id = "美貌", kind = "先天", desc = "外交 +2",
      attr = { diplomacy = 2 }, mods = { diploImprove = 1 } },
    { id = "丑陋", kind = "先天", desc = "外交 −1",
      attr = { diplomacy = -1 }, mods = { diploImprove = -1 } },
    { id = "巨人", kind = "先天", desc = "军事 +2，但不耐久",
      attr = { military = 2 }, mods = { recruit = -0.03 } },
    { id = "侏儒", kind = "先天", desc = "谋略 +1、军事 −1",
      attr = { intrigue = 1, military = -1 } },

    -- ===================== 健康 =====================
    { id = "强健", kind = "健康", desc = "人口 +3%、稳定 +0.2/月",
      mods = { popGrowth = 0.03, stabilityDelta = 0.2 } },
    { id = "病弱", kind = "健康", desc = "稳定 −0.3/月、征兵 −3%",
      mods = { stabilityDelta = -0.3, recruit = -0.03 } },

    -- ===================== 将领（**只有担任军职时才生效**） =====================
    --   2026-09-17 用户："为什么你这个只有文的没有武"
    --   载体：大将军 / 兵部尚书（见 CharacterSystem.MILITARY_POSTS）——
    --   不掌兵的人挂着这些特质也不生效，跟 CK3 的 commander traits 一个道理
    { id = "组织者", kind = "将领", militaryOnly = true, desc = "行军有方，战力 +4%",
      mods = { militaryPower = 0.04 } },
    { id = "攻城专家", kind = "将领", militaryOnly = true, desc = "善攻坚城，战力 +5%",
      mods = { militaryPower = 0.05 } },
    { id = "侧翼专家", kind = "将领", militaryOnly = true, desc = "善出奇兵，战力 +4%、防御 +3%",
      mods = { militaryPower = 0.04, defensePower = 0.03 } },
    { id = "激励者", kind = "将领", militaryOnly = true, desc = "士气如虹，征兵 +5%",
      mods = { recruit = 0.05 } },
    { id = "严酷", kind = "将领", militaryOnly = true, desc = "军纪严明，征兵 +4%、稳定 −0.2/月",
      mods = { recruit = 0.04, stabilityDelta = -0.2 } },
    { id = "后勤专家", kind = "将领", militaryOnly = true, desc = "粮道不绝，粮草 +6%",
      mods = { foodIncome = 0.06 } },
    { id = "冬季战士", kind = "将领", militaryOnly = true, desc = "不惧严寒，防御 +6%",
      mods = { defensePower = 0.06 } },
    { id = "掠夺者", kind = "将领", militaryOnly = true, desc = "以战养战，金钱 +7%、稳定 −0.3/月",
      mods = { goldIncome = 0.07, stabilityDelta = -0.3 } },
    { id = "战术家", kind = "将领", militaryOnly = true, desc = "临阵制变，军事 +2、战力 +6%",
      attr = { military = 2 }, mods = { militaryPower = 0.06 } },

    -- ===================== 生活（CK3 的 lifestyle 那类） =====================
    { id = "诗人", kind = "生活", desc = "文采风流，稳定 +0.3/月",
      attr = { learning = 1 }, mods = { stabilityDelta = 0.3 } },
    { id = "学者", kind = "生活", desc = "埋首典籍，学识 +2、人口 +3%",
      attr = { learning = 2 }, mods = { popGrowth = 0.03 } },
    { id = "猎手", kind = "生活", desc = "弓马娴熟，军事 +1、战力 +3%",
      attr = { military = 1 }, mods = { militaryPower = 0.03 } },
    { id = "酒徒", kind = "生活", desc = "沉湎杯中，管理 −1、稳定 −0.2/月",
      attr = { management = -1 }, mods = { stabilityDelta = -0.2 } },
    { id = "隐士", kind = "生活", desc = "不问世事，稳定 +0.4/月、征兵 −4%",
      mods = { stabilityDelta = 0.4, recruit = -0.04 } },
    { id = "游侠", kind = "生活", desc = "仗剑江湖，军事 +1、外交 +1",
      attr = { military = 1, diplomacy = 1 } },
    { id = "弈者", kind = "生活", desc = "手谈自娱，谋略 +1、稳定 +0.2/月",
      attr = { intrigue = 1 }, mods = { stabilityDelta = 0.2 } },

    -- ===================== 名声与恶名（吃「名声」那条口：prestigeDelta） =====================
    { id = "忠义", kind = "名声", desc = "名声 +0.5/月，外交 +1",
      attr = { diplomacy = 1 }, mods = { prestigeDelta = 0.5, diploImprove = 1 } },
    { id = "侠名", kind = "名声", desc = "名声 +0.3/月，征兵 +3%",
      mods = { prestigeDelta = 0.3, recruit = 0.03 } },
    { id = "清誉", kind = "名声", desc = "名声 +0.4/月，稳定 +0.2/月",
      mods = { prestigeDelta = 0.4, stabilityDelta = 0.2 } },
    { id = "残暴", kind = "名声", desc = "名声 −0.5/月，征兵 +5%、稳定 −0.3/月",
      mods = { prestigeDelta = -0.5, recruit = 0.05, stabilityDelta = -0.3 } },
    { id = "弑亲者", kind = "名声", desc = "名声 −1/月，稳定 −0.5/月",
      mods = { prestigeDelta = -1.0, stabilityDelta = -0.5 } },
    { id = "背誓者", kind = "名声", desc = "名声 −0.8/月，外交 −1",
      mods = { prestigeDelta = -0.8, diploImprove = -1 } },

    -- ===================== 伤病与残疾（CK3 的 health/wound 那类） =====================
    { id = "受伤", kind = "伤病", desc = "军事 −1、征兵 −3%",
      attr = { military = -1 }, mods = { recruit = -0.03 } },
    { id = "重伤", kind = "伤病", desc = "军事 −2、稳定 −0.2/月",
      attr = { military = -2 }, mods = { stabilityDelta = -0.2 } },
    { id = "残废", kind = "伤病", desc = "军事 −3、征兵 −6%",
      attr = { military = -3 }, mods = { recruit = -0.06 } },
    { id = "久病", kind = "伤病", desc = "管理 −1、人口 −3%",
      attr = { management = -1 }, mods = { popGrowth = -0.03 } },
    { id = "失明", kind = "伤病", desc = "学识 +1、军事 −2",
      attr = { learning = 1, military = -2 } },

    -- ===================== 教育：各系第 4 档（照 CK3 是 4 档） =====================
    { id = "兵家之圣", kind = "教育", desc = "军事 +4、战力 +8%",
      attr = { military = 4 }, mods = { militaryPower = 0.08 } },
    { id = "折冲樽俎", kind = "教育", desc = "外交 +4、改善关系 +3",
      attr = { diplomacy = 4 }, mods = { diploImprove = 3 } },
    { id = "富国之才", kind = "教育", desc = "管理 +4、金钱 +7%、粮草 +7%",
      attr = { management = 4 }, mods = { goldIncome = 0.07, foodIncome = 0.07 } },
    { id = "运筹帷幄", kind = "教育", desc = "谋略 +4、稳定 +0.7/月",
      attr = { intrigue = 4 }, mods = { stabilityDelta = 0.7 } },
    { id = "通天地人", kind = "教育", desc = "学识 +4、人口 +8%",
      attr = { learning = 4 }, mods = { popGrowth = 0.08 } },
}

--- id → 定义（加载时建一次）
---@type table<string, table>
Traits.BY_ID = {}
for _, t in ipairs(Traits.LIST) do
    Traits.BY_ID[t.id] = t
end

--- 按 id 取定义
---@param id string
---@return table|nil
function Traits.get(id)
    return Traits.BY_ID[id]
end

--- 某类特质的 id 列表（抽签用）
---@param kind string "性格"|"教育"|"先天"|"健康"
---@return string[]
function Traits.idsOfKind(kind)
    local out = {}
    for _, t in ipairs(Traits.LIST) do
        if t.kind == kind then out[#out + 1] = t.id end
    end
    return out
end

--- 随机特质 id
---@param kind string|nil 不传 = 从全部里抽
---@param avoid table|nil 已有的（避免重复）
---@return string|nil
function Traits.randomId(kind, avoid)
    local pool = kind and Traits.idsOfKind(kind) or nil
    local n = pool and #pool or #Traits.LIST
    for _ = 1, 12 do   -- 最多试 12 次，避免死循环
        local id = pool and pool[math.random(1, n)] or Traits.LIST[math.random(1, n)].id
        if not (avoid and avoid[id]) then return id end
    end
    return nil
end

--- 给一个人物抽特质（就地改 c.traits）
---   规则（照 CK3 的观感）：1 个性格必抽，再加 1 个别的类；约 1/4 的人再多一个；
---   上了年纪（≥55）另有三成概率带个伤病
---@param char table
---@param count number|nil 默认 2
function Traits.roll(char, count)
    count = count or 2
    char.traits = char.traits or {}
    local have = {}
    for _, id in ipairs(char.traits) do have[id] = true end

    -- 第 1 个必是性格；其余从"其它类"里抽（将领/生活/名声/伤病都算，
    -- 将领特质挂着不生效、掌兵后才生效，正好符合"人还是那个人"）
    local others = { "教育", "教育", "先天", "生活", "名声", "将领", "健康" }
    local plan = { "性格" }
    for i = 2, math.min(count, Traits.MAX_PER_CHAR) do
        plan[i] = others[math.random(1, #others)]
    end

    for i = 1, math.min(count, Traits.MAX_PER_CHAR) do
        local id = Traits.randomId(plan[i] or "性格", have)
        if id then
            char.traits[#char.traits + 1] = id
            have[id] = true
        end
    end

    -- 年长者的伤病（CK3 里打仗/上了年纪会带伤）
    if (char.age or 0) >= 55 and math.random() < 0.3 and #char.traits < Traits.MAX_PER_CHAR then
        local id = Traits.randomId("伤病", have)
        if id then char.traits[#char.traits + 1] = id end
    end
end

--- 把特质带来的**属性修正**加到人物五维上（生成时调一次；已加过就跳过）
---   存 base 值 → 只加差值，重复调用不会越加越多
---@param char table
function Traits.applyAttrs(char)
    if not char or not char.traits then return end
    if char._traitAttrApplied then return end
    char._traitAttrApplied = true
    local keys = { "diplomacy", "military", "management", "intrigue", "learning" }
    for _, id in ipairs(char.traits) do
        local def = Traits.BY_ID[id]
        if def and def.attr then
            for _, k in ipairs(keys) do
                local d = def.attr[k]
                if d then
                    local cur = char[k] or 3
                    char[k] = math.max(1, math.min(10, cur + d))
                end
            end
        end
    end
end

--- 汇总一组人物的特质 mods（**按势力聚合**用）
---   2026-09-17：`militaryOnly` 的**将领特质**只有在那个人**掌兵**（军职）时才计入 ——
---   没带兵的人挂着"攻城专家"不该给全国加成
---@param chars table[] 参与的人（君主 + 有职位的）
---@return table<string, number> key → 合计加成
function Traits.sumMods(chars)
    local out = {}
    for _, c in ipairs(chars) do
        local inArmy = c.post ~= nil and Traits.MILITARY_POSTS[c.post] == true
        for _, id in ipairs(c.traits or {}) do
            local def = Traits.BY_ID[id]
            if def and def.mods and not (def.militaryOnly and not inArmy) then
                for k, v in pairs(def.mods) do
                    out[k] = (out[k] or 0) + v
                end
            end
        end
    end
    return out
end

--- 军职（将军特质只有挂在这些位置上才生效）—— 与 CharacterSystem.POSTS 的 id 对齐
Traits.MILITARY_POSTS = {
    generalissimo = true,   -- 大将军
    minister_war  = true,   -- 兵部尚书
}

return Traits

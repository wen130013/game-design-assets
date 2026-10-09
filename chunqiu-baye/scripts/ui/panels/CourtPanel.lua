-- ============================================================================
-- CourtPanel.lua — 朝廷面板（自身 / 官员 / 后宫 / 任命）（2026-09-26 从 GameUI.lua 拆出）
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：导出 create(ctx) / install(GameUI)，
-- ctx 注入 UI/GameUI/refs/COLORS/SmallButton，**不 require GameUI**（避免循环依赖）。
--
-- 本模块代码原样搬自 GameUI.lua，头部声明了同名 upvalue，
-- 所以块内代码一行都不用改；openCourtPick/showCommanderPick/refreshCourtPanel
-- 由 install() 挂回 GameUI 主表。
-- ============================================================================

local M = {}

-- ── 模块级共享引用（create 时注入）──────────────────────────────
---@type any
local UI
---@type any
local GameUI
---@type table
local refs
---@type table
local COLORS
---@type function
local SmallButton
---@type table
local TAB_TEXT_ACTIVE
---@type table
local TAB_TEXT_IDLE

local function createSelfPanel(callbacks)
    return require("ui.panels.SelfPanel").create({ refs = refs, GameUI = GameUI, SmallButton = SmallButton })
end


-- ------------------------------------------------------------
-- 朝廷面板：**左=官员**（三公/六部/学官，可任命）**右=后宫**
--   行是每次刷新重建的（ClearChildren + AddChild）——这里元素少、又不是每帧刷，
--   比维护一堆引用简单可靠（跟游玩集面板一个套路）
-- ------------------------------------------------------------
local function createCourtPanel(callbacks)
    refs.courtTitle = UI.Label {
        text = "朝廷", fontSize = 18, fontColor = COLORS.gold, fontWeight = "bold",
    }
    refs.courtOfficeRows  = UI.Panel { width = "100%", gap = 5 }
    refs.courtConsortRows = UI.Panel { width = "100%", gap = 5 }
    -- 君主页 / 将军页 / 人才页（2026-09-28 新增）
    refs.courtRulerRows   = UI.Panel { width = "100%", gap = 5 }
    refs.courtGeneralRows = UI.Panel { width = "100%", gap = 5 }
    -- 人才页：在野/游方士人（可花钱招募）—— 照 CK3 的"访客招募"
    refs.courtTalentRows  = UI.Panel { width = "100%", gap = 5 }

    -- 任命候选弹层（点某职位的「任命」时弹）
    refs.courtPickTitle = UI.Label {
        text = "任命", fontSize = 15, fontColor = COLORS.gold, fontWeight = "bold",
    }
    refs.courtPickRows = UI.Panel { width = "100%", gap = 5 }
    refs.courtPickPanel = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 170 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                id = "courtPickBox", width = "96%", maxWidth = 600, height = "96%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 14,
                gap = 8,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            refs.courtPickTitle,
                            SmallButton("X", function()
                                refs.courtPickPanel:Hide()
                            end, { width = 26, height = 26, paddingH = 0, fontSize = 12, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } }),
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0,
                        children = { refs.courtPickRows } },
                },
            },
        },
    }
    refs.courtPickPanel:Hide()

    -- 人物详情弹层（2026-09-28 第3步）：点人物行 → 看完整信息
    --   内容：姓名/年龄/性别/身份 + 五维（带数值条）+ 特质 + 忠诚 + 现任职位
    --   这是后面"培养/阴谋"的入口（那些操作按钮会加在这里）
    refs.courtDetailTitle = UI.Label {
        text = "人物", fontSize = 16, fontColor = COLORS.gold, fontWeight = "bold",
    }
    refs.courtDetailBody = UI.Panel { width = "100%", gap = 6 }
    refs.courtDetailPanel = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 170 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                id = "courtDetailBox", width = "96%", maxWidth = 600, height = "96%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 14,
                gap = 8,
                children = {
                    UI.Panel {
                        flexDirection = "row", alignItems = "center",
                        justifyContent = "space-between", width = "100%",
                        children = {
                            refs.courtDetailTitle,
                            SmallButton("X", function()
                                refs.courtDetailPanel:Hide()
                            end, { width = 26, height = 26, paddingH = 0, fontSize = 12,
                                   bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } }),
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0,
                        children = { refs.courtDetailBody } },
                },
            },
        },
    }
    refs.courtDetailPanel:Hide()

    local closeBtn = SmallButton("X", function()
        GameUI.hideCourtPanel()
    end, { width = 28, height = 28, paddingH = 0, fontSize = 13, bg = COLORS.transparent, hoverBg = { 80, 40, 40, 200 } })

    -- 两栏内容（**一次只显示一栏**，由顶部的「官员」「后宫」两个按钮切换 ·
    --   2026-09-16 用户拍板："是通过左边右边两个按钮切换，两个都在最上方"）
    refs.courtTabOffice = UI.Panel {
        width = "100%",
        gap = 5,
        children = { refs.courtOfficeRows },
    }
    refs.courtTabConsort = UI.Panel {
        width = "100%",
        gap = 5,
        children = { refs.courtConsortRows },
    }
    -- 君主页（2026-09-28 用户："把角色系统分清楚 主角/官员/后宫/将军"）：
    --   主角 = 国君。单独一页展示五维/特质/年龄，并说明"国君属性影响全国"。
    refs.courtTabRuler = UI.Panel {
        width = "100%",
        gap = 5,
        children = { refs.courtRulerRows },
    }
    -- 将军页：列出各省统帅 + 统兵上限（谁在带兵、能带多少）
    refs.courtTabGeneral = UI.Panel {
        width = "100%",
        gap = 5,
        children = { refs.courtGeneralRows },
    }
    -- 人才页：在野人才 + 花钱招募（2026-09-28）
    refs.courtTabTalent = UI.Panel {
        width = "100%",
        gap = 5,
        children = { refs.courtTalentRows },
    }
    refs.courtTabTalent:Hide()
    refs.courtTabConsort:Hide()
    refs.courtTabRuler:Hide()
    refs.courtTabGeneral:Hide()

    --- 切换朝廷的四个页（ruler = 君主 / office = 官员 / consort = 后宫 / general = 将军）
    ---@param tab string
    local function showCourtTab(tab)
        refs.courtTabRuler:SetVisible(tab == "ruler")
        refs.courtTabOffice:SetVisible(tab == "office")
        refs.courtTabConsort:SetVisible(tab == "consort")
        refs.courtTabGeneral:SetVisible(tab == "general")
        refs.courtTabTalent:SetVisible(tab == "talent")
        local tabs = {
            { refs.courtTabRulerBtn, tab == "ruler" },
            { refs.courtTabOfficeBtn, tab == "office" },
            { refs.courtTabConsortBtn, tab == "consort" },
            { refs.courtTabGeneralBtn, tab == "general" },
            { refs.courtTabTalentBtn, tab == "talent" },
        }
        for _, t in ipairs(tabs) do
            local btn, active = t[1], t[2]
            if btn then
                -- ⚠️ 这里**只能改文字颜色**：SmallButton 铺的是"金漆木牌"九宫格底图，
                --   底色被底图盖住（改 backgroundColor 看不见），而 SPEED_BTN_ACTIVE 的
                --   深色字在深色木牌上等于没字（踩过：选中的那一页看着像禁用）
                btn.props.textColor = active and TAB_TEXT_ACTIVE or TAB_TEXT_IDLE
            end
        end
    end

    -- 四个页签（2026-09-28）：君主 / 官员 / 后宫 / 将军
    --   用户："把角色系统分清楚 —— 主角、他的官员、后宫、以及这个将军"
    local tabRulerBtn = SmallButton("君主", function()
        showCourtTab("ruler")
    end, { id = "courtTabRulerBtn", fontSize = 12, height = 32, flexGrow = 1, textColor = TAB_TEXT_IDLE })
    local tabOfficeBtn = SmallButton("官员", function()
        showCourtTab("office")
    end, { id = "courtTabOfficeBtn", fontSize = 12, height = 32, flexGrow = 1, textColor = TAB_TEXT_ACTIVE })
    local tabConsortBtn = SmallButton("后宫", function()
        showCourtTab("consort")
    end, { id = "courtTabConsortBtn", fontSize = 12, height = 32, flexGrow = 1, textColor = TAB_TEXT_IDLE })
    local tabGeneralBtn = SmallButton("将军", function()
        showCourtTab("general")
    end, { id = "courtTabGeneralBtn", fontSize = 12, height = 32, flexGrow = 1, textColor = TAB_TEXT_IDLE })
    local tabTalentBtn = SmallButton("人才", function()
        showCourtTab("talent")
    end, { id = "courtTabTalentBtn", fontSize = 12, height = 32, flexGrow = 1, textColor = TAB_TEXT_IDLE })
    refs.courtTabRulerBtn = tabRulerBtn
    refs.courtTabOfficeBtn = tabOfficeBtn
    refs.courtTabConsortBtn = tabConsortBtn
    refs.courtTabGeneralBtn = tabGeneralBtn
    refs.courtTabTalentBtn = tabTalentBtn
    showCourtTab("office")

    refs.courtPanel = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 150 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                id = "courtPanelBox", width = "96%", maxWidth = 600, height = "96%",
                backgroundColor = COLORS.bgPanel,
                borderRadius = 8,
                borderWidth = 1,
                borderColor = COLORS.border,
                padding = 16,
                gap = 10,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = { refs.courtTitle, closeBtn },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    -- 四个页签按钮，都在最上方（君主 / 官员 / 后宫 / 将军）
                    -- 两行放五个页签（君主/官员/后宫/将军/人才）——
                    --   五个挤一行在窄屏上会缩到看不清，换成 flexWrap 自动折行
                    UI.Panel {
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 4,
                        width = "100%",
                        children = { tabRulerBtn, tabOfficeBtn, tabConsortBtn, tabGeneralBtn, tabTalentBtn },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    UI.ScrollView {
                        width = "100%", flexGrow = 1, flexBasis = 0, scrollY = true,
                        children = { UI.Panel { width = "100%", children = {
                            refs.courtTabRuler, refs.courtTabOffice, refs.courtTabConsort,
                            refs.courtTabGeneral, refs.courtTabTalent,
                        } } },
                    },
                },
            },
            -- 任命候选弹层 + 人物详情弹层（挂在面板内，随面板一起显隐）
            refs.courtPickPanel,
            refs.courtDetailPanel,
        },
    }
    refs.courtPanel:Hide()
    return refs.courtPanel
end

--- 打开人物详情弹层（2026-09-28 第3步）
---   展示完整信息：身份 / 年龄 / 五维 / 特质 / 忠诚 / 现任职位
---@param gameState table
---@param char table 角色对象
local function openCharDetail(gameState, char)
    if not char or not refs.courtDetailPanel then return end
    local CharacterSystem = require("systems.CharacterSystem")

    -- 身份描述：君主 / 某职位 / 后宫位号 / 在野
    local roleText
    if char.post == "君主" then
        roleText = "国君"
    elseif char.post then
        local pname = char.post
        for _, p in ipairs(CharacterSystem.POSTS) do
            if p.id == char.post then pname = p.name end
        end
        roleText = pname
    elseif char.rank then
        roleText = "后宫 · " .. tostring(char.rank)
    else
        roleText = "在野"
    end

    refs.courtDetailTitle:SetText(char.name or "?")
    refs.courtDetailBody:ClearChildren()

    -- ① 身份行：身份 + 年龄 + 性别
    refs.courtDetailBody:AddChild(UI.Panel {
        flexDirection = "row", alignItems = "center", gap = 10, width = "100%",
        children = {
            UI.Label { text = roleText, fontSize = 13, fontColor = COLORS.gold, fontWeight = "bold" },
            UI.Label {
                text = string.format("%d 岁 · %s", char.age or 0, char.gender or "男"),
                fontSize = 12, fontColor = COLORS.textSecondary,
            },
        },
    })

    -- ② 五维（每维：名称 + 数值 + 一根短条）
    --   ⚠️ 上限是 **10** 不是 5（2026-09-28 修）：
    --     基础 rollAttr 是 1~5，但特质加成能把属性推到 10
    --     （Traits.applyAttrs 里 math.min(10, ...)）。
    --     第一版只画 5 格 → 军事 6 的角色会"5 格全亮还显示 6"，看着像 bug。
    refs.courtDetailBody:AddChild(UI.Label {
        text = "五维（基础 1~5，特质可加成至 10）", fontSize = 11,
        fontColor = { 160, 155, 140, 220 },
    })
    for _, a in ipairs(CharacterSystem.ATTRS) do
        local v = math.max(0, math.min(10, char[a.id] or 3))
        local cells = {}
        for i = 1, 10 do
            cells[#cells + 1] = UI.Panel {
                width = 9, height = 8, borderRadius = 2,
                -- 已点亮的格子用金色，未点亮用暗色
                backgroundColor = (i <= v) and { 214, 172, 96, 255 } or { 58, 66, 82, 255 },
            }
        end
        refs.courtDetailBody:AddChild(UI.Panel {
            flexDirection = "row", alignItems = "center", gap = 8, width = "100%",
            children = {
                UI.Label { text = a.name, fontSize = 12, fontColor = COLORS.textSecondary, width = 34 },
                UI.Panel { flexDirection = "row", gap = 2, children = cells },
                UI.Label {
                    text = tostring(char[a.id] or 3), fontSize = 12,
                    fontColor = (char[a.id] or 3) >= 4 and COLORS.gold or COLORS.textPrimary,
                },
            },
        })
    end

    -- ③ 特质
    local traitTxt = CharacterSystem.traitText(char)
    refs.courtDetailBody:AddChild(UI.Label {
        text = "特质：" .. (traitTxt ~= "" and traitTxt or "无"),
        fontSize = 12, fontColor = { 168, 190, 220, 235 },
        whiteSpace = "normal",
    })

    -- ④ 忠诚（在野人物没有忠诚概念，就不显示）
    if char.loyalty then
        refs.courtDetailBody:AddChild(UI.Label {
            text = string.format("忠诚：%d / 100", char.loyalty),
            fontSize = 12,
            fontColor = (char.loyalty >= 60) and { 150, 220, 150, 255 }
                        or (char.loyalty >= 30) and { 230, 210, 130, 255 }
                        or { 235, 130, 120, 255 },
        })
    end

    -- ⑤ 操作区（2026-09-28 第4步：培养 + 阴谋）
    local pf = gameState.factions[gameState.playerFactionId]
    if pf then
        local isMine = (char.factionId == pf.id)

        -- 历练中：显示倒计时，不给操作
        if char.training_ then
            refs.courtDetailBody:AddChild(UI.Label {
                text = string.format("历练中（还需 %d 个月）", char.training_),
                fontSize = 12, fontColor = { 230, 200, 120, 255 },
            })
        elseif isMine then
            -- ── 培养（仅自己人）──
            refs.courtDetailBody:AddChild(UI.Divider { color = COLORS.border, thickness = 1 })
            refs.courtDetailBody:AddChild(UI.Label {
                text = "培养（花金/粮，属性 +1）", fontSize = 11,
                fontColor = { 160, 155, 140, 220 },
            })
            --   ⚠️ SmallButton 不支持 disabled → 已满 10 的**不生成按钮**，
            --     改成一个灰字标签（免得点了才报错）
            local attrBtns = {}
            for _, a in ipairs(CharacterSystem.ATTRS) do
                local cur = char[a.id] or 3
                if cur >= 10 then
                    attrBtns[#attrBtns + 1] = UI.Label {
                        text = string.format("%s 已满", a.name),
                        fontSize = 10, height = 28,
                        fontColor = { 130, 125, 115, 220 },
                    }
                else
                    local g, fd = CharacterSystem.trainCost(cur)
                    attrBtns[#attrBtns + 1] = SmallButton(
                        string.format("%s %d→%d（%d金）", a.name, cur, cur + 1, g),
                        function()
                            local ok, msg = CharacterSystem.trainAttr(gameState, pf.id, char.id, a.id)
                            if ok then
                                GameUI.refreshCourtPanel(gameState)
                                openCharDetail(gameState, char)     -- 刷新详情（数值变了）
                            else
                                gameState.addMessage("培养失败：" .. tostring(msg), "warning")
                            end
                        end,
                        { fontSize = 10, height = 28, flexGrow = 1 }
                    )
                end
            end
            refs.courtDetailBody:AddChild(UI.Panel {
                flexDirection = "row", flexWrap = "wrap", gap = 4, width = "100%",
                children = attrBtns,
            })

            -- 历练按钮（国君除外）
            if char.post ~= "君主" then
                local tg, tf, tm = CharacterSystem.trainingCost()
                refs.courtDetailBody:AddChild(SmallButton(
                    string.format("历练（%d 月，%d 金 %d 粮）", tm, tg, tf),
                    function()
                        local ok, msg = CharacterSystem.startTraining(gameState, pf.id, char.id)
                        if ok then
                            GameUI.refreshCourtPanel(gameState)
                            refs.courtDetailPanel:Hide()     -- 人走了，关掉详情
                            gameState.addMessage(tostring(msg), "info")
                        else
                            gameState.addMessage("历练失败：" .. tostring(msg), "warning")
                        end
                    end,
                    { fontSize = 11, height = 30, width = "100%" }
                ))
            end

            -- ── 阴谋（对内：安抚 / 威慑）──
            refs.courtDetailBody:AddChild(UI.Divider { color = COLORS.border, thickness = 1 })
            refs.courtDetailBody:AddChild(UI.Label {
                text = string.format("阴谋（花 %d 名声）", CharacterSystem.SCHEME_COST),
                fontSize = 11, fontColor = { 160, 155, 140, 220 },
            })
            -- 主使者：本国谋略最高的人（没有别人就用自己的君主）
            local actor = nil
            local best = -1
            for _, c2 in ipairs(pf.characters or {}) do
                if c2.alive ~= false and c2.id ~= char.id and (c2.intrigue or 0) > best then
                    best = c2.intrigue or 0
                    actor = c2
                end
            end
            local chanceTxt = actor and
                string.format("成功率 %d%%", math.floor(CharacterSystem.schemeChance(actor, char) * 100 + 0.5))
                or "无可派之人"
            refs.courtDetailBody:AddChild(UI.Label {
                text = chanceTxt, fontSize = 10, fontColor = { 190, 180, 165, 200 },
            })
            refs.courtDetailBody:AddChild(UI.Panel {
                flexDirection = "row", gap = 6, width = "100%",
                children = {
                    SmallButton("安抚", function()
                        if not actor then
                            gameState.addMessage("没有可执行阴谋的人", "warning"); return
                        end
                        local ok, msg = CharacterSystem.schemeLoyalty(gameState, pf.id, actor.id, char.id, "soothe")
                        gameState.addMessage(tostring(msg), ok and "info" or "warning")
                        GameUI.refreshCourtPanel(gameState)
                        openCharDetail(gameState, char)
                    end, { fontSize = 11, height = 30, flexGrow = 1 }),
                    SmallButton("威慑", function()
                        if not actor then
                            gameState.addMessage("没有可执行阴谋的人", "warning"); return
                        end
                        local ok, msg = CharacterSystem.schemeLoyalty(gameState, pf.id, actor.id, char.id, "intimidate")
                        gameState.addMessage(tostring(msg), ok and "info" or "warning")
                        GameUI.refreshCourtPanel(gameState)
                        openCharDetail(gameState, char)
                    end, { fontSize = 11, height = 30, flexGrow = 1,
                           bg = { 96, 56, 44, 230 }, hoverBg = { 124, 72, 56, 245 } }),
                },
            })
        else
            -- ── 对他国人物：离间 ──
            refs.courtDetailBody:AddChild(UI.Divider { color = COLORS.border, thickness = 1 })
            refs.courtDetailBody:AddChild(UI.Label {
                text = "此人属于他国 —— 可派细作离间", fontSize = 11,
                fontColor = { 190, 180, 165, 220 },
            })
            local actor = nil
            local best = -1
            for _, c2 in ipairs(pf.characters or {}) do
                if c2.alive ~= false and (c2.intrigue or 0) > best then
                    best = c2.intrigue or 0
                    actor = c2
                end
            end
            refs.courtDetailBody:AddChild(SmallButton(
                string.format("离间（%d 名声）", CharacterSystem.SCHEME_COST),
                function()
                    if not actor then
                        gameState.addMessage("没有可执行阴谋的人", "warning"); return
                    end
                    local ok, msg = CharacterSystem.schemeAlienate(gameState, pf.id, actor.id, char.id)
                    gameState.addMessage(tostring(msg), ok and "info" or "warning")
                    openCharDetail(gameState, char)
                end,
                { fontSize = 11, height = 30, width = "100%",
                  bg = { 96, 56, 44, 230 }, hoverBg = { 124, 72, 56, 245 } }
            ))
        end
    end

    refs.courtDetailPanel:Show()
end

--- 五维中文名（从 CharacterSystem.ATTRS 查，改口径只改那一处）
---@param attrId string
---@return string
local function attrNameOf(attrId)
    local CharacterSystem = require("systems.CharacterSystem")
    for _, a in ipairs(CharacterSystem.ATTRS) do
        if a.id == attrId then return a.name end
    end
    return attrId
end

--- 打开「任命」候选弹层
---@param gameState table
---@param postId string
local function openCourtPick(gameState, postId)
    local CharacterSystem = require("systems.CharacterSystem")
    local pf = gameState.factions[gameState.playerFactionId]
    if not pf then return end

    local postDef = nil
    for _, p in ipairs(CharacterSystem.POSTS) do
        if p.id == postId then postDef = p end
    end
    if not postDef then return end

    refs.courtPickTitle.text = "任命 · " .. postDef.name .. "（看" .. attrNameOf(postDef.attr) .. "）"
    refs.courtPickRows:ClearChildren()

    local cands = CharacterSystem.candidatesFor(gameState, pf.id)
    if #cands == 0 then
        refs.courtPickRows:AddChild(UI.Label {
            text = "暂无可用人选（等人才来投）", fontSize = 13, fontColor = COLORS.textSecondary,
        })
    end
    for i = 1, math.min(#cands, 8) do
        local c = cands[i]
        local val = c[postDef.attr] or 3
        refs.courtPickRows:AddChild(UI.Button {
            id = "courtCand_" .. tostring(c.id),
            text = string.format("%s（%d岁）  %s %d", c.name, c.age, attrNameOf(postDef.attr), val),
            fontSize = 13,
            textColor = COLORS.textPrimary,
            backgroundColor = { 30, 38, 52, 235 },
            hoverBackgroundColor = { 48, 62, 84, 245 },
            borderWidth = 1,
            borderColor = COLORS.border,
            borderRadius = 5,
            height = 32,
            width = "100%",
            onClick = function()
                CharacterSystem.appoint(gameState, pf.id, postId, c.id)
                refs.courtPickPanel:Hide()
                GameUI.refreshCourtPanel(gameState)
            end,
        })
    end
    refs.courtPickPanel:Show()
end

--- 打开「任命将军」候选弹层（2026-09-23）
---   一套角色系统：候选 = 本国全部在世人物（君主/官员/在野都能当将军）
---   显示每人的军事属性 + 统兵上限（军事 × 500），点谁谁上任；也可「卸任」
---@param provinceId number 给哪个省的驻军指派
local function showCommanderPick(provinceId)
    local gameState = refs.gameState
    if not gameState or not gameState.playerFactionId then return end
    local pf = gameState.factions[gameState.playerFactionId]
    if not pf then return end
    local MIL = require("systems.MilitarySystem")
    local CharacterSystem = require("systems.CharacterSystem")
    local prov = gameState.provinces and gameState.provinces[provinceId]
    if not prov then return end

    refs.courtPickTitle.text = "任命统帅 · " .. tostring(prov.name or "?")
    refs.courtPickRows:ClearChildren()

    local capPer = require("config.GameConfig").Military.COMMANDER_TROOPS_PER_MILITARY or 500
    local cur = MIL.getProvinceCommander(gameState, pf.id, provinceId)

    -- 现任统帅总览（2026-09-28 用户："将军应该也放在军队这里"）
    --   在任将弹层顶部列一行"你现有的统帅"，换人时能看到全局，不用跑去朝廷
    do
        local rows = {}
        for pid2, cid in pairs(pf.provinceCommanders or {}) do
            local c2 = CharacterSystem.getById(gameState, cid)
            local p2 = gameState.provinces[pid2]
            if c2 and c2.alive ~= false and p2 then
                rows[#rows + 1] = string.format("%s（%s）", tostring(c2.name),
                    tostring(p2.name or pid2))
            end
        end
        if #rows > 0 then
            refs.courtPickRows:AddChild(UI.Label {
                text = "现任统帅：" .. table.concat(rows, "、"),
                fontSize = 10, fontColor = { 170, 185, 205, 230 },
                whiteSpace = "normal",
            })
        end
    end

    -- 卸任按钮（当前有将军时才显示）
    if cur then
        refs.courtPickRows:AddChild(UI.Button {
            id = "cmdPick_dismiss",
            text = string.format("卸任：%s", tostring(cur.name)),
            fontSize = 13, textColor = { 235, 180, 180, 255 },
            backgroundColor = { 60, 34, 34, 235 },
            hoverBackgroundColor = { 88, 44, 44, 245 },
            borderWidth = 1, borderColor = COLORS.border, borderRadius = 5,
            height = 32, width = "100%",
            onClick = function()
                MIL.setProvinceCommander(gameState, pf.id, provinceId, nil)
                refs.courtPickPanel:Hide()
                GameUI.refreshUnitPanel(gameState)
            end,
        })
    end

    -- 候选人：本国全部在世人物，按军事属性降序（能带兵的在前面）
    local list = CharacterSystem.listOf(gameState, pf.id) or {}
    local cands = {}
    for _, c in ipairs(list) do
        if c.alive then cands[#cands + 1] = c end
    end
    table.sort(cands, function(a, b)
        return (a.military or 0) > (b.military or 0)
    end)

    if #cands == 0 then
        refs.courtPickRows:AddChild(UI.Label {
            text = "暂无可用人选（等人才来投）", fontSize = 13, fontColor = COLORS.textSecondary,
        })
    end
    for i = 1, math.min(#cands, 10) do
        local c = cands[i]
        local mil = c.military or 3
        local isCur = cur and cur.id == c.id
        refs.courtPickRows:AddChild(UI.Button {
            id = "cmdCand_" .. tostring(c.id),
            text = string.format("%s%s（%d岁）  军事 %d · 统兵 %d",
                tostring(c.name), isCur and "（现任）" or "", c.age or 0, mil, mil * capPer),
            fontSize = 13,
            textColor = isCur and COLORS.gold or COLORS.textPrimary,
            backgroundColor = { 30, 38, 52, 235 },
            hoverBackgroundColor = { 48, 62, 84, 245 },
            borderWidth = 1,
            borderColor = COLORS.border,
            borderRadius = 5,
            height = 32,
            width = "100%",
            onClick = function()
                local ok, msg = MIL.setProvinceCommander(gameState, pf.id, provinceId, c.id)
                if refs.unitHintLabel and msg then refs.unitHintLabel:SetText(msg) end
                refs.courtPickPanel:Hide()
                GameUI.refreshUnitPanel(gameState)
            end,
        })
    end
    refs.courtPickPanel:Show()
end

--- 刷新朝廷面板（左官员 / 右后宫）—— 只在面板可见时做
---@param gameState table
local function refreshCourtPanel(gameState)
    if not refs.courtPanel or not refs.courtPanel:IsVisible() then return end
    local pf = gameState.factions[gameState.playerFactionId]
    if not pf then return end
    local CharacterSystem = require("systems.CharacterSystem")
    local fid = pf.id

    -- 左：官员（三公 / 六部 / 学官）
    refs.courtOfficeRows:ClearChildren()
    for _, post in ipairs(CharacterSystem.POSTS) do
        local holder = CharacterSystem.getHolder(gameState, fid, post.id)
        ---@type any[]
        local cells = {
            UI.Label { text = post.name, fontSize = 13, fontColor = COLORS.gold, width = 86 },
        }
        if holder then
            -- 名字 + 特质**上下两行**（2026-09-17）：面板窄，横着排会把名字挤换行
            --   2026-09-28：这块改成可点按钮 → 打开人物详情（罢免按钮仍在右边）
            cells[#cells + 1] = UI.Button {
                id = "courtOffice_" .. tostring(holder.id),
                flexDirection = "column",
                flexGrow = 1,
                flexBasis = 0,
                height = 38,
                paddingHorizontal = 4,
                backgroundColor = { 0, 0, 0, 0 },
                hoverBackgroundColor = { 50, 66, 90, 200 },
                borderRadius = 4,
                alignItems = "flex-start",
                onClick = function() openCharDetail(gameState, holder) end,
                children = {
                    UI.Label {
                        text = string.format("%s（%s %d）", holder.name, attrNameOf(post.attr), holder[post.attr] or 3),
                        fontSize = 13, fontColor = COLORS.textPrimary,
                    },
                    -- 特质：在位官员的特质影响国家 → 摆在行里能看见
                    UI.Label {
                        text = CharacterSystem.traitText(holder),
                        fontSize = 10, fontColor = { 168, 190, 220, 235 },
                    },
                },
            }
            cells[#cells + 1] = SmallButton("罢免", function()
                CharacterSystem.dismiss(gameState, fid, post.id)
                GameUI.refreshCourtPanel(gameState)
            end, { width = 48, height = 26, fontSize = 12, bg = { 62, 34, 34, 225 }, hoverBg = { 92, 46, 46, 245 } })
        else
            cells[#cells + 1] = UI.Label {
                text = "空缺", fontSize = 13, fontColor = { 150, 140, 120, 255 }, flexGrow = 1,
            }
            cells[#cells + 1] = SmallButton("任命", function()
                GameUI.openCourtPick(gameState, post.id)
            end, { width = 48, height = 26, fontSize = 12 })
        end
        refs.courtOfficeRows:AddChild(UI.Panel {
            flexDirection = "row",
            alignItems = "center",
            gap = 8,
            width = "100%",
            padding = 5,
            borderRadius = 4,
            backgroundColor = { 26, 33, 46, 225 },
            children = cells,
        })
    end

    -- ── 君主页（2026-09-28）：主角 = 国君 ──────────────────────────
    --   展示五维 / 特质 / 年龄，并说明"国君属性影响全国"
    --   （原来这些信息只散在"自身"面板里，角色系统这边看不到君主）
    refs.courtRulerRows:ClearChildren()
    do
        local ruler = pf.leaderId and CharacterSystem.getById(gameState, pf.leaderId) or nil
        if ruler then
            -- 五维一行（横排，窄屏会自动换行）
            local attrCells = {}
            for _, a in ipairs(CharacterSystem.ATTRS) do
                attrCells[#attrCells + 1] = UI.Panel {
                    flexDirection = "column", alignItems = "center", gap = 1,
                    width = 62,
                    children = {
                        UI.Label { text = a.name, fontSize = 10, fontColor = COLORS.textSecondary },
                        UI.Label {
                            text = tostring(ruler[a.id] or 3),
                            fontSize = 15, fontWeight = "bold",
                            fontColor = (ruler[a.id] or 3) >= 4 and COLORS.gold or COLORS.textPrimary,
                        },
                    },
                }
            end
            refs.courtRulerRows:AddChild(UI.Panel {
                width = "100%", padding = 8, borderRadius = 5, gap = 8,
                backgroundColor = { 32, 40, 56, 230 },
                children = {
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 8, width = "100%",
                        children = {
                            UI.Label {
                                text = string.format("国君 · %s", ruler.name or "?"),
                                fontSize = 15, fontWeight = "bold", fontColor = COLORS.gold,
                            },
                            UI.Label {
                                text = string.format("%d 岁", ruler.age or 0),
                                fontSize = 11, fontColor = COLORS.textSecondary,
                            },
                        },
                    },
                    UI.Label {
                        text = "特质：" .. (CharacterSystem.traitText(ruler) ~= "" and
                            CharacterSystem.traitText(ruler) or "无"),
                        fontSize = 11, fontColor = { 168, 190, 220, 235 },
                        whiteSpace = "normal",
                    },
                    UI.Panel {
                        flexDirection = "row", gap = 4, width = "100%",
                        flexWrap = "wrap",
                        children = attrCells,
                    },
                    UI.Label {
                        text = "国君五维影响全国：管理→金钱、外交→邦交、军事→征兵与战力",
                        fontSize = 10, fontColor = { 160, 155, 140, 220 },
                        whiteSpace = "normal",
                    },
                },
            })
        else
            refs.courtRulerRows:AddChild(UI.Label {
                text = "（国君数据未就绪）", fontSize = 12, fontColor = COLORS.textSecondary,
            })
        end
    end

    -- ── 将军页（2026-09-28）：谁在带兵、能带多少 ──────────────────
    --   将军 = 派驻某省的统帅（faction.provinceCommanders[provId] = charId）
    --   统兵上限 = 军事属性 × 500；有将军的驻军才会月度自动补员
    refs.courtGeneralRows:ClearChildren()
    do
        local generals = {}
        for pid, cid in pairs(pf.provinceCommanders or {}) do
            local c = CharacterSystem.getById(gameState, cid)
            local prov = gameState.provinces[pid]
            if c and c.alive ~= false and prov then
                generals[#generals + 1] = { char = c, prov = prov, pid = pid }
            end
        end
        table.sort(generals, function(a, b)
            return (a.char.military or 0) > (b.char.military or 0)
        end)
        if #generals == 0 then
            refs.courtGeneralRows:AddChild(UI.Label {
                text = "尚无统帅。点地图上的驻军旗 → 「任将」指派。",
                fontSize = 12, fontColor = COLORS.textSecondary,
                whiteSpace = "normal",
            })
        else
            local MIL = require("systems.MilitarySystem")
            for _, g in ipairs(generals) do
                local cap = MIL.commanderCapacity(gameState, pf, g.pid) or 0
                local garrison = g.prov.garrison or 0
                -- 2026-09-28：整行可点 → 打开该统帅的人物详情
                refs.courtGeneralRows:AddChild(UI.Button {
                    id = "courtGeneral_" .. tostring(g.char.id),
                    flexDirection = "row", alignItems = "center", gap = 8, width = "100%",
                    height = 40, paddingHorizontal = 8, borderRadius = 4,
                    backgroundColor = { 26, 33, 46, 225 },
                    hoverBackgroundColor = { 44, 58, 78, 245 },
                    borderWidth = 1, borderColor = { 40, 50, 66, 200 },
                    onClick = function() openCharDetail(gameState, g.char) end,
                    children = {
                        UI.Panel {
                            flexDirection = "column", flexGrow = 1, flexBasis = 0, gap = 1,
                            children = {
                                UI.Label {
                                    text = string.format("%s（军事 %d）", g.char.name or "?",
                                        g.char.military or 3),
                                    fontSize = 13, fontColor = COLORS.textPrimary,
                                },
                                UI.Label {
                                    text = string.format("驻 %s · 统兵上限 %d",
                                        tostring(g.prov.name or g.pid), cap),
                                    fontSize = 10, fontColor = { 168, 190, 220, 235 },
                                },
                            },
                        },
                        -- 兵力/上限，超编标红提示
                        UI.Label {
                            text = string.format("%d / %d", garrison, cap),
                            fontSize = 12,
                            fontColor = (garrison > cap) and { 235, 140, 120, 255 } or COLORS.textSecondary,
                        },
                    },
                })
            end
        end
    end

    -- ── 人才页（2026-09-28）：在野人才 + 花钱招募 ──────────────────
    --   用户："十字军之王他们那个人才获取有很多途径"
    --   这里列出本国在野人物（含游方士人），可花钱招募/直接任命
    refs.courtTalentRows:ClearChildren()
    do
        local talents = {}
        for _, c in ipairs(pf.characters or {}) do
            if c.alive ~= false and not c.post and not c.rank then
                talents[#talents + 1] = c
            end
        end
        -- 强的排前面（按五维总和）
        local function sumOf(c)
            local n = 0
            for _, a in ipairs(CharacterSystem.ATTRS) do n = n + (c[a.id] or 3) end
            return n
        end
        table.sort(talents, function(a, b) return sumOf(a) > sumOf(b) end)

        if #talents == 0 then
            refs.courtTalentRows:AddChild(UI.Label {
                text = "暂无在野人才。每年可能有游方士人前来求仕。",
                fontSize = 12, fontColor = COLORS.textSecondary, whiteSpace = "normal",
            })
        else
            for _, c in ipairs(talents) do
                local price = CharacterSystem.recruitPrice(c)
                -- 最强的那一维（显示出来，方便判断值不值）
                local bestName, bestV = "学识", 0
                for _, a in ipairs(CharacterSystem.ATTRS) do
                    if (c[a.id] or 0) > bestV then bestName, bestV = a.name, c[a.id] end
                end
                refs.courtTalentRows:AddChild(UI.Panel {
                    flexDirection = "row", alignItems = "center", gap = 6, width = "100%",
                    padding = 5, borderRadius = 4,
                    backgroundColor = { 26, 33, 46, 225 },
                    children = {
                        -- 名字块可点 → 看详情
                        UI.Button {
                            id = "courtTalent_" .. tostring(c.id),
                            flexDirection = "column", flexGrow = 1, flexBasis = 0,
                            height = 36, paddingHorizontal = 4,
                            backgroundColor = { 0, 0, 0, 0 },
                            hoverBackgroundColor = { 50, 66, 90, 200 },
                            borderRadius = 4, alignItems = "flex-start",
                            onClick = function() openCharDetail(gameState, c) end,
                            children = {
                                UI.Label {
                                    text = string.format("%s（%d岁）", c.name or "?", c.age or 0),
                                    fontSize = 13, fontColor = COLORS.textPrimary,
                                },
                                UI.Label {
                                    text = string.format("%s %d · %s", bestName, bestV,
                                        tostring(c.titleFrom or "在野")),
                                    fontSize = 10, fontColor = { 168, 190, 220, 235 },
                                },
                            },
                        },
                        -- 招募按钮（显示价钱；钱不够就提示）
                        SmallButton(string.format("招募 %d金", price), function()
                            local ok, msg = CharacterSystem.recruitGuest(gameState, pf.id, c.id)
                            if ok then
                                GameUI.refreshCourtPanel(gameState)
                                gameState.addMessage(tostring(msg), "info")
                            else
                                gameState.addMessage("招募失败：" .. tostring(msg), "warning")
                            end
                        end, { fontSize = 10, height = 30, width = 76 }),
                    },
                })
            end
        end
    end

    -- 右：后宫（2026-09-28：整行改成可点按钮 → 打开人物详情）
    refs.courtConsortRows:ClearChildren()
    for _, c in ipairs(CharacterSystem.consortsOf(gameState, fid)) do
        refs.courtConsortRows:AddChild(UI.Button {
            id = "courtConsort_" .. tostring(c.id),
            width = "100%",
            height = 34,
            paddingHorizontal = 8,
            backgroundColor = { 26, 33, 46, 225 },
            hoverBackgroundColor = { 44, 58, 78, 245 },
            borderRadius = 4,
            borderWidth = 1, borderColor = { 40, 50, 66, 200 },
            onClick = function() openCharDetail(gameState, c) end,
            children = {
                UI.Label {
                    text = string.format("%s %s", tostring(c.rank or "姬"), c.name),
                    fontSize = 12, fontColor = COLORS.textPrimary,
                },
                UI.Label {
                    text = string.format("%d 岁", c.age),
                    fontSize = 11, fontColor = COLORS.textSecondary,
                },
            },
        })
    end
end

--- 把本模块的方法挂回 GameUI 主表
---@param gameUI table GameUI 主表
function M.install(gameUI)
    gameUI.openCourtPick = function(gs, postId)
        openCourtPick(gs, postId)
        if refs and refs.courtPickPanel and gameUI.fitTouchTargets then gameUI.fitTouchTargets(refs.courtPickPanel) end
    end
    gameUI.showCommanderPick = function(provinceId)
        showCommanderPick(provinceId)
        if refs and refs.courtPickPanel and gameUI.fitTouchTargets then gameUI.fitTouchTargets(refs.courtPickPanel) end
    end
    gameUI.refreshCourtPanel = function(gs)
        refreshCourtPanel(gs)
        if refs and refs.courtPanel and gameUI.fitTouchTargets then gameUI.fitTouchTargets(refs.courtPanel) end
    end
end

--- 属性名（"军事"/"政务"…）—— GameUI.update 里还在用（政治/军事行）
---@param attrId string
---@return string
function M.attrNameOf(attrId)
    return attrNameOf(attrId)
end

--- 创建自身面板 + 朝廷面板
---@param ctx table 共享上下文
---@return Widget selfPanel, Widget courtPanel
function M.create(ctx)
    UI          = ctx.UI
    GameUI      = ctx.GameUI
    refs        = ctx.refs
    COLORS      = ctx.COLORS
    SmallButton = ctx.SmallButton
    TAB_TEXT_ACTIVE = ctx.TAB_TEXT_ACTIVE
    TAB_TEXT_IDLE   = ctx.TAB_TEXT_IDLE
    return createSelfPanel(ctx.callbacks), createCourtPanel(ctx.callbacks)
end

return M

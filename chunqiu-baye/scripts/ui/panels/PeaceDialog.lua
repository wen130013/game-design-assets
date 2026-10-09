-- ============================================================================
-- PeaceDialog.lua — 和平条约窗口 + 灭国确认（2026-09-26 从 GameUI.lua 拆出）
--
-- 这块原本 977 行，与 GameUI 其余部分**零耦合**（块内所有 GameUI.xxx 方法
-- 都在块内定义，不引用任何外部 GameUI 方法），所以整块搬走最干净。
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：导出 create(ctx) / install(GameUI)，
-- ctx 注入 UI/GameUI/refs/COLORS/SmallButton，**不 require GameUI**（避免循环依赖）。
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
---@type any
local WarSystem

local PEACE_HEADER_BG    = { 64, 22, 26, 255 }     -- 标题栏酒红
local PEACE_PANEL_BG     = { 12, 16, 26, 242 }     -- 面板背景
local PEACE_GOLD_BORDER  = { 150, 120, 70, 220 }   -- 金棕边框
local PEACE_SECTION_BG   = { 26, 38, 56, 230 }     -- 分区标题底
local PEACE_SECTION_TEXT = { 200, 215, 240, 255 }  -- 分区标题字
local PEACE_ROW_A        = { 20, 26, 38, 230 }     -- 行交替底色 A
local PEACE_ROW_B        = { 26, 33, 46, 230 }     -- 行交替底色 B
local PEACE_SEL_BG       = { 70, 90, 45, 230 }     -- 选中行底
local PEACE_SEL_BORDER   = { 120, 200, 110, 255 }  -- 选中边框/勾
local PEACE_PLAYER_BLUE  = { 40, 80, 180, 255 }    -- 玩家侧色块
local PEACE_ENEMY_GRAY   = { 120, 120, 125, 255 }  -- 敌侧色块
local PEACE_OK_GREEN     = { 90, 180, 95, 255 }    -- 预算充足
local PEACE_WARN_RED     = { 220, 70, 55, 255 }    -- 预算不足/警告
local PEACE_TAG_OCCUPIED = { 90, 210, 110, 255 }   -- 已占小标签

--- 计算当前条约成本（战争分数预算）
---@return number
local function peaceDialogCost()
    local gs = refs.gameState
    local cfg = refs.peaceCfg
    if not gs or not cfg then return 0 end
    local cost = 0
    for pid, _ in pairs(refs.peaceSelection or {}) do
        cost = cost + WarSystem.getProvinceCost(gs, pid, cfg.proposerId)
    end
    cost = cost + math.ceil((refs.peaceGold or 0) / 100) + math.ceil((refs.peaceFood or 0) / 100)
    if refs.peaceVassal then cost = cost + 30 end
    if refs.peaceAnnex then cost = cost + 50 end
    return cost
end

--- 刷新和平条约面板（预算行 / 步进器 / 卡片 / 省份行 / 缔结栏，AoH3 式左侧面板）
---@param gameState table
---@param passive boolean|nil 帧更新节流；玩家操作立即刷新
local function refreshPeaceDialog(gameState, passive)
    if not refs.peaceDialog or not refs.peaceDialog:IsVisible() then return end
    local cfg = refs.peaceCfg
    local gs = gameState or refs.gameState
    if not gs or not cfg then return end
    local now = os.clock()
    if passive and refs.peaceRefreshAt and now - refs.peaceRefreshAt < 0.25 then return end
    refs.peaceRefreshAt = now
    refs.gameState = gs
    local war = WarSystem.findWar(gs, cfg.proposerId, cfg.targetId)
    refs.peaceScore = war and WarSystem.getScore(gs, war, cfg.proposerId) or 0
    local cost = GameUI.peaceDialogCost()
    local score = math.max(0, refs.peaceScore)
    local annex = refs.peaceAnnex == true
    local over = not annex and cost > score + 1e-8

    -- 选择签名既用于控件缓存，也用于高亮回调；分数变化不能全刷地图高亮。
    local ids = {}
    for pid in pairs(refs.peaceSelection or {}) do ids[#ids + 1] = pid end
    table.sort(ids)
    local selectionSig = table.concat(ids, ",")
    local selCount = #ids
    local pickCount = 0
    for _ in pairs(refs.peacePickableIds or {}) do pickCount = pickCount + 1 end
    local rowsChanged = false
    if cfg.mode == "propose" then
        for pid, row in pairs(refs.peaceProvRows or {}) do
            if row.refresh(gs, cfg.proposerId, war, refs.peaceSelection[pid] == true) then
                rowsChanged = true
            end
        end
    end
    local signature = table.concat({ cfg.mode or "", tostring(refs.peaceScore), tostring(cost),
        selectionSig, tostring(pickCount), tostring(refs.peaceGold), tostring(refs.peaceFood),
        tostring(refs.peaceVassal), tostring(annex),
        tostring(cfg.terms and cfg.terms.allOccupied == true) }, "|")
    if signature == refs.peaceRefreshSignature and not rowsChanged then return end
    refs.peaceRefreshSignature = signature

    -- 区域 B：战争分数（propose/respond 通用，金色大字 + 🏆）
    if refs.peaceScoreValue then
        refs.peaceScoreValue.text = string.format("%.1f", refs.peaceScore or 0)
    end

    -- 预算摘要行（propose 独有）：已耗 / 剩余 / 已选
    if refs.budgetUsedVal then
        if over then
            refs.budgetUsedVal.text = string.format("%.2f", cost)
            refs.budgetUsedVal.props.fontColor = PEACE_WARN_RED
            refs.budgetLeftVal.text = string.format("不足 %.2f!", cost - score)
            refs.budgetLeftVal.props.fontColor = PEACE_WARN_RED
        else
            refs.budgetUsedVal.text = string.format("%.2f", cost)
            refs.budgetUsedVal.props.fontColor = PEACE_OK_GREEN
            refs.budgetLeftVal.text = string.format("%.2f", math.max(0, score - cost))
            refs.budgetLeftVal.props.fontColor = PEACE_OK_GREEN
        end
        refs.budgetPickVal.text = tostring(selCount) .. " / " .. tostring(pickCount)
    end

    -- 区域 C1/C2 步进器：步长边界 + 实时成本小字
    if refs.peaceGoldMinus then
        local gold = refs.peaceGold or 0
        local food = refs.peaceFood or 0
        refs.peaceGoldValueLabel.text = gold .. " 金"
        refs.peaceGoldCostLabel.text = "≈" .. math.ceil(gold / 100) .. "分"
        refs.peaceGoldMinus:SetDisabled(gold <= 0)
        refs.peaceGoldMinus:SetOpacity(gold > 0 and 1 or 0.4)
        refs.peaceFoodValueLabel.text = food .. " 粮"
        refs.peaceFoodCostLabel.text = "≈" .. math.ceil(food / 100) .. "分"
        refs.peaceFoodMinus:SetDisabled(food <= 0)
        refs.peaceFoodMinus:SetOpacity(food > 0 and 1 or 0.4)
    end

    -- 区域 C3 附庸卡 toggle 态
    if refs.peaceVassalCard then
        local on = refs.peaceVassal == true
        refs.peaceVassalIcon.text = on and "✓ " or ""
        refs.peaceVassalCard.props.borderColor = on and PEACE_SEL_BORDER or { 80, 90, 115, 200 }
        refs.peaceVassalCard.props.backgroundColor = on and { 45, 70, 45, 235 } or { 20, 26, 38, 220 }
    end

    -- 区域 C3 吞并卡可用性（仅对方全境被占领时可点；annexAll 绕过预算）
    if refs.peaceAnnexCard then
        local allOcc = cfg and cfg.terms and cfg.terms.allOccupied == true
        refs.peaceAnnexCard:SetDisabled(not allOcc)
        refs.peaceAnnexCard:SetOpacity(allOcc and 1 or 0.5)
    end

    -- 区域 D 工具按钮：全选占领 / 重置
    if refs.peaceSelectAllBtn then
        local proposerId = cfg and cfg.proposerId or nil
        local hasOccupied = false
        if proposerId then
            for pid in pairs(refs.peacePickableIds or {}) do
                local prov = gameState and gameState.provinces[pid]
                if prov and prov.occupiedBy == proposerId then
                    hasOccupied = true
                    break
                end
            end
        end
        refs.peaceSelectAllBtn:SetDisabled(not hasOccupied or annex)
        refs.peaceClearBtn:SetDisabled(selCount == 0 or annex)
    end

    -- 区域 F 缔结栏：文案 / 禁用 / 超支红字（annexAll 永不禁用）
    if refs.peaceSubmitBtn then
        local hasTerms = selCount > 0
            or (refs.peaceGold or 0) > 0
            or (refs.peaceFood or 0) > 0
            or refs.peaceVassal == true
        refs.peaceSubmitBtn:SetText(hasTerms and "缔结条约" or "仅缔结停战")
        local blocked = not annex and over
        refs.peaceSubmitBtn:SetDisabled(blocked)
        if refs.peaceOverLabel then
            if blocked then
                refs.peaceOverLabel.text = string.format("战争分数不足(超 %.2f 分)", cost - score)
                refs.peaceOverLabel:Show()
            else
                refs.peaceOverLabel.text = ""
                refs.peaceOverLabel:Hide()
            end
        end
    end

    -- 同步地图金色高亮（选择集合变化时）
    if selectionSig ~= refs.peaceSelectionSignature then
        refs.peaceSelectionSignature = selectionSig
        if refs.callbacks and refs.callbacks.onPeaceSelectionChanged then
            refs.callbacks.onPeaceSelectionChanged(ids)
        end
    end
end

--- 和谈选省模式：propose 会话打开时，点击地图敌省即可加入/移出割让清单
---@return boolean
local function isPeacePickMode()
    return refs.peaceDialog ~= nil and refs.peaceDialog:IsVisible()
        and refs.peaceCfg ~= nil and refs.peaceCfg.mode == "propose"
end

--- 某省是否在可索取集合内（和平条约涂抹起点判断用）
---@param provinceId number
---@return boolean
local function isProvincePickable(provinceId)
    if not GameUI.isPeacePickMode() then return false end
    return refs.peacePickableIds and refs.peacePickableIds[provinceId] == true
end

--- 和谈模式下的省份点选：可选项内 toggle；返回是否被消费
---@param provinceId number
---@param forceSelect boolean|nil  true=涂抹（只加选不取消）
---@return boolean
local function togglePeaceProvincePick(provinceId, forceSelect)
    if not GameUI.isPeacePickMode() then return false end
    if not refs.peacePickableIds or not refs.peacePickableIds[provinceId] then
        return true   -- 模式内点击其他省份：消费掉但不选择
    end
    local sel = refs.peaceSelection or {}
    if forceSelect then
        sel[provinceId] = true
    elseif sel[provinceId] then
        sel[provinceId] = nil
    else
        sel[provinceId] = true
    end
    refs.peaceSelection = sel
    -- 同步左栏清单勾选态
    for _, row in pairs(refs.peaceProvRows or {}) do
        if row.pid == provinceId and row.setSelected then
            row.setSelected(sel[provinceId] == true)
        end
    end
    GameUI.refreshPeaceDialog(refs.gameState)
    return true
end

--- 条约窗口选择状态读取（main.lua 提交时收集）
---@return table selection  pid -> true
local function getPeaceSelection()
    return refs.peaceSelection or {}
end
---@return number
local function getPeaceGold()
    return refs.peaceGold or 0
end
---@return number
local function getPeaceFood()
    return refs.peaceFood or 0
end
---@return boolean
local function getPeaceVassal()
    return refs.peaceVassal == true
end
---@return boolean
local function getPeaceAnnex()
    return refs.peaceAnnex == true
end

--- 创建省索取行（AoH3 纵向行：✓ + 省名 + 已占/未占标签 + 分数成本，点击 toggle）
---@param gs table
---@param item table {id, name, cost, occupied}
---@param index number 行序（1 起，奇偶交替底色）
---@return Widget
local function createProvinceRow(gs, item, index)
    local row = { pid = item.id }
    local baseBg = (index % 2 == 1) and PEACE_ROW_A or PEACE_ROW_B

    -- 左侧勾选位（未选中时留白占位）
    local iconLabel = UI.Label {
        text = "",
        fontSize = 12,
        width = 14,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }
    local nameLabel = UI.Label {
        text = item.name,
        fontSize = 12,
        fontColor = COLORS.textPrimary,
        fontWeight = "bold",
    }
    local tagLabel = UI.Label {
        text = item.occupied and "已占" or "未占",
        fontSize = 10,
        fontColor = item.occupied and PEACE_TAG_OCCUPIED or COLORS.textSecondary,
    }
    local costLabel = UI.Label {
        text = string.format("%.2f分", item.cost),
        fontSize = 11,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }

    local btn = UI.Button {
        height = 32,
        borderRadius = 6,
        backgroundColor = baseBg,
        hoverBackgroundColor = { 255, 255, 255, 18 },
        pressedBackgroundColor = { 255, 255, 255, 30 },
        flexDirection = "row",
        alignItems = "center",
        gap = 6,
        paddingHorizontal = 8,
        onClick = function()
            GameUI.togglePeaceProvincePick(item.id)
        end,
        children = {
            iconLabel,
            nameLabel,
            tagLabel,
            UI.Panel { flexGrow = 1 },
            costLabel,
        },
    }

    -- 地图点选、全选与重置共用同一选中态；值未变时不重复写控件。
    function row.setSelected(selected)
        if row.selected == selected then return end
        row.selected = selected
        btn.props.backgroundColor = selected and PEACE_SEL_BG or baseBg
        iconLabel.text = selected and "✓" or ""
    end

    -- 原行就地同步成本/占领标签，不重建列表，也不重排玩家正在操作的行。
    function row.refresh(state, claimantId, war, selected)
        row.setSelected(selected)
        local province = state.provinces[item.id]
        local signature = table.concat({ tostring(province and province.ownerId),
            tostring(province and province.occupiedBy), tostring(state.version),
            tostring(war and #(war.aProvinceIds or {})),
            tostring(war and #(war.dProvinceIds or {})) }, "|")
        if row.signature == signature and row.war == war then return false end
        row.signature, row.war = signature, war
        costLabel.text = string.format("%.2f分", WarSystem.getProvinceCost(state, item.id, claimantId))
        local occupied = province and province.occupiedBy == claimantId
        tagLabel.text = occupied and "已占" or "未占"
        tagLabel.props.fontColor = occupied and PEACE_TAG_OCCUPIED or COLORS.textSecondary
        return true
    end

    return btn, row
end


--- 和平条约面板的展开/收起（2026-09-25 用户："这个和平条约不要一下子就是展开状态"）
---   默认**收起**：只留顶部一条（"和平条约：林胡 → 燕国" + 展开/关闭按钮），
---   不挡地图；玩家想看条件再点开。
---   ⚠️ 不在模块顶层赋值 refs —— 那时 refs 还没注入（create 才注入）。
---   放到 initRefs()，由 create 调用。
local function initRefs()
    refs.peaceExpanded = false
end

--- 展开/收起和平面板内容（保留标题条常驻）
---@param expanded boolean|nil 不传 = 切换
local function setPeaceExpanded(expanded)
    if expanded == nil then expanded = not refs.peaceExpanded end
    refs.peaceExpanded = expanded and true or false
    -- 内容区（双方横幅 + 条件 + 按钮）随展开显隐
    if refs.peaceBody then
        if refs.peaceExpanded then refs.peaceBody:Show() else refs.peaceBody:Hide() end
    end
    -- 折叠时面板高度收紧成"一条"（否则会在左侧留一大块空白）
    if refs.peaceSheet then
        refs.peaceSheet:SetStyle({
            height = refs.peaceExpanded and "86%" or 52,
        })
    end
    if refs.peaceFoldBtn then
        refs.peaceFoldBtn:SetText(refs.peaceExpanded and "▲" or "▼")
    end
end

local function showPeaceDialog(gameState, cfg)
    if not refs.peaceDialog then return end
    refs.peaceCfg = cfg or {}
    refs.peaceRefreshSignature = nil
    refs.peaceSelectionSignature = nil
    refs.peaceRefreshAt = nil
    -- 和约窗口出现 = 暂停（2026-09-19 用户："点开这个合约则进入暂停状态"）：
    --   让玩家从容读条件；关闭/回应时恢复（hidePeaceDialog）
    do
        local okTS, TS = pcall(require, "core.TimeSystem")
        if okTS and TS and TS.pause then
            TS.pause()
            if gameState then gameState.paused = true end
        end
    end
    local gs = gameState
    local mode = cfg.mode   -- "propose" | "respond"

    local p = cfg.proposerId
    local t = cfg.targetId
    local fromF = gs.factions[p]
    local toF = gs.factions[t]
    local fromName = fromF and (fromF.fullName or fromF.name) or "?"
    local toName   = toF and (toF.fullName or toF.name) or "?"

    -- 区域 A：副标题（2026-09-25 加"谁向谁提"）
    --   旧版只写"对方提出条件"，玩家看不出哪边是自己
    --   （用户："这两个交战的身边的两个国家…是他们两个和我签约的？"）
    --   → 直接写成 "林胡 → 燕国（你）"，一眼看懂。
    local playerFid = gs.playerFactionId
    local function tag(fid, name)
        return (fid == playerFid) and (name .. "（你）") or name
    end
    local arrowLine = string.format("%s → %s", tag(p, fromName), tag(t, toName))
    refs.peaceSubTitle.text = arrowLine

    -- 区域 B：双方横幅（玩家蓝块 / AI 灰块）+ 谁是提出方
    refs.peaceSideAName.text = fromName .. "（提出方）"
    refs.peaceSideBName.text = toName .. "（被要求方）"
    refs.peaceColorBlockA.props.backgroundColor = (p == playerFid) and PEACE_PLAYER_BLUE or PEACE_ENEMY_GRAY
    refs.peaceColorBlockB.props.backgroundColor = (t == playerFid) and PEACE_PLAYER_BLUE or PEACE_ENEMY_GRAY

    -- 战争分数（照旧：以提出方视角读取）
    local score = 0
    local war = WarSystem.findWar(gs, p, t)
    if war then
        score = WarSystem.getScore(gs, war, p)
    end
    refs.peaceScore = score

    -- 重置选择状态
    refs.peaceSelection = {}
    refs.peaceGold = 0
    refs.peaceFood = 0
    refs.peaceVassal = false
    refs.peaceAnnex = false

    if mode == "propose" then
        -- 只显示 propose 交互区（预算行/条件/省份/缔结栏）
        refs.peaceProposeBox:Show()
        refs.peaceRespondBox:Hide()

        -- 构建省索取行（纵向；空列表居中灰字占位）
        refs.peaceProvRows = {}
        refs.peacePickableIds = {}
        refs.peaceProvList:ClearChildren()
        local terms = cfg.terms or {}
        local list = terms.provinceList or {}
        if #list == 0 then
            refs.peaceProvEmpty:Show()
        else
            refs.peaceProvEmpty:Hide()
            for i, item in ipairs(list) do
                refs.peacePickableIds[item.id] = true
                local widget, row = createProvinceRow(gs, item, i)
                refs.peaceProvRows[item.id] = row
                refs.peaceProvList:AddChild(widget)
            end
        end
    else
        -- respond：只显示只读文书（隐藏 propose 全部交互）
        refs.peaceProposeBox:Hide()
        refs.peaceRespondBox:Show()

        -- 重建只读条款文书（只列非空条款）
        refs.peaceRespondList:ClearChildren()
        local terms = cfg.terms or {}
        local provNames = {}
        for _, pid in ipairs(terms.provinces or {}) do
            local prov = gs.provinces[pid]
            if prov and prov.name then
                provNames[#provNames + 1] = prov.name
            end
        end
        local goldAmt = terms.gold or 0
        local foodAmt = terms.food or 0
        if #provNames > 0 then
            refs.peaceRespondList:AddChild(UI.Label {
                text = "· 割让 " .. #provNames .. " 省：" .. table.concat(provNames, "、"),
                fontSize = 12,
                fontColor = COLORS.textPrimary,
                whiteSpace = "normal",
            })
        end
        if goldAmt > 0 then
            refs.peaceRespondList:AddChild(UI.Label {
                text = "· 赔款：" .. goldAmt .. " 金",
                fontSize = 12,
                fontColor = COLORS.textPrimary,
            })
        end
        if foodAmt > 0 then
            refs.peaceRespondList:AddChild(UI.Label {
                text = "· 赔粮：" .. foodAmt .. " 粮",
                fontSize = 12,
                fontColor = COLORS.textPrimary,
            })
        end
        if #provNames == 0 and goldAmt <= 0 and foodAmt <= 0 then
            refs.peaceRespondList:AddChild(UI.Label {
                text = "对方请求仅缔结停战",
                fontSize = 12,
                fontColor = COLORS.textSecondary,
            })
        end
    end

    -- 镜头自动聚焦到被索取方领土（P 社风）+ 开启地图涂抹选省
    if refs.callbacks and refs.callbacks.onPeaceDialogOpened then
        refs.callbacks.onPeaceDialogOpened(cfg, gs)
    end

    -- 默认**收起**（2026-09-25 用户："这个和平条约不要一下子就是展开状态"）：
    --   只留一条标题（"和平条约 / 林胡 → 燕国（你）"），想看条件再点 ▼ 展开。
    --   这样不挡地图，玩家也能先扫一眼是谁来求和。
    GameUI.setPeaceExpanded(false)
    refs.peaceDialog:Show()
    -- refresh 的可见性保护要求先 Show；每次打开必须清掉上次的禁用状态。
    GameUI.refreshPeaceDialog(gs)
end

local function hidePeaceDialog()
    if refs.peaceDialog then refs.peaceDialog:Hide() end
    refs.peaceCfg = nil
    refs.peaceAnnex = false
    -- 关闭地图涂抹选省模式 + 清空高亮
    if refs.callbacks then
        if refs.callbacks.onPeaceDialogClosed then
            refs.callbacks.onPeaceDialogClosed()
        end
        if refs.callbacks.onPeaceSelectionChanged then
            refs.callbacks.onPeaceSelectionChanged({})
        end
    end
    -- 和约窗口关闭 → 恢复时间（2026-09-19：配套 showPeaceDialog 的暂停）。
    --   例外：底部战争面板仍开着时不恢复——它自己持有暂停（openWarBar 语义），
    --   否则会"关掉和谈时间就跑了"。
    if not (refs.warBar and refs.warBar:IsVisible()) then
        local okTS, TS = pcall(require, "core.TimeSystem")
        if okTS and TS and TS.resume then
            TS.resume()
            if refs.gameState then refs.gameState.paused = false end
        end
    end
end

local function isPeaceDialogVisible()
    return refs.peaceDialog and refs.peaceDialog:IsVisible() or false
end

local function createPeaceDialog(callbacks)
    -- 面板宽度：规格 420（逻辑宽 ≥1400 放宽 460）；小屏自动收窄保右侧地图可见
    local physW = graphics:GetWidth()
    local dpr = graphics:GetDPR()
    local logicalW = physW / (dpr and dpr > 0 and dpr or 1)
    local baseW = (logicalW >= 1400) and 460 or 420
    local panelW = math.max(280, math.min(baseW, logicalW - 24))

    -- ============ 区域 A：标题栏（酒红，左上/右上圆角 10） ============
    refs.peaceTitleText = UI.Label {
        text = "和平条约",
        fontSize = 16,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }
    refs.peaceSubTitle = UI.Label {
        text = "提出条件",
        fontSize = 11,
        fontColor = { 255, 255, 255, 178 },
    }
    -- 叉号（2026-09-25 用户："为什么我点不了这个叉号"）
    --   根因：这个按钮原来只有 28×28 且在 **ScrollView 内部** —— ScrollView 会为了
    --   滚动而 CancelPointer 吃掉指针，小按钮几乎点不中。
    --   修法：① 放大到 40×40（手机触控友好）② 标题条移出 ScrollView（见下方结构）。
    local closeBtn = SmallButton("×", function()
        GameUI.hidePeaceDialog()   -- respond 模式 X 沿用现状：仅关闭
    end, { width = 40, height = 40, paddingH = 0, fontSize = 20,
           bg = { 46, 52, 66, 235 }, hoverBg = { 120, 50, 46, 245 } })

    -- 展开/收起按钮（2026-09-25）：默认收起，点它才展开条件详情
    refs.peaceFoldBtn = SmallButton("▼", function()
        GameUI.setPeaceExpanded()
    end, { width = 40, height = 40, paddingH = 0, fontSize = 14,
           bg = { 46, 52, 66, 235 }, hoverBg = { 70, 86, 112, 245 } })

    -- ============ 区域 B：双方横幅（色块+国名）+ 战争分数 ============
    refs.peaceColorBlockA = UI.Panel {
        width = 24, height = 24, borderRadius = 4,
        backgroundColor = PEACE_PLAYER_BLUE,
    }
    refs.peaceSideAName = UI.Label { text = "", fontSize = 13, fontColor = COLORS.textPrimary, fontWeight = "bold" }
    refs.peaceSideBName = UI.Label { text = "", fontSize = 13, fontColor = COLORS.textPrimary, fontWeight = "bold" }
    refs.peaceColorBlockB = UI.Panel {
        width = 24, height = 24, borderRadius = 4,
        backgroundColor = PEACE_ENEMY_GRAY,
    }
    refs.peaceScoreValue = UI.Label {
        text = "0.0",   -- 2026-09-17：去掉 emoji（设备上回退成☒）
        fontSize = 16,
        fontColor = COLORS.gold,
        fontWeight = "bold",
    }

    -- ============ 分区标题条（区域 C/D 共用） ============
    local function SectionTitle(text)
        return UI.Panel {
            height = 26,
            borderRadius = 6,
            paddingHorizontal = 10,
            backgroundColor = PEACE_SECTION_BG,
            justifyContent = "center",
            children = {
                UI.Label { text = text, fontSize = 13, fontColor = PEACE_SECTION_TEXT, fontWeight = "bold" },
            },
        }
    end

    -- ============ 预算摘要行（已耗/剩余/已选 三列等分） ============
    local function BudgetStat(cap, val)
        return UI.Panel {
            flexGrow = 1,
            flexDirection = "row",
            alignItems = "center",
            justifyContent = "center",
            gap = 4,
            children = {
                UI.Label { text = cap, fontSize = 11, fontColor = COLORS.textSecondary },
                val,
            },
        }
    end
    refs.budgetUsedVal = UI.Label { text = "0", fontSize = 13, fontColor = PEACE_OK_GREEN, fontWeight = "bold" }
    refs.budgetLeftVal = UI.Label { text = "0", fontSize = 13, fontColor = PEACE_OK_GREEN, fontWeight = "bold" }
    refs.budgetPickVal = UI.Label { text = "0 / 0", fontSize = 13, fontColor = COLORS.gold, fontWeight = "bold" }
    local budgetRow = UI.Panel {
        flexDirection = "row",
        gap = 4,
        width = "100%",
        children = {
            BudgetStat("已耗", refs.budgetUsedVal),
            BudgetStat("剩余", refs.budgetLeftVal),
            BudgetStat("已选", refs.budgetPickVal),
        },
    }

    -- ============ 步进器行（赔金/赔粮，步长 500，最小 0） ============
    local function Stepper(opts)
        local minus = SmallButton("-", opts.onMinus, { width = 28, height = 28, paddingH = 0, fontSize = 15 })
        local plus  = SmallButton("+", opts.onPlus,  { width = 28, height = 28, paddingH = 0, fontSize = 15 })
        local valueLabel = UI.Label { text = "", fontSize = 13, fontColor = COLORS.gold, fontWeight = "bold" }
        local costLabel = UI.Label { text = "", fontSize = 10, fontColor = COLORS.textSecondary }
        local rowPanel = UI.Panel {
            height = 34,
            borderRadius = 6,
            paddingHorizontal = 8,
            backgroundColor = opts.bg,
            flexDirection = "row",
            alignItems = "center",
            gap = 6,
            width = "100%",
            children = {
                UI.Label { text = opts.title, fontSize = 12, fontColor = COLORS.textPrimary, flexGrow = 1 },
                minus,
                valueLabel,
                plus,
                costLabel,
            },
        }
        return rowPanel, minus, valueLabel, plus, costLabel
    end
    local goldRow, goldMinus, goldValueLabel, goldPlus, goldCostLabel =
        Stepper({
            bg = PEACE_ROW_A,
            title = "💰 战争赔款",
            onMinus = function()
                refs.peaceGold = math.max(0, (refs.peaceGold or 0) - 500)
                GameUI.refreshPeaceDialog(refs.gameState)
            end,
            onPlus = function()
                refs.peaceGold = (refs.peaceGold or 0) + 500
                GameUI.refreshPeaceDialog(refs.gameState)
            end,
        })
    refs.peaceGoldRow, refs.peaceGoldMinus, refs.peaceGoldValueLabel, refs.peaceGoldPlus, refs.peaceGoldCostLabel =
        goldRow, goldMinus, goldValueLabel, goldPlus, goldCostLabel
    local foodRow, foodMinus, foodValueLabel, foodPlus, foodCostLabel =
        Stepper({
            bg = PEACE_ROW_B,
            title = "粮草赔款",
            onMinus = function()
                refs.peaceFood = math.max(0, (refs.peaceFood or 0) - 500)
                GameUI.refreshPeaceDialog(refs.gameState)
            end,
            onPlus = function()
                refs.peaceFood = (refs.peaceFood or 0) + 500
                GameUI.refreshPeaceDialog(refs.gameState)
            end,
        })
    refs.peaceFoodRow, refs.peaceFoodMinus, refs.peaceFoodValueLabel, refs.peaceFoodPlus, refs.peaceFoodCostLabel =
        foodRow, foodMinus, foodValueLabel, foodPlus, foodCostLabel

    -- ============ 条款卡片：附庸 30 分（toggle）/ 吞并全境（确认后走灭国流程） ============
    refs.peaceVassalIcon = UI.Label { text = "", fontSize = 13, fontColor = PEACE_SEL_BORDER, fontWeight = "bold", width = 18 }
    local vassalTitle = UI.Label { text = "要求附庸", fontSize = 13, fontColor = COLORS.textPrimary, fontWeight = "bold" }
    local vassalCost = UI.Label { text = "30分", fontSize = 11, fontColor = COLORS.gold, fontWeight = "bold" }
    refs.peaceVassalCard = UI.Button {
        height = 60,
        flexGrow = 1,
        borderRadius = 6,
        borderWidth = 1,
        borderColor = { 80, 90, 115, 200 },
        backgroundColor = { 20, 26, 38, 220 },
        hoverBackgroundColor = { 255, 255, 255, 18 },
        pressedBackgroundColor = { 255, 255, 255, 30 },
        flexDirection = "row",
        alignItems = "center",
        gap = 4,
        paddingHorizontal = 10,
        onClick = function()
            refs.peaceVassal = not (refs.peaceVassal == true)
            GameUI.refreshPeaceDialog(refs.gameState)
        end,
        children = { refs.peaceVassalIcon, vassalTitle, UI.Panel { flexGrow = 1 }, vassalCost },
    }
    local annexTitle = UI.Panel {
        flexDirection = "row", alignItems = "center", gap = 5,
        children = {
            UI.Panel { width = 14, height = 14, backgroundImage = "image/icon_war_双剑交叉.png", backgroundFit = "contain" },
            UI.Label { text = "吞并全境", fontSize = 13, fontColor = COLORS.textPrimary, fontWeight = "bold" },
        },
    }
    local annexCost = UI.Label { text = "全部", fontSize = 11, fontColor = COLORS.gold, fontWeight = "bold" }
    refs.peaceAnnexCard = UI.Button {
        height = 60,
        flexGrow = 1,
        borderRadius = 6,
        borderWidth = 1,
        borderColor = { 80, 90, 115, 200 },
        backgroundColor = { 20, 26, 38, 220 },
        hoverBackgroundColor = { 255, 255, 255, 18 },
        pressedBackgroundColor = { 255, 255, 255, 30 },
        flexDirection = "row",
        alignItems = "center",
        gap = 4,
        paddingHorizontal = 10,
        onClick = function()
            GameUI.showAnnexConfirm()   -- 走既有灭国确认流程
        end,
        children = { annexTitle, UI.Panel { flexGrow = 1 }, annexCost },
    }
    local cardsRow = UI.Panel {
        flexDirection = "row",
        gap = 6,
        width = "100%",
        children = { refs.peaceVassalCard, refs.peaceAnnexCard },
    }

    -- ============ 区域 D：要求割让省份（标题 + 全选/重置 + 纵向行列表） ============
    refs.peaceSelectAllBtn = SmallButton("全选占领", function()
        local gs = refs.gameState
        local cfg = refs.peaceCfg
        if not gs or not cfg then return end
        local sel = refs.peaceSelection or {}
        for pid in pairs(refs.peacePickableIds or {}) do
            local prov = gs.provinces[pid]
            if prov and prov.occupiedBy == cfg.proposerId then
                sel[pid] = true
            end
        end
        refs.peaceSelection = sel
        GameUI.refreshPeaceDialog(gs)
    end, { height = 24, fontSize = 11, paddingH = 8 })
    refs.peaceClearBtn = SmallButton("重置", function()
        refs.peaceSelection = {}
        GameUI.refreshPeaceDialog(refs.gameState)
    end, { height = 24, fontSize = 11, paddingH = 8 })
    local provSectionHeader = UI.Panel {
        height = 30,
        borderRadius = 6,
        paddingHorizontal = 10,
        backgroundColor = PEACE_SECTION_BG,
        flexDirection = "row",
        alignItems = "center",
        gap = 6,
        width = "100%",
        children = {
            UI.Label { text = "要求割让省份", fontSize = 13, fontColor = PEACE_SECTION_TEXT, fontWeight = "bold", flexGrow = 1 },
            refs.peaceSelectAllBtn,
            refs.peaceClearBtn,
        },
    }
    refs.peaceProvList = UI.Panel { flexDirection = "column", gap = 4, width = "100%", children = {} }
    refs.peaceProvEmpty = UI.Label {
        text = "无可索取的省份",
        fontSize = 12,
        fontColor = COLORS.textSecondary,
        width = "100%",
        textAlign = "center",
        padding = 8,
    }
    refs.peaceProvEmpty:Hide()

    -- ============ 区域 F：缔结栏（钉在滚动末尾；超预算禁用+红字） ============
    refs.peaceOverLabel = UI.Label {
        text = "",
        fontSize = 11,
        fontColor = PEACE_WARN_RED,
        textAlign = "center",
    }
    refs.peaceOverLabel:Hide()
    refs.peaceSubmitBtn = SmallButton("缔结条约", function()
        local cfg = refs.peaceCfg
        if not cfg or cfg.mode ~= "propose" then return end
        if callbacks.onSubmitPeace then callbacks.onSubmitPeace(cfg) end
    end, { height = 44, fontSize = 14, bg = COLORS.btnSuccess, hoverBg = COLORS.btnSuccessHover })

    -- ============ propose 交互区（预算/条件/省份/缔结） ============
    refs.peaceProposeBox = UI.Panel {
        flexDirection = "column",
        gap = 8,
        padding = 12,
        width = "100%",
        children = {
            budgetRow,
            SectionTitle("条 件"),
            goldRow,
            foodRow,
            cardsRow,
            provSectionHeader,
            refs.peaceProvList,
            refs.peaceProvEmpty,
            UI.Panel {
                flexDirection = "column",
                gap = 4,
                width = "100%",
                children = { refs.peaceOverLabel, refs.peaceSubmitBtn },
            },
        },
    }

    -- ============ respond 区：只读文书 + 接受/拒绝 ============
    refs.peaceRespondList = UI.Panel { flexDirection = "column", gap = 6, width = "100%", children = {} }
    refs.peaceAccept = SmallButton("接受", function()
        if callbacks.onAcceptPeace then callbacks.onAcceptPeace() end
    end, { height = 44, fontSize = 14, bg = COLORS.btnSuccess, hoverBg = COLORS.btnSuccessHover, flexGrow = 1 })
    refs.peaceReject = SmallButton("拒绝", function()
        if callbacks.onRejectPeace then callbacks.onRejectPeace() end
    end, { height = 44, fontSize = 14, bg = COLORS.btnDanger, hoverBg = COLORS.btnDangerHover, flexGrow = 1 })
    refs.peaceRespondBox = UI.Panel {
        flexDirection = "column",
        gap = 10,
        padding = 12,
        width = "100%",
        children = {
            UI.Label { text = "── 对方提出 ──", fontSize = 12, fontColor = COLORS.textSecondary, textAlign = "center", width = "100%" },
            refs.peaceRespondList,
            UI.Divider { color = { 150, 120, 70, 160 }, thickness = 1 },
            UI.Label { text = "── 是否接受？──", fontSize = 12, fontColor = COLORS.textSecondary, textAlign = "center", width = "100%" },
            UI.Panel {
                flexDirection = "row",
                gap = 8,
                width = "100%",
                children = { refs.peaceAccept, refs.peaceReject },
            },
        },
    }
    refs.peaceRespondBox:Hide()

    -- ============ 灭国确认层（专门胜利结算流程的确认环节，覆盖全屏） ============
    refs.annexConfirmTitle = UI.Label {
        text = "确认灭亡",
        fontSize = 20,
        fontColor = { 255, 120, 100, 255 },
        fontWeight = "bold",
    }
    refs.annexConfirmBody = UI.Label {
        text = "",
        fontSize = 14,
        fontColor = COLORS.textPrimary,
        whiteSpace = "normal",
        maxLines = 4,
    }
    local annexConfirmYes = SmallButton("确认灭亡", function()
        -- 确认 → 标记吞并全部 → 提交条约（走 submitPeace 的 annexAll 分支，系统自动播报灭亡）
        refs.peaceAnnex = true
        local cfg = refs.peaceCfg
        if cfg and cfg.mode == "propose" and callbacks.onSubmitPeace then
            callbacks.onSubmitPeace(cfg)
        end
    end, { height = 44, fontSize = 14, bg = COLORS.btnDanger, hoverBg = COLORS.btnDangerHover, flexGrow = 1 })
    local annexConfirmNo = SmallButton("取消", function()
        GameUI.hideAnnexConfirm()
    end, { height = 44, fontSize = 14, flexGrow = 1 })
    refs.annexConfirmOverlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 150 },
        alignItems = "center",
        justifyContent = "center",
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 380,
                backgroundColor = { 18, 22, 34, 245 },
                borderRadius = 12,
                borderWidth = 1,
                borderColor = { 200, 100, 90, 220 },
                padding = 20,
                gap = 12,
                children = {
                    refs.annexConfirmTitle,
                    UI.Divider { color = { 200, 100, 90, 140 }, thickness = 1 },
                    refs.annexConfirmBody,
                    UI.Panel {
                        flexDirection = "row",
                        gap = 8,
                        width = "100%",
                        children = { annexConfirmYes, annexConfirmNo },
                    },
                },
            },
        },
    }
    refs.annexConfirmOverlay:Hide()

    -- ============ 和平条约：左侧全高面板（区域 A–F），其余区域透明可点地图 ============
    -- 面板容器（2026-09-25 重构：标题条**移出 ScrollView**）
    --   旧结构：整个面板（含标题条）是一个 ScrollView → ① 标题条上的叉号被滚动逻辑
    --   CancelPointer 吃掉、点不动 ② 无法做"折叠成一条"。
    --   新结构：外层普通 Panel（定高） = 标题条（常驻） + 可折叠的内容区。
    -- 可折叠内容区（2026-09-25）：**先在这里建好**，再在下面 peaceSheet 的表里引用。
    --   ⚠️ 不能在表构造器里写 `refs.peaceBody = UI.ScrollView{...}` —— Lua 表里只能写
    --   `名字 = 值`，写 `refs.x = 值` 是语法错误（会报 "'}' expected"）。
    refs.peaceBody = UI.ScrollView {
        width = "100%",
        flexGrow = 1, flexBasis = 0,
        flexDirection = "column",
        gap = 8,
        showScrollbar = false,
        children = {
            -- 区域 B：双方横幅 + 战争分数
            UI.Panel {
                width = "100%",
                flexDirection = "column",
                gap = 8,
                paddingHorizontal = 12,
                paddingTop = 8,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "center",
                        gap = 8,
                        width = "100%",
                        children = {
                            UI.Panel {
                                flexDirection = "row", alignItems = "center", gap = 5,
                                children = { refs.peaceColorBlockA, refs.peaceSideAName },
                            },
                            UI.Panel { width = 14, height = 14, backgroundImage = "image/icon_war_双剑交叉.png", backgroundFit = "contain" },
                            UI.Panel {
                                flexDirection = "row", alignItems = "center", gap = 5,
                                children = { refs.peaceSideBName, refs.peaceColorBlockB },
                            },
                        },
                    },
                    UI.Panel {
                        flexDirection = "row", alignItems = "center",
                        justifyContent = "center", gap = 6, width = "100%",
                        children = {
                            UI.Label { text = "战争分数：", fontSize = 13, fontColor = COLORS.textSecondary },
                            refs.peaceScoreValue,
                        },
                    },
                },
            },
            refs.peaceProposeBox,
            refs.peaceRespondBox,
        },
    }

    refs.peaceSheet = UI.Panel {
        position = "absolute",
        top = 56, left = 12,
        width = panelW,
        height = 52,                      -- 折叠态：只留标题条；展开时 setPeaceExpanded 改高
        backgroundColor = PEACE_PANEL_BG,
        borderRadius = 10,
        borderWidth = 1,
        borderColor = PEACE_GOLD_BORDER,
        flexDirection = "column",
        pointerEvents = "auto",
        overflow = "hidden",
        children = {
            -- 区域 A：标题栏（**常驻**，不随折叠消失）
            UI.Panel {
                height = 52,
                width = "100%",
                backgroundColor = PEACE_HEADER_BG,
                flexDirection = "row",
                alignItems = "center",
                gap = 8,
                paddingHorizontal = 12,
                flexShrink = 0,
                children = {
                    UI.Panel {
                        flexGrow = 1, flexShrink = 1,
                        flexDirection = "column", gap = 2,
                        children = { refs.peaceTitleText, refs.peaceSubTitle },
                    },
                    refs.peaceFoldBtn,
                    closeBtn,
                },
            },
            -- 区域 B~D：可折叠内容（在函数上方已建好，这里只引用）
            refs.peaceBody,
        },
    }

    -- 外层容器：透明、不吃事件（点面板外可穿透到地图）
    refs.peaceDialog = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 0 },
        pointerEvents = "box-none",
        children = {
            refs.peaceSheet,
            -- 灭国确认层（全屏遮罩，zIndex 高于面板）
            refs.annexConfirmOverlay,
        },
    }
    refs.peaceDialog:Hide()
    return refs.peaceDialog
end

-- ============================================================
-- 3.75.1) 灭国确认层（专门胜利结算流程）
-- ============================================================

--- 打开灭国确认：显示国名 / 省数 / 战争分数，让玩家明确这是决定性胜利
local function showAnnexConfirm()
    local overlay = refs.annexConfirmOverlay
    if not overlay then return end
    local gs = refs.gameState
    local cfg = refs.peaceCfg
    local t = cfg and cfg.targetId
    local f = gs and gs.factions[t]
    local name = f and (f.fullName or f.name) or "该诸侯"
    local provCount = f and #(f.provinces or {}) or 0
    local score = refs.peaceScore or 0
    refs.annexConfirmBody.text = string.format(
        "你正要对 %s 发起灭亡之战——\n将吞并其全部 %d 座城邑（战争分数 %d，可覆盖）。\n\n此役后将再无 %s，史书会记录这一天。",
        name, provCount, math.floor(score), name)
    overlay:Show()
end

--- 关闭灭国确认层
local function hideAnnexConfirm()
    if refs.annexConfirmOverlay then refs.annexConfirmOverlay:Hide() end
end

--- 把本模块的方法挂回 GameUI 主表
---@param gameUI table GameUI 主表
function M.install(gameUI)
    gameUI.peaceDialogCost         = peaceDialogCost
    gameUI.refreshPeaceDialog      = refreshPeaceDialog
    gameUI.isPeacePickMode         = isPeacePickMode
    gameUI.isProvincePickable      = isProvincePickable
    gameUI.togglePeaceProvincePick = togglePeaceProvincePick
    gameUI.getPeaceSelection       = getPeaceSelection
    gameUI.getPeaceGold            = getPeaceGold
    gameUI.getPeaceFood            = getPeaceFood
    gameUI.getPeaceVassal          = getPeaceVassal
    gameUI.getPeaceAnnex           = getPeaceAnnex
    gameUI.setPeaceExpanded        = setPeaceExpanded
    gameUI.showPeaceDialog         = showPeaceDialog
    gameUI.hidePeaceDialog         = hidePeaceDialog
    gameUI.isPeaceDialogVisible    = isPeaceDialogVisible
    gameUI.showAnnexConfirm        = showAnnexConfirm
    gameUI.hideAnnexConfirm        = hideAnnexConfirm
end

--- 创建和平条约面板（含灭国确认层）
---@param ctx table 共享上下文
---@return Widget peaceDialog
function M.create(ctx)
    UI          = ctx.UI
    GameUI      = ctx.GameUI
    refs        = ctx.refs
    COLORS      = ctx.COLORS
    SmallButton = ctx.SmallButton
    WarSystem   = ctx.WarSystem
    initRefs()
    return createPeaceDialog(ctx.callbacks)
end

return M

-- ============================================================================
-- ArmyPanel.lua — 征召军队面板（2026-09-26 从 GameUI.lua 拆出）
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：导出 create(ctx) / install(GameUI)，
-- ctx 注入 UI/GameUI/refs/COLORS/SmallButton，**不 require GameUI**。
--
-- 注意：isPointOverPanel 仍留在 GameUI.lua —— 它是**全局工具**
--   （main.lua 用它判断点击是否落在任意浮层面板上），不只服务本面板。
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

--- 是否处于"地图选省"模式（main.lua 的省份点击回调查它）
local function isArmyPickMode()
    return refs.armyPickMode == true
end

local function hideArmyPanel()
    refs.armyPickMode = false
    refs.armyProvRejectName = nil     -- 关面板清掉"不是你的省"的残留提示
    if refs.armyUnitList then refs.armyUnitList:Hide() end
    if refs.armyPanel then refs.armyPanel:Hide() end
end

--- 按顶栏**实测底边**校准征召面板顶部（2026-09-21 用户："把它往上挪，跟上面那个框紧挨着"）
---   顶栏 = minHeight 54 + flexWrap（窄屏换行会变高）→ 用测量值，别硬编码
---   面板只管自己贴顶：左上角的"待处理"事件条若出现，同高度也**不会挤动面板**——
---   两者各自绝对定位；层级上 armyPanel 在 root children 里排在 eventNoticeBar 之后 = 压在它上面
local function syncArmyPanelTop()
    local panel = refs.armyPanel
    if not panel then return end
    local probe = refs.topBar
    local h = 58
    if probe then
        local lay = probe:GetAbsoluteLayout()
        if lay and lay.y and lay.h and lay.h > 0 then
            h = math.floor(lay.y + lay.h)
        end
    end
    -- 只挪外壳的 paddingTop：内部面板 height="100%" 自动跟着变高，底部仍到屏幕底
    local m = refs.navigationMetrics
    panel:SetStyle({ paddingTop = m and m.top or h, paddingLeft = m and m.left or 0,
        paddingBottom = m and m.bottom or 0, paddingRight = m and m.right or 0 })
    if refs.armyPanelBox then
        local available = m and m.contentW or UI.GetWidth()
        refs.armyPanelBox:SetWidth(math.min(available - 16, math.min(400, math.max(300, math.floor(available * 0.42)))))
    end
end

local function showArmyPanel()
    if refs.armyPanel then
        -- 省份详情与征召侧栏同在左侧；保留已选省 ID 供「选地区」直接使用，
        -- 但先藏住其 UI，避免省份按钮透过半透明面板干扰视线。
        if refs.provincePanel then refs.provincePanel:Hide() end
        GameUI.syncArmyPanelTop()
        refs.armyPanel:Show()
        GameUI.refreshArmyPanel(refs.gameState)
    end
end

local function toggleArmyPanel()
    if refs.armyPanel and refs.armyPanel:IsVisible() then
        GameUI.hideArmyPanel()
    else
        refs.armyPickMode = false
        GameUI.showArmyPanel()
    end
end

--- 地图上点了一个省 → 回填（main.lua 调用）
---   面板**不关**（2026-09-21 起「选地区」期间面板一直开着，见按钮 onClick）
---   只接受自己的省（点了别人的省 = 没选上，继续留在选地区模式，并在地区行写明原因）
---@param provId number
local function setArmyProvince(provId)
    local gs = refs.gameState
    local f = gs and gs.getPlayerFaction and gs.getPlayerFaction() or nil
    local prov = gs and provId and gs.provinces[provId] or nil
    if not (prov and f and prov.ownerId == f.id) then
        -- 记下被拒的省名 → 地区行会把原因显示出来（见 refreshArmyPanel）
        --   以前只 print，界面毫无变化 → 看着像"点了没反应"（2026-09-24 用户截图）
        if prov and prov.ownerId then
            local Provinces = require("data.Provinces")
            local def = Provinces.byId and Provinces.byId[provId]
            refs.armyProvRejectName = (def and def.name) or tostring(provId)
        elseif prov then
            refs.armyProvRejectName = (prov.name or tostring(provId)) .. "（无主之地）"
        else
            refs.armyProvRejectName = nil      -- 点到空白/海洋：不改文字
        end
        refs.armyPickMode = true      -- 继续选
        GameUI.refreshArmyPanel(refs.gameState)
        print("[Army] 该省不属于你（点自己的省）")
        return
    end
    refs.armyProvId = provId
    refs.armyProvRejectName = nil
    -- 选中就把底部绿色提示清掉（2026-09-21 用户："当我选择一个区域之后这个绿色字就消失"）
    if refs.armyHint then refs.armyHint:SetText("") end
    -- ⚠️ **不退出选地区模式**（2026-09-21 用户："我在别地别的区块儿，这个地区就会自动变成
    --   别的地区，而不需要再次点击该按钮"）：模式一直开着，点谁换谁；
    --   退出 = 再点一下「选地区」按钮（或关面板 / 征召成功）
    -- 面板一直开着（2026-09-21 起「选地区」不再关面板）→ 只刷新即可，别重新 Show：
    --   showArmyPanel 会再校准一次顶部 padding，用户拖动过的话位置会白跳一下
    if refs.armyPanel and refs.armyPanel:IsVisible() then
        GameUI.refreshArmyPanel(refs.gameState)
    else
        GameUI.showArmyPanel()      -- 保底：面板被关了也能弹回来
    end
end

--- 输入框里的数量（空/非法 → 100；下限 100）
---@return number
local function armyWanted()
    local raw = refs.armyCountField and refs.armyCountField:GetValue() or ""
    local n = tonumber(raw) or 100
    if n < 100 then n = 100 end
    return math.floor(n)
end

--- 展开/收起征兵弹窗的兵种下拉（外部/SHOT 用；不传 = 切换）
---@param show boolean|nil
local function toggleArmyUnitList(show)
    if not refs.armyUnitList then return end
    local target = show
    if target == nil then
        target = not refs.armyUnitList:IsVisible()
    end
    if target then refs.armyUnitList:Show() else refs.armyUnitList:Hide() end
end

--- 刷新弹窗（地区行 / 成本预览）
---@param gs table|nil
local function refreshArmyPanel(gs)
    if not refs.armyPanel or not gs then return end
    local f = gs.getPlayerFaction and gs.getPlayerFaction() or nil
    if not f then return end

    -- 地区行：必须还是自己的省（打丢了就重置）
    if refs.armyProvLabel then
        local pid = refs.armyProvId
        local prov = pid and gs.provinces[pid] or nil
        if prov and prov.ownerId == f.id then
            local Provinces = require("data.Provinces")
            local def = Provinces.byId and Provinces.byId[pid]
            local name = (def and def.name) or ("省份 " .. tostring(pid))
            -- 选完省之后：这串字直接变成**所选省份的名字**（2026-09-19 用户要求）
            --   2026-09-25 加兵源：显示"还能征多少"——旧版被每月额度卡住时毫无提示，
            --   玩家只看到"征得起却不征"，不知道是被兵源卡了。现在直接写在行上。
            local pool = (gs.manpower and gs.manpower[pid])
            if pool == nil then
                local MILC = require("config.GameConfig").Military or {}
                pool = (prov.population or 0) * (MILC.MANPOOL_RATIO or 0.15)
            end
            refs.armyProvLabel:SetText(string.format("%s　驻军 %d　兵源 %d",
                name, prov.garrison or 0, math.floor(pool)))
            refs.armyProvLabel.props.fontColor = COLORS.textPrimary
            refs.armyProvRejectName = nil
        elseif refs.armyProvRejectName then
            -- 点了**别国的省**：征召只能在自己的省进行（MilitarySystem.recruit 会拒）。
            --   以前这里静默失败 → 玩家看着像"点了没反应"（2026-09-24 用户截图）。
            --   直接把原因写在地区行上，下次选对/关面板就清掉。
            refs.armyProvId = nil
            refs.armyProvLabel:SetText(string.format("⚠ %s 不是你的省 · 只能选自己的省",
                refs.armyProvRejectName))
            refs.armyProvLabel.props.fontColor = { 235, 150, 130, 255 }
        else
            refs.armyProvId = nil
            refs.armyProvLabel:SetText("未选地区 · 点右侧按钮，再点地图上自己的省")
            refs.armyProvLabel.props.fontColor = COLORS.textSecondary
        end
        -- 选地区按钮：**选地区模式开着就发亮**（2026-09-21 用户："点击完这个按钮之后
        --   它应该发亮才对，再点击就会关闭"）；选完省 / 手动关掉 → 恢复常态
        if refs.armyPickBtn then
            local lit = refs.armyPickMode == true
            refs.armyPickBtn.props.backgroundColor = lit and { 104, 82, 32, 245 } or { 46, 58, 78, 235 }
            refs.armyPickBtn.props.hoverBackgroundColor = lit and { 128, 100, 40, 250 } or { 66, 82, 108, 245 }
            refs.armyPickBtn.props.borderColor = lit and { 216, 176, 84, 235 } or { 120, 100, 66, 190 }
        end
    end

    -- 绿色提示行：**没内容就彻底藏起来**（2026-09-24 用户："这个绿色的字不要显示"）——
    --   选地区模式的说明已经写在「征召地区」那一行里；只有征召成功/失败才需要这行飘字。
    if refs.armyHint then
        local txt = refs.armyHint:GetText()
        if txt and txt ~= "" then refs.armyHint:Show() else refs.armyHint:Hide() end
    end

    -- 兵种行（2026-09-19 兵种系统）：按钮名 + 属性行 + 下拉列表（全列出，未解锁灰名）
    local mainUnit = nil
    do
        local Units = require("data.Units")
        mainUnit = Units.mainOf(f)
        if refs.armyUnitBtn then
            -- 只写兵种名：▾/▴ 三角在部分设备上渲染成缺字方框（用户截图红框）
            --   展开态已经由下方列表的出现表达，不需要箭头字符
            refs.armyUnitBtn:SetText(mainUnit.name)
        end
        if refs.armyUnitInfo then
            local vsTxt = ""
            for cat, mul in pairs(mainUnit.vs or {}) do
                vsTxt = vsTxt .. string.format(" · 克%s×%.1f", Units.catName(cat), mul)
            end
            refs.armyUnitInfo:SetText(string.format("伤害 %d  ·  坚韧 %d  ·  追击 %d  ·  掩护 %d  ·  维护 %.1f / 月%s",
                mainUnit.damage, mainUnit.toughness, mainUnit.pursuit,
                mainUnit.screen, mainUnit.maintenance, vsTxt))
        end
        -- 更新下拉列表（行已建好，这里只改 文字/禁用态/颜色 —— UI 库不支持重建 children 重排）
        if refs.armyUnitRows then
            for _, u in ipairs(Units.all()) do
                local row = refs.armyUnitRows[u.id]
                if row then
                    local unlocked = Units.isUnlocked(f, u.id)
                    local isMain = (u.id == mainUnit.id)
                    -- 列表行只留兵种名（2026-09-19 用户："上边儿对这个兵种进行介绍，
                    --   底下就不要有"）—— 数值统一由上面的介绍行负责，列表保持干净。
                    --   选中态**只看背景高亮**（用户："为什么用这个大白圈还有'当前'这两个字，把它取消"）
                    row:SetText(u.name)
                    row:SetDisabled(not unlocked)
                    row.props.backgroundColor = isMain and { 62, 82, 112, 240 } or { 36, 45, 60, 235 }
                    row.props.borderColor = isMain and { 150, 120, 70, 200 } or { 70, 62, 44, 150 }
                end
            end
        end
    end

    -- 成本预览（2026-09-24 改为**按人头等比**，与 MilitarySystem 共用同一套费率函数）
    --   旧口径按"1000 人一批向上取整" → 填 100 和填 1000 都报同一个价（用户截图质疑）
    if refs.armyCostGold and refs.armyCostFood then
        local n = GameUI.armyWanted()
        local MilitarySystem = require("systems.MilitarySystem")
        local goldCost, foodCost = MilitarySystem.recruitCostFor(f, n)
        -- 只报成本（2026-09-19 用户："把'现有多少多少'这个黄金和粮食给关掉"）
        --   —— 现有钱粮看顶栏就行，这里腾出位置给「征召」按钮
        -- 金/粮**两个独立 Label 竖排**（2026-09-24 用户："粮食和黄金竖着放，不然数字太多
        --   后边放不下"；点号也去掉）。⚠️ 不要用一个 Label 里塞 "\n" + whiteSpace="normal"：
        --   那样在 row 容器里量不到宽度，整块会消失（上一版就这么把成本弄没的）。
        refs.armyCostGold:SetText(string.format("需要 %d 金", goldCost))
        refs.armyCostFood:SetText(string.format("需要 %d 粮", foodCost))
    end
end

--- 点「征召」：能征多少征多少，实际数量会回话
local function doArmyRecruit()
    local gs = refs.gameState
    local f = gs and gs.getPlayerFaction and gs.getPlayerFaction() or nil
    if not (gs and f) then return end
    if refs.armyHint then refs.armyHint:SetText("") end
    local pid = refs.armyProvId
    if not pid then
        if refs.armyHint then refs.armyHint:SetText("先选一个地区（点「选地区」后到地图上点）") end
        return
    end
    local wanted = GameUI.armyWanted()
    local MilitarySystem = require("systems.MilitarySystem")
    local ok, res = MilitarySystem.recruit(gs, f.id, pid, wanted)
    if ok then
        -- 成功后**面板不关**（2026-09-24 用户："我并不能只征召，只是点了一下征召按钮它就关闭这个界面"）
        --   征召是可重复操作（补兵/分批征），关掉就得重新开面板 + 重选地区 → 很别扭。
        --   面板留着，地区/兵种/数量都还在，想连征几次直接再点「征召」。
        --   不飘绿字（用户："不要显示什么已征召多少人"），结果看顶栏「兵力」和地图驻军数字。
        print(string.format("[Army] 已征召 %d 人（面板保持打开）", tonumber(res) or wanted))
        -- 退出选地区模式（地区已确定），但**不关面板** —— 否则再点地图会误改征兵地区
        refs.armyPickMode = false
        GameUI.refreshArmyPanel(gs)      -- 刷新成本预览（钱粮少了，可负担数量跟着变）
    else
        if refs.armyHint then refs.armyHint:SetText("征召失败：" .. tostring(res)) end
        print("[Army] 征召失败：" .. tostring(res))
    end
end

local function createArmyPanel()
    -- 数量输入（TextField，可手打；两侧按钮各 ±100）
    refs.armyCountField = UI.TextField {
        id = "armyCountField",
        value = "100",
        height = 46, width = 100, flexGrow = 1, flexShrink = 1, fontSize = 16,
        -- 输入即时刷新成本行（2026-09-19 用户："随着我的数量增加它为什么没有变化"）
        onChange = function() GameUI.refreshArmyPanel(refs.gameState) end,
    }
    local function bump(delta)
        local n = GameUI.armyWanted() + delta
        if n < 100 then n = 100 end
        refs.armyCountField:SetValue(tostring(n))
        GameUI.refreshArmyPanel(refs.gameState)
    end

    -- 兵种行（2026-09-19 兵种系统，用户口径："兵种是向下划"）：
    --   点按钮 → 向下展开兵种列表；列表**全列出**，未解锁的**灰名字**、不可点
    refs.armyUnitBtn = UI.Button {
        text = "轻步兵", width = "100%", height = 48, fontSize = 15,
        backgroundColor = { 46, 58, 78, 235 },
        hoverBackgroundColor = { 66, 82, 108, 245 },
        pressedBackgroundColor = { 38, 48, 66, 250 },
        borderWidth = 1, borderColor = { 120, 100, 66, 190 },
        borderRadius = 6,
        onClick = function()
            if not refs.armyUnitList then return end
            GameUI.toggleArmyUnitList()
            GameUI.refreshArmyPanel(refs.gameState)
            print("[Army] 兵种列表" .. (refs.armyUnitList:IsVisible() and "展开" or "收起"))
        end,
    }
    refs.armyUnitInfo = UI.Label {
        text = "", fontSize = 12, fontColor = COLORS.textSecondary,
        width = "100%", whiteSpace = "normal", maxLines = 3,
    }
    -- 兵种下拉列表（默认收起）
    --   注意：UI 库没有"重建 children 后强制重排"的接口（InvalidateLayout 不存在），
    --   所以**行在创建时就全部建好**，refreshArmyPanel 里只改文字/颜色/禁用态
    refs.armyUnitRows = {}
    refs.armyUnitList = UI.Panel {
        -- 内联陈列（2026-09-19 用户："兵种这么多，放不下没关系，可以往下滑"）：
        --   面板已改成"全高侧栏 + 中间滚动区"，列表正常参与布局即可 ——
        --   超出屏幕由滚动区接管。之前那套 absolute 浮层 + 动态定位全部去掉。
        width = "100%",
        flexDirection = "column", gap = 4,
        pointerEvents = "auto",
        backgroundColor = { 22, 28, 40, 200 },
        borderRadius = 6,
        padding = 6,
        children = (function()
            local Units = require("data.Units")
            local rows = {}
            for _, u in ipairs(Units.all()) do
                local uid = u.id
                local btn = UI.Button {
                    text = u.name, width = "100%", height = 48, fontSize = 15,
                    backgroundColor = { 36, 45, 60, 235 },
                    hoverBackgroundColor = { 72, 92, 122, 245 },
                    textColor = { 232, 226, 210, 255 },
                    disabledTextColor = { 122, 122, 128, 255 },
                    disabledBackgroundColor = { 30, 36, 46, 200 },
                    borderWidth = 1, borderColor = { 70, 62, 44, 150 },
                    borderRadius = 5,
                    onClick = function()
                        local gs = refs.gameState
                        local f = gs and gs.getPlayerFaction and gs.getPlayerFaction() or nil
                        if not f or not Units.isUnlocked(f, uid) then return end
                        f.mainUnitId = uid
                        print(string.format("[Army] 主力兵种 → %s（%s）", u.name, uid))
                        GameUI.toggleArmyUnitList(false)
                        GameUI.refreshArmyPanel(gs)
                    end,
                }
                refs.armyUnitRows[uid] = btn
                rows[#rows + 1] = btn
            end
            return rows
        end)(),
    }
    refs.armyUnitList:Hide()
    -- 被拒省名（点了别国的省时记下来，地区行显示原因；选中/关面板清掉）
    refs.armyProvRejectName = nil
    refs.armyProvLabel = UI.Label {
        text = "未选地区 · 点右侧按钮，再点地图上自己的省",
        fontSize = 13, fontColor = COLORS.textSecondary,
        flexGrow = 1, flexShrink = 1, whiteSpace = "normal", maxLines = 2,
    }
    -- 选地区按钮（2026-09-19 用户："当我选完选地区之后，这个按钮变亮"）
    --   提到 refs，选完省之后由 refreshArmyPanel 换成亮色
    refs.armyPickBtn = UI.Button {
        text = "选地区", width = 104, height = 48, fontSize = 15, flexShrink = 0,
        backgroundColor = { 46, 58, 78, 235 },
        hoverBackgroundColor = { 66, 82, 108, 245 },
        pressedBackgroundColor = { 38, 48, 66, 250 },
        borderWidth = 1, borderColor = { 120, 100, 66, 190 },
        borderRadius = 6,
        onClick = function()
            -- 一个按钮两种意思（2026-09-21 用户："点击完这个按钮之后它应该发亮才对，
            --   再点击就会关闭这个选地区"）：
            --   没开 → 进入选地区模式（按钮发亮）；开着 → 再点一下退出
            --   ⚠️ 这里绝不能调 hideArmyPanel：它开头就把 armyPickMode 重置成 false
            if refs.armyPickMode then
                refs.armyPickMode = false
                if refs.armyHint then refs.armyHint:SetText("") end
                print("[Army] 退出选地区模式")
            else
                -- 快捷路径（2026-09-24 用户："我已经选择区块之后点击选地区按钮，则是选择这个区块"）：
                --   地图上已经点中一个**自己的省**（省份面板那个选中态）→ 直接拿它当征兵地区，
                --   不用再让玩家去地图上重点一遍；选完按钮照样保持发亮（= 还在选地区模式里，
                --   想换省直接点地图别的省即可，行为与手动选一致）。
                local gs = refs.gameState
                local selId = refs.selectedProvinceId
                local selProv = gs and selId and gs.provinces and gs.provinces[selId]
                if selProv and gs.playerFactionId and selProv.ownerId == gs.playerFactionId then
                    refs.armyPickMode = true
                    GameUI.setArmyProvince(selId)     -- 回填地区（它自己会清提示）
                    print(string.format("[Army] 选地区：直接用当前选中省 %s(%s)",
                        tostring(selProv.name), tostring(selId)))
                    GameUI.refreshArmyPanel(gs)
                    return
                end
                -- 已选中省但不是自己的 → 立刻说明原因，别让玩家以为"点了没反应"
                if selProv and selProv.ownerId then
                    local Provinces = require("data.Provinces")
                    local def = Provinces.byId and Provinces.byId[selId]
                    refs.armyProvRejectName = (def and def.name) or tostring(selId)
                end
                refs.armyPickMode = true
                -- 进入选地区模式**不写绿色提示**（2026-09-24 用户："这个绿色的字不要显示"）：
                --   该怎么点已经写在「征召地区」那一行里了，不必再飘一行绿字。
                --   下方 0.4 秒的定期刷新会把提示清空（见 refreshArmyPanel）。
                print("[Army] 进入选地区模式：点地图上自己的省")
            end
            GameUI.refreshArmyPanel(refs.gameState)   -- 立刻换按钮高亮（别等 0.4 秒的定期刷新）
        end,
    }
    -- 成本：金 / 粮**各一行**（竖排），不用单个多行 Label（2026-09-24 修，见 refreshArmyPanel 注释）
    refs.armyCostGold = UI.Label {
        text = "", fontSize = 13, fontColor = { 235, 210, 150, 255 }, fontWeight = "bold",
    }
    refs.armyCostFood = UI.Label {
        text = "", fontSize = 13, fontColor = { 235, 210, 150, 255 }, fontWeight = "bold",
    }
    refs.armyHint = UI.Label {
        text = "", fontSize = 12, fontColor = { 150, 230, 160, 255 },
        whiteSpace = "normal", maxLines = 2,
    }
    -- 右上角 X（2026-09-19 用户："在他的右上角有一个叉号"）
    refs.armyCloseBtn = UI.Button {
        text = "×", width = 46, height = 46, fontSize = 22, flexShrink = 0,
        backgroundColor = { 46, 52, 66, 235 },
        hoverBackgroundColor = { 92, 60, 58, 245 },
        borderWidth = 1, borderColor = { 110, 96, 66, 190 }, borderRadius = 6,
        onClick = function() GameUI.hideArmyPanel() end,
    }

    refs.armyPanel = UI.Panel {
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        -- 靠左摆放（2026-09-19 用户："把它往左靠"）：点「选地区」后右边要露出地图，
        --   居中会把地图挡死、没法点省份
        justifyContent = "flex-start", alignItems = "center",
        -- 左边**贴满屏幕**（2026-09-21 用户："首先左边儿贴满"）：原来留 14px 缝，现在贴左边缘
        paddingLeft = 0,
        -- 顶部**紧贴顶栏下沿**（2026-09-21 用户："把它往上挪，跟上面那个框（顶栏）紧挨着"）：
        --   打开时由 GameUI.syncArmyPanelTop() 按顶栏**实测底边**校准（顶栏是 minHeight 54 +
        --   flexWrap，窄屏换行会变高，不能硬编码）；这里的 58 = 顶栏 54 + 4，只是布局未算好时的初值
        paddingTop = 58,
        -- 背景不压暗（2026-09-19 用户："不要让背景是灰色"）：整块透明，
        --   地图保持原色，点选省份看得更清楚
        backgroundColor = { 0, 0, 0, 0 },
        -- 外层遮罩用 **box-none**（2026-09-19）：
        --   "none" 会把**整棵子树**都屏蔽 → 面板自己也点不动了
        --   （用户反馈："不仅无法滑动、无法拖动、也无法点击，只能点到它背后的东西"）
        --   "box-none" = 容器自己不响应（点空白处照样穿透到地图，能点省选地区），
        --   但**子元素正常吃事件** → 面板上的按钮/输入框/拖动都能用。
        pointerEvents = "box-none",
        children = {
            UI.Panel {
                width = 400,
                height = "100%",
                marginRight = "auto",
                backgroundColor = { 20, 25, 35, 255 },
                borderRadiusTopRight = 8,
                borderWidth = 1, borderColor = COLORS.border,
                padding = 14, gap = 8,
                pointerEvents = "auto",
                onClick = function() end,                 -- 点面板本体不关
                children = {
                    -- 标题行：标题 + 弹簧 + 右上角 X（2026-09-19 用户："在他的右上角有一个叉号"）
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", width = "100%",
                        children = {
                            UI.Label { text = "征召军队", fontSize = 15, fontColor = COLORS.gold, fontWeight = "bold" },
                            UI.Panel { flexGrow = 1 },
                            refs.armyCloseBtn,
                        },
                    },
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    -- ② 内容滚动区（2026-09-19 用户："兵种这么多，放不下没关系，可以往下滑"）：
                    --   标题和底栏固定，中间这段 flexGrow 撑满剩余空间、内容超出就滚动
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1, flexBasis = 0,
                        scrollY = true, scrollX = false,
                        showScrollbar = true,
                        children = {
                            UI.Panel {
                                flexDirection = "column", width = "100%", gap = 10,
                                children = {
                    -- 数量区
                    UI.Panel {
                        width = "100%", padding = 10, gap = 8,
                        backgroundColor = { 30, 38, 53, 235 }, borderRadius = 7,
                        children = {
                            UI.Label { text = "征召数量", fontSize = 13, fontColor = COLORS.gold },
                            UI.Panel {
                                flexDirection = "row", alignItems = "center", gap = 8, width = "100%",
                                children = {
                                    UI.Button {
                                        text = "−100", width = 74, height = 46, fontSize = 14, flexShrink = 0,
                                        backgroundColor = { 46, 58, 78, 235 },
                                        hoverBackgroundColor = { 66, 82, 108, 245 },
                                        pressedBackgroundColor = { 38, 48, 66, 250 },
                                        borderRadius = 6,
                                        onClick = function() bump(-100) end,
                                    },
                                    refs.armyCountField,
                                    UI.Button {
                                        text = "+100", width = 74, height = 46, fontSize = 14, flexShrink = 0,
                                        backgroundColor = { 46, 58, 78, 235 },
                                        hoverBackgroundColor = { 66, 82, 108, 245 },
                                        pressedBackgroundColor = { 38, 48, 66, 250 },
                                        borderRadius = 6,
                                        onClick = function() bump(100) end,
                                    },
                                },
                            },
                        },
                    },
                    -- 兵种区：说明独占一行，列表紧跟在选择按钮下方
                    UI.Panel {
                        width = "100%", padding = 10, gap = 8,
                        backgroundColor = { 30, 38, 53, 235 }, borderRadius = 7,
                        children = {
                            UI.Label { text = "兵种", fontSize = 13, fontColor = COLORS.gold },
                            refs.armyUnitBtn,
                            refs.armyUnitInfo,
                            refs.armyUnitList,
                        },
                    },
                    -- 地区区：按钮不挤压省名，右侧地图仍可点选
                    UI.Panel {
                        width = "100%", padding = 10, gap = 8,
                        backgroundColor = { 30, 38, 53, 235 }, borderRadius = 7,
                        children = {
                            UI.Label { text = "征召地区", fontSize = 13, fontColor = COLORS.gold },
                            UI.Panel {
                                flexDirection = "row", alignItems = "center", gap = 8, width = "100%",
                                children = { refs.armyProvLabel, refs.armyPickBtn },
                            },
                        },
                    },
                                },
                            },
                        },
                    },
                    -- ③ 底部固定栏（2026-09-19）：不随内容滚动跑掉，按钮永远点得到
                    UI.Divider { color = COLORS.border, thickness = 1 },
                    -- 成本行 + 按钮同一行（2026-09-19 用户："把'现有多少多少'这个
                    --   黄金和粮食给关掉，改为'征召'这两个字"）
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 10, width = "100%",
                        children = {
                            -- 金 / 粮竖排（column 容器，两行各一个 Label）
                            UI.Panel {
                                flexDirection = "column", gap = 2, flexShrink = 1,
                                children = { refs.armyCostGold, refs.armyCostFood },
                            },
                            UI.Panel { flexGrow = 1, flexShrink = 1 },   -- 弹簧：征召推到最右
                            -- 「取消」已删（2026-09-19 用户："把取消这个按钮删掉"）——
                            --   右上角有 X，这里只留「征召」
                            UI.Button {
                                text = "征召", width = 116, height = 50, fontSize = 16, fontWeight = "bold", flexShrink = 0,
                                backgroundColor = { 168, 124, 38, 240 },
                                hoverBackgroundColor = { 196, 148, 54, 245 },
                                pressedBackgroundColor = { 135, 96, 30, 255 },
                                borderRadius = 6,
                                onClick = doArmyRecruit,
                            },
                        },
                    },
                    refs.armyHint,
                },
            },
        },
    }
    -- 面板**不可拖动**（2026-09-21 用户："这个不可以拖动"）：原 2026-09-19 加的那套
    --   onPointerDown/Move/Up 拖拽已整段移除。点面板内部照样不会透到后面的地图
    --   （内层 pointerEvents="auto" 吃事件 + isPointOverPanel 兜底）。
    -- 黑框本体：防穿透判断用它（外壳是全屏容器，见 isPointOverPanel）
    refs.armyPanelBox = refs.armyPanel.props.children and refs.armyPanel.props.children[1] or nil

    refs.armyPanel:Hide()
    return refs.armyPanel
end

--- 把本模块的方法挂回 GameUI 主表
---@param gameUI table GameUI 主表
function M.install(gameUI)
    gameUI.isArmyPickMode      = isArmyPickMode
    gameUI.hideArmyPanel       = hideArmyPanel
    gameUI.syncArmyPanelTop    = syncArmyPanelTop
    gameUI.showArmyPanel       = showArmyPanel
    gameUI.toggleArmyPanel     = toggleArmyPanel
    gameUI.setArmyProvince     = setArmyProvince
    gameUI.armyWanted          = armyWanted
    gameUI.toggleArmyUnitList  = toggleArmyUnitList
    gameUI.refreshArmyPanel    = refreshArmyPanel
end

--- 创建征召军队面板
---@param ctx table 共享上下文
---@return Widget armyPanel
function M.create(ctx)
    UI          = ctx.UI
    GameUI      = ctx.GameUI
    refs        = ctx.refs
    COLORS      = ctx.COLORS
    SmallButton = ctx.SmallButton
    return createArmyPanel()
end

return M

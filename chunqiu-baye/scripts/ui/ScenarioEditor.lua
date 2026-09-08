-- ============================================================================
-- ScenarioEditor.lua - 剧本编辑器 v2（AoH3 式）
-- 进门即地图；国家增删改（名/色/金粮兵/倾向/都城）、领土划归刷、沙漠地形刷、
-- 两国关系编辑、剧本存载、以此国开局。
-- 剧本数据结构 = SaveManager.collect 的反结构；开局走 save.json+ContinueGame 管线。
-- ============================================================================

local UI          = require("urhox-libs/UI")
local Factions    = require("data.Factions")
local Geography   = require("data.Geography")
local MapPack     = require("data.MapPack")
local TimeSystem  = require("core.TimeSystem")
local SaveManager = require("save.SaveManager")
local MapRenderer = require("map.MapRenderer")

local ScenarioEditor = {}

local PALETTE = {
    {178,60,52,255},{92,155,145,255},{165,115,75,255},{178,175,58,255},
    {105,138,80,255},{150,115,195,255},{80,150,175,255},{185,105,125,255},
    {150,105,150,255},{85,98,135,255},{130,150,65,255},{196,150,80,255},
}

local PERSONALITIES = { "守成", "求存", "霸者", "掠夺" }

-- ---------------------------------------------------------------------------
-- 剧本数据构建
-- ---------------------------------------------------------------------------
local function buildScenario()
    local s = {
        version = 1,
        mapPack = MapPack.activeId,
        playerFactionId = nil,
        time = TimeSystem.getState(),
        factions = {},
        provinceStates = {},
        relations = {},
    }
    local best, bn = nil, -1
    for _, f in ipairs(Factions.data or {}) do
        if f.provinces and #f.provinces > 0 then
            s.factions[f.id] = {
                id = f.id,
                name = f.name or ("#" .. tostring(f.id)),
                fullName = f.fullName or (f.name or "?"),
                color = f.color or { 150, 150, 150, 255 },
                gold = f.gold or 150,
                food = f.food or 120,
                armySize = f.armySize or 2000,
                prestige = f.prestige or 50,
                stability = f.stability or 70,
                morale = 100,
                alive = true,
                capitalId = f.capitalId,
                provinces = {},
                aiPersonality = f.aiPersonality or "守成",
            }
            for _, pid in ipairs(f.provinces) do
                s.factions[f.id].provinces[#s.factions[f.id].provinces + 1] = pid
                s.provinceStates[tostring(pid)] = { ownerId = f.id }
            end
            if #s.factions[f.id].provinces > bn then
                best, bn = f.id, #s.factions[f.id].provinces
            end
        end
    end
    s.playerFactionId = best
    return s
end

-- ---------------------------------------------------------------------------
-- 主入口
-- ---------------------------------------------------------------------------
---@param opts table { onStart=function(scenario), onBack=function() }
function ScenarioEditor.show(opts)
    opts = opts or {}

    local scenario = SaveManager.loadScenario() or buildScenario()

    -- 编辑用活 gameState（Widget 实时读取归属/颜色/沙漠）
    local editorGS = { provinces = {}, factions = scenario.factions, playerFactionId = scenario.playerFactionId }
    local function syncEditorGS()
        editorGS.provinces = {}
        for pid, ps in pairs(scenario.provinceStates) do
            editorGS.provinces[tonumber(pid)] = {
                ownerId = ps.ownerId,
                isWasteland = ps.isWasteland or false,
            }
        end
        editorGS.factions = scenario.factions
    end
    syncEditorGS()

    local selectedId = scenario.playerFactionId
    local lastClickedProv = nil
    local mode = "off"            -- off / paint / desert
    local otherRelId = nil        -- 关系编辑：对方国家
    local mapWidget = nil

    local listRefs = {}           -- [fid] = { hl, nameLabel, countLabel }
    local msgLabel = nil
    local listPanelRef = nil
    local propsPanelRef = nil
    local modeBtnRef = nil
    local relOtherDropdown = nil
    local relSlider = nil
    local relValueLabel = nil

    local function setMsg(text)
        if msgLabel then msgLabel:SetText(text) end
    end

    local function selectedFaction()
        return selectedId and scenario.factions[selectedId] or nil
    end

    local function sortedFactions()
        local arr = {}
        for _, f in pairs(scenario.factions) do arr[#arr + 1] = f end
        table.sort(arr, function(a, b)
            return #(a.provinces or {}) > #(b.provinces or {})
        end)
        return arr
    end

    -- -------------------------------------------------------------------------
    -- 数据操作
    -- -------------------------------------------------------------------------
    local function assignProvince(pid, fid)
        local ps = scenario.provinceStates[tostring(pid)] or {}
        local old = ps.ownerId
        if old == fid then return end
        if old and scenario.factions[old] then
            local lst = scenario.factions[old].provinces
            for i, v in ipairs(lst) do
                if v == pid then table.remove(lst, i) break end
            end
            local of = scenario.factions[old]
            if of.capitalId == pid then of.capitalId = of.provinces[1] end
            if #of.provinces == 0 then of.alive = false end
            if listRefs[old] then listRefs[old].countLabel:SetText("省" .. #of.provinces) end
        end
        local nf = scenario.factions[fid]
        if nf then
            local exists = false
            for _, v in ipairs(nf.provinces) do
                if v == pid then exists = true break end
            end
            if not exists then nf.provinces[#nf.provinces + 1] = pid end
            if not nf.alive then nf.alive = true end
            if not nf.capitalId then nf.capitalId = pid end
            if listRefs[fid] then listRefs[fid].countLabel:SetText("省" .. #nf.provinces) end
        end
        scenario.provinceStates[tostring(pid)] = {
            ownerId = fid, isWasteland = ps.isWasteland or false,
        }
        editorGS.provinces[pid] = {
            ownerId = fid, isWasteland = ps.isWasteland or false,
        }
    end

    local function makeUnowned(pid)
        local ps = scenario.provinceStates[tostring(pid)] or {}
        local old = ps.ownerId
        if old and scenario.factions[old] then
            local lst = scenario.factions[old].provinces
            for i, v in ipairs(lst) do
                if v == pid then table.remove(lst, i) break end
            end
            local of = scenario.factions[old]
            if of.capitalId == pid then of.capitalId = of.provinces[1] end
            if #of.provinces == 0 then of.alive = false end
            if listRefs[old] then listRefs[old].countLabel:SetText("省" .. #of.provinces) end
        end
        scenario.provinceStates[tostring(pid)] = {
            ownerId = nil, isWasteland = ps.isWasteland or false,
        }
        editorGS.provinces[pid] = {
            ownerId = nil, isWasteland = ps.isWasteland or false,
        }
    end

    local function toggleDesert(pid)
        local ps = scenario.provinceStates[tostring(pid)] or {}
        local cur = ps.isWasteland or false
        local v = not cur
        ps.ownerId = ps.ownerId
        ps.isWasteland = v
        scenario.provinceStates[tostring(pid)] = ps
        local e = editorGS.provinces[pid] or {}
        e.ownerId = ps.ownerId
        e.isWasteland = v
        editorGS.provinces[pid] = e
        setMsg(v and "该省已沙漠化" or "已取消沙漠（注：原生沙漠底图无法还原）")
    end

    local function newFaction()
        local maxId = 0
        for fid in pairs(scenario.factions) do
            if fid > maxId then maxId = fid end
        end
        local nid = maxId + 1
        scenario.factions[nid] = {
            id = nid, name = "新国家", fullName = "新国家",
            color = PALETTE[math.random(#PALETTE)],
            gold = 150, food = 120, armySize = 2000,
            prestige = 50, stability = 70, morale = 100,
            alive = true, capitalId = nil, provinces = {},
            aiPersonality = "守成",
        }
        selectedId = nid
        editorGS.playerFactionId = nid
        setMsg("已新建国家（用「划归」刷给它领土）")
        if opts.rebuild then opts.rebuild() end
    end

    local function deleteFaction(fid)
        local f = scenario.factions[fid]
        if not f then return end
        for _, pid in ipairs(f.provinces) do
            makeUnowned(pid)
        end
        scenario.factions[fid] = nil
        -- 清理涉及该国的关系
        for k in pairs(scenario.relations) do
            local a, b = k:match("^(%d+)_(%d+)$")
            if a and (tonumber(a) == fid or tonumber(b) == fid) then
                scenario.relations[k] = nil
            end
        end
        if selectedId == fid then selectedId = nil end
        setMsg("已删除国家（领土设为无主）")
        if opts.rebuild then opts.rebuild() end
    end

    local function relKey(a, b) return tostring(a) .. "_" .. tostring(b) end

    local function getRelation(a, b)
        local rec = scenario.relations[relKey(a, b)] or scenario.relations[relKey(b, a)]
        return rec and rec.value or 0
    end

    local function setRelation(a, b, v)
        local rec = { value = v, atWar = false, peaceCooldown = 0 }
        scenario.relations[relKey(a, b)] = rec
        scenario.relations[relKey(b, a)] = rec
    end

    -- -------------------------------------------------------------------------
    -- 地图 Widget 与点击
    -- -------------------------------------------------------------------------
    mapWidget = MapRenderer.create(editorGS)

    -- 首帧全图对焦（等布局就绪后自动适配整个世界）+ 全图按钮共用
    local fitTicks = 0
    local function fitAll()
        if not mapWidget or not mapWidget.GetAbsoluteLayout then return false end
        local l = mapWidget:GetAbsoluteLayout()
        if not l or not l.w or l.w <= 0 then return false end
        local z = math.min(l.w / Geography.MAP_W, l.h / Geography.MAP_H) * 0.96
        mapWidget.camX = Geography.MAP_W * 0.5
        mapWidget.camY = Geography.MAP_H * 0.5
        mapWidget.zoom = z
        mapWidget.targetZoom = z
        if mapWidget._clampCamera then mapWidget:_clampCamera() end
        return true
    end
    -- 调试读数(定位预览黑地图:显示布局/缩放/镜头)
    local dbgLabel = nil
    local dbgTicks = 0
    local fitted = false
    ScenarioEditor.onUpdate = function()
        dbgTicks = dbgTicks + 1
        if (not fitted) and fitAll() then
            fitted = true
            setMsg("全图对焦完成")
        end
        if (dbgTicks % 10 == 0) and mapWidget.GetAbsoluteLayout then
            local l = mapWidget:GetAbsoluteLayout()
            local dbg = UI.FindById and UI.FindById("editorDbgLabel")
            if dbg then
                dbg:SetText(string.format(
                    "DBG 布局:%sx%s 缩放:%.3f 镜头:%.0f,%.0f 帧:%d%s",
                    l and math.floor(l.w) or -1, l and math.floor(l.h) or -1,
                    mapWidget.zoom or -1, mapWidget.camX or -1, mapWidget.camY or -1,
                    dbgTicks, fitted and " 已对焦" or " 对焦中"))
            end
        end
    end

    mapWidget.onProvinceClick = function(provId)
        if not provId then return end
        lastClickedProv = provId
        if mode == "paint" and selectedId then
            assignProvince(provId, selectedId)
        elseif mode == "desert" then
            toggleDesert(provId)
        end
    end

    -- -------------------------------------------------------------------------
    -- 通用控件
    -- -------------------------------------------------------------------------
    local function paperBtn(text, onClick, o)
        if type(onClick) == "table" and type(o) == "function" then
            onClick, o = o, onClick
        end
        o = o or {}
        return UI.Button {
            text = text,
            width = o.width, height = o.height or 36,
            fontSize = o.fontSize or 14,
            fontFamily = "gufeng", fontWeight = "bold",
            textColor = o.textColor or { 56, 36, 18, 255 },
            backgroundColor = { 255, 250, 236, 120 },
            hoverBackgroundColor = { 255, 244, 210, 190 },
            pressedBackgroundColor = { 214, 190, 148, 200 },
            borderColor = { 110, 82, 50, 200 }, borderWidth = 1,
            borderRadius = 8,
            onClick = onClick,
        }
    end

    local function sectionLabel(text)
        return UI.Label { text = text, fontSize = 14, fontFamily = "gufeng",
                          fontWeight = "bold", fontColor = { 150, 108, 52, 255 },
                          width = 240 }
    end

    -- -------------------------------------------------------------------------
    -- 侧栏：国家列表（选中高亮 = opacity 叠层）
    -- -------------------------------------------------------------------------
    local function buildList()
        local children = {}
        for _, f in ipairs(sortedFactions()) do
            local fid = f.id
            local hl = UI.Panel {
                position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
                backgroundColor = { 226, 192, 120, 110 }, borderRadius = 8,
                opacity = (fid == selectedId) and 1 or 0,
            }
            local nameLabel = UI.Label { text = f.name or "?", fontSize = 13, width = 88,
                fontFamily = "gufeng", fontWeight = "bold",
                fontColor = { 242, 228, 196, 255 } }
            local countLabel = UI.Label { text = "省" .. #(f.provinces or {}), fontSize = 10,
                width = 104, textAlign = "right",
                fontColor = { 214, 200, 170, 215 } }
            listRefs[fid] = { hl = hl, nameLabel = nameLabel, countLabel = countLabel }
            children[#children + 1] = UI.Button {
                width = "100%", height = 38, marginBottom = 3,
                backgroundColor = { 0, 0, 0, 0 },
                hoverBackgroundColor = { 236, 214, 160, 40 },
                pressedBackgroundColor = { 0, 0, 0, 0 },
                borderRadius = 8,
                onClick = function()
                    if selectedId and listRefs[selectedId] then
                        listRefs[selectedId].hl:SetStyle({ opacity = 0 })
                    end
                    selectedId = fid
                    editorGS.playerFactionId = fid
                    listRefs[fid].hl:SetStyle({ opacity = 1 })
                    if propsPanelRef then propsPanelRef:rebuild() end
                end,
                children = {
                    hl,
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 8,
                        width = "100%", paddingLeft = 8, paddingRight = 8,
                        children = {
                            UI.Panel { width = 16, height = 16, borderRadius = 8,
                                       backgroundColor = f.color or { 150, 150, 150, 255 } },
                            nameLabel,
                            UI.Panel { flexGrow = 1 },
                            countLabel,
                        },
                    },
                },
            }
        end
        return children
    end

    -- -------------------------------------------------------------------------
    -- 侧栏：选中国家属性（含关系编辑；每次选中重建）
    -- -------------------------------------------------------------------------
    local function buildProps()
        local f = selectedFaction()
        if not f then
            return { UI.Label { text = "（未选中国家）", fontSize = 12, width = 240,
                    fontColor = { 214, 200, 170, 200 } } }
        end
        local children = {}

        children[#children + 1] = sectionLabel("国名")
        children[#children + 1] = UI.TextField {
            width = 240, height = 38, value = f.name or "",
            placeholder = "输入国家名",
            onChange = function(self, value)
                f.name = value
                f.fullName = value
                if listRefs[f.id] then listRefs[f.id].nameLabel:SetText(value) end
            end,
        }

        children[#children + 1] = sectionLabel("颜色")
        local swatchRow = UI.Panel { flexDirection = "row", gap = 4, width = "100%" }
        for _, c in ipairs(PALETTE) do
            swatchRow:AddChild(UI.Button {
                width = 18, height = 18,
                backgroundColor = c, borderRadius = 9,
                borderWidth = 1, borderColor = { 30, 22, 12, 220 },
                onClick = function()
                    f.color[1], f.color[2], f.color[3], f.color[4] = c[1], c[2], c[3], 255
                    setMsg("颜色已更新（地图实时变色）")
                end,
            })
        end
        children[#children + 1] = swatchRow

        children[#children + 1] = sectionLabel("初始资源")
        local function numField(labelText, key)
            return UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 6, width = "100%",
                children = {
                    UI.Label { text = labelText, fontSize = 12, width = 40,
                               fontColor = { 214, 200, 170, 220 } },
                    UI.TextField {
                        width = 90, height = 32, value = tostring(f[key] or 0),
                        onChange = function(self, value)
                            local n = tonumber(value)
                            if n then f[key] = math.floor(n) end
                        end,
                    },
                },
            }
        end
        children[#children + 1] = numField("金", "gold")
        children[#children + 1] = numField("粮", "food")
        children[#children + 1] = numField("兵", "armySize")

        children[#children + 1] = sectionLabel("倾向")
        local popts = {}
        for _, p in ipairs(PERSONALITIES) do
            popts[#popts + 1] = { value = p, label = p }
        end
        children[#children + 1] = UI.Dropdown {
            options = popts, value = f.aiPersonality or "守成",
            width = 240, height = 36,
            onChange = function(self, value)
                f.aiPersonality = value
            end,
        }

        children[#children + 1] = sectionLabel("都城")
        children[#children + 1] = paperBtn("设为最后点选的省份", function()
            if lastClickedProv then
                f.capitalId = lastClickedProv
                setMsg("都城已设置")
            else
                setMsg("请先在地图上点一个省份")
            end
        end, { width = 240, height = 34, fontSize = 13 })

        -- 关系编辑
        children[#children + 1] = sectionLabel("与该国关系")
        local others = {}
        for _, of2 in ipairs(sortedFactions()) do
            if of2.id ~= f.id then others[#others + 1] = of2 end
        end
        if otherRelId == nil or otherRelId == f.id then
            otherRelId = others[1] and others[1].id or nil
        end
        local oopts = {}
        for _, of2 in ipairs(others) do
            oopts[#oopts + 1] = { value = tostring(of2.id), label = of2.name or "?" }
        end
        if #oopts == 0 then
            oopts[1] = { value = "0", label = "（无其他国家）" }
        end
        relOtherDropdown = UI.Dropdown {
            options = oopts,
            value = tostring(otherRelId or 0),
            width = 240, height = 36,
            onChange = function(self, value)
                otherRelId = tonumber(value)
                if relSlider and otherRelId then
                    relSlider:SetValue(getRelation(f.id, otherRelId))
                end
                if relValueLabel and otherRelId then
                    relValueLabel:SetText(tostring(getRelation(f.id, otherRelId)))
                end
            end,
        }
        children[#children + 1] = relOtherDropdown

        relValueLabel = UI.Label {
            text = tostring(otherRelId and getRelation(f.id, otherRelId) or 0),
            fontSize = 14, width = 40, fontColor = { 242, 228, 196, 255 },
        }
        relSlider = UI.Slider {
            min = -100, max = 100, step = 1,
            value = (otherRelId and getRelation(f.id, otherRelId)) or 0,
            width = 180, height = 36,
            trackHeight = 8, thumbSize = 24,
            trackBgColor = { 92, 70, 46, 200 },
            trackFillColor = { 172, 128, 62, 255 },
            thumbColor = { 122, 84, 40, 255 },
            onChange = function(self, value)
                if otherRelId then
                    setRelation(f.id, otherRelId, math.floor(value))
                    relValueLabel:SetText(tostring(math.floor(value)))
                end
            end,
        }
        children[#children + 1] = UI.Panel {
            flexDirection = "row", alignItems = "center", gap = 8, width = "100%",
            children = { relSlider, relValueLabel },
        }

        children[#children + 1] = UI.Button {
            text = "删除此国家", width = 240, height = 34,
            fontSize = 13, fontFamily = "gufeng", fontWeight = "bold",
            textColor = { 250, 234, 214, 255 },
            backgroundColor = { 146, 58, 40, 220 },
            hoverBackgroundColor = { 176, 70, 48, 235 },
            borderRadius = 8,
            onClick = function() deleteFaction(f.id) end,
        }

        return children
    end

    -- -------------------------------------------------------------------------
    -- 地图悬浮按钮
    -- -------------------------------------------------------------------------
    local function modeLabel()
        if mode == "paint" then return "模式:划归选中" end
        if mode == "desert" then return "模式:荒地(沙漠)" end
        return "模式:关"
    end

    local function buildMapOverlay()
        modeBtnRef = paperBtn(modeLabel(), function()
            if mode == "off" then mode = "paint"
            elseif mode == "paint" then mode = "desert"
            else mode = "off" end
            modeBtnRef:SetText(modeLabel())
            setMsg(mode == "paint" and "点省份→划给选中国家"
                or mode == "desert" and "点省份→切换 可占领⇄沙漠荒地"
                or "已关闭编辑刷")
        end, { height = 32, fontSize = 12, width = 150 })

        return {
            UI.Panel {
                position = "absolute", left = 8, top = 8,
                flexDirection = "column", gap = 6,
                children = {
                    modeBtnRef,
                    paperBtn("此省设为无主", function()
                        if lastClickedProv then
                            makeUnowned(lastClickedProv)
                            setMsg("该省已设为无主")
                        else
                            setMsg("请先在地图上点一个省份")
                        end
                    end, { height = 32, fontSize = 12, width = 150 }),
                },
            },
            UI.Panel {
                position = "absolute", right = 8, bottom = 8,
                children = {
                    paperBtn("全 图", function()
                        if not fitAll() then setMsg("布局未就绪,稍后再试") end
                    end, { height = 30, fontSize = 12, width = 76 }),
                },
            },
            UI.Panel {
                position = "absolute", right = 8, top = 8,
                flexDirection = "column", gap = 6,
                children = {
                    paperBtn("保存剧本", function()
                        local ok, reason = SaveManager.saveScenario(scenario)
                        setMsg(ok and "剧本已保存" or ("保存失败:" .. tostring(reason)))
                    end, { height = 32, fontSize = 12, width = 130 }),
                    paperBtn("载入剧本", function()
                        local d = SaveManager.loadScenario()
                        if d then
                            scenario = d
                            selectedId = scenario.playerFactionId
                            otherRelId = nil
                            syncEditorGS()
                            if opts.rebuild then opts.rebuild() end
                            setMsg("剧本已载入")
                        else
                            setMsg("没有已保存的剧本")
                        end
                    end, { height = 32, fontSize = 12, width = 130 }),
                    paperBtn("以此国开局", function()
                        ScenarioEditor.onUpdate = nil
                        local f = selectedFaction()
                        if f then
                            scenario.playerFactionId = f.id
                            if opts.onStart then opts.onStart(scenario) end
                        else
                            setMsg("请先选中一个国家")
                        end
                    end, { height = 32, fontSize = 12, width = 130,
                           textColor = { 120, 40, 24, 255 } }),
                    paperBtn("返回主菜单", function()
                        ScenarioEditor.onUpdate = nil
                        if opts.onBack then opts.onBack() end
                    end, { height = 32, fontSize = 12, width = 130 }),
                },
            },
        }
    end

    -- -------------------------------------------------------------------------
    -- 组装
    -- -------------------------------------------------------------------------
    local function assemble()
        listRefs = {}
        local sideChildren = {}

        sideChildren[#sideChildren + 1] = UI.Label {
            text = "剧本编辑器", fontSize = 20, width = 240,
            fontFamily = "gufeng", fontWeight = "bold", fontColor = { 240, 210, 120, 255 },
        }
        msgLabel = UI.Label { text = "模式:关——开「划归」点省份划给选中国家", fontSize = 11,
            width = 240, fontColor = { 214, 200, 170, 220 } }
        sideChildren[#sideChildren + 1] = msgLabel

        sideChildren[#sideChildren + 1] = sectionLabel("国家列表（点选中）")
        listPanelRef = UI.Panel { flexDirection = "column", width = "100%" }
        for _, c in ipairs(buildList()) do listPanelRef:AddChild(c) end
        sideChildren[#sideChildren + 1] = UI.ScrollView {
            width = "100%", height = 210, flexShrink = 0,
            children = { listPanelRef },
        }

        sideChildren[#sideChildren + 1] = UI.Panel {
            flexDirection = "row", gap = 6, width = "100%",
            children = {
                paperBtn("＋新建国家", function() newFaction() end,
                    { width = 116, height = 34, fontSize = 13 }),
                paperBtn("－删除选中", function()
                    if selectedId then deleteFaction(selectedId) end
                end, { width = 116, height = 34, fontSize = 13,
                      textColor = { 146, 58, 40, 255 } }),
            },
        }

        sideChildren[#sideChildren + 1] = sectionLabel("选中国家属性（可滚动）")
        propsPanelRef = UI.Panel {
            flexDirection = "column", width = "100%", gap = 5,
        }
        local function rebuildProps()
            if not propsPanelRef then return end
            for _, c in ipairs(propsPanelRef.children or {}) do
                propsPanelRef:RemoveChild(c)
            end
            for _, c in ipairs(buildProps()) do
                propsPanelRef:AddChild(c)
            end
        end
        propsPanelRef.rebuild = rebuildProps
        for _, c in ipairs(buildProps()) do propsPanelRef:AddChild(c) end
        sideChildren[#sideChildren + 1] = propsPanelRef

        local side = UI.Panel {
            width = 300,
            backgroundColor = { 24, 20, 15, 245 },
            padding = 10,
            flexDirection = "column",
            children = {
                UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0,
                                children = sideChildren },
            },
        }

        local mapPanel = UI.Panel { flexGrow = 1, children = { mapWidget } }
        local dbgLabel = UI.Panel {
            position = "absolute", left = 8, bottom = 34,
            backgroundColor = { 0, 0, 0, 200 },
            paddingLeft = 6, paddingRight = 6, paddingTop = 3, paddingBottom = 3,
            children = {
                UI.Label { id = "editorDbgLabel", text = "DBG init...", fontSize = 11,
                           width = 320, fontColor = { 255, 214, 90, 255 } },
            },
        }
        mapPanel:AddChild(dbgLabel)
        for _, w in ipairs(buildMapOverlay()) do
            mapPanel:AddChild(w)
        end

        local root = UI.Panel {
            width = "100%", height = "100%",
            backgroundColor = { 12, 12, 14, 255 },
            flexDirection = "row",
            children = { mapPanel, side },
        }
        UI.SetRoot(root)
    end

    opts.rebuild = function()
        assemble()
    end

    assemble()
end

return ScenarioEditor

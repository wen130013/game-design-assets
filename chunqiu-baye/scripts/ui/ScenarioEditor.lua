-- ============================================================================
-- ScenarioEditor.lua - 编辑器 v2（AoH3 式）
-- 进门即地图；国家增删改（名/色/金粮兵/倾向/都城）、领土划归刷、沙漠地形刷、
-- 两国关系编辑、剧本存载、以此国开局。
-- 剧本数据结构 = SaveManager.collect 的反结构；开局走 save.json+ContinueGame 管线。
-- ============================================================================

local UI          = require("urhox-libs/UI")
local Provinces   = require("data.Provinces")
local Geography   = require("data.Geography")
local MapPack     = require("data.MapPack")
local TimeSystem  = require("core.TimeSystem")
local SaveManager = require("save.SaveManager")
local MapRenderer = require("map.MapRenderer")
local WorldGenPanel = require("ui.WorldGenPanel")

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

--- 空剧本：全部领土无主（不含任何预设国家；玩家新建国家后从头划归）
--- 省份集合来自当前地图包，静态沙漠(isWasteland)省保持原样
local function buildEmptyScenario()
    local s = {
        version = 1,
        mapPack = MapPack.activeId,
        playerFactionId = nil,
        time = TimeSystem.getState(),
        factions = {},
        provinceStates = {},
        relations = {},
    }
    for _, prov in ipairs(Provinces.data or {}) do
        if prov.id and not prov.isOcean then
            s.provinceStates[tostring(prov.id)] = {
                ownerId = nil,
                isWasteland = prov.isWasteland or false,
            }
        end
    end
    return s
end

-- ---------------------------------------------------------------------------
-- 主入口
-- ---------------------------------------------------------------------------
---@param opts table { onStart=function(scenario), onBack=function() }
function ScenarioEditor.show(opts)
    opts = opts or {}

    -- 默认空剧本（全部领土无主，无预设国家）；如需读回已存剧本用左侧「载入剧本」
    local scenario = buildEmptyScenario()

    -- ============================================================
    -- 编辑器底图 = "无主底图"：底图上的可玩省统一为无主羊皮纸色，
    -- 避免旧春秋国家色残留在画面上；退出/开局前恢复政治底图。
    -- 整图包（eu4）切整图；只带瓦片的老包切瓦片前缀。
    -- （无主底图由 gen_neutral_tiles.py / make_whole_images.py 从
    --   province_id 位图染色生成，仅 eu4 包提供；其他地图包不切换。）
    -- ============================================================
    local origWhole      = MapPack.WHOLE_IMAGE_PATH
    local origWholeHalf  = MapPack.WHOLE_IMAGE_HALF_PATH
    local origTilePattern = MapPack.TILE_PATH_PATTERN
    local neutralOn = false
    if MapPack.activeId == "eu4" then
        if MapPack.NEUTRAL_WHOLE_IMAGE_PATH then
            MapPack.WHOLE_IMAGE_PATH      = MapPack.NEUTRAL_WHOLE_IMAGE_PATH
            MapPack.WHOLE_IMAGE_HALF_PATH = MapPack.NEUTRAL_WHOLE_IMAGE_HALF_PATH
        else
            MapPack.TILE_PATH_PATTERN = "image/eu4/neutral_tiles/map_%d_%d.png"
        end
        neutralOn = true
    end
    local function restoreBaseMap()
        if neutralOn then
            MapPack.WHOLE_IMAGE_PATH      = origWhole
            MapPack.WHOLE_IMAGE_HALF_PATH = origWholeHalf
            MapPack.TILE_PATH_PATTERN     = origTilePattern
            neutralOn = false
        end
    end
    -- 包装出口回调：先恢复政治底图再执行原有 onStart/onBack
    local origOnStart = opts.onStart
    local origOnBack = opts.onBack
    opts.onStart = function(data)
        restoreBaseMap()
        if origOnStart then origOnStart(data) end
    end
    opts.onBack = function()
        restoreBaseMap()
        if origOnBack then origOnBack() end
    end

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
    local pageRoot = nil          -- 本页 UI 根（世界生成面板挂载用）


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

    -- -------------------------------------------------------------------------
    -- 世界生成：清空现有国家，按邻接关系随机建国并划分全部领土
    -- -------------------------------------------------------------------------

    --- 随机生成世界（多源"轮流扩展"，保证各国领土大体均衡）
    ---@param count number 国家数量
    ---@return number assigned 已划分的省数
    local function randomizeWorld(count)
        count = math.max(1, math.floor(count or 12))
        -- 1) 重置归属与国家
        scenario.factions = {}
        for _, ps in pairs(scenario.provinceStates) do
            ps.ownerId = nil
        end
        selectedId = nil

        -- 2) 收集陆地省并打乱
        local land = {}
        for pid, ps in pairs(scenario.provinceStates) do
            if not ps.isWasteland then
                land[#land + 1] = tonumber(pid)
            end
        end
        if #land == 0 then return 0 end
        for i = #land, 2, -1 do
            local j = math.random(i)
            land[i], land[j] = land[j], land[i]
        end

        -- 3) 建国（颜色克隆自调色板，避免共享引用串色）
        for i = 1, count do
            local c = PALETTE[((i - 1) % #PALETTE) + 1]
            scenario.factions[i] = {
                id = i, name = "新国" .. i, fullName = "新国" .. i,
                color = { c[1], c[2], c[3], c[4] },
                gold = 150, food = 120, armySize = 2000,
                prestige = 50, stability = 70, morale = 100,
                alive = true, capitalId = nil, provinces = {},
                aiPersonality = "守成",
            }
        end

        -- 4) 均匀步长挑种子省，多源轮流扩展划分领土
        local owner = {}       -- pid -> fid
        local qs, qh = {}, {}  -- 每国队列 + 头指针
        local step = math.max(1, math.floor(#land / count))
        for i = 1, count do
            qs[i] = {}
            qh[i] = 1
            local pid = land[math.min(#land, (i - 1) * step + 1)]
            if pid and not owner[pid] then
                owner[pid] = i
                qs[i][#qs[i] + 1] = pid
            end
        end

        local active = count
        while active > 0 do
            active = 0
            for i = 1, count do
                local q = qs[i]
                if qh[i] <= #q then
                    active = active + 1
                    local pid = q[qh[i]]
                    qh[i] = qh[i] + 1
                    local prov = Provinces.byId[pid]
                    local nbs = prov and prov.neighbors
                    if nbs then
                        for k = 1, #nbs do
                            local nb = nbs[k]
                            if not owner[nb] then
                                local ps = scenario.provinceStates[tostring(nb)]
                                if ps and not ps.isWasteland then
                                    owner[nb] = i
                                    q[#q + 1] = nb
                                end
                            end
                        end
                    end
                end
            end
        end

        -- 5) 写回剧本
        local assigned = 0
        for pid, fid in pairs(owner) do
            local ps = scenario.provinceStates[tostring(pid)]
            local f = scenario.factions[fid]
            if ps and f then
                ps.ownerId = fid
                f.provinces[#f.provinces + 1] = pid
                if not f.capitalId then f.capitalId = pid end
                assigned = assigned + 1
            end
        end
        -- 国家列表按省数降序显示更直观：这里只保证数据正确，列表由 rebuild 读取
        syncEditorGS()
        return assigned
    end

    --- 世界生成面板回调（"生成新世界"）
    ---@param params table { pack, factionCount, seed, size, provinces, factions }
    local function onWorldGen(params)
        -- 地图包：切换后位图/尺寸都变 → 重建 shader 地图层并重挂到 mapWidget
        if params.pack and params.pack ~= MapPack.activeId then
            -- ⚠️ 必须用 switchTo（不是 setActive）：setActive 只切"名字"（activeId），
            --   省份数据 / 渲染常量 / 空间索引还停在旧包 → "旧包省份数据 + 新包尺寸底图"的
            --   混合态：地图错位、大片空白、按钮高亮与实际地图对不上。
            --   2026-09-23 修（用户反馈：选国页地图右边一整块空、高亮不符）。
            MapPack.switchTo(params.pack)
            setMsg("已切换地图包：" .. tostring(params.pack))
        end
        local seed = tonumber(params.seed)
        if seed then math.randomseed(seed) end
        local assigned = randomizeWorld(params.factionCount or 12)
        if opts.rebuild then opts.rebuild() end
        setMsg(string.format("已随机生成世界：%d 国 · 划分 %d 省（种子 %s）",
            params.factionCount or 12, assigned, tostring(params.seed)))
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
        -- 新建后自动进入「划归」模式：直接点地图领土划给新国家
        if mode ~= "paint" then
            mode = "paint"
            if modeBtnRef then modeBtnRef:SetText("模式:划归选中") end
        end
        setMsg("已新建国家——点击地图上的无主领土把它划给「" .. scenario.factions[nid].name .. "」")
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
        -- ⚠️ 布局未就绪时 GetAbsoluteLayout 可能返回 NaN 而非 0：
        --   `l.w <= 0` 对 NaN 恒为 false，会拿 NaN 算出 zoom=NaN → 整图黑。
        -- 必须显式排除非有限数。
        if not l or not l.w or not l.h then return false end
        if l.w ~= l.w or l.h ~= l.h then return false end      -- NaN 防护
        if l.w <= 0 or l.h <= 0 then return false end
        local z = math.min(l.w / Geography.MAP_W, l.h / Geography.MAP_H) * 0.96
        if z ~= z or z <= 0 then return false end              -- 计算 NaN 防护
        mapWidget.camX = Geography.MAP_W * 0.5
        mapWidget.camY = Geography.MAP_H * 0.5
        mapWidget.zoom = z
        mapWidget.targetZoom = z
        if mapWidget._clampCamera then mapWidget:_clampCamera() end
        return true
    end
    local fitted = false
    ScenarioEditor.onUpdate = function()
        if (not fitted) and fitAll() then
            fitted = true
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

    -- 编辑态实时着色（MapWidget 的 overlayColorFn 钩子）：已划归省份按国家色填充，
    -- 无主/沙漠省不填（露出羊皮纸/沙漠底图），玩家一划归立刻看到领土颜色
    mapWidget.overlayColorFn = function(pid)
        local ps = scenario.provinceStates[tostring(pid)]
        if not ps or ps.isWasteland or not ps.ownerId then
            return nil
        end
        local f = scenario.factions[ps.ownerId]
        if not f then return nil end
        return f.color[1], f.color[2], f.color[3]
    end

    -- -------------------------------------------------------------------------
    -- 通用控件
    -- -------------------------------------------------------------------------
    -- 工具条按钮（2026-09-13 改）：原来是半透明奶油色（{255,250,236,120}），
    -- 压在透明/白底上几乎看不见 → 改成**不透明深底 + 米色描边/文字**，
    -- 跟游戏内顶栏同一套视觉；高度 36→42（手机可点）。
    local function paperBtn(text, onClick, o)
        if type(onClick) == "table" and type(o) == "function" then
            onClick, o = o, onClick
        end
        o = o or {}
        return UI.Button {
            text = text,
            width = o.width, height = o.height or 42,
            fontSize = o.fontSize or 14,
            fontFamily = "gufeng", fontWeight = "bold",
            textColor = o.textColor or { 240, 226, 196, 255 },
            backgroundColor = { 38, 32, 26, 248 },
            hoverBackgroundColor = { 62, 52, 40, 252 },
            pressedBackgroundColor = { 28, 23, 18, 252 },
            borderColor = { 152, 118, 72, 220 }, borderWidth = 1,
            borderRadius = 8,
            onClick = onClick,
        }
    end

    local function sectionLabel(text)
        return UI.Label { text = text, fontSize = 14, fontFamily = "gufeng",
                          fontWeight = "bold", fontColor = { 214, 178, 110, 255 },
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
        end, { width = 240, height = 40, fontSize = 13 })

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
        end, { height = 40, fontSize = 13, width = 168 })

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
                    end, { height = 40, fontSize = 13, width = 168 }),
                    paperBtn("生成新世界", function()
                        if not pageRoot then return end
                        WorldGenPanel.show({
                            root = pageRoot,
                            onApply = onWorldGen,
                        })
                    end, { height = 40, fontSize = 13, width = 168 }),
                },
            },
            UI.Panel {
                position = "absolute", right = 8, bottom = 8,
                children = {
                    paperBtn("全 图", function()
                        if not fitAll() then setMsg("布局未就绪,稍后再试") end
                    end, { height = 40, fontSize = 13, width = 88 }),
                },
            },
            UI.Panel {
                position = "absolute", right = 8, top = 8,
                flexDirection = "column", gap = 6,
                children = {
                    paperBtn("保存剧本", function()
                        local ok, reason = SaveManager.saveScenario(scenario)
                        setMsg(ok and "剧本已保存" or ("保存失败:" .. tostring(reason)))
                    end, { height = 40, fontSize = 13, width = 146 }),
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
                    end, { height = 40, fontSize = 13, width = 146 }),
                    paperBtn("以此国开局", function()
                        ScenarioEditor.onUpdate = nil
                        local f = selectedFaction()
                        if f then
                            scenario.playerFactionId = f.id
                            if opts.onStart then opts.onStart(scenario) end
                        else
                            setMsg("请先选中一个国家")
                        end
                    end, { height = 40, fontSize = 13, width = 146,
                           textColor = { 255, 158, 120, 255 } }),
                    paperBtn("返回主菜单", function()
                        ScenarioEditor.onUpdate = nil
                        if opts.onBack then opts.onBack() end
                    end, { height = 40, fontSize = 13, width = 146 }),
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
            text = "编辑器", fontSize = 20, width = 240,
            fontFamily = "gufeng", fontWeight = "bold", fontColor = { 240, 210, 120, 255 },
        }
        msgLabel = UI.Label { text = "空剧本:先「＋新建国家」,再点地图领土划归(全图无主)", fontSize = 11,
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
                    { width = 124, height = 40, fontSize = 13 }),
                paperBtn("－删除选中", function()
                    if selectedId then deleteFaction(selectedId) end
                end, { width = 124, height = 40, fontSize = 13,
                      textColor = { 255, 148, 128, 255 } }),
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

        local mapPanel = UI.Panel { flexGrow = 1, backgroundColor = { 12, 18, 30, 255 },
                                    children = { mapWidget } }
        for _, w in ipairs(buildMapOverlay()) do
            mapPanel:AddChild(w)
        end

        -- 根面板 = 不透明深色底（2026-09-13 修）：原来是透明的（3D 时代防止盖住
        -- UI 之下的 3D 地图层），3D 废弃后透明底在手机上会透出平台白色，
        -- 浅色按钮全糊掉（实测截图 42% 像素 alpha=0）。
        local root = UI.Panel {
            width = "100%", height = "100%",
            backgroundColor = { 16, 13, 10, 255 },
            flexDirection = "row",
            children = { mapPanel, side },
        }
        pageRoot = root
        UI.SetRoot(root)
    end

    opts.rebuild = function()
        assemble()
    end

    assemble()
end

return ScenarioEditor

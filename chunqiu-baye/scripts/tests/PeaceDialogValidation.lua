-- 运行真实 PeaceDialog 构建/打开/点选/刷新方法；仅控件使用无渲染 mock。
local PeaceDialog = require("ui.panels.PeaceDialog")
local War = require("systems.WarSystem")
local Time = require("core.TimeSystem")

local function fixture(enemyCount)
    local gs = { playerFactionId = 1, version = 1, factions = {
        [1] = { id = 1, name = "甲", provinces = { 1 }, capitalId = 1 },
        [2] = { id = 2, name = "乙", provinces = {}, capitalId = 2 },
    }, provinces = { [1] = { id = 1, name = "甲都", ownerId = 1 } }, wars = {} }
    for pid = 2, enemyCount + 1 do
        gs.factions[2].provinces[#gs.factions[2].provinces + 1] = pid
        gs.provinces[pid] = { id = pid, name = "乙省" .. pid, ownerId = 2 }
    end
    gs.wars["1_2"] = { aId = 1, dId = 2, aProvinceIds = { 1 },
        dProvinceIds = gs.factions[2].provinces, aCapitalId = 1, dCapitalId = 2 }
    local stats = { created = 0, writes = 0, highlights = 0, submissions = 0 }
    ---@type table
    local methods = {}
    local function touch() stats.writes = stats.writes + 1 end
    function methods:SetText(value) touch(); self.props.text = value end
    function methods:SetDisabled(value) touch(); self.props.disabled = value end
    function methods:IsDisabled() return self.props.disabled == true end
    function methods:SetOpacity(value) touch(); self.props.opacity = value end
    function methods:Show() touch(); self.props.visible = true end
    function methods:Hide() touch(); self.props.visible = false end
    function methods:IsVisible() return self.props.visible ~= false end
    function methods:SetStyle(style)
        touch()
        for key, value in pairs(style) do self.props[key] = value end
    end
    function methods:ClearChildren() touch(); self.children = {} end
    function methods:AddChild(child) touch(); self.children[#self.children + 1] = child end
    function methods:Click()
        if not self:IsDisabled() and self.props.onClick then self.props.onClick(self) end
    end
    local function widget(props)
        stats.created = stats.created + 1
        local copy = {}
        for key, value in pairs(props or {}) do copy[key] = value end
        return setmetatable({ props = copy, children = copy.children or {} }, {
            __index = function(self, key)
                if methods[key] then return methods[key] end
                return self.props[key]
            end,
            __newindex = function(self, key, value)
                if key == "text" then methods.SetText(self, value)
                else rawset(self, key, value) end
            end,
        })
    end
    local ui = { Panel = widget, Label = widget, Button = widget,
        ScrollView = widget, Divider = widget }
    local callbacks = {
        onPeaceSelectionChanged = function() stats.highlights = stats.highlights + 1 end,
        onSubmitPeace = function() stats.submissions = stats.submissions + 1 end,
    }
    local refs = { gameState = gs, callbacks = callbacks }
    local gameUI = {}
    PeaceDialog.install(gameUI)
    PeaceDialog.create({ UI = ui, GameUI = gameUI, refs = refs, WarSystem = War,
        COLORS = {}, callbacks = callbacks,
        SmallButton = function(text, onClick, opts)
            local props = {}
            for key, value in pairs(opts or {}) do props[key] = value end
            props.text, props.onClick = text, onClick
            return widget(props)
        end,
    })
    local function offer()
        local list = {}
        for _, pid in ipairs(gs.factions[2].provinces) do
            list[#list + 1] = { id = pid, name = gs.provinces[pid].name,
                cost = War.getProvinceCost(gs, pid, 1), occupied = gs.provinces[pid].occupiedBy == 1 }
        end
        return { mode = "propose", proposerId = 1, targetId = 2,
            terms = { provinces = {}, provinceList = list, allOccupied = false } }
    end
    return gs, gameUI, refs, stats, offer
end

local function run()
    local gs, ui, refs, stats, offer = fixture(3)
    ui.showPeaceDialog(gs, offer())
    assert(ui.isPeaceDialogVisible() and not refs.peaceExpanded and not refs.peaceBody:IsVisible(),
        "打开未保留默认收起")
    assert(not refs.peaceSubmitBtn:IsDisabled() and refs.peaceSubmitBtn.text == "仅缔结停战",
        "首次打开零成本白和未初始化")
    ui.togglePeaceProvincePick(4)
    assert(refs.peaceSubmitBtn:IsDisabled(), "零分索取未占省应超预算")
    ui.hidePeaceDialog()
    ui.showPeaceDialog(gs, offer())
    assert(ui.peaceDialogCost() == 0 and not refs.peaceSubmitBtn:IsDisabled(),
        "重开仍继承超预算禁用")
    assert(refs.budgetUsedVal.text == "0.00" and not refs.peaceOverLabel:IsVisible(),
        "重开仍残留超预算摘要")
    ui.setPeaceExpanded(true)
    refs.peaceSubmitBtn:Click()
    assert(stats.submissions == 1, "重开零成本白和无法触发真实提交回调")
    print("[PeaceDialogValidation] PASS 超预算关闭重开恢复白和、默认收起")

    ui.togglePeaceProvincePick(4)
    assert(ui.peaceDialogCost() == 15 and refs.peaceSubmitBtn:IsDisabled())
    gs.provinces[3].occupiedBy = 1 -- 三省国占一非首都，真实 War 分数从0增长到20
    local created, highlights = stats.created, stats.highlights
    refs.peaceRefreshAt = os.clock() - 1 -- 模拟被动刷新间隔已过，不 mock 分数或时间逻辑
    ui.refreshPeaceDialog(gs, true)
    assert(refs.peaceScore == 20 and not refs.peaceSubmitBtn:IsDisabled(),
        "窗口内真实分数增长未恢复提交")
    assert(refs.budgetLeftVal.text == "5.00" and stats.highlights == highlights,
        "分数刷新错误或重复全刷地图高亮")
    refs.peaceSubmitBtn:Click()
    assert(stats.submissions == 2, "分数增长后提交按钮仍无法触发回调")
    gs.provinces[4].occupiedBy = 1
    ui.refreshPeaceDialog(gs)
    local provinceRow = refs.peaceProvList.children[3]
    assert(ui.peaceDialogCost() == 5 and provinceRow.children[3].text == "已占"
        and provinceRow.children[5].text == "5.00分", "省行成本/占领标签未就地同步")
    assert(stats.created == created and stats.highlights == highlights, "刷新重建了控件或全刷高亮")
    local writes = stats.writes
    ui.refreshPeaceDialog(gs)
    refs.peaceRefreshAt = os.clock() - 1
    ui.refreshPeaceDialog(gs, true)
    assert(stats.writes == writes, "数据不变时仍重复写控件")
    print("[PeaceDialogValidation] PASS 真分数增长可提交、省行就地同步与无变化缓存")

    gs, ui, refs, stats, offer = fixture(100)
    ui.showPeaceDialog(gs, offer())
    gs.provinces[3].occupiedBy = 1
    ui.togglePeaceProvincePick(3)
    assert(math.abs(refs.peaceScore - 0.6) < 1e-8
        and math.abs(ui.peaceDialogCost() - 0.3) < 1e-8 and not refs.peaceSubmitBtn:IsDisabled(),
        "小数分数被截断或成本口径不符")
    ui.togglePeaceProvincePick(4) -- 未占省0.9，合计1.2 > 0.6
    assert(refs.peaceSubmitBtn:IsDisabled(), "小数超预算未阻止提交")
    gs.provinces[5].occupiedBy = 1 -- 分数1.2，成本1.2；省4仍未占
    ui.refreshPeaceDialog(gs)
    assert(math.abs(refs.peaceScore - 1.2) < 1e-8 and not refs.peaceSubmitBtn:IsDisabled(),
        "小数等额预算不能提交")
    gs.provinces[3].occupiedBy, gs.provinces[5].occupiedBy = nil, nil
    ui.refreshPeaceDialog(gs)
    assert(refs.peaceScore == 0 and refs.peaceSubmitBtn:IsDisabled(), "失地降分仍允许提交")
    print("[PeaceDialogValidation] PASS 小数预算、等额边界与失地降分")
end

function Start()
    local oldGraphics, oldTime = _G.graphics, Time.getState()
    ---@type any
    local fakeGraphics = { GetWidth = function() return 1280 end, GetDPR = function() return 1 end }
    _G.graphics = fakeGraphics
    local ok, err = pcall(run)
    _G.graphics = oldGraphics
    Time.restore(oldTime)
    if ok then print("[PeaceDialogValidation] ALL PASS")
    else
        print("[PeaceDialogValidation] FAIL " .. tostring(err))
        if log then log:Write(LOG_ERROR, "[PeaceDialogValidation] FAIL " .. tostring(err)) end
    end
    engine:Exit()
end

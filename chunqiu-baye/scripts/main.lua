-- ============================================================================
-- 逐鹿九州 - Main Entry
-- 群雄逐鹿的架空历史策略战争游戏
-- ============================================================================

local UI = require("urhox-libs/UI")

-- Core systems
local GameConfig      = require("config.GameConfig")
local GameState       = require("core.GameState")
local TimeSystem      = require("core.TimeSystem")
local Factions        = require("data.Factions")
local MapPack         = require("data.MapPack")

-- Game logic systems
local EconomySystem   = require("systems.EconomySystem")
local MilitarySystem  = require("systems.MilitarySystem")
local DiplomacySystem = require("systems.DiplomacySystem")
local WarSystem       = require("systems.WarSystem")
local LeaderSystem    = require("systems.LeaderSystem")
local PolicySystem    = require("systems.PolicySystem")

-- AI
local AIManager       = require("ai.AIManager")
local SaveManager     = require("save.SaveManager")

-- UI modules
local MainMenu = require("ui.MainMenu")
local CountrySelect = require("ui.CountrySelect")
local ScenarioEditor = require("ui.ScenarioEditor")
local SaveSlotsPanel = require("ui.SaveSlotsPanel")
local GameUI   = require("ui.GameUI")
local MapRenderer = require("map.MapRenderer")
local Profile     = require("core.Profile")

-- Audio
local MusicManager = require("audio.MusicManager")

-- ============================================================================
-- Global state
-- ============================================================================
---@type Widget
local uiRoot_ = nil
---@type any
local mapWidget_ = nil
---@type any
local gameUIPanel_ = nil
---@type string
local currentPhase_ = "select"  -- "select" | "playing" | "gameover"
---@type integer|nil
local measurePlaysetCountdown_ = nil   -- 离屏测量用（等布局算完再量），nil = 不量
local switchCountdown_ = nil           -- 换视角延迟帧数（nil = 不延迟）
local switchThunk_     = nil           -- 到点了要执行的换视角动作
local measureRectCountdown_ = nil      -- 离屏：SHOT_RECT 排的倒计时（等布局算完再量）
local tapCountdown_ = nil              -- 离屏：SHOT_TAP 注入真实点击的倒计时
local tapQueue_ = nil                  -- 离屏：SHOT_TAP 的点击序列 { {x,y}, ... }

--- 世界指纹：省属 + 存活势力 + 时间 + 全势力钱粮总和。
--- 用途：换视角前后各打一次，**证明"同一局换国家"没有把世界重置**。
---
--- 为什么必须带「钱粮总和」：省属和时间在开局后很久都不变，
--- 光看它们，"世界没变"和"世界被重置回初始态"就是同一个值 —— 证明力是假的。
--- 钱粮是月度结算的产物，最敏感，它没回退才说明世界真的是同一个。
---
--- ⚠️ 必须定义在这里（文件顶部）：`Start()` 和 `SwitchViewFaction` 都要用它，
---    而 `local function` 只对**后面**的代码可见 —— 放后面会被编译成全局引用，
---    运行时直接 nil 崩溃。
---@return string
local function worldFingerprint_()
    local owned, total, gold, food, alive = 0, 0, 0, 0, 0
    for _, p in pairs(GameState.provinces or {}) do
        total = total + 1
        if p.ownerId then owned = owned + 1 end
    end
    for _, f in pairs(GameState.factions) do
        if f.alive then alive = alive + 1 end
        gold = gold + (f.gold or 0)
        food = food + (f.food or 0)
    end
    -- ⚠️ getTime() 返回的是多个数字（year, month, day, hour），不是表；getState() 才返回表
    local ts = TimeSystem.getState and TimeSystem.getState() or {}
    return string.format("省属 %d/%d · 存活势力 %d · 时间 %s年%s月 · 钱粮总和 %d/%d",
        owned, total, alive,
        tostring(ts.year or "?"), tostring(ts.month or "?"),
        math.floor(gold), math.floor(food))
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

function Start()
    Profile.mark("启动 Start()")
    graphics.windowTitle = GameConfig.Title

    -- 桌面端隐藏系统鼠标手掌指针；Web 预览保持默认（隐藏会触发
    -- 沙箱 iframe 的 Pointer Lock 拒绝：WrongDocumentError）
    local PlatformUtils = require("urhox-libs.Platform.PlatformUtils")
    if not PlatformUtils.IsWebPlatform() then
        input.mouseMode = MM_FREE
        input.mouseVisible = false
    end

    -- 入口（离屏测试钩子：SHOT_MODE=游戏内 / SHOT_EDITOR=编辑器 / SHOT_SELECT=选国页）
    local entry = "menu"
    if os.getenv and os.getenv("SHOT_EDITOR") then
        entry = "editor"
    elseif os.getenv and os.getenv("SHOT_SELECT") then
        entry = "select"
    elseif os.getenv and os.getenv("SHOT_MODE") then
        entry = "game"
    elseif os.getenv and os.getenv("SHOT_LOAD") then
        entry = "load"          -- 直接读最近存档进游戏（离屏验证"读档恢复"用）
    end

    -- SHOT_RES=1 → 注册一个演示资源「积分」（每过一天 +1、上限 999）
    --   用来离屏验证资源注册表这条链路：注册 → 每日结算 → 顶栏显示 → 存档/读档。
    --   将来模组就是用同样的方式注册自己的资源（清单 A6「资源注册表」）
    --   放在入口分发**之前**：这样 SHOT_RES 和 SHOT_MODE / SHOT_LOAD 都能叠加用
    if os.getenv and os.getenv("SHOT_RES") then
        require("data.Resources").register{
            id = "jifen", name = "积分", color = { 240, 170, 90 },
            order = 15, show = true, init = 0, cap = 999,
            incomeDay = 1,
            -- incomeMonth：演示"每月结算"这条路（洞 3 要验的就是它 —— 以前挂在经济系统里）
            incomeMonth = 10,
            -- 效果挂钩（修正器管道）：每 100 积分 → 金收入 +5%、征兵额度 +10%
            effects = {
                { key = "goldIncome", per = 100, mul = 0.05 },
                { key = "recruit",    per = 100, mul = 0.10 },
            },
            desc = "演示资源：每过一天 +1；每 100 点：金收入+5%、征兵+10%",
        }
        print("[Main] SHOT_RES：已注册演示资源「积分」（每天+1、每月+10、上限999、每100点金收入+5%/征兵+10%）")
    end

    -- SHOT_EVENTADD=1 → 用新增的 `Events.add` 注册一条"模组式"事件（验证注册口通了）
    --   配合 `SHOT_EVENT=100237_mengzhimeng`：能弹出来就说明"追加"式注册真的生效
    --   （weight=0 → 不参与随机抽取，只靠 SHOT_EVENT 强推，这样截图稳定）
    if os.getenv and os.getenv("SHOT_EVENTADD") then
        local Events = require("data.Events")
        local before = #Events.defs
        local ok, err = Events.add{
            id = "100237_mengzhimeng", title = "弭兵之盟",
            text = "诸侯会于宋，欲息兵戈。是盟也，可使天下稍安乎？",
            weight = 0,
            choices = {
                { text = "歃血为盟（名声 +10）",
                  effects = { { res = "prestige", add = 10 }, { msg = "弭兵之盟成，天下稍安。" } } },
                { text = "拒绝与会（名声 −5）",
                  effects = { { res = "prestige", add = -5 }, { msg = "诸侯失望而归。" } } },
            },
        }
        print(string.format("[Main] SHOT_EVENTADD：Events.add → ok=%s %s｜事件数 %d → %d（追加，不是替换）",
            tostring(ok), tostring(err or ""), before, #Events.defs))

        -- 再试一条"非法"的：没有 choices → 应该被挡下（证明校验有效）
        local ok2, err2 = Events.add{ id = "bad_no_choices", title = "缺选项的事件" }
        print(string.format("[Main] SHOT_EVENTADD：故意缺 choices → ok=%s %s",
            tostring(ok2), tostring(err2)))
    end

    -- SHOT_SLOT=1 → 往顶栏空位挂一个面板入口（验证"洞 5：模组能把面板挂上界面"）
    --   必须**在界面建好之前**注册 —— 空位是"建界面时读一次"的
    if os.getenv and os.getenv("SHOT_SLOT") then
        local ok, err = require("ui.UISlots").add("topbar.extra", {
            id = "realm_overview", label = "国势", panel = "realm_overview", order = 10,
        })
        print("[Main] SHOT_SLOT：往 topbar.extra 挂了「国势」入口 → "
            .. tostring(ok) .. " " .. tostring(err or ""))
    end

    -- SHOT_MONTHDBG=1 → 每月打印一次玩家势力的注册型资源
    --   一次验两条链路：① `month` 钩子真的会 fire ② "每月 +N"的结算真的跑了（洞 3）
    if os.getenv and os.getenv("SHOT_MONTHDBG") then
        require("systems.Hooks").on("month", function(p)
            local gs = p.gameState
            local f = gs and gs.getPlayerFaction and gs:getPlayerFaction()
            if not f then return end
            local Resources = require("data.Resources")
            local parts = {}
            for _, d in ipairs(Resources.list()) do
                if not Resources.isBinding(d) and d.computed == nil then
                    parts[#parts + 1] = string.format("%s=%d", tostring(d.name), math.floor(Resources.get(f, d.id) or 0))
                end
            end
            print(string.format("[MonthDBG] %s | %s", TimeSystem.formatDate(), table.concat(parts, " ")))
        end)
        print("[Main] SHOT_MONTHDBG：已挂「每月打印资源」的钩子")
    end

    -- SHOT_HOOKDBG=1 → 给几个脚本钩子挂上打印（离屏验证"时机真的会触发"）
    if os.getenv and os.getenv("SHOT_HOOKDBG") then
        local Hooks = require("systems.Hooks")
        Hooks.on("war_declared", function(p)
            print(string.format("[HookDBG] war_declared：%s → %s",
                tostring(p.attackerId), tostring(p.defenderId)))
        end)
        Hooks.on("battle_end", function(p)
            print(string.format("[HookDBG] battle_end：省%s 胜%s 负%s 全歼=%s 溃退=%s",
                tostring(p.provinceId), tostring(p.winnerId), tostring(p.loserId),
                tostring(p.wiped), tostring(p.routed)))
        end)
        Hooks.on("province_conquered", function(p)
            print(string.format("[HookDBG] province_conquered：省%s 归%s（原 %s）",
                tostring(p.provinceId), tostring(p.factionId), tostring(p.fromFactionId)))
        end)
        Hooks.on("month", function(p)
            print(string.format("[HookDBG] month：%s年%s月",
                tostring(p.time and p.time.year), tostring(p.time and p.time.month)))
        end)
        -- 声明式 UI 的"模组兜底动作"：没注册过的 action 会落到这里
        Hooks.on("ui_action", function(p)
            print(string.format("[HookDBG] ui_action：action=%s arg=%s（来自面板 %s）",
                tostring(p.action), tostring(p.arg), tostring(p.panelId)))
        end)
        print("[Main] SHOT_HOOKDBG：已挂 5 个演示钩子（war_declared/battle_end/province_conquered/month/ui_action）")
    end

    -- 2026-09-13 用户要求：**删掉整块载入画面**（平台自带进度条，不再自己画一个）。
    -- 代价：启动/进游戏时会同步干完所有初始化（画面停住几秒，无进度提示）。

    -- 深靛 + 金 配色主题（2026-09-13 UI 改版）
    --   之前没设主题 → Theme.Color 全部落回灰色 (128,128,128)：内置控件（Dropdown /
    --   TextField / Toggle / Slider）的文字与描边都是灰的，在深色底上发闷。
    --   ⚠️ 这里**只给 colors，不给 components / componentDefaults**：
    --     内置控件拿到我们的色，而按钮不会被主题套上阴影/高度（工程里按钮都是显式配色），
    --     避免一改主题把全工程按钮外观一起带偏。
    local themeColors = {
        primary         = { 226, 192, 120, 255 },   -- 金（选中/主操作）
        primaryHover    = { 240, 210, 150, 255 },
        primaryPressed  = { 198, 164,  96, 255 },
        primaryDeep     = { 150, 120,  70, 255 },
        primarySoft     = { 176, 150, 100, 255 },
        primaryShadow   = { 120,  96,  54, 255 },
        secondary       = {  69,  80, 104, 255 },
        secondaryHover  = {  86,  99, 126, 255 },
        secondaryPressed= {  54,  63,  82, 255 },
        background      = {  18,  22,  34, 255 },
        surface         = {  30,  36,  50, 255 },
        surfaceAlt      = {  40,  48,  66, 255 },
        surfaceRaised   = {  52,  60,  78, 255 },
        text            = { 232, 226, 210, 255 },   -- 骨白正文
        textSecondary   = { 190, 186, 172, 255 },
        textMuted       = { 152, 152, 156, 255 },
        textPlaceholder = { 150, 156, 170, 255 },
        textInverse     = {  34,  26,  14, 255 },   -- 金底上的墨字
        border          = { 120, 100,  66, 255 },   -- 金棕描边
        borderStrong    = { 150, 120,  70, 255 },
        borderFocus     = { 226, 192, 120, 255 },
        divider         = {  92,  82,  62, 220 },
        disabled        = {  46,  52,  66, 255 },
        disabledBorder  = {  96,  90,  76, 200 },
        disabledText    = { 138, 138, 142, 255 },
        success         = {  96, 178, 118, 255 },
        successHover    = { 118, 200, 140, 255 },
        successPressed  = {  74, 148,  96, 255 },
        warning         = { 232, 180,  92, 255 },
        warningPressed  = { 190, 140,  60, 255 },
        error           = { 210,  86,  70, 255 },
        errorHover      = { 230, 108,  90, 255 },
        errorPressed    = { 170,  62,  50, 255 },
        danger          = { 210,  86,  70, 255 },
        dangerHover     = { 230, 108,  90, 255 },
        dangerPressed   = { 170,  62,  50, 255 },
        overlay         = {   0,   0,   0, 170 },
        surfaceTooltip  = {  34,  40,  56, 255 },
        borderTooltip   = { 120, 100,  66, 255 },
    }

    UI.Init({
        fonts = {
            { family = "sans", weights = { normal = "Fonts/MiSans-Regular.ttf" } },
            { family = "gufeng", weights = {
                normal = "Fonts/LXGWWenKai-Regular.ttf",
                bold = "Fonts/LXGWWenKai-Regular.ttf",
            } },
        },
        theme = { colors = themeColors },
        scale = UI.Scale.DEFAULT,
    })
    Profile.mark("UI.Init（字体）")

    MusicManager.init()
    Profile.mark("MusicManager.init")

    -- SHOT_MAPPACK=<包id> → 强制激活某个地图包（离屏验证「旧大陆 / 新世界」两张图）
    --   ⚠️ **必须放在入口分发之前**：地图包决定 MAP_W/MAP_H、省份数据、底图路径，
    --      而这些在 GameState.init / Provinces 索引建立时就定死了 —— 晚一步就来不及。
    if os.getenv and os.getenv("SHOT_MAPPACK") then
        local id = os.getenv("SHOT_MAPPACK")
        -- ⚠️ 用 switchTo（不是 setActive）：省份数据在 require Provinces 时就按默认包装好了
        --    （先于这里），只 setActive 不 reload 的话，验证跑的是"旧包省份数据 + 新包底图"
        --    的混合态（2026-09-15 修，原因见 MAP_HANDOFF.md）
        local ok = MapPack.switchTo(id)
        print(string.format("[Main] SHOT_MAPPACK=%s → %s（当前 %dx%d）",
            id, tostring(ok), MapPack.MAP_W or -1, MapPack.MAP_H or -1))
    end

    if entry == "editor" then
        ShowScenarioEditor()
    elseif entry == "select" then
        ShowFactionSelect()
    elseif entry == "load" then
        ContinueGame()
    elseif entry == "game" then
        StartGame(2)
    else
        ShowMainMenu()
    end
    Profile.mark("首屏构建(" .. tostring(currentPhase_) .. ")")
    print("[Main] 首屏就绪")

    -- SHOT_MONTHDRIVE=<N> → 直接连推 N 个游戏月（离屏验证"按月结算"用）
    --   为什么不靠真实时间：默认速度下过一个游戏月要很久，离屏跑到一半进程就退了
    if os.getenv and os.getenv("SHOT_MONTHDRIVE") and currentPhase_ == "playing" then
        local n = tonumber(os.getenv("SHOT_MONTHDRIVE")) or 1
        local Resources = require("data.Resources")
        local function dumpRes(tag)
            local f = GameState.getPlayerFaction()
            if not f then return end
            local parts = {}
            for _, d in ipairs(Resources.list()) do
                if not Resources.isBinding(d) and d.computed == nil then
                    parts[#parts + 1] = string.format("%s=%d", tostring(d.name),
                        math.floor(Resources.get(f, d.id) or 0))
                end
            end
            print(string.format("[MonthDrive] %s | 金=%d 粟=%d | %s", tag,
                math.floor(f.gold or 0), math.floor(f.food or 0), table.concat(parts, " ")))
        end
        dumpRes("推之前")
        for i = 1, n do
            OnNewMonth(nil)
            dumpRes("第" .. i .. "月")
        end
    end

    -- SHOT_SLOT_CLICK=<控件id> → 点一下顶栏空位里的按钮（验证"洞 5"整条链路：
    --   模组注册空位条目 → 顶栏出现按钮 → 点它 → 声明式面板真的打开）
    if os.getenv and os.getenv("SHOT_SLOT_CLICK") and UI.FindById and currentPhase_ == "playing" then
        local w = UI.FindById(os.getenv("SHOT_SLOT_CLICK"))
        if w and w.OnClick then
            w:OnClick(nil)
            print("[Main] SHOT_SLOT_CLICK=" .. os.getenv("SHOT_SLOT_CLICK"))
        else
            print("[Main] ⚠️ SHOT_SLOT_CLICK：找不到控件 " .. tostring(os.getenv("SHOT_SLOT_CLICK")))
        end
    end

    -- SHOT_SWITCH=next|spectate|<势力id> → 切换视角（验证"同一局换国家 / 看海"）
    --   next     = 随便挑一个**别的**活着的势力（不用写死 id）
    --   spectate = 进看海（playerFactionId = nil）
    --   顺带打印"换之前/换之后"的世界指纹，**证明世界没被重置**
    --   SHOT_SWITCH_DELAY=<帧数>：把切换推迟到第 N 帧再执行。
    --     为什么需要：本块在"首屏就绪"就跑，那会儿**第一帧还没渲染**，
    --     面板都还是空的 —— 于是"面板停在旧视角"这类 bug 根本照不出来。
    --     先跑 N 帧让旧视角的界面画出来，再切，才验得到「换完界面跟着换」。
    if os.getenv and os.getenv("SHOT_SWITCH") and currentPhase_ == "playing" then
        local arg = os.getenv("SHOT_SWITCH")

        local function doSwitch()
            -- 世界指纹用模块级的 worldFingerprint_()（SwitchViewFaction 里也会打一对）
            local beforeFp  = worldFingerprint_()
            local beforeId  = GameState.playerFactionId
            local beforeName = (function()
                local f = beforeId and GameState.factions[beforeId]
                return f and tostring(f.name) or "（无 · 观战）"
            end)()

            local pid
            if arg == "spectate" then
                pid = nil
            elseif arg == "next" then
                for id, f in pairs(GameState.factions) do
                    if f.alive and id ~= GameState.playerFactionId then pid = id break end
                end
            else
                pid = tonumber(arg)
            end

            local ok, reason = SwitchViewFaction(pid)
            local afterF = GameState.playerFactionId and GameState.factions[GameState.playerFactionId]
            print(string.format("[Shot] SHOT_SWITCH=%s → ok=%s %s", arg, tostring(ok), tostring(reason or "")))
            print(string.format("[Shot]   视角：%s(id=%s) → %s(id=%s)",
                beforeName, tostring(beforeId),
                afterF and tostring(afterF.name) or "（无 · 观战）", tostring(pid)))
            print("[Shot]   世界换之前：" .. beforeFp)
            print("[Shot]   世界换之后：" .. worldFingerprint_())
        end

        local delay = tonumber(os.getenv("SHOT_SWITCH_DELAY") or "") or 0
        if delay > 0 then
            switchCountdown_ = delay
            switchThunk_     = doSwitch
            print(string.format("[Shot] SHOT_SWITCH=%s 推迟到第 %d 帧执行", arg, delay))
        else
            doSwitch()
        end
    end

    -- SHOT_RECT=<控件id> → 上膛：等 10 帧后打印该控件的绝对矩形（在 HandleUpdate 里执行）
    if os.getenv and os.getenv("SHOT_RECT") then
        measureRectCountdown_ = 10
        print("[Rect] SHOT_RECT=" .. os.getenv("SHOT_RECT") .. " 已上膛（10 帧后量）")
    end

    -- SHOT_TAP="x,y[;x2,y2;...]" → 注入**真实鼠标点击**（物理像素坐标；UI 坐标 = 物理 × 窗口UI尺寸/窗口物理尺寸）
    --   走 InputAdapter → hit test → Widget:OnPointerDown/Up → MapWidget → getProvinceAtPoint，
    --   和真机点击是同一条链路（补 MAP_HANDOFF 里"没有屏幕坐标注入式点击实测"的缺口）。
    --   支持一次上膛**多次点击**（首次在第 60 帧、其后每 20 帧一次）——
    --   "选国家 → 再点内部选省"这类两段式交互必须连点两次才验得到。
    --   语法：`x,y` = 单击；`x1,y1>x2,y2` = **拖动**（按下 → 分步移动 → 抬起）
    if os.getenv and os.getenv("SHOT_TAP") then
        local queue = {}
        for pair in os.getenv("SHOT_TAP"):gmatch("[^;]+") do
            local x1, y1, x2, y2 = pair:match(
                "^%s*(%-?%d+)%s*,%s*(%-?%d+)%s*>%s*(%-?%d+)%s*,%s*(%-?%d+)%s*$")
            if x1 then
                queue[#queue + 1] = { tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2) }
            else
                local xs, ys = pair:match("^%s*(%-?%d+)%s*,%s*(%-?%d+)%s*$")
                if xs and ys then queue[#queue + 1] = { tonumber(xs), tonumber(ys) } end
            end
        end
        if #queue > 0 then
            tapQueue_ = queue
            tapCountdown_ = 60
            local desc = {}
            for i = 1, #queue do desc[i] = string.format("(%d,%d)", queue[i][1], queue[i][2]) end
            print(string.format("[Tap] SHOT_TAP 上膛 %d 次点击：%s（首次 60 帧后，其后每 20 帧一次）",
                #queue, table.concat(desc, " ")))
        else
            print("[Tap] ⚠️ SHOT_TAP 格式应为 \"x,y[;x2,y2;...]\"，收到：" .. tostring(os.getenv("SHOT_TAP")))
        end
    end

    -- SHOT_FACTIONDBG=<势力id> → 打印该势力实际占的省（id + 名字 + 中心坐标）
    --   用途：验"换图之后势力落在哪" —— 省份 id 是按包各自编号的，
    --   同一个 id 在两张图里可能是相隔几千公里的两块地（eu4 的 1249=雒阳，world 的 1249=法国 Foix）。
    if os.getenv and os.getenv("SHOT_FACTIONDBG") then
        local fid = tonumber(os.getenv("SHOT_FACTIONDBG"))
        local Provinces = require("data.Provinces")
        local f = fid and GameState.factions[fid]
        if f and f.provinces then
            local parts = {}
            for i, pid in ipairs(f.provinces) do
                local p = Provinces.byId[pid]
                parts[#parts + 1] = string.format("%d:%s@%d,%d", pid,
                    tostring(p and p.name or "?"),
                    p and math.floor(p.center[1]) or -1,
                    p and math.floor(p.center[2]) or -1)
                if i >= 8 then parts[#parts + 1] = "…" break end
            end
            print(string.format("[Main] SHOT_FACTIONDBG 势力%d「%s」占 %d 省：%s（当前包 %s %dx%d）",
                fid, tostring(f.name), #f.provinces, table.concat(parts, " "),
                tostring(MapPack.activeId), MapPack.MAP_W or -1, MapPack.MAP_H or -1))
        else
            print("[Main] SHOT_FACTIONDBG：找不到势力 " .. tostring(fid))
        end
    end

    -- SHOT_SWITCHPAGE=1 → 打开「切换角色」页（走设置面板那条路，但不用手点）
    --   配 SHOT_CLICK=csRandomBtn|csSpectateBtn|csStartBtn 验证页内按钮真的有效果
    --   放在 SHOT_SWITCH 之后：它会把 phase 改成 "select"，后面那些守 "playing" 的钩子就不跑了
    if os.getenv and os.getenv("SHOT_SWITCHPAGE") and currentPhase_ == "playing" then
        print("[Shot] SHOT_SWITCHPAGE=1 → 打开切换角色页")
        ShowSwitchFaction()
    end

    -- SHOT_MODSLOT=write|check → 验证"模组格子"能活过存档（洞 2）
    --   write：往 f.mods / GameState.mods 塞东西 → 存到 1 号位 → 从盘上读回来看
    --   check：打印**当前**势力/全局格子里有什么（配合 SHOT_LOAD 用，验"读档真的还原了"）
    local modSlotCmd = os.getenv and os.getenv("SHOT_MODSLOT")
    if modSlotCmd and currentPhase_ == "playing" then
        local pf = GameState.getPlayerFaction()
        if modSlotCmd == "write" and pf then
            pf.mods = pf.mods or {}
            pf.mods["999999"] = { talents = { "张三" }, counter = 42 }
            GameState.mods = GameState.mods or {}
            GameState.mods["999999"] = { routes = { "临淄-邯郸" } }
            print("[ModSlot] 写入：势力格 counter=42、全局格 routes=1 条")
            local SM, TS = require("save.SaveManager"), require("core.TimeSystem")
            local okS, errS = SM.saveToSlot(1, GameState, TS.getState())
            print("[ModSlot] 存档 → " .. tostring(okS) .. " " .. tostring(errS or ""))
            local back = SM.loadSlot(1)
            local bf = back and back.factions and back.factions[tostring(pf.id)]
            print(string.format("[ModSlot] 盘上读回：势力格=%s 全局格=%s",
                tostring(bf and bf.mods and bf.mods["999999"] and bf.mods["999999"].counter),
                tostring(back and back.modState and back.modState["999999"]
                    and table.concat(back.modState["999999"].routes or {}, ","))))
        elseif pf then
            -- 老存档兼容：字段被剥掉后，这里应该看到**空表**（不是 nil，模组要能直接往上写）
            print(string.format("[ModSlot] 当前：势力格=%s（类型 %s）全局格=%s（类型 %s）",
                tostring(pf.mods and pf.mods["999999"] and pf.mods["999999"].counter), type(pf.mods),
                tostring(GameState.mods and GameState.mods["999999"]
                    and table.concat(GameState.mods["999999"].routes or {}, ",")), type(GameState.mods)))
        end
    end

    -- 离屏测试钩子：SHOT_MODS=1 → 模组面板；SHOT_NEWGAME=1 → 开始新游戏弹窗
    if os.getenv and os.getenv("SHOT_MODS") then
        if UI.FindById then
            local ov = UI.FindById("modsOverlay")
            if ov then
                ov:Show()
                print("[Main] SHOT_MODS：已打开模组面板")
                -- SHOT_MODTAG=官方 → 模拟点了这个类型标签（验证"点了会不会亮"）
                local tag = os.getenv("SHOT_MODTAG")
                if tag and ov.modsSetTag_ then
                    ov.modsSetTag_(tag)
                    print("[Main] SHOT_MODTAG=" .. tag)
                end
            end
        end
    end
    if os.getenv and os.getenv("SHOT_SAVEPAGE") then
        -- 打开存档页（先造几条假存档，方便看排版）
        local SM = require("save.SaveManager")
        SM.saveToSlot(1, GameState, TimeSystem.getState())
        local ok2, RSlots = pcall(require, "ui.SaveSlotsPanel")
        if ok2 and RSlots and RSlots.show then
            RSlots.show({ mode = "load", root = UI.GetRoot(),
                onSaveToSlot = function() return true end,
                onLoad = function() return true end,
            })
            print("[Main] SHOT_SAVEPAGE：已打开存档页")
        end
    end
    -- SHOT_EVENT=<事件id>[,<id2>,...] → 立刻把事件塞进待处理队列（逗号分隔可多个，2026-09-16）
    -- SHOT_EVENT_PICK=<选项号> → 再自动选队首事件的第 n 个选项（验证效果真的落地）
    -- SHOT_DEMO6=1 → 演示场景：3 个待处理事件 + 3 条通知（看"多个怎么摆"）
    local shotEvent = os.getenv and os.getenv("SHOT_EVENT")
    if shotEvent then
        local EventSystem = require("systems.EventSystem")
        local Resources = require("data.Resources")
        local pf = GameState.playerFactionId
        local lastId = nil
        for id in string.gmatch(shotEvent, "[^,]+") do
            if EventSystem.forcePending(id, pf, GameState.factions[pf]) then
                print("[Main] SHOT_EVENT：" .. id .. " 已入队")
                lastId = id
            else
                print("[Main] ⚠️ SHOT_EVENT：找不到事件 " .. tostring(id))
            end
        end
        local pick = tonumber(os.getenv("SHOT_EVENT_PICK") or "")
        if pick and lastId then
            local f = GameState.factions[pf]
            local before = f and Resources.get(f, "food") or 0
            EventSystem.choose(GameState, pick)
            local after = f and Resources.get(f, "food") or 0
            print(string.format("[Main] SHOT_EVENT_PICK=%d：效果已应用（粮草 %s → %s）",
                pick, tostring(before), tostring(after)))
        end
    end

    -- SHOT_DEMO6=1 → 演示：3 个待处理事件 + 3 条通知（2026-09-16 用户要看"多个怎么摆"）
    if os.getenv and os.getenv("SHOT_DEMO6") == "1" then
        local EventSystem = require("systems.EventSystem")
        local pf = GameState.playerFactionId
        EventSystem.forcePending("harvest_good", pf)
        EventSystem.forcePending("harvest_bad", pf)
        EventSystem.forcePending("envoy_gift", pf)
        GameState.addMessage("齐向鲁宣战！两国关系降至 -40", "war", true)
        GameState.addMessage("秦吞并了巴国", "war", true)
        GameState.addMessage("吴与越签订和约，罢兵停战", "diplomacy", true)
        print("[Main] SHOT_DEMO6：3 个待处理事件 + 3 条通知 已造")
    end

    -- SHOT_WAR=1 → 造一场战争（看右下战争列表的"双旗 + 战争分"）
    if os.getenv and os.getenv("SHOT_WAR") == "1" then
        local WarSystem = require("systems.WarSystem")
        local pf = GameState.playerFactionId
        -- 找两个和玩家接壤的邻居当对手（验证"多场战争左右并排"）
        ---@type number[]
        local enemyIds = {}
        local myProvs = GameState.factions[pf] and GameState.factions[pf].provinces or {}
        for _, pid2 in ipairs(myProvs) do
            local p = GameState.provinces[pid2]
            if p and p.neighbors then
                for _, nb in ipairs(p.neighbors) do
                    local np = GameState.provinces[nb]
                    if np and np.owner and np.owner ~= pf then
                        local dup = false
                        for _, e in ipairs(enemyIds) do if e == np.owner then dup = true end end
                        if not dup then enemyIds[#enemyIds + 1] = np.owner end
                    end
                    if #enemyIds >= 2 then break end
                end
            end
            if #enemyIds >= 2 then break end
        end
        if #enemyIds == 0 then enemyIds = { pf == 1 and 2 or 1 } end
        -- 不够两场就再补一个别的势力（离屏验证"多场并排"用）
        if #enemyIds < 2 then
            for fid in pairs(GameState.factions) do
                local dup = false
                for _, e in ipairs(enemyIds) do if e == fid then dup = true end end
                if not dup and fid ~= pf then
                    enemyIds[#enemyIds + 1] = fid
                    break
                end
            end
        end
        for _, eid in ipairs(enemyIds) do
            WarSystem.startWar(GameState, pf, eid)
        end
        if GameUI.forceRefreshWarList then GameUI.forceRefreshWarList(GameState) end
        -- SHOT_PEACE=1 → 顺便打开和谈面板（离屏验证版式）
        if os.getenv("SHOT_PEACE") == "1" then
            local PeacePanel = require("ui.PeacePanel")
            PeacePanel.Open(GameState, enemyIds[1], GameUI.refs and GameUI.refs.rootPanel, nil)
            print("[Main] SHOT_PEACE：已打开和谈面板 vs " .. tostring(enemyIds[1]))
        end
        print(string.format("[Main] SHOT_WAR：已造 %d 场战争 玩家(%s) vs %s",
            #enemyIds, tostring(pf), table.concat(enemyIds, ",")))
    end

    -- SHOT_MODDBG=1 → 打印修正器管道的拆解（基础/加法/百分比/连乘/取整），
    --   用来核对"资源效果真的进了公式"以及"老加成数值没变"
    if os.getenv and os.getenv("SHOT_MODDBG") then
        local Modifiers = require("systems.Modifiers")
        local Resources = require("data.Resources")
        local pf = GameState.getPlayerFaction and GameState.getPlayerFaction()
        if pf then
            local ctx = { gameState = GameState, faction = pf }
            -- 洞 4：**直接照公共接口清单遍历** —— 清单有 8 个口就打印 8 个，
            --   以后加口自动跟上，不用改这段
            local keys = {}
            for k in pairs(Modifiers.KEYS) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, key in ipairs(keys) do
                local b = Modifiers.breakdown(100, "faction", key, ctx)
                print(string.format(
                    "[ModDBG] %-14s 基础100 → 加法%+.2f 百分比%+.3f 连乘×%.3f = %.3f",
                    key, b.flat, b.mul, b.scale, b.value))
            end
            print(string.format("[ModDBG] 玩家势力=%s 积分=%s",
                tostring(pf.name), tostring(Resources.get(pf, "jifen"))))
        end
    end

    -- SHOT_MODRULE=1 → 证明"模组挂上去真的生效"（洞 4 的验收）
    --   ① 往 militaryPower 挂 +50%（模组式的外部规则）→ 看连乘是不是变大了
    --   ② 往一个**不存在**的 key 挂 → 看有没有当场警告（公共接口自检）
    if os.getenv and os.getenv("SHOT_MODRULE") and currentPhase_ == "playing" then
        local Modifiers = require("systems.Modifiers")
        local pf = GameState.getPlayerFaction()
        if pf then
            local ctx = { gameState = GameState, faction = pf }
            print(string.format("[ModRule] 挂之前 militaryPower 连乘 = ×%.4f",
                Modifiers.breakdown(1.0, "faction", "militaryPower", ctx).scale))
            Modifiers.rule{
                scope = "faction", key = "militaryPower", op = "scale",
                value = 1.5, source = "test:外挂战力+50%",
            }
            print(string.format("[ModRule] 挂之后 militaryPower 连乘 = ×%.4f（应 ×1.5）",
                Modifiers.breakdown(1.0, "faction", "militaryPower", ctx).scale))
            print("[ModRule] 下面这一条会挂到不存在的 key 上（应该出现警告）：")
            Modifiers.rule{
                scope = "faction", key = "魔法值", op = "flat",
                value = 99, source = "test:没人听的频道",
            }
        end
    end
    -- SHOT_CULTURE=1 → 把玩家势力一半省份改成异文化（荆蛮），验证"文化不满"进了修正器管道
    if os.getenv and os.getenv("SHOT_CULTURE") then
        local CultureSystem = require("systems.CultureSystem")
        local Modifiers = require("systems.Modifiers")
        local Resources2 = require("data.Resources")
        local pf = GameState.playerFactionId
        local f = pf and GameState.factions[pf]
        if f then
            local n = 0
            for _, pid in ipairs(f.provinces or {}) do
                n = n + 1
                -- 跳过首都：势力的"本文化"取自首都省，别把它也改了（否则看不出来是"异文化"惩罚）
                if n % 2 == 0 and pid ~= f.capitalId then
                    local prov = GameState.provinces[pid]
                    if prov then prov.culture = "荆蛮" end
                end
            end
            local s = CultureSystem.summary(GameState, f)
            local ctx = { gameState = GameState, faction = f }
            local delta = Modifiers.applyFloat(0, "faction", "stabilityDelta", ctx)
            print(string.format(
                "[CulDBG] 本文化=%s 省份=%d 异文化=%d 不满占比=%.2f → 稳定度月变化=%+.1f（粮草=%s）",
                s.ownerCulture, s.total, s.foreign, s.share, delta,
                tostring(Resources2.get(f, "food"))))
        end
    end

    -- SHOT_UIPANEL=<面板id> → 打开一块声明式面板（离屏验证 UIDesc/UIBuilder/UIPanelHost）
    -- SHOT_UIACTION=<动作名>[,参数] → 顺便派发一个动作（验证动作派发链）
    local shotPanel = os.getenv and os.getenv("SHOT_UIPANEL")
    if shotPanel then
        local UIPanelHost = require("ui.UIPanelHost")
        if UIPanelHost.open(shotPanel) then
            print("[Main] SHOT_UIPANEL：" .. shotPanel .. " 已打开")
        end
        local act = os.getenv("SHOT_UIACTION")
        if act then
            local name, arg = act:match("^([^,]+),?(.*)$")
            UIPanelHost.dispatch(name, (arg ~= "" and arg or nil), nil)
            print("[Main] SHOT_UIACTION：" .. tostring(act) .. " 已派发")
        end
    end
    if os.getenv and os.getenv("SHOT_PLAYSET") then
        if UI.FindById then
            local ov = UI.FindById("playsetOverlay")
            if ov then
                ov:Show()
                print("[Main] SHOT_PLAYSET：已打开游玩集面板")
                -- SHOT_PLAYSET_SET=<控件id>=<文字> → 给输入框填字（模拟玩家打字）
                local setSpec = os.getenv("SHOT_PLAYSET_SET")
                if setSpec then
                    local sid, sval = setSpec:match("^([^=]+)=(.*)$")
                    local w = sid and ov:FindById(sid)
                    if w and w.SetValue then
                        w:SetValue(sval)
                        print("[Main] SHOT_PLAYSET_SET：" .. sid .. " = " .. tostring(sval))
                    else
                        print("[Main] ⚠️ SHOT_PLAYSET_SET：找不到输入框 " .. tostring(sid))
                    end
                end
                -- SHOT_PLAYSET_MEASURE=1 → 打印底部那一排的真实宽度（确认没挤爆，别靠眼估）
                --   ⚠️ 不能在这儿直接量：这时还没跑过布局（w 会是 nan）
                --   → 挂个倒计时，等几帧、布局算完了再量
                if os.getenv("SHOT_PLAYSET_MEASURE") then
                    measurePlaysetCountdown_ = 8
                    print("[Measure] 已排程：8 帧后量按钮行")
                end
                -- SHOT_PLAYSET_CLICK=<控件id>[,<控件id>...] → 依次模拟点它们
                --   （截图点不了鼠标；走 Button:OnClick，所以"禁用态"也会被如实拦住）
                local clickId = os.getenv("SHOT_PLAYSET_CLICK")
                if clickId then
                    for oneId in clickId:gmatch("[^,]+") do
                        local w = ov:FindById(oneId)
                        if w and w.OnClick then
                            w:OnClick(nil)
                            print("[Main] SHOT_PLAYSET_CLICK=" .. oneId)
                        else
                            print("[Main] ⚠️ SHOT_PLAYSET_CLICK：找不到控件 " .. tostring(oneId))
                        end
                    end
                end
            end
        end
    end
    -- SHOT_PICKER=1 → 打开「选一个包导入」弹窗（离屏截图用）
    if os.getenv and os.getenv("SHOT_PICKER") then
        if UI.FindById then
            local ov = UI.FindById("packPickerOverlay")
            if ov then
                ov:Show()
                print("[Main] SHOT_PICKER：已打开导入弹窗")
                local clickId = os.getenv("SHOT_PICKER_CLICK")
                if clickId then
                    local w = ov:FindById(clickId)
                    if w and w.OnClick then
                        w:OnClick(nil)
                        print("[Main] SHOT_PICKER_CLICK=" .. clickId)
                    else
                        print("[Main] ⚠️ SHOT_PICKER_CLICK：找不到控件 " .. tostring(clickId))
                    end
                end
            end
        end
    end

    -- SHOT_LOADCONFIRM=1 → 弹出「读档前确认」窗（离屏截图用）
    --   有真差异就用真的；没有就造一个假的 —— 这样截图一定能看到三个按钮和分组列表
    if os.getenv and os.getenv("SHOT_LOADCONFIRM") and currentPhase_ == "menu" then
        local data = SaveManager.loadSlot(1)
        if data then
            local diff = SaveManager.diffMods(data)
            if not diff then
                diff = {
                    savePlayset = "标准（旧）", curPlayset = "标准",
                    playsetChanged = true, savePlaysetExists = true,
                    missing = { { id = "100237", name = "诸子学派" } },
                    extra   = { { id = "100300", name = "新军制" } },
                    versionChanged = { { id = "100088", name = "通用图标包", saveV = "1.2", curV = "2.0" } },
                }
                print("[Shot] SHOT_LOADCONFIRM：存档没差异 → 用造的假数据截图")
            end
            MainMenu.confirmLoadMods(diff, data, function()
                print("[Shot] SHOT_LOADCONFIRM：玩家选了「进入」（截图模式不真的进）")
            end)
            print("[Shot] SHOT_LOADCONFIRM：已弹出读档确认")

            -- SHOT_LOADCONFIRM_CLICK=<控件id> → 再点一下某个按钮（验证三个按钮真的接上了）
            local cid = os.getenv("SHOT_LOADCONFIRM_CLICK")
            if cid then
                local w = UI.FindById and UI.FindById(cid)
                if w and w.OnClick then
                    w:OnClick(nil)
                    print("[Shot] 点了 " .. cid)
                else
                    print("[Shot] ⚠️ 找不到控件 " .. tostring(cid))
                end
            end
        else
            print("[Shot] ⚠️ SHOT_LOADCONFIRM：1 号位没有存档")
        end
    end

    -- SHOT_PACK=<动作> → 离屏验证「模组包」的打包/解包（这块是二进制格式，先单独验，别混进 UI 调）
    --   <游玩集名>        导出这一整套（连模组一起打）
    --   exportmod:<模组id> 导出单个模组
    --   import:<包路径>    导入一个包
    --   list              列出 exports/ 里有什么
    local packCmd = os.getenv and os.getenv("SHOT_PACK")
    if packCmd then
        local ModPack = require("mods.ModPack")
        if packCmd == "list" then
            local packs = ModPack.listPacks()
            print(string.format("[Pack] exports/ 里有 %d 个包", #packs))
            for _, p in ipairs(packs) do
                print(string.format("[Pack]   %s → kind=%s name=%s files=%s err=%s", p.file,
                    tostring(p.manifest and p.manifest.kind),
                    tostring(p.manifest and p.manifest.name),
                    tostring(p.manifest and p.manifest.files), tostring(p.err)))
            end
        elseif packCmd:sub(1, 10) == "exportmod:" then
            local ok, msg = ModPack.exportMod(packCmd:sub(11))
            print(string.format("[Pack] exportMod → ok=%s %s", tostring(ok), tostring(msg)))
        elseif packCmd:sub(1, 7) == "import:" then
            local ok, msg = ModPack.importPack(packCmd:sub(8))
            print(string.format("[Pack] import → ok=%s %s", tostring(ok), tostring(msg)))
        else
            local ok, msg = ModPack.exportPlayset(packCmd)
            print(string.format("[Pack] exportPlayset(%s) → ok=%s %s", packCmd, tostring(ok), tostring(msg)))
        end
    end

    if os.getenv and os.getenv("SHOT_SETTINGS") then
        -- 局内：走 GameUI.showSettings() —— 它顺带 refreshSettings()，
        -- 能把「看海中」的禁用态刷出来（直接 FindById 强开的话这些刷新就都跳过了）
        if currentPhase_ == "playing" and GameUI and GameUI.showSettings then
            GameUI.showSettings()
            print("[Main] SHOT_SETTINGS：已打开局内设置")
        elseif UI.FindById then
            local ov = UI.FindById("settingsOverlay")
            if ov then ov:Show() print("[Main] SHOT_SETTINGS：已打开设置") end
        end
    end
    -- SHOT_NEWGAME=1 → 点一下主菜单的「新的游戏」按钮
    --   2026-09-15 改：原来这个是"打开选地图弹窗"，那个弹窗已按用户要求删除
    --   → 改成点按钮本身更有意义：它顺带验证"菜单 → 直接进选国页"这条链真的通了。
    if os.getenv and os.getenv("SHOT_NEWGAME") then
        local btn = UI.FindById and UI.FindById("btnNewGame")
        if btn and btn.OnClick then
            btn:OnClick(nil)
            print("[Main] SHOT_NEWGAME：已点击「新的游戏」")
        else
            print("[Main] ⚠️ SHOT_NEWGAME：找不到 btnNewGame")
        end
    end

    -- Subscribe to core events
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("KeyDown", "HandleKeyDown")

    print("=== 逐鹿九州 v" .. GameConfig.Version .. " 启动 ===")
end

function Stop()
    UI.Shutdown()
end

-- ============================================================================
-- Phase: Main Menu (进入页面)
-- ============================================================================

function ShowMainMenu()
    currentPhase_ = "menu"

    -- 主菜单播放主题曲《问鼎中原》
    MusicManager.play("qdzq")

    local menuRoot = MainMenu.create({
        onStart = function(playsetName)
            -- 游玩集（= 文件夹）：模组的启用组合；地图单独选（清单 A15 ⑤/⑦）
            print("[Main] 选择势力（游玩集=" .. tostring(playsetName) .. "）")
            ShowFactionSelect()
        end,
        onEditor = function()
            print("[Main] 打开编辑器")
            ShowScenarioEditor()
        end,
        -- 继续游戏（有存档时显示）
        onContinue = SaveManager.hasSave() and function()
            print("[Main] 继续游戏")
            ContinueGame()
        end or nil,
        -- 读取存档（独立入口）
        onLoadSave = function()
            print("[Main] 打开读取存档面板")
            ShowSaveSlots("load")
        end,
        -- 🗑 2026-09-15 删掉两个回调（用户拍板"一并删掉"）：
        --   onSelectMapPack   —— 全工程没人调用（模组面板早就不放地图下拉了）
        --   onApplyMapOptions —— 配套的「世界生成」面板也没有任何入口能打开
        --   地图现在只在**选国页**上选（上边那排=地图模组 / 左边那列=地图名）
    })

    uiRoot_ = menuRoot
    UI.SetRoot(uiRoot_)

    -- 启动主菜单交错入场动画
    MainMenu.beginIntro()
end

-- ============================================================================
-- Phase: Faction Select（选择势力）
-- ============================================================================

--- 显示"选择势力"界面：列出所有有领地的势力，点击进入游戏
function ShowFactionSelect()
    Profile.mark("进入选国页前")
    currentPhase_ = "select"

    -- 新版选国界面：列表 + 地图 + 信息卡（古风卷轴风）
    CountrySelect.show({
        onStart = function(factionId, settings, camState)
            -- camState：选国页当前镜头视角，进入游戏后继承
            -- settings：选国页的各项开关（难度/模式/侵略度/迷雾/人物生死）
            StartGame(factionId, camState, settings)
        end,
        -- 「观察」= 不选国家，直接用**看海模式**开局（2026-09-15）
        --   StartGame(nil) 即可：GameState.init(nil) 会写 playerFactionId = nil，
        --   而"无势力不判定胜负"的逻辑本来就有（CheckGameOver 第一行早退）。
        onSpectate = function(camState)
            print("[Main] 看海开局（不选国家）")
            StartGame(nil, camState)
        end,
        onBack = function()
            ShowMainMenu()
        end,
    })
end

-- ============================================================================
-- Phase: Scenario Editor（编辑器）
-- ============================================================================

--- 用编辑器剧本开局：直接传给读档管线（不占用存档位）
function StartScenario(scenarioData)
    if type(scenarioData) ~= "table" then
        print("[Main] 剧本开局失败：数据无效")
        return
    end
    print("[Main] 剧本开局（不占用存档位）")
    ContinueGame(scenarioData)
end

--- 打开编辑器
function ShowScenarioEditor()
    Profile.mark("进入编辑器前")
    currentPhase_ = "editor"
    ScenarioEditor.show({
        onStart = function(data)
            StartScenario(data)
        end,
        onBack = function()
            ShowMainMenu()
        end,
    })
end

--- 打开存档位面板（mode: "save" 保存 | "load" 读取）
---@param mode string
function ShowSaveSlots(mode)
    SaveSlotsPanel.show({
        mode = mode,
        root = uiRoot_,
        onSaveToSlot = function(slot)
            return SaveManager.saveToSlot(slot, GameState, TimeSystem.getState())
        end,
        onLoad = function(slot)
            local data = SaveManager.loadSlot(slot)
            if not data then
                print("[Main] 存档位 " .. tostring(slot) .. " 读取失败")
                return
            end
            print("[Main] 读取 " .. tostring(slot) .. " 号存档")

            -- 读档前确认（2026-09-14 · 用户设计）：
            --   存档当时启用的模组 ≠ 当前游玩集的模组 → **弹窗问**，别默默把游玩集切回去。
            --   三个按钮：直接进入（用现在的模组）/ 改回存档的模组并进入 / 取消
            local diff = SaveManager.diffMods(data)
            if diff then
                print(string.format("[Main] 模组不一致：缺 %d / 多 %d / 版本变 %d → 弹窗确认",
                    #diff.missing, #diff.extra, #diff.versionChanged))
                if MainMenu.confirmLoadMods(diff, data, function(d) ContinueGame(d) end) then
                    return      -- 等玩家选
                end
            end
            ContinueGame(data)
        end,
    })
end

-- ============================================================================
-- Phase: Continue Game（读档）
-- ============================================================================

--- 从存档恢复游戏
---@param savedData table|nil 可选：直接传入存档数据（剧本开局等）；nil 时读取最近存档
function ContinueGame(savedData)
    local data = savedData or SaveManager.load()
    if not data then
        print("[Main] 无存档，返回主菜单")
        ShowMainMenu()
        return
    end
    currentPhase_ = "playing"

    -- 读档进入游戏 → 无缝切换到战略地图曲《运筹帷幄》
    MusicManager.play("ycww")

    -- 1. 重建基础状态（静态数据从 Provinces.data / Factions.data 重建）
    GameState.init(data.playerFactionId)
    require("systems.EventSystem").reset()   -- 事件队列/一次性记录不跨局（2026-09-13）

    -- 1.2 战争迷雾开关（2026-09-24）：以存档为准（GameState.init 是从选国页设置推的，
    --     读档时那条线不该生效）。老存档没有这个字段 → 保持 init 的默认（关）。
    if data.fogOfWar ~= nil then
        GameState.fogOfWar = data.fogOfWar == true
        GameState.fogCache_ = nil
        print(string.format("[Fog] 读档恢复战争迷雾：%s", GameState.fogOfWar and "开" or "关"))
    end

    -- 1.5 事件系统：清空上一局的待处理事件/一次性记录（2026-09-13）
    require("systems.EventSystem").reset()

    -- 1.6 模组自己的**全局**格子（2026-09-14 · 洞 2）：整格恢复。
    --     老档没有 modState → 兜底成空表（GameState.init 已经建了一个，这里只覆盖）
    GameState.mods = data.modState or GameState.mods or {}

    -- 1.7 人物 id 计数器（2026-09-17）：跟存档一起恢复，避免读档后新人物撞 id
    -- 人物生死开关（2026-09-28）：老存档没有这个字段 → 视为开启
    GameState.mortalityEnabled = data.mortalityEnabled ~= false
    if data.characterNextId then
        require("systems.CharacterSystem")._nextId = data.characterNextId
    end

    -- 2. 应用势力动态字段
    if data.factions then
        for key, saved in pairs(data.factions) do
            local fid = tonumber(key)
            local f = GameState.factions[fid]
            if f then
                f.gold      = saved.gold or 0
                f.food      = saved.food or 0
                f.armySize  = saved.armySize or 0
                f.prestige  = saved.prestige or 0
                f.stability = saved.stability or 0
                f.morale    = saved.morale or 100
                f.alive     = saved.alive
                f.vassalOf  = saved.vassalOf
                if saved.leader then f.leader = saved.leader end
                -- 人物/官职/后宫 + 特质（2026-09-17）：特质是"人"的一部分，必须随档走
                if saved.characters then f.characters = saved.characters end
                if saved.consorts then f.consorts = saved.consorts end
                if saved.leaderId then f.leaderId = saved.leaderId end
                if saved.policies then f.policies = saved.policies end
                if saved.policyAxes then f.policyAxes = saved.policyAxes end
                if saved.reforms then f.reforms = saved.reforms end
                if saved.reformEffects then f.reformEffects = saved.reformEffects end
                if saved.provinces then f.provinces = saved.provinces end
                -- 资源注册表（2026-09-13）：注册型资源（积分/人力…）随档恢复；
                -- 老档没有这个字段 → 下面 ensure 会补上初始值
                if saved.resources then f.resources = saved.resources end
                -- 模组自己的格子（2026-09-14 · 洞 2）：整格恢复
                --   ⚠️ 老档没有这字段 → **必须兜底成空表**，不能留 nil（模组会往上写）
                f.mods = saved.mods or {}
                require("data.Resources").ensure(f)
            end
        end
    end

    -- 3. 应用省份动态字段（ownerId / garrison / stability / population）
    if data.provinceStates then
        for key, ps in pairs(data.provinceStates) do
            local pid = tonumber(key)
            local p = GameState.provinces[pid]
            if p then
                p.ownerId     = ps.ownerId
                p.occupiedBy  = ps.occupiedBy
                p.garrison    = ps.garrison or 0
                -- 混编（2026-09-24）：兵种构成。老存档没有这个字段 → 置 nil，
                --   读取时 Units.mixOf 会自动按该势力主力兵种兜底
                p.unitMix     = ps.unitMix
                -- 驻军士气（2026-09-26）：老存档没有 → 默认满
                p.morale      = ps.morale or 100
                p.stability   = ps.stability or 60
                p.population  = ps.population or 0
                p.isWasteland = ps.isWasteland or false

                -- 自愈：无主地不该有驻军（2026-09-26）
                --   老存档里可能残留 ownerId=nil + garrison>0 的矛盾数据
                --   （上一版"无主地只设 occupiedBy"造成的）——地图画成灰色却挂着
                --   "?" + 兵力数字的旗标，看起来像"无主但有守军"谁也占不了。
                --   这里统一清掉：无主地（非废土）驻军归零。
                if not p.ownerId and not p.isWasteland and (p.garrison or 0) > 0 then
                    print(string.format("[Load] 修正无主地残留驻军：省 %s 驻军 %d → 0",
                        tostring(p.name or pid), p.garrison))
                    p.garrison = 0
                    p.occupiedBy = nil
                end
            end
        end
    end

    -- 4. 重建 factionProvinces 反向索引（依据省份 ownerId）
    GameState.factionProvinces = {}
    for fid, _ in pairs(GameState.factions) do
        GameState.factionProvinces[fid] = {}
    end
    for pid, p in pairs(GameState.provinces) do
        if p.ownerId and GameState.factionProvinces[p.ownerId] then
            local tbl = GameState.factionProvinces[p.ownerId]
            tbl[#tbl + 1] = pid
        end
    end

    -- 5. 外交关系
    GameState.relations = {}
    if data.relations then
        for key, rel in pairs(data.relations) do
            local a, b = key:match("^(%d+)_(%d+)$")
            if a and b then
                local ai, bi = tonumber(a), tonumber(b)
                local rec = {
                    value         = rel.value or 0,
                    atWar         = rel.atWar or false,
                    peaceCooldown = rel.peaceCooldown or 0,
                }
                GameState.relations[ai] = GameState.relations[ai] or {}
                GameState.relations[ai][bi] = rec
                GameState.relations[bi] = GameState.relations[bi] or {}
                GameState.relations[bi][ai] = rec
            end
        end
    end

    -- 6/7. 军事字段共用独立恢复器：兵源/战斗/军令/战争/统帅/和谈与真实总账。
    -- 省份归属、驻军及混编仍由上面的原有加载逻辑负责；旧档不沿用上一局军事残留。
    require("save.MilitarySave").restore(GameState, data)

    -- 8. 时间
    TimeSystem.restore(data.time)
    GameState.speed = select(1, TimeSystem.getSpeed())
    GameState.paused = TimeSystem.isPaused()

    -- 9. 重新注册月度/每日/年度回调 + 构建 UI
    TimeSystem.on("month", function(t)
        OnNewMonth(t)
    end)
    TimeSystem.on("day", function(t)
        OnNewDay(t)
    end)
    TimeSystem.on("year", function(t)
        LeaderSystem.processYear(GameState)
        -- 人物年度推进（2026-09-28）：年龄增长 + 官员/后宫老死
        local CS = require("systems.CharacterSystem")
        CS.processYear(GameState)
        -- 君主与后宫生育（每年按年龄概率得子）
        CS.processYearBirths(GameState)
        -- 幼主成年 → 亲政
        CS.processRegency(GameState)
        -- 游方士人上门（每年 25% 概率来一位求仕者）
        CS.processYearWanderers(GameState)
        -- 脚本钩子（2026-09-13）：给"每年"开一个口子
        require("systems.Hooks").fire("year", { gameState = GameState, time = t })
    end)
    BuildGameUI()

    GameState.addMessage("读档成功，继续你的霸业！", "system")
    print("[Main] 读档成功")
end

-- ============================================================================
-- 切换视角（换国家 / 看海）—— **同一局，不重置世界**（2026-09-15）
-- ============================================================================

--- 把"我是谁"换成另一个势力（或 nil = 看海）
---
--- 🔴 **绝对不要**在这里碰 `GameState.init()` / 读档那条线 —— 那会把世界重置掉。
---   这个函数只做三件事：① 换 id（`GameState.setViewFaction`）② 关掉那些还指着旧势力的面板
---   ③ 打日志。顶栏和地图**每帧现读** playerFactionId，会自己跟上，不用管。
---
---   月度 AI 也不用管：它判断的是 `faction.id ~= playerFactionId`
---   → 旧国自动交给电脑、新国自动不再走电脑。
---@param factionId number|nil 目标势力 id；nil = 看海（观战）
---@return boolean ok
---@return string|nil reason
function SwitchViewFaction(factionId)
    if currentPhase_ ~= "playing" then
        return false, "还没进游戏，不能切换视角"
    end

    local fpBefore = worldFingerprint_()   -- 换之前的世界指纹（和换之后比对，见函数末尾）

    -- 先关掉"可能在显示旧势力数据"的面板（它们的绑定还是老的）
    if GameUI.hideProvincePanel then GameUI.hideProvincePanel() end
    if GameUI.hideSelfPanel    then GameUI.hideSelfPanel()    end
    if GameUI.hideCourtPanel   then GameUI.hideCourtPanel()   end
    if GameUI.hideDiplomacy    then GameUI.hideDiplomacy()    end
    if GameUI.hideRanking      then GameUI.hideRanking()      end
    if GameUI.hidePeaceDialog  then GameUI.hidePeaceDialog()  end
    if mapWidget_ and mapWidget_.setSelectedProvince then
        mapWidget_:setSelectedProvince(nil)
    end

    local ok, reason = GameState.setViewFaction(factionId)
    if not ok then
        print("[Main] ⚠️ 切换视角失败：" .. tostring(reason))
        return false, reason
    end
    print(string.format("[Main] 切换视角 → %s（同一局，世界状态未动）",
        factionId and tostring(factionId) or "观战（看海）"))
    -- 前后各打一次世界指纹：换视角是本作唯一"该动 id、不该动世界"的操作，
    -- 日志里留一对一模一样的指纹，将来出问题一眼能定位是不是这里把世界重置了。
    print("[Main]   世界换之前：" .. fpBefore)
    print("[Main]   世界换之后：" .. worldFingerprint_())
    return true, nil
end

--- 从选国页回到对局：还原阶段 + 把 UI 根换回游戏那棵。
---
--- 为什么不重建界面：`mapWidget_` / `gameUIPanel_` 都是**一次建好一直留着**的
--- （BuildGameUI）。重建会丢掉相机位置、地图缓存和已建控件；
--- `UI.SetRoot(uiRoot_)` 只是把原来那棵重新挂回去 —— 相机、选中省、面板状态全在。
function ReturnToGame()
    currentPhase_ = "playing"
    if uiRoot_ then UI.SetRoot(uiRoot_) end
end

--- 打开「切换角色」页：复用选国页，但走 **switch 模式** —— 只换视角，**绝不走开局流程**。
---
--- 为什么 phase 要设成 "select"：`HandleUpdate` 里有一句
--- `if currentPhase_ ~= "playing" then return end`，会顺带把时间推进 / AI / 经济全停住。
--- 选人时世界不该继续走（CK3 打开角色切换也是暂停的）。
function ShowSwitchFaction()
    currentPhase_ = "select"
    print("[Main] 打开切换角色页（世界暂停，选完只换视角）")

    CountrySelect.show{
        mode      = "switch",
        gameState = GameState,          -- 地图要画**当前这一局**的现归属，不是开局疆域
        onStart   = function(factionId)
            ReturnToGame()
            SwitchViewFaction(factionId)
        end,
        onSpectate = function()
            ReturnToGame()
            SwitchViewFaction(nil)      -- 「观察」= 看海
        end,
        onBack = function()
            ReturnToGame()              -- 直接返回：什么都没换
        end,
    }
end

-- ============================================================================
-- Phase: Start Game
-- ============================================================================

--- 开始游戏（玩家选择势力后进入）
---@param factionId number 玩家选择的势力 id
---@param camState table|nil 可选：选国页镜头视角 {camX, camY, zoom}，开局继承
---@param factionId number|nil 玩家势力（nil = 看海）
---@param camState table|nil 选国页继承的镜头
---@param settings table|nil 选国页设置 { difficulty, mode, aggression, fog, mortality }
function StartGame(factionId, camState, settings)
    currentPhase_ = "playing"

    -- 人物生死开关（2026-09-28）：选国页选的"人物生死"存进 GameState，
    --   供 CharacterSystem 的年度推进判断"官员/后宫要不要也老死"。
    --   默认**开启**（有生老病死更真实）；看海/剧本开局没有 settings → 也用默认。
    do
        local mort = settings and settings.mortality
        -- 2 = 开启，1 = 关闭（选国页的 FOG_OPTS 同款两档口径）
        GameState.mortalityEnabled = (mort == nil) or (mort == 2)
        print(string.format("[Character] 人物生死：%s",
            GameState.mortalityEnabled and "开启（官员/后宫会老死）" or "关闭（只有君主会死）"))
    end

    -- 底图加载：单帧同步尝试一次（成功则直接进游戏；没下完就交给渲染侧——
    -- MapRenderer 每 0.5s 重试 + 自动发起 DWP 下载，图到了自己出现）
    local function tryLoadMapImage()
        if mapWidget_ and not mapWidget_:IsMapImageReady() then
            print("[Main] 底图未就绪：已发起下载，进入游戏后自动出现")
        end
    end

    --- 进游戏的重活拆成步骤（顺序敏感：状态 → 时间 → 地图 → 界面 → 收尾）
    ---@return table[]
    local function buildSteps()
        return {
            { label = "初始化势力与省份…", weight = 22, fn = function()
                -- 0. 地图渲染由 P 社式 shader 3D 层负责（见 BuildMapWidget）
                GameState.init(factionId)
                Profile.mark("GameState.init")
            end },
            { label = "初始化时间与历法…", weight = 8, fn = function()
                TimeSystem.init()
                GameState.speed = select(1, TimeSystem.getSpeed())   -- sync initial speed to UI
                GameState.paused = false

                -- SHOT_SPEED=<档位 1~5> → 直接跳到该速度
                --   离屏验证"按月/按年结算"用：默认速度下要跑很久才过一个游戏月
                local shotSpeed = os.getenv and tonumber(os.getenv("SHOT_SPEED") or "")
                if shotSpeed then
                    TimeSystem.setSpeed(shotSpeed)
                    GameState.speed = select(1, TimeSystem.getSpeed())
                    print("[Main] SHOT_SPEED=" .. tostring(shotSpeed))
                end

                -- 按月 / 按日 / 按年回调
                TimeSystem.on("month", function(t) OnNewMonth(t) end)
                TimeSystem.on("day", function(t) OnNewDay(t) end)
                TimeSystem.on("year", function(t)
                    LeaderSystem.processYear(GameState)
                    -- 人物年度推进（2026-09-28）：年龄增长 + 官员/后宫老死
                    --   （是否老死由开局设置的"人物生死"开关决定）
                    local CS = require("systems.CharacterSystem")
                    CS.processYear(GameState)
                    -- 君主与后宫生育（每年按年龄概率得子）
                    CS.processYearBirths(GameState)
                    -- 幼主成年 → 亲政
                    CS.processRegency(GameState)
                    -- 游方士人上门（每年 25% 概率来一位求仕者）
                    CS.processYearWanderers(GameState)
                end)
            end },
            { label = "准备地图（底图 / 判省图 / 配色）…", weight = 30, fn = function()
                BuildMapWidget()
                Profile.mark("BuildMapWidget（含地图层）")
            end },
            { label = "加载地图底图…", weight = 20, fn = tryLoadMapImage },
            { label = "构建界面…", weight = 30, fn = function()
                BuildGameOverlays()
                Profile.mark("BuildGameOverlays")
            end },
            { label = "进入游戏…", weight = 10, fn = function()
                -- 无缝切换到战略地图曲《运筹帷幄》
                MusicManager.play("ycww")

                -- 继承选国页的镜头视角（放大位置），避免开局跳回全图
                if camState and mapWidget_ then
                    if camState.camX then mapWidget_.camX = camState.camX end
                    if camState.camY then mapWidget_.camY = camState.camY end
                    if camState.zoom then
                        mapWidget_.zoom = camState.zoom
                        mapWidget_.targetZoom = camState.zoom
                    end
                    if mapWidget_._clampCamera then mapWidget_:_clampCamera() end
                end

                print("[Main] 游戏开始！（玩家势力 " .. tostring(factionId) .. "）")

                -- 核心系统（2026-09-16）：开局记核心（= 初始归属）+ 接管 rebellion 钩子
                require("systems.CoreSystem").ensureInit(GameState)
                require("systems.CoreSystem").registerHooks()

                -- 人物系统（2026-09-16）：把君主登记成人物 + 生成在野人才
                require("systems.CharacterSystem").ensureInit(GameState)

                -- 截图模式附加：SHOT_ZOOM=3.0 → 直接跳到该倍率
                -- （离屏验证整图底图的 LOD 切换：≥1.0 用全分辨率图）
                local shotZoom = os.getenv and tonumber(os.getenv("SHOT_ZOOM") or "")
                if shotZoom and mapWidget_ then
                    mapWidget_.zoom = shotZoom
                    mapWidget_.targetZoom = shotZoom
                    if mapWidget_._clampCamera then mapWidget_:_clampCamera() end
                    print("[Main] SHOT_ZOOM=" .. tostring(shotZoom))
                end
                -- SHOT_SELPROV=<省id|1=玩家第一省> → 选中该省（离屏验证"选中高亮/国境轮廓"用）
                local shotSel = os.getenv and os.getenv("SHOT_SELPROV")
                if shotSel and mapWidget_ then
                    local selId = tonumber(shotSel)
                    if selId == 1 or selId == nil then
                        local pf2 = GameState.getPlayerFaction()
                        selId = pf2 and pf2.provinces and pf2.provinces[1] or nil
                    end
                    if selId then
                        -- 镜头也拉过去（不然选中的省可能在视口外，看不到高亮）
                        mapWidget_:focusProvince(selId, tonumber(os.getenv("SHOT_ZOOM") or "") or 3.0)
                        -- SHOT_PANEL=1 → 顺便把省份面板打开（离屏验证面板里的按钮排布）
                        if os.getenv("SHOT_PANEL") == "1" and GameUI.showProvincePanel then
                            local prov = GameState.getProvince and GameState.getProvince(selId)
                            if prov then GameUI.showProvincePanel(selId, prov) end
                        end
                        print("[Main] SHOT_SELPROV=" .. tostring(selId))
                    end
                end
                -- SHOT_WASTELAND=<省id|1=玩家首省> → 把该省变成沙漠（离屏看沙漠化表现）
                local shotWaste = os.getenv and os.getenv("SHOT_WASTELAND")
                if shotWaste and mapWidget_ then
                    local wid = tonumber(shotWaste)
                    if wid == 1 or wid == nil then
                        local pf3 = GameState.getPlayerFaction()
                        wid = pf3 and pf3.provinces and pf3.provinces[1] or nil
                    end
                    if wid then
                        GameState.setWasteland(wid, true)
                        mapWidget_:focusProvince(wid, tonumber(os.getenv("SHOT_ZOOM") or "") or 2.0)
                        print("[Main] SHOT_WASTELAND=" .. tostring(wid))
                    end
                end
                -- SHOT_CAM="x,y" → 把镜头对到地图该坐标（配合 SHOT_ZOOM 看局部细节）
                local shotCam = os.getenv and os.getenv("SHOT_CAM")
                if shotCam and mapWidget_ then
                    local sx, sy = shotCam:match("^(%-?%d+),(%-?%d+)$")
                    if sx then
                        mapWidget_.camX = tonumber(sx)
                        mapWidget_.camY = tonumber(sy)
                        if mapWidget_._clampCamera then mapWidget_:_clampCamera() end
                        print("[Main] SHOT_CAM=" .. shotCam)
                    end
                end
                -- 开场日志已由 GameState.init 统一写（2026-09-16：删掉这里的重复一份，
                --   修"开局出现两条一模一样的通知"）

                -- SHOT_MAPMODE=<id> → 切地图模式（离屏验证：resource 资源产出标注等）
                if os.getenv and os.getenv("SHOT_MAPMODE") then
                    GameState.mapMode = os.getenv("SHOT_MAPMODE")
                    print("[Main] SHOT_MAPMODE=" .. tostring(GameState.mapMode))
                end

                -- 截图模式：模拟宣战+战斗（验证战争列表/战斗卡布局）
                if os.getenv and os.getenv("SHOT_MODE") then
                    local playerId = GameState.playerFactionId
                    local enemyId = nil
                    for fid, f in pairs(GameState.factions) do
                        if fid ~= playerId and f.provinces and #f.provinces > 0 then
                            enemyId = fid
                            break
                        end
                    end
                    if enemyId then
                        DiplomacySystem.declareWar(GameState, playerId, enemyId)
                        local eprov = GameState.factions[enemyId].provinces[1]
                        GameState.battles = {
                            [eprov] = {
                                -- 数值随兵力总量 ÷5（2026-09-17），离屏截图才跟真实战况同一量级
                                att = { factionId = playerId, size = 160, morale = 100 },
                                def = { factionId = enemyId, size = 120, morale = 100 },
                                progress = 0.4,
                            },
                        }
                        -- SHOT_SAVELOAD=1 → 存/读档往返自检（验证"存档记录模组 + 读档校验"）
                        if os.getenv and os.getenv("SHOT_SAVELOAD") then
                            local SM = require("save.SaveManager")
                            local TS = require("core.TimeSystem")
                            local okS, errS = SM.saveToSlot(1, GameState, TS.getState())
                            print("[ShotSaveLoad] 存档 → " .. tostring(okS) .. " " .. tostring(errS or ""))
                            local back = SM.loadSlot(1)
                            local md = back and back.mods
                            if md then
                                local first = (md.list or {})[1] or {}
                                print(string.format("[ShotSaveLoad] 读回：游玩集=%s 模组数=%d 首个=%s v%s",
                                    tostring(md.playset), #(md.list or {}),
                                    tostring(first.name), tostring(first.version)))
                            else
                                print("[ShotSaveLoad] ⚠️ 读回失败或无 mods 字段")
                            end
                        end
                        -- SHOT_BATTLE_DEF=<兵力> → 加大守方兵力（离屏验证"溃退"用：让攻方必败）
                        local shotDef = os.getenv and tonumber(os.getenv("SHOT_BATTLE_DEF") or "")
                        if shotDef then
                            GameState.battles[eprov].def.size = shotDef
                            print("[Main] SHOT_BATTLE_DEF：守方兵力设为 " .. tostring(shotDef))
                        end
                        -- SHOT_DEFEND=1 → 造一场"敌人进攻玩家省"的战斗（守方 6 人，攻方必胜）
                        --   走真实战斗流程，验证"AI 打赢后占领玩家的省"地图怎么显示（用户实际场景）
                        if os.getenv and os.getenv("SHOT_DEFEND") then
                            local pf = GameState.getPlayerFaction()
                            local pprov = pf and pf.provinces and pf.provinces[1]
                            if pprov then
                                GameState.battles[pprov] = {
                                    att = { factionId = enemyId, size = 200, morale = 100 },
                                    def = { factionId = playerId, size = 6, morale = 100 },
                                    progress = 0.9,
                                }
                                print("[ShotDefend] 敌人进攻玩家省 " .. tostring(pprov) .. "（守方 6 人，攻方必胜）")
                            end
                        end
                        -- SHOT_PEACE_DLG=1 → 挂起一个 AI 求和（离屏验证"和约弹窗 → 暂停"）
                        if os.getenv and os.getenv("SHOT_PEACE_DLG") then
                            GameState.pendingPeace = {
                                proposerId = enemyId, targetId = playerId, terms = { gold = 100 },
                            }
                            print("[ShotPeaceDlg] 已挂起 AI 求和，等待弹窗")
                        end
                        -- SHOT_PEACE=1 → 直接走一次"接受AI求和"（离屏验证停战收尾：清战斗 + 撤回在途军队）
                        if os.getenv and os.getenv("SHOT_PEACE") then
                            local function countBattles()
                                local n = 0
                                for _ in pairs(GameState.battles or {}) do n = n + 1 end
                                return n
                            end
                            local function countArmies()
                                return #(GameState.armies or {})
                            end
                            local function hasWarBetween(f1, f2)
                                for _, w in pairs(GameState.wars or {}) do
                                    if (w.aId == f1 and w.dId == f2) or (w.dId == f1 and w.aId == f2) then
                                        return true
                                    end
                                end
                                return false
                            end
                            -- 造一支在途军队，覆盖"停战撤回在途部队"路径
                            GameState.armies = GameState.armies or {}
                            table.insert(GameState.armies, {
                                factionId = playerId, from = eprov, to = eprov,
                                size = 50, morale = 80, progress = 0, totalHours = 72, realElapsed = 0,
                            })
                            local b0, a0 = countBattles(), countArmies()
                            GameState.pendingPeace = {
                                proposerId = enemyId, targetId = playerId, terms = { gold = 100 },
                            }
                            local okP, reasonP = DiplomacySystem.respondPendingPeace(GameState, true)
                            print(string.format(
                                "[ShotPeace] 接受求和: %s (%s) | 战斗 %d→%d | 在途军队 %d→%d | 战争记录还在=%s",
                                tostring(okP), tostring(reasonP),
                                b0, countBattles(), a0, countArmies(),
                                tostring(hasWarBetween(playerId, enemyId))))
                        end
                        -- SHOT_OCCUPY=1 → 直接把该省标成"被占领"（离屏验证斜条纹用，不用等战斗打完）
                        if os.getenv and os.getenv("SHOT_OCCUPY") then
                            local p = GameState.provinces[eprov]
                            if p then
                                p.occupiedBy = playerId
                                print("[Main] SHOT_OCCUPY：省 " .. tostring(eprov) .. " 标记为被占领")
                            end
                        end
                    end
                end
            end },
        }
    end

    -- 2026-09-13：载入画面已删（用户要求），步骤改为**同步顺序执行**。
    -- 仍在同一个函数里按顺序做完，只是不再分帧、不再画进度条。
    ---@type table[]
    local steps = buildSteps()
    local t0 = os.clock()
    for i = 1, #steps do
        local st = steps[i]
        local ok, err = pcall(st.fn)
        if not ok then
            print("[Main] ⚠️ 开局步骤失败：" .. tostring(st.label) .. " → " .. tostring(err))
        end
    end
    print(string.format("[Main] 开局步骤完成 %d 步，%.0f ms", #steps, (os.clock() - t0) * 1000))
end

-- ============================================================================
-- Build Game UI (Map + Overlays)
-- ============================================================================

--- 建地图层与地图 widget（2D 路线：瓦片底图 + 逐省矢量上色）
function BuildMapWidget()
    -- 地图 widget（2026-09-12 停用 3D 方案：手机小游戏运行时不支持 3D 渲染）
    mapWidget_ = MapRenderer.create(GameState)
    Profile.mark("MapRenderer.create（地图 widget）")

    -- UI 遮挡（2026-09-19 用户："我点那个上面不会透过这个框直接点到后边的领土"）：
    --   点击落在浮层面板（征召/研究/战争条）上时，地图这边直接吞掉，不去选省
    mapWidget_.pointerBlockCheck = function(x, y)
        return GameUI.isPointOverPanel(x, y)
    end

    -- Set up province click handler
    mapWidget_.onProvinceClick = function(provinceId)
        OnProvinceClicked(provinceId)
    end

    -- 地图"涂抹/点选"统一入口（2026-09-16 泛化）：
    --   ① 和平条约选省（可索取省才涂）② 国交行动（点/涂抹国家即执行）
    mapWidget_.onPaintProvince = function(provinceId, forceSelect)
        if GameUI.isPeacePickMode() then
            GameUI.togglePeaceProvincePick(provinceId, forceSelect)
        elseif GameUI.isActMode() then
            RunInteractionOnProvince(provinceId, forceSelect == true)
        end
    end

    -- 一次涂抹结束（松开鼠标）：把"这次涂抹已处理过的国家"清掉
    mapWidget_.onPaintEnd = function()
        actPaintedFactions_ = {}
    end

    -- 哪些省能被涂（按下起点判定：可涂省上按住才涂抹，否则拖动地图）
    mapWidget_.isPaintable = function(provinceId)
        if GameUI.isPeacePickMode() then
            return GameUI.isProvincePickable(provinceId)
        elseif GameUI.isActMode() then
            return IsActModeTarget(provinceId)
        end
        return false
    end

    -- Army move target selected on map（2026-09-26：改成寻路，可点任意省）
    mapWidget_.onArmyMoveTarget = function(fromId, toId)
        local prov = GameState.getProvince(fromId)
        local target = GameState.getProvince(toId)
        if not prov or not target then return end
        local pid = GameState.playerFactionId
        -- 调军数量由玩家在军队面板里选（2026-10-04 用户："仿照他们去弄"）：
        --   原来是固定派一半、玩家没法选；现在读面板输入框，
        --   面板没开/没填时退回"一半"（保持旧行为兜底）。
        local moveSize = GameUI.moveWanted and GameUI.moveWanted() or 0
        if moveSize < 1 then
            moveSize = math.max(1, math.floor((prov.garrison or 0) * 0.5))
        end
        if moveSize < 1 then return end
        -- orderMove：BFS 找路 → 逐段行军（不是只能走相邻一步）
        local ok, result = MilitarySystem.orderMove(GameState, pid, fromId, toId, moveSize)
        if ok then
            -- 传 pid 启用通行权过滤（只走自家/无主/交战国，中立国绕开）
            local path = MilitarySystem.findPath(GameState, fromId, toId, pid)
            local hops = path and (#path - 1) or 1
            GameState.addMessage(string.format("从 %s 调军 %d 前往 %s（%d 段路程）",
                prov.name, moveSize, target.name, hops), "military")
        else
            GameState.addMessage("调军失败: " .. tostring(result), "warning")
        end
    end

    -- 面板关闭时清掉地图高亮（2026-09-23 用户："关闭详情（点叉号）…为什么这个区块还是发亮"）：
    --   省份选中高亮 + 军队旗的沿形金光。**只在用户主动关面板/点空白时调** ——
    --   程序化 hide（点别的省顺手收起）不能调，否则会把刚设上的新高亮也清掉。
    GameUI.onClearMapHighlight = function()
        if mapWidget_ and mapWidget_.clearSelectionHighlight then
            mapWidget_:clearSelectionHighlight()
        end
    end

    -- 点击地图上的军队旗标 → 打开军队详情面板（2026-09-23 用户："点击军队 → 弹出界面"；
    --   行军中的军队也能点开 → 随时拦截/改道，避开 AoH3"移动中点不到"的坑）
    mapWidget_.onArmyClick = function(army)
        if not GameState.playerFactionId then return end   -- 观战模式不给开操作面板
        GameUI.hideProvincePanel()
        -- 高亮**二选一**（2026-09-23 用户："点区块发亮之后再点军队旗，为什么区块还发亮"）：
        --   选中军队 = 取消省选中 → 地图上的省高亮熄灭，只留旗子的沿形金光
        mapWidget_:setSelectedProvince(nil)
        GameUI.showUnitPanel(army, "army")
    end

    -- 点击省上的驻军旗 → 只开左下角驻军面板，不走省份点击
    --   （旗面经常压到邻省边界；穿透选省会弹左上角省份面板，或选中错误的省）
    --   返回 false = 这次不拦截，交给省份点击（选地区 / 和谈涂抹 / 国交行动）
    mapWidget_.onGarrisonClick = function(provId)
        if not GameState.playerFactionId then return false end
        if GameUI.isArmyPickMode and GameUI.isArmyPickMode() then return false end
        if GameUI.isPeacePickMode and GameUI.isPeacePickMode() then return false end
        if IsActMode and IsActMode() then return false end
        local prov = GameState.getProvince(provId)
        if not prov or prov.isWasteland or (prov.garrison or 0) <= 0 then return false end
        print(string.format("[Main] 点击驻军旗: %s (ID:%s) 兵力 %d — 只开驻军面板，不选省",
            tostring(prov.name), tostring(provId), prov.garrison or 0))
        GameUI.hideProvincePanel()
        -- 同 onArmyClick：省高亮熄灭，只留这面旗的金光（2026-09-23 用户反馈）
        mapWidget_:setSelectedProvince(nil)
        GameUI.showUnitPanel({ provId = provId }, "garrison")
        return true
    end

    -- 点击战斗行（2026-09-26 用户："交战中也可以看到他们的士气"）
    --   交战中双方都已从 armies/驻军里移出（由 battle 对象接管），
    --   所以必须单独给战斗行一个点击入口，否则战斗期间完全看不到士气。
    --   只读面板：显示攻守双方各自的兵力 + 士气。
    mapWidget_.onBattleClick = function(battle, provId)
        if not GameState.playerFactionId then return false end
        if GameUI.isArmyPickMode and GameUI.isArmyPickMode() then return false end
        if GameUI.isPeacePickMode and GameUI.isPeacePickMode() then return false end
        if IsActMode and IsActMode() then return false end
        if not battle then return false end
        print(string.format("[Main] 点击战斗行: 省 %s — 显示双方兵力/士气", tostring(provId)))
        GameUI.hideProvincePanel()
        mapWidget_:setSelectedProvince(nil)
        -- 把省 id 挂上去：面板标题要显示"交战中 · 某省"
        battle.provId = provId
        GameUI.showUnitPanel(battle, "battle")
        return true
    end

    -- 军队面板「移动」按钮（2026-09-26 改为 AoH3 式：点按钮 → 点**任意**目标省）
    --   旧版只能点相邻的绿色省（enterArmyMoveMode 用 neighbors 列表）——
    --   手机上要先看清哪块是相邻的、还只能走一步，很别扭。
    --   现在：点「调军」→ 进入待选目标状态 → 点地图上任意省 → 自动 BFS 寻路走过去。
    GameUI.startArmyMove = function(fromId)
        local prov = GameState.getProvince(fromId)
        if not prov then return end
        -- 门槛已去掉（2026-09-28）：只要还有驻军就能调（同上一条注释）
        local garrison = prov.garrison or 0
        if garrison < 1 then
            GameState.addMessage("该省没有驻军，无法调军", "warning")
            return
        end
        if mapWidget_ then
            -- ⚠️ 必须先收起军队详情面板（2026-09-26 用户："点击我的军队然后点击个区域
            --   为什么他没有办法去往这个地方"）：
            --   左下角 unitPanelBox 是**全屏容器**，isPointOverPanel 会用它吞掉点击
            --   （见 GameUI.isPointOverPanel）→ 面板开着时，左半屏的目标省全点不动。
            --   进调军模式就该让出地图，选完目标再按需要打开。
            --   2026-10-04：**先记下调军数量**再关面板 —— hideUnitPanel 会清 unitTarget，
            --   关掉后就查不到驻军了，数量会退回"一半"（用户报的正是这个 bug）。
            if GameUI.beginArmyMoveCount then GameUI.beginArmyMoveCount(garrison) end
            GameUI.hideUnitPanel()
            if GameUI.onClearMapHighlight then GameUI.onClearMapHighlight() end
            mapWidget_:enterArmyMoveMode(fromId)   -- 不传邻居 = 任意省都可选
            GameState.addMessage("请在地图上点选目标省份", "info")
        end
    end

end

--- 建 UI 覆盖层（顶栏 / 省份面板 / 外交 / 消息…）
function BuildGameOverlays()
    -- 科技：点卡片 → 开始研究（2026-09-16）
    GameUI.onTechStart = function(techId)
        local TechSystem = require("systems.TechSystem")
        local f = GameState.getPlayerFaction and GameState.getPlayerFaction()
        if not f then return end
        local ok, err = TechSystem.startTech(GameState, f, techId)
        if not ok then
            GameState.addMessage("无法研究：" .. tostring(err), "warning")
        end
        GameUI.refreshTechPanel(GameState)
    end

    -- 事件弹窗：玩家点选项 → 交给 EventSystem 应用效果（事件系统 2026-09-13）
    GameUI.onEventChoose = function(index)
        -- 2026-09-16：多事件——按"打开时记下的第几条"精确处理
        local ok, err = require("systems.EventSystem").choose(GameState, index, GameUI.openEventIndex_ or 1)
        GameUI.openEventIndex_ = nil
        GameUI.hideEventDialog()
        if ok then
            GameState.addMessage("已做出抉择。", "system")
        else
            print("[Event] ⚠️ 选项处理失败：" .. tostring(err))
        end
        -- 处理完事件，时间继续（保持玩家原来的暂停偏好：这里默认恢复正常流速）
        GameState.paused = false
        TimeSystem.resume()
    end

    -- Create UI overlays (top bar, province panel, diplomacy, messages)
    gameUIPanel_ = GameUI.create(GameState, {
        onSpeedChange = function(delta)
            local steps = math.abs(delta)
            for _ = 1, steps do
                if delta > 0 then
                    TimeSystem.increaseSpeed()
                else
                    TimeSystem.decreaseSpeed()
                end
            end
            local idx, speedName = TimeSystem.getSpeed()
            GameState.speed = idx
            GameState.paused = false
            print("[Main] 速度调整: " .. speedName)
        end,

        onPauseToggle = function()
            TimeSystem.togglePause()
            local paused = TimeSystem.isPaused()
            GameState.paused = paused
            GameState.speed = paused and 0 or (select(1, TimeSystem.getSpeed()))
            local status = paused and "暂停" or "继续"
            print("[Main] " .. status)
        end,

        onSetSpeed = function(index)
            TimeSystem.setSpeed(index)
            TimeSystem.resume()   -- 切速度档 = 继续游戏（修复暂停后点档时间不走的 bug）
            local idx, speedName = TimeSystem.getSpeed()
            GameState.speed = idx
            GameState.paused = false
            print("[Main] 速度设置: " .. speedName)
        end,

        onMoveArmy = function(fromId)
            -- Enter army move mode: let the player pick a target province on the map
            local prov = GameState.getProvince(fromId)
            if not prov then return end
            -- 门槛已去掉（2026-09-28 用户："去掉门槛"）：
            --   原来要求驻军 ≥500 才能调军，但调军固定派**一半** →
            --   打完仗兵力掉到 500 以下就**再也派不出去**（用户："第二次尝试派军
            --   结果发现这回就不行了"）。现在只要 >0 就能调。
            local garrison = prov.garrison or 0
            if garrison < 1 then
                GameState.addMessage("该省没有驻军，无法调军", "warning")
                return
            end
            local neighbors = prov.neighbors or {}
            if #neighbors == 0 then
                GameState.addMessage("该省份没有相邻领地", "info")
                return
            end
            -- Activate army move mode on the map widget
            if mapWidget_ then
                mapWidget_:enterArmyMoveMode(fromId, neighbors)
                GameState.addMessage("请在地图上选择调军目标（绿色高亮省份）", "info")
            end
        end,

        -- 省份面板里的国交行动按钮（点别国省份 → 暗杀/间谍/宣战…）
        onInteraction = function(actionId, targetFactionId)
            RunInteraction(actionId, targetFactionId)
        end,

        -- 外交面板的行动栏：点一个 → 关面板 → 地图进入"点/涂抹国家即执行"模式
        onStartActMode = function(actionId)
            EnterActMode(actionId)
        end,
        onExitActMode = function()
            ExitActMode()
        end,

        -- 2026-09-16 删：onDeclareWar（省份面板/外交行的专属按钮都去掉了，
        --   操作统一走 RunInteraction，见 onInteraction / onStartActMode）

        -- 2026-09-16 删：onProposePeace（同上，走 RunInteraction 的 peace 分支）

        onSubmitPeace = function(cfg)
            local pid = GameState.playerFactionId
            -- 收集条约窗口的选择（选中省 / 赔款 / 附庸 / 吞并）
            local terms = cfg.terms or {}
            terms.provinces = {}
            for selPid, _ in pairs(GameUI.getPeaceSelection()) do
                terms.provinces[#terms.provinces + 1] = selPid
            end
            terms.gold = GameUI.getPeaceGold()
            terms.food = GameUI.getPeaceFood()
            terms.vassal = GameUI.getPeaceVassal()
            terms.annexAll = GameUI.getPeaceAnnex()
            -- 灭国（吞并全部）是决定性胜利，附庸无意义，强制关掉
            if terms.annexAll then
                terms.vassal = false
            end
            local ok, reason = DiplomacySystem.submitPeace(GameState, pid, cfg.targetId, terms)
            if ok then
                GameState.addMessage(reason, "diplomacy")
            else
                GameState.addMessage("求和失败: " .. tostring(reason), "warning")
            end
            GameUI.hidePeaceDialog()
        end,

        onCancelPeace = function()
            GameUI.hidePeaceDialog()
        end,

        onAcceptPeace = function()
            local ok, reason = DiplomacySystem.respondPendingPeace(GameState, true)
            GameState.addMessage(reason, "diplomacy")
            GameUI.hidePeaceDialog()
        end,

        onRejectPeace = function()
            local ok, reason = DiplomacySystem.respondPendingPeace(GameState, false)
            GameState.addMessage(reason, "diplomacy")
            GameUI.hidePeaceDialog()
        end,

        -- 2026-09-16 删：onImproveRelation（同上，走 RunInteraction 的 improve 分支）

        onDiplomacyToggle = function()
            GameUI.toggleDiplomacy(GameState)
        end,

        -- 顶栏左上角拆成两个入口（2026-09-16 用户拍板）：
        --   自身 = 君主个人；朝廷 = 左官员 / 右后宫
        onToggleSelfPanel = function()
            GameUI.toggleSelfPanel()
        end,
        onToggleCourtPanel = function()
            GameUI.toggleCourtPanel()
        end,

        onPolicyToggle = function()
            GameUI.togglePolicyPanel()
        end,

        onPolicyAxis = function(axisId, optionId)
            local pid = GameState.playerFactionId
            local ok, reason = PolicySystem.setAxis(GameState, pid, axisId, optionId)
            if not ok then
                GameState.addMessage("调整政策失败：" .. tostring(reason), "warning")
            end
        end,

        onReformActivate = function(reformId)
            local pid = GameState.playerFactionId
            local ok, reason = PolicySystem.activateReform(GameState, pid, reformId)
            if not ok then
                GameState.addMessage("变法失败: " .. tostring(reason), "warning")
            end
        end,

        onTechToggle = function()
            GameUI.toggleTechPanel()
        end,

        onSetMapMode = function(mode)
            GameState.mapMode = mode
            -- 地形模式（2026-09-19 用户：「文化」按钮改「地形」）：
            --   只设 mapMode —— 地形色/省界都在 MapRenderer 的 LUT 里按 mapMode 判断
            if mapWidget_ then mapWidget_.lutDirty_ = true end
            if mode == "ally" and not GameState.allyViewFactionId then
                GameState.allyViewFactionId = GameState.playerFactionId
            end
            local names = {
                political = "政治", region = "地区", war = "战争",
                ally = "盟友", resource = "资源", terrain = "地形",
            }
            GameState.addMessage("切换到" .. (names[mode] or mode) .. "模式", "system")
        end,

        onZoomIn = function()
            if mapWidget_ and mapWidget_.zoomIn then
                mapWidget_:zoomIn()
            end
        end,

        onZoomOut = function()
            if mapWidget_ and mapWidget_.zoomOut then
                mapWidget_:zoomOut()
            end
        end,

        -- 和平会议：已选省份同步到地图金色高亮
        onPeaceSelectionChanged = function(ids)
            if not mapWidget_ then return end
            local set = {}
            for _, pid in ipairs(ids or {}) do
                set[pid] = true
            end
            mapWidget_.peaceSelectedIds = set
        end,

        -- 和平条约打开：镜头聚焦到被索取方领土 + 开启地图涂抹选省
        -- （仅 propose 模式开启涂抹；respond 模式只是展示条款，不拦截地图交互）
        onPeaceDialogOpened = function(cfg, gs)
            if not mapWidget_ then return end
            local isPropose = cfg and cfg.mode == "propose"
            mapWidget_.paintEnabled = isPropose
            if isPropose and cfg.terms then
                local ids = {}
                for _, item in ipairs(cfg.terms.provinceList or {}) do
                    ids[#ids + 1] = item.id
                end
                mapWidget_:focusTerritory(ids, { paddingRatio = 0.12, maxZoom = 3.0 })
            end
        end,

        -- 和平条约关闭：关闭地图涂抹选省
        onPeaceDialogClosed = function()
            if not mapWidget_ then return end
            mapWidget_.paintEnabled = GameUI.isActMode()   -- 条约关了，但国交行动模式可能还开着
        end,

        onSave = function()
            -- 打开存档位面板选择保存位置（空位直接存，覆盖需确认）
            GameUI.hideSettings()
            ShowSaveSlots("save")
        end,

        onLoadGame = function()
            GameUI.hideSettings()
            ShowSaveSlots("load")
        end,

        -- 换视角（2026-09-15）：同一局里换国家 / 切看海，**世界原样不动**（清单 E ③）
        --   两个入口都先关掉设置面板：切看海是**原地**换（UI 根不换），
        --   不关的话设置面板会一直盖在游戏上。
        onSwitchFaction = function()
            GameUI.hideSettings()
            ShowSwitchFaction()
        end,

        onSpectate = function()
            GameUI.hideSettings()
            SwitchViewFaction(nil)
        end,

        onToggleMusic = function(on)
            print("[Main] 音乐 " .. (on and "开" or "关") .. "（音乐系统开发中）")
        end,

        onExitToMenu = function()
            print("[Main] 返回主菜单")
            ShowMainMenu()
        end,
    })

    -- 声明式 UI 宿主（2026-09-13）：挂覆盖层 + 注册"游戏能做的动作"
    --   面板描述在 data/Panels.lua（模组可照样加自己的）
    do
        local UIPanelHost = require("ui.UIPanelHost")
        require("data.Panels")                      -- 注册内置面板描述
        UIPanelHost.attach(gameUIPanel_)
        UIPanelHost.registerAction("speed_up", function()
            TimeSystem.increaseSpeed(); GameState.paused = false
        end)
        UIPanelHost.registerAction("speed_down", function()
            TimeSystem.decreaseSpeed(); GameState.paused = false
        end)
        UIPanelHost.registerAction("toggle_pause", function()
            TimeSystem.togglePause()
        end)
        UIPanelHost.registerAction("open_policy", function()
            UIPanelHost.close()
            if GameUI.togglePolicyPanel then GameUI.togglePolicyPanel() end
        end)
        UIPanelHost.registerAction("focus_province", function(arg)
            local pid = tonumber(arg)
            if pid and mapWidget_ and mapWidget_.focusProvince then
                UIPanelHost.close()
                mapWidget_:focusProvince(pid, 2.0)
            end
        end)
        print("[Main] 声明式 UI 宿主已挂载（面板：" .. tostring(#require("ui.UIDesc").list()) .. " 块）")
    end

    -- Build root: map behind, UI overlays in front
    -- 根面板给不透明深色（2026-09-13）：原来透明的（3D 时代防盖住 3D 地图层），
    -- 3D 废弃后透明区在手机上会透出平台白底（实测底部 19px 一条）
    uiRoot_ = UI.Panel {
        id = "gameRoot",
        width = "100%",
        height = "100%",
        backgroundColor = { 12, 18, 30, 255 },
        children = {
            -- Map occupies full screen
            mapWidget_,
            -- UI overlay on top (pointerEvents = box-none for pass-through)
            gameUIPanel_,
        }
    }

    UI.SetRoot(uiRoot_)
end

--- 一次性建好整个游戏界面（地图 widget + UI 覆盖层）
function BuildGameUI()
    BuildMapWidget()
    BuildGameOverlays()
end
-- ============================================================================
-- Province Click Handler
-- ============================================================================

-- ============================================================================
-- 国交行动（2026-09-16 · 用户："点别国要能暗杀/间谍…不只是宣战"，
--   且"外交面板点一个行动 → 回地图点/涂抹国家直接执行"）
-- ============================================================================

--- 本次涂抹已经处理过的国家（避免涂一下刷十条宣战；松开时清空）
actPaintedFactions_ = {}

--- 当前国交行动模式（nil = 不在模式里）
local actMode_ = nil   --[[@as table|nil]]

--- 是否正处于国交行动（点地图执行宣战/改善关系…）
---@return boolean
function IsActMode()
    return actMode_ ~= nil
end

--- 该省能不能作为"国交行动"的目标（涂抹起点判定 + 点击过滤都用它）
---@param provinceId number|nil
---@return boolean
function IsActModeTarget(provinceId)
    if not provinceId or not actMode_ then return false end
    local prov = GameState.getProvince(provinceId)
    if not prov or prov.isWasteland then return false end
    -- 只能对"别人家的省"动手（自己的省/无主地跳过）
    return prov.ownerId ~= nil and prov.ownerId ~= GameState.playerFactionId
end

--- 执行一条国交行动（按 id 分发；没实现的给明确提示）
---@param actionId string
---@param targetFactionId number
---@return boolean handled
function RunInteraction(actionId, targetFactionId)
    local Interactions = require("data.Interactions")
    local act = Interactions.get(actionId)
    local target = GameState.getFaction(targetFactionId)
    local tname = target and target.name or "?"
    if not act then return false end

    if not act.impl then
        -- 用户："先把内容做出来，能不能用先不管" → 摆出来，点了明确说没开放
        print(string.format("[国交] %s → %s（尚未开放）", act.name, tname))
        GameState.addMessage("「" .. act.name .. "」尚未开放：" .. act.desc, "info")
        return true
    end

    local pid = GameState.playerFactionId
    if actionId == "war" then
        local ok, reason = DiplomacySystem.declareWar(GameState, pid, targetFactionId)
        print(string.format("[国交] 宣战 → %s ok=%s %s", tname, tostring(ok), tostring(reason or "")))
        if ok then
            GameState.addMessage("向 " .. tname .. " 宣战！", "war")
            GameUI.forceRefreshWarList(GameState)
        else
            GameState.addMessage("无法宣战：" .. tostring(reason), "warning")
        end
    elseif actionId == "improve" then
        local ok, reason = DiplomacySystem.improveRelation(GameState, pid, targetFactionId)
        print(string.format("[国交] 改善关系 → %s ok=%s %s", tname, tostring(ok), tostring(reason or "")))
        if ok then
            GameState.addMessage("已遣使改善与 " .. tname .. " 的关系", "diplomacy")
        else
            GameState.addMessage("改善关系失败：" .. tostring(reason), "warning")
        end
    elseif actionId == "peace" then
        local ok, terms = DiplomacySystem.preparePeaceOffer(GameState, pid, targetFactionId)
        print(string.format("[国交] 求和 → %s ok=%s", tname, tostring(ok)))
        if not ok then
            GameState.addMessage("无法求和：" .. tostring(terms), "warning")
            return true
        end
        local chance = WarSystem.getPeaceAcceptChance(GameState, pid, targetFactionId)
        GameUI.showPeaceDialog(GameState, {
            mode = "propose", proposerId = pid, targetId = targetFactionId,
            terms = terms, chance = chance,
        })
    end
    return true
end

--- 地图上涂/点到某个省 → 对该省所属国家执行当前行动
---@param provinceId number
---@param isDrag boolean 是否来自"涂抹"（涂抹时每个国家只触发一次）
function RunInteractionOnProvince(provinceId, isDrag)
    if not actMode_ then return end
    local prov = GameState.getProvince(provinceId)
    if not prov or not prov.ownerId then return end
    if prov.ownerId == GameState.playerFactionId then return end
    if isDrag then
        if actPaintedFactions_[prov.ownerId] then return end
        actPaintedFactions_[prov.ownerId] = true
    end
    RunInteraction(actMode_.id, prov.ownerId)
end

--- 进入国交行动模式（外交面板点了某个行动 → 关面板 → 回地图点/涂抹）
---@param actionId string
function EnterActMode(actionId)
    local Interactions = require("data.Interactions")
    local act = Interactions.get(actionId)
    if not act then return end
    actMode_ = act
    actPaintedFactions_ = {}
    GameUI.hideDiplomacy()
    GameUI.showActBanner(act.name, act.desc, act.paintable)
    if mapWidget_ then
        mapWidget_.paintEnabled = act.paintable   -- 可涂抹的行动才接管拖动（否则保持拖地图）
    end
    print("[Main] 进入国交行动模式：" .. act.id)
end

--- 退出国交行动模式
function ExitActMode()
    if not actMode_ then return end
    print("[Main] 退出国交行动模式：" .. actMode_.id)
    actMode_ = nil
    actPaintedFactions_ = {}
    GameUI.hideActBanner()
    if mapWidget_ then
        mapWidget_.paintEnabled = GameUI.isPeacePickMode()
    end
end

function OnProvinceClicked(provinceId)
    if not provinceId then
        GameUI.hideProvincePanel()
        GameUI.hideUnitPanel()      -- 点空白：军队面板一起收（2026-09-23）
        -- 点空白 = 彻底取消选中：地图上的省份高亮 / 军队金光一起熄灭（2026-09-23）
        if mapWidget_ and mapWidget_.clearSelectionHighlight then
            mapWidget_:clearSelectionHighlight()
        end
        return
    end

    -- 征召军队的"选地区"模式（2026-09-19）：点地图选省 → 回填弹窗，不触发别的面板
    if GameUI.isArmyPickMode and GameUI.isArmyPickMode() then
        GameUI.setArmyProvince(provinceId)
        return
    end

    local prov = GameState.getProvince(provinceId)
    if not prov then return end

    -- 国交行动模式：点地图上的国家 = 对该国执行这个行动（宣战/改善关系…）
    if actMode_ then
        if IsActModeTarget(provinceId) then
            RunInteractionOnProvince(provinceId, false)
        else
            GameState.addMessage("请点击别国的领土", "info")
        end
        return
    end

    -- 和平会议选省模式：点击地图敌省 = 加入/移出割让清单（HOI4 式）
    if GameUI.isPeacePickMode() then
        GameUI.togglePeaceProvincePick(provinceId)
        return
    end

    -- 沙漠废土不可点击（2026-09-01）：不显示面板
    if prov.isWasteland then
        GameUI.hideProvincePanel()
        GameUI.hideUnitPanel()
        return
    end

    -- 盟友模式：点击某个国家 → 以其为视角着色（2026-09-01）
    if GameState.mapMode == "ally" and prov.ownerId then
        GameState.allyViewFactionId = prov.ownerId
    end

    -- Update map selection
    if mapWidget_ and mapWidget_.setSelectedProvince then
        mapWidget_:setSelectedProvince(provinceId)
    end

    -- Show province info panel
    GameUI.showProvincePanel(provinceId, prov)

    -- 军队面板**只从旗子进**（2026-09-23 用户："我点一个区块会自动相当于点那个军队，这是错误"）：
    --   点省份本身不再自动弹军队面板；顺手把之前开着的收起、军队金光清掉
    --   （军队面板入口 = 点地图上的旗子；行军面板里点"停止"也会转成驻军形态继续显示）
    GameUI.hideUnitPanel()
    if mapWidget_ and mapWidget_.clearArmyHighlight then
        mapWidget_:clearArmyHighlight()
    end

    print("[Main] 选中省份: " .. prov.name .. " (ID:" .. provinceId .. ")")
end

-- ============================================================================
-- Time Callbacks
-- ============================================================================

function OnNewMonth(t)
    -- 0. 人物月度推进（2026-09-28）：历练倒计时、阴谋冷却
    do
        local CS = require("systems.CharacterSystem")
        CS.processMonthTraining(GameState)
        CS.processMonthSchemes(GameState)
    end

    -- 1. Economy tick
    --   SHOT_NOECON=1 → **跳过**经济结算（离屏验证：经济"关掉"之后，
    --     下面的"每月资源结算"还照样跑 —— 这就是洞 3 要证的事）
    if not (os.getenv and os.getenv("SHOT_NOECON")) then
        EconomySystem.processMonth(GameState)
    else
        print("[Main] SHOT_NOECON：已跳过经济结算（模拟「经济模组被关掉」）")
    end

    -- 1.5 资源注册表：结算"每月 +N"的注册型资源（2026-09-14 从经济系统挪出来）
    --   为什么挪：**经济是模组（能关），资源结算属于插座（本体的一部分）**。
    --     留在经济里 → 经济一关，所有模组的"每月 +N"全停（"每天 +N"却没事）。
    --   顺序没变：仍在经济结算之后 → incomeMonth 的公式照样能读到本月结算完的金/粮/人口。
    --   （"每天 +N"的对应逻辑在 OnNewDay 里，一直是本体在管）
    local Resources = require("data.Resources")
    for _, faction in pairs(GameState.factions) do
        if faction.alive then
            Resources.settleMonthly(GameState, faction)
        end
    end

    -- 2. Diplomacy monthly update
    DiplomacySystem.processMonthlyDiplomacy(GameState)

    -- 3. AI decisions for all non-player factions
    for _, faction in pairs(GameState.factions) do
        if faction.alive and faction.id ~= GameState.playerFactionId then
            AIManager.processAI(GameState, faction.id)
        end
    end

    -- 4. Reset monthly recruitment counters
    if GameState.recruitedThisMonth then
        for k in pairs(GameState.recruitedThisMonth) do
            GameState.recruitedThisMonth[k] = nil
        end
    end

    -- 5. 变法副作用（稳定惩罚倒计时）
    PolicySystem.processMonthly(GameState)

    -- 5.5 科技系统（2026-09-16）：推进研究进度 / AI 开新研究
    require("systems.TechSystem").monthlyTick(GameState)

    -- 每月让交战各方继续向前线集结/推进（2026-09-17）：
    -- 宣战那一刻只走一步，内陆的兵要一个月一个月地往前挪，否则还是"只有边境在打"。
    do
        local WarSystem = require("systems.WarSystem")
        local MilitarySystem = require("systems.MilitarySystem")
        local seen = {}
        for _, w in ipairs(WarSystem.getWars(GameState)) do
            -- 战争诊断（2026-09-17）：每月打印双方分数 + 占领情况，用来定位"分数不动"
            do
                local W = require("systems.WarSystem")
                local occ = 0
                for _, pv in pairs(GameState.provinces) do
                    if pv.occupiedBy then occ = occ + 1 end
                end
                print(string.format("[WarDBG] %s vs %s | 攻方分=%.1f 守方分=%.1f | 全图被占省=%d",
                    (GameState.factions[w.aId] or {}).name or "?",
                    (GameState.factions[w.dId] or {}).name or "?",
                    W.getScore(GameState, w, w.aId), W.getScore(GameState, w, w.dId), occ))
            end
            for _, fid in ipairs({ w.aId, w.dId }) do
                if not seen[fid] then
                    seen[fid] = true
                    MilitarySystem.launchOffensive(GameState, fid)
                end
            end
        end
    end

    -- 6. Check victory/defeat conditions
    CheckGameOver()

    -- 6.5 文化系统（2026-09-13）：每月检查异文化叛乱苗头（只报信，交给钩子/事件处理）
    require("systems.CultureSystem").processMonthly(GameState)

    -- 6.6 核心系统（2026-09-16）：占有满 3 年得核心 / 失地满 100 年过期 / 每省最多 5 个
    require("systems.CoreSystem").processMonthly(GameState)

    -- 7. 事件系统（2026-09-13）：抽事件 + 临时修正到期
    --    （抽到的事件只进队列，由界面弹窗；玩家选完才应用效果）
    require("systems.EventSystem").processMonthly(GameState)

    -- 8. 脚本钩子（2026-09-13）：给"每月"开一个口子（资源/事件/将来的模组挂这里）
    require("systems.Hooks").fire("month", { gameState = GameState, time = t })

    -- Debug log（无势力模式不显示势力资源）
    local pf = GameState.getPlayerFaction()
    if pf then
        print("[Month] " .. TimeSystem.formatDate()
            .. " | 金:" .. math.floor(pf.gold)
            .. " 粟:" .. math.floor(pf.food)
            .. " 兵:" .. pf.armySize)
    end
end

function OnNewDay(t)
    -- （军队行军已改为每帧推进，见 HandleUpdate；
    --   政策的"实施进度"2026-09-16 已废弃 —— 政策点即生效，没有再按天推进的东西）

    -- 资源注册表：结算"每天 +N"的注册型资源（2026-09-13）
    local Resources = require("data.Resources")
    for _, faction in pairs(GameState.factions) do
        if faction.alive then
            Resources.settleDaily(GameState, faction)
        end
    end
end

-- ============================================================================
-- Victory / Defeat Check
-- ============================================================================

function CheckGameOver()
    -- 🔧 无势力模式（玩家未选择势力）：不判定胜负
    if not GameState.playerFactionId then return end
    local player = GameState.getPlayerFaction()
    if not player or not player.alive then
        currentPhase_ = "gameover"
        GameState.addMessage("你的势力已被消灭！游戏结束。", "system")
        TimeSystem.pause()
        ShowGameOverScreen(false)
        return
    end

    -- Check if player controls all provinces
    local allOwned = true
    for _, prov in pairs(GameState.provinces) do
        if prov.ownerId ~= GameState.playerFactionId then
            allOwned = false
            break
        end
    end

    if allOwned then
        currentPhase_ = "gameover"
        GameState.addMessage("天下一统！你赢得了最终胜利！", "system")
        TimeSystem.pause()
        ShowGameOverScreen(true)
    end
end

function ShowGameOverScreen(victory)
    local title = victory and "天下一统！" or "社稷倾覆…"
    local subtitle = victory
        and "你统一了天下，成为真正的霸主！"
        or "你的势力已被消灭，历史将铭记你的尝试…"
    local titleColor = victory and {255, 215, 0, 255} or {200, 60, 60, 255}

    local overlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = {0, 0, 0, 180},
        children = {
            UI.Panel {
                padding = 40,
                gap = 16,
                backgroundColor = {20, 25, 35, 240},
                borderRadius = 16,
                borderWidth = 2,
                borderColor = titleColor,
                alignItems = "center",
                children = {
                    UI.Label { text = title, fontSize = 32, fontColor = titleColor },
                    UI.Label { text = subtitle, fontSize = 16, fontColor = {200, 210, 230, 220} },
                    UI.Label { text = TimeSystem.getShortDate(), fontSize = 14, fontColor = {160, 170, 190, 200} },
                    UI.Button {
                        text = "重新开始",
                        variant = "primary",
                        marginTop = 16,
                        onClick = function()
                            StartGame(GameState.playerFactionId)
                        end,
                    },
                }
            }
        }
    }

    -- Add overlay to current root
    if uiRoot_ and uiRoot_.AddChild then
        uiRoot_:AddChild(overlay)
    end
end

-- ============================================================================
-- Frame Update
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 国交行动模式：右键 = 取消（和 ESC 一样，手机上也能用两指/长按以外的方式退出）
    if GameUI.isActMode() and input:GetMouseButtonPress(MOUSEB_RIGHT) then
        ExitActMode()
    end

    -- 离屏测量：SHOT_PLAYSET_MEASURE 排的倒计时到了 → 量按钮行（这时的布局才是算好的）
    if measurePlaysetCountdown_ then
        measurePlaysetCountdown_ = measurePlaysetCountdown_ - 1
        if measurePlaysetCountdown_ <= 0 then
            measurePlaysetCountdown_ = nil
            local ov = UI.FindById and UI.FindById("playsetOverlay")
            local apply = ov and ov:FindById("playsetApplyBtn")
            local row = apply and apply.parent          -- Widget 上就是 .parent 字段
            if row and row.children then
                local rl = row:GetAbsoluteLayout()
                print(string.format("[Measure] 按钮行 x=%.1f w=%.1f", rl.x, rl.w))
                for i, c in ipairs(row.children) do
                    local cl = c:GetAbsoluteLayout()
                    print(string.format("[Measure]   #%d x=%.1f w=%.1f", i, cl.x, cl.w))
                end
            else
                print("[Measure] ⚠️ 找不到按钮行")
            end
        end
    end

    -- 离屏：SHOT_RECT=<控件id> 排的倒计时到了 → 打印它的绝对矩形（连父容器一起）
    --   用途：布局出问题时**量**，别靠肉眼估 —— 比如"文字被容器切掉"，
    --   量出 内容高 > 容器高 就实锤了，还能知道差多少。
    --   排倒计时是因为控件刚建时布局还没算（Yoga 要等一帧），当场量全是 0。
    --   ⚠️ "上膛"写在 Start() 里（不能写这，否则每帧都重置，倒计时永远到不了）
    if measureRectCountdown_ then
        measureRectCountdown_ = measureRectCountdown_ - 1
        if measureRectCountdown_ <= 0 then
            measureRectCountdown_ = nil
            local id = os.getenv("SHOT_RECT")
            local w = UI.FindById and UI.FindById(id)
            if w then
                local r = w:GetAbsoluteLayout()
                print(string.format("[Rect] %s  x=%.1f y=%.1f w=%.1f h=%.1f", id, r.x, r.y, r.w, r.h))
                -- 祖先链（absolute 定位出问题时靠这个看它到底相对谁算的）
                local depth, anc = 0, w.parent
                while anc and depth < 6 do
                    local al = anc:GetAbsoluteLayout()
                    if al then
                        print(string.format("[Rect]   ↑祖先%d x=%.1f y=%.1f w=%.1f h=%.1f",
                            depth + 1, al.x, al.y, al.w, al.h))
                    end
                    anc = anc.parent
                    depth = depth + 1
                end
                if w.children then
                    for i, c in ipairs(w.children) do
                        local cl = c:GetAbsoluteLayout()
                        if cl then
                            print(string.format("[Rect]   子#%d y=%.1f h=%.1f（底=%.1f）",
                                i, cl.y, cl.h, cl.y + cl.h))
                        end
                    end
                end
            else
                print("[Rect] ⚠️ 找不到控件 " .. tostring(id))
            end
        end
    end

    -- 离屏：SHOT_TAP 排的倒计时到了 → 注入一次真实点击（和真机点同一条链路）
    if tapCountdown_ and tapQueue_ and #tapQueue_ > 0 then
        tapCountdown_ = tapCountdown_ - 1
        if tapCountdown_ <= 0 then
            local p2 = table.remove(tapQueue_, 1)
            local tx, ty = p2[1], p2[2]
            if #tapQueue_ == 0 then tapQueue_ = nil end
            tapCountdown_ = 20
            local hit = UI.FindWidgetAt and UI.FindWidgetAt(tx, ty)
            local hitId = "?"
            if hit then
                hitId = tostring(hit.id or (hit.props and hit.props.id) or hit.className or "widget")
            end
            if p2[3] then
                -- 拖动手势：按下 → 分步移动（UI 每步都会派发 OnPointerMove）→ 抬起
                print(string.format("[Tap] 注入拖动 (%d,%d) → (%d,%d)", tx, ty, p2[3], p2[4]))
                UI.HandleMouseDown(tx, ty, MOUSEB_LEFT)
                for i = 1, 6 do
                    UI.HandleMouseMove(tx + (p2[3] - tx) * i / 6, ty + (p2[4] - ty) * i / 6)
                end
                UI.HandleMouseUp(p2[3], p2[4], MOUSEB_LEFT)
                return
            end
            print(string.format("[Tap] 注入点击 (%d,%d) → hit test 命中：%s", tx, ty, hitId))
            UI.HandleMouseDown(tx, ty, MOUSEB_LEFT)
            UI.HandleMouseUp(tx, ty, MOUSEB_LEFT)
            local selId = mapWidget_ and mapWidget_.getSelectedProvince and mapWidget_:getSelectedProvince()
            local Provinces = require("data.Provinces")
            local p = selId and Provinces.byId[selId]
            -- 命中的 widget 就是地图（选国页/游戏内都是同一类 widget）→ 直接从它读状态
            local mw = hit
            print(string.format("[Tap] 点击后：地图选中省 = %s ｜ 粒度 = %s ｜ 只选国家 = %s",
                p and (tostring(p.name) .. "(" .. tostring(selId) .. ")") or "无",
                tostring((mw and mw.selectionLevel_) or (mapWidget_ and mapWidget_.selectionLevel_) or "无"),
                tostring((mw and mw.factionSelectOnly) or false)))
            local titleW = UI.FindById and UI.FindById("provName")
            if titleW then
                print("[Tap] 省份面板标题 = " .. tostring(titleW.text))
            else
                print("[Tap] 省份面板标题控件未找到（面板未打开？）")
            end
        end
    end

    -- 离屏：SHOT_SWITCH_DELAY 排的倒计时到了 → 执行换视角
    --   （放这儿是为了让旧视角的界面先画出来几帧，否则照不出"面板停在旧视角"）
    if switchCountdown_ then
        switchCountdown_ = switchCountdown_ - 1
        if switchCountdown_ <= 0 then
            switchCountdown_ = nil
            local fn = switchThunk_
            switchThunk_ = nil
            if fn then fn() end
        end
    end

    -- 音乐交叉淡化每帧驱动（主菜单/游戏均需）
    MusicManager.update(dt)

    -- 主菜单入场动画驱动
    MainMenu.update(dt)

    -- 编辑器帧驱动（首帧全图对焦等）
    if currentPhase_ == "editor" and ScenarioEditor.onUpdate then
        ScenarioEditor.onUpdate(dt)
    end

    if currentPhase_ ~= "playing" then return end

    -- Advance game time (this triggers hour/day/month/year callbacks)
    TimeSystem.update(dt)

    -- 军队行军 + 战斗：每帧推进（2026-09-01，平滑移动 + 保底现实秒数 + 持续战斗）
    local _, _, hoursPerSec = TimeSystem.getSpeed()
    if not TimeSystem.isPaused() and hoursPerSec then
        MilitarySystem.updateArmies(GameState, dt * hoursPerSec, dt)
        MilitarySystem.processBattles(GameState, dt * hoursPerSec)
    end

    -- 战争警报（弹框 + 暂停）已于 2026-09-18 删除（用户："删掉战争警报的暂停 + 弹红框，
    -- 改右上角普通通知"）：战斗开始/结束只发 notify 消息 → 挂到顶栏下右侧的通知条。
    -- 时间**不再被战斗打断**；玩家想议和时点右下角战旗进和谈。

    -- AI 求和玩家：弹出和平谈判窗口等玩家决定
    --
    -- ⚠️ 必须核对这份和谈**是发给"现在这个玩家国家"的**（2026-09-15 换视角）：
    --    pendingPeace 挂在全局状态里，换国家/切看海之后它**不会自己消失**。
    --    只判"有没有 pendingPeace"的话：换成别国后这个旧弹窗照样弹，
    --    而点「接受/拒绝」走的是 respondPendingPeace，里头按 `pending.targetId` 结算
    --    —— 也就是**以旧国家的身份**割地赔款，替别国做了主。
    --    加这一条后：旧弹窗自动不显示，那份和谈仍留在状态里，换回去还会再弹。
    local pendingPeace = GameState.pendingPeace
    if pendingPeace and pendingPeace.targetId == GameState.playerFactionId
        and gameUIPanel_
        and not GameUI.isPeaceDialogVisible() then
        GameUI.showPeaceDialog(GameState, {
            mode = "respond",
            proposerId = pendingPeace.proposerId,
            targetId   = pendingPeace.targetId,
            terms      = pendingPeace.terms,
        })
        -- 诊断（2026-09-19）：和约弹窗应让游戏暂停
        print("[Peace] 和约弹窗打开：暂停=" .. tostring(TimeSystem.isPaused()))
    end

    -- 事件处理（2026-09-16 改版 · 用户拍板）：
    --   🔴 时间不暂停；事件挂成"顶栏下的小条"，点开才弹框（是否自动展开由设置开关决定）；
    --   关掉弹框 ≠ 放弃事件——小条常驻，直到做出选择
    --
    -- ⚠️ 和上面的和谈一样，要核对事件**是发给"现在这个玩家国家"的**（2026-09-15 换视角）：
    --    事件在生成那一刻记下了 factionId，换国家后这个旧事件不会自己消失。
    --    不核对的话：换成晋国了，齐国的旧事件还弹出来；点选项走 EventSystem.choose，
    --    里头按 `p.factionId` 结算 —— 效果落到齐国头上，等于替别国做抉择。
    do
        local EventSystem = require("systems.EventSystem")
        -- 2026-09-16：支持多条——过滤出"发给当前玩家"的事件（换视角后旧玩家的遗留事件不挂）
        local pendingAll = EventSystem.getPendingList() or {}   --[[@as table[] ]]
        local list = {}
        for _, p in ipairs(pendingAll) do
            if p.factionId == GameState.playerFactionId then
                list[#list + 1] = p
            end
        end
        GameUI.updatePendingEvent(list, GameUI.isEventAutoPopup())

        -- SHOT_EVENT_OPEN=1 → 把队首待处理事件弹出来（离屏看正文：如"变法之议"的随机提议人）
        if os.getenv and os.getenv("SHOT_EVENT_OPEN") == "1" and not GameUI._shotEventOpenDone then
            GameUI._shotEventOpenDone = true
            local p = EventSystem.getPending()
            if p then
                GameUI.showEventDialog(p)
                print("[Main] SHOT_EVENT_OPEN：已弹出队首事件")
            end
        end

        -- SHOT_NOTICE=1 → 打开一张"通知详情"弹窗（离屏验证：居中 / 大小），只开一次
        if os.getenv and os.getenv("SHOT_NOTICE") == "1" and not GameUI._shotNoticeDone then
            GameUI._shotNoticeDone = true
            GameUI.showNoticeDialog("这是一条测试通知：验证详情弹窗的居中位置与大小。")
        end


        -- SHOT_TECHSTART=<科技id> → 先开始研究（**必须排在"打开面板"之前**，否则面板显示的还是旧状态）
        if os.getenv and os.getenv("SHOT_TECHSTART") and not GameUI._shotTechStartDone then
            GameUI._shotTechStartDone = true
            local TechSystem = require("systems.TechSystem")
            local f = GameState.getPlayerFaction and GameState.getPlayerFaction()
            local tid = os.getenv("SHOT_TECHSTART")
            if f and tid then
                TechSystem.ensureRegistered()
                local ok, err = TechSystem.startTech(GameState, f, tid)
                print("[Main] SHOT_TECHSTART=" .. tostring(tid) .. " → " .. (ok and "开始研究" or tostring(err)))
            end
        end
        -- SHOT_MAPMODE=<模式id> → 切地图模式（离屏验证地形/战争等视图，2026-09-19）
        --   只设 mapMode：地形色/省界都在 LUT 里按 mapMode 判断，签名一变自动重建
        if os.getenv and os.getenv("SHOT_MAPMODE") and not GameUI._shotMapModeDone then
            GameUI._shotMapModeDone = true
            GameState.mapMode = os.getenv("SHOT_MAPMODE")
            if mapWidget_ then mapWidget_.lutDirty_ = true end
            print("[Main] SHOT_MAPMODE=" .. tostring(GameState.mapMode))
        end
        -- SHOT_ARMY=1 → 打开征召军队弹窗（离屏验证布局，2026-09-19）
        if os.getenv and os.getenv("SHOT_ARMY") == "1" and not GameUI._shotArmyDone then
            GameUI._shotArmyDone = true
            GameUI.toggleArmyPanel()
            -- 附加 SHOT_ARMY_UNITLIST=1 → 展开兵种下拉（验证灰名/列表布局）
            if os.getenv("SHOT_ARMY_UNITLIST") == "1" then
                GameUI.toggleArmyUnitList(true)
            end
        end
        -- SHOT_SPEEDMENU=1 → 打开时间流速弹窗（离屏验证 7 档布局）
        if os.getenv and os.getenv("SHOT_SPEEDMENU") == "1" and not GameUI._shotSpeedDone then
            GameUI._shotSpeedDone = true
            GameUI.toggleSpeedMenu()
        end
        -- SHOT_TECH=1 → 打开科技面板（离屏验证面板布局）
        -- SHOT_TECHCAT=<类id> → 顺便切到指定分类（wealth/people/war/culture/system/craft）
        if os.getenv and os.getenv("SHOT_TECH") == "1" and not GameUI._shotTechDone then
            GameUI._shotTechDone = true
            GameUI.toggleTechPanel()
            local cat = os.getenv("SHOT_TECHCAT")
            if cat and GameUI.onTechCatClick then
                GameUI.onTechCatClick(cat)
                print("[Main] SHOT_TECHCAT=" .. cat)
            end
        end
        -- 政策面板开着时：刷新变法区（未解锁的隐藏；2026-09-16）
        --   放"每帧"而不是 toggle 里——toggle 那条调用链之前没生效过（排查未果），每帧最稳；
        --   函数内有签名短路，不会白刷
        if GameUI.isPolicyPanelOpen and GameUI.isPolicyPanelOpen() then
            GameUI.refreshPolicyPanel(GameState)
        end

        -- SHOT_CLICK_REFORM=<变法id> → 先解锁、再模拟点它一下（验证 onClick 链路 + callbacks 传参修复）
        if os.getenv and os.getenv("SHOT_CLICK_REFORM") and not GameUI._shotClickReformDone then
            GameUI._shotClickReformDone = true
            local PolicySystem = require("systems.PolicySystem")
            local f = GameState.getPlayerFaction and GameState.getPlayerFaction()
            local rid = os.getenv("SHOT_CLICK_REFORM")
            if f then
                PolicySystem.unlockReform(GameState, f.id, rid)
                GameUI.togglePolicyPanel()
                local UI = require("urhox-libs/UI")
                local w = UI.FindById and UI.FindById("policyReform_" .. rid)
                if w and w.OnClick then
                    w:OnClick(nil)
                    print("[Main] SHOT_CLICK_REFORM 已点击：" .. rid)
                else
                    print("[Main] SHOT_CLICK_REFORM 没找到按钮：" .. rid)
                end
            end
        end

        -- SHOT_DIPLO=1 → 打开外交面板（看国交行动栏）
        if os.getenv and os.getenv("SHOT_DIPLO") and not GameUI._shotDiploDone then
            GameUI._shotDiploDone = true
            GameUI.toggleDiplomacy(GameState)
            print("[Main] SHOT_DIPLO：已打开外交面板")
        end

        -- SHOT_CORETEST=1 → 核心系统的算法自检（保留分 / 过期 / 上限裁剪），结果打日志
        if os.getenv and os.getenv("SHOT_CORETEST") and not GameUI._shotCoreTestDone then
            GameUI._shotCoreTestDone = true
            local CoreSystem = require("systems.CoreSystem")
            local TimeSystem = require("core.TimeSystem")
            CoreSystem.ensureInit(GameState)
            local year = select(1, TimeSystem.getTime())
            local pid = 985
            local p = GameState.provinces[pid]
            -- 7 个候选：寿命 / 失去时间 各不相同（fid 1..7 都是现存势力）
            local specs = {
                { fid = 1, life = 300, lost = 20 },   -- 周：长命 + 新近失去 → 该留
                { fid = 2, life = 150, lost = 60 },   -- 齐
                { fid = 3, life = 2,   lost = 10 },   -- 晋：短命 → 该裁
                { fid = 4, life = 400, lost = 90 },   -- 楚：长命但久远
                { fid = 5, life = 10,  lost = 95 },   -- 秦：短命又久远 → 该裁
                { fid = 6, life = 250, lost = 105 },  -- 鲁：超 100 年 → 该直接过期
                { fid = 7, life = 120, lost = 50 },   -- 宋
            }
            p.cores = {}
            for _, s in ipairs(specs) do
                local f = GameState.factions[s.fid]
                if f then
                    f.foundedYear = year - s.life
                    f.destroyedYear = year
                    f.culture = "华夏"
                    p.cores[s.fid] = { gainedYear = year - s.life, lostYear = year - s.lost }
                    print(string.format("[CoreTest] 候选 %s（%d）：存续 %d 年 · 失去 %d 年 → 分 %.1f",
                        tostring(f.name), s.fid, s.life, s.lost,
                        CoreSystem.scoreFor(GameState, s.fid, p.cores[s.fid], p, year)))
                end
            end
            p._coreLastOwner = p.ownerId
            CoreSystem.processMonthly(GameState)
            local left = {}
            for fid, _ in pairs(p.cores) do left[#left + 1] = tostring(fid) end
            table.sort(left)
            print("[CoreTest] 结算后还剩 " .. #left .. " 个核心：" .. table.concat(left, ","))
        end

        -- SHOT_REVOLT=<省id>,<核心势力id>[,dead|none] → 强制该省叛乱（离屏验证复国/自立）
        --   dead：把核心势力先"判死"（验**复国**路径）
        --   none：不给任何核心（验**自立建新国** + 方位命名路径）
        if os.getenv and os.getenv("SHOT_REVOLT") and not GameUI._shotRevoltDone then
            GameUI._shotRevoltDone = true
            local sid, sfid, mode = os.getenv("SHOT_REVOLT"):match("^(%d+),?(%d*),?(%a*)$")
            local pid = tonumber(sid)
            local p = pid and GameState.provinces[pid]
            local CoreSystem = require("systems.CoreSystem")
            CoreSystem.ensureInit(GameState)
            if p then
                local ownerBefore = p.ownerId
                if mode == "none" then
                    p.cores = {}
                    print(string.format("[Main] SHOT_REVOLT：省 %d「%s」（%s 的）→ 无核心，走自立",
                        pid, tostring(p.name), tostring(ownerBefore)))
                else
                    local fid = tonumber(sfid)
                    p.cores = p.cores or {}
                    p.cores[fid] = { gainedYear = -770 }
                    if mode == "dead" then
                        local f = GameState.factions[fid]
                        f.alive = false
                        f.provinces = {}
                        f.destroyedYear = -760
                        print(string.format("[Main] SHOT_REVOLT：把「%s」判死（模拟已被灭）",
                            tostring(f.name)))
                    end
                    print(string.format("[Main] SHOT_REVOLT：省 %d「%s」（%s 的）核心=%s",
                        pid, tostring(p.name), tostring(ownerBefore), tostring(fid)))
                end
                CoreSystem.handleRebellion(GameState, pid)
                print(string.format("[Main] SHOT_REVOLT 结果：省 %d 现在属于「%s」",
                    pid, tostring(GameState.factions[p.ownerId] and GameState.factions[p.ownerId].name)))
            end
        end

        -- SHOT_SELF=1 → 打开「自身」面板（君主五维）
        if os.getenv and os.getenv("SHOT_SELF") and not GameUI._shotSelfDone then
            GameUI._shotSelfDone = true
            GameUI.toggleSelfPanel()
            print("[Main] SHOT_SELF：已打开自身面板")
        end

        -- SHOT_COURT=1[,<职位id>] → 打开「朝廷」面板；给了职位id就顺手任命一个人（验任命链路）
        if os.getenv and os.getenv("SHOT_COURT") and not GameUI._shotCourtDone then
            GameUI._shotCourtDone = true
            GameUI.toggleCourtPanel()
            local postId = os.getenv("SHOT_COURT"):match("^1,([%a_]+)$")   -- 职位 id 里有下划线
            -- 这几个是"切页"开关，不是职位 id，别拿去任命（否则日志刷"没有这个职位"）
            if postId == "harem" or postId == "ruler"
               or postId == "general" or postId == "consort" or postId == "office" then
                postId = nil
            end
            if postId then
                local CharacterSystem = require("systems.CharacterSystem")
                local pf = GameState.getPlayerFaction()
                local cands = pf and CharacterSystem.candidatesFor(GameState, pf.id) or {}
                if pf and cands[1] then
                    local ok, why = CharacterSystem.appoint(GameState, pf.id, postId, cands[1].id)
                    print(string.format("[Main] SHOT_COURT：任命 %s → %s（%s）",
                        tostring(cands[1].name), postId, tostring(ok and "成功" or why)))
                end
            end
            -- SHOT_COURT=1,<页名> → 顺手切到该页（验页签切换）
            --   页名：ruler（君主）/ harem（后宫）/ general（将军）
            local wantTab = os.getenv("SHOT_COURT"):match("^1,(%a+)$")
            local tabBtnId = ({
                ruler = "courtTabRulerBtn",
                harem = "courtTabConsortBtn",
                consort = "courtTabConsortBtn",
                general = "courtTabGeneralBtn",
                office = "courtTabOfficeBtn",
                talent = "courtTabTalentBtn",
            })[wantTab]
            if tabBtnId then
                local btn = UI.FindById(tabBtnId)
                if btn and btn.OnClick then
                    btn:OnClick(nil)
                    print("[Main] SHOT_COURT：已切到 " .. tostring(wantTab) .. " 页")
                end
            end
            GameUI.refreshCourtPanel(GameState)
            -- SHOT_COURT=1,detail → 再打开一个人物详情（验证详情弹层）
            local pfId = GameState.playerFactionId
            local courtEnv = os.getenv("SHOT_COURT") or ""
            if courtEnv:find("detail") and pfId then
                local target = nil
                for _, c in ipairs(require("systems.CharacterSystem").consortsOf(GameState, pfId)) do
                    target = UI.FindById("courtConsort_" .. tostring(c.id))
                    if target then break end
                end
                if target and target.OnClick then
                    target:OnClick(nil)
                    print("[Main] SHOT_COURT：已打开人物详情")
                end
            end
            print("[Main] SHOT_COURT：已打开朝廷面板")
        end

        -- SHOT_FLAGDEMO=1 → 打出「燕尾旗画廊」（1/2/3 字国名 + 不同排版，离屏看旗子画法）
        if os.getenv and os.getenv("SHOT_FLAGDEMO") and not GameUI._shotFlagDemoDone then
            GameUI._shotFlagDemoDone = true
            require("dev.FlagGallery").Start()
        end

        -- OCC_STYLE=1..4 → 被占领表现方案（离屏对比用；四种方案都做出来让用户挑）
        --   1=现状(压暗+占领方斜纹) 2=EU4强制明暗 3=HOI4铺满 4=铺满+省中心旗标
        if os.getenv and os.getenv("OCC_STYLE") and not GameUI._occStyleDone then
            GameUI._occStyleDone = true
            MapRenderer.SetOccupiedStyle(tonumber(os.getenv("OCC_STYLE")) or 1)
        end

        -- SHOT_OCCUPY_PROV=<省id|self>[,<占领方势力id>] → 直接把该省标成"被占领"
        --   （离屏看被占表现：压暗底 + 占领方粗斜纹 + 占领方描边；默认占领方=玩家）
        --   self = 玩家第一省；省略占领方时自动取"非玩家的第一个势力"
        --   （2026-09-19 加：验证"敌方占了我的省"这个玩家实际会遇到的场景）
        if os.getenv and os.getenv("SHOT_OCCUPY_PROV") and not GameUI._shotOccupyDone then
            GameUI._shotOccupyDone = true
            local sid, sby = os.getenv("SHOT_OCCUPY_PROV"):match("^([%w_]+),?(%d*)$")
            local id = tonumber(sid)
            local by = tonumber(sby)
            if not id and sid == "self" then
                local pf = GameState.getPlayerFaction()
                id = pf and pf.provinces and pf.provinces[1] or nil
                if id and not by then
                    for fid in pairs(GameState.factions) do
                        if fid ~= GameState.playerFactionId then by = fid break end
                    end
                end
            end
            by = by or GameState.playerFactionId
            local p = id and GameState.provinces[id]
            if p and by then
                p.occupiedBy = by
                local f = GameState.factions[by]
                print(string.format("[Main] SHOT_OCCUPY_PROV=%d 被 %s 占领", id,
                    tostring(f and f.name or by)))
            end
        end

        -- SHOT_PICKPROV=<省id> → 走真实回调"点一下这个省"（弹省份面板；看别国的国交行动按钮）
        if os.getenv and os.getenv("SHOT_PICKPROV") and not GameUI._shotPickProvDone then
            GameUI._shotPickProvDone = true
            local id = tonumber(os.getenv("SHOT_PICKPROV"))
            if id then
                OnProvinceClicked(id)
                print("[Main] SHOT_PICKPROV=" .. id)
                -- SHOT_PICKACT=<行动id> → 再点一下省份面板里的那个国交行动按钮
                local actId = os.getenv("SHOT_PICKACT")
                if actId and UI.FindById then
                    local w = UI.FindById("provAct_" .. actId)
                    if w and w.OnClick then
                        w:OnClick(nil)
                        print("[Main] SHOT_PICKACT=" .. actId)
                    else
                        print("[Main] ⚠️ SHOT_PICKACT：找不到按钮 " .. actId)
                    end
                end
            end
        end

        -- SHOT_ACTMODE=<行动id> → 进入国交行动模式（看横幅 + 地图待命状态）
        -- SHOT_ACTCLICK=<省id> → 走地图真实回调"点一下"该省（验证点国家即执行）
        -- SHOT_ACTPAINT=<省id>,<省id>,... → 模拟"涂抹"刷过这些省（验证批量执行 + 去重）
        if os.getenv and os.getenv("SHOT_ACTMODE") and not GameUI._shotActDone then
            GameUI._shotActDone = true
            EnterActMode(os.getenv("SHOT_ACTMODE"))
            local click = os.getenv("SHOT_ACTCLICK")
            local paint = os.getenv("SHOT_ACTPAINT")
            if click and mapWidget_ and mapWidget_.onPaintProvince then
                mapWidget_.onPaintProvince(tonumber(click))
                print("[Main] SHOT_ACTCLICK=" .. click)
            end
            if paint and mapWidget_ and mapWidget_.onPaintProvince then
                for id in string.gmatch(paint, "[^,]+") do
                    mapWidget_.onPaintProvince(tonumber(id), true)   -- true = 来自涂抹
                end
                if mapWidget_.onPaintEnd then mapWidget_.onPaintEnd() end
                print("[Main] SHOT_ACTPAINT=" .. paint)
            end
            -- SHOT_ACTEXIT=1 → 立刻退出模式（验证"取消"链路：横幅收起 + 不再拦地图点击）
            if os.getenv("SHOT_ACTEXIT") then
                ExitActMode()
                print("[Main] SHOT_ACTEXIT：退出后 isActMode=" .. tostring(GameUI.isActMode()))
            end
        end

        -- SHOT_CLICK_AXIS=<轴id>,<立场名> → 打开政策面板并模拟点该档位
        --   （2026-09-17：政策改成光谱轴后，验证"点完立刻生效 + 数值真的变"）
        if os.getenv and os.getenv("SHOT_CLICK_AXIS") and not GameUI._shotClickAxisDone then
            GameUI._shotClickAxisDone = true
            local spec = os.getenv("SHOT_CLICK_AXIS")
            local axisId, optId = spec:match("^([^,]+),(.+)$")
            GameUI.togglePolicyPanel()
            local PolicySystem = require("systems.PolicySystem")
            local pf = GameState.getPlayerFaction and GameState.getPlayerFaction()
            local g0 = pf and PolicySystem.getGoldModifier(pf) or 0
            local f0 = pf and PolicySystem.getFoodModifier(pf) or 0
            local UI = require("urhox-libs/UI")
            local w = axisId and optId and UI.FindById
                and UI.FindById("policyAxis_" .. axisId .. "_" .. optId)
            if w and w.OnClick then
                w:OnClick(nil)
                local g1 = pf and PolicySystem.getGoldModifier(pf) or 0
                local f1 = pf and PolicySystem.getFoodModifier(pf) or 0
                print(string.format(
                    "[Main] SHOT_CLICK_AXIS 已点击：%s/%s（金钱倍率 %.3f → %.3f，粮草倍率 %.3f → %.3f）",
                    axisId, optId, g0, g1, f0, f1))
            else
                print("[Main] SHOT_CLICK_AXIS 没找到按钮：" .. tostring(spec))
            end
        end

        -- SHOT_POLICY=1 → 打开政策面板（离屏验证：无变法时显示"无"）
        -- 2026-09-16：从 Start 挪到这里——Start 阶段 UI 还没装配，togglePolicyPanel 会撞空
        if os.getenv and os.getenv("SHOT_POLICY") and not GameUI._shotPolicyDone then
            GameUI._shotPolicyDone = true
            GameUI.togglePolicyPanel()
            print("[Main] SHOT_POLICY：已打开政策面板")
        end
        -- SHOT_REFORM=<变法id> → 直接解锁该变法并打开政策面板（验证"有人提出→变法区出现"）
        if os.getenv and os.getenv("SHOT_REFORM") and not GameUI._shotReformDone then
            GameUI._shotReformDone = true
            local PolicySystem = require("systems.PolicySystem")
            local f = GameState.getPlayerFaction and GameState.getPlayerFaction()
            if f then
                PolicySystem.unlockReform(GameState, f.id, os.getenv("SHOT_REFORM"))
                GameUI.togglePolicyPanel()
                print("[Main] SHOT_REFORM=" .. tostring(os.getenv("SHOT_REFORM")) .. " 已解锁并打开政策面板")
            end
        end
        -- SHOT_TECHCAT=<类id> → 切到该类（验证各页布局，如 craft=技艺）
        if os.getenv and os.getenv("SHOT_TECHCAT") and not GameUI._shotTechCatDone then
            GameUI._shotTechCatDone = true
            GameUI.onTechCatClick(os.getenv("SHOT_TECHCAT"))
        end
        -- SHOT_TECHGO=<科技id> → 直接完成一项（离屏验证：效果落没落到管道）
        if os.getenv and os.getenv("SHOT_TECHGO") and not GameUI._shotTechGoDone then
            GameUI._shotTechGoDone = true
            local TechSystem = require("systems.TechSystem")
            local f = GameState.getPlayerFaction and GameState.getPlayerFaction()
            local tid = os.getenv("SHOT_TECHGO")
            if f then
                TechSystem.ensureRegistered()
                TechSystem.complete(GameState, f, tid)
                print("[Main] SHOT_TECHGO=" .. tostring(tid) .. " 已直接完成")
                -- 立刻复查：效果是否进了管道（以防"注册/完成"之间有时序问题）
                local Modifiers = require("systems.Modifiers")
                local b = Modifiers.breakdown(100, "faction", "foodIncome",
                    { gameState = GameState, faction = f })
                print(string.format("[Main] 复查 foodIncome：基础 100 → %.2f（研究后应 >100）", b.value))
            end
        end
    end

    -- 声明式面板：刷新绑定值（宿主内部按 10 次/秒限流）
    require("ui.UIPanelHost").refresh()

    -- Update UI labels
    if gameUIPanel_ then
        GameUI.update(GameState, TimeSystem)
    end

    -- Update message log from game state
    local msgs = GameState.getRecentMessages(5)
    if msgs and #msgs > 0 then
        -- GameUI.refreshMessages() is called inside GameUI.update
    end
end

-- ============================================================================
-- Key Input
-- ============================================================================

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    local key = eventData["Key"]:GetInt()

    if currentPhase_ ~= "playing" then return end

    -- Space = toggle pause
    if key == KEY_SPACE then
        TimeSystem.togglePause()
        local status = TimeSystem.isPaused() and "暂停" or "继续"
        GameState.addMessage(status, "system")
    end

    -- +/- = speed control
    if key == KEY_KP_PLUS or key == KEY_EQUALS then
        TimeSystem.increaseSpeed()
    end
    if key == KEY_KP_MINUS or key == KEY_MINUS then
        TimeSystem.decreaseSpeed()
    end

    -- D = toggle diplomacy
    if key == KEY_D then
        GameUI.toggleDiplomacy(GameState)
    end

    -- Escape = 取消国交行动模式 / 关面板
    if key == KEY_ESCAPE then
        if GameUI.isActMode() then
            ExitActMode()
        elseif GameUI.isSettingsVisible() then
            GameUI.hideSettings()
        elseif GameUI.isDiplomacyVisible() then
            GameUI.hideDiplomacy()
        elseif GameUI.isProvincePanelVisible() then
            GameUI.hideProvincePanel()
            if mapWidget_ and mapWidget_.setSelectedProvince then
                mapWidget_:setSelectedProvince(nil)
            end
        end
    end
end

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
local GameUI   = require("ui.GameUI")
local MapRenderer = require("map.MapRenderer")

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

-- ============================================================================
-- Lifecycle
-- ============================================================================

function Start()
    graphics.windowTitle = GameConfig.Title

    -- 桌面端隐藏系统鼠标手掌指针；Web 预览保持默认（隐藏会触发
    -- 沙箱 iframe 的 Pointer Lock 拒绝：WrongDocumentError）
    local PlatformUtils = require("urhox-libs.Platform.PlatformUtils")
    if not PlatformUtils.IsWebPlatform() then
        input.mouseMode = MM_FREE
        input.mouseVisible = false
    end

    -- Initialize UI system
    UI.Init({
        fonts = {
            { family = "sans", weights = {
                normal = "Fonts/MiSans-Regular.ttf",
            } },
            -- 古风字体族：霞鹜文楷（免费商用 OFL 协议），用于主菜单/古风标题
            { family = "gufeng", weights = {
                normal = "Fonts/LXGWWenKai-Regular.ttf",
                bold = "Fonts/LXGWWenKai-Regular.ttf",
            } },
        },
        scale = UI.Scale.DEFAULT,
    })

    -- 初始化音乐系统（双 SoundSource 无缝交叉淡化）
    MusicManager.init()

    -- Show the main menu (进入页面)
    if os.getenv and os.getenv("SHOT_MODE") then
        StartGame(2)
    else
        ShowMainMenu()
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
        onStart = function()
            print("[Main] 选择势力")
            ShowFactionSelect()
        end,
        -- 继续游戏（有存档时显示）
        onContinue = SaveManager.hasSave() and function()
            print("[Main] 继续游戏")
            ContinueGame()
        end or nil,
        -- 读取存档（独立入口）
        onLoadSave = function()
            if SaveManager.hasSave() then
                print("[Main] 读取存档")
                ContinueGame()
            else
                print("[Main] 没有可用存档")
                -- 无存档时用系统提示（Toast 或 GameState 日志由主菜单内显示）
            end
        end,
        -- 模组：切换地图包（热切换需重建索引，这里先切配置 + 提示）
        onSelectMapPack = function(id)
            local ok = MapPack.setActive(id)
            print("[Main] 切换地图包: " .. tostring(id) .. " → " .. tostring(ok))
        end,
        -- 地图编辑器：应用生成参数（当前先切地图包 + 记录参数）
        onApplyMapOptions = function(opts)
            if opts and opts.pack then
                MapPack.setActive(opts.pack)
            end
            print("[Main] 地图参数: 包=" .. tostring(opts and opts.pack)
                .. " 尺寸=" .. tostring(opts and opts.size)
                .. " 省密度=" .. tostring(opts and opts.provinces)
                .. " 势力=" .. tostring(opts and opts.factions)
                .. " 种子=" .. tostring(opts and opts.seed))
        end,
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
    currentPhase_ = "select"

    -- 列出有领地的势力（按领土大小排序）
    ---@type table[]
    local list = {}
    ---@type table[]
    local allFactions = Factions.data
    for _, f in ipairs(allFactions) do
        if f.provinces and #f.provinces > 0 then
            list[#list + 1] = f
        end
    end
    table.sort(list, function(a, b) return #a.provinces > #b.provinces end)

    local rows = UI.Panel { width = "100%", gap = 6 }
    for i = 1, #list do
        local f = list[i]
        rows:AddChild(UI.Button {
            height = 46,
            backgroundColor = { 35, 45, 65, 220 },
            borderRadius = 6,
            onClick = function()
                print("[Main] 选择势力: " .. (f.name or f.id))
                StartGame(f.id)
            end,
            children = {
                UI.Panel {
                    flexDirection = "row",
                    alignItems = "center",
                    gap = 8,
                    width = "100%",
                    children = {
                        UI.Panel {
                            width = 14, height = 14,
                            borderRadius = 7,
                            backgroundColor = f.color or { 150, 150, 150, 255 },
                        },
                        UI.Label {
                            text = f.name or ("势力#" .. f.id),
                            fontSize = 14,
                            fontColor = { 255, 255, 255, 255 },
                            fontWeight = "bold",
                        },
                        UI.Label {
                            text = "🗺" .. #f.provinces .. "  ⚔️" .. (f.armySize or 0),
                            fontSize = 11,
                            fontColor = { 180, 190, 210, 200 },
                            flexGrow = 1,
                        },
                    },
                },
            },
        })
    end

    uiRoot_ = UI.Panel {
        width = "100%",
        height = "100%",
        backgroundColor = { 15, 20, 30, 255 },
        padding = 20,
        children = {
            UI.Panel {
                width = "100%",
                alignItems = "center",
                marginBottom = 12,
                children = {
                    UI.Label {
                        text = "选择你的国家",
                        fontSize = 24,
                        fontColor = { 255, 210, 80, 255 },
                        fontWeight = "bold",
                    },
                    UI.Label {
                        text = "你将在乱世中崛起，逐鹿九州",
                        fontSize = 12,
                        fontColor = { 160, 165, 175, 255 },
                        marginTop = 4,
                    },
                },
            },
            UI.ScrollView {
                width = "100%",
                flexGrow = 1,
                flexBasis = 0,
                children = { rows },
            },
        },
    }
    UI.SetRoot(uiRoot_)
end

-- ============================================================================
-- Phase: Continue Game（读档）
-- ============================================================================

--- 从存档恢复游戏
function ContinueGame()
    local data = SaveManager.load()
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
                f.taxLevel  = saved.taxLevel
                f.vassalOf  = saved.vassalOf
                if saved.leader then f.leader = saved.leader end
                if saved.policies then f.policies = saved.policies end
                if saved.policyProgress then f.policyProgress = saved.policyProgress end
                if saved.reforms then f.reforms = saved.reforms end
                if saved.reformEffects then f.reformEffects = saved.reformEffects end
                if saved.provinces then f.provinces = saved.provinces end
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
                p.stability   = ps.stability or 60
                p.population  = ps.population or 0
                p.isWasteland = ps.isWasteland or false
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

    -- 6. 战争
    GameState.wars = {}
    if data.wars then
        for key, war in pairs(data.wars) do
            GameState.wars[key] = war
        end
    end

    -- 7. 军队
    GameState.armies = {}
    if data.armies then
        for i = 1, #data.armies do
            GameState.armies[i] = data.armies[i]
        end
    end

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
    end)
    BuildGameUI()

    GameState.addMessage("读档成功，继续你的霸业！", "system")
    print("[Main] 读档成功")
end

-- ============================================================================
-- Phase: Start Game
-- ============================================================================

--- 开始游戏（玩家选择势力后进入）
---@param factionId number 玩家选择的势力 id
function StartGame(factionId)
    currentPhase_ = "playing"

    -- 进入游戏 → 无缝切换到战略地图曲《运筹帷幄》
    MusicManager.play("ycww")

    -- 0. 地图渲染：NanoVG 直接贴成品位图（map_political.png，gen_final_map.py 烘焙），
    --    颜色与小地图同路径，无 3D shader 层的颜色空间转换。

    -- 1. Initialize game state（玩家势力）
    GameState.init(factionId)

    -- 2. Initialize time system
    TimeSystem.init()
    GameState.speed = select(1, TimeSystem.getSpeed())   -- sync initial speed to UI
    GameState.paused = false

    -- 3. Register monthly callbacks
    TimeSystem.on("month", function(t)
        OnNewMonth(t)
    end)

    TimeSystem.on("day", function(t)
        OnNewDay(t)
    end)

    -- 每年：君主年龄增长/死亡/继承
    TimeSystem.on("year", function(t)
        LeaderSystem.processYear(GameState)
    end)

    -- 4. Build the game UI
    BuildGameUI()

    print("[Main] 游戏开始!（玩家势力 " .. tostring(factionId) .. "）")
    local pf = GameState.getPlayerFaction()
    if pf then
        GameState.addMessage("你选择了" .. (pf.fullName or pf.name) .. "，逐鹿天下由此开始！", "system")
    else
        GameState.addMessage("游戏开始！选择你的策略，逐鹿九州！", "system")
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
                    att = { factionId = playerId, size = 800, morale = 100 },
                    def = { factionId = enemyId, size = 600, morale = 100 },
                    progress = 0.4,
                },
            }
        end
    end
end

-- ============================================================================
-- Build Game UI (Map + Overlays)
-- ============================================================================

function BuildGameUI()
    -- Create the map widget（地图画面由 NanoVG 直接贴成品位图渲染）
    mapWidget_ = MapRenderer.create(GameState)

    -- Set up province click handler
    mapWidget_.onProvinceClick = function(provinceId)
        OnProvinceClicked(provinceId)
    end

    -- 和平条约涂抹选省：地图涂抹/点选 → GameUI 加入/移出割让清单
    mapWidget_.onPeacePaintProvince = function(provinceId, forceSelect)
        if GameUI.isPeacePickMode() then
            GameUI.togglePeaceProvincePick(provinceId, forceSelect)
        end
    end

    -- 判断省是否可索取（涂抹起点判定：可索取省上按住才涂抹，否则拖动地图）
    mapWidget_.isPeacePickable = function(provinceId)
        return GameUI.isProvincePickable(provinceId)
    end

    -- Army move target selected on map
    mapWidget_.onArmyMoveTarget = function(fromId, toId)
        local prov = GameState.getProvince(fromId)
        local target = GameState.getProvince(toId)
        if not prov or not target then return end
        local pid = GameState.playerFactionId
        local moveSize = math.floor((prov.garrison or 0) * 0.5)
        if moveSize < 1 then return end
        local ok, result = MilitarySystem.moveArmy(GameState, pid, fromId, toId, moveSize)
        if ok then
            GameState.addMessage("从 " .. prov.name .. " 调军 " .. moveSize .. " 前往 " .. target.name, "military")
        else
            GameState.addMessage("调军失败: " .. tostring(result), "warning")
        end
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

        onRecruit = function(provinceId)
            local pid = GameState.playerFactionId
            local ok, result = MilitarySystem.recruit(GameState, pid, provinceId)
            if ok then
                GameState.addMessage("在 " .. (GameState.getProvince(provinceId).name or "?") .. " 征兵 " .. result .. " 人", "military")
            else
                GameState.addMessage("征兵失败: " .. tostring(result), "warning")
            end
        end,

        onMoveArmy = function(fromId)
            -- Enter army move mode: let the player pick a target province on the map
            local prov = GameState.getProvince(fromId)
            if not prov then return end
            local garrison = prov.garrison or 0
            if garrison < 500 then
                GameState.addMessage("驻军不足（至少500），无法调军", "warning")
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

        onDeclareWar = function(targetFactionId)
            local ok, reason = DiplomacySystem.declareWar(GameState, GameState.playerFactionId, targetFactionId)
            if ok then
                local target = GameState.getFaction(targetFactionId)
                GameState.addMessage("向 " .. (target and target.name or "?") .. " 宣战！", "war")
                -- 立即刷新战争列表（绕过节流延迟）
                GameUI.forceRefreshWarList(GameState)
            else
                GameState.addMessage("无法宣战: " .. tostring(reason), "warning")
            end
        end,

        onProposePeace = function(targetFactionId)
            -- 玩家求和：先生成条款 → 弹条约窗口，确认后提交
            local pid = GameState.playerFactionId
            local ok, terms = DiplomacySystem.preparePeaceOffer(GameState, pid, targetFactionId)
            if not ok then
                GameState.addMessage("无法求和: " .. tostring(terms), "warning")
                return
            end
            local chance = WarSystem.getPeaceAcceptChance(GameState, pid, targetFactionId)
            GameUI.showPeaceDialog(GameState, {
                mode = "propose",
                proposerId = pid,
                targetId = targetFactionId,
                terms = terms,
                chance = chance,
            })
        end,

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

        onImproveRelation = function(targetFactionId)
            local ok, reason = DiplomacySystem.improveRelation(GameState, GameState.playerFactionId, targetFactionId)
            if ok then
                local target = GameState.getFaction(targetFactionId)
                GameState.addMessage("正在改善与 " .. (target and target.name or "?") .. " 的关系", "diplomacy")
            else
                GameState.addMessage("改善关系失败: " .. tostring(reason), "warning")
            end
        end,

        onDiplomacyToggle = function()
            GameUI.toggleDiplomacy(GameState)
        end,

        onToggleNationPanel = function()
            GameUI.toggleNationPanel()
        end,

        onPolicyToggle = function()
            GameUI.togglePolicyPanel()
        end,

        onPolicyStart = function(slot, cardId)
            local pid = GameState.playerFactionId
            local ok, reason = PolicySystem.startPolicy(GameState, pid, slot, cardId)
            if not ok then
                GameState.addMessage("实施政策失败: " .. tostring(reason), "warning")
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
            if mode == "ally" and not GameState.allyViewFactionId then
                GameState.allyViewFactionId = GameState.playerFactionId
            end
            local names = {
                political = "政治", region = "地区", war = "战争",
                ally = "盟友", resource = "资源",
            }
            GameState.addMessage("切换到" .. (names[mode] or mode) .. "模式", "system")
        end,

        onSetTaxLevel = function(level)
            local pid = GameState.playerFactionId
            local f = pid and GameState.factions[pid]
            if not f then return end
            f.taxLevel = level
            local entry = GameConfig.Economy.TAX_RATES[level]
            local name = entry and entry.name or tostring(level)
            GameState.addMessage("税率调整为：" .. name, "system")
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

        onWarAlertFocus = function(alert)
            if not alert or not mapWidget_ then return end
            if mapWidget_.focusProvince then
                mapWidget_:focusProvince(alert.provinceId, 1.0)
            end
            local province = GameState.getProvince(alert.provinceId)
            if province then
                GameUI.showProvincePanel(alert.provinceId, province)
            end
        end,

        onWarAlertResume = function()
            TimeSystem.resume()
            GameState.paused = false
            print("[WarAlert] 继续时间")
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
            mapWidget_.peacePaintEnabled = isPropose
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
            mapWidget_.peacePaintEnabled = false
        end,

        onSave = function()
            local ok, reason = SaveManager.save(GameState, TimeSystem.getState())
            if ok then
                GameState.addMessage("已保存游戏", "system")
                print("[Main] 已保存")
            else
                GameState.addMessage("保存失败: " .. tostring(reason), "warning")
                print("[Main] 保存失败: " .. tostring(reason))
            end
        end,

        onToggleMusic = function(on)
            print("[Main] 音乐 " .. (on and "开" or "关") .. "（音乐系统开发中）")
        end,

        onExitToMenu = function()
            print("[Main] 返回主菜单")
            ShowMainMenu()
        end,
    })

    -- Build root: map behind, UI overlays in front
    uiRoot_ = UI.Panel {
        id = "gameRoot",
        width = "100%",
        height = "100%",
        children = {
            -- Map occupies full screen
            mapWidget_,
            -- UI overlay on top (pointerEvents = box-none for pass-through)
            gameUIPanel_,
        }
    }

    UI.SetRoot(uiRoot_)
end

-- ============================================================================
-- Province Click Handler
-- ============================================================================

function OnProvinceClicked(provinceId)
    if not provinceId then
        GameUI.hideProvincePanel()
        return
    end

    local prov = GameState.getProvince(provinceId)
    if not prov then return end

    -- 和平会议选省模式：点击地图敌省 = 加入/移出割让清单（HOI4 式）
    if GameUI.isPeacePickMode() then
        GameUI.togglePeaceProvincePick(provinceId)
        return
    end

    -- 沙漠废土不可点击（2026-09-01）：不显示面板
    if prov.isWasteland then
        GameUI.hideProvincePanel()
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

    print("[Main] 选中省份: " .. prov.name .. " (ID:" .. provinceId .. ")")
end

-- ============================================================================
-- Time Callbacks
-- ============================================================================

function OnNewMonth(t)
    -- 1. Economy tick
    EconomySystem.processMonth(GameState)

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

    -- 6. Check victory/defeat conditions
    CheckGameOver()

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
    -- 政策实施进度（HoI4 式：剩余天数递减）
    -- （军队行军已改为每帧推进，见 HandleUpdate）
    PolicySystem.processDaily(GameState)
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

    -- 音乐交叉淡化每帧驱动（主菜单/游戏均需）
    MusicManager.update(dt)

    -- 主菜单入场动画驱动
    MainMenu.update(dt)

    if currentPhase_ ~= "playing" then return end

    -- Advance game time (this triggers hour/day/month/year callbacks)
    TimeSystem.update(dt)

    -- 军队行军 + 战斗：每帧推进（2026-09-01，平滑移动 + 保底现实秒数 + 持续战斗）
    local _, _, hoursPerSec = TimeSystem.getSpeed()
    if not TimeSystem.isPaused() and hoursPerSec then
        MilitarySystem.updateArmies(GameState, dt * hoursPerSec, dt)
        MilitarySystem.processBattles(GameState, dt * hoursPerSec)
    end

    -- 战争警报优先级高于普通外交通知：弹出即暂停，玩家明确处理后才继续
    if gameUIPanel_ and not GameUI.isWarAlertVisible() then
        local alert = GameState.popWarAlert and GameState.popWarAlert() or nil
        if alert then
            TimeSystem.pause()
            GameState.paused = true
            GameUI.showWarAlert(alert)
        end
    end

    -- AI 求和玩家：弹出和平谈判窗口等玩家决定（战争警报期间不叠加）
    if GameState.pendingPeace and gameUIPanel_
        and not GameUI.isWarAlertVisible()
        and not GameUI.isPeaceDialogVisible() then
        local pd = GameState.pendingPeace
        GameUI.showPeaceDialog(GameState, {
            mode = "respond",
            proposerId = pd.proposerId,
            targetId   = pd.targetId,
            terms      = pd.terms,
        })
    end

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

    -- Escape = deselect province or close panels
    if key == KEY_ESCAPE then
        if GameUI.isDiplomacyVisible() then
            GameUI.hideDiplomacy()
        elseif GameUI.isProvincePanelVisible() then
            GameUI.hideProvincePanel()
            if mapWidget_ and mapWidget_.setSelectedProvince then
                mapWidget_:setSelectedProvince(nil)
            end
        end
    end
end

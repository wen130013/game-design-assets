-- ============================================================================
-- SettingsPanel.lua — 设置菜单（2026-09-26 从 GameUI.lua 拆出）
--
-- 拆分模式（详见 NoticePanel.lua 头部说明）：导出 create(ctx) / install(GameUI)，
-- ctx 注入 UI/GameUI/refs/COLORS/SmallButton/MusicManager，**不 require GameUI**。
-- 注意：isFogOfWar/setFogOfWar/isEventAutoPopup/setEventAutoPopup 仍留在 GameUI 上
--   （别的模块也用），这里通过 GameUI.xxx 调用。
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
local MusicManager

-- ============================================================
-- 6) Settings Panel（设置菜单：保存 / 音乐 / 返回主菜单）
-- ============================================================
local function showSettings()
    if not refs.settingsOverlay then return end
    GameUI.refreshSettings()
    refs.settingsOverlay:Show()
    -- 打开设置 = 暂停（2026-09-25 用户："当我点开设置它应该暂停"）
    --   与战争面板 / 和约窗口同一套做法：看设置时时间不该继续跑
    --   （否则一边调音量一边被 AI 打，还要分心看战报）
    do
        local okTS, TS = pcall(require, "core.TimeSystem")
        if okTS and TS and TS.pause then
            TS.pause()
            if refs.gameState then refs.gameState.paused = true end
        end
    end
end

--- 关闭设置：**不自动恢复时间**（2026-09-25）
---   原因：暂停可能是别的面板先按下的（比如先开战争面板再开设置），
---   设置关掉就恢复时间，会把那些面板的暂停一起解掉。
---   玩家自己点顶栏的暂停按钮恢复即可 —— 与其它面板口径一致。
local function hideSettings()
    if refs.settingsOverlay then refs.settingsOverlay:Hide() end
end

local function toggleSettings()
    if refs.settingsOverlay and refs.settingsOverlay:IsVisible() then
        GameUI.hideSettings()
    else
        GameUI.showSettings()
    end
end

--- 设置面板是否可见
local function isSettingsVisible()
    return refs.settingsOverlay ~= nil and refs.settingsOverlay:IsVisible()
end

--- 刷新设置面板（进入时同步音乐开关/音量/当前曲目状态）
local function refreshSettings()
    if not refs.settingsOverlay then return end
    -- 音乐开关
    if refs.settingsMusicBtn then
        local on = MusicManager.getEnabled()
        refs.settingsMusicBtn:SetText(on and "音乐：开" or "音乐：关")
    end
    -- 音量滑块
    if refs.musicVolumeSlider then
        refs.musicVolumeSlider:SetValue(MusicManager.getVolume())
        if refs.musicVolumeLabel then
            refs.musicVolumeLabel.text = "音量：" .. math.floor(MusicManager.getVolume() * 100) .. "%"
        end
    end
    -- 当前曲目
    if refs.musicCurrentLabel then
        refs.musicCurrentLabel.text = "正在播放：" .. (MusicManager.getCurrentName() or "无")
    end
    -- 换视角区（2026-09-15）：已经在看海了就把「看海模式」禁掉 —— 点了也没变化，不如明说
    if refs.settingsSpectateBtn then
        local spectating = refs.gameState ~= nil and refs.gameState.playerFactionId == nil
        refs.settingsSpectateBtn:SetText(spectating and "看海中" or "看海模式")
        refs.settingsSpectateBtn:SetDisabled(spectating)
        refs.settingsSpectateBtn:SetOpacity(spectating and 0.62 or 1)
    end
    -- 战争迷雾（2026-09-24）：看海模式下没有"我"，迷雾无从判定 → 禁用并说明
    if refs.settingsFogBtn then
        local spectating = refs.gameState ~= nil and refs.gameState.playerFactionId == nil
        refs.settingsFogBtn:SetText(GameUI.isFogOfWar() and "战争迷雾：开" or "战争迷雾：关")
        refs.settingsFogBtn:SetDisabled(spectating)
        refs.settingsFogBtn:SetOpacity(spectating and 0.62 or 1)
    end
end

local function createSettingsPanel(callbacks)
    -- 统一皮肤（2026-09-25 用户："设置这个页面怎么还是这种古老版本，不要这个 UI"）：
    --   原来这里是**羊皮纸风格**（棕色字 + 米黄底 + 卷轴底图），跟游戏内其它面板
    --   （深靛底 + 金棕描边 + 金字）完全是两套视觉。现在改走 ui/UISkin 统一皮肤 ——
    --   和主菜单/征召面板/军队面板同一套配色，改 UISkin 一处就能整游戏换皮。
    local UISkin = require("ui.UISkin")
    local SK = UISkin.COLORS
    refs.musicOn = MusicManager.getEnabled()

    --- 设置项按钮工厂（UISkin 金漆木牌风格）
    ---@param label string
    ---@param onClick function
    ---@param kind string|nil "normal"|"primary"|"danger"
    local function settingBtn(label, onClick, kind)
        local props = UISkin.button(kind or "normal", {
            width = "100%", height = 52, fontSize = 16,
        })
        props.text = label
        props.onClick = onClick
        return UI.Button(props)
    end

    refs.settingsMusicBtn = settingBtn(
        refs.musicOn and "音乐：开" or "音乐：关",
        function()
            refs.musicOn = not refs.musicOn
            refs.settingsMusicBtn:SetText(refs.musicOn and "音乐：开" or "音乐：关")
            MusicManager.setEnabled(refs.musicOn)
            if callbacks.onToggleMusic then
                callbacks.onToggleMusic(refs.musicOn)
            end
        end)

    -- 当前曲目显示
    refs.musicCurrentLabel = UI.Label {
        text = "正在播放：" .. (MusicManager.getCurrentName() or "无"),
        fontSize = 15,
        fontColor = SK.textDim,
    }

    -- 曲目下拉选择（无缝切换）
    local musicOptions = {}
    local trackList = MusicManager.getTrackList()
    local curId = MusicManager.getCurrentId()
    for _, t in ipairs(trackList) do
        musicOptions[#musicOptions + 1] = { value = t.id, label = t.name }
    end
    if #musicOptions == 0 then
        musicOptions[1] = { value = "none", label = "（无可用曲目）" }
    end
    refs.musicDropdown = UI.Dropdown {
        options = musicOptions,
        value = curId,
        placeholder = "选择音乐",
        height = 46,
        triggerBgColor = SK.inkBtn,
        width = "100%",
        onChange = function(self, value, option)
            MusicManager.play(value)
            if refs.musicCurrentLabel then
                refs.musicCurrentLabel.text = "正在播放：" .. (MusicManager.getCurrentName() or "无")
            end
        end,
    }

    -- 音量滑块（0~1）
    refs.musicVolumeLabel = UI.Label {
        text = "音量：" .. math.floor(MusicManager.getVolume() * 100) .. "%",
        fontSize = 15,
        fontColor = SK.textDim,
    }
    refs.musicVolumeSlider = UI.Slider {
        min = 0,
        max = 1,
        step = 0.01,
        value = MusicManager.getVolume(),
        height = 40,
        trackHeight = 8,
        thumbSize = 26,
        trackBgColor = SK.inkBtn,
        trackFillColor = SK.goldSoft,
        thumbColor = SK.gold,
        onChange = function(self, value)
            MusicManager.setVolume(value)
            if refs.musicVolumeLabel then
                refs.musicVolumeLabel.text = "音量：" .. math.floor(value * 100) .. "%"
            end
        end,
    }

    -- 动作按钮 = 同一个 settingBtn 工厂（UISkin 风格）
    local function paperActionBtn(label, _color, onClick)
        return settingBtn(label, onClick)
    end

    local closeBtn = UI.Button {
        text = "X",
        width = 46,
        height = 46,
        fontSize = 24,
        textColor = SK.vermilionTxt,
        fontWeight = "bold",
        fontFamily = "gufeng",
        backgroundColor = SK.danger,                  -- 印章式：朱红印底
        hoverBackgroundColor = SK.dangerHover,
        pressedBackgroundColor = SK.dangerPress,
        borderRadius = 10,
        borderWidth = 2,
        borderColor = SK.vermilionLn,
        onClick = function()
            GameUI.hideSettings()
        end,
    }

    refs.settingsCloseBtn = closeBtn

    -- 换视角区（2026-09-15）：
    --   「切换角色」= 打开选国页（复用），选完只换视角 —— **世界原样不动**
    --   「看海模式」= 直接切看海（已在看海则禁用，见 refreshSettings）
    -- ⚠️ 必须在这里先建好再引用：表构造器里只能写 `键 = 值`，写 `refs.x = 值` 是语法错误
    refs.settingsSwitchBtn = paperActionBtn("切换角色", { 64, 42, 20, 255 }, function()
        if callbacks.onSwitchFaction then callbacks.onSwitchFaction() end
    end)
    refs.settingsSpectateBtn = paperActionBtn("看海模式", { 64, 42, 20, 255 }, function()
        if callbacks.onSpectate then callbacks.onSpectate() end
    end)

    -- 重要事件自动弹出（2026-09-16）：开 = 事件来了直接弹框（不暂停时间）；
    --   关 = 只挂顶栏下的小条，等玩家自己点开
    refs.settingsAutoPopupBtn = paperActionBtn(
        GameUI.isEventAutoPopup() and "重要事件自动弹出：开" or "重要事件自动弹出：关",
        { 64, 42, 20, 255 }, function()
            GameUI.setEventAutoPopup(not GameUI.isEventAutoPopup())
        end)

    -- 战争迷雾开关（2026-09-24）：局内也能改（选国页那个是开局设定）。
    --   改完立刻重算可见性并重绘地图 —— 否则要等下一次领地变动才刷新。
    refs.settingsFogBtn = paperActionBtn(
        GameUI.isFogOfWar() and "战争迷雾：开" or "战争迷雾：关",
        { 64, 42, 20, 255 }, function()
            GameUI.setFogOfWar(not GameUI.isFogOfWar())
        end)

    refs.settingsOverlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 170 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 440,
                -- ⚠️ 必须用 height（确定尺寸），不能用 maxHeight：
                --    里面有个 flexGrow 的 ScrollView，父容器尺寸不确定时
                --    flexGrow 分不到剩余空间，滚动区会塌成 0 高（ui.md 陷阱 9）。
                height = "94%",
                -- 皮肤统一（2026-09-25）：去掉羊皮纸底图，改用深靛底 + 金棕描边，
                --   与征召面板/军队面板/主菜单同一套视觉
                backgroundColor = SK.panelBg,
                borderRadius = 12,
                borderWidth = 2,
                borderColor = SK.panelBorder,
                paddingTop = 16,
                paddingBottom = 16,
                paddingHorizontal = 20,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            UI.Label {
                                text = "设置",
                                fontSize = 22,
                                fontFamily = "gufeng",
                                fontColor = SK.gold,
                                fontWeight = "bold",
                            },
                            closeBtn,
                        },
                    },
                    UI.Divider { color = SK.divider, thickness = 1 },
                    -- 条目区可滚动（2026-09-15）：加上「切换角色」「看海模式」之后，
                    -- 矮屏（含离屏验证用的 800×600）会把上下两头切掉 —— 改成能滚才稳。
                    -- 题签行留在滚动区外，滚的时候不会跟着跑掉。
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,                -- 配 flexGrow 时必须为 0
                        scrollY = true,
                        showScrollbar = true,
                        children = {
                            UI.Panel {
                                width = "100%",
                                gap = 14,
                                children = {
                                    UI.Divider { color = { 110, 82, 50, 160 }, thickness = 1 },
                                    paperActionBtn("保存游戏", { 64, 42, 20, 255 }, function()
                                        if callbacks.onSave then callbacks.onSave() end
                                    end),
                                    paperActionBtn("读取存档", { 64, 42, 20, 255 }, function()
                                        if callbacks.onLoadGame then callbacks.onLoadGame() end
                                    end),
                                    -- ===== 换视角区（2026-09-15）=====
                                    refs.settingsSwitchBtn,
                                    refs.settingsSpectateBtn,
                                    -- ===== 事件提示（2026-09-16）=====
                                    refs.settingsAutoPopupBtn,
                                    -- ===== 战争迷雾（2026-09-24）=====
                                    refs.settingsFogBtn,
                                    -- ===== 音乐区 =====
                                    UI.Label {
                                        text = "音　乐",
                                        fontSize = 18,
                                        fontFamily = "gufeng",
                                        fontColor = SK.gold,
                                        fontWeight = "bold",
                                    },
                                    refs.settingsMusicBtn,
                                    refs.musicCurrentLabel,
                                    refs.musicDropdown,
                                    refs.musicVolumeLabel,
                                    refs.musicVolumeSlider,
                                    -- 滚到底时给「返回主菜单」留口气（否则它贴着滚动区底边）
                                    UI.Panel { height = 30 },
                                    UI.Divider { color = { 110, 82, 50, 160 }, thickness = 1 },
                                    paperActionBtn("返回主菜单", { 146, 58, 40, 255 }, function()
                                        if callbacks.onExitToMenu then callbacks.onExitToMenu() end
                                    end),
                                },
                            },
                        },
                    },
                },
            },
        },
    }
    refs.settingsOverlay:Hide()
    return refs.settingsOverlay
end

--- 把本模块的方法挂回 GameUI 主表
---@param gameUI table GameUI 主表
function M.install(gameUI)
    gameUI.showSettings       = showSettings
    gameUI.hideSettings       = hideSettings
    gameUI.toggleSettings     = toggleSettings
    gameUI.isSettingsVisible  = isSettingsVisible
    gameUI.refreshSettings    = refreshSettings
end

--- 创建设置面板
---@param ctx table 共享上下文
---@return Widget settingsOverlay
function M.create(ctx)
    UI          = ctx.UI
    GameUI      = ctx.GameUI
    refs        = ctx.refs
    COLORS      = ctx.COLORS
    SmallButton = ctx.SmallButton
    MusicManager = ctx.MusicManager
    return createSettingsPanel(ctx.callbacks)
end

return M

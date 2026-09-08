--- MainMenu.lua - 进入页面（主菜单）
---
--- 统一"羊皮纸古卷"风格：标题 / 按钮 / 弹窗使用同一套配色（暖纸底 + 深棕描边 + 古金标题）。
--- 2026-09-01：
---   * 设置可点（音乐开关/切歌/音量，复用 MusicManager）
---   * 新增"退出游戏"按钮（engine:Exit）
---   * 新增"模组"按钮（打开模组面板：切换地图包，不带"开发中"）
---   * 新增"地图编辑器"按钮（打开地图编辑器面板：地图包/尺寸/省数量/势力/种子）
---   * 新增"读取存档"按钮（独立读档入口）

local UI = require("urhox-libs/UI")
local MusicManager = require("audio.MusicManager")

local MainMenu = {}

-- ============================================================
-- 统一古卷配色（羊皮纸 + 深棕 + 古金）
-- ============================================================
local PALETTE = {
    parchment      = { 236, 221, 187, 250 },   -- 羊皮纸底
    parchmentLight = { 250, 240, 214, 255 },   -- 悬停提亮
    parchmentDark  = { 214, 196, 158, 255 },   -- 按下
    ink            = { 74, 52, 26, 255 },      -- 深棕墨字
    border         = { 120, 88, 44, 255 },     -- 深棕描边
    gold           = { 200, 158, 70, 255 },    -- 古金
    goldText       = { 150, 112, 40, 255 },    -- 古金标题字
    overlayScrim   = { 30, 24, 16, 120 },      -- 弹窗遮罩
    subText        = { 110, 88, 60, 255 },     -- 次级文字
}

-- ============================================================
-- 入场动画（交错浮现）：手动逐帧插值驱动（不依赖引擎 Animate，
-- 最坏情况 = 无动画但元素必然可见）
-- ============================================================
local intro_ = { t = nil, items = {} }
local INTRO_DUR = 0.45   -- 单项动画时长（秒）
local INTRO_FROM_Y = -16 -- 起始上移距离

--- easeOutCubic 缓动（快进慢停）
local function easeOutCubic(t)
    local f = t - 1
    return f * f * f + 1
end

function MainMenu.beginIntro()
    intro_.t = 0
end

--- 由 main.lua HandleUpdate 每帧调用
function MainMenu.update(dt)
    if not intro_.t then return end
    intro_.t = intro_.t + dt
    local allDone = true
    for _, it in ipairs(intro_.items) do
        if not it.done then
            local el = intro_.t - (it.delay or 0)
            if el >= INTRO_DUR then
                it.w:SetStyle({ opacity = 1, translateY = 0 })
                it.done = true
            else
                allDone = false
                if el < 0 then
                    it.w:SetStyle({ opacity = 0, translateY = INTRO_FROM_Y })
                else
                    local k = easeOutCubic(el / INTRO_DUR)
                    it.w:SetStyle({ opacity = k, translateY = INTRO_FROM_Y * (1 - k) })
                end
            end
        end
    end
    if allDone then intro_.t = nil end  -- 动画全部完成，停止驱动
end

--- 注册入场动画项（注册即隐藏，等交错浮现；仅主菜单直接可见的元素）
local function introAdd(w, delay)
    w:SetStyle({ opacity = 0, translateY = INTRO_FROM_Y })
    intro_.items[#intro_.items + 1] = { w = w, delay = delay or 0, done = false }
end

-- ============================================================
-- 古风按钮（"羊皮纸小卷轴"：AI 素材图做底，墨字写在纸上）
-- 与背景同质同源：真实纸纹 + 毛边 + 两端卷轴 + 光影
-- ============================================================
local function GuFengButton(label, onClick, opts)
    opts = opts or {}
    local btn = UI.Button {
        id = opts.id,
        text = label,
        width = opts.width or 360,
        height = opts.height or 56,
        marginBottom = opts.marginBottom or 14,
        fontSize = opts.fontSize or 20,
        fontFamily = "gufeng",
        fontWeight = "bold",
        textColor = { 56, 36, 18, 255 },                     -- 浓墨字（Button 用 textColor）
        textShadow = { offsetX = 0, offsetY = 1, blur = 1, color = { 255, 250, 235, 70 } },
        backgroundColor = { 0, 0, 0, 0 },                    -- 已去掉棕色底框（纸图透明区不再透出棕色）
        hoverBackgroundColor = { 0, 0, 0, 0 },
        pressedBackgroundColor = { 0, 0, 0, 0 },             -- 按下反馈改由纸图变暗承担
        backgroundImage = "image/btn_scroll_normal.png",     -- 羊皮纸卷轴条（仅一张图）
        backgroundFit = "fill",
        hoverBackgroundImageOpacity = 1,                     -- 悬停不变
        pressedBackgroundImageOpacity = 0.55,                -- 按下：纸图变暗（按下反馈），无棕框无手印
        onClick = onClick,
    }
    if opts.intro then
        introAdd(btn, 0.08 * #intro_.items)   -- 交错浮现（注册即隐藏）
    end
    return btn
end

-- ============================================================
-- 通用古卷弹窗壳（统一弹窗外观）
-- 面板 = AI 羊皮纸素材（毛边+纹理，与背景/按钮同源）；尺寸按手机触控标准
-- ============================================================
local PANEL_PAPER = "image/panel_parchment_20260901161208.png"

--- 创建一个居中古卷弹窗
---@param title string 弹窗标题
---@param children table 内容控件
---@param refs table 引用表（用于存取 overlay 句柄，便于开关）
---@param key string refs 中保存 overlay 的键名
local function createModal(title, children, refs, key)
    local overlay = UI.Panel {
        id = key,                                  -- 供 UI.FindById 查找（测试/外部控制）
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 170 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 440,
                backgroundImage = PANEL_PAPER,         -- 羊皮纸毛边素材
                backgroundFit = "fill",
                paddingTop = 66,                       -- 下移避开纸顶深色卷边
                paddingBottom = 44,
                paddingHorizontal = 38,
                gap = 14,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            -- 题签：浅色衬底小纸条，压在深色褶皱上也清晰
                            UI.Panel {
                                backgroundColor = { 250, 240, 214, 215 },
                                borderRadius = 8,
                                borderWidth = 1,
                                borderColor = { 150, 118, 76, 200 },
                                paddingHorizontal = 16,
                                paddingVertical = 6,
                                children = {
                                    UI.Label {
                                        text = title,
                                        fontSize = 24,
                                        fontFamily = "gufeng",
                                        fontColor = { 64, 42, 20, 255 },  -- 浓墨标题
                                        fontWeight = "bold",
                                    },
                                },
                            },
                            -- 印章式关闭钮：朱红印底 + 纸色字，任何背景都醒目
                            UI.Button {
                                text = "X",
                                width = 46,
                                height = 46,
                                fontSize = 24,
                                textColor = { 250, 240, 222, 255 },
                                fontWeight = "bold",
                                fontFamily = "gufeng",
                                backgroundColor = { 166, 42, 34, 255 },
                                hoverBackgroundColor = { 190, 58, 46, 255 },
                                pressedBackgroundColor = { 138, 34, 26, 255 },
                                borderRadius = 10,
                                borderWidth = 2,
                                borderColor = { 120, 26, 20, 255 },
                                onClick = function()
                                    if refs[key] then refs[key]:Hide() end
                                end,
                            },
                        },
                    },
                    UI.Divider { color = { 110, 82, 50, 160 }, thickness = 1 },
                    -- 内容
                    children,
                },
            },
        },
    }
    overlay:Hide()
    refs[key] = overlay
    return overlay
end

-- ============================================================
-- 设置弹窗（音乐开关 / 当前曲目 / 切歌 / 音量）
-- ============================================================

---@param refs table
---@return Widget settingsOverlay
local function createSettingsOverlay(refs)
    -- 音乐开关
    refs.musicOn = MusicManager.getEnabled()
    refs.settingsMusicBtn = UI.Button {
        text = refs.musicOn and "音乐：开" or "音乐：关",
        width = "100%",
        height = 52,
        fontSize = 17,
        fontFamily = "gufeng",
        fontWeight = "bold",
        textColor = { 64, 42, 20, 255 },
        backgroundColor = { 255, 250, 236, 120 },
        hoverBackgroundColor = { 255, 244, 210, 190 },
        pressedBackgroundColor = { 214, 190, 148, 200 },
        borderColor = { 110, 82, 50, 200 },
        borderWidth = 1,
        borderRadius = 8,
        onClick = function(self)
            refs.musicOn = not refs.musicOn
            self:SetText(refs.musicOn and "音乐：开" or "音乐：关")
            MusicManager.setEnabled(refs.musicOn)
        end,
    }

    -- 当前曲目
    refs.musicCurrentLabel = UI.Label {
        text = "正在播放：" .. (MusicManager.getCurrentName() or "无"),
        fontSize = 15,
        fontColor = { 90, 64, 38, 255 },
    }

    -- 曲目下拉
    local musicOptions = {}
    for _, t in ipairs(MusicManager.getTrackList()) do
        musicOptions[#musicOptions + 1] = { value = t.id, label = t.name }
    end
    if #musicOptions == 0 then
        musicOptions[1] = { value = "none", label = "（无可用曲目）" }
    end
    refs.musicDropdown = UI.Dropdown {
        options = musicOptions,
        value = MusicManager.getCurrentId(),
        placeholder = "选择音乐",
        height = 46,
        triggerBgColor = { 72, 56, 38, 235 },
        width = "100%",
        onChange = function(self, value, option)
            MusicManager.play(value)
            refs.musicCurrentLabel.text = "正在播放：" .. (MusicManager.getCurrentName() or "无")
        end,
    }

    -- 音量滑块
    refs.musicVolumeLabel = UI.Label {
        text = "音量：" .. math.floor(MusicManager.getVolume() * 100) .. "%",
        fontSize = 15,
        fontColor = { 90, 64, 38, 255 },
    }
    refs.musicVolumeSlider = UI.Slider {
        min = 0,
        max = 1,
        step = 0.01,
        value = MusicManager.getVolume(),
        height = 40,
        trackHeight = 8,
        thumbSize = 26,
        trackBgColor = { 92, 70, 46, 200 },
        trackFillColor = { 172, 128, 62, 255 },
        thumbColor = { 122, 84, 40, 255 },
        onChange = function(self, value)
            MusicManager.setVolume(value)
            refs.musicVolumeLabel.text = "音量：" .. math.floor(value * 100) .. "%"
        end,
    }

    local content = UI.Panel {
        width = "100%",
        gap = 14,
        children = {
            UI.Label { text = "音　乐", fontSize = 18, fontFamily = "gufeng", fontColor = { 64, 42, 20, 255 }, fontWeight = "bold" },
            refs.settingsMusicBtn,
            refs.musicCurrentLabel,
            refs.musicDropdown,
            refs.musicVolumeLabel,
            refs.musicVolumeSlider,
        },
    }
    return createModal("设置", content, refs, "settingsOverlay")
end

-- ============================================================
-- 模组面板（切换地图包，真实可用，不带"开发中"）
-- ============================================================

---@param refs table
---@param options table 包含 onSelectMapPack callback
---@return Widget
local function createModsOverlay(refs, options)
    local MapPack = require("data.MapPack")

    -- 已注册地图包列表
    local packOptions = {}
    for id, p in pairs(MapPack.registry) do
        packOptions[#packOptions + 1] = { value = id, label = (p.LABEL or id) .. "（" .. id .. "）" }
    end
    table.sort(packOptions, function(a, b) return a.value < b.value end)

    refs.modMapPackLabel = UI.Label {
        text = "当前地图：" .. (MapPack.getActive and MapPack.getActive().LABEL or MapPack.activeId),
        fontSize = 15,
        fontColor = { 90, 64, 38, 255 },
    }
    refs.modMapPackDropdown = UI.Dropdown {
        options = packOptions,
        value = MapPack.activeId,
        placeholder = "选择地图包",
        height = 46,
        triggerBgColor = { 72, 56, 38, 235 },
        width = "100%",
        onChange = function(self, value, option)
            refs.modMapPackLabel.text = "当前地图：" .. option.label
            if options.onSelectMapPack then options.onSelectMapPack(value) end
        end,
    }

    local content = UI.Panel {
        width = "100%",
        gap = 12,
        children = {
            UI.Label {
                text = "地图模组：可切换已安装的地图包（欧亚非 / 旧版底图等）。",
                fontSize = 15,
                fontColor = { 90, 64, 38, 255 },
                whiteSpace = "normal",
                maxLines = 3,
            },
            refs.modMapPackLabel,
            refs.modMapPackDropdown,
        },
    }
    return createModal("模组", content, refs, "modsOverlay")
end

-- ============================================================
-- 地图编辑器面板（地图包 / 尺寸 / 省数量 / 势力 / 种子）
-- ============================================================

---@param refs table
---@param options table 包含 onApplyMapOptions callback
---@return Widget
local function createMapEditorOverlay(refs, options)
    local MapPack = require("data.MapPack")

    -- 地图包（沿用模组选择）
    local packOptions = {}
    for id, p in pairs(MapPack.registry) do
        packOptions[#packOptions + 1] = { value = id, label = (p.LABEL or id) }
    end
    table.sort(packOptions, function(a, b) return a.value < b.value end)

    -- 参数（暂存于 refs.mapOptions，点"生成"时回调）
    refs.mapOptions = {
        pack     = MapPack.activeId,
        size     = "large",   -- small / medium / large
        provinces = 3,        -- 1=少 2=中 3=多
        factions = 2,         -- 1=少 2=中 3=多
        seed     = tostring(math.random(1000, 9999)),
    }

    local sizeOptions = {
        { value = "small",   label = "小" },
        { value = "medium",  label = "中" },
        { value = "large",   label = "大" },
    }
    local densityOptions = {
        { value = 1, label = "疏" },
        { value = 2, label = "中" },
        { value = 3, label = "密" },
    }

    -- 地图包
    refs.mapPackDropdown = UI.Dropdown {
        options = packOptions,
        value = refs.mapOptions.pack,
        placeholder = "地图包",
        height = 46,
        triggerBgColor = { 72, 56, 38, 235 },
        width = "100%",
        onChange = function(self, value, option)
            refs.mapOptions.pack = value
        end,
    }
    -- 尺寸
    refs.mapSizeDropdown = UI.Dropdown {
        options = sizeOptions,
        value = refs.mapOptions.size,
        placeholder = "尺寸",
        height = 46,
        triggerBgColor = { 72, 56, 38, 235 },
        width = "100%",
        onChange = function(self, value, option)
            refs.mapOptions.size = value
        end,
    }
    -- 省密度
    refs.mapProvDensity = UI.Dropdown {
        options = densityOptions,
        value = refs.mapOptions.provinces,
        placeholder = "省密度",
        height = 46,
        triggerBgColor = { 72, 56, 38, 235 },
        width = "100%",
        onChange = function(self, value, option)
            refs.mapOptions.provinces = value
        end,
    }
    -- 势力数量
    refs.mapFactionDensity = UI.Dropdown {
        options = densityOptions,
        value = refs.mapOptions.factions,
        placeholder = "势力数",
        height = 46,
        triggerBgColor = { 72, 56, 38, 235 },
        width = "100%",
        onChange = function(self, value, option)
            refs.mapOptions.factions = value
        end,
    }
    -- 随机种子
    refs.mapSeedText = UI.TextField {
        value = refs.mapOptions.seed,
        placeholder = "随机种子",
        fontSize = 17,
        height = 48,
        width = "100%",
        borderColor = { 110, 82, 50, 220 },
        focusedBorderColor = { 146, 58, 40, 255 },
        focusedBorderWidth = 2,
        onChange = function(self, value)
            refs.mapOptions.seed = value
        end,
    }
    -- 随机种子按钮
    local seedRandomBtn = GuFengButton("随机", function()
        refs.mapOptions.seed = tostring(math.random(1000, 9999))
        refs.mapSeedText.props.value = refs.mapOptions.seed
        refs.mapSeedText:SetText(refs.mapOptions.seed)
    end, { width = 104, height = 48, fontSize = 17, marginBottom = 0 })

    -- 参数标签行
    local function rowLabel(txt)
        return UI.Label { text = txt, fontSize = 15, fontColor = { 90, 64, 38, 255 } }
    end

    local content = UI.Panel {
        width = "100%",
        gap = 12,
        children = {
            UI.Label {
                text = "按你的偏好生成一张全新世界地图，用于开局。",
                fontSize = 15,
                fontColor = { 90, 64, 38, 255 },
                whiteSpace = "normal",
                maxLines = 2,
            },
            rowLabel("地图包"),
            refs.mapPackDropdown,
            rowLabel("地图尺寸"),
            refs.mapSizeDropdown,
            rowLabel("省份密度"),
            refs.mapProvDensity,
            rowLabel("势力数量"),
            refs.mapFactionDensity,
            rowLabel("随机种子（同种子=同一张图）"),
            UI.Panel {
                flexDirection = "row",
                gap = 6,
                children = {
                    UI.Panel { flexGrow = 1, children = { refs.mapSeedText } },
                    seedRandomBtn,
                },
            },
            UI.Divider { color = PALETTE.border, thickness = 1 },
            GuFengButton("生成新世界", function()
                if options.onApplyMapOptions then
                    options.onApplyMapOptions(refs.mapOptions)
                end
            end, { width = "100%", height = 42, fontSize = 16 }),
        },
    }
    return createModal("地图编辑器", content, refs, "mapEditorOverlay")
end

-- ============================================================
-- 主菜单
-- ============================================================

--- 创建主菜单
---@param options table
---   onStart          function 点击"开始游戏"
---   onContinue       function|nil 点击"继续游戏"（无存档则不显示）
---   onLoadSave       function 点击"读取存档"
---   onSelectMapPack  function 点击模组面板切换地图包
---   onApplyMapOptions function 地图编辑器点击"生成新世界"
---@return Widget
function MainMenu.create(options)
    options = options or {}
    ---@type table
    local refs = {}

    -- 重置入场动画队列（重复进出主菜单时重建）
    intro_.items = {}
    intro_.t = nil

    local settingsOverlay = createSettingsOverlay(refs)
    local modsOverlay = createModsOverlay(refs, options)
    local mapEditorOverlay = createMapEditorOverlay(refs, options)

    ---@type table[]
    local children = {
        -- 标题行：金色书法大字 + 朱红印章落款（与背景窗棂金光呼应）
        UI.Panel {
            flexDirection = "row",
            alignItems = "flex-end",
            gap = 12,
            marginBottom = 44,
            children = {
                UI.Label {
                    text = "逐鹿九州",
                    fontSize = 58,
                    fontWeight = "bold",
                    fontFamily = "gufeng",
                    fontColor = { 255, 214, 90, 255 },
                    textShadow = { offsetX = 0, offsetY = 3, blur = 10, color = { 30, 20, 10, 160 } },
                    textStroke = { width = 2.5, color = { 40, 28, 12, 220 } },
                },
                -- 朱文印章（印泥红底 + 白字，落款位）
                UI.Panel {
                    width = 50,
                    height = 50,
                    marginBottom = 8,
                    justifyContent = "center",
                    alignItems = "center",
                    backgroundColor = { 166, 42, 34, 255 },
                    borderRadius = 6,
                    borderWidth = 2,
                    borderColor = { 120, 26, 20, 255 },
                    children = {
                        UI.Label {
                            text = "霸",
                            fontSize = 24,
                            fontFamily = "gufeng",
                            fontWeight = "bold",
                            fontColor = { 250, 240, 222, 255 },
                        },
                    },
                },
            },
        },
    }
    -- 标题行整体参与入场动画（第一个浮现）
    introAdd(children[1], 0)

    -- 新的游戏
    children[#children + 1] = GuFengButton("新的游戏", function()
        if options.onStart then options.onStart() end
    end, { intro = true, id = "btnNewGame" })

    -- 读取存档（有存档时显示）
    if options.onLoadSave or options.onContinue then
        children[#children + 1] = GuFengButton("读取存档", function()
            if options.onLoadSave then
                options.onLoadSave()
            elseif options.onContinue then
                options.onContinue()
            end
        end, { intro = true })
    end

    -- 地图编辑器
    children[#children + 1] = GuFengButton("地图编辑器", function()
        if options.onEditor then options.onEditor() end
    end, { intro = true })

    -- 模组
    children[#children + 1] = GuFengButton("模组", function()
        -- 打开前刷新当前地图包显示
        local MapPack = require("data.MapPack")
        refs.modMapPackLabel.text = "当前地图：" .. (MapPack.getActive and MapPack.getActive().LABEL or MapPack.activeId)
        refs.modsOverlay:Show()
    end, { intro = true })

    children[#children + 1] = GuFengButton("设置", function()
        -- 打开设置前同步音乐状态
        refs.musicCurrentLabel.text = "正在播放：" .. (MusicManager.getCurrentName() or "无")
        refs.musicVolumeSlider:SetValue(MusicManager.getVolume())
        refs.musicVolumeLabel.text = "音量：" .. math.floor(MusicManager.getVolume() * 100) .. "%"
        refs.settingsOverlay:Show()
    end, { intro = true })

    children[#children + 1] = GuFengButton("退出游戏", function()
        print("[MainMenu] 退出游戏")
        if engine then engine:Exit() end
    end, { marginBottom = 0, intro = true })

    children[#children + 1] = UI.Label {
        text = "v0.2.0 · 逐鹿九州",
        fontSize = 12,
        fontFamily = "gufeng",
        fontColor = { 120, 96, 66, 220 },
        marginTop = 20,
    }

    local root = UI.Panel {
        width = "100%",
        height = "100%",
        -- 明亮沙盘推演风格古风背景（突出谋略/研究/运筹帷幄）
        backgroundImage = "image/menu_bg_strategy_bright_20260901151528.png",
        backgroundImageOpacity = 1,
        backgroundFit = "cover",
        justifyContent = "center",
        alignItems = "center",
        children = {
            -- 极淡柔光遮罩：轻微统一亮度，保持明亮通透
            UI.Panel {
                position = "absolute",
                top = 0, left = 0, right = 0, bottom = 0,
                backgroundColor = { 20, 18, 14, 40 },
            },
            UI.Panel {
                alignItems = "center",
                children = children,
            },
            settingsOverlay,
            modsOverlay,
            mapEditorOverlay,
        },
    }
    -- [P0 临时] root 就绪后注入给工坊验证模块（按钮 onClick 不直接引用 root）
    require("mod.WorkshopProbe").attachRoot(root)

    return root
end

return MainMenu

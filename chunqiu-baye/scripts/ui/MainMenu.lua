--- MainMenu.lua - 进入页面（主菜单）
---
--- 统一"羊皮纸古卷"风格：标题 / 按钮 / 弹窗使用同一套配色（暖纸底 + 深棕描边 + 古金标题）。
--- 2026-09-01：
---   * 设置可点（音乐开关/切歌/音量，复用 MusicManager）
---   * 新增"退出游戏"按钮（engine:Exit）
---   * 新增"模组"按钮（打开模组面板：切换地图包，不带"开发中"）
---   * "编辑器"按钮（打开编辑器：国家/势力/领土/剧本等）
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
-- ============================================================
-- 弹窗配色（深靛金框，替代羊皮纸）
-- ============================================================
-- 配色统一走 ui/UISkin.lua（2026-09-13）：**改那一个文件 = 全游戏换风格**
--   （皮肤层是"配置层换皮"，将来模组带自己的皮肤文件即可换皮）
local UISkin = require("ui.UISkin")
local SK = UISkin.COLORS
local DLG_BG       = SK.panelBg
local DLG_BORDER   = SK.panelBorder
local DLG_TEXT     = SK.text
local DLG_DIM      = SK.textDim
local DLG_GOLD     = SK.gold
local DLG_GOLD_INK = SK.goldInk
local DLG_BTN_BG   = SK.inkBtn
local DLG_BTN_HOV  = SK.inkBtnHover
local DLG_ROW_BG   = SK.rowBg
local DLG_ROW_HOV  = SK.rowHover
local DLG_WARN     = SK.textWarn

local function GuFengButton(label, onClick, opts)
    opts = opts or {}
    -- 外观（2026-09-13 用户拍板）：**金漆木牌**（常规）/ **朱漆金纹**（主操作）
    --   样式全部来自 ui/UISkin.lua —— 改那一处就能整游戏换风格
    --   （入场动画、尺寸、顺序一律不动：用户点名说这段动画保留）
    -- 用户定稿：**所有按钮同一种样式**（不再有朱漆主操作），统一用 AI 生成的漆器牌匾底图
    local sp = UISkin.button(opts.kind or "normal", {
        width = opts.width or 360,
        height = opts.height or 56,
        fontSize = opts.fontSize or 20,
        textured = opts.textured ~= false,     -- 默认带底图；小胶囊可关掉
    })
    sp.id = opts.id
    sp.text = label
    -- 14 → 10（2026-10-05）：见标题 marginBottom 注释，为"有存档"多出的一行腾空间
    sp.marginBottom = opts.marginBottom or 10
    sp.onClick = onClick
    local btn = UI.Button(sp)
    if opts.intro then
        introAdd(btn, 0.08 * #intro_.items)   -- 交错浮现（注册即隐藏）
    end
    return btn
end

-- ============================================================
-- 通用弹窗壳（统一弹窗外观）
-- 2026-09-13 改版：深靛实色底 + 金棕描边（原为羊皮纸毛边素材）；尺寸按手机触控标准
-- ============================================================
--- 创建一个居中弹窗（深靛金框）
---@param title string|nil 弹窗标题；传 nil = 不显示标题（只留右上角 ✕，给内容腾一整行）
---@param children table 内容控件
---@param refs table 引用表（用于存取 overlay 句柄，便于开关）
---@param key string refs 中保存 overlay 的键名
local function createModal(title, children, refs, key, opts)
    opts = opts or {}

    -- 关闭钮：朱红印章（保留原来的印章风格，任何底上都醒目）
    local closeBtn = UI.Button {
        text = "X",
        width = 42,
        height = 42,
        fontSize = 22,
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
    }

    ---@type any[]
    local headerChildren = {}
    if title then
        headerChildren[#headerChildren + 1] = UI.Label {
            text = title,
            fontSize = 22,
            fontFamily = "gufeng",
            fontWeight = "bold",
            fontColor = DLG_GOLD,
        }
    end
    -- 标题后面的空地可以塞一个额外控件（如游玩集的"选中：xxx"）
    if opts.headerExtra then
        headerChildren[#headerChildren + 1] = opts.headerExtra
    end
    headerChildren[#headerChildren + 1] = UI.Panel { flexGrow = 1, flexShrink = 1 }
    headerChildren[#headerChildren + 1] = closeBtn

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
                -- fullscreen（2026-09-14）：**真的铺满整个屏幕**，不留那圈能看到背景的边。
                --   用户："为什么还能看到后边的内容，没有排满、没有直接挤满整个屏幕"
                --   全屏时不要圆角（圆角会在四角漏出后面的画面）
                width = opts.fullscreen and "100%" or (opts.width or 440),
                height = opts.fullscreen and "100%" or opts.height,
                maxHeight = opts.fullscreen and nil or opts.maxHeight,
                -- 实色矩形 + 描边：不再用羊皮纸素材（素材四周的烤焦卷边是画在图里的，
                -- 被拉伸到近全屏就变形 → "边缘都是卷着的、不完整"）
                backgroundColor = DLG_BG,
                borderWidth = opts.fullscreen and 0 or 1,
                borderColor = DLG_BORDER,
                borderRadius = opts.fullscreen and 0 or 12,
                padding = 16,
                gap = 10,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        width = "100%",
                        children = headerChildren,
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
    -- 开关按钮：开 = 金实心 + 墨字（一眼看出状态）；关 = 墨底描边
    refs.settingsMusicBtn = UI.Button {
        text = refs.musicOn and "音乐：开" or "音乐：关",
        width = "100%",
        height = 50,
        fontSize = 17,
        fontFamily = "gufeng",
        fontWeight = "bold",
        textColor = refs.musicOn and DLG_GOLD_INK or DLG_DIM,
        backgroundColor = refs.musicOn and DLG_GOLD or DLG_BTN_BG,
        hoverBackgroundColor = refs.musicOn and { 240, 210, 150, 255 } or DLG_BTN_HOV,
        pressedBackgroundColor = refs.musicOn and { 198, 164, 96, 255 } or { 32, 38, 52, 240 },
        borderColor = { 120, 100, 66, 200 },
        borderWidth = 1,
        borderRadius = 8,
        onClick = function(self)
            refs.musicOn = not refs.musicOn
            self:SetText(refs.musicOn and "音乐：开" or "音乐：关")
            -- 底色/字色跟着状态走（金实心 = 开）
            self:SetStyle {
                backgroundColor = refs.musicOn and DLG_GOLD or DLG_BTN_BG,
                textColor = refs.musicOn and DLG_GOLD_INK or DLG_DIM,
            }
            MusicManager.setEnabled(refs.musicOn)
        end,
    }

    -- 当前曲目
    refs.musicCurrentLabel = UI.Label {
        text = "正在播放：" .. (MusicManager.getCurrentName() or "无"),
        fontSize = 15,
        fontColor = DLG_DIM,
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
        triggerBgColor = DLG_BTN_BG,
        borderColor = { 120, 100, 66, 200 },
        hoverBorderColor = DLG_GOLD,
        openBorderColor = DLG_GOLD,
        popupBgColor = { 26, 32, 46, 252 },
        popupBorderColor = DLG_BORDER,
        itemHoverBgColor = { 56, 66, 88, 240 },
        itemSelectedColor = DLG_GOLD,
        itemSelectedTextColor = DLG_GOLD_INK,
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
        fontColor = DLG_DIM,
    }
    refs.musicVolumeSlider = UI.Slider {
        min = 0,
        max = 1,
        step = 0.01,
        value = MusicManager.getVolume(),
        height = 40,
        trackHeight = 8,
        thumbSize = 26,
        trackBgColor = { 52, 60, 78, 220 },
        trackFillColor = { 198, 164, 96, 255 },
        thumbColor = { 226, 192, 120, 255 },
        onChange = function(self, value)
            MusicManager.setVolume(value)
            refs.musicVolumeLabel.text = "音量：" .. math.floor(value * 100) .. "%"
        end,
    }

    local content = UI.Panel {
        width = "100%",
        gap = 14,
        children = {
            UI.Label { text = "音　乐", fontSize = 18, fontFamily = "gufeng", fontColor = DLG_GOLD, fontWeight = "bold" },
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
-- 模组面板（骨架版 2026-09-13 · 设计见 docs/制作清单.md A15）
--   类型标签（点击切换） + 排序（热门待后端，先灰显） + 模组列表
--   ⚠️ 2026-09-14 用户精简：删掉了"游玩集（文件夹）"和"地图选择"两块 ——
--      这个面板**就是「模组」**，别的都是噪音（地图改在【开始新游戏】弹窗里选）
--   ⚠️ 本版只"登记 + 勾选"（ModManager），不做真正的覆盖式加载
-- ============================================================

---@param refs table
---@param options table 包含 onModToast callback
---@return Widget
local function createModsOverlay(refs, options)
    local ModManager = require("mods.ModManager")

    -- 类型标签（清单 A15 ②：可多选标签 + "其他"兜底；"前置"不是分类）
    --
    -- 顺序是**用户定的两头 + 我排的中间**（2026-09-14 定稿）：
    --   最左 = 官方，左二 = 全部   ← 两个"筛选"，永远在最前，手熟了直接点
    --   最右 = 整合包，右二 = 其他  ← "整套"给专门的位子；"其他"兜底挨着它
    --   中间按**"从骨架到皮肤"**排：
    --     地图/剧本（世界的骨架）→ 玩法系统（规则）→ 文化 → 角色（世界里的人和族群）
    --     → 事件（玩的时候发生的）→ 美术音效（最外层的表现）
    --
    -- 2026-09-14 删掉过：「文本语言」（不做多语言）、「数值平衡」「界面便利」（没人会只做这个）
    -- 同日又加回/新增：「文化」「事件」「角色」（用户要求 —— 这三个系统本体都做了，会有对应模组）
    -- 2026-09-14 再加「原版修改」（用户定的名）：
    --   给"觉得原版军事/经济不怎么样、在它基础上改"的那类模组。
    --   和「玩法系统」的分工：**玩法系统 = 往里加，原版修改 = 改现有的**。
    --   讨论过的名字：全面改造 / 魔改 / 平衡 / 大改 / 改造 / 改制 / 变法 / 重制 —— 用户选了「原版修改」。
    --   （「魔改」带贬义，官方分类词不该用；「平衡」用户早先删过，理由"没人会只做平衡"）
    --
    -- 硬约束没丢：**前置/要哪张图不是分类，是字段**（dependencies / requires_map），引擎照样会查
    --
    -- 🔴 **一整串，且每个都 flexGrow**（2026-09-14 二次修正）：
    --    用户："最右边是他们所有的在一起""没排满，没直接挤满整个屏幕""放大缩小都要占满"。
    --    → 让标签**均分剩余宽度**：彼此紧挨（没空档）、右边缘正好顶到行尾、
    --      **窗口放大缩小都自动铺满**（不用改数字）。
    --    之前试过"拆两段 + space-between"——那样中间会留一个大空档，正是用户说的问题。
    local TAGS = { "官方", "全部", "地图/剧本", "玩法系统", "原版修改", "文化", "角色", "事件",
                   "美术音效", "其他", "整合包" }
    local SORTS = { "最热门", "一周内最热门", "最新更新", "最新上线" }
    local HOT_SORTS = { ["最热门"] = true, ["一周内最热门"] = true }   -- 需要后端统计 → 先灰显

    local curTag = "全部"
    local curSort = "最新更新"

    -- 2026-09-14 用户要求**删掉三样**（"这玩意儿没必要"）：
    --   ① 顶部那句"启用哪些模组由「文件夹（游玩集）」决定；地图跟着文件夹走"
    --   ② 那行"当前文件夹：标准（在主页【新的游戏】右边切换）"
    --   ③ 底部的"本文件夹的地图"+ 地图下拉
    --   → 这个面板回归成**就是「模组」**：标签 + 排序 + 列表。别的都是噪音。
    --   （地图改在【开始新游戏】弹窗里选，那里本来就有）

    -- ---------------- 三段可重建区（标签 / 排序 / 列表） ----------------
    -- 🔴 2026-09-13 修 bug：点标签时只重建了列表，**标签行本身没重建** →
    --    "点了官方，官方不亮"（用户反馈）。高亮是建按钮时算死的，
    --    所以 curTag/curSort 一变，这三行必须一起重建。
    -- 标签行：宽度 100% + 每个标签 flexGrow=1 → 均分剩余宽度、铺满整行、右边缘顶齐
    --   flexWrap 留着当兜底：屏太窄（放不下最小宽度）才换行，正常情况一行铺满
    local tagHolder = UI.Panel { flexDirection = "row", gap = 4, width = "100%", flexWrap = "wrap" }
    local sortHolder = UI.Panel { flexDirection = "row", gap = 6, alignItems = "center", width = "100%" }
    local listHolder = UI.Panel { width = "100%", gap = 6, flexDirection = "column" }

    -- 类型标签（金框墨底；选中 = 金实心 + 墨字）
    -- 尺寸按手机触控放宽（用户反馈"放大之后按钮没跟着放大，手机点不了"）
    local function tagButton(text)
        local active = (text == curTag)
        return UI.Button {
            text = text,
            height = 42,            -- 触控高度**不动**（手机点得着）
            -- 字号 13 + 内边距 6：**11 个标签要在 800×600 这种常见尺寸下也排得下一行**。
            --   实测：11 个标签时，字号 14 / 内边距 8 在 800 宽下会换行（"整合包"掉第二行），
            --   而"最右是整合包"是用户明确要的 → 只能再收一档。
            --   ⚠️ 这是**权衡**：标签多了就得小一点。再加标签的话，先看这行还塞不塞得下。
            fontSize = 13,
            paddingHorizontal = 6,
            flexGrow = 1,           -- ★ 均分剩余宽度 → 整行铺满、右边缘顶齐、缩放自适应
            flexShrink = 1,
            -- ★ 上限 150：**防止"落到第二行的那一个"被拉成整条大横条**。
            --   宽屏上根本碰不到这个上限（要涨的只有 +50 左右）；只在"屏太窄、换行了"时才兜住。
            maxWidth = 150,
            fontFamily = "gufeng",
            fontWeight = "bold",
            textColor = active and DLG_GOLD_INK or DLG_TEXT,
            backgroundColor = active and DLG_GOLD or DLG_BTN_BG,
            hoverBackgroundColor = active and { 240, 210, 150, 255 } or DLG_BTN_HOV,
            pressedBackgroundColor = active and { 198, 164, 96, 255 } or { 32, 38, 52, 240 },
            borderRadius = 8,
            borderWidth = 1,
            borderColor = active and { 120, 96, 54, 220 } or { 120, 100, 66, 180 },
            onClick = function()
                curTag = text
                if refs.modsRebuild then refs.modsRebuild() end
            end,
        }
    end

    -- 排序（同上；热门两种需要后端统计 → 灰显不可点）
    local function sortButton(text)
        local hot = HOT_SORTS[text]
        local active = (text == curSort) and not hot
        return UI.Button {
            text = hot and (text .. "(待接入)") or text,
            height = 30,
            fontSize = 12,
            paddingHorizontal = 10,
            textColor = hot and { 130, 134, 146, 220 }
                or (active and DLG_GOLD_INK or DLG_DIM),
            backgroundColor = hot and { 30, 36, 50, 140 }
                or (active and DLG_GOLD or { 0, 0, 0, 0 }),
            hoverBackgroundColor = active and { 240, 210, 150, 255 } or DLG_BTN_HOV,
            pressedBackgroundColor = active and { 198, 164, 96, 255 } or { 32, 38, 52, 240 },
            borderRadius = 6,
            borderWidth = 1,
            borderColor = hot and { 90, 88, 84, 140 }
                or (active and { 120, 96, 54, 220 } or { 120, 100, 66, 140 }),
            onClick = function()
                if hot then return end            -- 热门排序需要后端统计（清单 A15 ①）
                curSort = text
                if refs.modsRebuild then refs.modsRebuild() end
            end,
        }
    end

    --- 一行模组
    local function modRow(m)
        local enabled = ModManager.isEnabled(m.id)
        local missing = ModManager.missingDeps(m)
        local subtitle
        if #missing > 0 then
            local first = missing[1]
            subtitle = string.format("⚠ 缺 %s（%s）—— 它是「%s」的前置",
                tostring(first.id), first.needVersion and (">=" .. first.needVersion) or "前置",
                tostring(first.forName))
        elseif m.author then
            subtitle = string.format("by %s · v%s%s", tostring(m.author), tostring(m.version or "?"),
                m.requires_map and ("  · 需地图 " .. tostring(m.requires_map)) or "")
        else
            subtitle = string.format("v%s", tostring(m.version or "?"))
        end

        local tagText = m.official and "官方" or ((m.tags and m.tags[1]) or "其他")
        -- 启用状态钮：已启用 = 金实心 + 墨字（一眼看出开着的）；本体 = 锁死的灰金
        local enableBtn
        if m.locked then
            enableBtn = UI.Button {
                text = "本体", width = 52, height = 32, fontSize = 12,
                backgroundColor = { 30, 36, 50, 160 },
                hoverBackgroundColor = { 30, 36, 50, 160 },
                textColor = { 168, 148, 104, 220 },
                borderWidth = 1, borderColor = { 110, 96, 66, 160 }, borderRadius = 6,
            }
        else
            -- 拨杆开关（2026-09-14 用户要求）：开 = **绿**，关 = **本色**（面板的深靛底）
            --   ⚠️ **关不用红色** —— 红 = 危险/错误，会让人以为模组出问题了。
            --   这是各家通用做法（Minecraft 启动器 / 各类设置页都是"绿开、灰关"）。
            enableBtn = UI.Toggle {
                value = enabled,
                trackWidth = 56, trackHeight = 30, thumbSize = 26,   -- 手机点得着
                -- 开：暗绿轨道 + 亮滑块
                trackCheckedBgColor = { 74, 138, 66, 255 },
                trackCheckedHoverBgColor = { 88, 158, 78, 255 },
                trackCheckedBorderColor = { 112, 178, 98, 220 },
                trackCheckedHoverBorderColor = { 140, 210, 124, 240 },
                thumbCheckedColor = { 244, 248, 238, 255 },
                -- 关：本色（就是面板底那种墨靛），不是红
                trackBg = DLG_BTN_BG,
                trackHoverBgColor = DLG_BTN_HOV,
                trackBorderColor = { 120, 100, 66, 170 },
                trackHoverBorderColor = DLG_GOLD,
                thumbColor = { 186, 182, 172, 255 },
                thumbHoverColor = { 214, 210, 198, 255 },
                onChange = function(_, v)
                    local ok, reason = ModManager.setEnabled(m.id, v)
                    if not ok then
                        if options.onModToast then options.onModToast(reason) end
                        print("[Mod] " .. tostring(reason))
                    end
                    if refs.modsRebuild then refs.modsRebuild() end
                end,
            }
        end

        return UI.Panel {
            width = "100%",
            flexDirection = "row",
            alignItems = "center",
            gap = 10,
            padding = 8,
            borderRadius = 8,
            backgroundColor = DLG_ROW_BG,
            borderWidth = 1,
            borderColor = { 120, 100, 66, 120 },
            children = {
                enableBtn,
                UI.Panel {
                    flexGrow = 1, flexShrink = 1, gap = 2, flexDirection = "column",
                    children = {
                        UI.Label {
                            text = tostring(m.name) .. "   v" .. tostring(m.version or "?") ..
                                   "   [" .. tagText .. "]",
                            fontSize = 14,
                            fontFamily = "gufeng",
                            fontWeight = "bold",
                            fontColor = DLG_TEXT,
                        },
                        UI.Label {
                            text = subtitle,
                            fontSize = 11,
                            fontColor = (#missing > 0) and DLG_WARN or DLG_DIM,
                            whiteSpace = "normal",
                            maxLines = 2,
                        },
                    },
                },
            },
        }
    end

    local function rebuildMods()
        -- 标签行 & 排序行**也要重建**：高亮是建按钮时算死的（active = text == curTag），
        -- 只重建列表 → 点了"官方"它不亮（用户反馈的 bug）
        tagHolder:ClearChildren()
        for _, t in ipairs(TAGS) do tagHolder:AddChild(tagButton(t)) end
        sortHolder:ClearChildren()
        for _, s in ipairs(SORTS) do sortHolder:AddChild(sortButton(s)) end

        listHolder:ClearChildren()
        local mods = ModManager.listByTag(curTag)
        -- 排序（"最新更新/最新上线" 用 updated_at；热门待后端）
        table.sort(mods, function(a, b)
            if a.locked ~= b.locked then return a.locked end
            if a.official ~= b.official then return a.official end
            return tostring(a.updated_at or "") > tostring(b.updated_at or "")
        end)
        for _, m in ipairs(mods) do
            listHolder:AddChild(modRow(m))
        end
    end
    refs.modsRebuild = rebuildMods

    -- 顶部：标签行 + 排序行 + 列表（滚动）
    local content = UI.Panel {
        width = "100%",
        -- flexGrow + flexBasis=0：**撑满面板剩余高度**，列表才能吃掉剩下的地方。
        --   （原来靠"下面还有说明+地图下拉"把高度顶出来 —— 那两块删了之后，
        --     这里不补上，列表就只剩 minHeight，下面空一大片）
        flexGrow = 1, flexBasis = 0,
        gap = 10,
        children = {
            tagHolder,
            sortHolder,
            UI.ScrollView {
                -- 占满"面板剩余高度"：小屏也不会被截断，大屏自动变长
                -- （flexBasis=0 + flexGrow=1 是 ScrollView 的标准用法）
                width = "100%", flexGrow = 1, flexBasis = 0, minHeight = 140,
                children = { listHolder },
            },
        },
    }

    -- 标题（2026-09-14）：用户说叉号那一横"很多空白"，要在那显示标题。
    --   选「模组」而不是「创意工坊」：
    --     ① 主菜单那个按钮就叫「模组」，一致
    --     ② 「创意工坊」暗示"能下载别人做的东西" —— **那个功能还没有**（要服务器），
    --        叫了名字玩家点进来发现只有本地几个模组，会失望。等真做了分发再改名。
    -- fullscreen：用户 2026-09-14 "为什么还能看到后边的内容，没挤满整个屏幕"
    local overlay = createModal("模组", content, refs, "modsOverlay", { fullscreen = true })
    -- 离屏测试用：让 `SHOT_MODTAG=官方` 能模拟"点了这个标签"（截图点不了鼠标）

    overlay.modsSetTag_ = function(t)
        curTag = tostring(t)
        if refs.modsRebuild then refs.modsRebuild() end
    end
    rebuildMods()
    return overlay
end

-- ============================================================
-- 「读档前确认」弹窗（2026-09-14 · 用户设计）
--
--   什么时候弹：**存档当时启用的模组 ≠ 当前游玩集启用的模组**（缺/多/版本变）
--   三个按钮（用户原话）：
--     ① 直接进入            —— 用**现在**的模组进（"采用的模组应该是你现在的模组"）
--     ② 改回存档的模组并进入 —— 切到存档当时那个游玩集，再进
--     ③ 取消
--
--   为什么要有它：原来读档会**默默把游玩集切回存档那个** ——
--   玩家刚在主菜单改的勾选被无声覆盖，一头雾水（见 SaveManager.checkMods 的注释）
-- ============================================================
---@param refs table
---@return Widget
local function createLoadModsOverlay(refs)
    local listHolder = UI.Panel { flexDirection = "column", gap = 6, width = "100%" }
    local intro = UI.Label { text = "", fontSize = 13, fontColor = DLG_DIM, whiteSpace = "normal", maxLines = 3 }

    -- ⚠️ 三个按钮**先造出来**（props 上设好 text/onClick，再交给 UI.Button）：
    --   ① `UISkin.button()` 返回的是 **props 表**，不是控件 —— 存它当句柄会 "attempt to call a nil value"
    --   ② 控件的 `onClick` 要写在 **props** 里：Button 内部读的是 `self.props.onClick`，
    --      事后 `widget.onClick = fn` 只是加了个没人读的实例字段（按钮点了没反应）
    local cancelProps = UISkin.button("secondary", { width = 90, height = 42, fontSize = 14 })
    cancelProps.id = "loadmods_cancel"          -- 供 UI.FindById 查找（离屏测试点它）
    cancelProps.text = "取消"
    cancelProps.onClick = function() MainMenu.resetLoadMods() end
    local cancelBtn = UI.Button(cancelProps)

    -- 「改回存档的模组并进入」：存档那个游玩集**已经被删了**就没得改回 → 灰掉
    local backProps = UISkin.button("normal", { width = 190, height = 42, fontSize = 14 })
    backProps.id = "loadmods_back"
    backProps.text = "改回存档的模组并进入"
    backProps.onClick = function()
        local d = refs.loadModsDiff_
        if not d or not d.savePlaysetExists then return end
        require("mods.ModManager").setActivePlayset(d.savePlayset)
        print("[Load] 已改回存档的游玩集：" .. tostring(d.savePlayset))
        MainMenu.resetLoadMods("back")
    end
    local backBtn = UI.Button(backProps)
    refs.loadModsBackBtn = backBtn

    local enterProps = UISkin.button("primary", { width = 130, height = 42, fontSize = 14 })
    enterProps.id = "loadmods_enter"
    enterProps.text = "直接进入"
    enterProps.onClick = function() MainMenu.resetLoadMods("enter") end
    local enterBtn = UI.Button(enterProps)

    local content = UI.Panel {
        width = "100%", gap = 10,
        children = {
            intro,
            UI.Divider { color = DLG_BORDER, thickness = 1 },
            UI.ScrollView { width = "100%", minHeight = 100, maxHeight = 220,
                children = { listHolder } },
            UI.Panel {
                flexDirection = "row", gap = 8, width = "100%", justifyContent = "flex-end",
                children = { cancelBtn, backBtn, enterBtn },
            },
        },
    }

    refs.loadModsHolder = listHolder
    refs.loadModsIntro = intro
    -- 不给 height：让面板**按内容自适应**。给死高度（原来 72%）会在列表短的时候留一大片空
    --   （列表长的时候由 ScrollView 的 maxHeight = 220 兜住，不会撑破屏）
    return createModal("读档前确认", content, refs, "loadModsOverlay", { width = "74%" })
end

-- ============================================================
-- 「选一个包来导入」弹窗（导出/导入那套的配套）
--   exports/ 里的 .upk 列出来，点一个就导入
--   为什么不做"选文件对话框"：引擎**没有**文件选择器，也读不到沙箱外的目录
-- ============================================================
---@param refs table
---@return Widget
local function createPackPickerOverlay(refs)
    local listHolder = UI.Panel { flexDirection = "column", gap = 6, width = "100%" }
    local hint = UI.Label { text = "", fontSize = 12, fontColor = DLG_DIM, height = 20 }
    ---@param msg string
    ---@param warn boolean|nil
    local function setHint(msg, warn)
        hint.text = msg or ""
        hint:SetFontColor(warn and DLG_WARN or DLG_DIM)
    end

    --- 重扫 exports/ 把包列出来（每次打开都调）
    ---@param keepHint boolean|nil true = 保留提示行（导完刷列表时用，不然刚写的提示会被自己清掉）
    refs.packPickerRefresh = function(keepHint)
        local ModPack = require("mods.ModPack")
        listHolder:ClearChildren()
        if not keepHint then setHint("") end
        local shown = 0
        for _, p in ipairs(ModPack.listPacks()) do
            local m = p.manifest
            if m then
                shown = shown + 1
                local isSet = (m.kind == "playset")
                local line = string.format("%s　%s　·　%s　·　%s 个文件　·　%s",
                    isSet and "【整套】" or "【模组】",
                    tostring(m.name or "?"),
                    isSet and ("地图 " .. tostring(m.map or "无")) or ("id " .. tostring(m.id or "?")),
                    tostring(m.files or 0),
                    tostring(m.created_at or ""))
                local sp = UISkin.button("normal", { width = "100%", height = 48, fontSize = 13 })
                sp.id = "packRow_" .. p.file
                sp.text = line
                sp.onClick = function()
                    local ok, msg = ModPack.importPack(p.path)
                    -- 导完立刻刷新：左侧文件夹列表、右侧模组清单都要能看到新东西
                    if refs.playsetRefresh then refs.playsetRefresh() end
                    refs.packPickerRefresh(true)      -- true = 别把下面这行提示清掉
                    setHint(ok and ("导入成功：" .. msg) or ("导入失败：" .. msg), not ok)
                end
                listHolder:AddChild(UI.Button(sp))
            else
                shown = shown + 1
                listHolder:AddChild(UI.Label {
                    text = string.format("⚠ %s 读不了：%s", p.file, tostring(p.err)),
                    fontSize = 13, fontColor = DLG_WARN, whiteSpace = "normal",
                })
            end
        end
        if shown == 0 then
            listHolder:AddChild(UI.Label {
                text = "exports/ 里还没有包。先回游玩集面板按「导出整套」，导出一个才会出现在这里。",
                fontSize = 13, fontColor = DLG_DIM, whiteSpace = "normal",
            })
        end
    end

    local content = UI.Panel {
        width = "100%", gap = 10, flexGrow = 1, flexBasis = 0,
        children = {
            UI.Label {
                text = "从游戏的 exports/ 里选一个包导进来。整套包会连模组一起装好，并自动多出一个文件夹。",
                fontSize = 13, fontColor = DLG_DIM, whiteSpace = "normal", maxLines = 2,
            },
            UI.Divider { color = DLG_BORDER, thickness = 1 },
            UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0, minHeight = 160,
                children = { listHolder } },
            hint,
        },
    }
    local overlay = createModal("导入", content, refs, "packPickerOverlay", { width = "86%", height = "80%" })
    -- 每次打开都重扫一遍 exports/（不然看到的是上次那份列表；也免得调用方每次记得调刷新）
    local baseShow = overlay.Show
    overlay.Show = function(self, ...)
        baseShow(self, ...)
        refs.packPickerRefresh()
    end
    return overlay
end

-- ============================================================
-- 游玩集（文件夹）大面板（2026-09-13 用户要求）
--   用户原话："点开这个游玩集怎么是往下弄，而不是出现一个大的在里边能够看详细的模组？
--              这个地方太小了，我根本不知道这个作用是什么"
--   → 所以：**独立按钮 + 大面板** = 说明"这是什么" + 列出它包含的模组 + 管理（新建/重命名/复制/删除）
-- ============================================================
---@return Widget
local function createPlaysetOverlay(refs)
    local ModManager = require("mods.ModManager")

    -- 「选中」≠「应用」（2026-09-14 用户定）：
    --   点文件夹那一下 = **只选中**（朱漆高亮 + 下面这一列都跟着它走），
    --   底部按「应用」才真的切过去。所以这里要单独记"面板正在看的是哪个"。
    local sel = ModManager.getActivePlayset()
    --- 面板正在看的文件夹（选中但可能还没应用）
    local function curName()
        return sel or ModManager.getActivePlayset()
    end
    refs.playsetSelect = function(name)
        sel = name
        refs.playsetRefresh()
    end

    -- 左列：文件夹列表（选中 = 朱漆金纹）
    local listHolder = UI.Panel { flexDirection = "column", gap = 6, width = "100%" }
    -- 右列：这个文件夹包含的模组
    local modsHolder = UI.Panel { flexDirection = "column", gap = 6, width = "100%" }
    -- 名字框：**显示当前文件夹自己的名字**（不是空框 + "新名字"占位）
    --   用户："这个长框不是应该这个样子，而是应该这个文件它本身是个什么就在这里显示，可以进行修改"
    --   改完**不点「保存」就不生效**（刷新时会被重置回当前名字）
    refs.playsetRenameField = UI.TextField {
        id = "playsetRenameField",             -- 供 UI.FindById 查找（离屏测试给它填字）
        placeholder = "文件夹名字", height = 40, flexGrow = 1, flexShrink = 1,
    }
    -- 「一键补全」按钮：**先造出来**（refresh 要拿它的句柄做灰显），再塞进底部那一排
    --   ⚠️ 必须存 UI.Button(...) 的返回值（控件），不能存 UISkin.button(...) 的返回值（那是 props 表）
    local fixProps = UISkin.button("normal", { width = 100, height = 40, fontSize = 14 })
    fixProps.id = "playsetFixBtn"          -- 供 UI.FindById 查找（离屏测试点它）
    fixProps.text = "一键补全"
    fixProps.onClick = function()
        -- 下载源还没接入（清单 A15 分发链路）→ 点了只能把话说清楚
        refs.playsetSetHint("补全要等「模组分发」接入；现在请手动把缺的模组放进 mods/ 文件夹", true)
        print("[Mod] ⚠️ 一键补全：分发功能还没接入（见清单 A15 分发链路）")
    end
    refs.playsetFixBtn = UI.Button(fixProps)

    -- 「应用」：把**选中的**文件夹真正切成当前使用的（用户："点就是现在应用，这个就叫做应用"）
    --   选中 ≠ 应用是用户 2026-09-14 定的：点一下只红一下，按这个才生效
    local applyProps = UISkin.button("primary", { width = 80, height = 40, fontSize = 14 })
    applyProps.id = "playsetApplyBtn"
    applyProps.text = "应用"
    applyProps.onClick = function()
        local MM = require("mods.ModManager")
        local target = curName()
        if target == MM.getActivePlayset() then
            refs.playsetSetHint(string.format("「%s」已经在用了", tostring(target)))
        elseif MM.setActivePlayset(target) then
            local mapId = MM.getPlaysetMap(target)
            -- ⚠️ 用 switchTo（不是 setActive）：setActive 只切字段，省份数据/渲染常量还停在
            --    旧包 → 之后进选国页/开局是"半套"状态（2026-09-15 修）
            if mapId then require("data.MapPack").switchTo(mapId) end
            print("[Mod] 应用文件夹：" .. tostring(target))
            refs.playsetRefresh()
            refs.playsetSetHint(string.format("已应用「%s」", tostring(target)))
        else
            refs.playsetSetHint("应用失败", true)
        end
    end
    refs.playsetApplyBtn = UI.Button(applyProps)

    -- 标题后面的"选中：xxx"（用户："最上面的游玩集后边不是很大的空地吗，在这里显示选中"）
    refs.playsetSelLabel = UI.Label { text = "", fontSize = 14, fontColor = DLG_DIM }

    -- 底部提示行：保存/补全的反馈（不然点了没反应）
    --   固定高度：左列的「新建文件夹」下面会垫一块同样高的空，好让两列的底边**对齐**
    --   （用户："新建文件夹和右边那一堆同行，感觉有点别扭" → 选的是"只把高度对齐，不动位置"）
    refs.playsetHint = UI.Label { text = "", fontSize = 12, fontColor = DLG_DIM, height = 20 }
    --- 设置提示文字（msg 为空 = 清掉）
    ---@param msg string
    ---@param warn boolean|nil  true = 用警告色
    refs.playsetSetHint = function(msg, warn)
        refs.playsetHint.text = msg or ""
        refs.playsetHint:SetFontColor(warn and DLG_WARN or DLG_DIM)
    end

    --- 刷新面板（打开时 + 任何改动后都调）
    refs.playsetRefresh = function()
        local active = ModManager.getActivePlayset()
        local names = ModManager.listPlaysetNames()

        local cur = curName()

        -- 标题后面：选中哪个 / 正在用哪个
        --   两者不一样时才把"正在使用"也写出来（一样就只说一句，别啰嗦）
        refs.playsetSelLabel.text = (cur == active)
            and string.format("选中：%s（正在使用）", tostring(cur))
            or string.format("选中：%s　·　正在使用：%s", tostring(cur), tostring(active))

        -- 名字框 = **选中的那个**文件夹的名字（改了不点「保存」就不生效，刷新会重置回来）
        refs.playsetRenameField:SetValue(tostring(cur))
        refs.playsetSetHint("")

        -- 左：文件夹（**点一下 = 只选中**；要真切过去按底部「应用」）
        listHolder:ClearChildren()
        for _, n in ipairs(names) do
            local isSel = (n == cur)          -- 选中 → 朱漆高亮
            local isUsing = (n == active)     -- 正在用 → 挂一个「使用中」小签
            local sp = UISkin.button(isSel and "primary" or "normal", { width = "100%", height = 44, fontSize = 15 })
            sp.id = "playsetRow_" .. n        -- 供 UI.FindById 查找（离屏测试点某一行）
            -- ⚠️ 原来这里挂了个「●」，用户说"变红也就算了，为什么还有这个白圈" → 去掉
            sp.text = tostring(n) .. (isUsing and "　使用中" or "")
            sp.onClick = function()
                if sel == n then return end   -- 点的就是已选中的 → 不用刷
                sel = n
                refs.playsetRefresh()
            end
            listHolder:AddChild(UI.Button(sp))
        end

        -- 右：包含的模组（2026-09-14 用户要求）：
        --   ① 每条标出**类型**（[玩法系统] / [地图剧本] …，取 mod.json 的 tags）
        --   ② **缺的单独列一段**，并写清"它是谁的前置" → 一眼看出缺什么、为什么缺
        --   （"一键补全"没做：下载源还没落地，先不做点了没反应的按钮）
        modsHolder:ClearChildren()
        local ps = ModManager.playsets_[cur]
        local mods = (ps and ps.mods) or {}
        --- 一行模组：名字 v版本 + [类型] + （官方小标，如果类型没写"官方"的话）
        ---@param nameText string
        ---@param tag string 类型（原样，不带方括号）
        ---@param official boolean
        local function modRow(nameText, tag, official)
            ---@type any[]
            local kids = {
                UI.Label {
                    text = tostring(nameText), fontSize = 14, fontFamily = "gufeng",
                    fontWeight = "bold", fontColor = DLG_TEXT, flexGrow = 1, flexShrink = 1,
                },
                UI.Label { text = "[" .. tostring(tag) .. "]", fontSize = 12, fontColor = DLG_GOLD, flexShrink = 0 },
            }
            -- 🔴 2026-09-14 修重复：本体的 tags 本来就是「官方」，再挂一个「官方」小标
            --   → 显示成 "[官方] 官方"。用户："本来就有一个官方，后面怎么又加了这两个字"
            --   小标是给"官方出品、但类型是别的"的模组用的（如 [地图/剧本] 官方），
            --   类型已经是「官方」时就别再重复了
            if official and tag ~= "官方" then
                kids[#kids + 1] = UI.Label { text = "官方", fontSize = 12, fontColor = DLG_DIM, flexShrink = 0 }
            end
            return UI.Panel {
                width = "100%", flexDirection = "row", alignItems = "center", gap = 8,
                padding = 8, borderRadius = 8, backgroundColor = DLG_ROW_BG,
                borderWidth = 1, borderColor = { 120, 100, 66, 120 },
                children = kids,
            }
        end

        -- 拆成"装了的"和"缺的"
        --   缺的有两个来源，都要列出来：
        --     ① 游玩集里点了名，但 mods/ 里没有（比如作者删了、或者从别人那复制了套配置）
        --     ② 装了的模组的前置没装（mod.json 的 dependencies）← 这个才是最常见的"缺"
        local installed = {}
        ---@type string[]
        local missingIds = {}
        ---@type table<string, string|false>  id -> 为什么缺（false = 只是游玩集里列了但没装）
        local missingWhy = {}
        local function addMissing(id, why)
            local key = tostring(id)
            if missingWhy[key] == nil then
                missingIds[#missingIds + 1] = key
                missingWhy[key] = why or false
            elseif why and missingWhy[key] == false then
                missingWhy[key] = why     -- 补上更具体的理由（"它是 X 的前置" 比 "没装" 有用）
            end
        end
        for _, id in ipairs(mods) do
            local m = ModManager.mods_[tostring(id)]
            if m then installed[#installed + 1] = m
            else addMissing(id, "这套游玩集里有它，但 mods/ 文件夹里没有") end
        end
        for _, m in ipairs(installed) do
            for _, miss in ipairs(ModManager.missingDeps(m)) do
                addMissing(miss.id, string.format("它是「%s」的前置", tostring(miss.forName)))
            end
        end
        print(string.format("[Playset] 「%s」已装 %d / 缺 %d（%s）%s",
            tostring(cur), #installed, #missingIds, table.concat(missingIds, ","),
            (cur == active) and "" or ("　[使用中：" .. tostring(active) .. "]")))

        -- 「一键补全」：没有缺的就灰掉（不做"点了没用"的按钮）
        if refs.playsetFixBtn then refs.playsetFixBtn:SetDisabled(#missingIds == 0) end

        for _, m in ipairs(installed) do
            local tag = (m.tags and m.tags[1]) or (m.official and "官方" or "其他")
            modsHolder:AddChild(modRow(
                string.format("%s  v%s", tostring(m.name or m.id), tostring(m.version or "?")),
                tostring(tag),
                m.official))
        end
        if #mods == 0 then
            modsHolder:AddChild(UI.Label { text = "（这个文件夹里还没有模组）", fontSize = 13, fontColor = DLG_DIM })
        end

        -- 缺失段：单列 + 说清"它是谁的前置"
        if #missingIds > 0 then
            modsHolder:AddChild(UI.Panel { height = 6 })
            modsHolder:AddChild(UI.Label {
                text = string.format("⚠ 缺失 %d 个（装上才能用这一套）", #missingIds),
                fontSize = 13, fontFamily = "gufeng", fontWeight = "bold", fontColor = DLG_WARN,
            })
            for _, id in ipairs(missingIds) do
                local why = missingWhy[id]
                modsHolder:AddChild(UI.Panel {
                    width = "100%", flexDirection = "row", alignItems = "center", gap = 8,
                    padding = 10, borderRadius = 8,
                    backgroundColor = { 58, 30, 28, 220 },         -- 暗红底：一眼看出是缺的
                    borderWidth = 1, borderColor = { 170, 80, 60, 180 },
                    children = {
                        UI.Label { text = "缺失：" .. id, fontSize = 14, fontFamily = "gufeng",
                            fontWeight = "bold", fontColor = DLG_WARN, flexShrink = 0 },
                        UI.Label { text = why or "（没有找到它在为哪个模组服务）",
                            fontSize = 12, fontColor = DLG_DIM, flexGrow = 1, flexShrink = 1 },
                    },
                })
            end
        end
    end

    local content = UI.Panel {
        width = "100%", gap = 10, flexGrow = 1, flexBasis = 0,
        -- 2026-09-14 用户减法：删掉顶部说明段、左列「文件夹」标题、右列「「X」包含的模组…」标题
        --   —— "中间这一行这一堆是什么东西，这好像是没有用的"
        --   面板名就是「游玩集」，左边一坨明显是文件夹、右边一坨明显是模组，不用再挂标题
        children = {
            UI.Divider { color = DLG_BORDER, thickness = 1 },
            UI.Panel {
                flexDirection = "row", gap = 12, width = "100%", flexGrow = 1, flexBasis = 0,
                children = {
                    -- 左：文件夹列表 + 新建
                    UI.Panel {
                        width = 200, gap = 6, flexShrink = 0,   -- 200：留得下"名字 + 使用中"小签
                        children = {
                            -- 文件夹列表**单独围一个框**（用户："弄出一个框，和其他都不一样，能明显看出这一个"）
                            --   → 比面板底更深 + 金棕描边 + 内边距；右边模组列表保持无框，一眼分清两坨
                            --   marginBottom：框**不贴着**下面的「＋新建文件夹」
                            UI.ScrollView {
                                width = "100%", flexGrow = 1, flexBasis = 0, minHeight = 120,
                                marginBottom = 8,
                                backgroundColor = { 12, 15, 24, 220 },
                                borderWidth = 1,
                                borderColor = { 150, 120, 70, 150 },
                                borderRadius = 8,
                                padding = 6,
                                children = { listHolder },
                            },
                            UI.Button((function()
                                local sp = UISkin.button("normal", { width = "100%", height = 40, fontSize = 13 })
                                sp.text = "＋ 新建文件夹"
                                sp.onClick = function()
                                    local n = 2
                                    while ModManager.playsets_["新游玩集" .. n] do n = n + 1 end
                                    local name = "新游玩集" .. n
                                    ModManager.createPlayset(name)
                                    -- 新建 = 只**选中**（"选中 ≠ 应用"），要真用还得按底部「应用」
                                    sel = name
                                    refs.playsetRefresh()
                                    refs.playsetSetHint(string.format("已新建「%s」（按「应用」才切过去）", name))
                                    print("[Mod] 新建游玩集：" .. name)
                                end
                                return sp
                            end)()),
                            -- 导入 / 导出**整套**（2026-09-14 用户定：整套的按钮归游玩集面板）
                            --   放左列而不是右下角：① 右边那排已经 6 个控件，再加就挤爆
                            --   ② 这两个动作是"管整套文件夹"的，跟「新建文件夹」放一起才顺
                            UI.Button((function()
                                local sp = UISkin.button("secondary", { width = "100%", height = 40, fontSize = 14 })
                                sp.id = "playsetImportBtn"
                                sp.text = "导入整套"
                                -- Show() 自己会刷新列表（见 createPackPickerOverlay 尾部）
                                sp.onClick = function()
                                    if refs.packPickerOverlay then refs.packPickerOverlay:Show() end
                                end
                                return sp
                            end)()),
                            UI.Button((function()
                                local sp = UISkin.button("secondary", { width = "100%", height = 40, fontSize = 14 })
                                sp.id = "playsetExportBtn"
                                sp.text = "导出整套"
                                sp.onClick = function()
                                    local ModPack = require("mods.ModPack")
                                    local ok, msg = ModPack.exportPlayset(curName())
                                    if ok then
                                        refs.playsetSetHint(string.format("已导出到 %s（桌面端可拷出来发给别人）", tostring(msg)))
                                    else
                                        refs.playsetSetHint("导出失败：" .. tostring(msg), true)
                                    end
                                end
                                return sp
                            end)()),
                        },
                    },
                    -- 右：包含的模组 + 管理
                    UI.Panel {
                        flexGrow = 1, flexShrink = 1, gap = 6,
                        children = {
                            UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0, minHeight = 120,
                                children = { modsHolder } },
                            UI.Panel {
                                flexDirection = "row", gap = 6, width = "100%", alignItems = "center",
                                children = {
                                    refs.playsetRenameField,
                                    -- 「保存」：把名字框里的字存成文件夹的新名字
                                    --   用户："把「重命名」这三个字改为「保存」；不点保存，名字就改了也不会保存"
                                    UI.Button((function()
                                        local sp = UISkin.button("normal", { width = 76, height = 40, fontSize = 14 })
                                        sp.id = "playsetSaveBtn"      -- 供 UI.FindById 查找（离屏测试点它）
                                        sp.text = "保存"
                                        sp.onClick = function()
                                            local MM = require("mods.ModManager")
                                            local cur = curName()
                                            local raw = refs.playsetRenameField:GetValue() or ""
                                            local newName = raw:gsub("^%s+", ""):gsub("%s+$", "")
                                            if newName == "" then
                                                refs.playsetSetHint("名字不能为空", true)
                                            elseif newName == cur then
                                                refs.playsetSetHint("名字没变")
                                            elseif MM.playsets_[newName] then
                                                refs.playsetSetHint(string.format("已经有一个叫「%s」的文件夹了", newName), true)
                                            elseif MM.renamePlayset(cur, newName) then
                                                print("[Mod] 保存（改名）：" .. cur .. " → " .. newName)
                                                -- 选中要跟着改名走（不然刷新后选中的是个不存在的名字）；
                                                -- "当前使用"由 renamePlayset 自己维护
                                                sel = newName
                                                refs.playsetRefresh()
                                                refs.playsetSetHint(string.format("已保存为「%s」", newName))
                                            else
                                                refs.playsetSetHint("保存失败", true)
                                            end
                                        end
                                        return sp
                                    end)()),
                                    UI.Button((function()
                                        local sp = UISkin.button("normal", { width = 72, height = 40, fontSize = 14 })
                                        sp.text = "复制"
                                        sp.onClick = function()
                                            local MM = require("mods.ModManager")
                                            local cur = curName()
                                            local n = 1
                                            local newName = cur .. " 副本"
                                            while MM.playsets_[newName] do
                                                n = n + 1
                                                newName = cur .. " 副本" .. n
                                            end
                                            MM.duplicatePlayset(cur, newName)
                                            sel = newName            -- 复制完直接选中新的那个
                                            refs.playsetRefresh()
                                            refs.playsetSetHint(string.format("已复制为「%s」", newName))
                                            print("[Mod] 复制：" .. cur .. " → " .. newName)
                                        end
                                        return sp
                                    end)()),
                                    UI.Button((function()
                                        local sp = UISkin.button("danger", { width = 72, height = 40, fontSize = 14 })
                                        sp.text = "删除"
                                        sp.onClick = function()
                                            local MM = require("mods.ModManager")
                                            local cur = curName()
                                            if MM.deletePlayset(cur) then
                                                -- 删掉的是选中的那个 → 选中落到"当前使用"上（它一定还在）
                                                sel = MM.getActivePlayset()
                                                refs.playsetRefresh()
                                                refs.playsetSetHint(string.format("已删除「%s」", cur))
                                                print("[Mod] 已删除文件夹：" .. cur)
                                            else
                                                refs.playsetSetHint("至少要留一个文件夹", true)
                                                print("[Mod] ⚠️ 不能删除（至少要留一个文件夹）")
                                            end
                                        end
                                        return sp
                                    end)()),
                                    -- 「一键补全」：用户定"放在底部那一排"（控件在上面先造好了）
                                    --   没有缺失时由 refresh 自动灰掉 → 不做"点了没用的按钮"
                                    refs.playsetFixBtn,
                                    -- 「应用」：把选中的文件夹真正切成当前使用的（朱漆 = 主操作）
                                    refs.playsetApplyBtn,
                                },
                            },
                            -- 提示行（保存/补全的反馈都走这里）
                            refs.playsetHint,
                        },
                    },
                },
            },
        },
    }

    -- 尺寸：用户 2026-09-14"我发现你这个框好像太小了没有覆盖整个的，不可以它必须是覆盖整个的"
    --   → 与模组面板对齐（92%），不再留一大圈桌面
    -- headerExtra：标题「游玩集」后面那块空地放"选中：xxx"
    -- fullscreen：和模组面板统一（用户要"挤满整个屏幕"）
    local overlay = createModal("游玩集", content, refs, "playsetOverlay",
        { fullscreen = true, headerExtra = refs.playsetSelLabel })
    refs.playsetRefresh()
    return overlay
end

-- ============================================================
-- 主菜单
-- ============================================================

--- 创建主菜单
---@param options table
---   onStart          function 点击"开始游戏"
---   onContinue       function|nil 点击"继续游戏"（无存档则不显示）
---   onLoadSave       function 点击"读取存档"
--- （2026-09-15 删：onSelectMapPack / onApplyMapOptions 两个回调连同「世界生成」面板一起删了
---   —— 全工程没有任何地方调用它们，地图改在选国页上选）
---@return Widget
function MainMenu.create(options)
    options = options or {}
    ---@type table
    local refs = {}
    -- 存到模块级：main.lua 要在"读档前"调 MainMenu.confirmLoadMods（见文件末尾），
    -- 那个函数拿不到这里的局部 refs
    MainMenu.refs_ = refs

    -- 重置入场动画队列（重复进出主菜单时重建）
    intro_.items = {}
    intro_.t = nil

    local settingsOverlay = createSettingsOverlay(refs)
    -- 模组管理初始化（内置本体 + 扫描 mods/ + 读游玩集）
    require("mods.ModManager").init()

    local modsOverlay = createModsOverlay(refs, options)
    local playsetOverlay = createPlaysetOverlay(refs)
    local packPickerOverlay = createPackPickerOverlay(refs)
    local loadModsOverlay = createLoadModsOverlay(refs)

    -- ============================================================
    -- 🗑 2026-09-15 用户要求：**删掉「开始新游戏」那个"选地图"弹窗**
    --   用户原话："点击新的游戏为什么还得选地图，[应该]直接[进]那个画面……
    --             这第一个是我们最开始[做]的，现在已经被淘汰了，删掉它"
    --
    --   为什么它淘汰了：地图现在在**选国页**上选（上边那排=地图模组 / 左边那列=地图名），
    --   开头再弹一次"选地图"是重复的中间一步。
    --   → 「新的游戏」现在**直接**调 `options.onStart`（进选国页），中间不再有窗。
    -- ============================================================
    ---@type table[]
    local children = {
        -- 标题行：金色书法大字 + 朱红印章落款（与背景窗棂金光呼应）
        UI.Panel {
            flexDirection = "row",
            alignItems = "flex-end",
            gap = 12,
            -- 44 → 22（2026-10-05）：有存档时多一个「读取存档」按钮 → 内容超高 → 标题被切。
            --   压缩标题下间距，给按钮行腾空间。
            marginBottom = 22,
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

    -- 新的游戏 + 右边的「游玩集」按钮（2026-09-14 用户定稿第二版）：
    --   ① 它是个**按钮**（不是下拉）：只显示"现在用的是哪个游玩集"
    --   ② 点一下 → 打开**游玩集大面板**（在里面看模组 / 切换 / 管理）
    --   ③ 尺寸按用户意见：**保持小巧**，只比原来大一点点（110×44）
    --   ④ **不动其他按钮**：行宽仍是 360，按钮 absolute 挂右侧往右探 → 整列对齐不变
    do
        local MM = require("mods.ModManager")
        local sp = UISkin.button("normal", { width = 110, height = 44, fontSize = 14, textured = true })
        -- 用户定稿：按钮上**只写「游玩集」**（说明它是什么）；
        -- "当前选中的是哪个"进面板才看（面板里当前那个有朱漆高亮 + ●）
        sp.text = "游玩集"
        sp.position = "absolute"
        sp.left = "100%"
        sp.marginLeft = 8
        sp.top = 6                                  -- 行高 56、按钮 44 → 上下各 6，视觉居中
        sp.onClick = function()
            -- 打开大面板（切换/管理都在里面做）
            if refs.playsetRefresh then refs.playsetRefresh() end
            refs.playsetOverlay:Show()
        end
        refs.menuPlayset = UI.Button(sp)

        local newGameBtn = GuFengButton("新的游戏", function()
            -- 2026-09-15：**直接进选国页**（原来中间还弹一个"选地图"窗，已删）。
            --   地图改在选国页上选（上边那排=地图模组 / 左边那列=地图名），
            --   这里只把"这个游玩集绑定的地图"应用上，剩下的交给选国页。
            local MM = require("mods.ModManager")
            local psName = MM.getActivePlayset()
            local mid = psName and MM.getPlaysetMap and MM.getPlaysetMap(psName) or nil
            -- ⚠️ 用 switchTo（不是 setActive）：理由同上面游玩集的「应用」按钮（2026-09-15 修）
            if mid then require("data.MapPack").switchTo(mid) end
            print(string.format("[Mod] 新的游戏：游玩集=%s 地图=%s（直接进选国页）",
                tostring(psName), tostring(mid)))
            if options.onStart then options.onStart(psName) end
        end, { intro = false, id = "btnNewGame", marginBottom = 0 })

        local row = UI.Panel {
            width = 360, height = 56, marginBottom = 14,
            children = { newGameBtn, refs.menuPlayset },
        }
        children[#children + 1] = row
        introAdd(row, 0.08 * #intro_.items)   -- 整行一起入场（动画顺序不变）
    end

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

    -- 编辑器
    children[#children + 1] = GuFengButton("编辑器", function()
        if options.onEditor then options.onEditor() end
    end, { intro = true })

    -- 模组
    children[#children + 1] = GuFengButton("模组", function()
        -- 打开前重建列表（勾选状态跟着"当前文件夹"变 —— 那个可能刚在主页被切过）
        if refs.modsRebuild then refs.modsRebuild() end
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

    -- 安全区（2026-10-05 用户截图："这个字是不是被挡住了"）：手机状态栏/刘海会吃掉顶部，
    --   主菜单原来**完全没处理安全区** → 标题跑到状态栏底下。内边距留出四边安全区。
    local safeInsets = UI.GetSafeAreaInsets()
    local root = UI.Panel {
        width = "100%",
        height = "100%",
        -- 明亮沙盘推演风格古风背景（突出谋略/研究/运筹帷幄）
        backgroundImage = "image/menu_bg_strategy_bright_20260901151528.png",
        backgroundImageOpacity = 1,
        backgroundFit = "cover",
        paddingTop = safeInsets.top,
        paddingBottom = safeInsets.bottom,
        paddingLeft = safeInsets.left,
        paddingRight = safeInsets.right,
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
            playsetOverlay,
            packPickerOverlay,
            loadModsOverlay,
        },
    }
    -- [P0 临时] root 就绪后注入给工坊验证模块（按钮 onClick 不直接引用 root）
    require("mod.WorkshopProbe").attachRoot(root)

    return root
end

-- ============================================================================
-- 读档前确认：模组不一致时弹窗（2026-09-14 · 用户设计）
--   main.lua 的读档流程调 MainMenu.confirmLoadMods(diff, data, onEnter)
-- ============================================================================

--- 弹出「读档前确认」窗
---@param diff table SaveManager.diffMods 的结果
---@param data table 存档数据（选完了要用它继续）
---@param onEnter fun(data:table) 玩家选了「直接进入」或「改回并进入」→ 带着存档数据继续
---@return boolean 是否真的弹了窗（false = 界面没建好，调用方自己直接进）
function MainMenu.confirmLoadMods(diff, data, onEnter)
    local refs = MainMenu.refs_
    if not refs or not refs.loadModsOverlay then return false end

    MainMenu.loadModsOnEnter_ = onEnter
    MainMenu.loadModsData_ = data
    refs.loadModsDiff_ = diff          -- 「改回存档的模组」按钮要用它

    -- 正文：按"存档有 / 版本变 / 当前有"分组列出来
    refs.loadModsHolder:ClearChildren()
    local function group(title, color, items, fmt)
        if #items == 0 then return end
        refs.loadModsHolder:AddChild(UI.Label {
            text = title, fontSize = 13, fontFamily = "gufeng", fontWeight = "bold", fontColor = color,
        })
        for _, it in ipairs(items) do
            refs.loadModsHolder:AddChild(UI.Label {
                text = fmt(it), fontSize = 12, fontColor = DLG_DIM, whiteSpace = "normal", maxLines = 2,
            })
        end
    end
    group(string.format("存档有、当前没有（%d）", #diff.missing), DLG_WARN, diff.missing,
        function(it) return "　· " .. it.name .. "（" .. it.id .. "）" end)
    group(string.format("版本不同（%d）", #diff.versionChanged), DLG_WARN, diff.versionChanged,
        function(it) return string.format("　· %s：存档 v%s / 当前 v%s", it.name, it.saveV, it.curV) end)
    group(string.format("当前有、存档没有（%d）", #diff.extra), DLG_DIM, diff.extra,
        function(it) return "　· " .. it.name .. "（" .. it.id .. "）" end)

    -- 开头那句：这个存档是哪个文件夹存的、那个文件夹还在不在
    --   ⚠️ 别写太长 —— 它会自动折行，再叠上 \n 就会出现"句号孤零零跑到下一行"
    refs.loadModsIntro.text = string.format(
        "存档用的是「%s」，你当前是「%s」%s。「直接进入」= 用你现在这套模组。",
        tostring(diff.savePlayset or "（未记录）"), tostring(diff.curPlayset),
        diff.savePlaysetExists and "" or "（那个文件夹已经不在了）")

    -- 「改回存档的模组」：存档那个游玩集**已经不在了** → 没得改回，灰掉
    if refs.loadModsBackBtn then refs.loadModsBackBtn:SetDisabled(not diff.savePlaysetExists) end

    refs.loadModsOverlay:Show()
    return true
end

--- 「读档前确认」窗收尾
---@param choice string|nil "enter"=直接进入 / "back"=改回存档的模组 / nil=取消
function MainMenu.resetLoadMods(choice)
    local refs = MainMenu.refs_
    if refs and refs.loadModsOverlay then refs.loadModsOverlay:Hide() end

    local cb, data = MainMenu.loadModsOnEnter_, MainMenu.loadModsData_
    MainMenu.loadModsOnEnter_, MainMenu.loadModsData_ = nil, nil
    if choice and cb then
        cb(data)
    else
        print("[Load] 已取消读档")
    end
end

return MainMenu

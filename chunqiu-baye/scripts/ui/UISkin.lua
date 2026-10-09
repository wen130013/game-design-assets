-- ============================================================================
-- UISkin.lua — UI 皮肤配置层（2026-09-13 · 用户定稿"金漆木牌 + 朱漆主操作"）
--
-- 为什么要它：
--   按钮/面板的配色以前散在各处（MainMenu 的 DLG_*、GameUI 的 COLORS、UIBuilder 的 PAL），
--   想换风格要满地改，玩家更不可能换。现在**收成一处**：
--     * 改这个文件 = 全游戏换风格（配置层换皮）
--     * 将来模组带一份自己的皮肤文件 / 同名覆盖 → 玩家换皮（模组层，另做）
--
-- 视觉语言（用户拍板）：
--   * **常规按钮 = 金漆木牌**：黑褐漆底 + 金线描边 + 金色行楷字
--   * **主操作 = 朱漆金纹**：朱红漆底 + 金线 + 米金字（只给"新的游戏"这类主操作用）
--   * 面板 = 深靛底 + 金棕描边（沿用，与游戏内 UI 一致）
--
-- 用法：
--   local UISkin = require("ui.UISkin")
--   UISkin.button("normal")     -- → 一套 Button 能直接用的 props（含 hover/pressed）
--   UISkin.color("gold")        -- → {r,g,b,a}
--   UISkin.setSkin({...})       -- 换皮（模组/设置界面用）
-- ============================================================================

local UISkin = {}

-- ---------------------------------------------------------------------------
-- 调色板
-- ---------------------------------------------------------------------------
UISkin.COLORS = {
    -- 面板
    panelBg      = { 18, 22, 34, 250 },     -- 深靛（面板底）
    panelBgSoft  = { 26, 32, 46, 252 },     -- 弹出层
    panelBorder  = { 150, 120, 70, 220 },   -- 金棕描边
    divider      = { 110, 82, 50, 160 },

    -- 文字
    text         = { 232, 226, 210, 255 },  -- 骨白正文
    textDim      = { 158, 162, 178, 235 },  -- 次要
    textWarn     = { 232, 128, 96, 255 },   -- 警告

    -- 金（强调）
    gold         = { 226, 192, 120, 255 },
    goldSoft     = { 198, 164, 96, 220 },
    goldInk      = { 34, 26, 14, 255 },     -- 金底上的墨字

    -- 金漆木牌（常规按钮）
    lacquer      = { 38, 30, 24, 240 },     -- 漆底
    lacquerHover = { 54, 43, 32, 248 },
    lacquerPress = { 28, 22, 18, 250 },
    lacquerLine  = { 198, 164, 96, 200 },   -- 金线
    lacquerLineH = { 232, 196, 120, 255 },  -- 悬停金线（更亮）
    lacquerText  = { 232, 196, 120, 255 },  -- 金字

    -- 朱漆金纹（主操作）
    vermilion    = { 122, 34, 26, 246 },    -- 朱漆底
    vermilionHov = { 146, 44, 34, 250 },
    vermilionPrs = { 96, 26, 20, 250 },
    vermilionLn  = { 226, 192, 120, 230 },
    vermilionTxt = { 246, 228, 198, 255 },

    -- 墨底（次级/列表行）
    inkBtn       = { 40, 48, 66, 220 },
    inkBtnHover  = { 56, 66, 88, 240 },
    inkBtnPress  = { 32, 38, 52, 240 },
    rowBg        = { 30, 36, 50, 220 },
    rowHover     = { 46, 56, 76, 235 },

    -- 危险
    danger       = { 166, 42, 34, 255 },
    dangerHover  = { 190, 58, 46, 255 },
    dangerPress  = { 138, 34, 26, 255 },

    -- 禁用（灰显）
    disabledBg   = { 32, 36, 46, 170 },
    disabledText = { 112, 116, 128, 190 },
}

--- 按钮底图（AI 生成的漆器牌匾，切成九宫格：四角纹样保留、中间拉伸）
---   * 只给"大按钮"用（主菜单/开局按钮）—— 面板里的小按钮保持纯色，否则太花
---   * 换皮时换这张图 + 边距即可
UISkin.BUTTON_IMAGE = "image/ui/btn_lacquer_9s.png"
UISkin.BUTTON_SLICE = { left = 75, top = 60, right = 75, bottom = 60 }

--- 形状/字体令牌（改这里 = 全游戏按钮一起变）
UISkin.SHAPE = {
    radius       = 10,      -- 圆角
    borderWidth  = 1,       -- 描边宽
    height       = 56,      -- 主菜单按钮高度（其他场景各自指定）
    fontSize     = 20,
    fontFamily   = "gufeng",
    letterSpacing = 0.5,    -- 字距（古风味道：略宽）
}

---@param name string
---@return table|nil {r,g,b,a}
function UISkin.color(name)
    return UISkin.COLORS[name]
end

-- ---------------------------------------------------------------------------
-- 按钮样式 → 可直接展开进 UI.Button 的 props
-- ---------------------------------------------------------------------------
--- 取一套按钮样式
---@param kind string|nil "normal"（金漆木牌，默认）| "primary"（朱漆金纹）| "secondary"（墨底）| "danger"
---@param opts table|nil { height, width, fontSize, radius, fontFamily }
---@return table props
function UISkin.button(kind, opts)
    opts = opts or {}
    local C, S = UISkin.COLORS, UISkin.SHAPE
    kind = kind or "normal"

    local bg, hover, press, line, lineH, fg
    if kind == "primary" then
        bg, hover, press = C.vermilion, C.vermilionHov, C.vermilionPrs
        line, lineH, fg = C.vermilionLn, C.gold, C.vermilionTxt
    elseif kind == "secondary" then
        bg, hover, press = C.inkBtn, C.inkBtnHover, C.inkBtnPress
        line, lineH, fg = C.panelBorder, C.gold, C.text
    elseif kind == "danger" then
        bg, hover, press = C.danger, C.dangerHover, C.dangerPress
        line, lineH, fg = C.vermilionLn, C.gold, C.vermilionTxt
    else -- normal：金漆木牌
        bg, hover, press = C.lacquer, C.lacquerHover, C.lacquerPress
        line, lineH, fg = C.lacquerLine, C.lacquerLineH, C.lacquerText
    end

    local props = {
        width = opts.width,
        height = opts.height or S.height,
        fontSize = opts.fontSize or S.fontSize,
        fontFamily = opts.fontFamily or S.fontFamily,
        fontWeight = "bold",
        letterSpacing = S.letterSpacing,
        textColor = fg,
        backgroundColor = bg,
        hoverBackgroundColor = hover,
        pressedBackgroundColor = press,
        borderWidth = S.borderWidth,
        borderColor = line,
        hoverBorderColor = lineH,
        pressedBorderColor = line,
        borderRadius = opts.radius or S.radius,
        -- 禁用态：底压暗、字变灰 —— 用来表达"现在没有可做的事"
        -- （如「一键补全」在没有缺失时）→ 免得出现"点了没反应"的按钮
        disabledBackgroundColor = C.disabledBg,
        disabledTextColor = C.disabledText,
    }

    -- 素材版（textured）：用九宫格底图 + 不要纯色底/描边
    --   反馈改成"底图透明度"：常态 0.94 → 悬停 1.0（提亮）→ 按下 0.72（压暗）
    if opts.textured and UISkin.BUTTON_IMAGE then
        props.backgroundImage = UISkin.BUTTON_IMAGE
        props.backgroundSlice = UISkin.BUTTON_SLICE
        props.backgroundImageOpacity = 0.94
        props.hoverBackgroundImageOpacity = 1.0
        props.pressedBackgroundImageOpacity = 0.72
        props.disabledBackgroundImageOpacity = 0.30    -- 禁用：底图淡掉
        props.backgroundColor = nil
        props.hoverBackgroundColor = nil
        props.pressedBackgroundColor = nil
        props.disabledBackgroundColor = nil            -- 走底图透明度，不叠纯色
        props.borderWidth = 0
    end

    return props
end

--- 把按钮样式套到一个已有的 Button widget 上（换皮时用；不重建控件）
---@param btn any UI.Button
---@param kind string|nil
function UISkin.applyButton(btn, kind)
    if not btn or not btn.SetStyle then return end
    local p = UISkin.button(kind)
    btn:SetStyle {
        textColor = p.textColor,
        backgroundColor = p.backgroundColor,
        borderColor = p.borderColor,
    }
end

-- ---------------------------------------------------------------------------
-- 换皮（模组层将来用；现在给设置界面/调试用）
-- ---------------------------------------------------------------------------
--- 覆盖皮肤令牌
---@param patch table { colors = {...}, shape = {...} }
function UISkin.setSkin(patch)
    patch = patch or {}
    for k, v in pairs(patch.colors or {}) do
        UISkin.COLORS[k] = v
    end
    for k, v in pairs(patch.shape or {}) do
        UISkin.SHAPE[k] = v
    end
    print("[UISkin] 皮肤已应用（颜色 " .. tostring(#patch.colors or 0) .. " 项）")
end

return UISkin

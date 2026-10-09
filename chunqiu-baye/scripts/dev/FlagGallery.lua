-- ===========================================================================
-- 开发用：燕尾旗画法预览（离屏截图看效果，不参与正式玩法）
--
-- 用途：一屏列出"1 个字 / 2 个字 / 3 个字国名"在不同排版下的样子，
--       用来定"国名长的时候旗面怎么写"这件事。
-- 触发：离屏钩子 SHOT_FLAGDEMO=1（main.lua 里调 FlagGallery.Start()）
--
-- ⚠️ 用 UI 自绘控件（Widget:Extend + Render(nvg)）实现，**不要**自己 nvgCreate 一个
--    独立上下文挂 NanoVGRender —— 那条路画出来的东西会被游戏 UI 那一层盖掉（踩过）。
-- ===========================================================================
local UI = require("urhox-libs/UI")
local Widget = require("urhox-libs/UI/Core/Widget")
local MapRenderer = require("map.MapRenderer")

local M = {}

-- 样本：颜色取真实势力色，方便看深浅对比
local SAMPLES = {
    {
        title = "① 真实大小（地图上就是这么小：26×32）",
        scale = 1.0,
        items = { { "周", 150, 115, 195 }, { "齐", 92, 155, 145 }, { "燕", 150, 105, 150 } },
    },
    {
        title = "② 放大 2 倍 · 1 个字国名（周 齐 燕 楚 秦）",
        scale = 2.0,
        items = {
            { "周", 150, 115, 195 }, { "齐", 92, 155, 145 }, { "燕", 150, 105, 150 },
            { "楚", 105, 138, 80 }, { "秦", 178, 175, 58 },
        },
    },
    {
        title = "③ 放大 2 倍 · 2 个字国名 → 只取首字（东胡 白狄 山戎 楼烦）",
        scale = 2.0,
        items = {
            { "东", 110, 125, 95 }, { "白", 160, 150, 135 },
            { "山", 115, 120, 130 }, { "楼", 135, 133, 110 },
        },
    },
    {
        title = "④ 放大 2 倍 · 2 个字国名 → 旗面加宽 + 字号缩小，两个字都写",
        scale = 2.0,
        wide = 1.35,
        items = {
            { "东胡", 110, 125, 95 }, { "白狄", 160, 150, 135 },
            { "山戎", 115, 120, 130 }, { "楼烦", 135, 133, 110 },
        },
    },
    {
        title = "⑤ 放大 2 倍 · 3 个字国名 → 加宽旗面硬塞（周王室 中山国）",
        scale = 2.0,
        wide = 1.75,
        items = { { "周王室", 150, 115, 195 }, { "中山国", 178, 175, 58 } },
    },
}

local GalleryPanel = Widget:Extend("FlagGalleryPanel")

function GalleryPanel:Init(props)
    props = props or {}
    props.position = "absolute"
    props.left, props.top = 0, 0
    props.width, props.height = "100%", "100%"
    props.pointerEvents = "box-none"
    props.backgroundColor = { 38, 34, 30, 255 }   -- 不透明底，盖住游戏画面
    Widget.Init(self, props)
end

function GalleryPanel:Render(nvg)
    nvgFontFace(nvg, "sans")
    local y = 26
    for i = 1, #SAMPLES do
        y = self:_drawRow(nvg, y, SAMPLES[i])
    end
end

function GalleryPanel:_drawRow(nvg, y, sample)
    local s = sample.scale
    local baseW, baseH = 26 * s, 32 * s
    local wideFactor = sample.wide or 1

    nvgFillColor(nvg, nvgRGBA(235, 220, 170, 255))
    nvgFontSize(nvg, 17)
    nvgTextAlign(nvg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgText(nvg, 40, y, sample.title, nil)

    local x, ty = 40, y + 30
    for i = 1, #sample.items do
        local it = sample.items[i]
        local w = baseW * wideFactor
        local fs = baseH * 0.58
        if sample.wide then fs = fs * 0.72 end   -- 字多 → 字号缩一点，别贴边
        MapRenderer.DrawBanner(nvg, x, ty, w, baseH, { it[2], it[3], it[4] }, it[1],
            { lw = s, fontSize = fs, textAnchor = 0.42 })
        x = x + w + 52 * s
    end
    return ty + baseH + 34 * s
end

--- 启动（幂等）
function M.Start()
    if M._panel then return end
    local root = UI.GetRoot()
    if not root then
        print("[FlagGallery] UI 根节点还没有，挂不上")
        return
    end
    M._panel = GalleryPanel {}
    root:AddChild(M._panel)
    print("[FlagGallery] 旗子画廊已挂上（SHOT_FLAGDEMO=1）")
end

return M

-- ============================================================================
-- Emblem — 势力旗（2026-09-17 用户定案）
--
--   军队 / 国家身份 → 牙旗 army
--   战斗 / 战争     → 大纛 war
--
-- 素材是"纯白旗"（AI 生成、无字无图案），运行时两层叠色：
--   第 1 层 <shape>_flag.png   整旗，固定深棕（杆/穗/杆头）
--   第 2 层 <shape>_cloth.png  旗面，染势力色
--   第 3 层 国名首字           写在旗面正中
--
-- 颜色与尺寸来自 assets/image/flags/flags.json（由 gen_flag_assets.py 生成）。
-- ============================================================================

local UI = require("urhox-libs/UI")

local Emblem = {}

-- 杆/穗/杆头：所有国家统一的浅木金（要在深色面板和地图上都看得见）
local FRAME_TINT = { 176, 138, 88, 255 }

-- 与 flags.json 一致（整旗尺寸 px、旗面相对偏移与尺寸 px）
local FLAGS = {
    army = { size = { 406, 656 }, cloth = { 33, 55, 371, 251 } },
    war  = { size = { 303, 723 }, cloth = { 37, 89, 230, 428 } },
}

--- 取 UTF-8 首字（引擎里 utf8 库不可用，按首字节位模式切）
---@param s string
---@return string
local function firstChar(s)
    if not s or s == "" then return "?" end
    local b = string.byte(s, 1)
    local n = 1
    if b >= 240 then n = 4
    elseif b >= 224 then n = 3
    elseif b >= 192 then n = 2 end
    return string.sub(s, 1, n)
end

--- 按旗面底色亮度选字色（亮旗配深字，暗旗配白字 —— 保证读得清）
---@param color RGBAColor|nil
---@return RGBAColor
local function textColorOn(color)
    local r = (color and color[1]) or 160
    local g = (color and color[2]) or 160
    local b = (color and color[3]) or 160
    local lum = 0.299 * r + 0.587 * g + 0.114 * b
    if lum > 150 then
        return { 38, 30, 22, 255 }      -- 亮旗 → 深字
    end
    return { 252, 250, 244, 255 }       -- 暗旗 → 白字
end

--- 造一面势力旗
---@param faction table|nil 势力（name / color）；nil = 空旗（灰底）
---@param shape string|nil "army"(牙旗，默认) | "war"(大纛)
---@param height number|nil 显示高度 px，默认 56
---@return Widget
function Emblem.Make(faction, shape, height)
    shape = shape or "army"
    local def = FLAGS[shape] or FLAGS.army
    height = height or 56
    local sw, sh = def.size[1], def.size[2]
    local cx, cy, cw, ch = def.cloth[1], def.cloth[2], def.cloth[3], def.cloth[4]
    local w = math.floor(height * sw / sh + 0.5)

    local color = (faction and faction.color) or { 150, 150, 150, 255 }
    local text = firstChar(faction and faction.name)

    -- 旗面内字号：单字是方的 → 取"旗面宽/高"里小的那个来定，避免窄旗面（大纛）字溢出
    local clothWpx = cw * height / sh
    local clothHpx = ch * height / sh
    local fontSize = math.max(9, math.floor(math.min(clothWpx * 0.78, clothHpx * 0.70) + 0.5))

    ---@type table
    local clothBox = UI.Panel {
        position = "absolute",
        left = tostring(cx / sw * 100) .. "%",
        top = tostring(cy / sh * 100) .. "%",
        width = tostring(cw / sw * 100) .. "%",
        height = tostring(ch / sh * 100) .. "%",
        backgroundImage = "image/flags/" .. shape .. "_cloth.png",
        imageTint = color,
        justifyContent = "center",
        alignItems = "center",
        children = {
            UI.Label {
                text = text,
                fontSize = fontSize,
                fontColor = textColorOn(color),
                fontWeight = "bold",
            },
        },
    }

    return UI.Panel {
        width = w,
        height = height,
        backgroundImage = "image/flags/" .. shape .. "_flag.png",
        imageTint = FRAME_TINT,
        children = { clothBox },
    }
end

--- 只要旗面（锦旗式：不带杆、不带穗，省地方又能放大）
---@param faction table|nil
---@param shape string|number|nil "army"(默认) | "war"；传数字时视为 height（旧调用兼容）
---@param height number|nil
---@return Widget
function Emblem.MakeCloth(faction, shape, height)
    if type(shape) == "number" then
        height, shape = shape, "army"
    end
    shape = shape or "army"
    local def = FLAGS[shape] or FLAGS.army
    local _cx, _cy, cw, ch = def.cloth[1], def.cloth[2], def.cloth[3], def.cloth[4]
    local h = height or 22
    local w = math.floor(h * cw / ch + 0.5)
    local color = (faction and faction.color) or { 150, 150, 150, 255 }
    return UI.Panel {
        width = w,
        height = h,
        backgroundImage = "image/flags/" .. shape .. "_cloth.png",
        imageTint = color,
        justifyContent = "center",
        alignItems = "center",
        children = {
            UI.Label {
                text = firstChar(faction and faction.name),
                fontSize = math.max(8, math.floor(math.min(w * 0.78, h * 0.6) + 0.5)),
                fontColor = textColorOn(color),
                fontWeight = "bold",
            },
        },
    }
end

Emblem.firstChar = firstChar
Emblem.FRAME_TINT = FRAME_TINT

return Emblem

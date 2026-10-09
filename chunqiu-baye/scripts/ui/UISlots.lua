-- ============================================================================
-- UISlots.lua — UI "空位"（模组往本体界面上挂入口的地方 · 2026-09-14）
--
-- 解决什么问题（清单「洞 5」）：
--   声明式面板（ui/UIDesc.lua + ui/UIPanelHost.lua）**早就做好了** ——
--   能声明内容、能 open()、能刷新，动作派发也通了。
--   但它**全项目零入口**：只有离屏测试钩子 `SHOT_UIPANEL` 能打开它，
--   连本体自己都没在界面上放按钮。模组更不可能把面板挂到玩家看得见的地方。
--
-- 做法：本体在几个地方**声明空位**，谁都能往空位里注册入口。
--   本体只管"这里有个空位、条目按皮肤画成按钮"，
--   **不需要知道谁会挂上来、挂的是什么** —— 这就是"插座"的思路用在 UI 上。
--
-- 用法（模组侧，在 startup 阶段调）：
--   local UISlots = require("ui.UISlots")
--   UISlots.add("topbar.extra", {
--       id = "trade", label = "贸易", panel = "trade_panel", order = 10,
--   })
--   面板内容本身照 ui/UIDesc.lua 的格式注册（见 data/Panels.lua 的样板）
--
-- ⚠️ **空位是"建界面时读一次"的** —— 注册必须发生在界面建好之前。
--      运行时热插拔（界面已经在跑了再挂）暂不支持，需要时再加 onChange 回调。
-- ============================================================================

local UISlots = {}

-- ---------------------------------------------------------------------------
-- 本体现在开放的空位（加空位要同时在这里登记 + 在界面上写一行 UISlots.list）
-- ---------------------------------------------------------------------------
UISlots.SLOTS = {
    ["topbar.extra"] = "游戏内顶栏 · 外交/政策/科技 右边（放「打开某面板」的按钮）",
}

---@type table<string, table[]>  slotId -> entry[]
UISlots.slots_ = {}

--- 往空位里挂一个入口
---@param slotId string 见 UISlots.SLOTS
---@param entry table { id=, label=, panel=|onOpen=, order=, tooltip= }
---@return boolean ok
---@return string|nil err
function UISlots.add(slotId, entry)
    if type(entry) ~= "table" or not entry.id or not entry.label then
        return false, "空位条目必须有 id 和 label"
    end
    if not entry.panel and not entry.onOpen then
        return false, "空位条目要么给 panel（声明式面板 id），要么给 onOpen（函数）"
    end
    if not UISlots.slots_[slotId] then UISlots.slots_[slotId] = {} end
    local list = UISlots.slots_[slotId]
    -- 同 id 视为同一条（改定义 / 模组重载时不重复堆）
    for i = 1, #list do
        if list[i].id == entry.id then
            list[i] = entry
            return true, nil
        end
    end
    list[#list + 1] = entry
    return true, nil
end

--- 取空位里的条目（按 order 排好；order 小的在左）
---@param slotId string
---@return table[]
function UISlots.list(slotId)
    local list = UISlots.slots_[slotId]
    if not list or #list == 0 then return {} end
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    table.sort(out, function(a, b)
        return (a.order or 100) < (b.order or 100)
    end)
    return out
end

--- 这个空位里有东西吗（本体据此决定"要不要留那一段"，空着就不占地方）
---@param slotId string
---@return boolean
function UISlots.any(slotId)
    local list = UISlots.slots_[slotId]
    return list ~= nil and #list > 0
end

--- 清空一个空位（卸载模组 / 测试用）
---@param slotId string
function UISlots.clear(slotId)
    UISlots.slots_[slotId] = nil
end

--- 清空所有空位
function UISlots.clearAll()
    UISlots.slots_ = {}
end

return UISlots

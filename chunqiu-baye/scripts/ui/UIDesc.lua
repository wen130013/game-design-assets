-- ============================================================================
-- UIDesc.lua — 声明式 UI：**面板描述格式**（"插座"第七块 · 2026-09-13）
--
-- 目的：面板 = **一份数据**（不是一段布局代码）。模组/事件/编辑器只要写数据 +
--       接一个 action 钩子，就能给自己加面板、加按钮，不用碰 Lua 布局。
--
-- 一份面板描述长这样（完整字段见下）：
--   UIDesc.register{
--     id    = "my_panel",              -- 稳定 id（打开面板用 UIPanelHost.open("my_panel")）
--     title = "我的面板",               -- 标题栏文字（nil = 无标题栏）
--     width = "72%", maxHeight = "86%",-- 尺寸（数字 = 逻辑像素；字符串 = 百分比）
--     desc  = "…",                     -- 说明（给编辑器/工具看）
--     body  = { …节点树… },             -- 面板内容
--   }
--
-- 节点（body / children 里的每一项）——**通用字段**：
--   type       column | row | scroll | grid | label | button | divider | spacer
--              | resource | value | progress | toggle | image | list
--   id         可选，给动作回调用（payload.widgetId）
--   gap / padding / paddingX / paddingY          间距
--   width / height / flexGrow / flexShrink       尺寸
--   align / justify                              交叉轴 / 主轴对齐
--   bg / border / borderColor / radius           外观
--   visibleIf  function(gs, f) -> boolean        条件显示（false = 不建这个节点）
--   children   子节点数组（column/row/scroll/grid 用）
--
-- 各 type 的专属字段：
--   label      text, fontSize, fontFamily, fontWeight, textAlign, color, maxLines, whiteSpace
--   button     text, action, actionArg, height, fontSize, style("primary"/"secondary"/"danger"/"ghost"),
--              disabledIf = function(gs,f) -> boolean
--   divider    color, thickness, inset, label
--   spacer     （无字段，占位用，一般配 flexGrow=1）
--   resource   id（资源注册表里的 id）, label, showLabel（默认 true）
--   value      bind = function(gs, f) -> string    （自定义只读文本，每秒刷新几次）
--   progress   bind = function(gs,f) -> number, max = number
--   toggle     label, bind = function(gs,f) -> boolean, action（切换时回调，arg = 新值）
--   image      path（assets 相对路径）, fit("contain"/"cover"/"fill"）, tint
--   list       bind = function(gs,f) -> { {text=, action=, arg=, disabled=}, … }
--              itemTemplate（默认 { type="button" }）, columns（默认 1）, gap
--   scroll     children, maxHeight
--   grid       children, columns, gap
--
-- 动作（action）：先查 UIPanelHost.actions（游戏注册的），没有则
--   `Hooks.fire("ui_action", { action=, arg=, panelId=, widgetId=, gameState= })`
--   → 模组/事件可以自己接（这就是"模组加按钮不写布局"的落点）
--
-- ⚠️ 格式稳定性约定（已定稿，向后兼容）：
--   1. 字段只增不改；老字段语义不变（模组写过的描述不会因为升级失效）
--   2. `id` 是稳定标识；显示名/文案随便改
--   3. 不写 `type` 的节点按 "column" 处理（省事写法）
-- ============================================================================

local UIDesc = {}

---@type table<string, table> 面板 id → 描述
UIDesc.panels_ = {}
---@type string[] 注册顺序（给"面板列表"用）
UIDesc.order_ = {}

--- 注册一块面板（同 id 覆盖，方便调试/热改）
---@param d table 面板描述
---@return table d
function UIDesc.register(d)
    assert(type(d) == "table" and d.id, "面板描述必须有 id")
    assert(d.body ~= nil, "面板描述必须有 body（内容节点树）")
    if not UIDesc.panels_[d.id] then
        UIDesc.order_[#UIDesc.order_ + 1] = d.id
    end
    UIDesc.panels_[d.id] = d
    return d
end

---@param id string
---@return table|nil
function UIDesc.get(id)
    return UIDesc.panels_[id]
end

--- 全部已注册面板（按注册顺序）
---@return table[]
function UIDesc.list()
    local out = {}
    for _, id in ipairs(UIDesc.order_) do
        out[#out + 1] = UIDesc.panels_[id]
    end
    return out
end

--- 取消注册（模组停用/测试用）
---@param id string
---@return boolean
function UIDesc.unregister(id)
    if not UIDesc.panels_[id] then return false end
    UIDesc.panels_[id] = nil
    for i = #UIDesc.order_, 1, -1 do
        if UIDesc.order_[i] == id then table.remove(UIDesc.order_, i) end
    end
    return true
end

--- 校验一块面板描述（编辑器/模组工具用；返回问题清单，空表 = 没问题）
---@param d table
---@return string[] problems
function UIDesc.validate(d)
    local problems = {}
    if type(d) ~= "table" then return { "描述不是表" } end
    if not d.id then problems[#problems + 1] = "缺 id" end
    if d.body == nil then problems[#problems + 1] = "缺 body" end

    local KNOWN = {
        column = true, row = true, scroll = true, grid = true, label = true, button = true,
        divider = true, spacer = true, resource = true, value = true, progress = true,
        toggle = true, image = true, list = true,
    }
    local function walk(node, path)
        if type(node) ~= "table" then
            problems[#problems + 1] = path .. "：不是表"
            return
        end
        local t = node.type or "column"
        if not KNOWN[t] then
            problems[#problems + 1] = string.format("%s：未知 type=%s", path, tostring(node.type))
        end
        if t == "button" and not node.text then
            problems[#problems + 1] = path .. "：button 缺 text"
        end
        if t == "resource" and not node.id then
            problems[#problems + 1] = path .. "：resource 缺 id"
        end
        if (t == "value" or t == "progress" or t == "list") and type(node.bind) ~= "function" then
            problems[#problems + 1] = path .. "：" .. t .. " 需要 bind 函数"
        end
        if node.visibleIf ~= nil and type(node.visibleIf) ~= "function" then
            problems[#problems + 1] = path .. "：visibleIf 必须是函数"
        end
        for i, child in ipairs(node.children or {}) do
            walk(child, string.format("%s.children[%d]", path, i))
        end
    end
    walk(d.body, "body")
    return problems
end

return UIDesc

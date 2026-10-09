-- ============================================================================
-- Hooks.lua — 脚本钩子（"插座"第三块 · 2026-09-13）
--
-- 解决什么问题：
--   想做"某件事发生时干点什么"（宣战了加个 buff、打完仗掉资源、吞了省触发事件…），
--   以前只能去改对应系统的代码。本文件给游戏里这些**时机**开出口子：
--   任何系统/资源/事件/将来的模组都能"挂"上去，而不用碰原代码。
--
-- 用法：
--   local Hooks = require("systems.Hooks")
--   local id = Hooks.on("war_declared", function(p) print(p.attackerId, p.defenderId) end)
--   Hooks.off(id)                 -- 取消
--
-- 已开出的时机（name → payload 里有什么）：
--   war_declared        { gameState, attackerId, defenderId }      宣战成功（canDeclareWar 通过之后）
--   battle_end          { gameState, provinceId, winnerId, loserId, wiped, routed }
--   province_conquered  { gameState, provinceId, factionId, fromFactionId }  吞并/占领一个省
--   month               { gameState, time }                        每月（月末结算之后）
--   year                { gameState, time }                        每年
--
-- 约定（重要）：
--   * 单个钩子报错**只跳过它自己**（pcall 包住），不影响其他钩子和游戏主流程
--   * 钩子按注册顺序触发；同一 name 可以挂多个
--   * 返回值不参与游戏逻辑（要改数值请走 Modifiers 管道 / Resources 注册表）
-- ============================================================================

local Hooks = {}

---@class HookEntry
---@field id number
---@field name string
---@field fn fun(payload: table)

---@type table<string, HookEntry[]>
Hooks.listeners_ = {}
---@type table<number, HookEntry>
Hooks.byId_ = {}
Hooks.nextId_ = 1

--- 挂一个钩子；返回 id（取消时用）
---@param name string 时机名（见文件头列表）
---@param fn fun(payload: table)
---@return number id
function Hooks.on(name, fn)
    assert(type(name) == "string" and name ~= "", "钩子必须有时机名")
    assert(type(fn) == "function", "钩子必须是函数")
    local entry = { id = Hooks.nextId_, name = name, fn = fn }
    Hooks.nextId_ = Hooks.nextId_ + 1

    local list = Hooks.listeners_[name]
    if not list then
        list = {}
        Hooks.listeners_[name] = list
    end
    list[#list + 1] = entry
    Hooks.byId_[entry.id] = entry
    return entry.id
end

--- 取消一个钩子（按 id）
---@param id number
---@return boolean removed
function Hooks.off(id)
    local entry = Hooks.byId_[id]
    if not entry then return false end
    local list = Hooks.listeners_[entry.name]
    if list then
        for i = #list, 1, -1 do
            if list[i].id == id then table.remove(list, i) break end
        end
    end
    Hooks.byId_[id] = nil
    return true
end

--- 取消某个来源挂的所有钩子（模组停用时用；配合 Hooks.on 的返回值或按来源命名约定）
---@param name string
---@return number removed
function Hooks.clear(name)
    local list = Hooks.listeners_[name]
    local n = list and #list or 0
    if list then
        for _, e in ipairs(list) do Hooks.byId_[e.id] = nil end
    end
    Hooks.listeners_[name] = {}
    return n
end

--- 触发（游戏侧调用）。payload 里带上 gameState 等上下文
---@param name string
---@param payload table|nil
---@return number fired 实际成功执行的钩子数
function Hooks.fire(name, payload)
    local list = Hooks.listeners_[name]
    if not list or #list == 0 then return 0 end
    payload = payload or {}
    local fired = 0
    -- 拷贝一份再遍历：钩子里 on/off 不会打乱本次触发
    local snapshot = {}
    for i = 1, #list do snapshot[i] = list[i] end
    for i = 1, #snapshot do
        local e = snapshot[i]
        local ok, err = pcall(e.fn, payload)
        if ok then
            fired = fired + 1
        else
            print(string.format("[Hooks] ⚠️ 钩子 '%s' (#%d) 出错（已跳过）：%s",
                name, e.id, tostring(err)))
        end
    end
    return fired
end

--- 当前挂了哪些（调试/设置界面用）
---@return table<string, number> name → 数量
function Hooks.summary()
    local out = {}
    for name, list in pairs(Hooks.listeners_) do
        if #list > 0 then out[name] = #list end
    end
    return out
end

return Hooks

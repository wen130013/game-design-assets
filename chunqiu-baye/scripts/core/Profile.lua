------------------------------------------------------------------------
-- Profile.lua — 阶段耗时探针（手机端排查启动卡顿用）
--
-- 用法：
--   local Profile = require("core.Profile")
--   Profile.mark("GameState.init")     -- 打印「距上一步 / 距启动」的毫秒数
--
-- 输出形如：
--   [PERF] UI.Init                       +1234.5 ms  (累计   1234.5 ms)
-- 只在关键路径手动埋点，不做自动 hook，开销可忽略。
------------------------------------------------------------------------

local Profile = {}

local t0_ = os.clock()
local last_ = t0_
local enabled_ = true

--- 打一个时间点
---@param label string
function Profile.mark(label)
    if not enabled_ then return end
    local now = os.clock()
    print(string.format("[PERF] %-26s +%7.1f ms  (累计 %8.1f ms)",
        label, (now - last_) * 1000, (now - t0_) * 1000))
    last_ = now
end

--- 从启动到现在的总耗时（毫秒）
---@return number
function Profile.elapsed()
    return (os.clock() - t0_) * 1000
end

--- 开关（线上如嫌吵可关）
---@param on boolean
function Profile.setEnabled(on)
    enabled_ = on and true or false
end

return Profile

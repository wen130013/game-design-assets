---@class TimeSystem
---@field year integer
---@field month integer
---@field day integer
---@field hour integer
---@field speedIndex integer
---@field paused boolean
local TimeSystem = {}

-- 速度档位数据源：config.GameConfig.Time.SPEEDS（2026-09-01 统一单一数据源，
-- 避免此处硬编码副本与 GameConfig 不同步导致"改了配置速度不变"）
local GameConfig = require("config.GameConfig")
local SPEEDS = GameConfig.Time and GameConfig.Time.SPEEDS or {
    { name = "1速", hoursPerSec = 24 },
}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

local state = {
    year  = -770,
    month = 1,
    day   = 1,
    hour  = 6,

    speedIndex = 3,
    paused     = false,

    -- fractional hour accumulator (sub-hour precision between frames)
    accumulator = 0.0,
}

-- Callback registry --
-- Each key maps to an array of listener functions.
-- Listeners receive (timeState) as the sole argument.
local listeners = {
    hour  = {},
    day   = {},
    month = {},
    year  = {},
}

-- Config reference (data source: GameConfig.Time.SPEEDS, see top of file)
local HOURS_PER_DAY   = 24
local DAYS_PER_MONTH  = 30
local MONTHS_PER_YEAR = 12

-- ---------------------------------------------------------------------------
-- Reign-era data (simple lookup for formatDate)
-- ---------------------------------------------------------------------------

-- Zhou Ping Wang: -770  ..  -720  (51 years on the throne)
local PING_WANG_START = -770
local PING_WANG_END   = -720

-- Season names indexed 1..4
local SEASON_NAMES = { "春", "夏", "秋", "冬" }

-- Chinese month names
local MONTH_NAMES = {
    "一月", "二月", "三月",
    "四月", "五月", "六月",
    "七月", "八月", "九月",
    "十月", "十一月", "十二月",
}

-- ---------------------------------------------------------------------------
-- Helpers (private)
-- ---------------------------------------------------------------------------

--- Build a read-only snapshot of the current time state for listeners.
---@return table
local function snapshot()
    return {
        year  = state.year,
        month = state.month,
        day   = state.day,
        hour  = state.hour,
    }
end

--- Fire all listeners registered under *event*.
---@param event string  "hour"|"day"|"month"|"year"
local function fire(event)
    local cbs = listeners[event]
    if not cbs then return end
    local snap = snapshot()
    for i = 1, #cbs do
        cbs[i](snap)
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Initialise (or re-initialise) the time system.
--- Accepts an optional config table that mirrors GameConfig.Time.
---@param cfg? table
function TimeSystem.init(cfg)
    cfg = cfg or {}

    state.year  = cfg.START_YEAR  or -770
    state.month = cfg.START_MONTH or 1
    state.day   = cfg.START_DAY   or 1
    state.hour  = cfg.START_HOUR  or 6

    state.speedIndex = cfg.DEFAULT_SPEED or 3
    state.paused     = false
    state.accumulator = 0.0

    -- Reset listeners
    listeners.hour  = {}
    listeners.day   = {}
    listeners.month = {}
    listeners.year  = {}
end

--- Advance game time by *dt* real seconds.
--- Call this from your Update handler every frame.
---@param dt number  real elapsed seconds (timeStep)
function TimeSystem.update(dt)
    if state.paused then return end

    local speed = SPEEDS[state.speedIndex]
    if not speed then return end

    -- Accumulate fractional hours
    state.accumulator = state.accumulator + dt * speed.hoursPerSec

    -- Consume whole hours one at a time so that listeners fire in order
    while state.accumulator >= 1.0 do
        state.accumulator = state.accumulator - 1.0

        state.hour = state.hour + 1

        -- Day rollover
        if state.hour >= HOURS_PER_DAY then
            state.hour = 0
            state.day  = state.day + 1

            -- Month rollover
            if state.day > DAYS_PER_MONTH then
                state.day   = 1
                state.month = state.month + 1

                -- Year rollover
                if state.month > MONTHS_PER_YEAR then
                    state.month = 1
                    state.year  = state.year + 1
                    fire("year")
                end

                fire("month")
            end

            fire("day")
        end

        fire("hour")
    end
end

-- ---------------------------------------------------------------------------
-- Callback registration
-- ---------------------------------------------------------------------------

--- Register a listener for a time event.
---@param event string  "hour"|"day"|"month"|"year"
---@param fn    fun(timeState: table)
function TimeSystem.on(event, fn)
    if not listeners[event] then
        listeners[event] = {}
    end
    table.insert(listeners[event], fn)
end

--- Remove a previously registered listener.
---@param event string
---@param fn    fun(timeState: table)
function TimeSystem.off(event, fn)
    local cbs = listeners[event]
    if not cbs then return end
    for i = #cbs, 1, -1 do
        if cbs[i] == fn then
            table.remove(cbs, i)
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Speed control
-- ---------------------------------------------------------------------------

--- Increase game speed by one level (clamped).
function TimeSystem.increaseSpeed()
    if state.speedIndex < #SPEEDS then
        state.speedIndex = state.speedIndex + 1
    end
end

--- Decrease game speed by one level (clamped).
function TimeSystem.decreaseSpeed()
    if state.speedIndex > 1 then
        state.speedIndex = state.speedIndex - 1
    end
end

--- Set speed to a specific index (1 .. 5).
---@param index integer
function TimeSystem.setSpeed(index)
    if index >= 1 and index <= #SPEEDS then
        state.speedIndex = index
    end
end

--- Toggle between paused and running.
function TimeSystem.togglePause()
    state.paused = not state.paused
end

--- Pause the clock explicitly.
function TimeSystem.pause()
    state.paused = true
end

--- Resume the clock explicitly.
function TimeSystem.resume()
    state.paused = false
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

---@return boolean
function TimeSystem.isPaused()
    return state.paused
end

---@return integer index, string name, number hoursPerSec
function TimeSystem.getSpeed()
    local s = SPEEDS[state.speedIndex]
    return state.speedIndex, s.name, s.hoursPerSec
end

---@return integer year, integer month, integer day, integer hour
function TimeSystem.getTime()
    return state.year, state.month, state.day, state.hour
end

--- Return the current season name.
---@return string  "春"|"夏"|"秋"|"冬"
function TimeSystem.getSeason()
    -- spring 1-3, summer 4-6, autumn 7-9, winter 10-12
    local idx = math.ceil(state.month / 3)
    return SEASON_NAMES[idx] or "春"
end

-- ---------------------------------------------------------------------------
-- Save / Restore（存档支持）
-- ---------------------------------------------------------------------------

--- 返回当前时间状态（可序列化）
---@return table {year, month, day, hour, speedIndex, paused}
function TimeSystem.getState()
    return {
        year       = state.year,
        month      = state.month,
        day        = state.day,
        hour       = state.hour,
        speedIndex = state.speedIndex,
        paused     = state.paused,
    }
end

--- 从存档恢复时间状态（不清除监听器）
---@param t table {year, month, day, hour, speedIndex, paused}
function TimeSystem.restore(t)
    if not t then return end
    state.year       = t.year  or -770
    state.month      = t.month or 1
    state.day        = t.day   or 1
    state.hour       = t.hour  or 6
    state.speedIndex = t.speedIndex or 3
    state.paused     = t.paused ~= nil and t.paused or false
    state.accumulator = 0.0
end

--- 返回精简数字纪年格式（顶栏/结算用，2026-09-01 定稿）：
---   "前770年 春 1月 15日"
--- 季节用汉字（放在月份头边）、公元前用"前"字、月日阿拉伯数字。
---@return string
function TimeSystem.getShortDate()
    local yearStr = state.year < 0
        and ("前" .. tostring(-state.year) .. "年")
        or (tostring(state.year) .. "年")
    return string.format("%s %s %d月 %d日", yearStr, TimeSystem.getSeason(), state.month, state.day)
end

--- Return a human-readable date string in classical Chinese style.
---
--- Examples:
---   "周平王元年 春一月"
---   "周平王二十年 秋七月"
---   "公元前500年 夏四月"
---@return string
function TimeSystem.formatDate()
    local season    = TimeSystem.getSeason()
    local monthName = MONTH_NAMES[state.month]

    -- Reign era string
    local eraStr
    if state.year >= PING_WANG_START and state.year <= PING_WANG_END then
        local reignYear = state.year - PING_WANG_START + 1
        if reignYear == 1 then
            eraStr = "周平王元年"
        else
            eraStr = "周平王" .. tostring(reignYear) .. "年"
        end
    else
        -- Generic "公元前X年" for years outside the Ping Wang era
        if state.year < 0 then
            eraStr = "公元前" .. tostring(-state.year) .. "年"
        else
            eraStr = "公元" .. tostring(state.year) .. "年"
        end
    end

    return eraStr .. " " .. season .. monthName
end

return TimeSystem

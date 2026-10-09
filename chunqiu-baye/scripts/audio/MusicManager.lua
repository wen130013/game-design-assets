-- ============================================================================
-- MusicManager.lua — 春秋霸业 背景音乐管理器
--
-- 核心特性：
--   * 双 SoundSource 交叉淡化（crossfade）实现无缝切换
--     旧曲淡出 / 新曲淡入同时进行，无硬切
--   * 音量、开关、当前曲目持久化到 "settings.json"
--   * 曲库自动检测：文件存在即出现在可选列表（后生成曲目放入即生效）
--
-- 用法：
--   local MusicManager = require("audio.MusicManager")
--   MusicManager.init()                      -- 启动时初始化一次
--   MusicManager.play("ycww")                -- 切到指定曲目（自动交叉淡化）
--   MusicManager.setVolume(0.8)              -- 0.0 ~ 1.0
--   MusicManager.setEnabled(false)           -- 开关
--   MusicManager.update(dt)                  -- 每帧驱动淡化（main.lua HandleUpdate）
-- ============================================================================

local MusicManager = {}

-- 曲库（file 相对 assets/；id 稳定，用于存档持久化）
-- 前两首已生成；后两首生成后放入 assets/audio/ 即自动可用
local TRACKS = {
    { id = "qdzq", name = "问鼎中原", file = "audio/music_1788273038828.ogg" }, -- 主菜单/开局
    { id = "ycww", name = "运筹帷幄", file = "audio/music_1788273282460.ogg" }, -- 战略地图/内政外交
    { id = "jgmt", name = "金戈铁马", file = "audio/music_jgmt.ogg" },          -- 战争（待生成）
    { id = "zmds", name = "钟鸣鼎食", file = "audio/music_zmds.ogg" },          -- 胜利/大事件（待生成）
}

-- 淡入淡出速度（增益/秒）
local FADE_SPEED = 1.8

-- ============================================================
-- Internal state
-- ============================================================
local settingsPath_ = "settings.json"

---@type Scene
local scene_ = nil
---@type Node
local node_ = nil
---@type SoundSource[]
local sources_ = {}          -- [1] / [2] 双缓冲
---@type number[]
local curGain_ = { 0, 0 }    -- 当前实际增益
---@type number[]
local targetGain_ = { 0, 0 } -- 目标增益（淡化驱动用）

local activeIdx_ = 1         -- 当前主源（正在出声的源）
local currentId_ = nil       -- 当前曲目 id
local volume_ = 0.7          -- 主音量 0~1
local enabled_ = true        -- 音乐开关

---@type table[] 可用曲目（文件存在的）
local availableTracks_ = {}

-- ============================================================
-- Settings persistence
-- ============================================================

local function saveSettings()
    local data = {
        music = {
            enabled = enabled_,
            volume = volume_,
            current = currentId_,
        },
    }
    local ok, json = pcall(cjson.encode, data)
    if not ok then return end
    local file = File(settingsPath_, FILE_WRITE)
    if not file or not file:IsOpen() then return end
    file:WriteString(json)
    file:Close()
end

local function loadSettings()
    if not fileSystem or not fileSystem:FileExists(settingsPath_) then
        return
    end
    local file = File(settingsPath_, FILE_READ)
    if not file or not file:IsOpen() then return end
    local str = file:ReadString()
    file:Close()
    if not str or str == "" then return end

    local ok, data = pcall(cjson.decode, str)
    if not ok or type(data) ~= "table" or not data.music then return end
    local m = data.music
    enabled_ = m.enabled ~= false
    if type(m.volume) == "number" then
        volume_ = math.max(0, math.min(1, m.volume))
    end
    if type(m.current) == "string" then
        currentId_ = m.current
    end
end

-- ============================================================
-- Internal helpers
-- ============================================================

--- 构建可用曲库（检查文件是否加载成功）
local function buildAvailableTracks()
    availableTracks_ = {}
    for _, t in ipairs(TRACKS) do
        -- 用 Exists 安全检查：缺失曲目不触发 GetResource 的 ERROR 日志
        if cache:Exists(t.file) then
            availableTracks_[#availableTracks_ + 1] = t
        else
            print("[Music] 曲目缺失（跳过）: " .. t.file)
        end
    end
end

--- 按 id 查找可用曲目
---@param id string
---@return table|nil
local function findTrack(id)
    for _, t in ipairs(availableTracks_) do
        if t.id == id then return t end
    end
    return nil
end

-- ============================================================
-- Public API
-- ============================================================

--- 初始化：创建音频节点 + 双 SoundSource，加载设置
function MusicManager.init()
    if scene_ then return end

    -- 轻量场景挂音频节点（本游戏地图走 NanoVG，无需 3D 渲染场景）
    scene_ = Scene()
    node_ = scene_:CreateChild("MusicNode")
    for i = 1, 2 do
        ---@type SoundSource
        local src = node_:CreateComponent("SoundSource")
        src:SetSoundType("Music")
        src:SetGain(0)
        sources_[i] = src
    end

    loadSettings()
    buildAvailableTracks()
    print("[Music] 初始化完成，可用曲目 " .. #availableTracks_ .. " 首")
end

--- 播放指定曲目（自动交叉淡化切换）
---@param id string
---@return boolean
function MusicManager.play(id)
    if not scene_ then return false end
    local track = findTrack(id)
    if not track then return false end

    -- 已在播放且正在出声 → 无需切换
    if currentId_ == id and sources_[activeIdx_]:IsPlaying() then
        return true
    end

    -- 新曲用另一个源播放，从 0 淡入
    local newIdx = 3 - activeIdx_   -- 1 ↔ 2 交换
    local Profile = require("core.Profile")
    local sound = cache:GetResource("Sound", track.file)
    Profile.mark("音乐首次加载(" .. tostring(track.file or "?") .. ")")
    if not sound then return false end
    sound:SetLooped(true)

    sources_[newIdx]:Stop()
    sources_[newIdx]:SetGain(0)
    sources_[newIdx]:Play(sound, 0, 0)
    curGain_[newIdx] = 0
    targetGain_[newIdx] = enabled_ and volume_ or 0

    -- 旧源淡出
    targetGain_[activeIdx_] = 0

    activeIdx_ = newIdx
    currentId_ = id
    saveSettings()
    print("[Music] 播放: " .. track.name)
    return true
end

--- 每帧驱动交叉淡化
---@param dt number
function MusicManager.update(dt)
    if not scene_ then return end
    for i = 1, 2 do
        local diff = targetGain_[i] - curGain_[i]
        if math.abs(diff) > 0.001 then
            local step = FADE_SPEED * dt
            if math.abs(diff) < step then
                curGain_[i] = targetGain_[i]
            else
                curGain_[i] = curGain_[i] + (diff > 0 and step or -step)
            end
            sources_[i]:SetGain(curGain_[i])
        end
    end
    -- 已完全淡出的源停止（省资源）
    local otherIdx = 3 - activeIdx_
    if curGain_[otherIdx] <= 0.002 and targetGain_[otherIdx] <= 0 then
        sources_[otherIdx]:Stop()
    end
end

--- 设置主音量（0~1）
---@param v number
function MusicManager.setVolume(v)
    volume_ = math.max(0, math.min(1, v))
    if enabled_ then
        targetGain_[activeIdx_] = volume_
    end
    saveSettings()
end

--- 音乐开关
---@param on boolean
function MusicManager.setEnabled(on)
    enabled_ = on
    targetGain_[activeIdx_] = on and volume_ or 0
    saveSettings()
end

--- 获取可用曲目列表（UI 下拉用）
---@return table[]
function MusicManager.getTrackList()
    return availableTracks_
end

--- 当前曲目 id
---@return string|nil
function MusicManager.getCurrentId()
    return currentId_
end

--- 当前曲目名
---@return string|nil
function MusicManager.getCurrentName()
    local id = currentId_
    for _, t in ipairs(availableTracks_) do
        if t.id == id then return t.name end
    end
    return nil
end

--- 当前音量（0~1）
---@return number
function MusicManager.getVolume()
    return volume_
end

--- 音乐是否开启
---@return boolean
function MusicManager.getEnabled()
    return enabled_
end

return MusicManager

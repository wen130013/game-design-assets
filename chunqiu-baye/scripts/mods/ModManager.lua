------------------------------------------------------------------------
-- ModManager.lua — 模组管理（骨架版 v0.1 · 2026-09-13）
--
-- 设计见 docs/制作清单.md → A15「模组体系最终设计」。本文件只做**数据层**：
--   * 内置官方模组（本体）：写死在代码里，永远在最底、不可关闭
--   * 扫描 mods/ 目录：每个子目录一个模组（读 mod.json）
--   * 游玩集（playset）：命名组合 = 启用哪些模组；存 mods/playsets.json
--   * 依赖检查：缺前置 → 给出"缺谁 + 它是谁的前置"
--
-- ⚠️ 本版**不做真正的覆盖式加载**（那要等"数据化功课"，见清单 A6/A15）：
--    现在只是"登记 + 界面骨架"，enable/disable 只改内存里的启用标记。
--
-- mod.json 约定（明文，玩家可手改 → 高级作者可 git/批量）：
--   {
--     "id": "100237",              -- 平台自动发号（6 位），作者不能自选
--     "name": "诸子学派",
--     "version": "0.3",
--     "author": "玩家A",
--     "desc": "……",
--     "tags": ["玩法系统"],         -- 可多选；无法归类写 ["其他"]
--     "dependencies": ["100088"],  -- 前置模组 id（可带版本： "100088>=1.2"）
--     "requires_map": "eu4",       -- 可选：只对某张地图有意义
--     "requires_restart": false,   -- 可选：改了引擎级配置，需重启
--     "official": false,           -- 官方内容为 true（玩家伪造无意义，只用于显示标签）
--     "updated_at": "2026-09-13"   -- 可选：用于"最新更新"排序
--   }
------------------------------------------------------------------------

local ModManager = {}

ModManager.MODS_DIR = "mods"
ModManager.PLAYSETS_PATH = "mods/playsets.json"

-- 官方本体（不落文件；将来"本体官方化"时再搬到 mods/official/）
ModManager.BASE_ID = "000001"
ModManager.official = {
    id = ModManager.BASE_ID,
    name = "春秋霸业",
    version = "0.1.0",
    author = "官方",
    desc = "本体：地图 / 剧本 / 系统 / 数值",
    tags = { "官方" },
    official = true,
    locked = true,           -- 本体不可关闭（清单 A15 ②）
    dependencies = {},
    size_kb = 0,
    updated_at = "2026-09-13",
}

---@type table<string, table>
ModManager.mods_ = {}        -- id -> mod 记录
---@type table<string, table>
ModManager.playsets_ = {}    -- 名字 -> { name=, mods={id,...} }
ModManager.activePlayset_ = nil

-- ---------------------------------------------------------------------------
-- 内部：文件读写（照 SaveManager 的写法）
-- ---------------------------------------------------------------------------
local function readJson(path)
    if not fileSystem or not fileSystem.FileExists or not fileSystem:FileExists(path) then
        return nil
    end
    local f = File(path, FILE_READ)
    if not f or not f:IsOpen() then return nil end
    local str = f:ReadString()
    f:Close()
    if not str or str == "" then return nil end
    local ok, data = pcall(cjson.decode, str)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

local function writeJson(path, data)
    if fileSystem and fileSystem.DirExists and not fileSystem:DirExists(ModManager.MODS_DIR) then
        fileSystem:CreateDir(ModManager.MODS_DIR)
    end
    local f = File(path, FILE_WRITE)
    if not f or not f:IsOpen() then
        print("[Mod] ⚠️ 无法写入 " .. path)
        return false
    end
    f:WriteString(cjson.encode(data))
    f:Close()
    return true
end

-- ---------------------------------------------------------------------------
-- 依赖
-- ---------------------------------------------------------------------------
--- 解析 "100088>=1.2" 形式的依赖项
---@param dep string
---@return string id
---@return string|nil minVersion
local function splitDep(dep)
    local id, ver = tostring(dep):match("^([^>=]+)>=?([%d%.]+)$")
    if id then return id, ver end
    return tostring(dep), nil
end

--- 版本比较（够用即可：按点分段数字比较）
---@return boolean b 是否 >= a
local function versionGE(cur, want)
    if not want then return true end
    local function parts(s)
        local t = {}
        for n in tostring(s):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local a, b = parts(cur or "0"), parts(want)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return true
end

--- 某模组缺哪些前置（清单 A15 ④：缺才显示，且要说清"它是谁的前置"）
---@param mod table
---@return table[] missing { id=, needVersion=, forName= }
function ModManager.missingDeps(mod)
    ModManager.init()
    local missing = {}
    for _, dep in ipairs(mod.dependencies or {}) do
        local id, needVer = splitDep(dep)
        local have = ModManager.mods_[id]
        if not have then
            missing[#missing + 1] = { id = id, needVersion = needVer, forName = mod.name }
        elseif not versionGE(have.version, needVer) then
            missing[#missing + 1] = {
                id = id, needVersion = needVer, forName = mod.name,
                haveVersion = have.version,
            }
        end
    end
    return missing
end

--- 全部模组里，有谁缺前置（用于列表上"缺 xxx（它是【某模组】的前置）"）
---@return table[] list
function ModManager.allMissing()
    local out = {}
    for _, m in pairs(ModManager.mods_) do
        for _, miss in ipairs(ModManager.missingDeps(m)) do
            out[#out + 1] = miss
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- 扫描磁盘上的模组
-- ---------------------------------------------------------------------------
--- 扫描 mods/<目录>/mod.json（目录名无所谓，以 mod.json 里的 id 为准）
function ModManager.scan()
    if not fileSystem or not fileSystem.ScanDir then return end
    if fileSystem.DirExists and not fileSystem:DirExists(ModManager.MODS_DIR) then
        return          -- 还没有 mods 目录：只有本体
    end
    local ok, entries = pcall(function()
        return fileSystem:ScanDir(ModManager.MODS_DIR, "", SCAN_DIRS, false)
    end)
    if not ok or type(entries) ~= "table" then
        print("[Mod] ⚠️ mods/ 扫描失败（忽略）")
        return
    end
    for _, item in ipairs(entries) do
        local dirName = (type(item) == "table") and (item.name or item.fileName) or item
        if type(dirName) == "string" and dirName ~= "." and dirName ~= ".." then
            local path = ModManager.MODS_DIR .. "/" .. dirName .. "/mod.json"
            local data = readJson(path)
            if data and data.id then
                data.dir = ModManager.MODS_DIR .. "/" .. dirName
                data.official = data.official or false
                data.tags = data.tags or (data.category and { data.category }) or { "其他" }
                ModManager.mods_[tostring(data.id)] = data
            end
        end
    end
    print(string.format("[Mod] 扫描完成：%d 个玩家模组", #ModManager.listMods() - 1))
end

-- ---------------------------------------------------------------------------
-- 游玩集（playset）
-- ---------------------------------------------------------------------------
local DEFAULT_PLAYSET = "标准"

--- 兜底：**一个文件夹都没有**时才建「标准」（首次运行 / 文件被清空）
--- ⚠️ 2026-09-14 修 bug：原来写的是"只要没有「标准」就建一个"，
---    结果用户把「标准」改名或删掉之后，它会在下次打开面板时**自己长回来**（还带着 ● 或空内容）。
---    「标准」是给新玩家的兜底，不是钉子户。
local function ensureDefaultPlayset()
    if next(ModManager.playsets_) == nil then
        ModManager.playsets_[DEFAULT_PLAYSET] = { name = DEFAULT_PLAYSET, mods = { ModManager.BASE_ID } }
    end
    -- 当前指向的那个不存在了（被改名/删除）→ 落到第一个（listPlaysetNames 已保证「标准」优先）
    if not ModManager.activePlayset_ or not ModManager.playsets_[ModManager.activePlayset_] then
        ModManager.activePlayset_ = ModManager.listPlaysetNames()[1]
    end
end

function ModManager.loadPlaysets()
    local data = readJson(ModManager.PLAYSETS_PATH)
    if data and type(data.playsets) == "table" then
        for _, ps in ipairs(data.playsets) do
            if ps.name then
                -- map（2026-09-13）：这个文件夹用哪张地图（"地图跟着文件夹走"）
                ModManager.playsets_[ps.name] = { name = ps.name, mods = ps.mods or {}, map = ps.map }
            end
        end
        ModManager.activePlayset_ = data.active
    end
    ensureDefaultPlayset()
end

function ModManager.savePlaysets()
    local list = {}
    for _, ps in pairs(ModManager.playsets_) do
        list[#list + 1] = { name = ps.name, mods = ps.mods, map = ps.map }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    writeJson(ModManager.PLAYSETS_PATH, { active = ModManager.activePlayset_, playsets = list })
end

---@return string
function ModManager.getActivePlayset()
    ModManager.init()
    ensureDefaultPlayset()
    return ModManager.activePlayset_
end

---@param name string
function ModManager.setActivePlayset(name)
    if not ModManager.playsets_[name] then return false end
    ModManager.activePlayset_ = name
    ModManager.savePlaysets()
    return true
end

--- 某个游玩集用哪张地图（"地图跟着文件夹走" —— 用户 2026-09-13 定稿）
---   没设过 → 回落到当前地图包（保证老档/新文件夹都有地图可用）
---@param name string|nil 默认当前游玩集
---@return string|nil mapId
function ModManager.getPlaysetMap(name)
    ModManager.init()
    name = name or ModManager.getActivePlayset()
    local ps = ModManager.playsets_[name]
    if ps and ps.map then return ps.map end
    local MapPack = require("data.MapPack")
    return MapPack.activeId
end

--- 设置某个游玩集用的地图
---@param name string
---@param mapId string
---@return boolean ok
function ModManager.setPlaysetMap(name, mapId)
    local ps = ModManager.playsets_[name]
    if not ps or not mapId then return false end
    ps.map = mapId
    ModManager.savePlaysets()
    print(string.format("[Mod] 游玩集「%s」的地图 → %s", name, mapId))
    return true
end

---@return string[]
function ModManager.listPlaysetNames()
    local names = {}
    for n in pairs(ModManager.playsets_) do names[#names + 1] = n end
    table.sort(names)
    -- 「标准」永远钉在第一行（用户 2026-09-14 定："把我那个标准的改到最上方"）
    --   注意：deletePlayset 删掉当前项后取 names[1] 兜底，钉住后兜底就是「标准」，正合适
    for i, n in ipairs(names) do
        if n == DEFAULT_PLAYSET and i > 1 then
            table.remove(names, i)
            table.insert(names, 1, n)
            break
        end
    end
    return names
end

--- 新建游玩集（自动把本体放进去）
---@param name string
---@return boolean ok
function ModManager.createPlayset(name)
    if not name or name == "" or ModManager.playsets_[name] then return false end
    ModManager.playsets_[name] = { name = name, mods = { ModManager.BASE_ID } }
    ModManager.savePlaysets()
    return true
end

--- 新建时保留地图：复制一份游玩集（模组清单 + 地图都抄）
---@param srcName string
---@param newName string
---@return boolean ok
function ModManager.duplicatePlayset(srcName, newName)
    local src = ModManager.playsets_[srcName]
    if not src or not newName or newName == "" or ModManager.playsets_[newName] then return false end
    local mods = {}
    for i, id in ipairs(src.mods or {}) do mods[i] = id end
    ModManager.playsets_[newName] = { name = newName, mods = mods, map = src.map }
    ModManager.savePlaysets()
    return true
end

--- 重命名（模组清单/地图跟着走；如果是当前游玩集，当前也跟着改）
---@param oldName string
---@param newName string
---@return boolean ok
function ModManager.renamePlayset(oldName, newName)
    local ps = ModManager.playsets_[oldName]
    if not ps or not newName or newName == "" or ModManager.playsets_[newName] then return false end
    ModManager.playsets_[newName] = { name = newName, mods = ps.mods, map = ps.map }
    ModManager.playsets_[oldName] = nil
    if ModManager.activePlayset_ == oldName then
        ModManager.activePlayset_ = newName
    end
    ModManager.savePlaysets()
    return true
end

--- 删除（不允许删最后一个：至少要留一个能开局）
---@param name string
---@return boolean ok
function ModManager.deletePlayset(name)
    if not ModManager.playsets_[name] then return false end
    if #ModManager.listPlaysetNames() <= 1 then return false end
    ModManager.playsets_[name] = nil
    if ModManager.activePlayset_ == name then
        ModManager.activePlayset_ = ModManager.listPlaysetNames()[1]
    end
    ModManager.savePlaysets()
    return true
end

--- 当前游玩集里是否启用了某模组
---@param id string
function ModManager.isEnabled(id)
    ModManager.init()
    local ps = ModManager.playsets_[ModManager.getActivePlayset()]
    if not ps then return false end
    for _, mid in ipairs(ps.mods or {}) do
        if mid == id then return true end
    end
    return false
end

--- 启用/禁用某模组（本体锁定不可关）
---@param id string
---@param on boolean
---@return boolean ok
---@return string|nil reason
function ModManager.setEnabled(id, on)
    local mod = ModManager.mods_[id]
    if not mod then return false, "模组不存在" end
    if mod.locked and not on then return false, "本体不可关闭" end
    if on and #ModManager.missingDeps(mod) > 0 then
        return false, "缺前置模组，不能启用"
    end
    local ps = ModManager.playsets_[ModManager.getActivePlayset()]
    if not ps then return false, "没有游玩集" end
    ps.mods = ps.mods or {}
    for i = #ps.mods, 1, -1 do
        if ps.mods[i] == id then table.remove(ps.mods, i) end
    end
    if on then ps.mods[#ps.mods + 1] = id end
    ModManager.savePlaysets()
    return true
end

-- ---------------------------------------------------------------------------
-- 查询
-- ---------------------------------------------------------------------------
--- 全部模组（本体永远第一）
---@return table[]
function ModManager.listMods()
    ModManager.init()
    local list = {}
    for _, m in pairs(ModManager.mods_) do
        list[#list + 1] = m
    end
    table.sort(list, function(a, b)
        if a.official ~= b.official then return a.official end
        if a.locked ~= b.locked then return a.locked end
        return tostring(a.name) < tostring(b.name)
    end)
    return list
end

--- 按类型标签过滤（"全部" = 不过滤；"官方" = official）
---@param tag string
---@return table[]
function ModManager.listByTag(tag)
    local all = ModManager.listMods()
    if not tag or tag == "全部" then return all end
    local out = {}
    for _, m in ipairs(all) do
        if tag == "官方" then
            if m.official then out[#out + 1] = m end
        else
            for _, t in ipairs(m.tags or {}) do
                if t == tag then out[#out + 1] = m break end
            end
        end
    end
    return out
end

--- 重新扫一遍 mods/（**导入模组包之后**必须调，不然新模组要重启才看得到）
---   init() 有幂等锁，所以单独给一个能重复调的
function ModManager.rescan()
    ModManager.mods_ = {}
    ModManager.mods_[ModManager.official.id] = ModManager.official
    ModManager.scan()
    print(string.format("[Mod] 重扫：模组 %d 个（含本体）", #ModManager.listMods()))
end

--- 初始化（主菜单建立时调用一次）
function ModManager.init()
    if ModManager.inited_ then return end      -- 幂等：任何入口重复调用都安全
    ModManager.inited_ = true
    ModManager.mods_ = {}
    ModManager.mods_[ModManager.official.id] = ModManager.official
    ModManager.scan()
    ModManager.loadPlaysets()
    print(string.format("[Mod] 初始化：模组 %d 个（含本体），游玩集 %d 个，当前 = %s",
        #ModManager.listMods(), #ModManager.listPlaysetNames(), ModManager.getActivePlayset()))
end

return ModManager

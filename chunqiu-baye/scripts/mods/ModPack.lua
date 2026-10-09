------------------------------------------------------------------------
-- ModPack.lua — 模组 / 整合包的**打包与解包**（.upk）
--
-- 用户 2026-09-14 定：先做**「导出/导入文件」**这条路（不需要服务器）。
--   导出的包落在游戏自己的目录里；桌面端能拷出来发给别人，
--   手机上在沙箱里拿不出来（引擎没有"分享/另存为"接口）。
--   将来接了分发服务器，这一层的打包/解包**原样复用**，
--   只是把"读本地文件"换成"从网上下载"。
--
-- 为什么自己造容器、不用 zip：
--   引擎只给了 zlib 级的 `CompressVectorBuffer` / `DecompressVectorBuffer`，
--   没有 zip 读写（要自己写中央目录 + CRC，不值当）。所以是个极简容器：
--   **壳 + 明文清单 + 压缩正文**。
--
-- 文件布局（小端，引擎原生字节序）：
--   [0..3]   magic "UPK1"
--   uint32   version
--   string   清单（**UTF-8 明文 JSON**）← 不解压就能看出"这个包里有什么"
--   uint32   正文未压缩字节数（0 = 正文没压缩）
--   uint32   正文实际字节数
--   bytes    正文 = CompressVectorBuffer(blob)
--
-- ⚠️ 坑：`File:Write(buf)` 写的是**裸字节**，`File:ReadBuffer()` 读的是
--   **长度前缀 + 字节** —— 两边不对称。所以正文长度得自己写一个 uint32，
--   读的时候用 `File:Read(size)`。（踩过一次：写完读回来全错，导入 0 个文件）
--
-- 正文 blob（未压缩，用 VectorBuffer 的 Write* 生成）：
--   uint32   文件数
--   fileCount × { string 相对路径；VectorBuffer 数据 }
--
-- ⚠️ 本文件**不碰 UI**，只做打包/解包；界面在 MainMenu 里接。
------------------------------------------------------------------------

local ModPack = {}

ModPack.EXPORT_DIR = "exports"     -- 导出的包放这（在游戏沙箱目录里）
ModPack.MODS_DIR   = "mods"
ModPack.MAGIC      = "UPK1"
ModPack.VERSION    = 1

-- ---------------------------------------------------------------------------
-- 内部工具
-- ---------------------------------------------------------------------------
--- 目录不存在就建（逐级建，供解包时还原子目录）
---@param path string
local function ensureDir(path)
    if path == "" or fileSystem:DirExists(path) then return true end
    -- 逐级建：FileSystem:CreateDir 不保证递归
    local acc = ""
    for seg in path:gmatch("[^/]+") do
        acc = (acc == "") and seg or (acc .. "/" .. seg)
        if not fileSystem:DirExists(acc) then
            if not fileSystem:CreateDir(acc) then return false end
        end
    end
    return true
end

--- 递归列出目录下所有**文件**，返回相对路径（"100237/mod.json"）
---   自己递归而不用 ScanDir 的 recursive：各版本对"递归返回的是全路径还是名字"不一致
---@param root string
---@return string[]
local function listFilesRecursive(root)
    local out = {}
    local function walk(rel)
        local dir = (rel == "") and root or (root .. "/" .. rel)
        local ok, items = pcall(function()
            return fileSystem:ScanDir(dir, "", SCAN_FILES | SCAN_DIRS | SCAN_HIDDEN, false)
        end)
        if not ok or type(items) ~= "table" then return end
        for _, item in ipairs(items) do
            -- ScanDir 有的版本回字符串、有的回 {name=...} 表
            local name = (type(item) == "table") and (item.name or item.fileName) or item
            if type(name) == "string" and name ~= "." and name ~= ".." then
                local childRel = (rel == "") and name or (rel .. "/" .. name)
                if fileSystem:DirExists(root .. "/" .. childRel) then
                    walk(childRel)
                else
                    out[#out + 1] = childRel
                end
            end
        end
    end
    walk("")
    return out
end

--- 读整个文件 → VectorBuffer（失败返回 nil）
---@param path string
---@return VectorBuffer|nil
local function readFileBuffer(path)
    local f = File(path, FILE_READ)
    if not f or not f:IsOpen() then return nil end
    local size = f:GetSize()
    local buf = (size > 0) and f:Read(size) or nil
    f:Close()
    return buf
end

--- 写整个文件（data 可以是 string 或 VectorBuffer）
---@param path string
---@param data string|VectorBuffer
---@return boolean
local function writeFileData(path, data)
    local f = File(path, FILE_WRITE)
    if not f or not f:IsOpen() then return false end
    if type(data) == "string" then
        f:WriteString(data)
    else
        f:Write(data)
    end
    f:Close()
    return true
end

-- ---------------------------------------------------------------------------
-- 打包
-- ---------------------------------------------------------------------------
--- 把 root 目录下所有文件塞进一个 blob
---@param root string
---@param files string[] 相对路径列表
---@return VectorBuffer blob
---@return integer fileCount
local function buildBlob(root, files)
    local blob = VectorBuffer()
    local n = 0
    -- 先占个位放文件数（写完再回填）—— VectorBuffer 不能回填，
    -- 所以改成"每条记录自带路径"，读到空路径就是结束
    blob:WriteUInt(#files)
    for _, rel in ipairs(files) do
        local buf = readFileBuffer(root .. "/" .. rel)
        if buf then
            blob:WriteString(rel)
            blob:WriteBuffer(buf)
            n = n + 1
        else
            print("[ModPack] ⚠️ 读不到 " .. root .. "/" .. rel .. "（跳过）")
        end
    end
    return blob, n
end

--- 写出一个 .upk
---@param outPath string
---@param manifest table 明文清单（不解压就能读）
---@param blob VectorBuffer|nil nil = 只有清单，没有正文（"只导清单"模式留给以后）
---@return boolean ok
---@return string msg
local function writePack(outPath, manifest, blob)
    ensureDir(ModPack.EXPORT_DIR)
    local f = File(outPath, FILE_WRITE)
    if not f or not f:IsOpen() then return false, "写不进 " .. outPath end
    f:WriteString(ModPack.MAGIC)
    f:WriteUInt(ModPack.VERSION)

    local jsonOk, jsonStr = pcall(cjson.encode, manifest)
    if not jsonOk or type(jsonStr) ~= "string" then
        f:Close()
        return false, "清单 JSON 编码失败"
    end
    f:WriteString(jsonStr)

    if blob then
        local rawSize = blob:GetSize()
        local packed = CompressVectorBuffer(blob)
        -- 压不动（极小的包）→ 原文写，rawSize = 0 表示"这片没压缩"
        if packed and packed:GetSize() > 0 and packed:GetSize() < rawSize then
            f:WriteUInt(rawSize)
            f:WriteUInt(packed:GetSize())
            f:Write(packed)
        else
            f:WriteUInt(0)
            f:WriteUInt(rawSize)
            f:Write(blob)
        end
    else
        f:WriteUInt(0)
        f:WriteUInt(0)         -- 只有清单，没有正文
    end

    f:Close()
    return true, outPath
end

-- ---------------------------------------------------------------------------
-- 对外：导出
-- ---------------------------------------------------------------------------
--- 文件名里去掉不能用的字符（跨平台保守一点）
---@param s string
---@return string
local function safeFileName(s)
    return (tostring(s):gsub("[\\/:*?\"<>|]", "_"))
end

--- 导出一个**模组**（把 mods/<目录> 整个打进去）
---@param modId string
---@return boolean ok
---@return string msg
function ModPack.exportMod(modId)
    local ModManager = require("mods.ModManager")
    ModManager.init()
    local m = ModManager.mods_[tostring(modId)]
    if not m then return false, "找不到模组 " .. tostring(modId) end
    if not m.dir then return false, "「" .. tostring(m.name) .. "」是内置本体，没有文件夹可导" end

    local files = listFilesRecursive(m.dir)
    if #files == 0 then return false, "这个模组文件夹是空的" end

    local blob, n = buildBlob(m.dir, files)
    local outPath = string.format("%s/%s_%s.upk", ModPack.EXPORT_DIR,
        safeFileName(m.name or m.id), safeFileName(m.id))
    local ok, msg = writePack(outPath, {
        kind = "mod",
        name = m.name,
        id = tostring(m.id),
        version = m.version,
        author = m.author,
        tags = m.tags,
        dependencies = m.dependencies,
        files = n,
        created_at = os.date("%Y-%m-%d %H:%M"),
    }, blob)
    if ok then
        print(string.format("[ModPack] 导出模组「%s」→ %s（%d 个文件）", tostring(m.name), outPath, n))
    end
    return ok, msg
end

--- 导出一整套（游玩集 = 文件夹）：**连模组一起打包**
---@param playsetName string
---@return boolean ok
---@return string msg
function ModPack.exportPlayset(playsetName)
    local ModManager = require("mods.ModManager")
    ModManager.init()
    local ps = ModManager.playsets_[tostring(playsetName)]
    if not ps then return false, "找不到文件夹「" .. tostring(playsetName) .. "」" end

    -- 打包时**把 mods/ 当成根**，所以包里的路径就是 "<模组目录>/xxx"，
    -- 解包时直接往 mods/ 里放 —— 两头都不需要额外转换
    local wantDirs = {}
    local manifestMods = {}
    for _, id in ipairs(ps.mods or {}) do
        local m = ModManager.mods_[tostring(id)]
        if m and m.dir then
            local sub = m.dir:match("^" .. ModPack.MODS_DIR .. "/(.+)$")
            if sub then
                wantDirs[sub] = true
                manifestMods[#manifestMods + 1] = {
                    id = tostring(id), name = m.name, version = m.version, dir = sub,
                }
            end
        elseif m then
            -- 内置本体（000001）：不在 mods/ 里，包里不带（人人都有）
            manifestMods[#manifestMods + 1] = { id = tostring(id), name = m.name, builtin = true }
        end
    end

    if next(wantDirs) == nil then
        return false, "这一套里没有可打包的模组（本体不用打包）"
    end

    local files = {}
    for sub in pairs(wantDirs) do
        for _, rel in ipairs(listFilesRecursive(ModPack.MODS_DIR .. "/" .. sub)) do
            files[#files + 1] = sub .. "/" .. rel
        end
    end
    if #files == 0 then return false, "这一套里的模组文件夹都是空的" end

    local blob, n = buildBlob(ModPack.MODS_DIR, files)
    local outPath = string.format("%s/整套_%s.upk", ModPack.EXPORT_DIR, safeFileName(playsetName))
    local ok, msg = writePack(outPath, {
        kind = "playset",
        name = playsetName,
        map = ps.map,
        mods = manifestMods,
        files = n,
        created_at = os.date("%Y-%m-%d %H:%M"),
    }, blob)
    if ok then
        print(string.format("[ModPack] 导出整套「%s」→ %s（%d 个文件）", tostring(playsetName), outPath, n))
    end
    return ok, msg
end

-- ---------------------------------------------------------------------------
-- 对外：读包（不解压正文就能看清单）
-- ---------------------------------------------------------------------------
--- 读一个包的**清单**（只读文件头，不解压）
---@param path string
---@return table|nil manifest
---@return string|nil err
function ModPack.peekPack(path)
    local f = File(path, FILE_READ)
    if not f or not f:IsOpen() then return nil, "打不开 " .. tostring(path) end
    local magic = f:ReadString()
    if magic ~= ModPack.MAGIC then
        f:Close()
        return nil, "不是本游戏的包（magic=" .. tostring(magic) .. "）"
    end
    local _ver = f:ReadUInt()
    local jsonStr = f:ReadString()
    f:Close()
    if not jsonStr or jsonStr == "" then return nil, "包里没有清单" end
    local ok, data = pcall(cjson.decode, jsonStr)
    if not ok or type(data) ~= "table" then return nil, "清单解析失败" end
    return data, nil
end

--- 列出 exports/ 里所有包（带清单）
---@return table[] { file=, path=, manifest=, err= }
function ModPack.listPacks()
    local out = {}
    if not fileSystem:DirExists(ModPack.EXPORT_DIR) then return out end
    local ok, items = pcall(function()
        return fileSystem:ScanDir(ModPack.EXPORT_DIR, "*.upk", SCAN_FILES, false)
    end)
    if not ok or type(items) ~= "table" then return out end
    for _, item in ipairs(items) do
        local name = (type(item) == "table") and (item.name or item.fileName) or item
        if type(name) == "string" then
            local path = ModPack.EXPORT_DIR .. "/" .. name
            local manifest, err = ModPack.peekPack(path)
            out[#out + 1] = { file = name, path = path, manifest = manifest, err = err }
        end
    end
    table.sort(out, function(a, b) return a.file < b.file end)
    return out
end

-- ---------------------------------------------------------------------------
-- 对外：导入（解包到 mods/）
-- ---------------------------------------------------------------------------
--- 解一个包到 mods/；如果是整套，顺便把游玩集补上
---@param path string
---@return boolean ok
---@return string msg 给人看的一句话
function ModPack.importPack(path)
    local manifest, err = ModPack.peekPack(path)
    if not manifest then return false, tostring(err) end

    local f = File(path, FILE_READ)
    if not f or not f:IsOpen() then return false, "打不开 " .. tostring(path) end
    f:ReadString()                 -- magic（peek 已经验过）
    f:ReadUInt()                   -- version
    f:ReadString()                 -- manifest
    local rawSize = f:ReadUInt()      -- 0 = 这片没压缩
    local bodySize = f:ReadUInt()     -- 正文实际字节数（自己写的，见文件头的坑）
    ---@type VectorBuffer
    local body
    local raw = (bodySize > 0) and f:Read(bodySize) or nil
    if not raw then
        f:Close()
        return false, "包里没有正文"
    end
    if rawSize == 0 then
        body = raw
    else
        body = DecompressVectorBuffer(raw)
    end
    f:Close()
    if not body then return false, "正文解压失败（包坏了？）" end

    ensureDir(ModPack.MODS_DIR)
    local count = body:ReadUInt()
    print(string.format("[ModPack] 正文 %d 字节（未压缩 %d）→ 声明 %d 个文件",
        bodySize, rawSize, count))
    local written = 0
    for _ = 1, count do
        if body:IsEof() then break end
        local rel = body:ReadString()
        local data = body:ReadBuffer()
        if rel and rel ~= "" and data then
            local full = ModPack.MODS_DIR .. "/" .. rel
            local dir = full:match("^(.*)/[^/]+$")
            if dir then ensureDir(dir) end
            if writeFileData(full, data) then
                written = written + 1
            else
                print("[ModPack] ⚠️ 写不进 " .. full)
            end
        end
    end

    -- 整套包 → 补一个游玩集（重名就加后缀，不覆盖别人的）
    local extra = ""
    if manifest.kind == "playset" and manifest.name then
        local ModManager = require("mods.ModManager")
        ModManager.init()
        local base = manifest.name
        local name = base
        local n = 1
        while ModManager.playsets_[name] do
            n = n + 1
            name = string.format("%s（导入%d）", base, n)
        end
        local mods = {}
        for _, mm in ipairs(manifest.mods or {}) do
            mods[#mods + 1] = tostring(mm.id)
        end
        ModManager.playsets_[name] = { name = name, mods = mods, map = manifest.map }
        ModManager.savePlaysets()
        extra = string.format("，并新建了文件夹「%s」", name)
    end

    -- 重扫 mods/（不然新模组要重启才看得到）
    require("mods.ModManager").rescan()

    print(string.format("[ModPack] 导入 %s：%d 个文件%s", tostring(path), written, extra))
    return true, string.format("已导入 %d 个文件%s", written, extra)
end

return ModPack

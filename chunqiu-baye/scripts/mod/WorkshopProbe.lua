-- ============================================================
-- [P0 临时验证] 云变量工坊边界探测模块 —— 跑通即删，勿依赖
-- 目标：实测 clientCloud 能力边界，结论回填 docs/mod-workshop-design.md
--   T1  Set/Get 基本往返（values 对象 + iscore）
--   T2  values 单 key 大小上限阶梯（1K..64K+）
--   T3  稀疏榜：作者唯一排序 key 时 GetRankList(key,0,1) 首位是否自己
--       + 排行榜附加字段能否带回该玩家 Set 的大 values（跨玩家分发通道关键）
--   T4  主榜空榜结构 / GetRankList 字段形状
--   T5  GetUserNickname 返回结构
--   T6  GetUserRank 自己排名 & 不存在 uid 的返回形态
--   T7  GetRankTotal
--   T8  双账号指引（真跨玩家验证留给两个 TapTap 账号实测）
-- ============================================================
local UI = require("urhox-libs/UI")

local M = {}

local PANEL_PAPER = "image/panel_parchment_20260901161208.png"

---@class WsProbeRefs
local refs = {
    overlay = nil,        -- 当前弹窗（用于幂等关闭）
    logLines = {},        -- 日志行
    passCount = 0,
    failCount = 0,
    uid = nil,
}

-- 前向声明：startTasks 定义在本文件后部，buildOverlay 的按钮回调引用它。
-- Lua 单遍编译，若无此声明，回调里的 startTasks 会被当作全局 nil（点击才崩）。
---@type fun(statusLabel: Label, logLabel: Label)
local startTasks

-- ------------------------------------------------------------------
-- 日志区：ScrollView 内累积 Label
-- ------------------------------------------------------------------

local function buildOverlay(root)
    if not root then
        print("[WsProbe] buildOverlay: root 为空，未挂载（需先 attachRoot）")
        return
    end
    if refs.overlay then root:RemoveChild(refs.overlay) end

    local sv = UI.ScrollView {
        width = "100%",
        height = 320,
        scrollY = true,
        showScrollbar = true,
    }
    local logLabel = UI.Label {
        id = "wsProbeLog",
        text = "点「开始验证」逐项实测云变量边界。\n\n" ..
            "双账号实测指引（跑完仍需换号做，此为本方案核心前提）：\n" ..
            "1) 本号数据保留在 ws_p_sparse_<userId>（排序值 1）\n" ..
            "2) 换号执行 GetRankList(\"ws_p_sparse_<原号>\",0,1,…,\"ws_p_row\")\n" ..
            "3) 首位为原号且带出 score.ws_p_row → 跨玩家分发通道成立\n" ..
            "4) 空榜/无附加字段 → 分发架构需另想（先停 P2）",
        width = "100%",
        fontSize = 13,
        whiteSpace = "normal",
        fontColor = { 40, 26, 12, 255 },
    }
    sv:AddChild(logLabel)

    local statusLabel = UI.Label {
        text = "未开始",
        width = "100%",
        fontSize = 15,
        fontWeight = "bold",
        fontColor = { 120, 40, 20, 255 },
        marginBottom = 6,
    }

    local overlay = UI.Panel {
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 170 },
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 480,
                backgroundImage = PANEL_PAPER,
                backgroundFit = "fill",
                paddingTop = 62,
                paddingBottom = 30,
                paddingHorizontal = 30,
                gap = 10,
                children = {
                    UI.Label {
                        text = "云变量边界验证（P0）",
                        fontSize = 20,
                        fontWeight = "bold",
                        fontFamily = "gufeng",
                        fontColor = { 56, 36, 18, 255 },
                        alignSelf = "center",
                    },
                    statusLabel,
                    sv,
                    UI.Button {
                        text = "开始验证",
                        width = "100%",
                        height = 44,
                        onClick = function()
                            refs.passCount = 0
                            refs.failCount = 0
                            refs.logLines = {}
                            logLabel.text = "验证中…"
                            statusLabel.text = "验证中…"
                            local ok, err = pcall(startTasks, statusLabel, logLabel)
                            if not ok then
                                statusLabel.text = "启动失败: " .. tostring(err)
                                print("[WsProbe] 验证启动失败:", err)
                            end
                        end,
                    },
                    UI.Button {
                        text = "关闭",
                        width = "100%",
                        height = 40,
                        variant = "secondary",
                        onClick = function()
                            if refs.overlay then
                                root:RemoveChild(refs.overlay)
                                refs.overlay = nil
                            end
                        end,
                    },
                },
            },
        },
    }

    refs.overlay = overlay
    refs.logLabel = logLabel
    refs.statusLabel = statusLabel
    root:AddChild(overlay)
end

-- ------------------------------------------------------------------
-- 日志与任务队列
-- ------------------------------------------------------------------
local function addLine(logLabel, line)
    local lines = refs.logLines
    lines[#lines + 1] = line
    logLabel.text = table.concat(lines, "\n")
end

---@param label Label
---@param sv ScrollView
local function mark(logLabel, ok, note)
    local prefix = ok and "[PASS]" or "[FAIL]"
    addLine(logLabel, string.format("%s %s", prefix, note))
    if ok then refs.passCount = refs.passCount + 1 else refs.failCount = refs.failCount + 1 end
end

-- 每个任务: function(cb) 完成时 cb(ok:boolean, note:string)
local taskQueue = {}
local function runTask(statusLabel, logLabel)
    if #taskQueue == 0 then
        statusLabel.text = string.format("完成：通过 %d / 失败 %d —— 详情见日志；双账号实测步骤见日志末尾",
            refs.passCount, refs.failCount)
        return
    end
    local task = table.remove(taskQueue, 1)
    statusLabel.text = "执行中：" .. task.name
    local ok, done = pcall(task.run)
    if not ok then
        mark(logLabel, false, task.name .. " 抛错: " .. tostring(done))
        runTask(statusLabel, logLabel)
        return
    end
    -- task.run 负责调用 cb；超时由各回调 error/timeout 兜底
end

local function queue(name, run)
    taskQueue[#taskQueue + 1] = { name = name, run = run }
end

local function cb(logLabel, statusLabel, taskName)
    return function(ok, note)
        mark(logLabel, ok, taskName .. ": " .. note)
        runTask(statusLabel, logLabel)
    end
end

-- ------------------------------------------------------------------
-- 验证序列
-- ------------------------------------------------------------------
local function startTasks(statusLabel, logLabel)
    taskQueue = {}
    refs.uid = nil

    queue("T0 环境探测", function()
        local cc = clientCloud
        if not cc then cb(logLabel, statusLabel, "T0 环境")(false, "clientCloud 不可用") return end
        local uid = cc.userId
        if uid == nil and GetUserId then uid = GetUserId() end
        refs.uid = uid
        local mapN = cc.mapName or "?"
        addLine(logLabel, string.format("[T0] clientCloud=%s userId=%s mapName=%s",
            tostring(cc ~= nil), tostring(uid), tostring(mapN)))
        cb(logLabel, statusLabel, "T0 环境")(uid ~= nil, "userId=" .. tostring(uid))
    end)

    queue("T1 Set/Get 往返", function()
        local events = cb(logLabel, statusLabel, "T1")
        clientCloud:BatchSet()
            :Set("ws_p_obj", { hello = "世界", n = 42 })
            :SetInt("ws_p_int", 7)
            :Save("ws probe T1", {
                ok = function()
                    clientCloud:BatchGet():Key("ws_p_obj"):Key("ws_p_int"):Fetch({
                        ok = function(values, iscores)
                            local obj = values and values.ws_p_obj
                            local okObj = type(obj) == "table" and obj.hello == "世界" and obj.n == 42
                            addLine(logLabel, string.format("[T1] 回读 obj=%s int=%s",
                                okObj and "一致" or "异常", tostring(iscores and iscores.ws_p_int)))
                            events(okObj, "values 对象往返")
                        end,
                        error = function(code, reason) events(false, "读失败 code=" .. tostring(code) .. " " .. tostring(reason)) end,
                        timeout = function() events(false, "读超时") end,
                    })
                end,
                error = function(code, reason) events(false, "写失败 code=" .. tostring(code) .. " " .. tostring(reason)) end,
                timeout = function() events(false, "写超时") end,
            })
    end)

    -- T2 大小阶梯：每档 set+读回长度，串行推进
    queue("T2 大小阶梯", function()
        local sizes = { 1, 2, 4, 8, 16, 32, 64, 128 }
        local idx = 1
        local maxOk = 0
        local function nextSize()
            if idx > #sizes then
                addLine(logLabel, string.format("[T2] 单 key 实测上限：>=%d KB（到 %dKB 档成功；后续失败见日志）",
                    maxOk, maxOk))
                cb(logLabel, statusLabel, "T2 大小")(maxOk > 0, "最大成功 " .. maxOk .. " KB")
                return
            end
            local kb = sizes[idx]
            local key = "ws_p_sz_" .. kb
            local payload = string.rep("a", kb * 1024)
            clientCloud:Set(key, payload, {
                ok = function()
                    clientCloud:Get(key, {
                        ok = function(values)
                            local got = type(values) == "table" and tostring(values[key])
                            local len = got and #got or -1
                            if len == #payload then
                                maxOk = kb
                                addLine(logLabel, string.format("[T2] %dKB 写入+回读 OK (%d bytes)", kb, len))
                            else
                                addLine(logLabel, string.format("[T2] %dKB 回读长度异常 len=%s expect=%d", kb, tostring(len), #payload))
                            end
                            idx = idx + 1
                            nextSize()
                        end,
                        error = function(code, reason)
                            addLine(logLabel, string.format("[T2] %dKB 读失败 code=%s %s（上限疑低于此档）", kb, tostring(code), tostring(reason)))
                            idx = idx + 1
                            nextSize()
                        end,
                        timeout = function()
                            addLine(logLabel, string.format("[T2] %dKB 读超时", kb))
                            idx = idx + 1
                            nextSize()
                        end,
                    })
                end,
                error = function(code, reason)
                    addLine(logLabel, string.format("[T2] %dKB 写失败 code=%s %s（上限疑低于此档）", kb, tostring(code), tostring(reason)))
                    idx = idx + 1
                    nextSize()
                end,
                timeout = function()
                    addLine(logLabel, string.format("[T2] %dKB 写超时", kb))
                    idx = idx + 1
                    nextSize()
                end,
            })
        end
        nextSize()
    end)

    -- T3 稀疏榜 + 附加字段（核心）
    queue("T3 稀疏榜自测", function()
        local events = cb(logLabel, statusLabel, "T3 稀疏榜")
        if not refs.uid then
            addLine(logLabel, "[T3] SKIP：T0 未取得 userId")
            events(false, "无 userId，跳过（依赖 T0）")
            return
        end
        local uid = tostring(refs.uid)
        local sparseKey = "ws_p_sparse_" .. uid
        clientCloud:SetInt(sparseKey, 1, {
            ok = function()
                -- 同行塞一个大 values，验证附加字段带回
                clientCloud:Set("ws_p_row", { src = "self", big = string.rep("x", 2048) }, {
                    ok = function()
                        clientCloud:GetRankList(sparseKey, 0, 1, {
                            ok = function(list)
                                addLine(logLabel, "[T3] 稀疏榜长度=" .. tostring(#list))
                                if #list > 0 then
                                    local it = list[1]
                                    local rankVal = it.iscore and it.iscore[sparseKey]
                                    local row = it.score and it.score.ws_p_row
                                    addLine(logLabel, string.format("[T3] 首位 userId=%s iscore=%s rowType=%s",
                                        tostring(it.userId), tostring(rankVal),
                                        row and type(row) or "nil"))
                                    local same = tostring(it.userId) == uid
                                    events(same, "首位是自己=" .. tostring(same) .. " 附加字段类型=" .. tostring(row and type(row)))
                                else
                                    events(false, "稀疏榜返回空（关键风险）")
                                end
                            end,
                            error = function(code, reason) events(false, "GetRankList 失败 code=" .. tostring(code) .. " " .. tostring(reason)) end,
                            timeout = function() events(false, "GetRankList 超时") end,
                        })
                    end,
                    error = function(code, reason) events(false, "Set row 失败 " .. tostring(reason)) end,
                })
            end,
            error = function(code, reason) events(false, "SetInt 失败 " .. tostring(reason)) end,
        })
    end)

    -- T4 主榜空榜结构
    queue("T4 空榜结构", function()
        local events = cb(logLabel, statusLabel, "T4 空榜")
        clientCloud:GetRankList("ws_p_never_used_catalog", 0, 5, {
            ok = function(list)
                addLine(logLabel, "[T4] 空榜长度=" .. tostring(#list) .. "（结构已回）")
                events(true, "空榜返回长度为 " .. tostring(#list))
            end,
            error = function(code, reason) events(false, "空榜查询失败 code=" .. tostring(code) .. " " .. tostring(reason)) end,
            timeout = function() events(false, "空榜查询超时") end,
        })
    end)

    -- T5 昵称查询
    queue("T5 昵称查询", function()
        local events = cb(logLabel, statusLabel, "T5 昵称")
        if not GetUserNickname then events(false, "GetUserNickname 不存在") return end
        if not refs.uid then
            addLine(logLabel, "[T5] SKIP：T0 未取得 userId")
            events(false, "无 userId，跳过（依赖 T0）")
            return
        end
        GetUserNickname({
            userIds = { refs.uid },
            onSuccess = function(list)
                local info = list and list[1]
                addLine(logLabel, string.format("[T5] 昵称返回=%s", info and info.nickname or "nil"))
                events(info ~= nil, "nickname=" .. tostring(info and info.nickname))
            end,
            onError = function(errorCode)
                events(false, "昵称查询失败 errorCode=" .. tostring(errorCode))
            end,
        })
    end)

    -- T6 GetUserRank 自己 & 不存在 uid
    queue("T6 GetUserRank", function()
        local events = cb(logLabel, statusLabel, "T6 GetUserRank")
        if not refs.uid then
            addLine(logLabel, "[T6] SKIP：T0 未取得 userId")
            events(false, "无 userId，跳过（依赖 T0）")
            return
        end
        local sparseKey = "ws_p_sparse_" .. tostring(refs.uid)
        local function querySelf()
            clientCloud:GetUserRank(refs.uid, sparseKey, {
                ok = function(rank, scoreValue)
                    addLine(logLabel, string.format("[T6] 自己 rank=%s score=%s", tostring(rank), tostring(scoreValue)))
                    -- 假 uid 形态
                    clientCloud:GetUserRank(4294967294, sparseKey, {
                        ok = function(r2, s2)
                            addLine(logLabel, string.format("[T6] 不存在uid rank=%s score=%s", tostring(r2), tostring(s2)))
                            events(true, "自己 rank=" .. tostring(rank) .. "；不存在uid返回 rank=" .. tostring(r2))
                        end,
                        error = function(code, reason)
                            addLine(logLabel, string.format("[T6] 不存在uid error code=%s %s", tostring(code), tostring(reason)))
                            events(true, "自己 rank=" .. tostring(rank))
                        end,
                    })
                end,
                error = function(code, reason) events(false, "查自己排名失败 code=" .. tostring(code) .. " " .. tostring(reason)) end,
            })
        end
        querySelf()
    end)

    -- T7 榜总人数
    queue("T7 榜总人数", function()
        local events = cb(logLabel, statusLabel, "T7 总人数")
        if not refs.uid then
            addLine(logLabel, "[T7] SKIP：T0 未取得 userId")
            events(false, "无 userId，跳过（依赖 T0）")
            return
        end
        clientCloud:GetRankTotal("ws_p_sparse_" .. tostring(refs.uid), {
            ok = function(total)
                addLine(logLabel, "[T7] 总人数=" .. tostring(total))
                events(true, "total=" .. tostring(total))
            end,
            error = function(code, reason) events(false, "GetRankTotal 失败 " .. tostring(reason)) end,
        })
    end)

    -- T8 双账号指引（不执行网络，仅文案）
    queue("T8 双账号指引", function()
        local uid = tostring(refs.uid)
        addLine(logLabel, "=== 双账号实测（换另一个 TapTap 账号运行本工具）===")
        addLine(logLabel, string.format("1) 本号数据保留在 key ws_p_sparse_%s（排序值1）", uid))
        addLine(logLabel, string.format("2) 换号后执行: GetRankList(\"ws_p_sparse_%s\",0,1,...,\"ws_p_row\")", uid))
        addLine(logLabel, "3) 若返回首位为原账号且带出 score.ws_p_row → 跨玩家分发通道成立（方案核心前提）")
        addLine(logLabel, "4) 若空榜/无附加字段 → 需另想分发架构，先别继续开发")
        cb(logLabel, statusLabel, "T8 指引")(true, "双账号步骤已写入日志")
    end)

    runTask(statusLabel, logLabel)
end

-- ------------------------------------------------------------------
--- 入口（安全模式）：挂载方先在 root 就绪后调用 attachRoot，
--- 按钮 onClick 只调 show()，不在闭包里引用未定义变量。
---@param root Widget UI 根面板（MainMenu.create / ShowMainMenu 返回的 root）
-- ------------------------------------------------------------------
local attachedRoot = nil

function M.attachRoot(root)
    attachedRoot = root
    -- 换 root 时丢弃旧弹窗句柄（旧弹窗随旧 root 一起销毁，勿再从新 root 移除）
    refs.overlay = nil
end

function M.show()
    buildOverlay(attachedRoot)
end

--- 兼容旧调用：直接给 root 显示（root 必须已就绪）
function M.showWith(root)
    buildOverlay(root)
end

return M

-- ============================================================================
-- SaveSlotsPanel.lua — 存档位选择面板（10 个存档位：保存 / 读取 / 删除）
--   mode="save"：点击存档位保存（空位直接存；已有存档弹确认覆盖）
--   mode="load"：点击存档位读取（空位/损坏位不可点）；每行可删除（弹确认）
-- 由 main.lua 接线；纯 UI 面板，不直接依赖 GameState
-- ============================================================================

local UI = require("urhox-libs/UI")
local SaveManager = require("save.SaveManager")
local SaveThumb = require("ui.SaveThumb")

local SaveSlotsPanel = {}

--- 缩略图尺寸（1 网格像素 = 1 UI 像素，见 SaveThumb.GRID_W/H）
local THUMB_W, THUMB_H = SaveThumb.GRID_W, SaveThumb.GRID_H

--- 当前打开的面板（防重入）
local current = nil

local PANEL_BG  = { 18, 22, 34, 245 }
local BORDER    = { 150, 120, 70, 220 }
local ROW_BG    = { 30, 36, 50, 220 }
local ROW_HOVER = { 46, 56, 76, 235 }
local ROW_EMPTY = { 24, 28, 40, 200 }
local GOLD      = { 255, 200, 50, 255 }
local TEXT      = { 235, 232, 225, 255 }
local TEXT_DIM  = { 170, 178, 195, 210 }
local WARNRED   = { 220, 70, 55, 255 }

--- 打开存档面板
---@param opts table { mode="save"|"load", root=Widget,
---                     onSaveToSlot=function(slot):boolean,string|nil,
---                     onLoad=function(slot), onClose=function() }
function SaveSlotsPanel.show(opts)
    if current then return end
    opts = opts or {}
    local root = opts.root
    if not root then return end
    local mode = opts.mode or "load"

    ---@type Label
    local msgLabel
    ---@type Panel
    local listBox
    ---@type Panel
    local confirmLayer
    ---@type Label
    local confirmText
    ---@type function|nil
    local pendingAction = nil

    local function close()
        if current and current.parent then
            current.parent:RemoveChild(current)
        end
        current = nil
        if opts.onClose then opts.onClose() end
    end

    local function refreshList()
        listBox:ClearChildren()
        local slots = SaveManager.listSlots()
        for _, info in ipairs(slots) do
            local slot = info.slot
            local exists = info.exists
            local broken = exists and (info.name == "（损坏或不兼容）")
            local nameText = exists and (info.name or ("存档 " .. slot)) or "空存档"
            local dateText = exists and not broken and (info.dateText or "") or ""
            -- 缩略图：用存档里的省份归属画一张纯色块小地图（空档/损坏档没有）
            local thumb = (exists and not broken) and SaveThumb.build(info.data) or nil

            ---@type any[]
            local rowChildren = {
                UI.Label {
                    text = tostring(slot), fontSize = 15, width = 26, textAlign = "center",
                    fontFamily = "gufeng", fontWeight = "bold",
                    fontColor = exists and GOLD or TEXT_DIM,
                },
                thumb and SaveThumb.Widget {
                    thumb = thumb, width = THUMB_W, height = THUMB_H, flexShrink = 0,
                } or UI.Panel {
                    width = THUMB_W, height = THUMB_H, flexShrink = 0,
                    backgroundColor = { 20, 26, 38, 220 },
                    borderWidth = 1, borderColor = { 96, 92, 84, 160 },
                    alignItems = "center", justifyContent = "center",
                    children = {
                        UI.Label {
                            text = broken and "×" or "", fontSize = 18,
                            fontColor = TEXT_DIM, textAlign = "center",
                        },
                    },
                },
                -- 三列宽度：加了缩略图后总宽要收一收，否则窄屏上会被 Yoga 压缩
                UI.Label {
                    text = nameText, fontSize = 14, width = 170,
                    fontFamily = "gufeng",
                    fontWeight = exists and "bold" or "normal",
                    fontColor = exists and TEXT or TEXT_DIM,
                },
                UI.Label {
                    text = dateText, fontSize = 12, width = 96, textAlign = "right",
                    fontColor = TEXT_DIM,
                },
                UI.Panel {
                    flexDirection = "column", width = 196, gap = 0,
                    children = {
                        UI.Label {
                            text = exists and not broken
                                and ("游玩集：" .. tostring(info.playset or "标准")) or "",
                            fontSize = 11, fontColor = TEXT_DIM,
                        },
                        UI.Label {
                            text = exists and not broken
                                and ("保存于：" .. tostring(info.savedAt or "—")) or "",
                            fontSize = 11, fontColor = TEXT_DIM,
                        },
                    },
                },
                UI.Panel { flexGrow = 1 },
            }

            -- 删除按钮（仅非空存档；点击不冒泡到整行：UI 命中测试取最深节点）
            if exists then
                rowChildren[#rowChildren + 1] = UI.Button {
                    text = "删除", width = 58, height = 30, fontSize = 12,
                    fontFamily = "gufeng", fontWeight = "bold",
                    textColor = WARNRED,
                    backgroundColor = { 60, 30, 30, 220 },
                    hoverBackgroundColor = { 96, 46, 42, 240 },
                    borderRadius = 6,
                    onClick = function()
                        confirmText.text = "确定删除 " .. slot .. " 号存档（" .. tostring(info.name or "") .. "）？"
                        pendingAction = function()
                            local ok = SaveManager.deleteSlot(slot)
                            msgLabel.text = ok and ("已删除 " .. slot .. " 号存档")
                                or ("删除失败：" .. slot .. " 号存档")
                            refreshList()
                        end
                        confirmLayer:Show()
                    end,
                }
            end

            local row = UI.Button {
                width = "100%", height = THUMB_H + 12, marginBottom = 4,
                borderRadius = 8, paddingHorizontal = 10,
                backgroundColor = exists and ROW_BG or ROW_EMPTY,
                hoverBackgroundColor = exists and ROW_HOVER or ROW_EMPTY,
                flexDirection = "row", alignItems = "center", gap = 8,
                children = rowChildren,
                onClick = function()
                    if mode == "save" then
                        if exists then
                            confirmText.text = "覆盖 " .. slot .. " 号存档（" .. tostring(info.name or "") .. "）？"
                            pendingAction = function()
                                local ok, reason = nil, nil
                                if opts.onSaveToSlot then ok, reason = opts.onSaveToSlot(slot) end
                                msgLabel.text = ok and ("已保存到 " .. slot .. " 号存档位")
                                    or ("保存失败：" .. tostring(reason))
                                refreshList()
                            end
                            confirmLayer:Show()
                        else
                            local ok, reason = nil, nil
                            if opts.onSaveToSlot then ok, reason = opts.onSaveToSlot(slot) end
                            msgLabel.text = ok and ("已保存到 " .. slot .. " 号存档位")
                                or ("保存失败：" .. tostring(reason))
                            refreshList()
                        end
                    else
                        if exists and not broken then
                            local cb = opts.onLoad
                            close()
                            if cb then cb(slot) end
                        end
                    end
                end,
            }
            if mode == "load" and (not exists or broken) then
                row:SetDisabled(true)
            end
            listBox:AddChild(row)
        end
    end

    -- ===== 头部 =====
    local titleText = (mode == "save") and "保存游戏" or "读取存档"
    local hintText = (mode == "save")
        and "点击存档位保存（空位直接保存，已有存档将确认覆盖）"
        or "点击存档位读取；可用「删除」清理旧存档"

    msgLabel = UI.Label {
        text = hintText, fontSize = 12, width = "100%",
        fontColor = TEXT_DIM, whiteSpace = "normal",
    }

    local closeBtn = UI.Button {
        text = "×", width = 30, height = 30, fontSize = 16,
        textColor = TEXT, backgroundColor = { 0, 0, 0, 0 },
        hoverBackgroundColor = { 90, 50, 45, 200 },
        borderRadius = 6,
        onClick = function() close() end,
    }

    listBox = UI.Panel { flexDirection = "column", width = "100%" }

    -- ===== 覆盖/删除确认层 =====
    confirmText = UI.Label {
        text = "", fontSize = 13, width = "100%", whiteSpace = "normal", fontColor = TEXT,
    }
    local confirmYes = UI.Button {
        text = "确定", height = 38, fontSize = 14, flexGrow = 1,
        fontFamily = "gufeng", fontWeight = "bold", textColor = TEXT,
        backgroundColor = { 160, 50, 50, 230 },
        hoverBackgroundColor = { 190, 60, 60, 240 },
        borderRadius = 8,
        onClick = function()
            local a = pendingAction
            pendingAction = nil
            confirmLayer:Hide()
            if a then a() end
        end,
    }
    local confirmNo = UI.Button {
        text = "取消", height = 38, fontSize = 14, flexGrow = 1,
        fontFamily = "gufeng", fontWeight = "bold", textColor = TEXT,
        backgroundColor = { 60, 66, 84, 230 },
        hoverBackgroundColor = { 78, 86, 108, 240 },
        borderRadius = 8,
        onClick = function()
            pendingAction = nil
            confirmLayer:Hide()
        end,
    }
    confirmLayer = UI.Panel {
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 140 },
        alignItems = "center", justifyContent = "center",
        pointerEvents = "auto",
        children = {
            UI.Panel {
                width = 360,
                backgroundColor = { 22, 26, 38, 248 },
                borderRadius = 10, borderWidth = 1, borderColor = { 200, 100, 90, 200 },
                padding = 16, gap = 12,
                children = {
                    confirmText,
                    UI.Panel {
                        flexDirection = "row", gap = 8, width = "100%",
                        children = { confirmYes, confirmNo },
                    },
                },
            },
        },
    }
    confirmLayer:Hide()

    -- ===== 面板主体 =====
    local panel = UI.Panel {
        width = "86%",   -- 2026-09-13 用户要求：存档页扩到接近全屏
        backgroundColor = PANEL_BG,
        borderRadius = 12, borderWidth = 1, borderColor = BORDER,
        padding = 14, gap = 8,
        children = {
            UI.Panel {
                flexDirection = "row", alignItems = "center", width = "100%",
                children = {
                    UI.Label {
                        text = titleText, fontSize = 20, flexGrow = 1,
                        fontFamily = "gufeng", fontWeight = "bold", fontColor = GOLD,
                    },
                    closeBtn,
                },
            },
            UI.Divider { color = { 110, 82, 50, 160 }, thickness = 1 },
            msgLabel,
            UI.ScrollView {
                width = "100%", height = "58%", flexShrink = 0,
                children = { listBox },
            },
        },
    }

    local overlay = UI.Panel {
        id = "saveSlotsOverlay",
        position = "absolute", top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 150 },
        alignItems = "center", justifyContent = "center",
        pointerEvents = "auto",
        children = { panel, confirmLayer },
    }
    root:AddChild(overlay)
    current = overlay
    refreshList()
end

return SaveSlotsPanel

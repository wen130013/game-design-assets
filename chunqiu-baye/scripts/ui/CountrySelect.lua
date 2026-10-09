-- ============================================================================
-- CountrySelect.lua - 选择国家界面（照 AoH3 参考图重做 · 手机横屏优先）
-- 布局：左上=三横线开关（展开/收起设置面板）  左=设置面板（默认收起）  中=世界地图
--       右=国家详情卡（默认隐藏：点国家区块出现；再点该国任意区块收起）
-- 详情卡内：图标位为「空槽」预留（科技/军队等图案后续生成后替换）
-- 用法：
--   CountrySelect.show({ onStart=function(factionId, settings) ... end, onBack=function() ... end })
-- ============================================================================

local UI          = require("urhox-libs/UI")
local Factions    = require("data.Factions")
local MapRenderer = require("map.MapRenderer")
local MapPack     = require("data.MapPack")
local Emblem      = require("ui.Emblem")

local CountrySelect = {}

-- ---------------------------------------------------------------------------
-- 工具
-- ---------------------------------------------------------------------------

--- 蛮族名特征（按字匹配）
local TRIBAL_KEYS = { "狄", "戎", "胡", "蛮", "夷", "濮" }

local function isTribal(name)
    if type(name) ~= "string" then return false end
    for _, k in ipairs(TRIBAL_KEYS) do
        if name:find(k, 1, true) then return true end
    end
    return false
end

-- 2026-09-16 删：「难度」星级（starCount / starText）
--   用户："选择国家的那个难度……把它取消" —— 那个星级只是**按省份数量粗估**的
--   （≥10 省=5 星，≥7=4 星，≥4=3 星，≥2=2 星，否则 1 星），
--   既不是真难度，也和玩法无关（大不等于难）→ 整块去掉，不再显示


-- 设置项预设（值暂存于本页；难度/AI 侵略度系统接入后由 main 消费）
local DIFFICULTY_OPTS = { "简易", "普通", "困难", "传奇" }
local MODE_OPTS       = { "事件", "沙盒" }
local AGGRESSION_OPTS = { "低", "普通", "高", "疯狂" }
-- 战争迷雾（2026-09-24 用户："我们可以选择要不要这个战争迷雾，就是在选国家里边这个设置"）：
--   开 = 只看得到自己 + 接壤的省（EU4 式）；关 = 全图可见。
--   选项做成两档而不是勾选框，和上面三组的「<< >>」交互保持一致。
local FOG_OPTS        = { "关闭", "开启" }
-- 人物生死（2026-09-28 用户："会不会死就是在设置里面可以设置，就进入游戏不是可以调设置吗"）：
--   开 = 官员/后宫/君主都会随年龄增长、会老死（职位空出来要重新任命，像 CK3）
--   关 = 只有君主会老死，官员/后宫不会（管理负担小，适合休闲玩法）
local MORTALITY_OPTS  = { "关闭", "开启" }
-- 存一份到全局，供 main.lua 开局时读取（选国页关闭后 settings 表就没了）
_G.CS_SETTINGS = _G.CS_SETTINGS or {}

-- ---------------------------------------------------------------------------
-- 主入口
-- ---------------------------------------------------------------------------
---@param opts table {
---   onStart=function(factionId, settings, camState), onBack=function(),
---   mode="start"|"switch",       -- switch = 局内「切换角色」：复用本页，但只换视角、不走开局
---   gameState=table|nil,         -- switch 模式必传：当前这一局的 GameState（地图要画**现归属**）
---   onSpectate=function()|nil,   -- 「观察」= 切看海（playerFactionId = nil）
--- }
function CountrySelect.show(opts)
    opts = opts or {}

    -- 切换模式：数据源从"静态初始表"换成"当前这一局"，
    -- 否则地图画的是一百年前的开局疆域，跟玩家看到的现状对不上。
    local isSwitch = (opts.mode == "switch")
    local liveGS   = opts.gameState

    -- 布局常量
    local GAP = 10
    -- LEFT_W 现在只给**设置面板**用（它要放三组"标签 + << >>"）。
    -- 左边「地图名」那一列是另一个宽度（2026-09-15 用户："这个占的地方太大了"）：
    --   只需装下地图名（现在最长是「旧大陆」3 个字），150 够用，
    --   比原来窄 100px，全给地图。
    local LEFT_W, RIGHT_W = 252, 300
    local MAPCOL_W = 150

    -- ---------------------------------------------------------------------------
    -- 数据源（两种模式的分叉口：开局查静态表 / 切换查当前局）
    -- ---------------------------------------------------------------------------
    ---@param fid number
    ---@return table|nil
    local function factionById(fid)
        if liveGS then return liveGS.factions[fid] end
        return Factions.getById(fid)
    end

    --- 省 → 归属势力 id
    ---@param pid number
    ---@return number|nil
    local function factionIdByProvince(pid)
        if liveGS then
            local p = liveGS.provinces[pid]
            return p and p.ownerId or nil
        end
        return Factions.getFactionByProvince(pid)
    end

    --- 遍历全部势力（切换模式只列**活着的** —— 灭亡的国家在地图上也没地，选了也没意义）
    ---@return table[]
    local function listFactions()
        local out = {}
        if liveGS then
            for _, f in pairs(liveGS.factions) do
                if f.alive ~= false and f.provinces and #f.provinces > 0 then
                    out[#out + 1] = f
                end
            end
            table.sort(out, function(a, b) return a.id < b.id end)
        else
            for _, f in ipairs(Factions.data or {}) do
                if f.provinces and #f.provinces > 0 then out[#out + 1] = f end
            end
        end
        return out
    end

    -- ---------------------------------------------------------------------------
    -- 上边那排（地图模组）+ 左边那列（地图名）的数据源
    --
    -- 用户拍板的层级（2026-09-15）：
    --     上边那排 = **地图模组**（= 一堆地图包的总称；没命名就只是个空白按钮）
    --       └─ 左边那列 = 这个模组里的**地图名**（现在 1 张：旧大陆）
    --            └─ 中间 = 选中的那张大地图
    --
    -- ⚠️ **「地图模组」这一层现在还不存在**：地图还写在本体 `data/mappacks/eu4.lua` 里，
    --    不是模组。所以这里先摆成"一个模组装下当前所有已注册地图包" ——
    --    等 A15 ⑦「地图注册桥」做完，**只要换掉 listMapModules() 的内部实现**，
    --    上边那排和左边那列不用返工。
    -- ---------------------------------------------------------------------------
    local BASE_MODULE_ID = "__base__"

    ---@return table[] 每个元素 { id, name, packs = { {id, name}, ... } }
    local function listMapModules()
        local packs = {}
        for id, p in pairs(MapPack.registry or {}) do
            packs[#packs + 1] = { id = id, name = p.name or id }
        end
        table.sort(packs, function(a, b) return a.id < b.id end)
        -- 本体自带这一个模组：我们给它起个名，别真留空白按钮（认不出来是 bug 还是没名字）
        return { { id = BASE_MODULE_ID, name = "本体", packs = packs } }
    end

    ---@type table<string, number>
    -- fog：1 = 关闭（默认），2 = 开启。用全局里上次的选择做默认值，重进选国页不丢。
    local settings = {
        difficulty = 2, mode = 1, aggression = 2,
        fog = _G.CS_SETTINGS.fog or 1,
        -- 人物生死：默认**开启**（有生老病死更真实）
        mortality = _G.CS_SETTINGS.mortality or 2,
    }
    _G.CS_SETTINGS = settings     -- 让 main.lua / 其它模块能读到最新选择
    local selected = nil
    local mapWidget = nil

    -- 前置声明（select/deselect 会引用，实际在下方创建）
    ---@type Panel
    local infoCard
    ---@type Button
    local startBtn
    ---@type Panel
    local settingsHolder

    -- 详情卡文字引用
    local titleLabel, emblemDot
    local infoPolityLabel, infoFaithLabel, infoLeaderLabel
    local infoProvLabel, infoArmyLabel, infoGoldLabel, infoFoodLabel
    local infoFlagPanel                  -- 旗帜位容器（旗子本体 2026-09-17 换成 Emblem）
    local infoFlagInner                  -- container 里挂的那面旗（换国时重挂）

    local function updateInfo(f)
        titleLabel:SetText(f.name or ("#" .. tostring(f.id)))
        emblemDot.props.backgroundColor = f.color or { 150, 150, 150, 255 }
        infoPolityLabel:SetText(isTribal(f.name) and "部族" or "诸侯")
        infoFaithLabel:SetText("未定")          -- 宗教系统占位
        infoLeaderLabel:SetText("—")            -- 领袖数据未接入
        infoProvLabel:SetText(tostring(#(f.provinces or {})))
        -- ⚠️ 必须 math.floor：这三个是 number（月度结算会产生小数），
        --    而 string.format("%d", 3.7) 在 Lua 5.4 会**直接抛**
        --    "bad argument #2 to 'format' (number has no integer representation)"。
        --    实战后果：开局几十个月后，在选国/切换角色页点儿国家，整个页面直接崩掉。
        infoArmyLabel:SetText(string.format("%d", math.floor(f.armySize or 0)))
        infoGoldLabel:SetText(string.format("%d", math.floor(f.gold or 0)))
        infoFoodLabel:SetText(string.format("%d", math.floor(f.food or 0)))
        -- 2026-09-17：倾向/评语不再展示（见下方卡片布局处的说明）
        -- 旗帜（2026-09-17）：**锦旗式**（不带杆）+ 国名首字
        if infoFlagInner then
            infoFlagInner:ClearChildren()
            infoFlagInner:AddChild(Emblem.MakeCloth(f, "army", 84))
        end
    end

    --- 显示/隐藏详情卡
    ---@param v boolean
    local function showCard(v)
        if not infoCard then return end
        if v then infoCard:Show() else infoCard:Hide() end
    end

    --- 开始按钮启用态（未选国家时禁用）
    ---@param v boolean
    local function setStartEnabled(v)
        if not startBtn then return end
        startBtn:SetDisabled(not v)
        -- 禁用态别太淡：0.45 在手机上几乎看不见 → 0.62
        startBtn:SetOpacity(v and 1 or 0.62)
    end

    --- 选中某国：显示详情卡 + 地图整国高亮（镜头不动）
    ---@param f table
    local function select(f)
        if not f then return end
        selected = f
        updateInfo(f)
        showCard(true)
        setStartEnabled(true)
        -- 地图同步整国高亮（2026-09-18）：点地图进来的选中由地图自己设过了，
        --   但「随机角色」按钮/自动选中这些**不经过地图**的路径不会设 ——
        --   这里补一次，保证"卡片显示谁，地图就亮谁"。
        --   粒度显式给 "faction"：选国页只按国家选（不钻省）。
        if mapWidget and f.provinces and f.provinces[1] then
            mapWidget:setSelectedProvince(f.provinces[1], "faction")
        end
    end

    --- 取消选中：收起详情卡 + 清除地图整国高亮（镜头保持原位）
    local function deselect()
        selected = nil
        showCard(false)
        setStartEnabled(false)
        if mapWidget then
            -- 清地图的选中省 = 清整国高亮
            -- （选国页这张图没传 shaderRenderer，所以真正生效的是 selectedProvinceId=nil，
            --   矢量那条路径读的就是它；游戏里那张图有 shaderRenderer，还会顺带清 shader 高亮）
            mapWidget:setSelectedProvince(nil)
        end
        print("[CountrySelect] 取消选中（收起介绍卡 + 清整国高亮）")
    end

    local function selectById(provId)
        local fid = provId and factionIdByProvince(provId) or nil
        local f = fid and factionById(fid)
        if not f then
            -- 点到**海洋/空白**（provId = nil），或点到**无主省份**（沙漠废土、无归属）
            -- → 当作"取消选中"。
            --
            -- 🔴 2026-09-15 用户反馈修的就是这里：
            --    原来第一行是 `if not provId then return end` —— 把"点空"直接吞掉了。
            --    地图那边点空会自己把 selectedProvinceId 清成 nil（画面上高亮就没了），
            --    但**右边的详情卡不会消失** —— 于是出现"国家不亮了、介绍还挂着"的矛盾状态。
            --    这里改成走 deselect()：收卡片 + 停用「开始」按钮，顺带再清一次地图选中。
            deselect()
            return
        end
        if selected and selected.id == f.id then
            deselect()          -- 再点同一国家的任意区块：收起介绍
        else
            select(f)           -- 点其他国家：切换介绍
        end
    end

    -- -------------------------------------------------------------------------
    -- 左栏：设置面板（AoH3 式：条目显示「标签: 值」+ 下方 << >> 方块按钮）
    -- -------------------------------------------------------------------------
    local TONE_RED   = { 112, 40, 40, 215 }
    local TONE_GREEN = { 52, 84, 48, 215 }

    ---@param labelText string
    ---@param list string[]
    ---@param key string
    ---@param tone table
    local function settingBlock(labelText, list, key, tone)
        local entryLabel = UI.Label {
            text = labelText .. ": " .. list[settings[key]],
            fontSize = 13, fontFamily = "gufeng", fontWeight = "bold",
            fontColor = { 240, 228, 205, 240 },
        }
        local function refresh()
            entryLabel:SetText(labelText .. ": " .. list[settings[key]])
        end
        local function step(d)
            local n = #list
            settings[key] = ((settings[key] - 1 + d) % n) + 1
            refresh()
            -- 同步给全局（选国页的 settings 是局部表，关掉页面就没了，
            --   而 main.lua 开局时要读 fog 这一项）
            _G.CS_SETTINGS = settings
        end
        local function arrowBtn(txt, d)
            return UI.Button {
                text = txt, flexGrow = 1, flexBasis = 0, height = 30, fontSize = 13,
                textColor = { 236, 222, 200, 235 },
                backgroundColor = { 62, 30, 30, 225 },
                hoverBackgroundColor = { 108, 48, 44, 240 },
                pressedBackgroundColor = { 48, 22, 22, 240 },
                borderRadius = 6,
                onClick = function() step(d) end,
            }
        end
        return UI.Panel {
            width = "100%", flexDirection = "column", gap = 4,
            children = {
                UI.Panel {
                    width = "100%", height = 38, borderRadius = 8,
                    backgroundColor = tone,
                    justifyContent = "center", alignItems = "center",
                    children = { entryLabel },
                },
                UI.Panel {
                    width = "100%", flexDirection = "row", gap = 6,
                    children = { arrowBtn("<<", -1), arrowBtn(">>", 1) },
                },
            },
        }
    end

    local settingsPanel = UI.Panel {
        id = "csSettingsPanel",        -- 给离屏 SHOT_RECT 量尺寸用
        width = "100%",
        backgroundColor = { 24, 20, 21, 238 },
        borderRadius = 10, padding = 8,
        flexDirection = "column", gap = 8,
        children = {
            UI.Panel {
                width = "100%", height = 34, borderRadius = 6,
                backgroundColor = { 96, 26, 32, 255 },
                justifyContent = "center", alignItems = "center",
                children = {
                    UI.Label { text = "设　置", fontSize = 16, fontFamily = "gufeng",
                               fontWeight = "bold", fontColor = { 240, 210, 120, 255 } },
                },
            },
            settingBlock("难度", DIFFICULTY_OPTS, "difficulty", TONE_RED),
            settingBlock("模式", MODE_OPTS, "mode", TONE_GREEN),
            settingBlock("AI 侵略度", AGGRESSION_OPTS, "aggression", TONE_RED),
            settingBlock("战争迷雾", FOG_OPTS, "fog", TONE_GREEN),
            UI.Label {
                text = "战争迷雾开启后，只看得见自己与接壤的领地；关闭则全图可见",
                fontSize = 9, width = "100%", textAlign = "center",
                whiteSpace = "normal", fontColor = { 190, 180, 165, 150 },
            },
            settingBlock("人物生死", MORTALITY_OPTS, "mortality", TONE_RED),
            UI.Label {
                text = "开启后官员与后宫也会随年龄老死，职位空缺需重新任命",
                fontSize = 9, width = "100%", textAlign = "center",
                whiteSpace = "normal", fontColor = { 190, 180, 165, 150 },
            },
        },
    }

    -- 设置面板容器（2026-09-15 两改）：
    --   ① 最早挂在左栏（左上角 ☰ 展开）→ ② 搬到右上角 → ③ **最终：右下角、贴着底栏**
    --   因为设置按钮本身按用户要求搬到下边栏了，面板就从下边长出来，和按钮挨着。
    settingsHolder = UI.Panel {
        id = "settingsOverlay",        -- 离屏钩子 SHOT_SETTINGS 靠这个 id 找它
        position = "absolute",
        -- 注意单位是 **base pixel**（= 窗口像素 / scale），不是窗口像素！
        -- 底栏高 60 base px，66 只留了 6 的缝，看着贴太紧 → 74
        right = 10, bottom = 74,
        width = LEFT_W, flexDirection = "column",
        children = { settingsPanel },
    }
    settingsHolder:Hide()   -- 默认收起（点底栏「设置」展开）

    -- -------------------------------------------------------------------------
    -- 上边那排：地图模组（用户："上边是地图包"→ 后来澄清是**所有地图包的总称**）
    -- -------------------------------------------------------------------------
    local modules = listMapModules()
    ---@type Widget[]
    local moduleChildren = {}
    for _, m in ipairs(modules) do
        local isActive = (m.id == BASE_MODULE_ID)   -- 现在只有一个模组，恒为选中
        moduleChildren[#moduleChildren + 1] = UI.Button {
            height = 40, borderRadius = 8,
            paddingLeft = 24, paddingRight = 24,
            justifyContent = "center", alignItems = "center",
            backgroundColor = isActive and { 96, 26, 32, 255 } or { 34, 30, 28, 230 },
            hoverBackgroundColor = { 118, 40, 42, 255 },
            pressedBackgroundColor = { 78, 22, 26, 255 },
            borderWidth = 1,
            borderColor = isActive and { 214, 172, 96, 220 } or { 96, 84, 68, 170 },
            onClick = function()
                if not isActive then
                    print("[CountrySelect] 点选地图模组 " .. tostring(m.name)
                        .. "（多模组还没做：等 A15⑦ 地图注册桥）")
                end
            end,
            children = {
                UI.Label {
                    -- 没命名 → 空白按钮（用户要的行为："没有名字就只是一个空白的按钮"）
                    text = m.name or "",
                    fontSize = 15, fontFamily = "gufeng", fontWeight = "bold",
                    fontColor = isActive and { 248, 226, 170, 255 } or { 206, 194, 176, 225 },
                },
            },
        }
    end

    -- 地图包多了要能横向滚（2026-09-15 用户："最上面地图包也是"）
    -- 注意：ScrollView 里那层要用 flexDirection=row + height="100%"，
    -- 否则按钮会被拉成整行高、垂直居中失效。
    local moduleBar = UI.Panel {
        width = "100%", height = 56,
        flexDirection = "row", alignItems = "center",
        paddingLeft = 10, paddingRight = 10,
        backgroundColor = { 22, 18, 16, 245 },
        borderBottomWidth = 1, borderBottomColor = { 110, 84, 56, 170 },
        children = {
            UI.ScrollView {
                width = "100%", height = "100%",
                scrollX = true, scrollY = false,
                showScrollbar = true,
                children = {
                    UI.Panel {
                        flexDirection = "row", alignItems = "center",
                        gap = 8, height = "100%",
                        children = moduleChildren,
                    },
                },
            },
        },
    }

    -- -------------------------------------------------------------------------
    -- 左边那列：当前地图模组里的地图名（用户："左边的也是这个地图的名字"）
    --   点别的图 = 热切换（2026-09-15 接上）：MapPack.switchTo（字段+省份数据+渲染常量）
    --   + 整页重建。
    --   ⚠️ 只有"还没开局"能换——局内（mode="switch"，见 isSwitch）不允许：
    --      世界数据（省份归属/势力/军队/存档）全按省份 id 存，换包 = 换整套 id 空间，
    --      换完世界就对不上（P 社换图 mod = 旧存档报废，同理）。
    --      局内这一列显示为禁用 + 一行说明。
    -- -------------------------------------------------------------------------
    local curModule = modules[1]
    local mapColTitle = UI.Panel {
        width = "100%", height = 28,
        justifyContent = "center", alignItems = "center",
        children = {
            UI.Label { text = "地　图", fontSize = 12, fontFamily = "gufeng",
                       fontWeight = "bold", fontColor = { 190, 160, 110, 220 } },
        },
    }
    -- 只有"地图行"进滚动区，标题留在外面（滚的时候标题不该跟着跑）
    ---@type Widget[]
    local mapColRows = {}
    for _, p in ipairs(curModule.packs or {}) do
        local isActive = (p.id == MapPack.activeId)
        -- 局内：非当前地图的行禁用（世界数据按省份 id 存，换包会对不上；见上方注释）
        local locked = isSwitch and not isActive
        mapColRows[#mapColRows + 1] = UI.Button {
            id = "csMap_" .. tostring(p.id),   -- 给离屏 SHOT_CLICK 用（如 csMap_world）
            width = "100%", height = 38,
            borderRadius = 8,
            disabled = locked,
            backgroundColor = isActive and { 96, 26, 32, 255 } or { 34, 30, 28, 230 },
            disabledBackgroundColor = { 26, 23, 22, 205 },
            hoverBackgroundColor = { 118, 40, 42, 255 },
            pressedBackgroundColor = { 78, 22, 26, 255 },
            borderWidth = 1,
            borderColor = locked and { 66, 58, 50, 150 }
                or (isActive and { 214, 172, 96, 220 } or { 96, 84, 68, 170 }),
            onClick = function()
                -- 局内兜底：按钮已灰，但指针层万一没拦，这里也不能真换（见上方注释）
                if isSwitch then
                    print("[CountrySelect] 局内不能换地图（世界数据按省份 id 存，换包会对不上）")
                    return
                end
                if isActive then return end
                -- 换地图（2026-09-15 接上；以前这里只打日志，所以"点了没反应"）
                --   `MapPack.switchTo` 负责：包的字段 + 整套省份数据 + 渲染常量/空间索引
                --   剩下的"作废的东西"（这张预览地图 widget、底图缓存）最省事也最不会错的
                --   处理方式 = **把这一页整个重建一遍** —— 选国页是纯预览、没有世界状态，
                --   重建代价很小，而且不会漏掉任何一个"按旧包算好"的东西。
                print(string.format("[CountrySelect] 换地图 → %s（%s）", tostring(p.name), tostring(p.id)))
                if not MapPack.switchTo(p.id) then
                    print("[CountrySelect] ⚠️ 换图失败，保持原样")
                    return
                end
                -- 重建这一页（带 _skipShotHooks：离屏钩子只在首次建页时跑，
                -- 否则 SHOT_CLICK 会在重建后又点一次 → 死循环）
                local opts2 = {}
                for k, v in pairs(opts) do opts2[k] = v end
                opts2._skipShotHooks = true
                CountrySelect.show(opts2)
            end,
            children = {
                UI.Panel {
                    width = "100%", height = "100%",
                    justifyContent = "center", alignItems = "center",
                    children = {
                        UI.Label { text = p.name, fontSize = 14, fontFamily = "gufeng",
                                   fontWeight = "bold",
                                   fontColor = locked and { 116, 106, 96, 190 }
                                       or (isActive and { 248, 226, 170, 255 }
                                           or { 214, 202, 178, 225 }) },
                    },
                },
            },
        }
    end

    -- 局内不允许换图 → 明说原因（用户要求：按钮灰掉或提示，别让玩家以为能换）
    local mapLockHint = nil
    if isSwitch then
        mapLockHint = UI.Panel {
            -- 明确高度：auto 高度按 fontSize 估得偏小，两行文字会溢出被裁（实测量出）
            width = "100%", height = 38, paddingTop = 4,
            flexDirection = "column", gap = 1,
            children = {
                UI.Label { text = "局内不能换图", fontSize = 11, fontFamily = "gufeng",
                           fontColor = { 176, 142, 96, 230 } },
                -- 文案长度受列宽限制（MAPCOL_W=150）：12 字会折行溢出，9 字刚好一行
                UI.Label { text = "会与当前世界对不上", fontSize = 10, fontFamily = "gufeng",
                           fontColor = { 130, 112, 88, 200 } },
            },
        }
    end

    local mapListCol = UI.Panel {
        width = MAPCOL_W,
        -- 必须给确定高度（height="100%"）：里面 ScrollView 是 flexGrow，
        -- 父容器尺寸不确定的话滚动区会塌成 0 高（ui.md 陷阱 9）
        height = "100%",
        flexDirection = "column",
        padding = 8,
        backgroundColor = { 20, 17, 16, 235 },
        borderRightWidth = 1, borderRightColor = { 110, 84, 56, 170 },
        children = {
            mapColTitle,
            -- 地图多了要能往下滚（2026-09-15 用户："应该是可以往下的"）
            UI.ScrollView {
                width = "100%", flexGrow = 1, flexBasis = 0,
                scrollY = true, showScrollbar = true,
                children = {
                    UI.Panel { width = "100%", gap = 6, children = mapColRows },
                },
            },
            mapLockHint,   -- 仅局内非 nil（末尾 nil 在 table 构造器里自动跳过）
        },
    }

    -- -------------------------------------------------------------------------
    -- 中栏：活地图 Widget（缩放/拖拽/点击选国） + 悬浮控件（默认全图视野）
    --   * 传入"选国用轻量 gameState"（省份归属 + 势力颜色）：
    --     点击省份时地图会以该省为锚点【高亮其所属国家的全部领土】
    --   * 点选不移动镜头（符合主流做法：EU4/CK3/AoH3 点选均不聚焦）
    -- -------------------------------------------------------------------------
    -- 切换模式：借当前局的省份/势力表，但**不借**玩家与地图模式 ——
    --   ① playerFactionId 传 nil：这一页没有"我方"，免得战争/盟友模式把地图染色带进来
    --   ② mapMode 强制 political：玩家在局内可能切到了"战争"版图，选国页要中立底色
    local selectGS
    if liveGS then
        selectGS = {
            provinces       = liveGS.provinces,
            factions        = liveGS.factions,
            relations       = liveGS.relations,
            battles         = liveGS.battles,
            playerFactionId = nil,
            mapMode         = "political",
        }
    else
        selectGS = { provinces = {}, factions = {}, playerFactionId = nil }
        for _, f in ipairs(Factions.data or {}) do
            if f.provinces and #f.provinces > 0 then
                selectGS.factions[f.id] = { id = f.id, name = f.name, color = f.color }
                for _, pid in ipairs(f.provinces) do
                    selectGS.provinces[pid] = { ownerId = f.id }
                end
            end
        end
    end

    -- factionSelectOnly（2026-09-18 用户）：选国页点地图**只选国家** ——
    --   整国高亮 + 右侧介绍卡；不给"再点一次钻到省"（那是游戏内才要的两段式）
    mapWidget = MapRenderer.create(selectGS, nil, { factionSelectOnly = true })
    mapWidget.onProvinceClick = function(provId)
        -- 粒度日志（2026-09-18）：此刻地图刚设完选择、还没被下面的"
        --   同国再点 = 收起卡片"清掉 —— 查"选国页是不是真的只按国家选"就看这里。
        --   带上国家名：反复点同一个国家的两块地，粒度应恒为 faction（不钻省）
        local fidLog = provId and factionIdByProvince(provId) or nil
        local fLog = fidLog and factionById(fidLog)
        print(string.format("[CountrySelect] 地图点击：省=%s ｜ 粒度=%s ｜ 国家=%s",
            tostring(provId), tostring(mapWidget.selectionLevel_),
            tostring(fLog and fLog.name or "无")))
        selectById(provId)
    end

    local mapOverlay = {
        UI.Panel {
            position = "absolute", left = 8, bottom = 8,
            backgroundColor = { 10, 10, 14, 170 }, borderRadius = 6,
            paddingLeft = 8, paddingRight = 8, paddingTop = 4, paddingBottom = 4,
            children = {
                -- 底栏那句「选中国家，再点开始」搬到这里了（2026-09-15）：
                --   底栏加了「设置」之后一共 5 个按钮，800 宽下再塞提示会把按钮挤出去。
                --   地图这条本来就在，合并成一条更省地方。
                -- ⚠️ 别加 maxWidth + whiteSpace="normal" 想让它换行 —— 实测那样整条会**高度算成 0、
                --    直接不显示**。改成单行 + 把文案压短到放得下（详情卡左边缘之前）。
                UI.Label { text = "点国家看介绍 · 再点收起 · 滚轮/双指缩放 · 选中国家后点「"
                            .. (isSwitch and "切换" or "开始") .. "」",
                           fontSize = 10, fontColor = { 235, 225, 200, 175 } },
            },
        },
        -- 「全图」按钮已删（2026-09-12 用户要求）：开局本就是全图视野，
        -- 想拉回全图用双指捏合/滚轮缩小即可
    }

    -- 地图容器：也给不透明深色（地图 widget 万一没铺满，四周也不会透出白底）
    local mapPanel = UI.Panel { flexGrow = 1, borderRadius = 0,
                                backgroundColor = { 12, 18, 30, 255 },
                                children = { mapWidget } }
    for _, w in ipairs(mapOverlay) do
        mapPanel:AddChild(w)
    end

    -- -------------------------------------------------------------------------
    -- 右栏：国家详情卡（照 AoH3 参考图：红标题条 / 旗帜+人物 / 属性 / 数值 / 外交）
    -- 所有图标位置 = 空槽预留（后续生成图标后替换）
    -- -------------------------------------------------------------------------
    titleLabel = UI.Label { text = "-", fontSize = 16, fontFamily = "gufeng",
                            fontWeight = "bold", fontColor = { 245, 220, 150, 255 } }
    emblemDot = UI.Panel { width = 16, height = 16, borderRadius = 4,
                           backgroundColor = { 150, 150, 150, 255 } }

    -- 空白占位槽（旗帜 / 人物）
    local function emptySlot(capText, slotH)
        return UI.Panel {
            flexGrow = 1, flexBasis = 0, height = slotH,
            backgroundColor = { 32, 28, 30, 225 },
            borderWidth = 1, borderColor = { 100, 88, 70, 150 },
            borderRadius = 6,
            justifyContent = "center", alignItems = "center",
            children = {
                UI.Label { text = capText, fontSize = 10, fontColor = { 150, 140, 125, 150 } },
            },
        }
    end

    --- 旗帜位（2026-09-17）：**真正的旗子** —— 牙旗素材（纯白）染势力色 + 国名首字
    ---   用户："国家领土是什么颜色就用什么颜色的旗帜，然后再加个名字" → 现在直接用旗素材
    ---@type Widget
    local flagSlot = (function()
        infoFlagInner = UI.Panel { justifyContent = "center", alignItems = "center" }
        infoFlagPanel = UI.Panel {
            flexGrow = 1, flexBasis = 0, height = 96,
            backgroundColor = { 30, 27, 30, 225 },
            borderRadius = 6,
            borderWidth = 1, borderColor = { 100, 88, 70, 190 },
            justifyContent = "center", alignItems = "center",
            children = { infoFlagInner },
        }
        return infoFlagPanel
    end)()

    -- 属性列（值 + 小标签）
    --   2026-09-16：原来值上面还有个 20px 的**空图标槽**（等以后填图标），
    --   用户看到一排空方块以为界面坏了 → 去掉；将来真有图标再加回来
    local function infoCol(capText, valueLabel)
        return UI.Panel {
            flexGrow = 1, flexBasis = 0,
            flexDirection = "column", alignItems = "center", gap = 3,
            children = {
                valueLabel,
                UI.Label { text = capText, fontSize = 10, fontColor = { 155, 145, 130, 175 } },
            },
        }
    end

    infoPolityLabel = UI.Label { text = "-", fontSize = 12, fontWeight = "bold", fontColor = { 232, 222, 206, 240 } }
    infoFaithLabel  = UI.Label { text = "-", fontSize = 12, fontWeight = "bold", fontColor = { 232, 222, 206, 240 } }
    infoLeaderLabel = UI.Label { text = "-", fontSize = 12, fontWeight = "bold", fontColor = { 200, 188, 170, 225 } }

    -- 数值列（大数字 + 小标签）
    local function statCol(capText, valueLabel)
        return UI.Panel {
            flexGrow = 1, flexBasis = 0,
            flexDirection = "column", alignItems = "center", gap = 3,
            children = {
                valueLabel,
                UI.Label { text = capText, fontSize = 10, fontColor = { 155, 145, 130, 175 } },
            },
        }
    end

    infoProvLabel = UI.Label { text = "-", fontSize = 17, fontWeight = "bold", fontColor = { 238, 230, 214, 245 } }
    infoArmyLabel = UI.Label { text = "-", fontSize = 17, fontWeight = "bold", fontColor = { 226, 132, 118, 245 } }
    infoGoldLabel = UI.Label { text = "-", fontSize = 17, fontWeight = "bold", fontColor = { 242, 202, 92, 245 } }
    infoFoodLabel = UI.Label { text = "-", fontSize = 17, fontWeight = "bold", fontColor = { 150, 204, 126, 245 } }

    -- 2026-09-17 删：infoPersonaLabel / infoDescLabel（倾向与评语不再展示）

    local divider = UI.Panel { width = "100%", height = 1, backgroundColor = { 96, 86, 70, 110 } }

    infoCard = UI.Panel {
        -- 悬浮在地图之上（absolute：出现/隐藏不挤压地图、不改变地图视口）
        position = "absolute",
        -- top 10 → 66（2026-09-15）：右上角现在是设置按钮（top 8 + 高 50 = 到 58），
        -- 卡片从 66 起，正好让开，不会被按钮压住
        -- 2026-09-16：去掉 bottom（原来拉到贴底，是为给"外交"占位块留地方）；
        --   现在按**内容高度**悬浮，底下不再是一大片空
        right = 10, top = 66,
        width = RIGHT_W,
        backgroundColor = { 22, 19, 22, 240 },
        borderWidth = 1, borderColor = { 120, 92, 60, 190 },
        borderRadius = 10, padding = 10,
        flexDirection = "column", alignItems = "center", gap = 8,
        children = {
            -- 顶部标题条（酒红）：色块 + 国名
            UI.Panel {
                width = "100%", height = 36, borderRadius = 8,
                backgroundColor = { 96, 26, 32, 255 },
                flexDirection = "row", alignItems = "center", justifyContent = "center", gap = 8,
                children = { emblemDot, titleLabel },
            },
            -- 旗帜位（**势力色 + 国名**）/ 人物位（仍是待填占位）
            UI.Panel {
                flexDirection = "row", gap = 6, width = "100%",
                children = { flagSlot, emptySlot("人物", 96) },
            },
            -- 政体 / 信仰 / 领袖（图标位预留）
            UI.Panel {
                flexDirection = "row", width = "100%",
                children = {
                    infoCol("政体", infoPolityLabel),
                    infoCol("信仰", infoFaithLabel),
                    infoCol("领袖", infoLeaderLabel),
                },
            },
            divider,
            -- 国势四数值（图标位预留）
            UI.Panel {
                flexDirection = "row", width = "100%", paddingTop = 2, paddingBottom = 2,
                children = {
                    statCol("省份", infoProvLabel),
                    statCol("兵员", infoArmyLabel),
                    statCol("金", infoGoldLabel),
                    statCol("粮", infoFoodLabel),
                },
            },
            divider,
            -- 2026-09-17 删：原来这里显示「倾向：守成 / 稳守基业，徐图进取。」
            --   用户："这个倾向在哪里能看到？还是说只是背景？别的游戏没有这些，要不要把它去除？
            --   这个国家怎么样只是靠他们的君王，所以我觉得这个没用，评价也不要有"
            --   → AI 倾向本身**照旧在数据里生效**（AIManager 用它决定宣战/求和概率），
            --     只是不再在选国页展示 —— 玩家不需要看到 AI 的内部参数。
            --   （原来的「难度」星级更早就删掉了。）
            -- 2026-09-16 删：原来这里有个「外交」占位块（3 个空图标槽 + 一行 "———"），
            --   用户看到那 3 个空格子问"为什么会出现这种情况" —— 它是**画着等以后填图标**的
            --   预留位，从来没填过；而外交操作现在已经有了正经入口（局内「外交」面板 +
            --   国交行动），选国页不需要再占一块。
            --   ⚠️ 教训：预留位要画出**可见的说明**（或干脆先不放），别让人以为界面坏了。
        },
    }
    infoCard:Hide()   -- 默认隐藏：点国家区块才出现

    -- -------------------------------------------------------------------------
    -- 底部栏（返回 / 提示 / 开始；无旗条、无"创建文明"）
    -- -------------------------------------------------------------------------
    local backBtn = UI.Button {
        id = "csBackBtn",
        -- 140 → 110（2026-09-15）：底栏左侧新增「随机角色」「观察」，一行要塞 4 个按钮
        width = 110, height = 36,
        backgroundColor = { 62, 34, 34, 235 },
        hoverBackgroundColor = { 96, 46, 42, 245 },
        pressedBackgroundColor = { 46, 24, 24, 245 },
        borderRadius = 8,
        onClick = function()
            if opts.onBack then opts.onBack() end
        end,
        children = {
            UI.Panel { width = "100%", height = "100%", justifyContent = "center",
                       alignItems = "center",
                       children = { UI.Label { text = "‹返回", fontSize = 14, fontFamily = "gufeng",
                            fontWeight = "bold", fontColor = { 238, 222, 190, 235 } } } },
        },
    }

    startBtn = UI.Button {
        id = "csStartBtn",
        -- 210 → 190：底栏现在有 4 个按钮 + 提示语，给它们让点位置（800 宽也只是刚够）
        width = 190, height = 46,
        backgroundColor = { 148, 44, 44, 250 },
        hoverBackgroundColor = { 178, 56, 52, 252 },
        pressedBackgroundColor = { 120, 34, 36, 252 },
        borderRadius = 8,
        onClick = function()
            if selected and opts.onStart then
                -- 携带当前镜头视角开局（进入游戏后继承，不跳回全图）
                local camState = nil
                if mapWidget then
                    camState = {
                        camX = mapWidget.camX,
                        camY = mapWidget.camY,
                        zoom = mapWidget.zoom,
                    }
                end
                opts.onStart(selected.id, settings, camState)
            end
        end,
        children = {
            UI.Panel { width = "100%", height = "100%", justifyContent = "center",
                       alignItems = "center",
                       children = { UI.Label { text = isSwitch and "切　换" or "开　始",
                            fontSize = 19, fontFamily = "gufeng",
                            fontWeight = "bold", fontColor = { 248, 226, 170, 255 } } } },
        },
    }

    -- -------------------------------------------------------------------------
    -- 左下两个按钮（照 CK3 参考图的位置）：「随机角色」「观察」
    --   随机角色 = 随便挑一个**选中**（不直接进场，还能反悔 —— 用户明确要求"然后还能点切换"）
    --   观察     = 看海（playerFactionId = nil）；没给 onSpectate 回调就不显示
    -- -------------------------------------------------------------------------
    ---@param w number|nil 宽度（默认 112）
    local function smallBtn(id, text, onClick, w)
        return UI.Button {
            id = id,            -- 给离屏 SHOT_CLICK 用
            -- 96 → 112：实测「随机角色」4 个字在 96 宽里会折成两行
            --（照截图量：3 字的「观察」占约 60px ≈ 20px/字，4 字要 80px + 内边距）
            width = w or 112, height = 36,
            backgroundColor = { 52, 42, 30, 235 },
            hoverBackgroundColor = { 92, 74, 48, 245 },
            pressedBackgroundColor = { 40, 32, 24, 245 },
            borderWidth = 1, borderColor = { 128, 100, 64, 190 },
            borderRadius = 8,
            onClick = onClick,
            children = {
                UI.Panel { width = "100%", height = "100%", justifyContent = "center",
                           alignItems = "center",
                           children = { UI.Label { text = text, fontSize = 14, fontFamily = "gufeng",
                                fontWeight = "bold", fontColor = { 238, 222, 190, 235 } } } },
            },
        }
    end

    local randomBtn = smallBtn("csRandomBtn", "随机角色", function()
        local pool = listFactions()
        if #pool == 0 then return end
        local f = pool[math.random(1, #pool)]
        select(f)
        -- select() 只管详情卡；整国高亮得让地图自己来（focusProvince 顺带把镜头带过去）
        if mapWidget and f.provinces and f.provinces[1] then
            mapWidget:focusProvince(f.provinces[1])
        end
        print("[CountrySelect] 随机角色 → " .. tostring(f.name) .. "(id=" .. tostring(f.id) .. ")")
    end)

    local spectateBtn = opts.onSpectate and smallBtn("csSpectateBtn", "观　察", function()
        -- 和「开始 / 切换」一样，带上当前镜头视角（不然进游戏会跳回全图）
        local camState = nil
        if mapWidget then
            camState = { camX = mapWidget.camX, camY = mapWidget.camY, zoom = mapWidget.zoom }
        end
        if opts.onSpectate then opts.onSpectate(camState) end
    end) or nil

    -- 设置按钮（2026-09-15 再改）：
    --   ① 从**右上角**搬到**下边栏**（用户："一样放到下边去"）
    --   ② 从三横线图标改成**写着「设置」两个字**（用户："给他名字就是设置"）
    --   原来那个 ☰ 图标按钮整个删掉了 —— 图标认不出来是干嘛的，用户也这么说
    local settingsBtn = smallBtn("csSettingsBtn", "设置", function()
        if not settingsHolder then return end
        -- 设置面板和国家详情卡都在右半边，会打架 → 开一个就收起另一个
        if settingsHolder:IsVisible() then
            settingsHolder:Hide()
            if selected then showCard(true) end   -- 关设置 → 国家卡回来
        else
            settingsHolder:Show()
            showCard(false)                      -- 开设置 → 给设置让位
        end
    end, 84)

    -- 底栏（2026-09-16 用户改序）：**返回放最左下角**，接着 设置 → 随机角色 → 观察，
    --   右端仍是「开始」；中间用弹性空格顶开
    -- 用 append 拼而不是表构造器：spectateBtn 可能为 nil，写成 {a, nil, b} 会留空洞，
    -- 而 ipairs 遇到空洞就停 —— 后面的按钮会整排消失。
    ---@type Widget[]
    local footerChildren = { backBtn, settingsBtn }   -- 显式声明元素类型：不写会被推断成 Button?[]，塞 Panel 就报错
    footerChildren[#footerChildren + 1] = randomBtn
    if spectateBtn then footerChildren[#footerChildren + 1] = spectateBtn end
    footerChildren[#footerChildren + 1] = UI.Panel { flexGrow = 1 }
    footerChildren[#footerChildren + 1] = startBtn

    local footer = UI.Panel {
        width = "100%", height = 60,
        flexDirection = "row", alignItems = "center", gap = 10,
        borderTopWidth = 1, borderTopColor = { 110, 84, 56, 170 },
        paddingTop = 7, paddingBottom = 7, paddingLeft = 10, paddingRight = 10,
        children = footerChildren,
    }

    -- 根面板 = 不透明深色底（2026-09-13 修）：
    --   原来是透明的（3D 时代的规矩：底色会盖住 UI 之下的 3D 地图层），
    --   但 3D 已废弃、地图改由 UI 自己画 → 透明底在手机上会透出平台的白色，
    --   浅色按钮全糊掉（实测截图 55% 像素 alpha=0）。现在铺满深色。
    local root = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = { 16, 14, 12, 255 },
        flexDirection = "column",
        children = {
            -- 上边那排：地图模组（2026-09-15 新增，照 CK3 的剧本分组那一排）
            moduleBar,
            -- 主体：地图名（左一列） | 地图（右侧全宽；详情卡悬浮其上、不挤压地图）
            UI.Panel {
                width = "100%", flexGrow = 1, flexBasis = 0,
                flexDirection = "row", gap = 0,
                padding = 0,
                children = { mapListCol, mapPanel },
            },
            footer,          -- 含「设置」按钮（2026-09-15 从右上角搬下来）
            infoCard,        -- 悬浮层：点国家出现、再点收起
            settingsHolder,  -- 弹层：从右下角长出（贴着底栏）
        },
    }

    -- 初始：未选中任何国家（默认全图视野，不聚焦）
    setStartEnabled(false)

    UI.SetRoot(root)

    -- 离屏测试钩子（放在页面建完之后，否则详情卡的控件还没建）：
    --   SHOT_SELECT=<势力id>  自动选中该国 → 画出国家外轮廓
    --   SHOT_ZOOM=<倍率>      设定初始倍率
    -- 用途：截图验证"金边是否贴合底图黑线"
    -- 离屏钩子只在**首次建页**时跑：换地图会把这一页重建一遍（见地图行的 onClick），
    -- 重建时若还跑一次，SHOT_CLICK 就会再点一下 → 再换图 → 死循环。
    if not opts._skipShotHooks then
        -- ⚠️ SHOT_SELECT 被 main.lua 复用成"入口=选国页"的分发开关了，两者会打架：
        --    在**局内**打开切换页时再传 SHOT_SELECT，entry 会被判成 "select"，
        --    结果是"又开了一局新的"而不是"打开切换页"。所以局内这条链路用 SHOT_PAGE_SELECT。
        local shotSel = os.getenv and tonumber(os.getenv("SHOT_PAGE_SELECT")
            or os.getenv("SHOT_SELECT") or "")
        local shotZoom = os.getenv and tonumber(os.getenv("SHOT_ZOOM") or "")
        if shotSel then
            -- 走 listFactions()：切换模式下要按"当前这局活着的势力"找，静态表在那是错的
            for _, f in ipairs(listFactions()) do
                if f.id == shotSel and f.provinces and f.provinces[1] then
                    selectById(f.provinces[1])
                    -- 有倍率就把镜头对到该国，否则停在默认全图视野
                    if shotZoom and mapWidget.focusProvince then
                        mapWidget:focusProvince(f.provinces[1], shotZoom)
                    end
                    print("[CountrySelect] SHOT_SELECT 自动选中势力 " .. tostring(shotSel))
                    break
                end
            end
        elseif shotZoom then
            mapWidget.zoom = shotZoom
            mapWidget.targetZoom = shotZoom
        end
        if shotZoom then
            print("[CountrySelect] SHOT_ZOOM=" .. tostring(shotZoom))
        end

        -- SHOT_CLICK=<控件id> → 点一下本页某个按钮
        --   （离屏验证"随机角色/观察/切换"这些按钮真的能点出效果，而不是只看它在不在）
        local shotClick = os.getenv and os.getenv("SHOT_CLICK")
        if shotClick and UI.FindById then
            local w = UI.FindById(shotClick)
            if w and w.OnClick then
                w:OnClick(nil)
                print("[CountrySelect] SHOT_CLICK=" .. shotClick .. " 已点击")
            else
                print("[CountrySelect] ⚠️ SHOT_CLICK 找不到控件 " .. tostring(shotClick))
            end
        end

        -- SHOT_MAPCLICK=nil|<省id> → 模拟"在地图上点了一下"，走的是**地图的真实回调**
        --   （MapRenderer 点海洋/废土时就是调 onProvinceClick(nil)）
        --   用途：验证"点空白 → 取消选中 + 右边介绍卡收起"
        local mapClick = os.getenv and os.getenv("SHOT_MAPCLICK")
        if mapClick and mapWidget and mapWidget.onProvinceClick then
            local pid = (mapClick == "nil") and nil or tonumber(mapClick)
            print("[CountrySelect] SHOT_MAPCLICK=" .. mapClick .. "（模拟地图点击）")
            mapWidget.onProvinceClick(pid)
        end
    end
end

return CountrySelect

-- ============================================================================
-- 逐鹿九州 - 全局配置
-- ============================================================================
local GameConfig = {}

-- 游戏基本信息
GameConfig.Title = "逐鹿九州"
GameConfig.Version = "0.1.0"

-- 当前地图包（"eu4"=EU4 欧亚非）
-- 地图包选择见 data.MapPack 注册表；主菜单/存档可覆盖此默认值
-- （2026-09-14 删掉了旧的 legacy 包，见 MapPack.lua 顶部注释）
GameConfig.MapPack = "eu4"

-- 地图配置（逻辑坐标系）
GameConfig.Map = {
    WIDTH = 960,           -- 逻辑宽度
    HEIGHT = 600,          -- 逻辑高度
    MIN_ZOOM = 0.5,        -- 最小缩放
    MAX_ZOOM = 3.0,        -- 最大缩放
    DEFAULT_ZOOM = 1.0,    -- 默认缩放
    SCROLL_SPEED = 300,    -- WASD滚动速度（像素/秒）
    ZOOM_SPEED = 0.1,      -- 缩放速度
    BG_COLOR = {45, 80, 120, 255},  -- 海洋/背景色
}

-- 时间配置
GameConfig.Time = {
    START_YEAR = -770,     -- 公元前770年
    START_MONTH = 1,
    START_DAY = 1,
    START_HOUR = 6,
    DAYS_PER_MONTH = 30,   -- 简化：每月30天
    MONTHS_PER_YEAR = 12,
    HOURS_PER_DAY = 24,
    -- 速度档位：现实1秒 = 游戏N小时（2026-09-19 扩到 7 档）
    -- 基准：3档"1速" = 24小时/秒（1秒=1天）；快档照 EU4（他们最快 10 天/秒），
    -- 我们多给两档（10、20）——大地图长时段推进用，EU4 一局全程约 12 小时
    SPEEDS = {
        {name = "1/4速", hoursPerSec = 6},
        {name = "1/2速", hoursPerSec = 12},
        {name = "1速",   hoursPerSec = 24},
        {name = "2速",   hoursPerSec = 48},
        {name = "5速",   hoursPerSec = 120},
        {name = "10速",  hoursPerSec = 240},
        {name = "20速",  hoursPerSec = 480},
    },
    DEFAULT_SPEED = 3,     -- 默认1速（索引）
}

-- 经济配置
GameConfig.Economy = {
    BASE_INCOME_PER_POP = 0.01,     -- 每人口每月基础金收入
    -- 2026-09-16 删：TAX_RATES / DEFAULT_TAX（税率四档废弃）
    --   用户："国家面板里的税率和政策那里好像重复了" → 经济杠杆交给政策卡
    ARMY_GOLD_COST = 5,    -- 每千兵每月金消耗
    ARMY_FOOD_COST = 8,    -- 每千兵每月粟消耗
}

-- 军事配置
GameConfig.Military = {
    RECRUIT_COST_GOLD = 20,    -- 每1000兵征兵金费用（2026-09-19 数值×10）
    RECRUIT_COST_FOOD = 30,    -- 每1000兵征兵粟费用（2026-09-19 数值×10）
    -- 默认征召量（不传 wanted 时用；AI 每月也以它为上限）。
    -- ⚠️ 2026-09-24 起**不再是计价单位**：成本按人头等比（见 MilitarySystem.recruitCostFor），
    --   填多少就征多少 —— 以前按它向上取整，导致填 100 也征 1000、成本还不随数量变。
    RECRUIT_BATCH = 1000,
    RECRUIT_RATE = 0.03,       -- 和平征兵率（人口的3%）
    -- 兵源池（2026-09-25 照 AoH3/CK3/EU4 三家口径，替代旧的"每月配额"）
    --   旧做法是"人口 × RECRUIT_RATE，每月清零重置" —— 三家没有一家这么做，
    --   而且会导致"人口 30 万的省每月只能征 9000，想征 1 万被卡住却不提示"。
    --   三家全是总量池子：CK3 按领地出固定征召兵、EU4 是人力池、AoH3 是人口 ×10~20%。
    MANPOOL_RATIO = 0.15,      -- 兵源池上限 = 省人口 × 此比例（AoH3 是 10~20%，取中值）
    MANPOOL_REGEN = 0.04,      -- 兵源池每月恢复比例（占上限的百分比）
    -- 养不起兵时的惩罚（2026-09-25，照 CK3"逐渐崩溃"而非"立即解散"）
    BANKRUPT_MORALE_HIT = 10,  -- 金或粮任一为负 → 士气 -此值（两者都负则叠加）
    DESERTION_RATE = 0.05,     -- 同上 → 每月逃兵比例
    REVOLT_ARMY_RATE = 0.15,   -- 士气归零后，每月哗变解散的兵力比例（持续赤字才会走到这）
    MOVE_DAYS = 3,             -- 军队移动到相邻省份天数（游戏天数）
    MIN_MARCH_REAL_SEC = 3,    -- 行军最少现实秒数（2026-09-01：极速档也可见移动过程）
    BASE_MORALE = 100,         -- 基础士气
    MORALE_RECOVERY = 5,       -- 脱战后每天恢复
    ROUT_MORALE = 20,          -- 溃逃士气阈值
    -- 战斗结算（2026-09-13 改：按"游戏天"结算 + 士气崩溃溃退，照 P 社）
    BATTLE_TICK_HOURS = 24,    -- 每满 24 游戏小时结算一轮（这样兵力数字每天都在动）
    BATTLE_DAILY_LOSS_MAX = 0.12,  -- 每天最多损失该方兵力的比例
    BATTLE_MIN_LOSS = 1,       -- 每天每方至少损失 1 兵（小部队也不会"数字不动"）
    MORALE_LOSS_BASE = 4,      -- 每天基础士气损失
    MORALE_LOSS_SCALE = 30,    -- 按"当日损失占自身比例"追加的士气损失
    ROUT_RETREAT_HOURS = 96,   -- 溃退行军时长（比正常行军慢，4 天）
    ROUT_RETREAT_RANGE = 3,    -- 溃退时「就近找己方省」的最大跳数（1=只允许相邻）
    ROUT_MIN_SIZE = 1,         -- 溃退后至少保留的兵力
    OCCUPY_DAYS = 10,          -- 占领需要天数
    CAPITAL_FALL_HOURS = 72 * 24,  -- 首都沦陷小时数（72天简化）
    -- 补给（2026-09-19 照 CK3）：省的"养兵容量"是**容量不是存量**——
    --   驻军 ≤ 容量 → 安稳；驻军超过容量 → **超编部分**每月饿死/逃散
    --   2026-09-19 首次实测：基础容量 300 时**开局各国就全员超编**（首都+边境的分配
    --   本身就超过 300），天天掉兵 → 抬到 800。补给应该是"极端情况的惩罚"
    --   （大军堆在穷省、远征久留），不是日常扣血。
    SUPPLY_BASE = 5000,        -- 每省基础补给容量（2026-09-19 照 CK3：平原 ~5000）
    SUPPLY_ATTRITION = 0.08,   -- 超编部分每月损耗比例

    -- 驻军自动补员（2026-09-23 用户拍板，照 CK3）：
    --   规则：**有将军**的驻军，在自家省、兵力低于将军统兵上限 → 每月自动补（花金/粮）
    --   没将军 = 纯数字驻军，不自动补（只能手动征兵）
    COMMANDER_TROOPS_PER_MILITARY = 500,  -- 将军统兵上限 = 军事属性 × 此值（3 → 1500，5 → 2500）
    REPLENISH_RATE = 0.25,     -- 每月补上缺口的比例（0.25 ≈ 4 个月补满，不瞬满）

    -- 国家士气（faction.morale）月度恢复（2026-09-26 修）
    --   背景：这个值只在"养不起兵"时被扣（BANKRUPT_MORALE_HIT），**从来没有恢复过**，
    --   而且界面上看不到 → 破产几次后它悄悄归零，之后每次破产都直接触发哗变，
    --   玩家完全不知道自己正在滑向崩溃。
    --   （2026-09-26 核实：全项目对 faction.morale 只有减号、没有加号。）
    --   修法：**不欠饷的月份自动回升**（照 EU4 的"每月回士气"），给玩家爬出坑的机会。
    FACTION_MORALE_RECOVERY = 5,   -- 每月恢复多少（不欠饷时）
    FACTION_MORALE_MAX = 100,      -- 上限
    FACTION_MORALE_WARN = 30,      -- 低于此值给一条预警（再破产几次就要哗变了）
}

-- 外交配置
GameConfig.Diplomacy = {
    MIN_RELATION = -100,
    MAX_RELATION = 100,
    IMPROVE_PER_MONTH = 2,     -- 改善关系每月+2
    IMPROVE_COST = 10,         -- 改善关系每月费用
    WAR_DECLARE_PRESTIGE = -10,-- 宣战威望消耗
    SAME_CULTURE_BONUS = 10,   -- 同文化关系加成
    NEIGHBOR_PENALTY = -5,     -- 邻国摩擦
    WAR_RELATION_DROP = -40,   -- 战争后关系下降
    PEACE_COOLDOWN_MONTHS = 60,-- 和平后冷却月数（2026-09-17：12→60，照 EU4 的停战期 5 年）
}

-- 稳定度配置
GameConfig.Stability = {
    MAX = 100,
    MIN = 0,
    BASE_RECOVERY = 1,         -- 每月基础恢复
    GARRISON_BONUS = 2,        -- 每千驻军加成（上限10）
    FOREIGN_CULTURE_PENALTY = -5,
    NEW_OCCUPATION_PENALTY = -5,
    REVOLT_THRESHOLD = 20,     -- 叛乱触发阈值
    REVOLT_CHANCE = 0.1,       -- 低于阈值时每月叛乱概率
}

-- AI配置
GameConfig.AI = {
    DECISION_INTERVAL_MONTHS = 1,  -- AI决策间隔
    ATTACK_STRENGTH_RATIO = 1.5,   -- 攻击力量比阈值
    ATTACK_CHANCE = 0.3,           -- 满足条件时宣战概率
    PEACE_CHANCE = 0.5,            -- 劣势时求和概率
    RECRUIT_THRESHOLD = 0.5,       -- 兵力低于邻国此比例时征兵
    -- 征兵节制（2026-09-17 用户："他招出军队速度也太频繁了，你看看别人的游戏"）
    RECRUIT_COOLDOWN = 6,          -- 两次征兵之间至少间隔几个月（照 EU4 的造兵节奏）
    ARMY_CAP_PER_PROVINCE = 500,   -- 兵力上限 = 省份数 × 此值（EU4 force limit 思路；随兵力总量 ÷5）
    -- 战争执行（2026-08-31 AI 真正调军进攻）
    ATTACK_MIN_GARRISON = 180,     -- 前线省驻军≥此值才发起进攻（随兵力总量 ÷5）
    ATTACK_MOVE_RATIO   = 0.6,     -- 进攻时调走驻军的比例
    SUPPLY_THRESHOLD    = 400,     -- 后方省驻军>此值才开始向前线补给（随兵力总量 ÷5）
    SUPPLY_MOVE         = 240,     -- 每次补给调走的兵力（随兵力总量 ÷5）
    -- 抢占无主白地（2026-09-26 用户："这些白色可占领区域…AI也不去"）
    --   白地不设防，所以门槛比打仗低；但必须留人守家，不能把老本全押出去。
    CLAIM_KEEP_GARRISON = 200,     -- 占白地时本省至少留这么多守军
    CLAIM_MIN_TROOPS    = 100,     -- 派出兵力少于此值就不值得跑一趟
    -- 宣战门槛（2026-09-17 用户："他怎么经常在打仗" → 照 EU4：不是想打就能打）
    DECLARE_WAR_MAX_RELATION = 0,  -- 关系高于此值就不宣战（关系≥0 = 无仇，不打朋友）
}

-- 颜色配置（UI用）
GameConfig.Colors = {
    PANEL_BG = {20, 25, 35, 230},
    PANEL_BORDER = {60, 70, 90, 200},
    TEXT_PRIMARY = {255, 255, 255, 255},
    TEXT_SECONDARY = {180, 190, 210, 200},
    HIGHLIGHT = {255, 200, 50, 255},
    DANGER = {220, 60, 60, 255},
    SUCCESS = {60, 180, 80, 255},
    BUTTON_BG = {50, 60, 80, 255},
    BUTTON_HOVER = {70, 80, 100, 255},
}

-- 图标 / 图案路径（2026-09-13 抽出来 → 玩家/模组可改）
--   ⚠️ 改图标有两条路：①直接替换同名图片文件 ②改这里的路径指向自己的图
--   规范：PNG、正方形、带透明底、图形居中（建议 128×128）
GameConfig.Icons = {
    -- 地图上的"交战中"标记（画在两军旗标中间）
    --   frames/fps：序列帧动画 —— 模组放一张 frames×frames 排布的帧图并写 fps 即可自带动画
    --   （frames = 1 表示静态图；size = 屏幕像素尺寸，默认 22 略小于军队旗标）
    battle = { path = "image/icon_war_双剑交叉.png", size = 22, frames = 1, fps = 0 },

    -- 被占领省的斜条纹图案（64×64 可无缝平铺；运行时按**占领方颜色**染色）
    occupiedStripes = "image/pattern_occupied_stripes.png",
}

return GameConfig

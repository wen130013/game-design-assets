-- ============================================================================
-- 逐鹿九州 - 全局配置
-- ============================================================================
local GameConfig = {}

-- 游戏基本信息
GameConfig.Title = "逐鹿九州"
GameConfig.Version = "0.1.0"

-- 当前地图包（"eu4"=EU4欧亚非主线 / "legacy"=旧手绘底图）
-- 地图包选择见 data.MapPack 注册表；主菜单/存档可覆盖此默认值
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
    -- 速度档位：现实1秒 = 游戏N小时
    -- 基准：3档"常" = 24小时/秒（1秒=1天），其余按倍率 1/4、1/2、1、2、5 缩放
    SPEEDS = {
        {name = "1/4速", hoursPerSec = 6},
        {name = "1/2速", hoursPerSec = 12},
        {name = "1速",   hoursPerSec = 24},
        {name = "2速",   hoursPerSec = 48},
        {name = "5速",   hoursPerSec = 120},
    },
    DEFAULT_SPEED = 3,     -- 默认1速（索引）
}

-- 经济配置
GameConfig.Economy = {
    BASE_INCOME_PER_POP = 0.01,     -- 每人口每月基础金收入
    TAX_RATES = {
        {name = "低税", rate = 0.5, stability = 2, growth = 0.005},
        {name = "标准", rate = 1.0, stability = 0, growth = 0},
        {name = "高税", rate = 1.5, stability = -1, growth = -0.003},
        {name = "压榨", rate = 2.0, stability = -3, growth = -0.01},
    },
    DEFAULT_TAX = 2,   -- 默认标准税率
    ARMY_GOLD_COST = 5,    -- 每千兵每月金消耗
    ARMY_FOOD_COST = 8,    -- 每千兵每月粟消耗
}

-- 军事配置
GameConfig.Military = {
    RECRUIT_COST_GOLD = 2,     -- 每100兵征兵金费用
    RECRUIT_COST_FOOD = 3,     -- 每100兵征兵粟费用
    RECRUIT_BATCH = 500,       -- 每次征兵数量
    RECRUIT_RATE = 0.03,       -- 和平征兵率（人口的3%）
    MOVE_DAYS = 3,             -- 军队移动到相邻省份天数（游戏天数）
    MIN_MARCH_REAL_SEC = 3,    -- 行军最少现实秒数（2026-09-01：极速档也可见移动过程）
    BASE_MORALE = 100,         -- 基础士气
    MORALE_RECOVERY = 5,       -- 脱战后每天恢复
    ROUT_MORALE = 20,          -- 溃逃士气阈值
    OCCUPY_DAYS = 10,          -- 占领需要天数
    CAPITAL_FALL_HOURS = 72 * 24,  -- 首都沦陷小时数（72天简化）
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
    PEACE_COOLDOWN_MONTHS = 12,-- 和平后冷却月数
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
    -- 战争执行（2026-08-31 AI 真正调军进攻）
    ATTACK_MIN_GARRISON = 800,     -- 前线省驻军≥此值才发起进攻
    ATTACK_MOVE_RATIO   = 0.6,     -- 进攻时调走驻军的比例
    SUPPLY_THRESHOLD    = 2000,    -- 后方省驻军>此值才开始向前线补给
    SUPPLY_MOVE         = 1200,    -- 每次补给调走的兵力
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

return GameConfig

-- ============================================================================
-- 春秋霸业 - 科技表（2026-09-16 第二版：**跨朝代**）
--   用户要求："不是春秋战国了，要能覆盖很多朝代；火药、造纸这些都需要"
--   6 大类 × 每类 20~30 条，从春秋战国一路铺到两宋；
--   每类 = 1 根 + 两条脉络（各 10 级，跨时代由浅入深）；纯正面效果。
--
--   效果一律走**修正器管道**（Modifiers）——key 都是现成的（和事件/政策共用）：
--     goldIncome / foodIncome / popGrowth / recruit / militaryPower /
--     defensePower / diploImprove（flat）/ stabilityDelta（flat）
--
--   名字/条目/数值全部可改；加条目零成本（表里加一行 + PREREQ 里接一条线）。
-- ============================================================================

local Techs = {}

--- 系统显示名（2026-09-16 用户拍板：叫「研究」，不叫科技）
Techs.NAME = "研究"

--- 六大类（顺序 = 面板按钮顺序）
Techs.CATEGORIES = {
    { id = "wealth",  label = "财富", icon = "💰" },
    { id = "people",  label = "民生", icon = "🌾" },
    { id = "war",     label = "武备", icon = "⚔️" },
    { id = "culture", label = "文治", icon = "📚" },
    { id = "system",  label = "制度", icon = "⚖️" },
    { id = "craft",   label = "技艺", icon = "🏗" },
}

--- 条目：{ id, cat, name, months, cost, desc, effects }
---   months = 研究月数；cost = 开始研究时花费的金钱
---   effects = { { key="goldIncome", op="mul", value=0.10 }, ... }
Techs.list_ = {
    -- ═══════════════════════ 💰 财富 ═══════════════════════
    -- 货币线
    { id = "barter",     cat = "wealth", name = "布币刀币", months = 4,  cost = 30,
      desc = "布刀行市，货殖相通", effects = { { key = "goldIncome", op = "mul", value = 0.05 } } },
    { id = "market",     cat = "wealth", name = "市集",     months = 6,  cost = 50,
      desc = "聚商成市，百货流转", effects = { { key = "goldIncome", op = "mul", value = 0.06 } } },
    { id = "shellcoin",  cat = "wealth", name = "半两钱",     months = 7,  cost = 60,
      desc = "秦并天下，币归一统", effects = { { key = "goldIncome", op = "mul", value = 0.06 } } },
    { id = "coining",    cat = "wealth", name = "铸币",     months = 9,  cost = 90,
      desc = "铸金为币，货殖通行", effects = { { key = "goldIncome", op = "mul", value = 0.08 } } },
    { id = "wuzhu",      cat = "wealth", name = "五铢钱",   months = 11, cost = 120,
      desc = "轻重得宜，钱法一统", effects = { { key = "goldIncome", op = "mul", value = 0.08 } } },
    { id = "kaiyuan",    cat = "wealth", name = "开元通宝", months = 13, cost = 150,
      desc = "钱文规范，通宝之始", effects = { { key = "goldIncome", op = "mul", value = 0.08 } } },
    { id = "jiaozi",     cat = "wealth", name = "交子",     months = 15, cost = 190,
      desc = "纸币轻赍，天下便之", effects = { { key = "goldIncome", op = "mul", value = 0.10 } } },
    { id = "measures",   cat = "wealth", name = "度量衡",   months = 6,  cost = 50,
      desc = "统一计量，商贾无欺",
      effects = { { key = "goldIncome", op = "mul", value = 0.05 }, { key = "diploImprove", op = "flat", value = 1 } } },
    { id = "customs",    cat = "wealth", name = "关市之征", months = 9,  cost = 80,
      desc = "设关收税，聚财于国", effects = { { key = "goldIncome", op = "mul", value = 0.07 } } },
    { id = "credit",     cat = "wealth", name = "借贷",     months = 10, cost = 100,
      desc = "贷本生息，周转生金", effects = { { key = "goldIncome", op = "mul", value = 0.08 } } },
    { id = "traderoute", cat = "wealth", name = "商路",     months = 12, cost = 130,
      desc = "通商于远，货通四海", effects = { { key = "goldIncome", op = "mul", value = 0.09 } } },
    { id = "silkroad",   cat = "wealth", name = "丝路",     months = 14, cost = 170,
      desc = "驼铃西去，锦缎东来", effects = { { key = "goldIncome", op = "mul", value = 0.10 } } },
    { id = "shibosi",    cat = "wealth", name = "市舶司",   months = 15, cost = 200,
      desc = "海舶云集，抽解抽买",
      effects = { { key = "goldIncome", op = "mul", value = 0.10 }, { key = "diploImprove", op = "flat", value = 1 } } },
    { id = "junsu",      cat = "wealth", name = "均输",     months = 8,  cost = 70,
      desc = "均输平准，输粟四方", effects = { { key = "goldIncome", op = "mul", value = 0.06 } } },
    { id = "pingzhun",   cat = "wealth", name = "平准",     months = 10, cost = 100,
      desc = "贵卖贱买，平抑物价",
      effects = { { key = "goldIncome", op = "mul", value = 0.07 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "quecha",     cat = "wealth", name = "榷茶",     months = 12, cost = 130,
      desc = "茶利归官，岁入巨万", effects = { { key = "goldIncome", op = "mul", value = 0.08 } } },
    { id = "shiyifa",    cat = "wealth", name = "市易法",   months = 13, cost = 160,
      desc = "平价收购，贷以生息", effects = { { key = "goldIncome", op = "mul", value = 0.08 } } },
    { id = "juntian",    cat = "wealth", name = "均田制",   months = 14, cost = 180,
      desc = "计口授田，耕者有其田",
      effects = { { key = "goldIncome", op = "mul", value = 0.08 }, { key = "foodIncome", op = "mul", value = 0.05 } } },
    { id = "fangtian",   cat = "wealth", name = "方田均税", months = 15, cost = 200,
      desc = "丈量田亩，均定税赋", effects = { { key = "goldIncome", op = "mul", value = 0.09 } } },
    { id = "duzhi",      cat = "wealth", name = "度支",     months = 20, cost = 360,
      desc = "量入为出，国用有经",
      effects = { { key = "goldIncome", op = "mul", value = 0.14 }, { key = "stabilityDelta", op = "flat", value = 1 } } },

    -- ═══════════════════════ 🌾 民生 ═══════════════════════
    -- 耕作线
    { id = "slashburn",  cat = "people", name = "畎亩法", months = 4,  cost = 30,
      desc = "畎亩相间，旱涝有备", effects = { { key = "foodIncome", op = "mul", value = 0.05 } } },
    { id = "rotation",   cat = "people", name = "轮作",     months = 6,  cost = 50,
      desc = "休耕轮种，地力不衰", effects = { { key = "foodIncome", op = "mul", value = 0.06 } } },
    { id = "irrigation", cat = "people", name = "水利",     months = 8,  cost = 70,
      desc = "沟渠纵横，旱涝有备",
      effects = { { key = "foodIncome", op = "mul", value = 0.08 }, { key = "popGrowth", op = "mul", value = 0.05 } } },
    { id = "oxplow",     cat = "people", name = "牛耕",     months = 8,  cost = 80,
      desc = "牵牛挽犁，倍于人力", effects = { { key = "foodIncome", op = "mul", value = 0.08 } } },
    { id = "daitian",    cat = "people", name = "代田法",   months = 11, cost = 120,
      desc = "畎亩相代，用力少而得谷多", effects = { { key = "foodIncome", op = "mul", value = 0.09 } } },
    { id = "quyuanli",   cat = "people", name = "曲辕犁",   months = 13, cost = 150,
      desc = "犁评可调，深浅自如", effects = { { key = "foodIncome", op = "mul", value = 0.10 } } },
    { id = "champa",     cat = "people", name = "占城稻",   months = 14, cost = 180,
      desc = "耐旱早熟，一岁两熟",
      effects = { { key = "foodIncome", op = "mul", value = 0.10 }, { key = "popGrowth", op = "mul", value = 0.05 } } },
    { id = "terrace",    cat = "people", name = "梯田",     months = 15, cost = 200,
      desc = "层层而上，尽山之力", effects = { { key = "foodIncome", op = "mul", value = 0.10 } } },
    { id = "doublecrop", cat = "people", name = "双季稻",   months = 17, cost = 250,
      desc = "一年两熟，仓廪倍实",
      effects = { { key = "foodIncome", op = "mul", value = 0.12 }, { key = "popGrowth", op = "mul", value = 0.05 } } },
    { id = "garrisonfarm", cat = "people", name = "屯田",   months = 9,  cost = 70,
      desc = "且耕且守，兵食自足", effects = { { key = "foodIncome", op = "mul", value = 0.07 } } },
    { id = "encouragefarm", cat = "people", name = "劝农",  months = 10, cost = 90,
      desc = "劝课农桑，民勤于本",
      effects = { { key = "foodIncome", op = "mul", value = 0.07 }, { key = "popGrowth", op = "mul", value = 0.05 } } },
    { id = "granary",    cat = "people", name = "粮仓",     months = 12, cost = 120,
      desc = "积谷防饥，岁有常储", effects = { { key = "foodIncome", op = "mul", value = 0.08 } } },
    { id = "canal",      cat = "people", name = "漕运",     months = 13, cost = 150,
      desc = "转粟千里，舟楫相望", effects = { { key = "foodIncome", op = "mul", value = 0.09 } } },
    { id = "weitian",    cat = "people", name = "圩田",     months = 14, cost = 180,
      desc = "筑堤围田，化泽为壤", effects = { { key = "foodIncome", op = "mul", value = 0.09 } } },
    { id = "changping",  cat = "people", name = "常平仓",   months = 15, cost = 200,
      desc = "谷贱籴之，谷贵粜之",
      effects = { { key = "foodIncome", op = "mul", value = 0.09 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "locust",     cat = "people", name = "治蝗",     months = 16, cost = 220,
      desc = "捕蝻除蝗，保我禾稼", effects = { { key = "foodIncome", op = "mul", value = 0.10 } } },
    { id = "reclaim",    cat = "people", name = "垦荒令",   months = 18, cost = 280,
      desc = "招民垦荒，永不起科", effects = { { key = "foodIncome", op = "mul", value = 0.12 } } },
    { id = "storage",    cat = "people", name = "仓储之制", months = 20, cost = 340,
      desc = "社仓义仓，荒年有恃",
      effects = { { key = "foodIncome", op = "mul", value = 0.14 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    -- 水利工程线（第三条：大工程）
    { id = "gouxu",      cat = "people", name = "沟洫",     months = 8,  cost = 70,
      desc = "田间水道，旱涝有备", effects = { { key = "foodIncome", op = "mul", value = 0.06 } } },
    { id = "dujiangyan", cat = "people", name = "都江堰",   months = 11, cost = 110,
      desc = "分水鱼嘴，沃野千里",
      effects = { { key = "foodIncome", op = "mul", value = 0.08 }, { key = "popGrowth", op = "mul", value = 0.04 } } },
    { id = "zhengguoqu", cat = "people", name = "郑国渠",   months = 12, cost = 130,
      desc = "引泾注洛，泽卤之地成沃野", effects = { { key = "foodIncome", op = "mul", value = 0.08 } } },
    { id = "lingqu",     cat = "people", name = "灵渠",     months = 13, cost = 160,
      desc = "凿渠通湘漓，舟楫贯南北", effects = { { key = "foodIncome", op = "mul", value = 0.08 } } },
    { id = "kanerjing",  cat = "people", name = "坎儿井",   months = 14, cost = 180,
      desc = "暗渠引雪水，沙碛生绿洲", effects = { { key = "foodIncome", op = "mul", value = 0.09 } } },
    { id = "grandcanal", cat = "people", name = "大运河",   months = 15, cost = 210,
      desc = "南北通漕，天下转输",
      effects = { { key = "foodIncome", op = "mul", value = 0.10 }, { key = "goldIncome", op = "mul", value = 0.05 } } },
    { id = "seawall",    cat = "people", name = "海塘",     months = 16, cost = 230,
      desc = "石塘御潮，滨海安堵", effects = { { key = "foodIncome", op = "mul", value = 0.09 } } },
    { id = "pond",       cat = "people", name = "陂塘",     months = 17, cost = 250,
      desc = "蓄水为塘，溉田灌园", effects = { { key = "foodIncome", op = "mul", value = 0.10 } } },
    { id = "wellirrig",  cat = "people", name = "井灌",     months = 18, cost = 270,
      desc = "凿井取水，高原可耕", effects = { { key = "foodIncome", op = "mul", value = 0.10 } } },
    { id = "rivercontrol", cat = "people", name = "治黄",   months = 20, cost = 360,
      desc = "束水攻沙，河定民安",
      effects = { { key = "foodIncome", op = "mul", value = 0.13 }, { key = "stabilityDelta", op = "flat", value = 2 } } },

    -- ═══════════════════════ ⚔️ 武备 ═══════════════════════
    -- 兵器线
    { id = "stonearms",  cat = "war", name = "戈矛", months = 4,  cost = 30,
      desc = "戈矛相济，以卫社稷", effects = { { key = "militaryPower", op = "mul", value = 0.05 } } },
    { id = "bow",        cat = "war", name = "弓矢",     months = 6,  cost = 50,
      desc = "弦木为弧，剡木为矢", effects = { { key = "militaryPower", op = "mul", value = 0.06 } } },
    { id = "bronze",     cat = "war", name = "青铜兵",   months = 8,  cost = 70,
      desc = "范金合土，铸为利器", effects = { { key = "militaryPower", op = "mul", value = 0.07 } } },
    { id = "ironarms",   cat = "war", name = "铁兵器",   months = 10, cost = 100,
      desc = "铁锐于铜，锋不可当", effects = { { key = "militaryPower", op = "mul", value = 0.09 } } },
    { id = "stirrup",    cat = "war", name = "马镫",     months = 12, cost = 130,
      desc = "铁镫既成，骑战无敌", effects = { { key = "militaryPower", op = "mul", value = 0.10 } } },
    { id = "gunpowder",  cat = "war", name = "火药",     months = 14, cost = 170,
      desc = "硝石硫磺，一触即发", effects = { { key = "militaryPower", op = "mul", value = 0.12 } } },
    { id = "tuhuoqiang", cat = "war", name = "突火枪",   months = 15, cost = 200,
      desc = "竹管喷射，声如霹雳", effects = { { key = "militaryPower", op = "mul", value = 0.12 } } },
    { id = "conscription", cat = "war", name = "征兵之制", months = 6, cost = 50,
      desc = "籍民为兵，农隙讲武", effects = { { key = "recruit", op = "mul", value = 0.08 } } },
    { id = "chariot",    cat = "war", name = "战车",     months = 9,  cost = 90,
      desc = "千乘之国，驰骋疆场", effects = { { key = "militaryPower", op = "mul", value = 0.08 } } },
    { id = "cavalry",    cat = "war", name = "骑兵",     months = 11, cost = 120,
      desc = "胡服骑射，来去如风", effects = { { key = "militaryPower", op = "mul", value = 0.09 } } },
    { id = "drill",      cat = "war", name = "训练之法", months = 12, cost = 140,
      desc = "教之以阵法，齐之以号令",
      effects = { { key = "militaryPower", op = "mul", value = 0.09 }, { key = "recruit", op = "mul", value = 0.05 } } },
    { id = "fubing",     cat = "war", name = "府兵制",   months = 14, cost = 170,
      desc = "寓兵于农，兵农合一", effects = { { key = "recruit", op = "mul", value = 0.10 } } },
    { id = "mubing",     cat = "war", name = "募兵制",   months = 15, cost = 200,
      desc = "募民为兵，职业常备",
      effects = { { key = "militaryPower", op = "mul", value = 0.10 }, { key = "recruit", op = "mul", value = 0.05 } } },
    { id = "imperialguard", cat = "war", name = "禁军",  months = 16, cost = 230,
      desc = "精锐拱卫，京师重兵", effects = { { key = "defensePower", op = "mul", value = 0.12 } } },
    { id = "sima",       cat = "war", name = "司马法",   months = 9,  cost = 80,
      desc = "以战止战，虽战可也", effects = { { key = "militaryPower", op = "mul", value = 0.06 } } },
    { id = "sunzi",      cat = "war", name = "孙子兵法", months = 11, cost = 110,
      desc = "兵者，诡道也",
      effects = { { key = "militaryPower", op = "mul", value = 0.08 }, { key = "defensePower", op = "mul", value = 0.04 } } },
    { id = "wuzi",       cat = "war", name = "吴子",     months = 12, cost = 130,
      desc = "内修文德，外治武备", effects = { { key = "militaryPower", op = "mul", value = 0.07 } } },
    { id = "sunbin",     cat = "war", name = "孙膑兵法", months = 13, cost = 150,
      desc = "围魏救赵，批亢捣虚", effects = { { key = "militaryPower", op = "mul", value = 0.08 } } },
    { id = "liutao",     cat = "war", name = "六韬",     months = 14, cost = 170,
      desc = "文韬武略，谋定后动",
      effects = { { key = "militaryPower", op = "mul", value = 0.09 }, { key = "diploImprove", op = "flat", value = 1 } } },
    { id = "weiliaozi",  cat = "war", name = "尉缭子",   months = 15, cost = 190,
      desc = "号令严明，赏罚必信", effects = { { key = "militaryPower", op = "mul", value = 0.09 } } },
    { id = "sanlue",     cat = "war", name = "三略",     months = 16, cost = 210,
      desc = "上略柔远，中略御将", effects = { { key = "defensePower", op = "mul", value = 0.10 } } },
    { id = "weigong",    cat = "war", name = "李卫公问对", months = 17, cost = 240,
      desc = "奇正相生，变化无穷", effects = { { key = "militaryPower", op = "mul", value = 0.11 } } },
    { id = "wujing",     cat = "war", name = "武经总要", months = 18, cost = 280,
      desc = "军器图籍，攻守有法",
      effects = { { key = "militaryPower", op = "mul", value = 0.12 }, { key = "defensePower", op = "mul", value = 0.05 } } },
    { id = "knots",      cat = "culture", name = "简牍", months = 4,  cost = 30,
      desc = "削竹为简，书于方策", effects = { { key = "popGrowth", op = "mul", value = 0.05 } } },
    { id = "writing",    cat = "culture", name = "小篆",     months = 6,  cost = 50,
      desc = "书同文字，笔法归一",
      effects = { { key = "stabilityDelta", op = "flat", value = 1 }, { key = "popGrowth", op = "mul", value = 0.05 } } },
    { id = "oracle",     cat = "culture", name = "盟书",     months = 8,  cost = 70,
      desc = "歃血为盟，载书于策", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "bronzein",   cat = "culture", name = "金文",     months = 9,  cost = 90,
      desc = "铸鼎铭功，传于后世", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "philosophers", cat = "culture", name = "诸子",   months = 11, cost = 120,
      desc = "百家之说，争鸣于世",
      effects = { { key = "popGrowth", op = "mul", value = 0.08 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "taixue",     cat = "culture", name = "太学",     months = 13, cost = 150,
      desc = "设太学，置五经博士", effects = { { key = "popGrowth", op = "mul", value = 0.08 } } },
    { id = "keju",       cat = "culture", name = "科举",     months = 15, cost = 190,
      desc = "分科取士，寒门可进",
      effects = { { key = "popGrowth", op = "mul", value = 0.10 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "academy",    cat = "culture", name = "书院",     months = 16, cost = 220,
      desc = "讲学授徒，学风蔚然", effects = { { key = "popGrowth", op = "mul", value = 0.10 } } },
    { id = "neo_conf",   cat = "culture", name = "理学",     months = 17, cost = 260,
      desc = "格物致知，存理去欲", effects = { { key = "stabilityDelta", op = "flat", value = 2 } } },
    { id = "leishu",     cat = "culture", name = "类书",     months = 20, cost = 340,
      desc = "永乐大典，集古之大成",
      effects = { { key = "popGrowth", op = "mul", value = 0.12 }, { key = "stabilityDelta", op = "flat", value = 2 } } },
    -- 传承线
    { id = "rites",      cat = "culture", name = "礼乐",     months = 6,  cost = 50,
      desc = "礼别尊卑，乐和上下", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "schools",    cat = "culture", name = "庠序",     months = 8,  cost = 70,
      desc = "设为庠序，教以人伦", effects = { { key = "popGrowth", op = "mul", value = 0.06 } } },
    { id = "historians", cat = "culture", name = "史官",     months = 10, cost = 100,
      desc = "君举必书，以昭鉴戒",
      effects = { { key = "goldIncome", op = "mul", value = 0.04 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "lishu",      cat = "culture", name = "隶书",     months = 11, cost = 120,
      desc = "化圆为方，书写便捷", effects = { { key = "popGrowth", op = "mul", value = 0.06 } } },
    { id = "paper",      cat = "culture", name = "造纸",     months = 13, cost = 150,
      desc = "蔡侯纸成，天下便之", effects = { { key = "popGrowth", op = "mul", value = 0.08 } } },
    { id = "woodblock",  cat = "culture", name = "雕版印刷", months = 15, cost = 190,
      desc = "镂版印书，化身千百",
      effects = { { key = "popGrowth", op = "mul", value = 0.10 }, { key = "goldIncome", op = "mul", value = 0.04 } } },
    { id = "movable",    cat = "culture", name = "活字印刷", months = 16, cost = 220,
      desc = "胶泥活字，排印如飞",
      effects = { { key = "popGrowth", op = "mul", value = 0.10 }, { key = "goldIncome", op = "mul", value = 0.05 } } },
    { id = "library",    cat = "culture", name = "藏书",     months = 17, cost = 250,
      desc = "藏之名山，传之后世", effects = { { key = "popGrowth", op = "mul", value = 0.10 } } },
    { id = "bushi",      cat = "culture", name = "卜筮",     months = 8,  cost = 70,
      desc = "灼龟观兆，以决大事", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "shijing",    cat = "culture", name = "诗经",     months = 10, cost = 100,
      desc = "诗三百，思无邪", effects = { { key = "popGrowth", op = "mul", value = 0.06 } } },
    { id = "chunqiu",    cat = "culture", name = "春秋",     months = 11, cost = 120,
      desc = "微言大义，一字褒贬",
      effects = { { key = "stabilityDelta", op = "flat", value = 1 }, { key = "popGrowth", op = "mul", value = 0.05 } } },
    { id = "shiji",      cat = "culture", name = "史记",     months = 13, cost = 150,
      desc = "究天人之际，通古今之变", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "hanshu",     cat = "culture", name = "汉书",     months = 14, cost = 180,
      desc = "断代为史，包举一代", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "shuowen",    cat = "culture", name = "说文解字", months = 15, cost = 200,
      desc = "据形系联，部首统字", effects = { { key = "popGrowth", op = "mul", value = 0.07 } } },
    { id = "zhaoming",   cat = "culture", name = "昭明文选", months = 16, cost = 220,
      desc = "事出于沉思，义归乎翰藻", effects = { { key = "goldIncome", op = "mul", value = 0.05 } } },
    { id = "zizhitongjian", cat = "culture", name = "资治通鉴", months = 17, cost = 260,
      desc = "鉴于往事，有资于治道",
      effects = { { key = "stabilityDelta", op = "flat", value = 2 }, { key = "goldIncome", op = "mul", value = 0.05 } } },
    { id = "squads",     cat = "system", name = "什伍之制", months = 4,  cost = 30,
      desc = "五家为伍，十家为什", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "census",     cat = "system", name = "户籍",     months = 6,  cost = 50,
      desc = "编户齐民，籍载丁口",
      effects = { { key = "goldIncome", op = "mul", value = 0.04 }, { key = "recruit", op = "mul", value = 0.04 } } },
    { id = "bureaucracy", cat = "system", name = "官制",    months = 8,  cost = 70,
      desc = "设官分职，各司其守",
      effects = { { key = "goldIncome", op = "mul", value = 0.05 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "lawcode",    cat = "system", name = "律法",     months = 10, cost = 100,
      desc = "刑书铸鼎，民知所避", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "counties",   cat = "system", name = "郡县",     months = 12, cost = 130,
      desc = "废封建，置郡县",
      effects = { { key = "goldIncome", op = "mul", value = 0.07 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "sangong",    cat = "system", name = "三公九卿", months = 14, cost = 170,
      desc = "丞相总百官，九卿分职守",
      effects = { { key = "goldIncome", op = "mul", value = 0.08 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "sansheng",   cat = "system", name = "三省六部", months = 15, cost = 200,
      desc = "中书决策，门下审议，尚书执行",
      effects = { { key = "goldIncome", op = "mul", value = 0.09 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "grandcouncil", cat = "system", name = "勤政",     months = 18, cost = 280,
      desc = "政务通达，上下无壅",
      effects = { { key = "stabilityDelta", op = "flat", value = 2 }, { key = "goldIncome", op = "mul", value = 0.06 } } },
    { id = "reform",     cat = "system", name = "变法图强", months = 20, cost = 360,
      desc = "苟利于民，不必法古",
      effects = { { key = "goldIncome", op = "mul", value = 0.10 }, { key = "militaryPower", op = "mul", value = 0.10 },
                  { key = "stabilityDelta", op = "flat", value = 2 } } },
    -- 专项线
    { id = "armysystem", cat = "system", name = "军制",     months = 7,  cost = 60,
      desc = "寓兵于农，军政合一",
      effects = { { key = "recruit", op = "mul", value = 0.07 }, { key = "militaryPower", op = "mul", value = 0.04 } } },
    { id = "qimin",      cat = "system", name = "编户齐民", months = 10, cost = 100,
      desc = "按户编籍，齐民一视",
      effects = { { key = "goldIncome", op = "mul", value = 0.05 }, { key = "recruit", op = "mul", value = 0.05 } } },
    { id = "chaju",      cat = "system", name = "察举制",   months = 12, cost = 130,
      desc = "乡举里选，察孝廉", effects = { { key = "popGrowth", op = "mul", value = 0.06 } } },
    { id = "jiupin",     cat = "system", name = "考课",     months = 13, cost = 150,
      desc = "考绩黜陟，以功次迁",
      effects = { { key = "stabilityDelta", op = "flat", value = 1 }, { key = "goldIncome", op = "mul", value = 0.05 } } },
    { id = "kejuzhi",    cat = "system", name = "科举制",   months = 15, cost = 190,
      desc = "考试取士，择优而仕",
      effects = { { key = "popGrowth", op = "mul", value = 0.08 }, { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "liangshui",  cat = "system", name = "两税法",   months = 16, cost = 220,
      desc = "夏秋两征，简化税制", effects = { { key = "goldIncome", op = "mul", value = 0.09 } } },
    { id = "zuyongdiao", cat = "system", name = "租庸调",   months = 17, cost = 250,
      desc = "租调之外，庸可代役",
      effects = { { key = "goldIncome", op = "mul", value = 0.08 }, { key = "foodIncome", op = "mul", value = 0.04 } } },
    { id = "baojia",     cat = "system", name = "乡约",     months = 18, cost = 280,
      desc = "乡里自治，守望相助", effects = { { key = "stabilityDelta", op = "flat", value = 2 } } },
    { id = "censors",    cat = "system", name = "监察",     months = 19, cost = 300,
      desc = "纠察百官，绳愆纠谬", effects = { { key = "stabilityDelta", op = "flat", value = 2 } } },
    { id = "posts",      cat = "system", name = "驿传",     months = 20, cost = 340,
      desc = "置驿设亭，通达四方",
      effects = { { key = "diploImprove", op = "flat", value = 2 }, { key = "goldIncome", op = "mul", value = 0.05 } } },
    -- 地方治理线（第三条：乡治）
    { id = "xiangsui",   cat = "system", name = "乡遂",     months = 8,  cost = 70,
      desc = "乡遂分治，比闾相保", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "fengbang",   cat = "system", name = "封邦建国", months = 10, cost = 100,
      desc = "封建亲戚，以藩屏周",
      effects = { { key = "stabilityDelta", op = "flat", value = 1 }, { key = "recruit", op = "mul", value = 0.05 } } },
    { id = "junguo",     cat = "system", name = "郡国并行", months = 12, cost = 130,
      desc = "郡县与封国并置", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "lishe",      cat = "system", name = "里社",     months = 16, cost = 210,
      desc = "里中设社，春秋祈报", effects = { { key = "stabilityDelta", op = "flat", value = 1 } } },
    { id = "shexue",     cat = "system", name = "社学",     months = 17, cost = 240,
      desc = "乡社立学，蒙童受教", effects = { { key = "popGrowth", op = "mul", value = 0.08 } } },
    { id = "xiangyin",   cat = "system", name = "乡饮",     months = 18, cost = 270,
      desc = "乡饮酒礼，序齿尚德", effects = { { key = "stabilityDelta", op = "flat", value = 2 } } },
    { id = "yizhuang",   cat = "system", name = "义庄",     months = 19, cost = 310,
      desc = "赡族济贫，义田常存",
      effects = { { key = "stabilityDelta", op = "flat", value = 1 }, { key = "foodIncome", op = "mul", value = 0.04 } } },
    { id = "shantang",   cat = "system", name = "善堂",     months = 20, cost = 360,
      desc = "育婴养老，善政在民",
      effects = { { key = "popGrowth", op = "mul", value = 0.10 }, { key = "stabilityDelta", op = "flat", value = 2 } } },

    -- ═══════════════════════ 🏗 技艺 ═══════════════════════
    -- 材料线
    { id = "stonecraft", cat = "craft", name = "玉雕",     months = 4,  cost = 30,
      desc = "琢玉成器，君子比德", effects = { { key = "foodIncome", op = "mul", value = 0.05 } } },
    { id = "pottery",    cat = "craft", name = "硬陶",     months = 6,  cost = 50,
      desc = "印纹硬陶，坚致耐用", effects = { { key = "goldIncome", op = "mul", value = 0.05 } } },
    { id = "bronzecast", cat = "craft", name = "失蜡法", months = 9,  cost = 80,
      desc = "蜡模熔铸，纤毫毕现", effects = { { key = "goldIncome", op = "mul", value = 0.06 } } },
    { id = "weaving",    cat = "craft", name = "纺织",     months = 10, cost = 100,
      desc = "纺纱织布，衣被天下", effects = { { key = "goldIncome", op = "mul", value = 0.06 } } },
    { id = "lacquer",    cat = "craft", name = "漆器",     months = 11, cost = 120,
      desc = "髹漆为饰，器美价昂", effects = { { key = "goldIncome", op = "mul", value = 0.07 } } },
    { id = "porcelain",  cat = "craft", name = "瓷器",     months = 13, cost = 150,
      desc = "瓷土入窑，如玉如冰", effects = { { key = "goldIncome", op = "mul", value = 0.08 } } },
    { id = "xuanpaper",  cat = "craft", name = "宣纸",     months = 14, cost = 180,
      desc = "泾县纸贵，宜书宜画", effects = { { key = "goldIncome", op = "mul", value = 0.08 } } },
    { id = "sunmao",     cat = "craft", name = "榫卯",     months = 15, cost = 200,
      desc = "不用钉胶，天衣无缝", effects = { { key = "goldIncome", op = "mul", value = 0.08 } } },
    { id = "glass",      cat = "craft", name = "玻璃",     months = 17, cost = 250,
      desc = "琉璃透明，器用日广", effects = { { key = "goldIncome", op = "mul", value = 0.10 } } },
    { id = "construction", cat = "craft", name = "营造",   months = 7,  cost = 60,
      desc = "版筑夯土，筑城浚池",
      effects = { { key = "stabilityDelta", op = "flat", value = 1 }, { key = "foodIncome", op = "mul", value = 0.04 } } },
    { id = "metallurgy", cat = "craft", name = "冶金",     months = 10, cost = 100,
      desc = "鼓风橐龠，铸铁为器",
      effects = { { key = "militaryPower", op = "mul", value = 0.07 }, { key = "foodIncome", op = "mul", value = 0.04 } } },
    { id = "compass",    cat = "craft", name = "指南针",   months = 12, cost = 130,
      desc = "司南定向，不迷于途",
      effects = { { key = "goldIncome", op = "mul", value = 0.06 }, { key = "diploImprove", op = "flat", value = 1 } } },
    { id = "waterwheel", cat = "craft", name = "水车",     months = 13, cost = 150,
      desc = "引水灌田，不劳人力", effects = { { key = "foodIncome", op = "mul", value = 0.08 } } },
    { id = "shipbuilding", cat = "craft", name = "造船",   months = 14, cost = 180,
      desc = "刳木为舟，剡木为楫",
      effects = { { key = "goldIncome", op = "mul", value = 0.07 }, { key = "foodIncome", op = "mul", value = 0.04 } } },
    { id = "gunpowdercraft", cat = "craft", name = "火药术", months = 15, cost = 200,
      desc = "炼硝提纯，药性猛烈", effects = { { key = "militaryPower", op = "mul", value = 0.10 } } },
    { id = "printingcraft", cat = "craft", name = "印刷术", months = 16, cost = 230,
      desc = "雕版活字，典籍流布",
      effects = { { key = "goldIncome", op = "mul", value = 0.06 }, { key = "popGrowth", op = "mul", value = 0.06 } } },
    { id = "hydraulics", cat = "craft", name = "水工",     months = 17, cost = 260,
      desc = "决渠引水，变泽为田",
      effects = { { key = "foodIncome", op = "mul", value = 0.10 }, { key = "popGrowth", op = "mul", value = 0.05 } } },
    { id = "surveying",  cat = "craft", name = "测绘",     months = 18, cost = 280,
      desc = "丈天量地，图籍可考",
      effects = { { key = "goldIncome", op = "mul", value = 0.06 }, { key = "diploImprove", op = "flat", value = 1 } } },
    { id = "armillary",  cat = "craft", name = "浑仪",     months = 20, cost = 340,
      desc = "观星测影，以授农时",
      effects = { { key = "foodIncome", op = "mul", value = 0.08 }, { key = "popGrowth", op = "mul", value = 0.08 } } },
    -- 天文历法线（第三条：观天授时）
    { id = "guanxiang",  cat = "craft", name = "观象授时", months = 8,  cost = 70,
      desc = "观日月星辰，定农事之节", effects = { { key = "foodIncome", op = "mul", value = 0.05 } } },
    { id = "ershibaxiu", cat = "craft", name = "二十八宿", months = 10, cost = 100,
      desc = "分天为宿，以纪日月",
      effects = { { key = "foodIncome", op = "mul", value = 0.05 }, { key = "popGrowth", op = "mul", value = 0.03 } } },
    { id = "jieqi",      cat = "craft", name = "二十四节气", months = 11, cost = 120,
      desc = "顺天应时，不违农候",
      effects = { { key = "foodIncome", op = "mul", value = 0.07 }, { key = "popGrowth", op = "mul", value = 0.04 } } },
    { id = "taichuli",   cat = "craft", name = "太初历",   months = 13, cost = 150,
      desc = "以正月为岁首，历法一新", effects = { { key = "foodIncome", op = "mul", value = 0.07 } } },
    { id = "damingli",   cat = "craft", name = "大明历",   months = 14, cost = 180,
      desc = "岁差入历，推步益精", effects = { { key = "foodIncome", op = "mul", value = 0.07 } } },
    { id = "dayanli",    cat = "craft", name = "大衍历",   months = 15, cost = 200,
      desc = "九执历术，测算精微",
      effects = { { key = "foodIncome", op = "mul", value = 0.08 }, { key = "popGrowth", op = "mul", value = 0.04 } } },
    { id = "yixiangtai", cat = "craft", name = "水运仪象台", months = 17, cost = 260,
      desc = "以水激轮，报时观星", effects = { { key = "goldIncome", op = "mul", value = 0.05 } } },
}

-- ---------------------------------------------------------------------------
-- 前置关系（**跨朝代**的两条脉络；每类 = 1 根 + 两条 10 级链）
--   财富：货币线（布币→…→交子）／商贸线（度量衡→…→市舶司）／财政线（均输→…→度支）
--   民生：耕作线（畎亩法→…→双季稻）／组织线（屯田→…→仓储之制）／水利线（沟洫→…→治黄）
--   武备：兵器线（戈矛→弓矢→青铜→铁兵→马镫→火药→突火枪）
--         军制线（征兵→战车→骑兵→训练→府兵→募兵→禁军）／兵书线（司马法→…→武经总要）
--   文治：思想线（简牍→小篆→盟书→金文→诸子→太学→科举→书院→理学→类书）
--         传承线（礼乐→庠序→史官→隶书→**造纸→雕版印刷→活字印刷**→藏书）／典籍线（卜筮→…→资治通鉴）
--   制度：行政线（什伍→户籍→官制→律法→郡县→三公九卿→三省六部→勤政→变法）
--         专项线（军制→编户齐民→察举→九品中正→科举制→两税法→租庸调→保甲→监察→驿传）
--   技艺：材料线（玉雕→硬陶→失蜡法→纺织→漆器→瓷器→宣纸→榫卯→玻璃）
--         工程线（营造→冶金→**指南针**→水车→造船→**火药术→印刷术**→水工→测绘→浑仪）
--   （改这里的"父 id"即改树上连线/解锁关系）
-- ---------------------------------------------------------------------------
Techs.PREREQ = {
    -- ═══════════ 💰 财富 ═══════════
    -- 货币主线（布币刀币 → 市易法，8 层）
    market = "barter", shellcoin = "market", coining = "shellcoin", wuzhu = "coining",
    kaiyuan = "wuzhu", jiaozi = "kaiyuan", shiyifa = "jiaozi",
    -- 支线（串成长链挂主线不同层）
    measures = "barter", customs = "measures", credit = "customs",
    junsu = "barter", pingzhun = "junsu",
    traderoute = "pingzhun", silkroad = "traderoute",
    quecha = "pingzhun", duzhi = "quecha",
    juntian = "quecha", fangtian = "juntian",
    shibosi = "jiaozi",

    -- ═══════════ 🌾 民生 ═══════════
    -- 耕作主线（畎亩法 → 双季稻，6 层）
    rotation = "slashburn", oxplow = "rotation", daitian = "oxplow",
    quyuanli = "daitian", champa = "quyuanli", doublecrop = "champa",
    -- 水利线（挂根，长链）
    gouxu = "slashburn", dujiangyan = "gouxu", zhengguoqu = "dujiangyan",
    lingqu = "zhengguoqu", kanerjing = "lingqu", grandcanal = "kanerjing", rivercontrol = "grandcanal",
    -- 组织线（挂轮作）
    garrisonfarm = "rotation", encouragefarm = "garrisonfarm", granary = "encouragefarm",
    canal = "granary", changping = "canal", storage = "changping",
    -- 短支线（挂不同层）
    irrigation = "oxplow", weitian = "irrigation", seawall = "weitian",
    terrace = "champa", locust = "terrace", reclaim = "locust",
    pond = "zhengguoqu", wellirrig = "pond",

    -- ═══════════ ⚔️ 武备 ═══════════
    -- 兵器主线（戈矛 → 突火枪，6 层）
    bow = "stonearms", bronze = "bow", ironarms = "bronze", stirrup = "ironarms",
    gunpowder = "stirrup", tuhuoqiang = "gunpowder",
    -- 军制线（挂根，长链）
    conscription = "stonearms", chariot = "conscription", cavalry = "chariot",
    drill = "cavalry", fubing = "drill", mubing = "fubing", imperialguard = "mubing",
    -- 兵书线（分段挂主线不同层）
    sima = "stonearms", sunzi = "sima", wuzi = "sunzi",
    sunbin = "bronze", liutao = "sunbin", weiliaozi = "liutao",
    sanlue = "ironarms", weigong = "sanlue", wujing = "weigong",

    -- ═══════════ 📚 文治 ═══════════
    -- 思想主线（简牍 → 类书，9 层）
    writing = "knots", oracle = "writing", bronzein = "oracle", philosophers = "bronzein",
    taixue = "philosophers", keju = "taixue", academy = "keju", neo_conf = "academy", leishu = "neo_conf",
    -- 传承线（挂根）
    rites = "knots", schools = "rites", historians = "schools", lishu = "historians",
    -- 典籍线（挂根）
    bushi = "knots", shijing = "bushi", chunqiu = "shijing", shiji = "chunqiu", hanshu = "shiji",
    -- 纸书线（挂诸子）
    paper = "philosophers", woodblock = "paper", movable = "woodblock", library = "movable",
    -- 史学支线（挂隶书）
    shuowen = "lishu", zhaoming = "shuowen", zizhitongjian = "zhaoming",

    -- ═══════════ ⚖️ 制度 ═══════════
    -- 行政主线（什伍 → 变法，8 层）
    census = "squads", bureaucracy = "census", lawcode = "bureaucracy", counties = "lawcode",
    sangong = "counties", sansheng = "sangong", grandcouncil = "sansheng", reform = "grandcouncil",
    -- 专项线（挂根，长链）
    armysystem = "squads", qimin = "armysystem", chaju = "qimin", jiupin = "chaju",
    kejuzhi = "jiupin", liangshui = "kejuzhi", zuyongdiao = "liangshui",
    baojia = "zuyongdiao", censors = "baojia", posts = "censors",
    -- 地方线（挂郡县）
    xiangsui = "squads", fengbang = "xiangsui", junguo = "fengbang",
    lishe = "counties", shexue = "lishe", xiangyin = "shexue", yizhuang = "xiangyin", shantang = "yizhuang",

    -- ═══════════ 🏗 技艺 ═══════════
    -- 材料主线（玉雕 → 玻璃，8 层）
    pottery = "stonecraft", bronzecast = "pottery", weaving = "bronzecast", lacquer = "weaving",
    porcelain = "lacquer", xuanpaper = "porcelain", sunmao = "xuanpaper", glass = "sunmao",
    -- 工程线（挂根，长链）
    construction = "stonecraft", metallurgy = "construction", compass = "metallurgy",
    waterwheel = "compass", shipbuilding = "waterwheel", gunpowdercraft = "shipbuilding",
    printingcraft = "gunpowdercraft", hydraulics = "printingcraft", surveying = "hydraulics",
    armillary = "surveying",
    -- 天文历法线（挂材料线中段）
    guanxiang = "porcelain", ershibaxiu = "guanxiang", jieqi = "ershibaxiu",
    taichuli = "jieqi", damingli = "taichuli", dayanli = "damingli", yixiangtai = "dayanli",
}


--- 某科技的前置 id（nil = 根）
---@param id string
---@return string|nil
function Techs.prereqIdOf(id)
    return Techs.PREREQ[id]
end

--- 按 id 取
---@param id string
---@return table|nil
function Techs.get(id)
    for _, t in ipairs(Techs.list_) do
        if t.id == id then return t end
    end
    return nil
end

--- 取某一类下的条目（保持表内顺序）
---@param catId string
---@return table[]
function Techs.byCategory(catId)
    local out = {}
    for _, t in ipairs(Techs.list_) do
        if t.cat == catId then out[#out + 1] = t end
    end
    return out
end

--- 全部条目
---@return table[]
function Techs.all()
    return Techs.list_
end

return Techs

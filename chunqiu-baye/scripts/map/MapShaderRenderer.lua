------------------------------------------------------------------------
-- MapShaderRenderer.lua — P 社式 GPU 逐像素地图渲染（3D 层）
--
-- 地图画面 = 3D 正交相机 + 全屏 quad + ParadoxMapV3.shader
--   shader 采样省 ID 位图(NEAREST) → 查 LUT(省ID→显示色)
--   → 4 邻比较「势力键」画边界（同势力不画）→ 海陆交界画海岸线
-- 世界坐标 = 逻辑坐标 / 1000（归一化，避开大 orthoSize 引擎异常）
-- UI（NanoVG）渲染在 3D 层之上（引擎默认叠加顺序）
--
-- ⚠️ 渲染要点（踩坑记录）：
--   * quad 绕 Y 转 180°：相机（朝 +Z）看到 Box 的本地 -Z 面，
--     旋转后其 u 轴与世界 +X 同向 → 地图不镜像，与标签/小地图一致
--   * 海色底 quad 必须用 depth_draw_never 的 SurfaceShader（与地图同
--     渲染队列），不透明技术会写深度盖住地图
--   * Zone.tonemapMode = NONE：关闭引擎默认 LUT 色调映射，否则地图
--     颜色被压成灰白、海陆不分
--   * V3 颜色空间（2026-08-29）：province_lut 采样器加 source_color，
--     引擎自动 sRGB→linear 解码 + 输出 linear→sRGB 编码，往返恒等，
--     大地图显示色 = LUT sRGB 值 = 小地图 NanoVG 直显色。
--     faction_lut 必须用独立纹理对象（键值是线性标量，不能被 sRGB 解码污染）。
--
-- 由 MapWidget 每帧驱动：
--   update(camX, camY, zoom, viewW, viewH)  同步相机
--   updateLUT(colorFn, factionKeyFn)         重建两张 LUT（势力/地形变化时）
--   setHover / setSelected                  交互高亮
------------------------------------------------------------------------
---@class MapShaderRenderer
---@field mat_ Material 地图 quad 材质（ParadoxMapV3.shader）
---@field lutTex_ Texture2D|nil 省 ID → 显示色 LUT 纹理
---@field factionTex_ Texture2D|nil 省 ID → 势力键 LUT 纹理
---@field camNode_ Node 地图正交相机节点
---@field camera_ Camera 地图正交相机
local MapPack = require("data.MapPack")

local MapShaderRenderer = {}

local WORLD_SCALE = 1000.0
local MAP_W = MapPack.MAP_W / WORLD_SCALE       -- 世界单位（当前包：eu4=2.82）
local MAP_H = MapPack.MAP_H / WORLD_SCALE       -- 世界单位（eu4=1.92）
local BITMAP_W = MapPack.BITMAP_W               -- 位图宽（map_texel 用）
local BITMAP_H = MapPack.BITMAP_H               -- 位图高
local LUT_W = MapPack.LUT_W or 4096             -- LUT 纹理宽

-- 海色（与底图 SEA_COLOR 一致，保持视觉风格）
local SEA_COLOR = { 156, 183, 212 }
-- 无主陆地默认色（羊皮纸米色）
local DEFAULT_LAND = { 210, 196, 158 }

------------------------------------------------------------------------
-- 内部：生成两张 LUT 纹理（Image → Texture2D:SetData）
--   province_lut：省 id → 显示色（渲染上色）
--   faction_lut：省 id → 势力键（边界判定；同势力同键不画边界）
------------------------------------------------------------------------
---@param colorFn function|nil  省 id → {r,g,b} 0-255；nil 用默认
---@param factionKeyFn function|nil  省 id → 势力键（整数）；nil 全 0
function MapShaderRenderer:updateLUT(colorFn, factionKeyFn)
    -- 纹理对象在首次创建后必须复用、只更新内容：
    -- 引擎对已编译/已渲染的 SurfaceShader 材质，替换 SetSurfaceTexture 为新纹理
    -- 对象不会生效（shader 仍采样首次绑定的纹理，实测势力色 LUT 出不来、全是
    -- 占位米色）。因此首次绑定后只对同一 Texture2D:SetData 刷新像素——2026-08-29。

    -- 1. 显示色 LUT
    local lutImg = Image()
    lutImg:SetSize(LUT_W, 1, 4)
    for x = 0, LUT_W - 1 do
        local c
        if x == 0 then
            c = SEA_COLOR
        else
            c = colorFn and colorFn(x)
            if not c then c = DEFAULT_LAND end
        end
        lutImg:SetPixel(x, 0, Color(c[1] / 255, c[2] / 255, c[3] / 255, 1.0))
    end
    local isNewLut = not self.lutTex_
    local lutTex = self.lutTex_ or Texture2D:new()
    lutTex:SetData(lutImg)
    lutTex.filterMode = FILTER_NEAREST   -- LUT 必须 NEAREST
    self.lutTex_ = lutTex
    if isNewLut then
        self.mat_:SetSurfaceTexture("province_lut", lutTex)
    end

    -- 2. 势力键 LUT（RGB 编码：R=k>>8, G=k&0xFF, B=0）
    local fImg = Image()
    fImg:SetSize(LUT_W, 1, 4)
    for x = 0, LUT_W - 1 do
        local k = 0
        if x > 0 and factionKeyFn then
            k = factionKeyFn(x) or 0
        end
        local hi = (k >> 8) & 0xFF
        local lo = k & 0xFF
        fImg:SetPixel(x, 0, Color(hi / 255, lo / 255, 0.0, 1.0))
    end
    local isNewFaction = not self.factionTex_
    local factionTex = self.factionTex_ or Texture2D:new()
    factionTex:SetData(fImg)
    factionTex.filterMode = FILTER_NEAREST   -- ⚠️ 势力键必须 NEAREST
    self.factionTex_ = factionTex
    if isNewFaction then
        self.mat_:SetSurfaceTexture("faction_lut", factionTex)
    end
end

------------------------------------------------------------------------
-- 创建：海色底 quad + 地图 quad + 正交相机
------------------------------------------------------------------------
MapShaderRenderer.__index = MapShaderRenderer

---@param scene Scene 共享 3D 场景
---@return table MapShaderRenderer 实例
function MapShaderRenderer.create(scene)
    local self = setmetatable({}, MapShaderRenderer)

    -- 0. 关闭色调映射（引擎默认 LUT tonemap 会把地图颜色压成灰白）
    --    ⚠️ Zone 必须设置覆盖全场景的 bounds，否则 tonemap 设置不生效
    --    🔧 环境光置零：引擎默认 ambient 会加进 unlit 输出（实测黑色通道被抬到
    --    ~137，逆推为 ~0.11 线性灰 ambient），必须显式指定 ambientSource=COLOR，
    --    否则 ambientColor 设置被默认 PREBAKED/SKYBOX 源忽略（2026-08-29）
    local zoneNode = scene:CreateChild("MapZone")
    local zone = zoneNode:CreateComponent("Zone")
    zone.tonemapMode = TONEMAP_MODE_NONE
    zone.ambientSource = AMBIENT_COLOR
    zone.ambientColor = Color(0.0, 0.0, 0.0, 1.0)
    zone.ambientStartColor = Color(0.0, 0.0, 0.0, 1.0)
    zone.ambientEndColor = Color(0.0, 0.0, 0.0, 1.0)
    zone.ambientIntensity = 0.0
    zone.boundingBox = BoundingBox(Vector3(-20.0, -20.0, -40.0), Vector3(30.0, 20.0, 10.0))
    zone:SetPriority(100)

    -- 1. 海色底 quad（比地图大一圈，相机 clamp 后无黑边）
    --    ⚠️ depth_draw_never 的 SurfaceShader（与地图同队列，避免盖住地图）
    local seaNode = scene:CreateChild("SeaQuad")
    seaNode:SetPosition(Vector3(MAP_W * 0.5, MAP_H * 0.5, -0.5))
    seaNode:SetScale(Vector3(MAP_W + 2.0, MAP_H + 2.0, 0.1))
    local seaSm = seaNode:CreateComponent("StaticModel")
    seaSm.model = cache:GetResource("Model", "Models/Box.mdl")
    local seaMat = Material:new()
    if not seaMat:SetSurfaceShader("Shaders/BLGL/SeaColor.shader") then
        print("[MapShaderRenderer] ⚠️ SeaColor.shader 加载失败")
    end
    seaMat:SetShaderParameter("sea_color",
        Variant(Color(SEA_COLOR[1] / 255, SEA_COLOR[2] / 255, SEA_COLOR[3] / 255, 1.0)))
    seaSm.material = seaMat

    -- 2. 地图 quad（shader 材质）
    --    🔧 CustomGeometry 显式 quad：Box 模型的面 UV 是图集式布局（不全幅），
    --    直接采样只能取到位图一角（2026-08-29 UV 诊断帧实证）。
    --    自建顶点让 UV 精确 [0,1]²：uv(0,0)=左上(逻辑顶部/位图首行)，v 向下。
    local mapNode = scene:CreateChild("MapQuad")
    mapNode:SetPosition(Vector3(0.0, 0.0, 0.0))
    local geom = mapNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)
    -- 顶点：世界坐标即逻辑/1000；LT(0,H)/(0,0) RT(W,H)/(1,0) RB(W,0)/(1,1) LB(0,0)/(0,1)
    -- 绕序：(v1-v0)×(v2-v0) = -Z，正面朝相机
    local vn = Vector3(0.0, 0.0, -1.0)
    geom:DefineVertex(Vector3(0.0, MAP_H, 0.0))       geom:DefineNormal(vn)  geom:DefineTexCoord(Vector2(0.0, 0.0))
    geom:DefineVertex(Vector3(MAP_W, MAP_H, 0.0))     geom:DefineNormal(vn)  geom:DefineTexCoord(Vector2(1.0, 0.0))
    geom:DefineVertex(Vector3(MAP_W, 0.0, 0.0))       geom:DefineNormal(vn)  geom:DefineTexCoord(Vector2(1.0, 1.0))
    geom:DefineVertex(Vector3(0.0, MAP_H, 0.0))       geom:DefineNormal(vn)  geom:DefineTexCoord(Vector2(0.0, 0.0))
    geom:DefineVertex(Vector3(MAP_W, 0.0, 0.0))       geom:DefineNormal(vn)  geom:DefineTexCoord(Vector2(1.0, 1.0))
    geom:DefineVertex(Vector3(0.0, 0.0, 0.0))         geom:DefineNormal(vn)  geom:DefineTexCoord(Vector2(0.0, 1.0))
    geom:Commit()
    local mat = Material:new()
    if not mat:SetSurfaceShader("Shaders/BLGL/ParadoxMapV3.shader") then
        print("[MapShaderRenderer] ⚠️ ParadoxMapV3.shader 加载失败")
    end
    local idTex = cache:GetResource("Texture2D", MapPack.PROVINCE_ID_PATH)
    mat:SetSurfaceTexture("province_map", idTex)
    -- 显示色 LUT：静态 pak 资源（gen_static_lut.py 生成，按势力归属写死颜色）。
    -- 必须在 create 时一次性绑定——引擎对已渲染的 SurfaceShader 材质，
    -- SetData/替换纹理均不刷新（GPU 采样器缓存），2026-08-29 实测。
    local lutTex = cache:GetResource("Texture2D", MapPack.PROVINCE_LUT_PATH)
    if lutTex then
        lutTex.filterMode = FILTER_NEAREST
        mat:SetSurfaceTexture("province_lut", lutTex)
        self.lutTex_ = lutTex
    else
        print("[MapShaderRenderer] ⚠️ province_lut.png 未加载，回退默认 LUT")
        self.lutTex_ = nil
        self.factionTex_ = nil
        self:updateLUT(nil, nil)
    end
    geom:SetMaterial(mat)
    self.mat_ = mat

    -- 3. 势力键 LUT（边界判定）：运行时势力归属在静态方案下不变，
    --    用同一张 province_lut 图片另建独立纹理对象，避免与 province_lut
    --    共用对象（province_lut 采样器带 source_color，引擎会把它标记为
    --    sRGB 自动解码；若复用同一纹理对象，faction_lut 的键值也被解码，
    --    浅色相邻键差值 < 0.5 会漏画边界）。键值语义与 V2 完全一致。
    if self.lutTex_ then
        local fImg = cache:GetResource("Image", MapPack.PROVINCE_LUT_PATH)
        if fImg then
            local factionTex = Texture2D:new()
            factionTex:SetData(fImg)
            factionTex.filterMode = FILTER_NEAREST   -- ⚠️ 势力键必须 NEAREST
            mat:SetSurfaceTexture("faction_lut", factionTex)
            self.factionTex_ = factionTex
        else
            print("[MapShaderRenderer] ⚠️ province_lut.png 图片资源未加载，faction_lut 退化复用 LUT 纹理")
            mat:SetSurfaceTexture("faction_lut", self.lutTex_)
            self.factionTex_ = self.lutTex_
        end
    end

    -- 4. 正交相机
    --    逻辑 y 向下、世界 Y 向上；顶点已按"世界 Y=MAP_H = 逻辑顶部"放置，
    --    因此相机世界 Y = MAP_H - camY/SCALE（camY 为逻辑视口中心）
    self.camNode_ = scene:CreateChild("MapCam")
    self.camera_ = self.camNode_:CreateComponent("Camera")
    self.camera_.orthographic = true
    self.camera_.orthoSize = MAP_H
    self.camNode_:SetPosition(Vector3(MAP_W * 0.5, MAP_H - MAP_H * 0.5, -10.0))

    -- 5. 关键 uniform（⚠️ shader 源码里的默认值不一定初始化，必须显式设置）
    mat:SetShaderParameter("lut_width", Variant(LUT_W))
    mat:SetShaderParameter("map_texel", Variant(Vector2(1.0 / BITMAP_W, 1.0 / BITMAP_H)))
    mat:SetShaderParameter("hover_id", Variant(-1))
    mat:SetShaderParameter("selected_id", Variant(-1))
    mat:SetShaderParameter("border_width", Variant(1.0))

    return self
end

---@return Camera 地图相机（用于 renderer:SetViewport）
function MapShaderRenderer:getCamera()
    return self.camera_
end

------------------------------------------------------------------------
-- 每帧同步：逻辑相机 → 3D 正交相机
-- camX/camY = 逻辑坐标视口中心；zoom = 逻辑像素→屏幕像素；viewW/H = widget 物理像素
------------------------------------------------------------------------
function MapShaderRenderer:update(camX, camY, zoom, viewW, viewH)
    local ortho = math.max(0.001, (viewH / zoom) / WORLD_SCALE)
    self.camera_.orthoSize = ortho
    -- 逻辑 y 向下、世界 Y 向上：世界 Y = MAP_H - camY/SCALE
    self.camNode_:SetPosition(Vector3(camX / WORLD_SCALE, MAP_H - camY / WORLD_SCALE, -10.0))

    -- 边界线宽固定屏幕 px（约 1.2px）：border_width(texel) = 1.2*zoom / (MAP_W/BITMAP_W)
    local bw = math.max(0.15, math.min(1.5, 1.2 * zoom / (MapPack.MAP_W / BITMAP_W)))
    self.mat_:SetShaderParameter("border_width", Variant(bw))
end

function MapShaderRenderer:setHover(id)
    self.mat_:SetShaderParameter("hover_id", Variant(id or -1))
end

function MapShaderRenderer:setSelected(id)
    self.mat_:SetShaderParameter("selected_id", Variant(id or -1))
end

return MapShaderRenderer

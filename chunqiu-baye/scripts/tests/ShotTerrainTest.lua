-- 验证：引擎自带地形系统能否加载并渲染
require("main")
local gameStart = Start

local frames, scene_, wp, cam_ = 0, nil, nil, nil

function HandleShotTerrainTest()
    frames = frames + 1

    if frames == 30 then
        local ok, err = pcall(function()
            scene_ = Scene()
            scene_:LoadXML("terrain/verify/scene.xml")
            wp = scene_:GetComponent("WorldPartitionComponent")
            print("[Terrain] 场景已加载，WorldPartition=" .. tostring(wp))

            -- 分区到底有没有网格？（uuid 没解析成功的话 = 0）
            local n = wp:GetNumGridLevels()
            print("[Terrain] 分区网格层数 = " .. tostring(n))
            if n == 0 then
                print("[Terrain] uuid 没解析成功 → 手动加载 world_partition.json")
                local ok2 = wp:LoadWorldData("terrain/verify/world_partition.json")
                print("[Terrain] 手动加载结果 = " .. tostring(ok2)
                    .. "，网格层数 = " .. tostring(wp:GetNumGridLevels()))
            end

            -- 地形范围 (0..122.88, 0..122.88)，相机放正上方俯视（距离最近 → 肯定在加载范围内）
            local cx, cz = 61.44, 61.44
            local camNode = scene_:CreateChild("Cam")
            camNode.position = Vector3(cx, 120, cz)
            camNode.rotation = Quaternion(-90, Vector3.RIGHT)   -- 垂直向下
            cam_ = camNode:CreateComponent("Camera")
            cam_.farClip = 800
            cam_.fov = 60

            local lightNode = scene_:CreateChild("Sun")
            lightNode.rotation = Quaternion(-45, Vector3.RIGHT)
            local light = lightNode:CreateComponent("Light")
            light.lightType = LIGHT_DIRECTIONAL
            light.brightness = 1.4

            local zoneNode = scene_:CreateChild("Zone")
            local zone = zoneNode:CreateComponent("Zone")
            zone.ambientColor = Color(0.55, 0.55, 0.6)

            renderer:SetViewport(0, Viewport:new(scene_, cam_))

            local UI = require("urhox-libs/UI")
            local uiRoot = UI.GetRoot()
            if uiRoot then uiRoot:Hide() end
            print("[Terrain] 搭建完成：相机在 (61.4, 120, 61.4) 垂直俯视")
        end)
        if not ok then print("[Terrain] 失败: " .. tostring(err)) end
        return
    end

    -- 每帧驱动场景更新（WorldPartition 靠这个感知相机、激活格子）
    if scene_ and frames > 30 then
        local ok = pcall(function() scene_:Update(1 / 60) end)
        if not ok then print("[Terrain] scene:Update 报错") end
    end

    if frames > 30 and frames % 30 == 0 and wp then
        local done = wp:IsInitialLoadComplete()
        local prog = wp:GetLoadingProgress()
        local total = wp:GetTotalCellsInRange()
        local act = wp:GetActivatedCellsInRange()
        print(string.format("[Terrain] 帧%d 完成=%s 进度=%.2f 范围内=%d 已激活=%d",
            frames, tostring(done), prog, total, act))
    end
end

function Start()
    gameStart()
    SubscribeToEvent("Update", "HandleShotTerrainTest")
end

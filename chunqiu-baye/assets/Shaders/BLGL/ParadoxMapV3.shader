// ParadoxMapV3.shader — P 社式 GPU 逐像素地图着色（颜色空间自动管理版）
// 管线：省 ID 位图(NEAREST) → 解码省 ID → 查 LUT(省ID→显示色)
//        → 4 邻比较「势力键」画边界（同势力同键不画；无主省每省唯一键必画）
//        → 海陆交界画海岸线 → hover / 选中高亮
// 颜色管线（V3 改进，2026-08-29）：
//   province_lut 加 source_color → 引擎自动 sRGB→linear 解码采样；
//   ALBEDO = col 直通（linear），引擎输出再 linear→sRGB 编码。
//   往返天然恒等：大地图显示色 = LUT 里写的 sRGB 值 = 小地图 NanoVG 直显色。
//   移除 V2 的 pipeline_inverse()（逆 gamma + 逆 ACES 拟合）——
//   实测其逆 ACES 部分在无 tonemap 管线上过冲，导致势力色发荧光。
// 注意：所有 texture() 采样必须直接写在 fragment() 主体内
//       （SurfaceShader 编译器对自定义函数内采样多 sampler 支持不稳）
// 数据约定：位图像素 RGB = (R=0, G=id>>8, B=id&0xFF)；id=0 为海洋
//           province_lut 索引 = 省 ID（0=海洋色），存显示色（sRGB，source_color）
//           faction_lut  索引 = 省 ID（0=海洋），RGB 编码势力键（线性标量，不解码）
//             有主省 = faction_id；无主省 = 256 + id（唯一，不与势力键冲突）
shader_type spatial;
render_mode shading_model_unlit, cull_disabled, depth_draw_never;

uniform sampler2D province_map;
uniform sampler2D province_lut : source_color;
uniform sampler2D faction_lut;
uniform float lut_width : hint_range(2.0, 65536.0, 1.0) = 4096.0;
uniform vec2 map_texel = vec2(0.000244140625, 0.0003841728774);   // 1/4096, 1/2603
uniform float border_width : hint_range(0.1, 2.0, 0.05) = 1.0;    // 边界线宽（texel，由 Lua 按 zoom 缩放）
uniform vec3 border_color : source_color = vec3(0.12, 0.12, 0.14);
uniform float border_mix : hint_range(0.0, 1.0, 0.05) = 0.55;
uniform vec3 coast_color : source_color = vec3(0.42, 0.53, 0.66);
uniform float coast_mix : hint_range(0.0, 1.0, 0.05) = 0.45;
uniform int hover_id = -1;
uniform vec4 hover_tint : source_color = vec4(1.0, 1.0, 0.78, 0.30);
uniform int selected_id = -1;
uniform vec4 selected_tint : source_color = vec4(1.0, 0.86, 0.32, 0.42);

// 解码省 ID（R=0, G=id>>8, B=id&0xFF）
float decode_id(vec4 px) {
    return px.g * 256.0 + px.b;
}

// 解码势力键（R=k>>8, G=k&0xFF, B=0）
float decode_key(vec4 px) {
    return px.r * 256.0 + px.g;
}

void fragment() {
    // V 轴直通：实测 Box 面 UV 下 1.0-UV.y 会造成上下颠倒（2026-08-29 阶跃编码实验）
    vec2 mUV = UV;
    vec2 texel = map_texel * border_width;

    // ── 当前省：ID / 显示色 / 势力键（全部采样在 fragment 主体内）──
    vec4 idpx = texture(province_map, mUV);
    float pid = decode_id(idpx);
    vec3 col = texture(province_lut, vec2((pid + 0.5) / lut_width, 0.5)).rgb;
    float key = decode_key(texture(faction_lut, vec2((pid + 0.5) / lut_width, 0.5)));

    // ── 4 邻边界检测：同省/同势力不画，海陆交界画海岸 ──
    float et = 0.0;   // 0=无, 1=势力边界, 2=海岸

    vec4 np1 = texture(province_map, mUV + vec2( texel.x, 0.0));
    float nid1 = decode_id(np1);
    if (abs(nid1 - pid) >= 0.5) {
        if (pid < 0.5 || nid1 < 0.5) {
            et = max(et, 2.0);
        } else {
            float nk1 = decode_key(texture(faction_lut, vec2((nid1 + 0.5) / lut_width, 0.5)));
            if (abs(nk1 - key) >= 0.5) { et = max(et, 1.0); }
        }
    }

    vec4 np2 = texture(province_map, mUV - vec2( texel.x, 0.0));
    float nid2 = decode_id(np2);
    if (abs(nid2 - pid) >= 0.5) {
        if (pid < 0.5 || nid2 < 0.5) {
            et = max(et, 2.0);
        } else {
            float nk2 = decode_key(texture(faction_lut, vec2((nid2 + 0.5) / lut_width, 0.5)));
            if (abs(nk2 - key) >= 0.5) { et = max(et, 1.0); }
        }
    }

    vec4 np3 = texture(province_map, mUV + vec2(0.0,  texel.y));
    float nid3 = decode_id(np3);
    if (abs(nid3 - pid) >= 0.5) {
        if (pid < 0.5 || nid3 < 0.5) {
            et = max(et, 2.0);
        } else {
            float nk3 = decode_key(texture(faction_lut, vec2((nid3 + 0.5) / lut_width, 0.5)));
            if (abs(nk3 - key) >= 0.5) { et = max(et, 1.0); }
        }
    }

    vec4 np4 = texture(province_map, mUV - vec2(0.0,  texel.y));
    float nid4 = decode_id(np4);
    if (abs(nid4 - pid) >= 0.5) {
        if (pid < 0.5 || nid4 < 0.5) {
            et = max(et, 2.0);
        } else {
            float nk4 = decode_key(texture(faction_lut, vec2((nid4 + 0.5) / lut_width, 0.5)));
            if (abs(nk4 - key) >= 0.5) { et = max(et, 1.0); }
        }
    }

    // 边界/海岸上色
    if (et > 1.5) {
        col = mix(col, coast_color, coast_mix);
    } else if (et > 0.5) {
        col = mix(col, border_color, border_mix);
    }

    // 交互高亮（hover / 选中）
    int ipid = int(pid + 0.5);
    if (hover_id >= 0 && ipid == hover_id) {
        col = mix(col, hover_tint.rgb, hover_tint.a);
    }
    if (selected_id >= 0 && ipid == selected_id) {
        col = mix(col, selected_tint.rgb, selected_tint.a);
    }

    // 直通输出：source_color 已把 LUT 解码为 linear，
    // 引擎输出 linear→sRGB 编码，往返恒等 → 与小地图直显色一致
    ALBEDO = col;
    ALPHA = 1.0;
}

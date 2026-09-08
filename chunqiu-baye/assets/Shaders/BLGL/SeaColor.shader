// SeaColor.shader — 海色底（depth_draw_never 与地图 quad 同渲染队列）
// ⚠️ 必须与地图 quad 同队列（depth_draw_never），否则不透明底会盖住地图
shader_type spatial;
render_mode shading_model_unlit, cull_disabled, depth_draw_never;

uniform vec4 sea_color : source_color = vec4(0.61, 0.72, 0.83, 1.0);

vec3 pipeline_inverse(vec3 target) {
    vec3 lin = pow(max(target, vec3(0.0)), vec3(2.2));
    vec3 a = vec3(2.43) * lin - vec3(2.51);
    vec3 b = vec3(0.59) * lin - vec3(0.03);
    vec3 c = vec3(0.14) * lin;
    vec3 disc = sqrt(max(b * b - 4.0 * a * c, vec3(0.0)));
    vec3 x = (-b - disc) / (2.0 * a);
    return clamp(x, vec3(0.0), vec3(1.0));
}

void fragment() {
    ALBEDO = pipeline_inverse(sea_color.rgb);
    ALPHA = 1.0;
}
